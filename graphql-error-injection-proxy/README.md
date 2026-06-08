# GraphQL fault-injection proxy

Two implementations of the same idea: a reverse proxy that sits between
the client and a real GraphQL server and lets you swap individual
operations for typed GraphQL errors (`Unauthenticated`, `Forbidden`,
`Bad user input`, `Internal error`) or simulate transport failures
(offline, HTTP 500 no body, truncated body, slow trickle). Both expose
a small web UI at `/__mock` with one-click presets plus a custom-rule
form, and a `POST /__mock/control` JSON API.

Originally built for manual testing of typed GraphQL errors + the
connection-lost banner in omSupply
([PR #11444](https://github.com/msupply-foundation/open-msupply/pull/11444)).

## Which one should I use?

Pick the [Node version](./node/) unless you need slow-trickle streaming.

| | [node/](./node/) | [python/](./python/) |
| --- | --- | --- |
| Runtime | Node 18+ | Python + [mitmproxy](https://mitmproxy.org/) (`brew install mitmproxy`) |
| Install step | none | `brew install mitmproxy` |
| Typed GraphQL errors | yes | yes |
| Offline / hard-close | yes | yes |
| HTTP status (no body) | yes | yes |
| Truncated body | yes | yes |
| Fixed delay | yes | yes |
| **Slow-trickle streaming** | no | yes |
| Per-operation matching | yes | yes |
| `count: N` then revert | yes | yes |

Both listen on `:8000` and forward to `http://localhost:8001` by
default; both serve the control UI at <http://localhost:8000/__mock>.
Settings and presets are kept in sync between the two — switching
implementations should not change behaviour beyond the
`slow_stream` mode that only the Python version supports.

See each subdirectory's README for setup details.

## Scope (both)

Manual-test helpers, not production artifacts. No auth on the control
plane, and the control plane shares the data-plane port — only bind
them to localhost.

For things neither can do — mid-flight intermittent failures with
random distribution, jitter, bandwidth caps — reach for
[mitmproxy](https://mitmproxy.org/) directly or
[Toxiproxy](https://github.com/Shopify/toxiproxy).
