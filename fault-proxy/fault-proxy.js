#!/usr/bin/env node
/**
 * fault-proxy — a tiny, zero-dependency reverse proxy for exercising the
 * client's error-handling paths (PR #11444 "Typed GraphQL errors, connection
 * banner, cookie validation" and the #11885 long-delay work).
 *
 * It sits between the web client and the open-mSupply server and lets you
 * inject failure modes live, without touching the server. Point the client at
 * the proxy instead of the real API:
 *
 *     node fault-proxy/fault-proxy.js                  # proxy :8001 -> :8000
 *     cd client && yarn start --env API_HOST=http://localhost:8001
 *
 * Then open the control panel at http://localhost:8001/__proxy and flip modes
 * while the app is running.
 *
 * Why a socket-level proxy and not webpack devServer.proxy / mitmproxy:
 *  - "offline" needs to destroy the TCP connection so the browser's fetch
 *    rejects with a TypeError (no HTTP response). That is exactly what
 *    GqlContext's `isTransportFailure` maps to `NetworkError`. A normal HTTP
 *    proxy returning 502 would NOT reproduce that branch.
 *
 * How the client maps responses to typed errors (see
 * client/packages/common/src/api/GqlContext.tsx + errors.ts in PR #11444):
 *  - No HTTP response at all (socket drop / DNS / CORS) ......... NetworkError
 *  - HTTP error with no GraphQL `errors` body .................. NetworkError
 *  - HTTP 200 { errors:[{ message:'Unauthenticated' }] } ....... UnauthenticatedError
 *  - HTTP 200 { errors:[{ message:'Forbidden', path }] } ....... PermissionDeniedError
 *  - HTTP 200 { errors:[{ message:'Bad user input' }] } ........ BadUserInputError
 *  - HTTP 200 { errors:[{ message:'Internal error' }] } ........ InternalServerError
 *  - HTTP 200 { data:{...}, errors:[...] } .................... errors + partial data
 */

'use strict';

const http = require('http');
const { URL } = require('url');

// ---------------------------------------------------------------------------
// Config (override via env)
// ---------------------------------------------------------------------------
const PROXY_PORT = Number(process.env.PROXY_PORT || 8001);
const UPSTREAM = new URL(process.env.UPSTREAM || 'http://localhost:8000');

// ---------------------------------------------------------------------------
// Mode catalogue — single source of truth for the control panel + help text.
// `kind` tells the request handler how to respond.
// ---------------------------------------------------------------------------
const MODES = {
  pass: {
    label: 'Pass-through (healthy)',
    kind: 'pass',
    desc: 'Forward everything to the real server unchanged.',
    clientResult: '—',
  },
  offline: {
    label: 'Offline (drop connection)',
    kind: 'drop',
    desc: 'Destroy the socket with no HTTP response. Simulates the server being stopped / unreachable.',
    clientResult: 'NetworkError → ConnectionLostBanner / ConnectionLostPage',
  },
  http500: {
    label: 'HTTP 500, empty body',
    kind: 'http500',
    desc: 'Return a bare HTTP 500 with no GraphQL errors body (transport-error branch).',
    clientResult: 'NetworkError (via isTransportFailure HTTP path)',
  },
  internal: {
    label: 'GraphQL "Internal error"',
    kind: 'gql',
    message: 'Internal error',
    desc: 'HTTP 200 with a GraphQL Internal error. Like forcing a panic/Err in a resolver.',
    clientResult: 'InternalServerError → toast + Bugsnag',
  },
  unauthenticated: {
    label: 'GraphQL "Unauthenticated"',
    kind: 'gql',
    message: 'Unauthenticated',
    desc: 'HTTP 200 with an Unauthenticated GraphQL error (expired/rejected token).',
    clientResult: 'UnauthenticatedError → re-login modal',
  },
  forbidden: {
    label: 'GraphQL "Forbidden"',
    kind: 'gql',
    message: 'Forbidden',
    desc: 'HTTP 200 with a Forbidden GraphQL error (authenticated but not allowed).',
    clientResult: 'PermissionDeniedError → permission modal',
  },
  badinput: {
    label: 'GraphQL "Bad user input"',
    kind: 'gql',
    message: 'Bad user input',
    desc: 'HTTP 200 with a Bad user input GraphQL error.',
    clientResult: 'BadUserInputError → toast',
  },
  partial: {
    label: 'Errors + partial data',
    kind: 'partial',
    message: 'Forbidden',
    desc: 'Forward the real response but graft an errors[] array onto it, keeping data. Exercises the errors+data matrix cell.',
    clientResult: 'Typed error thrown even though data is present',
  },
  delay: {
    label: 'Slow response (delay)',
    kind: 'delay',
    desc: 'Forward to the real server but hold the response back by delayMs. Tests timeouts / "startup in progress" masquerade and the migration loader.',
    clientResult: 'Eventually succeeds (or whatever the client timeout does)',
  },
};

