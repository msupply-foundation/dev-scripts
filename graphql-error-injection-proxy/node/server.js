#!/usr/bin/env node
/* eslint-disable no-console */
/*
 * GraphQL fault-injection proxy
 *
 * Sits between the client and the real omSupply server and lets a tester
 * selectively replace GraphQL responses with typed errors (Unauthenticated,
 * Forbidden, BadUserInput, InternalServerError) or simulate transport
 * failures (offline, HTTP 500 no body, truncation).
 *
 * Used for manual testing of PR #11444 (typed GraphQL errors + connection
 * banner). See README.md in this folder for usage.
 *
 * Defaults:
 *   - Listens on  http://localhost:8000  (the client's dev API host)
 *   - Forwards to http://localhost:8001  (run the real server there)
 *   - Control UI on http://localhost:8000/__mock
 *
 * No dependencies; Node 18+ (uses global fetch).
 */

const http = require("http");
const fs = require("fs");
const path = require("path");
const { URL } = require("url");

const CONTROL_HTML = fs.readFileSync(
  path.join(__dirname, "control.html"),
  "utf8",
);

const LISTEN_PORT = parseInt(process.env.MOCK_PORT || "8000", 10);
const UPSTREAM = process.env.UPSTREAM || "http://localhost:8001";

/**
 * Active rules. Mutated via the /__mock/control endpoint.
 *
 *   mode: 'passthrough' | 'offline' | 'error' | 'http_status' | 'truncate'
 *   errorType: 'Unauthenticated' | 'Forbidden' | 'Bad user input'
 *              | 'Internal error' | (custom string for the message field)
 *   detail: optional string for `extensions.details`
 *   path: optional string[] for `path` (used by Forbidden allowlist test)
 *   operations: string[]    only apply when operationName is in this list
 *                           (empty = apply to ALL graphql requests)
 *   count: number | null    apply this many times then auto-revert to
 *                           passthrough; null = forever
 *   delay_ms: number        delay before responding (any mode)
 *   http_status: number     used when mode === 'http_status'
 */
let rule = {
  mode: "passthrough",
  errorType: "Internal error",
  detail: "",
  path: [],
  operations: [],
  count: null,
  delay_ms: 0,
  http_status: 500,
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Build CORS headers for a response. The client may be on a different
 * origin (e.g. webpack dev server on :3003 while we listen on :8000)
 * and sends cookies, so we can't use the wildcard `*` — we must echo
 * the request's Origin and set `Allow-Credentials: true`.
 */
const corsHeaders = (req) => {
  const origin = req.headers.origin;
  const reqHeaders = req.headers["access-control-request-headers"];
  const reqMethod = req.headers["access-control-request-method"];
  const headers = {
    "Access-Control-Allow-Origin": origin || "*",
    "Access-Control-Allow-Methods":
      reqMethod || "GET, POST, PUT, PATCH, DELETE, OPTIONS",
    "Access-Control-Allow-Headers":
      reqHeaders || "Content-Type, Authorization, X-Requested-With",
    "Access-Control-Expose-Headers": "*",
    "Access-Control-Max-Age": "600",
    Vary: "Origin",
  };
  if (origin) headers["Access-Control-Allow-Credentials"] = "true";
  return headers;
};

// Headers we never want to pass through from upstream — we set our own
// CORS so cookies work cross-origin during `yarn start`.
const STRIPPED_UPSTREAM_HEADERS = new Set([
  "content-encoding",
  "content-length",
  "access-control-allow-origin",
  "access-control-allow-credentials",
  "access-control-allow-methods",
  "access-control-allow-headers",
  "access-control-expose-headers",
  "access-control-max-age",
]);

const copyUpstreamHeaders = (upstreamRes) => {
  const out = {};
  upstreamRes.headers.forEach((v, k) => {
    if (STRIPPED_UPSTREAM_HEADERS.has(k)) return;
    out[k] = v;
  });
  return out;
};

const ruleAppliesTo = (operationName) => {
  if (rule.mode === "passthrough") return false;
  if (!rule.operations || rule.operations.length === 0) return true;
  return rule.operations.includes(operationName);
};

const consumeRule = () => {
  if (rule.count === null) return;
  rule.count -= 1;
  if (rule.count <= 0) {
    rule.mode = "passthrough";
    rule.count = null;
  }
};

const sendJson = (req, res, status, body) => {
  const json = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(json),
    ...corsHeaders(req),
  });
  res.end(json);
};

const respondTypedError = (req, res, operationName) => {
  const body = {
    errors: [
      {
        message: rule.errorType,
        path: rule.path && rule.path.length ? rule.path : [operationName],
        extensions: rule.detail ? { details: rule.detail } : undefined,
      },
    ],
    data: null,
  };
  sendJson(req, res, 200, body);
};

const respondHttpStatus = (req, res) => {
  res.writeHead(rule.http_status, {
    "Content-Type": "text/plain",
    ...corsHeaders(req),
  });
  // No body — exercises the `isTransportFailure` fallback path in
  // GqlContext.tsx that treats HTTP errors with no graphql body as
  // NetworkError.
  res.end("mock proxy: forced status");
};

const respondTruncated = async (req, res) => {
  // Forward to upstream, then close the connection mid-response to
  // simulate a partial body / dropped connection.
  const upstream = await forwardToUpstream(req);
  res.writeHead(upstream.status, upstream.headers);
  res.write(upstream.body.slice(0, Math.floor(upstream.body.length / 2)));
  res.destroy(); // hard close — client sees ECONNRESET
};

