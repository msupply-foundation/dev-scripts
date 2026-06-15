# WIP — picking this back up

Work in progress on `graphql-error-injection-proxy/`. Committed mid-flight
so it's easy to resume.

## What's been done

- Split into `node/` and `python/` subdirectories with a top-level README
  comparing the two implementations.
- Extracted the control-UI HTML out of both `server.js` and
  `fault_injection_proxy.py` into sibling `control.html` files loaded
  from disk at startup.
- **Python:** rewrote `fault_injection_proxy.py` against a new two-stage
  rule schema (see below). Deleted dead helper functions, moved
  CORS-preflight handling above the `/graphql` branch (OPTIONS preflights
  no longer fall into the fault path), and narrowed a bare `except:`.
  Rewrote `control.html` to match.
- **Python:** removed the `slow_stream` (slow-trickle) mode entirely —
  code, UI, and docs. Real chunked trickling via mitmproxy's
  `flow.response.stream` was unreliable (empty body + hang), so rather
  than ship it broken it's deferred to a future dev. `python/README.md`
  documents what a future implementation needs.
- **Python:** rewrote `python/README.md` for the new two-stage schema
  (it previously documented the old mode-based schema).

## The new (Python) rule schema

Two stages:

- **Stage 1 — `active`**: master switch. When `false` the proxy is
  byte-for-byte transparent; nothing else in the rule has any effect.
- **Stage 2 — faults compose** when active:
  - `delay_ms`: pre-response delay in ms (0 disables). Composes with
    any `response.kind`.
  - `response.kind`: one of `passthrough | offline | error |
    http_status | truncate`.
  - `response.{errorType,detail,path,http_status}`: knobs specific to
    the chosen kind.
  - `operations` / `count`: filters.

So `delay_ms: 5000 + response.kind: error` = wait 5s then return a
typed GraphQL error — the combo the old `slow` "preset" couldn't
actually express because it was `passthrough + delay_ms` and the delay
path was gated behind `rule_applies_to`, which returned `false` for
passthrough.

Smoke-tested and passing:
- `active=false` → transparent passthrough to real upstream
- Forbidden preset returns typed error
- `delay_ms=2000 + kind=error` actually takes ~2s and returns the error
  (composition works)
- `count=2` fires twice then auto-deactivates

## slow_stream — removed, deferred to a future dev

Decision (June 2026): removed for now instead of fixing. The rewrite
tried to do **actual** chunked trickling via `flow.response.stream =
trickle` (a generator), but with the test upstream curl got HTTP 200,
0 bytes, and a 15s timeout. The old code just did one `time.sleep` then
sent the whole body — a single delay misadvertised as a "trickle."

For a future implementation: confirm the mitmproxy `Response.stream`
callable signature in the installed version — single-chunk
`fn(bytes) -> bytes` vs iterator `fn(chunks) -> Iterator[bytes]` (read
`mitmproxy/http.py`). Note mitmproxy ships its own bundled Python, so
`import mitmproxy` from a plain venv won't necessarily match the
runtime; either pip-install the same version into a venv to inspect, or
read the source. For a plain fixed delay (not a trickle), `delay_ms` /
the `Slow` preset already covers it.

## Still outstanding

Node version (still on the OLD `mode`-based schema, untouched apart from
the HTML extraction and doc-accuracy fixes):

1. **Slow preset is a no-op bug** — `mode:passthrough + delay_ms:5000`
   but `ruleAppliesTo` returns false for passthrough. Wants the same
   two-stage redesign the Python version got.
2. Dedupe the three near-identical upstream-forward blocks in
   `handleGraphql` (passthrough, truncate, and `forwardToUpstream`).
3. Bare catch in truncate mode silently destroys the socket — add a
   `console.error`.
4. `respondHttpStatus` writes a 26-byte body despite the "no body"
   comment. Drop the body to match.
5. Stop logging `errorType` for non-error modes.

Python — minor:

6. Verify the response shape omits `extensions` when detail is empty
   (Node omits the key; Python should match — looks done in the rewrite).

Cross-cutting (deferred):

7. The two implementations duplicate the preset list, control HTML, and
   rule shape, and have now diverged (Python = two-stage, Node = mode).
   Once Node is on the new schema, consider factoring presets into a
   shared JSON file or accepting the divergence in writing.

## Files in this directory

```
graphql-error-injection-proxy/
├── README.md                          (overview + comparison)
├── WIP.md                             (this file)
├── node/
│   ├── README.md
│   ├── control.html
│   └── server.js                      (old schema, untouched)
└── python/
    ├── README.md                      (new schema, current)
    ├── control.html                   (new schema, no slow_stream)
    └── fault_injection_proxy.py       (new schema, no slow_stream)
```
