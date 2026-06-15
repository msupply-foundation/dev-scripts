# GraphQL fault-injection proxy

A tiny Node proxy used for manual testing of the typed GraphQL error /
connection banner work in [PR #11444](https://github.com/msupply-foundation/open-msupply/pull/11444).

It sits between the client and the real omSupply server and proxies
everything normally — but lets you selectively swap individual
operations for typed GraphQL errors (`Unauthenticated`, `Forbidden`,
`Bad user input`, `Internal error`) or simulate transport failures
(offline, HTTP 500 with no body, truncated body) via a
small web UI.

No npm dependencies. Node 18+.

Works alongside `yarn start` — the proxy sends credentials-aware CORS
headers (echoes `Origin`, sets `Access-Control-Allow-Credentials: true`)
so the webpack dev server on a different port can hit it directly with
cookies. No rebuild needed.

## Setup

The client dev build calls the server at `http://localhost:8000` by
default. Move the real Rust server out of the way so the proxy can take
that port:

1. **Run the real server on a different port**, e.g. 8001:

   ```sh
   cd server
   APP__SERVER__PORT=8001 cargo run
   ```

2. **Run the proxy on 8000**:

   ```sh
   cd scripts/graphql-error-injection-proxy/node
   node server.js
   ```

   Defaults: listens on `:8000`, forwards to `http://localhost:8001`.
   Override with env vars:

   ```sh
   MOCK_PORT=8000 UPSTREAM=http://localhost:8001 node server.js
   ```

3. **Run the client dev build as normal** — it'll hit the proxy.

4. **Open the control UI**: <http://localhost:8000/__mock>

## Usage

The control UI exposes one-click presets for the common scenarios in
the test plan, plus a custom-rule form for everything else.

### Quick presets

| Preset                       | Scenario it drives                                                                      |
| ---------------------------- | --------------------------------------------------------------------------------------- |
| Pass through                 | normal operation; all requests forwarded                                                |
| Offline (all)                | hard-close every `/graphql` request — drives `NetworkError`, banner, ConnectionLostPage |
| Unauthenticated              | typed `UnauthenticatedError` — re-auth modal, cookie validation                         |
| Forbidden                    | typed `PermissionDeniedError` with `path: ['items']` — page-level modal                 |
| Forbidden (empty path)       | edge case from the Copilot review (`isSilentPermissionDenied` defensive check)          |
| Forbidden on silent path     | `path: ['reports']` — should be silent (no modal/toast)                                 |
| Bad user input               | toast only                                                                              |
| Internal error               | short toast, Bugsnag event                                                              |
| Internal error (long detail) | `errorWithDetail` expandable toast (detail >100 chars)                                  |
| HTTP 500 no body             | exercises the `isTransportFailure` fallback path → `NetworkError`                       |
| Truncated body               | mid-response disconnect → `NetworkError`                                                |
| Slow (5s delay)              | exercises retry/backoff timing                                                          |
| Fail next 3 then recover     | retry-on-`NetworkError` predicate; banner auto-dismiss on success                       |

### Custom rule

For finer control, set `operations: items,migrationStatus` (CSV of
GraphQL operation names) so the rule only fires for those operations
and everything else proxies normally. Leave blank to apply to all
`/graphql` requests.

`count: 3` makes the rule self-revert to passthrough after 3
invocations — useful for retry behaviour tests.

`path` (CSV) is the GraphQL `path` field on the error — relevant for
`Forbidden` errors since the silent-permission allowlist
([SILENT_PERMISSION_DENIED_PATHS](../../client/packages/host/src/QueryErrorHandler.tsx))
checks every segment. Defaults to `[operationName]` if blank.

### Programmatic control

The UI is a thin wrapper over `POST /__mock/control`:

```sh
# Drop all graphql requests
curl -X POST localhost:8000/__mock/control \
  -H 'Content-Type: application/json' \
  -d '{"mode":"offline","operations":[],"count":null}'

# Fail just the migrationStatus query once with a NetworkError
curl -X POST localhost:8000/__mock/control \
  -H 'Content-Type: application/json' \
  -d '{"mode":"offline","operations":["migrationStatus"],"count":1}'

# Force a typed Forbidden on the items query
curl -X POST localhost:8000/__mock/control \
  -H 'Content-Type: application/json' \
  -d '{"mode":"error","errorType":"Forbidden","operations":["items"],"path":["items"]}'

# Reset
curl -X POST localhost:8000/__mock/control \
  -H 'Content-Type: application/json' \
  -d '{"mode":"passthrough","operations":[],"count":null}'

# Read current rule
curl localhost:8000/__mock/control
```

## Scope

This is a manual-test helper, not a production artifact. It does no
auth checks of its own and exposes a control plane on the same port as
the data plane — only bind it to localhost.

For test scenarios that don't need any GraphQL response (e.g. login
mutation returning `Internal error`), use the proxy as well — log out
first, then trigger the mocked failure on `authToken` from the login
form.

For things this proxy can't do — mid-flight intermittent failures with
random distribution, jitter, bandwidth caps — reach for
[mitmproxy](https://mitmproxy.org/) or
[Toxiproxy](https://github.com/Shopify/toxiproxy).