const goOffline = (res) => {
  // Hard-close the socket. From the browser's perspective this looks
  // like a transport failure, which is what NetworkError represents.
  res.destroy();
};

const forwardToUpstream = async (req) => {
  const url = new URL(req.url, UPSTREAM);
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const body = Buffer.concat(chunks);

  const headers = { ...req.headers };
  delete headers.host;
  delete headers["content-length"];

  const upstreamRes = await fetch(url.toString(), {
    method: req.method,
    headers,
    body: req.method === "GET" || req.method === "HEAD" ? undefined : body,
    redirect: "manual",
  });

  const respBody = Buffer.from(await upstreamRes.arrayBuffer());
  const respHeaders = {
    ...copyUpstreamHeaders(upstreamRes),
    ...corsHeaders(req),
  };

  return { status: upstreamRes.status, headers: respHeaders, body: respBody };
};

const handleGraphql = async (req, res) => {
  // Buffer the request body so we can both inspect it (for operationName)
  // and replay it to upstream.
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const body = Buffer.concat(chunks);

  let operationName = "";
  try {
    const parsed = JSON.parse(body.toString("utf8"));
    operationName = parsed.operationName || "";
  } catch {
    /* not a JSON graphql request — fall through */
  }

  if (!ruleAppliesTo(operationName)) {
    // Passthrough: rebuild the upstream request with the buffered body.
    const url = new URL(req.url, UPSTREAM);
    const headers = { ...req.headers };
    delete headers.host;
    delete headers["content-length"];

    const upstreamRes = await fetch(url.toString(), {
      method: req.method,
      headers,
      body,
      redirect: "manual",
    });
    const respBody = Buffer.from(await upstreamRes.arrayBuffer());
    const respHeaders = {
      ...copyUpstreamHeaders(upstreamRes),
      ...corsHeaders(req),
    };
    res.writeHead(upstreamRes.status, respHeaders);
    res.end(respBody);
    return;
  }

  if (rule.delay_ms > 0) await sleep(rule.delay_ms);

  console.log(
    `[mock] ${rule.mode} (${rule.errorType}) for operation=${operationName || "<anonymous>"}`,
  );

  switch (rule.mode) {
    case "offline":
      goOffline(res);
      break;
    case "error":
      respondTypedError(req, res, operationName);
      break;
    case "http_status":
      respondHttpStatus(req, res);
      break;
    case "truncate":
      // Forward to upstream first, then truncate. Need to recreate the
      // request stream from the buffered body.
      try {
        const url = new URL(req.url, UPSTREAM);
        const headers = { ...req.headers };
        delete headers.host;
        delete headers["content-length"];
        const upstreamRes = await fetch(url.toString(), {
          method: req.method,
          headers,
          body,
          redirect: "manual",
        });
        const upstreamBody = Buffer.from(await upstreamRes.arrayBuffer());
        res.writeHead(upstreamRes.status, {
          "Content-Type": "application/json",
          ...corsHeaders(req),
        });
        res.write(upstreamBody.slice(0, Math.floor(upstreamBody.length / 2)));
        res.destroy();
      } catch {
        res.destroy();
      }
      break;
    default:
      sendJson(req, res, 500, { error: "mock: unknown mode " + rule.mode });
  }

  consumeRule();
};

const handleControl = async (req, res) => {
  if (req.method === "GET") {
    sendJson(req, res, 200, rule);
    return;
  }
  if (req.method === "POST") {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    try {
      const patch = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      rule = { ...rule, ...patch };
      console.log("[mock] rule updated:", rule);
      sendJson(req, res, 200, rule);
    } catch (e) {
      sendJson(req, res, 400, { error: String(e) });
    }
    return;
  }
  sendJson(req, res, 405, { error: "method not allowed" });
};

const handleControlUi = (req, res) => {
  res.writeHead(200, { "Content-Type": "text/html", ...corsHeaders(req) });
  res.end(CONTROL_HTML);
};

const server = http.createServer(async (req, res) => {
  // CORS preflight. With `yarn start` the client is on a different
  // origin (webpack dev server) and sends cookies, so we echo the
  // Origin and set Allow-Credentials — wildcard would be rejected.
  if (req.method === "OPTIONS") {
    res.writeHead(204, corsHeaders(req));
    res.end();
    return;
  }

  try {
    if (req.url === "/__mock" || req.url === "/__mock/") {
      handleControlUi(req, res);
      return;
    }
    if (req.url === "/__mock/control") {
      await handleControl(req, res);
      return;
    }
    if (req.url === "/graphql" || req.url.startsWith("/graphql?")) {
      await handleGraphql(req, res);
      return;
    }
    // Everything else: pass through.
    const upstream = await forwardToUpstream(req);
    res.writeHead(upstream.status, upstream.headers);
    res.end(upstream.body);
  } catch (e) {
    console.error("[mock] error:", e);
    if (!res.headersSent) {
      sendJson(req, res, 502, { error: "mock proxy error: " + String(e) });
    } else {
      res.destroy();
    }
  }
});

server.listen(LISTEN_PORT, () => {
  console.log(`[mock] listening on http://localhost:${LISTEN_PORT}`);
  console.log(`[mock] forwarding to ${UPSTREAM}`);
  console.log(`[mock] control UI: http://localhost:${LISTEN_PORT}/__mock`);
});
