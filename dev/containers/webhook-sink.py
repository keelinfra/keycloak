#!/usr/bin/env python3
"""Alert webhook stand-in for the container rig: answers 200 to every POST
and appends the body, one JSON document per line, to the given file."""
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, log_path = int(sys.argv[1]), sys.argv[2]


class Sink(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        with open(log_path, "ab") as f:
            f.write(body.replace(b"\n", b" ") + b"\n")
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", port), Sink).serve_forever()
