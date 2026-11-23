#!/usr/bin/env python3
"""Answers on port 80 with the update page while Captua's stack is down.

From the moment an update stops the stack until nginx is back, nothing else
listens on port 80, and a browser on the unit or on the network would get a
connection error. dtk-system-helper's update-page-start runs this script, as
a transient systemd unit with a dynamic user, over a root-owned copy of the
page in /run/dtk-update-page; update-page-stop ends it, and update.sh and
rollback-update.sh call that before every start of dtk.

    python3 -I -B serve.py --root /run/dtk-update-page --port 80

Every path answers with index.html, so a browser left on any page of the
interface reloads into it. The exceptions: a regular file that sits inside
the root (state.json, which the helper rewrites and the page reads on each
poll) is served as itself, and anything under /api answers 503 with a short
JSON body, so the interface's own requests fail as requests instead of
receiving HTML. Only GET and HEAD are answered; every other method is 405.
Nothing is cached (Cache-Control: no-store on every response), nothing is
listed, and no path resolves outside the root: a path is decoded, joined to
the root and resolved through symlinks, and anything that does not land on a
regular file inside the root gets the page.

No client can hold the server. At most MAX_CONNECTIONS connections are
handled at once, and one beyond that is closed as soon as it is accepted.
The request line and headers must arrive in full within HEADER_DEADLINE
seconds of the connection, however slowly the bytes come, and may not
exceed HEADER_BYTES (431 beyond that). Every response closes its connection.
Request bodies are never read.

Standard library only: the unit runs it with the system python3 and nothing
installed, and the tests run it with the Python 3 that ships with macOS.
"""

import argparse
import http.server
import os
import socket
import sys
import threading
import time
import urllib.parse

CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".json": "application/json",
}
API_BODY = b'{"status":"unavailable","detail":"Captua is stopped for an update."}\n'
MAX_CONNECTIONS = 32
HEADER_DEADLINE = 5.0
HEADER_BYTES = 16384
WRITE_TIMEOUT = 10.0


class HeadersTooLarge(Exception):
    pass


