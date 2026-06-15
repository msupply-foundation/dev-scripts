# fault-proxy

A zero-dependency reverse proxy that sits between the web client and the
open-mSupply server so you can inject the error/connectivity states that are
otherwise hard to reproduce by hand. Built to test **PR #11444** (typed GraphQL
errors, connection banner, cookie validation) and the **#11885** long-delay
work.

## Run it

```bash
# 1. start the real server as usual (listens on :8000)
cd server && cargo run

# 2. start the proxy (listens on :8001, forwards to :8000)
#    (run from your dev-scripts checkout)
node fault-proxy/fault-proxy.js

# 3. start the client pointed at the proxy instead of the server
cd client && yarn start --env API_HOST=http://localhost:8001
```

Open the **control panel** at <http://localhost:8001/__proxy> and click a mode
to flip it live while the app is running. Everything also works over curl:

```bash
curl 'http://localhost:8001/__proxy/mode?mode=offline'        # turn fault on
curl 'http://localhost:8001/__proxy/mode?mode=forbidden&count=1'  # one-shot
curl 'http://localhost:8001/__proxy/mode?mode=pass'           # back to healthy
curl  http://localhost:8001/__proxy/state                     # inspect state
```

Override ports with env vars: `PROXY_PORT=8001 UPSTREAM=http://localhost:8000`.

## Modes

| mode | what it does on the wire | client result (per GqlContext.tsx) |
|---|---|---|
| `pass` | forward unchanged | healthy |
| `offline` | destroy the socket, no HTTP response | `NetworkError` → ConnectionLostBanner / ConnectionLostPage |
| `http500` | HTTP 500 with an empty body | `NetworkError` (transport-failure HTTP branch) |
| `internal` | HTTP 200 `{errors:[{message:"Internal error"}]}` | `InternalServerError` → toast + Bugsnag |
| `unauthenticated` | HTTP 200 `{errors:[{message:"Unauthenticated"}]}` | `UnauthenticatedError` → re-login modal |
| `forbidden` | HTTP 200 `{errors:[{message:"Forbidden", path}]}` | `PermissionDeniedError` → permission modal |
| `badinput` | HTTP 200 `{errors:[{message:"Bad user input"}]}` | `BadUserInputError` → toast |
| `partial` | forward real data, graft an `errors[]` onto it | typed error thrown despite present data |
| `delay` | forward, but hold the response by `delayMs` | slow / "startup in progress" path |

**Knobs** (set on the panel or as query params):

- `scope` — `graphql` (default, only `/graphql` is faulted) or `all` (every request).
- `count` — fault the next N GraphQL POSTs, then auto-revert to `pass`. Great for
  testing banner auto-dismiss ("next query succeeds") and re-arm. `0` = until
  changed. **`offline` ignores `count`** (the preflight is dropped, so the POST
  never arrives) — toggle it off manually.
- `delayMs` — milliseconds for `delay` mode.
- `detail` — the `extensions.details` string on injected GraphQL errors.

## Mapping to the PR #11444 test checklist

| Checklist item | Do this |
|---|---|
| Stop the server while on a list page → banner appears | mode `offline` |
| Restart server → next query → banner auto-dismisses | `offline` then `pass` (or `offline&count=…` won't apply — just switch to `pass`) |
| Close banner, trigger a *new* failing action → banner re-opens | `pass`, navigate, then `offline` again on a new page action |
| Trigger a 500 → toast + Bugsnag | mode `internal` |
| Trigger permission-denied on a list page | mode `forbidden` |
| Reload with server unreachable → ConnectionLostPage | mode `offline`, then reload the app |
| Click "Try again" after restart → app resumes | with ConnectionLostPage showing, set `pass`, click Try again |
| HTTP error with no body (failure matrix) | mode `http500` |
| GraphQL errors + partial data (failure matrix) | mode `partial` |
| Stale cookie / re-init cookie validation | use `unauthenticated`, or re-init the DB and cold-load |

## Notes

- Auth survives the proxy: the client attaches a `Bearer` token header, which is
  forwarded as-is.
- Injected responses carry CORS headers (echoes `Origin` + `Allow-Credentials`)
  so the browser can actually read the injected body — required because the
  client uses `credentials: 'include'`.
- If the real upstream is genuinely down while in `pass` mode, the proxy drops
  the socket too, so the client still sees an honest transport failure.
