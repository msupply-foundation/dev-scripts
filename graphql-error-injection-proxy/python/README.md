# GraphQL fault-injection proxy (Python / mitmproxy)

A mitmproxy reverse proxy used for manual testing of the typed GraphQL
error / connection banner work in
[PR #11444](https://github.com/msupply-foundation/open-msupply/pull/11444).

It sits between the client and the real omSupply server and proxies
everything normally — but lets you selectively swap individual
operations for typed GraphQL errors (`Unauthenticated`, `Forbidden`,
`Bad user input`, `Internal error`) or simulate transport failures
(offline, HTTP 500 with no body, truncated body) via a small web UI.

This is the mitmproxy-based sibling of the [Node version](../node/).
Prefer the Node version unless you specifically want mitmproxy — it
needs no install step. See the [top-level README](../README.md) for a
comparison.

## Install

Needs [mitmproxy](https://mitmproxy.org/) (it ships its own bundled
Python, so no virtualenv is required):

```sh
brew install mitmproxy
mitmdump --version
```

## Setup

Two processes:

1. **Real server on port 8001:**

   ```sh
   cd server
   APP__SERVER__PORT=8001 cargo run
   ```

2. **Fault-injection proxy on port 8000:**

   ```sh
   cd scripts/graphql-error-injection-proxy/python
   mitmdump -s ./fault_injection_proxy.py \
     --mode reverse:http://localhost:8001 --listen-port 8000
   ```

3. **Run the client dev build as normal** — it'll hit the proxy.

Then open the control UI at <http://localhost:8000/__mock>.

## Rule model

Rules have two stages:

- **Stage 1 — `active`:** master switch. When off, the proxy is
  byte-for-byte transparent and nothing else in the rule has any effect.
- **Stage 2 — when active, these compose:**
  - `delay_ms` — pre-response delay in milliseconds (0 disables).
    Composes with any response kind.
  - `response.kind` — one of `passthrough`, `offline`, `error`,
    `http_status`, `truncate`.
  - `response.{errorType,detail,path,http_status}` — knobs for the
    chosen kind.
  - `operations` (CSV) — only fire for these operation names; blank =
    all `/graphql` requests.
  - `count` — fire N times then auto-deactivate; blank = forever.

So `delay_ms: 5000` + `kind: error` waits 5s and then returns a typed
error — the delay and the response compose independently.

### Response kinds

| kind | effect |
| --- | --- |
| `passthrough` | forward upstream unchanged (CORS overridden) |
| `offline` | kill the connection — client sees `NetworkError` |
| `error` | typed GraphQL error body (`errorType` / `detail` / `path`) |
| `http_status` | bare HTTP status, no body — exercises the transport-failure fallback |
| `truncate` | forward upstream, then cut the body in half |

## Quick presets

The control UI has one-click presets for the common scenarios (off,
active passthrough, offline, each typed error, HTTP 500, truncate,
`Slow` = 5s delay then upstream, `Slow + Forbidden`, and "fail next 3
then auto-off"), plus a custom-rule form.

## Programmatic control

The UI is a thin wrapper over `POST /__mock/control`. The patch is
shallow-merged into the current rule; the `response` sub-object is
merged, not replaced, so a partial patch keeps the other response knobs:

```sh
# Forbidden on the items query
curl -X POST localhost:8000/__mock/control \
  -H 'Content-Type: application/json' \
  -d '{"active":true,"operations":["items"],"response":{"kind":"error","errorType":"Forbidden","path":["items"]}}'

# 5s delay then a typed error (composition)
curl -X POST localhost:8000/__mock/control \
  -H 'Content-Type: application/json' \
  -d '{"active":true,"delay_ms":5000,"response":{"kind":"error","errorType":"Internal error"}}'

# Reset to transparent
curl -X POST localhost:8000/__mock/control \
  -H 'Content-Type: application/json' -d '{"active":false}'

# Read current rule
curl localhost:8000/__mock/control
```

## Debugging

mitmproxy logs to stderr (`[MITM] ...`). Check it if no faults fire (is
the operation name matched?) or for CORS issues (is the `Origin` being
echoed?).

## Not implemented yet: slow-trickle streaming

There is no `slow_stream` / slow-trickle mode. A previous attempt tried
to trickle the upstream body chunk-by-chunk via mitmproxy's
`flow.response.stream`, but it returned an empty body and hung, and was
removed rather than shipped broken.

A future implementation needs to confirm the `Response.stream` callable
signature in the installed mitmproxy version — single-chunk
`fn(bytes) -> bytes` vs iterator `fn(chunks) -> Iterator[bytes]` (read
`mitmproxy/http.py`). Note mitmproxy ships its own bundled Python, so
`import mitmproxy` from a plain venv won't necessarily match the
runtime — either pip-install the same version into a venv to inspect, or
read the source. For a plain fixed delay (not a trickle), `delay_ms` /
the `Slow` preset already covers it.

## Scope

A manual-test helper, not a production artifact. No auth on the control
plane, and the control plane shares the data-plane port — only bind it
to localhost.

For mid-flight intermittent failures with random distribution, jitter,
or bandwidth caps, reach for [mitmproxy](https://mitmproxy.org/)
directly or [Toxiproxy](https://github.com/Shopify/toxiproxy).
