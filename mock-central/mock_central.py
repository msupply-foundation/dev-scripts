"""
Mock mSupply central server for testing sync integration without a real central.

Responds to all /sync/v5/* endpoints with minimal valid responses so that
manualSync can reach the integration step and process sync_buffer records.
Accepts any username/password — auth is not validated.

See README.md for usage and how to find --site-id / --uuid.
"""

import argparse
import json
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs


class MockCentralHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        if path == "/sync/v5/site":
            self.json_response(
                {
                    "id": self.server.uuid,
                    "siteId": self.server.site_id,
                    "code": "mock",
                    "name": "Open mSupply Central Server",
                    "initialisationStatus": "completed",
                    "isOmSupplyCentralServer": True,
                    "omSupplyCentralServerUrl": "",
                    "mSupplyCentralSiteId": 1,
                }
            )

        elif path == "/sync/v5/central_records":
            # Return empty batch — no new central records to pull
            params = parse_qs(parsed.query)
            cursor = int(params.get("cursor", ["0"])[0])
            self.json_response({"maxCursor": cursor, "data": []})

        elif path == "/sync/v5/queued_records":
            # Return empty batch — no new remote records to pull
            self.json_response({"queueLength": 0, "data": []})

        elif path == "/sync/v5/site_status":
            self.json_response(
                {"code": "idle", "message": "idle", "data": None}
            )

        else:
            self.send_error(404, f"Unknown GET path: {path}")

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        content_length = int(self.headers.get("Content-Length", 0))

        if path == "/sync/v5/queued_records":
            self.rfile.read(content_length)  # consume body
            # Accept pushed records
            self.json_response({"integrationStarted": True})

        elif path == "/sync/v5/acknowledged_records":
            self.rfile.read(content_length)  # consume body
            self.send_response(204)
            self.end_headers()

        elif path == "/sync/v5/initialise":
            self.rfile.read(content_length)  # consume body
            self.json_response({"queueLength": 0, "data": []})

        elif path == "/api/v4/login":
            # Force OMS to authenticate against its LOCAL user_account table instead
            # of trusting central. Returning a non-200/401/403 response makes the
            # server's LoginApiV4 treat central as unavailable for login
            # (ConnectionError), which falls through to local verify_password.
            # See server/service/src/login.rs do_login() + apis/login_v4.rs.
            self.rfile.read(content_length)  # consume body
            self.send_error(404, "Login handled locally")

        else:
            self.rfile.read(content_length)  # consume body
            self.send_error(404, f"Unknown POST path: {path}")

    def json_response(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        print(f"[mock-central] {self.command} {self.path} -> {args[1] if len(args) > 1 else args[0]}")


def main():
    parser = argparse.ArgumentParser(description="Mock mSupply central server for sync testing")
    parser.add_argument("--port", type=int, default=8080, help="Port to listen on (default: 8080)")
    parser.add_argument(
        "--site-id",
        type=int,
        required=True,
        help="siteId to report on /sync/v5/site — key_value_store SETTINGS_SYNC_SITE_ID",
    )
    parser.add_argument(
        "--uuid",
        required=True,
        help="id (uuid) to report on /sync/v5/site — key_value_store SETTINGS_SYNC_SITE_UUID",
    )
    args = parser.parse_args()

    server = HTTPServer(("127.0.0.1", args.port), MockCentralHandler)
    server.site_id = args.site_id
    server.uuid = args.uuid
    print(f"Mock central server listening on http://127.0.0.1:{args.port} (siteId={args.site_id})")
    print("Configure local.yaml with (username/password can be anything):")
    print(f'  sync:')
    print(f'    url: "http://localhost:{args.port}"')
    print(f'    username: "anything"')
    print(f'    password_sha256: "anything"')
    server.serve_forever()


if __name__ == "__main__":
    main()