class DeadlineReader:
    """Reads the request line and headers straight from the socket, against
    one deadline for all of them and one cap on their total size. Each recv
    waits only for the time left, so a client sending a byte at a time is
    cut at the deadline, not after it stops sending."""

    def __init__(self, sock, deadline, limit):
        self.sock = sock
        self.deadline = deadline
        self.limit = limit
        self.buf = b""
        self.total = 0

    def readline(self, size=-1):
        while True:
            nl = self.buf.find(b"\n")
            if nl >= 0 or (0 <= size <= len(self.buf)):
                end = nl + 1 if nl >= 0 else size
                if 0 <= size < end:
                    end = size
                line, self.buf = self.buf[:end], self.buf[end:]
                return line
            if self.total >= self.limit:
                raise HeadersTooLarge()
            left = self.deadline - time.monotonic()
            if left <= 0:
                raise socket.timeout("request headers not received in time")
            self.sock.settimeout(left)
            data = self.sock.recv(min(4096, self.limit - self.total + 1))
            if not data:
                line, self.buf = self.buf, b""
                return line
            self.total += len(data)
            self.buf += data

    def read(self, size=-1):
        return b""

    def close(self):
        pass


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "dtk-update-page"
    sys_version = ""
    # HTTP/1.0: the connection closes after every response, so an idle client
    # cannot keep a slot between requests.
    protocol_version = "HTTP/1.0"

    def __getattr__(self, name):
        # BaseHTTPRequestHandler answers a method it finds no do_<METHOD> for
        # with 501; every method other than GET and HEAD is 405 instead.
        if name.startswith("do_"):
            return self._method_not_allowed
        raise AttributeError(name)

    def setup(self):
        super().setup()
        self.rfile = DeadlineReader(self.connection,
                                    time.monotonic() + self.server.header_deadline,
                                    self.server.header_bytes)

    def handle(self):
        self.close_connection = True
        try:
            self.raw_requestline = self.rfile.readline(65537)
            if not self.raw_requestline:
                return
            if not self.parse_request():
                return
        except HeadersTooLarge:
            self.command = None
            self.request_version = "HTTP/1.0"
            self.send_error(431)
            self._drain()
            return
        except (socket.timeout, OSError):
            return
        self.connection.settimeout(WRITE_TIMEOUT)
        try:
            getattr(self, "do_" + self.command)()
            self.wfile.flush()
        except OSError:
            pass

    def _drain(self):
        # Closing with unread request bytes makes the kernel send a reset,
        # and the client may lose the 431 with it. Read and discard what is
        # still arriving, for a second and 64 KiB at most.
        try:
            self.wfile.flush()
            self.connection.shutdown(socket.SHUT_WR)
            end = time.monotonic() + 1.0
            got = 0
            while got < 65536:
                left = end - time.monotonic()
                if left <= 0:
                    break
                self.connection.settimeout(left)
                data = self.connection.recv(4096)
                if not data:
                    break
                got += len(data)
        except OSError:
            pass

    def log_request(self, code="-", size="-"):
        # The page polls every 5 s from every open browser, so answered
        # requests are not logged; errors still reach the journal through
        # log_error.
        pass

    def send_error(self, code, message=None, explain=None):
        body = ("%d\n" % code).encode()
        try:
            self._send(code, "text/plain; charset=utf-8", body,
                       send_body=getattr(self, "command", None) != "HEAD")
        except OSError:
            pass

    def do_GET(self):
        self._answer(send_body=True)

    def do_HEAD(self):
        self._answer(send_body=False)

    def _method_not_allowed(self):
        self._send(405, "text/plain; charset=utf-8", b"Method not allowed\n",
                   send_body=True, extra={"Allow": "GET, HEAD"})

    def _answer(self, send_body):
        path = urllib.parse.urlsplit(self.path).path
        decoded = urllib.parse.unquote(path)
        if decoded == "/api" or decoded.startswith("/api/") \
                or path == "/api" or path.startswith("/api/"):
            self._send(503, "application/json", API_BODY, send_body)
            return
        name = self._file_inside_root(decoded) or "index.html"
        body = self._read(name)
        if body is None and name != "index.html":
            # state.json was removed between the check and the read.
            name = "index.html"
            body = self._read(name)
        if body is None:
            self._send(503, "text/plain; charset=utf-8",
                       b"Captua is stopped for an update.\n", send_body)
            return
        ctype = CONTENT_TYPES.get(os.path.splitext(name)[1],
                                  "application/octet-stream")
        self._send(200, ctype, body, send_body)

    def _read(self, name):
        try:
            with open(os.path.join(self.server.root, name), "rb") as f:
                return f.read()
        except OSError:
            return None

    def _file_inside_root(self, decoded):
        """The path's name relative to the root, if it is a regular file
        inside it; None otherwise."""
        if "\x00" in decoded or "\\" in decoded:
            return None
        root = self.server.root
        try:
            candidate = os.path.realpath(os.path.join(root, decoded.lstrip("/")))
        except (ValueError, OSError):
            return None
        if os.path.commonpath([root, candidate]) != root or candidate == root:
            return None
        if not os.path.isfile(candidate):
            return None
        return os.path.relpath(candidate, root)

    def _send(self, status, ctype, body, send_body, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if send_body:
            self.wfile.write(body)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, root, address, family, max_connections,
                 header_deadline, header_bytes):
        self.address_family = family
        self.root = os.path.realpath(root)
        self.header_deadline = header_deadline
        self.header_bytes = header_bytes
        self._slots = threading.BoundedSemaphore(max_connections)
        self._max = max_connections
        self._count_lock = threading.Lock()
        self._active = 0
        super().__init__(address, Handler)

    def active_connections(self):
        with self._count_lock:
            return self._active

    def server_bind(self):
        if self.address_family == socket.AF_INET6:
            # One socket for IPv6 and IPv4: the kiosk's "localhost" may
            # resolve to ::1, a laptop on the network uses IPv4.
            try:
                self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            except OSError:
                pass
        super().server_bind()

    def process_request(self, request, client_address):
        if not self._slots.acquire(blocking=False):
            # Every slot is taken: close at once rather than queue.
            self.shutdown_request(request)
            return
        with self._count_lock:
            self._active += 1
        try:
            super().process_request(request, client_address)
        except Exception:
            self._release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._release()

    def _release(self):
        with self._count_lock:
            self._active -= 1
        self._slots.release()

    def handle_error(self, request, client_address):
        # A client that goes away mid-response is not an error worth a
        # traceback in the journal.
        pass


def make_server(root, host, port, max_connections=MAX_CONNECTIONS,
                header_deadline=HEADER_DEADLINE, header_bytes=HEADER_BYTES):
    """A server for root on host:port, not yet serving. Host "::" listens on
    IPv6 and IPv4 together, and falls back to IPv4 alone on a host without
    IPv6."""
    limits = (max_connections, header_deadline, header_bytes)
    if host == "::":
        try:
            return Server(root, ("::", port), socket.AF_INET6, *limits)
        except OSError:
            host = "0.0.0.0"
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    return Server(root, (host, port), family, *limits)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--root", required=True,
                        help="directory holding index.html and state.json")
    parser.add_argument("--host", default="::")
    parser.add_argument("--port", type=int, default=80)
    args = parser.parse_args(argv)
    if not os.path.isfile(os.path.join(args.root, "index.html")):
        sys.stderr.write("dtk-update-page: no index.html in %s\n" % args.root)
        return 2
    server = make_server(args.root, args.host, args.port)
    sys.stderr.write("dtk-update-page: serving %s on port %d\n"
                     % (server.root, server.server_address[1]))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