// ---------------------------------------------------------------------------
// Mutable runtime state
// ---------------------------------------------------------------------------
const state = {
  mode: 'pass',
  scope: 'graphql', // 'graphql' = only /graphql requests are faulted; 'all' = everything
  count: 0, // 0 = until changed; >0 = fault next N matching POSTs, then auto-revert to pass
  delayMs: 5000, // used by delay mode
  detail: 'Injected by fault-proxy', // extensions.details on injected GraphQL errors
};

let faultsServed = 0; // simple counter for the panel

const isGraphql = pathname => pathname === '/graphql' || pathname.startsWith('/graphql');

const inScope = pathname =>
  state.scope === 'all' || isGraphql(pathname);

const log = (...args) => console.log('[fault-proxy]', ...args);

// ---------------------------------------------------------------------------
// CORS helpers — injected (non-forwarded) responses must carry CORS headers
// themselves, because the browser talks to the proxy origin. The client sends
// `credentials: 'include'` so we must echo Origin (not '*') + allow-credentials.
// ---------------------------------------------------------------------------
const corsHeaders = req => ({
  'Access-Control-Allow-Origin': req.headers.origin || '*',
  'Access-Control-Allow-Credentials': 'true',
  Vary: 'Origin',
});

const sendPreflight = (req, res) => {
  res.writeHead(204, {
    ...corsHeaders(req),
    'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, PATCH, OPTIONS',
    'Access-Control-Allow-Headers':
      req.headers['access-control-request-headers'] ||
      'authorization, content-type',
    'Access-Control-Max-Age': '600',
  });
  res.end();
};

