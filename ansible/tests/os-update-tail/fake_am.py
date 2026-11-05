"""Fake Alertmanager v2 for test-os-update-tail-silence.sh (stdlib only).

The first path segment picks the scenario: GET /<scenario>/api/v2/silences
returns SILENCES[<scenario>]; every POST/DELETE is appended to the log as JSONL.
Prints the bound port on stdout, then serves until killed.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = sys.argv[1]
ACTIVE = {"state": "active"}
SILENCES = {
    "run": [],
    # Another host in the same contour finished a moment ago: its TAIL is up.
    "tail": [{"id": "t1", "status": ACTIVE, "createdBy": "os-update-tail",
              "comment": "OS update tail issues-maestra#1104 contour=us_test_lw host=us-test-worker01 run=r — workloads returning after the reboot"}],
    # Negative control: another host is mid-drain (a real maintenance silence).
    "drain": [{"id": "d1", "status": ACTIVE, "createdBy": "gha-os-update",
               "comment": "OS update issues-maestra#1104 contour=us_test_lw host=us-test-worker01 run=r"}],
}


class H(BaseHTTPRequestHandler):
    def _log(self, body=None):
        with open(LOG, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path, "body": body}) + "\n")

    def _reply(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._reply(SILENCES[self.path.split("/")[1]])

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self._log(body)
        self._reply({"silenceID": "new-%d" % sum(1 for _ in open(LOG))})

    def do_DELETE(self):
        self._log()
        self._reply({})

    def log_message(self, *a):
        pass


srv = HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
