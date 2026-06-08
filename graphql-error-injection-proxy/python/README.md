# Unified Fault-Injection Proxy

Single mitmproxy script providing **both** typed GraphQL error injection and transport layer faults.

## What is it?

This consolidates two tools into one:

- **Typed GraphQL errors** (Unauthenticated, Forbidden, Bad user input, Internal error)
- **Transport faults** (slow trickle, hard-close, truncated responses, HTTP 500)

Single process, single control interface.

## Installation

### macOS

Install mitmproxy via Homebrew:

```sh
brew install mitmproxy
```

Verify:

```sh
mitmdump --version
```

## Setup

You need **two** processes (down from three!):

1. **Real server** on port 8001

   ```sh
   cd server
   # Start your Rust server (it should bind to 8001 per local.yaml)
   ```

2. **Fault-injection proxy** on port 8000

   ```sh
   cd scripts/graphql-error-injection-proxy/python
   mitmdump -s ./fault_injection_proxy.py --mode reverse:http://localhost:8001 --listen-port 8000
   ```

3. **Client** (webpack dev server, port 3003 or similar)
   ```sh
   cd client
   yarn start
   ```

Then navigate to http://localhost:3003 — it will hit `http://localhost:8000/graphql` (the proxy), which forwards to the real server.

**Control UI:** http://localhost:8000/\_\_mock

## Usage

### Quick Presets

Click any preset button in the UI:

- **Pass through** — no injection (default)
- **Offline** — hard-close socket (NetworkError)
- **Unauthenticated** — typed error
- **Forbidden** — typed error
- **Forbidden (silent path)** — typed error on a path in the silent allowlist
- **Bad user input** — typed error
- **Internal error** — typed error
- **Internal error (long)** — internal error with long detail string
- **HTTP 500 no body** — HTTP 500 with no GraphQL body (triggers NetworkError path)
- **Truncated body** — cut response in half (NetworkError)
- **Slow** — 5-second delay on entire request
- **Slow stream** — trickle response in small chunks (triggers timeout)
- **Fail next 3** — first 3 queries fail, then reset to passthrough

### Custom Rules

Fine-tune with the form:

- **Mode**: passthrough, offline, error, http_status, truncate, slow_stream
- **Error message**: Unauthenticated, Forbidden, Bad user input, Internal error
- **Detail**: optional string for `extensions.details`
- **Path**: comma-separated path list for the error (blank = [operationName])
- **Operations**: comma-separated operation names to match (blank = all)
- **Count**: apply N times then revert to passthrough (blank = forever)
- **Delay ms**: delay entire request by N milliseconds
- **Slow stream delay**: seconds to sleep between chunks
- **HTTP status**: HTTP status code to return

Click **Apply** to activate, **Refresh** to reload current state.

## Modes

### passthrough

No injection — request/response pass through unchanged.

### offline

Hard-close the socket mid-request (no response sent). Client sees `ECONNRESET` → `NetworkError` path.

### error

Return a typed GraphQL error response:

```json
{
  "errors": [
    {
      "message": "Unauthenticated",
      "path": ["operationName"],
      "extensions": { "details": "..." }
    }
  ],
  "data": null
}
```

### http_status

Return an HTTP status code with no GraphQL body (e.g., 500). Triggers `isTransportFailure()` → `NetworkError`.

### truncate

Truncate the response body halfway through. Client sees partial payload → socket closes → `NetworkError`.

### slow_stream

Trickle the response in chunks with delays between them. Slow enough to trigger client timeout (~10s) → `NetworkError` + retry.

Adjust **Slow stream delay** (in seconds) to speed up or slow down:

- 0.1s = 10 chunks/second (realistically slow)
- 0.5s = 2 chunks/second (very slow, obvious timeout)
- 2s = 1 chunk/2 seconds (extremely slow, for demos)

## Debugging

mitmproxy logs to stderr:

```
[MITM] Fault-injection proxy loaded
[MITM] Control UI: http://localhost:8000/__mock
[MITM] Control API: http://localhost:8000/__mock/control
[MITM] error (Unauthenticated) for operation=me
[MITM] Rule updated: {...}
```

Check the log if:

- No errors injected — is the operation name matched?
- CORS issues — are Origin headers being echoed?
- Slow mode not working — restarted mitmproxy after editing?

## Typical Workflow

1. **Start both processes** (server, mitmproxy)
2. **Open UI** at http://localhost:8000/\_\_mock
3. **Click a preset** (e.g., "Unauthenticated")
4. **Trigger a query** in the app (navigate, refresh, sign out & back in)
5. **Observe** UI behavior (banner, retry, error toast)
6. **Check stderr** for debug logs

## Examples

### Test "Forbidden" error banner

1. Click **Forbidden** preset
2. Navigate to a page that loads items
3. See banner/modal with "Forbidden" error

### Test retry after timeout

1. Click **Slow stream** preset
2. Trigger a query
3. Wait ~10s for client timeout
4. See banner + auto-retry
5. Click **Pass through** to let it succeed

### Test intermittent failures

1. Click **Fail next 3** preset
2. Trigger 3 queries → all fail with "Internal error"
3. Queries automatically retry
4. 4th query succeeds
5. Banner auto-dismisses

### Test transport failure path

1. Click **HTTP 500 no body** preset
2. Trigger a query
3. See `NetworkError` (not typed error) because no GraphQL body
4. Banner appears, retry fires

## Combining with Other Tools

You can extend `fault_injection_proxy.py` with custom logic:

```python
def responseheaders(self, flow):
    # Only slow down the 'items' query
    if 'operationName=items' in flow.request.text:
        flow.metadata["slow_stream"] = True
```

See the [mitmproxy scripting docs](https://docs.mitmproxy.org/stable/guide-addons/) for the full API.

## See Also

- [mitmproxy docs](https://docs.mitmproxy.org/) — full reference
- PR #11444 — Typed GraphQL errors, connection banner, cookie validation