const sendJson = (req, res, status, bodyObj) => {
  const body = JSON.stringify(bodyObj);
  res.writeHead(status, {
    ...corsHeaders(req),
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
};

const graphqlErrorBody = (message, { data = null, path } = {}) => ({
  data,
  errors: [
    {
      message,
      ...(path ? { path } : {}),
      extensions: { details: state.detail },
    },
  ],
});

// ---------------------------------------------------------------------------
// Pass-through proxy to the upstream server
// ---------------------------------------------------------------------------
const proxyPass = (req, res, { transform } = {}) => {
  const headers = { ...req.headers, host: UPSTREAM.host };

  const upstreamReq = http.request(
    {
      protocol: UPSTREAM.protocol,
      hostname: UPSTREAM.hostname,
      port: UPSTREAM.port,
      method: req.method,
      path: req.url,
      headers,
    },
    upstreamRes => {
      if (!transform) {
        // Stream straight back, preserving status + upstream CORS headers.
        res.writeHead(upstreamRes.statusCode, upstreamRes.headers);
        upstreamRes.pipe(res);
        return;
      }
      // Buffer so we can rewrite the body (used by `partial`).
      const chunks = [];
      upstreamRes.on('data', c => chunks.push(c));
      upstreamRes.on('end', () => {
        const buf = Buffer.concat(chunks);
        const out = transform(buf, upstreamRes) ?? buf;
        const headersOut = { ...upstreamRes.headers };
        delete headersOut['content-length'];
        delete headersOut['content-encoding']; // we may have decoded/rewritten
        res.writeHead(upstreamRes.statusCode, headersOut);
        res.end(out);
      });
    }
  );

  upstreamReq.on('error', err => {
    // Real server is genuinely down → behave like 'offline' so the client
    // still sees an honest transport failure rather than a proxy 502.
    log(`upstream error (${err.code || err.message}) → dropping socket`);
    try {
      req.socket.destroy();
    } catch {
      /* noop */
    }
  });

  req.pipe(upstreamReq);
};

// ---------------------------------------------------------------------------
// Fault application
// ---------------------------------------------------------------------------

// Buffer the request body so we can log which GraphQL operation was faulted.
// Used by the injected modes (which don't forward the body upstream anyway),
// so consuming the stream here is safe.
const bufferBody = (req, cb) => {
  const chunks = [];
  req.on('data', c => chunks.push(c));
  req.on('end', () => cb(Buffer.concat(chunks).toString('utf8')));
  req.on('error', () => cb(''));
};

const opName = body => {
  const m = body.match(/"operationName"\s*:\s*"([^"]+)"/);
  if (m && m[1]) return m[1];
  const m2 = body.match(/(?:query|mutation|subscription)\s+(\w+)/);
  return m2 ? m2[1] : '(anonymous)';
};

const stamp = () => new Date().toISOString().slice(11, 23); // HH:MM:SS.mmm

const applyFault = (req, res, mode) => {
  const def = MODES[mode];
  faultsServed += 1;
  const seq = faultsServed;

  switch (def.kind) {
    case 'drop':
      bufferBody(req, body => {
        log(`#${seq} ${stamp()} drop          op=${opName(body)}`);
        req.socket.destroy();
      });
      return;

    case 'http500':
      bufferBody(req, body => {
        log(`#${seq} ${stamp()} http500       op=${opName(body)}`);
        res.writeHead(500, {
          ...corsHeaders(req),
          'Content-Type': 'text/plain',
        });
        res.end(''); // empty body → client's transport-failure branch
      });
      return;

    case 'gql':
      bufferBody(req, body => {
        log(`#${seq} ${stamp()} gql:${def.message.padEnd(16)} op=${opName(body)}`);
        sendJson(
          req,
          res,
          200,
          graphqlErrorBody(def.message, {
            path: def.message === 'Forbidden' ? ['queryName'] : undefined,
          })
        );
      });
      return;

    case 'partial':
      log(`partial (data + "${def.message}") ${req.method} ${req.url}`);
      proxyPass(req, res, {
        transform: buf => {
          let parsed;
          try {
            parsed = JSON.parse(buf.toString('utf8'));
          } catch {
            return buf; // not JSON, leave alone
          }
          parsed.errors = [
            ...(parsed.errors || []),
            {
              message: def.message,
              path: ['queryName'],
              extensions: { details: state.detail },
            },
          ];
          return JSON.stringify(parsed);
        },
      });
      return;

    case 'delay':
      log(`delay ${state.delayMs}ms ${req.method} ${req.url}`);
      setTimeout(() => proxyPass(req, res), state.delayMs);
      return;

    default:
      proxyPass(req, res);
  }
};

// ---------------------------------------------------------------------------
// Control plane (/__proxy ...)
// ---------------------------------------------------------------------------
const setStateFromParams = params => {
  if (params.has('mode') && MODES[params.get('mode')]) {
    state.mode = params.get('mode');
  }
  if (params.has('scope')) {
    const s = params.get('scope');
    if (s === 'graphql' || s === 'all') state.scope = s;
  }
  if (params.has('count')) state.count = Math.max(0, Number(params.get('count')) || 0);
  if (params.has('delayMs')) state.delayMs = Math.max(0, Number(params.get('delayMs')) || 0);
  if (params.has('detail')) state.detail = params.get('detail');
};

const handleControl = (req, res, url) => {
  // State as JSON
  if (url.pathname === '/__proxy/state') {
    return sendJson(req, res, 200, { ...state, faultsServed, upstream: UPSTREAM.href });
  }

  // Set mode (GET query or POST body), e.g. /__proxy/mode?mode=offline&count=1
  if (url.pathname === '/__proxy/mode' || url.pathname === '/__proxy/set') {
    const apply = body => {
      const params =
        body && body.length
          ? new URLSearchParams(body)
          : url.searchParams;
      setStateFromParams(params);
      log(`mode=${state.mode} scope=${state.scope} count=${state.count} delayMs=${state.delayMs}`);
      sendJson(req, res, 200, { ...state, faultsServed });
    };
    if (req.method === 'POST') {
      let body = '';
      req.on('data', c => (body += c));
      req.on('end', () => {
        try {
          // accept JSON or form-encoded
          if (body.trim().startsWith('{')) {
            const obj = JSON.parse(body);
            const p = new URLSearchParams();
            Object.entries(obj).forEach(([k, v]) => p.set(k, v));
            return apply(p.toString());
          }
        } catch {
          /* fall through to form parse */
        }
        apply(body);
      });
      return;
    }
    return apply('');
  }

  // Control panel HTML
  if (url.pathname === '/__proxy' || url.pathname === '/__proxy/') {
    const html = controlPanelHtml();
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(html);
  }

  return sendJson(req, res, 404, { error: 'unknown control endpoint' });
};

// ---------------------------------------------------------------------------
// Main server
// ---------------------------------------------------------------------------
const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${PROXY_PORT}`);

  // Control plane first
  if (url.pathname.startsWith('/__proxy')) {
    return handleControl(req, res, url);
  }

  const faulting = state.mode !== 'pass' && inScope(url.pathname);

  // Preflight: in non-offline modes we still need CORS to succeed so the real
  // POST is sent and our injected JSON body can be read by the browser. In
  // offline mode we drop the preflight too (server is "gone").
  if (req.method === 'OPTIONS') {
    if (faulting && MODES[state.mode].kind === 'drop') {
      log(`drop preflight ${req.url}`);
      return req.socket.destroy();
    }
    if (faulting) return sendPreflight(req, res);
    return proxyPass(req, res); // let upstream answer its own preflight
  }

  if (!faulting) return proxyPass(req, res);

  // count-limited one-shots: only real (non-OPTIONS) requests decrement.
  const mode = state.mode;
  if (state.count > 0) {
    state.count -= 1;
    if (state.count === 0) {
      log(`count exhausted → reverting to pass after this request`);
      // revert AFTER serving this faulted request
      setImmediate(() => {
        state.mode = 'pass';
      });
    }
  }

  return applyFault(req, res, mode);
});

server.listen(PROXY_PORT, () => {
  log(`listening on http://localhost:${PROXY_PORT}  ->  ${UPSTREAM.href}`);
  log(`control panel:  http://localhost:${PROXY_PORT}/__proxy`);
  log('');
  log('Start the client pointed at the proxy:');
  log(`  cd client && yarn start --env API_HOST=http://localhost:${PROXY_PORT}`);
  log('');
});

