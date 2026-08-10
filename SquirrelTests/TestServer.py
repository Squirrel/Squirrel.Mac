#!/usr/bin/env python3
#
# A file server for the download specs: serves a directory with ETag,
# Accept-Ranges and byte ranges, and can cut a transfer short.
#
#   TestServer.py <directory> <request-log>
#
# Prints "PORT <n>" once listening. Every request is appended to <request-log>
# as "<METHOD> <path> Range=<header or -> If-Range=<header or ->".
#
#   GET /<file>?drop=<n>   the first request for <file> is closed after <n>
#                          body bytes; later requests are served in full.
#   GET /<file>?slow=<ms>  each 64 KiB of body is followed by a <ms> pause.

import hashlib
import http.server
import os
import socket
import sys
import time
import urllib.parse

root, request_log = sys.argv[1], sys.argv[2]
dropped = set()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        sys.stderr.write("TestServer: " + (format % args) + "\n")

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(url.query)
        with open(request_log, "a") as log:
            log.write("GET %s Range=%s If-Range=%s\n" % (url.path, self.headers.get("Range", "-"), self.headers.get("If-Range", "-")))

        path = os.path.join(root, url.path.lstrip("/"))
        if not os.path.isfile(path):
            self.send_error(404)
            return

        size = os.path.getsize(path)
        with open(path, "rb") as f:
            etag = '"%s"' % hashlib.sha1(f.read()).hexdigest()

        start = 0
        if self.headers.get("Range") and self.headers.get("If-Range", etag) == etag:
            start = int(self.headers["Range"].split("=")[1].split("-")[0])

        self.send_response(206 if start else 200)
        self.send_header("ETag", etag)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size - start))
        if start:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, size - 1, size))
        self.end_headers()

        limit = None
        pause = int(query.get("slow", ["0"])[0]) / 1000.0
        drop = int(query.get("drop", ["0"])[0])
        if drop and url.path not in dropped:
            dropped.add(url.path)
            limit = drop

        sent = 0
        with open(path, "rb") as f:
            f.seek(start)
            while True:
                chunk = f.read(64 * 1024)
                if not chunk:
                    break
                if limit is not None and sent + len(chunk) >= limit:
                    self.wfile.write(chunk[: limit - sent])
                    self.wfile.flush()
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.close_connection = True
                    return
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    return
                sent += len(chunk)
                if pause:
                    self.wfile.flush()
                    time.sleep(pause)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
sys.stdout.write("PORT %d\n" % server.server_address[1])
sys.stdout.flush()
server.serve_forever()
