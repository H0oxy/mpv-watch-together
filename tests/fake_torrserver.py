"""A stand-in for TorrServer in tests\\torrent.ps1: the API calls torrent.ps1 and mpv make, over local files.

  python fake_torrserver.py <port> <config.json>

config.json: {"torrents": {"<hash>": [["Show/S01E01.mkv", "C:\\path\\ep1.mkv"], ...]},
              "files": {"<.torrent path>": "<hash>"}, "speed_file": "<path holding bytes/s>"}
GET /log returns every link that was added, so a test can see what the plugin handed the engine.
"""
import json
import os
import re
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
CONFIG_FILE = sys.argv[2]


def config():
    """Read again on every call: a test can add a torrent while the plugin keeps asking."""
    with open(CONFIG_FILE, encoding="utf-8") as f:
        return json.load(f)


ADDED = {}      # hash -> True once added
LOG = []
LOCK = threading.Lock()


def speed():
    try:
        with open(config().get("speed_file", ""), encoding="utf-8") as f:
            return int(f.read().strip() or 0)
    except (OSError, ValueError):
        return 0


def status(h, with_files=True):
    files = config()["torrents"][h]
    st = {"hash": h, "download_speed": speed(), "active_peers": 7, "connected_seeders": 3}
    if with_files:
        st["file_stats"] = [{"id": i + 1, "path": p, "length": os.path.getsize(local)}
                            for i, (p, local) in enumerate(files)]
    return st


def hash_of(link):
    m = re.search(r"xt=urn:btih:([0-9a-fA-F]{40})", link)
    if m:
        return m.group(1).lower()
    if re.fullmatch(r"[0-9a-fA-F]{40}", link):
        return link.lower()
    if link.startswith("file:///"):
        path = urllib.parse.unquote(link[len("file:///"):])
        try:
            with open(path, encoding="utf-8") as f:
                return f.read().strip().lower()
        except OSError:
            return None
    return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if self.path == "/settings":
            return self.reply(200, {"cacheSize": 64 << 20, "useDisk": False} if req.get("action") == "get" else {})
        if self.path == "/torrents":
            action = req.get("action")
            if action == "add":
                link = req.get("link", "")
                with LOCK:
                    LOG.append(link)
                h = hash_of(link)
                if h not in config()["torrents"]:
                    return self.reply(500, {"error": "unknown torrent"})
                ADDED[h] = True
                return self.reply(200, status(h, with_files=False))  # like the real one: no metadata yet
            if action == "get":
                h = req.get("hash", "")
                if not ADDED.get(h):
                    return self.reply(404, b"", "text/plain")
                return self.reply(200, status(h))
        self.reply(404, b"", "text/plain")

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        if url.path == "/echo":
            return self.reply(200, b"fake", "text/plain")
        if url.path == "/log":
            with LOCK:
                return self.reply(200, list(LOG))
        q = urllib.parse.parse_qs(url.query)
        if url.path == "/stream" and "preload" in url.query.split("&"):
            with LOCK:
                LOG.append("preload %s %s" % (q.get("link", [""])[0].lower(), q.get("index", [""])[0]))
            return self.reply(200, b"", "text/plain")
        if not url.path.startswith("/stream/"):
            return self.reply(404, b"", "text/plain")
        h, index = q.get("link", [""])[0].lower(), int(q.get("index", ["0"])[0])
        files = config()["torrents"].get(h)
        if not files or not ADDED.get(h) or not 1 <= index <= len(files):
            return self.reply(404, b"", "text/plain")
        local = files[index - 1][1]
        size = os.path.getsize(local)
        start, end = 0, size - 1
        m = re.match(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
        if m:
            start = int(m.group(1))
            if m.group(2):
                end = min(int(m.group(2)), size - 1)
            if start >= size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        else:
            self.send_response(200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Type", "video/x-matroska")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            with open(local, "rb") as f:
                f.seek(start)
                left = end - start + 1
                while left > 0:
                    chunk = f.read(min(262144, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
