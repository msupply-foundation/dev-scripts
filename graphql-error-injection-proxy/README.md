# GraphQL fault-injection proxy

Two implementations of the same idea: a reverse proxy that sits between
the client and a real GraphQL server and lets you swap individual
operations for typed GraphQL errors (`Unauthenticated`, `Forbidden`,
`Bad user input`, `Internal error`) or simulate transport failures
(offline, HTTP 500 no body, truncated body). Both expose
a small web UI at `/__mock` with one-click presets plus a custom-rule
form, and a `POST /__mock/control` JSON API.

Originally built for manual testing of typed GraphQL errors + the
connection-lost banner in omSupply
([PR #11444](https://github.com/msupply-foundation/open-msupply/pull/11444)).

## Which one should I use?

Pick the [Node version](./node/) — it has no install step. The
[Python version](./python/) is a mitmproxy-based alternative that uses
the newer two-stage rule schema; reach for it if you'd rather work in
mitmproxy.

| | [node/](./node/) | [python/](./python/) |
| --- | --- | --- |
| Runtime | Node 18+ | Python + [mitmproxy](https://mitmproxy.org/) (`brew install mitmproxy`) |
| Install step | none | `brew install mitmproxy` |
| Typed GraphQL errors | yes | yes |
| Offline / hard-close | yes | yes |
| HTTP status (no body) | yes | yes |
| Truncated body | yes | yes |
| Fixed delay | yes | yes |
| Slow-trickle streaming | not yet | not yet |
| Per-operation matching | yes | yes |
| `count: N` then revert | yes | yes |

Both listen on `:8000` and forward to `http://localhost:8001` by
default; both serve the control UI at <http://localhost:8000/__mock>.
The two share the same presets and scenarios, but the Python version
now uses the newer two-stage rule schema (`active` + composable
`delay_ms` / `response.kind`) while the Node version still uses the
original `mode`-based schema — porting Node to the two-stage schema is
pending (see Future work).

See each subdirectory's README for setup details.

## Scope (both)

Manual-test helpers, not production artifacts. No auth on the control
plane, and the control plane shares the data-plane port — only bind
them to localhost.

For things neither can do — mid-flight intermittent failures with
random distribution, jitter, bandwidth caps — reach for
[mitmproxy](https://mitmproxy.org/) directly or
[Toxiproxy](https://github.com/Shopify/toxiproxy).

## Future work

- **Slow-trickle streaming** (real chunked trickle of the upstream
  body) is not implemented in either version. Python had a `slow_stream`
  mode but it was removed — real trickling via mitmproxy's
  `Response.stream` was unreliable; see [`python/README.md`](./python/)
  for what an implementation needs. For a fixed delay (not a trickle),
  use the `delay_ms` knob / `Slow` preset.
- **Port the Node version to the two-stage rule schema** so the two
  implementations match again (and fix the Node `Slow` preset no-op
  along the way).
