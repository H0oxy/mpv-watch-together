# Test helper: serves files from one folder over HTTP with Range support, throttled to the bytes per
# second written in a rate file (0 or missing = unlimited). Lets tests make a guest really buffer.
# Usage: python slow_server.py <folder> <port> <rate-file>
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

root, port, rate_file = sys.argv[1], int(sys.argv[2]), sys.argv[3]


def rate():
    try:
        with open(rate_file) as f:
            return int(f.read().strip() or 0)
    except (OSError, ValueError):
        return 0


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_HEAD(self):
        self.serve(body=False)

    def do_GET(self):
        self.serve(body=True)

    def serve(self, body):
        path = os.path.join(root, os.path.basename(self.path.split("?")[0]))
        if not os.path.isfile(path):
            self.send_error(404)
            return
        size = os.path.getsize(path)
        start, end = 0, size - 1
        rng = self.headers.get("Range", "")
        if rng.startswith("bytes="):
            a, _, b = rng[6:].partition("-")
            start, end = int(a or 0), int(b) if b else size - 1
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        else:
            self.send_response(200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Content-Type", "video/x-matroska")
        self.end_headers()
        if not body:
            return
        with open(path, "rb") as f:
            f.seek(start)
            left = end - start + 1
            while left > 0:
                chunk = f.read(min(8192, left))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                    return
                left -= len(chunk)
                r = rate()
                if r > 0:
                    time.sleep(len(chunk) / r)


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
