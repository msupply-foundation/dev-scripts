#!/usr/bin/env python3
"""
Fault-injection proxy for omSupply manual testing.

Two-stage rule model:
  Stage 1 — `active`: master switch. When false, the proxy is byte-for-byte
            transparent: nothing else in the rule has any effect.
  Stage 2 — when active, these compose:
            - `delay_ms`: pre-response delay (ms). 0 disables.
            - `response.kind`: one of passthrough | offline | error |
              http_status | truncate.
            - `response.{errorType,detail,path,http_status}`:
              knobs for the chosen kind.
            - `operations` / `count`: filters.

  So `delay_ms: 5000` + `response.kind: error` = wait 5s, then return a
  typed GraphQL error. `delay_ms: 0` + `response.kind: passthrough` while
  active=true is a no-op forward (useful for sanity-checking the proxy).

Setup:
  1. Start the real server on port 8001.
  2. Run: mitmdump -s ./fault_injection_proxy.py --mode reverse:http://localhost:8001 --listen-port 8000
  3. Point client API at http://localhost:8000.
  4. Open control UI at http://localhost:8000/__mock.
"""

import json
import sys
import time
from pathlib import Path
from mitmproxy import http

CONTROL_HTML = (Path(__file__).parent / "control.html").read_text()

DEFAULT_RESPONSE = {
    "kind": "passthrough",
    "errorType": "Internal error",
    "detail": "",
    "path": [],
    "http_status": 500,
}

RULE = {
    "active": False,
    "operations": [],
    "count": None,
    "delay_ms": 0,
    "response": dict(DEFAULT_RESPONSE),
}


def log(msg):
    print(f"[MITM] {msg}", file=sys.stderr)


def cors_headers(flow):
    """Echo Origin so cookies work cross-origin during `yarn start`."""
    origin = flow.request.headers.get("origin", "")
    req_headers = flow.request.headers.get("access-control-request-headers", "")
    req_method = flow.request.headers.get("access-control-request-method", "")
    headers = {
        "Access-Control-Allow-Methods":
            req_method or "GET, POST, PUT, PATCH, DELETE, OPTIONS",
        "Access-Control-Allow-Headers":
            req_headers or "Content-Type, Authorization, X-Requested-With",
        "Access-Control-Expose-Headers": "*",
        "Access-Control-Max-Age": "600",
        "Vary": "Origin",
    }
    if origin:
        headers["Access-Control-Allow-Origin"] = origin
        headers["Access-Control-Allow-Credentials"] = "true"
    else:
        headers["Access-Control-Allow-Origin"] = "*"
    return headers


def rule_applies_to(operation_name):
    if not RULE["active"]:
        return False
    if not RULE["operations"]:
        return True
    return operation_name in RULE["operations"]


def consume_rule():
    """Decrement count, deactivate when it hits zero."""
    if RULE["count"] is None:
        return
    RULE["count"] -= 1
    if RULE["count"] <= 0:
        RULE["active"] = False
        RULE["count"] = None


def get_operation_name(flow):
    try:
        return json.loads(flow.request.text).get("operationName", "") or ""
    except (ValueError, TypeError, AttributeError):
        return ""


def merge_rule(patch):
    """Shallow-merge patch into RULE; the `response` sub-object is merged,
    not replaced, so a partial patch like {response: {kind: 'offline'}}
    keeps the other response knobs at their previous values."""
    if "response" in patch:
        new_response = dict(RULE["response"])
        new_response.update(patch["response"])
        RULE["response"] = new_response
    for k, v in patch.items():
        if k == "response":
            continue
        RULE[k] = v


def build_typed_error_body(operation_name):
    response = RULE["response"]
    path = response.get("path") or ([operation_name] if operation_name else [])
    err = {"message": response["errorType"], "path": path}
    if response.get("detail"):
        err["extensions"] = {"details": response["detail"]}
    return {"errors": [err], "data": None}


class FaultInjectionAddon:
    def request(self, flow):
        path = flow.request.path

        if path in ("/__mock", "/__mock/"):
            flow.response = http.Response.make(
                200, CONTROL_HTML,
                {"Content-Type": "text/html", **cors_headers(flow)},
            )
            return

        if path == "/__mock/control":
            self._handle_control(flow)
            return

        # OPTIONS must be handled BEFORE the /graphql branch — preflights
        # to /graphql would otherwise fall into the fault path and the
        # browser would reject the actual request.
        if flow.request.method == "OPTIONS":
            flow.response = http.Response.make(204, b"", cors_headers(flow))
            return

        if path.startswith("/graphql"):
            self._handle_graphql_request(flow)

    def _handle_control(self, flow):
        if flow.request.method == "GET":
            flow.response = http.Response.make(
                200, json.dumps(RULE),
                {"Content-Type": "application/json", **cors_headers(flow)},
            )
            return
        if flow.request.method == "POST":
            try:
                patch = json.loads(flow.request.text)
                merge_rule(patch)
                log(f"Rule updated: {RULE}")
                flow.response = http.Response.make(
                    200, json.dumps(RULE),
                    {"Content-Type": "application/json", **cors_headers(flow)},
                )
            except Exception as e:
                flow.response = http.Response.make(
                    400, json.dumps({"error": str(e)}),
                    {"Content-Type": "application/json", **cors_headers(flow)},
                )
            return
        flow.response = http.Response.make(
            405, json.dumps({"error": "method not allowed"}),
            {"Content-Type": "application/json", **cors_headers(flow)},
        )

    def _handle_graphql_request(self, flow):
        operation_name = get_operation_name(flow)
        if not rule_applies_to(operation_name):
            return

        delay = RULE["delay_ms"]
        if delay > 0:
            time.sleep(delay / 1000.0)

        kind = RULE["response"]["kind"]
        log(f"{kind} (delay={delay}ms) for operation="
            f"{operation_name or '<anonymous>'}")

        if kind == "offline":
            flow.kill()
        elif kind == "error":
            flow.response = http.Response.make(
                200, json.dumps(build_typed_error_body(operation_name)),
                {"Content-Type": "application/json", **cors_headers(flow)},
            )
        elif kind == "http_status":
            flow.response = http.Response.make(
                RULE["response"]["http_status"], b"",
                {"Content-Type": "text/plain", **cors_headers(flow)},
            )
        elif kind in ("passthrough", "truncate"):
            # Need upstream's response — tag for responseheaders/response hooks
            flow.metadata["fault_kind"] = kind

        consume_rule()

    def responseheaders(self, flow):
        """Runs before the body streams. Overrides CORS on any
        upstream-forwarded /graphql response (passthrough included) so the
        dev-server origin works. truncate is body-shaped, so it's handled in
        the `response` hook once the full body is buffered."""
        kind = flow.metadata.get("fault_kind")
        if kind is None:
            return

        for k, v in cors_headers(flow).items():
            flow.response.headers[k] = v

    def response(self, flow):
        if flow.metadata.get("fault_kind") != "truncate":
            return
        body = flow.response.content
        if body:
            flow.response.content = body[:len(body) // 2]
            log("Truncated response")


addons = [FaultInjectionAddon()]

log("Fault-injection proxy loaded")
log("Control UI: http://localhost:8000/__mock")
log("Control API: http://localhost:8000/__mock/control")
