# WIP — picking this back up

Work in progress on `graphql-error-injection-proxy/`. Committed mid-flight
so it's easy to resume.

## What's been done

- Split into `node/` and `python/` subdirectories with a top-level README
  comparing the two implementations.
- Extracted the control-UI HTML out of both `server.js` and
  `fault_injection_proxy.py` into sibling `control.html` files loaded
  from disk at startup. Both verified booting + serving the UI.
- **Python only**: rewrote `fault_injection_proxy.py` against a new
  two-stage rule schema (see below). Deleted the dead helper functions
  (`respond_typed_error`, `respond_http_status`, `respond_truncated`,
  `respond_offline`). Moved CORS-preflight handling above the
  `/graphql` branch so OPTIONS preflights no longer fall into the
  fault-injection path. Switched bare `except:` to a targeted catch.
  Rewrote `control.html` to match the new schema with conditional
  per-kind config sections.

## The new (Python) rule schema

Two stages, picked in conversation:

- **Stage 1 — `active`**: master switch. When `false` the proxy is
  byte-for-byte transparent; nothing else in the rule has any effect.
- **Stage 2 — faults compose** when active:
  - `delay_ms`: pre-response delay in ms (0 disables). Composes with
    any `response.kind`.
  - `response.kind`: one of `passthrough | offline | error |
    http_status | truncate | slow_stream`.
  - `response.{errorType,detail,path,http_status,chunk_delay}`:
    knobs specific to the chosen kind.
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

## Where I got stuck

`slow_stream` — the rewrite tries to do **actual** chunked trickling
via `flow.response.stream = trickle` (a generator). With the test
upstream, curl gets HTTP 200, 0 bytes, and times out at 15s. The old
code just did one `time.sleep` then sent the whole body — it was a
single delay misadvertised as a "trickle." I committed to making it a
real trickle and that's what's broken.

Open question I was about to research: the mitmproxy `Response.stream`
attribute signature in 12.2.3. Two patterns exist in the wild —
single-chunk-in, single-chunk-out (`fn(bytes) -> bytes`) vs
iterator-in, iterator-out (`fn(chunks) -> Iterator[bytes]`). I assumed
the latter. Could not check at the time because mitmproxy ships with
its own bundled Python (it's a "binary" build, not pip-installed).

**Next step:** install mitmproxy via pip into a venv so you can `import
mitmproxy` and inspect the actual API, or read the source at
https://github.com/mitmproxy/mitmproxy/blob/main/mitmproxy/http.py and
search for `stream`.

Fallback if real trickling is too painful: revert `slow_stream` to a
single-sleep model and **rename** the mode + update docs so the name
matches what it does (e.g. `slow_response` instead of `slow_stream`).
The user explicitly accepted "honest docs" as the alternative.

## Still outstanding from the original code review

Node version (untouched after the HTML extraction):

1. **Slow preset is a no-op bug** — same root cause as the Python one.
   `mode:passthrough + delay_ms:5000` but `ruleAppliesTo` returns false
   for passthrough. The user wanted Node to get the same redesign in a
   follow-up pass.
2. Dedupe the three near-identical upstream-forward blocks in
   `handleGraphql` (passthrough at ~L210, truncate at ~L250,
   `forwardToUpstream` at ~L167).
3. Bare catch in truncate mode silently destroys the socket — add a
   `console.error`.
4. `respondHttpStatus` writes a 26-byte body despite the "no body"
   comment. Drop the body to match.
5. Stop logging `errorType` for non-error modes.

Python — still TODO after slow_stream is sorted:

6. Defensive `elif` between truncate/slow_stream metadata checks (less
   relevant after the rewrite, but worth a glance).
7. Match Node's response shape: omit `extensions: {}` when detail is
   empty (Python currently emits an empty object; Node omits the key).
   Done implicitly in the rewrite — verify.

Cross-cutting (deferred):

8. The two implementations duplicate the preset list, control HTML, and
   rule shape. After both are on the new schema they should still drift
   apart over time unless we factor presets into a shared JSON file or
   accept the divergence in writing.

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
    ├── README.md                      (still describes OLD schema — needs rewrite)
    ├── control.html                   (new schema)
    └── fault_injection_proxy.py       (new schema, slow_stream broken)
```

`python/README.md` is now out of date — it documents the old
`mode`-based schema and preset list. Either fix it as part of resuming
the slow_stream work, or do it as its own pass once the schema settles.