// ---------------------------------------------------------------------------
// Control panel UI
// ---------------------------------------------------------------------------
function controlPanelHtml() {
  const modeButtons = Object.entries(MODES)
    .map(
      ([key, def]) => `
      <button class="mode" data-mode="${key}">
        <span class="m-label">${def.label}</span>
        <span class="m-key">${key}</span>
        <span class="m-desc">${def.desc}</span>
        <span class="m-result">→ ${def.clientResult}</span>
      </button>`
    )
    .join('');

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>fault-proxy control</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 14px/1.5 system-ui, -apple-system, sans-serif; margin: 0; padding: 24px; max-width: 880px; }
  h1 { font-size: 18px; margin: 0 0 4px; }
  .sub { color: #888; margin: 0 0 20px; }
  .current { padding: 12px 16px; border-radius: 10px; background: #1f6feb1a; border: 1px solid #1f6feb55; margin-bottom: 20px; }
  .current b { font-size: 16px; }
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
  button.mode { text-align: left; padding: 12px 14px; border-radius: 10px; border: 1px solid #8884; background: #8881; cursor: pointer; display: flex; flex-direction: column; gap: 2px; }
  button.mode:hover { border-color: #1f6feb; }
  button.mode.active { border-color: #1f6feb; background: #1f6feb22; outline: 2px solid #1f6feb55; }
  .m-label { font-weight: 600; }
  .m-key { font-family: ui-monospace, monospace; font-size: 11px; color: #888; }
  .m-desc { font-size: 12px; color: #aaa; }
  .m-result { font-size: 12px; color: #2ea043; font-family: ui-monospace, monospace; }
  .controls { display: flex; gap: 16px; flex-wrap: wrap; align-items: end; margin: 20px 0; }
  .controls label { display: flex; flex-direction: column; gap: 4px; font-size: 12px; color: #888; }
  input, select { font: inherit; padding: 6px 8px; border-radius: 8px; border: 1px solid #8886; background: transparent; color: inherit; }
  .hint { font-size: 12px; color: #888; margin-top: 18px; }
  code { font-family: ui-monospace, monospace; background: #8881; padding: 1px 5px; border-radius: 4px; }
  .pill { display:inline-block; padding:1px 8px; border-radius: 999px; background:#8882; font-family: ui-monospace, monospace; font-size: 12px; }
</style>
</head>
<body>
  <h1>fault-proxy</h1>
  <p class="sub">Injecting faults between the client and <span class="pill">${UPSTREAM.href}</span></p>

  <div class="current">
    Active mode: <b id="cur-mode">…</b>
    &nbsp;·&nbsp; scope <span class="pill" id="cur-scope">…</span>
    &nbsp;·&nbsp; count <span class="pill" id="cur-count">…</span>
    &nbsp;·&nbsp; faults served <span class="pill" id="cur-served">…</span>
  </div>

  <div class="grid">${modeButtons}</div>

  <div class="controls">
    <label>scope
      <select id="scope">
        <option value="graphql">graphql only (/graphql)</option>
        <option value="all">all requests</option>
      </select>
    </label>
    <label>count (0 = until changed)
      <input id="count" type="number" min="0" value="0" style="width:120px" />
    </label>
    <label>delayMs (delay mode)
      <input id="delayMs" type="number" min="0" value="5000" style="width:120px" />
    </label>
    <label>detail (error details)
      <input id="detail" type="text" value="Injected by fault-proxy" style="width:200px" />
    </label>
  </div>

  <p class="hint">
    <b>count</b> = fault the next N GraphQL POSTs, then auto-revert to pass — handy for testing banner
    auto-dismiss ("next query succeeds") and re-arm. <b>offline</b> ignores count and persists until you change it.
    <br/>Same controls over curl: <code>curl 'http://localhost:${PROXY_PORT}/__proxy/mode?mode=offline'</code>
    · <code>curl 'http://localhost:${PROXY_PORT}/__proxy/mode?mode=forbidden&count=1'</code>
    · <code>curl 'http://localhost:${PROXY_PORT}/__proxy/mode?mode=pass'</code>
  </p>

<script>
  const $ = s => document.querySelector(s);
  async function refresh() {
    const s = await (await fetch('/__proxy/state')).json();
    $('#cur-mode').textContent = s.mode;
    $('#cur-scope').textContent = s.scope;
    $('#cur-count').textContent = s.count;
    $('#cur-served').textContent = s.faultsServed;
    document.querySelectorAll('button.mode').forEach(b =>
      b.classList.toggle('active', b.dataset.mode === s.mode));
    // keep inputs in sync (but don't clobber while focused)
    if (document.activeElement.id !== 'scope') $('#scope').value = s.scope;
    if (document.activeElement.id !== 'count') $('#count').value = s.count;
    if (document.activeElement.id !== 'delayMs') $('#delayMs').value = s.delayMs;
    if (document.activeElement.id !== 'detail') $('#detail').value = s.detail;
  }
  async function setMode(mode) {
    const p = new URLSearchParams({
      mode,
      scope: $('#scope').value,
      count: $('#count').value,
      delayMs: $('#delayMs').value,
      detail: $('#detail').value,
    });
    await fetch('/__proxy/mode?' + p.toString());
    refresh();
  }
  document.querySelectorAll('button.mode').forEach(b =>
    b.addEventListener('click', () => setMode(b.dataset.mode)));
  // pushing scope/delay/detail without changing mode
  ['scope','count','delayMs','detail'].forEach(id =>
    $('#' + id).addEventListener('change', () => setMode($('#cur-mode').textContent)));
  refresh();
  setInterval(refresh, 1500);
</script>
</body>
</html>`;
}
