"""Tests for scripts/update-page/serve.py, the page that answers on port 80
while the stack is down for an update.

Run from the superproject, with the Python 3 that ships with macOS or any
later one, and nothing else installed:

    python3 -m unittest discover -s scripts/tests -p 'test_update_page_server.py'

Each test serves a temporary root (an index.html and a state.json, with a
file beside the root that must never be reachable) on an ephemeral port of
127.0.0.1: in-process for the request tests, as a subprocess for the command
line. Requests go out over raw sockets where the exact request line matters,
so that no client library normalises a traversal attempt away before the
server sees it.
"""

import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(os.path.dirname(HERE), "update-page", "serve.py")
PAGE = os.path.join(os.path.dirname(HERE), "update-page", "index.html")

_spec = importlib.util.spec_from_file_location("update_page_serve", SCRIPT)
serve = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(serve)

INDEX = b"<!doctype html><title>update page</title>"
SECRET = b"outside the root"


def raw_request(port, request_line, headers=b"", body=b""):
    """Send one request as written and return (status, headers, body)."""
    with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
        s.sendall(request_line + b"\r\nHost: test\r\nConnection: close\r\n"
                  + headers + b"\r\n" + body)
        chunks = []
        while True:
            data = s.recv(65536)
            if not data:
                break
            chunks.append(data)
    raw = b"".join(chunks)
    head, _, rest = raw.partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    status = int(lines[0].split()[1])
    hdrs = {}
    for line in lines[1:]:
        k, _, v = line.partition(b":")
        hdrs[k.strip().lower().decode()] = v.strip().decode()
    return status, hdrs, rest


class ServerCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="update-page-test.")
        self.root = os.path.join(self.tmp, "www")
        os.mkdir(self.root)
        with open(os.path.join(self.root, "index.html"), "wb") as f:
            f.write(INDEX)
        with open(os.path.join(self.root, "state.json"), "wb") as f:
            f.write(b'{"state":"updating"}\n')
        with open(os.path.join(self.tmp, "secret.txt"), "wb") as f:
            f.write(SECRET)
        os.symlink(os.path.join(self.tmp, "secret.txt"),
                   os.path.join(self.root, "link.txt"))
        os.mkdir(os.path.join(self.root, "sub"))
        self.server = serve.make_server(self.root, "127.0.0.1", 0)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(5)
        shutil.rmtree(self.tmp)

    def get(self, path, method=b"GET"):
        return raw_request(self.port, method + b" " + path + b" HTTP/1.1")

    def assert_page(self, path):
        status, hdrs, body = self.get(path)
        self.assertEqual(status, 200, path)
        self.assertEqual(body, INDEX, path)
        self.assertEqual(hdrs.get("cache-control"), "no-store", path)
        self.assertTrue(hdrs.get("content-type", "").startswith("text/html"), path)

    def test_root_serves_the_page_without_caching(self):
        self.assert_page(b"/")

    def test_any_other_path_serves_the_page(self):
        self.assert_page(b"/dashboard/projects/12?tab=capture")
        self.assert_page(b"/index.html")
        self.assert_page(b"/_app/immutable/start.js")

    def test_a_directory_serves_the_page_not_a_listing(self):
        self.assert_page(b"/sub/")
        self.assert_page(b"/sub")

    def test_state_json_is_served_as_json_without_caching(self):
        status, hdrs, body = self.get(b"/state.json")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"state": "updating"})
        self.assertEqual(hdrs.get("cache-control"), "no-store")
        self.assertTrue(hdrs.get("content-type", "").startswith("application/json"))

    def test_state_json_is_read_on_each_request(self):
        with open(os.path.join(self.root, "state.json"), "wb") as f:
            f.write(b'{"state":"failed"}\n')
        _, _, body = self.get(b"/state.json?t=1")
        self.assertEqual(json.loads(body), {"state": "failed"})

    def test_api_paths_answer_503_json(self):
        for path in (b"/api/health", b"/api/cameras/capture", b"/api", b"/api/"):
            status, hdrs, body = self.get(path)
            self.assertEqual(status, 503, path)
            self.assertTrue(hdrs.get("content-type", "").startswith("application/json"), path)
            self.assertEqual(hdrs.get("cache-control"), "no-store", path)
            self.assertIn("status", json.loads(body), path)

    def test_post_and_other_methods_are_405(self):
        for method in (b"POST", b"PUT", b"DELETE", b"PATCH", b"OPTIONS"):
            status, hdrs, _ = raw_request(
                self.port, method + b" /api/health HTTP/1.1",
                headers=b"Content-Length: 0\r\n")
            self.assertEqual(status, 405, method)
            self.assertEqual(hdrs.get("allow"), "GET, HEAD", method)
            self.assertEqual(hdrs.get("cache-control"), "no-store", method)

    def test_head_answers_headers_only(self):
        status, hdrs, body = self.get(b"/", method=b"HEAD")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"")
        self.assertEqual(hdrs.get("content-length"), str(len(INDEX)))
        self.assertEqual(hdrs.get("cache-control"), "no-store")
        status, _, body = self.get(b"/api/health", method=b"HEAD")
        self.assertEqual(status, 503)
        self.assertEqual(body, b"")

    def test_traversal_never_leaves_the_root(self):
        attempts = [
            b"/../secret.txt",
            b"/../../etc/passwd",
            b"/%2e%2e/secret.txt",
            b"/%2e%2e%2fsecret.txt",
            b"/..%2fsecret.txt",
            b"/sub/../../secret.txt",
            b"//etc/passwd",
            b"/%2Fetc%2Fpasswd",
            b"/link.txt",
            b"/%00/secret.txt",
            b"/..\\secret.txt",
        ]
        for path in attempts:
            status, _, body = self.get(path)
            self.assertEqual(status, 200, path)
            self.assertNotIn(SECRET, body, path)
            self.assertNotIn(b"root:", body, path)
            self.assertEqual(body, INDEX, path)

    def test_a_missing_state_file_is_not_an_error_page(self):
        os.unlink(os.path.join(self.root, "state.json"))
        status, _, body = self.get(b"/state.json")
        self.assertEqual(status, 200)
        self.assertEqual(body, INDEX)


class LimitsCase(unittest.TestCase):
    """Slow or greedy clients cannot hold the server: connections are capped,
    the request line and headers must arrive within a total deadline, and
    their size is capped. Small limits keep the waits short; every wait is
    bounded."""

    MAX = 4
    DEADLINE = 1.0

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="update-page-limits.")
        with open(os.path.join(self.tmp, "index.html"), "wb") as f:
            f.write(INDEX)
        self.server = serve.make_server(self.tmp, "127.0.0.1", 0,
                                        max_connections=self.MAX,
                                        header_deadline=self.DEADLINE,
                                        header_bytes=4096)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       daemon=True)
        self.thread.start()
        self.socks = []

    def tearDown(self):
        for s in self.socks:
            s.close()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(5)
        shutil.rmtree(self.tmp)

    def slow(self, data=b"GET / HTTP/1.1\r\n"):
        s = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        s.sendall(data)
        self.socks.append(s)
        return s

    def closed_within(self, s, seconds):
        """True when the server closes s (recv returns b"" or the reset)
        before the bound; whatever it sent first is ignored."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            s.settimeout(max(0.01, deadline - time.monotonic()))
            try:
                data = s.recv(4096)
            except socket.timeout:
                return False
            except ConnectionResetError:
                return True
            if not data:
                return True
        return False

    def test_slow_clients_below_the_cap_do_not_block_a_request(self):
        for _ in range(self.MAX - 1):
            self.slow()
        start = time.monotonic()
        status, _, body = raw_request(self.port, b"GET / HTTP/1.1")
        self.assertEqual(status, 200)
        self.assertEqual(body, INDEX)
        self.assertLess(time.monotonic() - start, self.DEADLINE)

    def test_a_connection_beyond_the_cap_is_closed_at_once(self):
        held = [self.slow() for _ in range(self.MAX)]
        # Every slot is taken once each held connection has its thread.
        deadline = time.monotonic() + 3
        while self.server.active_connections() < self.MAX:
            self.assertLess(time.monotonic(), deadline, "slots never filled")
            time.sleep(0.01)
        extra = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        self.socks.append(extra)
        self.assertTrue(self.closed_within(extra, self.DEADLINE / 2))
        # Once the held ones are cut at their deadline, requests are answered.
        for s in held:
            self.assertTrue(self.closed_within(s, self.DEADLINE + 2))
        deadline = time.monotonic() + 3
        while self.server.active_connections() > 0:
            self.assertLess(time.monotonic(), deadline, "slots never freed")
            time.sleep(0.01)
        status, _, _ = raw_request(self.port, b"GET / HTTP/1.1")
        self.assertEqual(status, 200)

    def test_dribbled_headers_are_cut_at_the_total_deadline(self):
        s = self.slow(b"G")
        start = time.monotonic()
        cut = False
        # One byte every 0.2 s: no single read waits long, so only a total
        # deadline ends it.
        payload = b"ET / HTTP/1.1\r\nX-Slow: " + b"a" * 200
        for b in payload:
            try:
                s.sendall(bytes([b]))
            except OSError:
                cut = True
                break
            if self.closed_within(s, 0.2):
                cut = True
                break
            self.assertLess(time.monotonic() - start, self.DEADLINE + 2,
                            "still open well past the deadline")
        self.assertTrue(cut)
        self.assertGreaterEqual(time.monotonic() - start, self.DEADLINE * 0.8)

    def test_oversized_headers_are_refused(self):
        big = b"X-Big: " + b"a" * 8000 + b"\r\n"
        status, hdrs, _ = raw_request(self.port, b"GET / HTTP/1.1", headers=big)
        self.assertEqual(status, 431)
        self.assertEqual(hdrs.get("cache-control"), "no-store")

    def test_every_response_closes_the_connection(self):
        with socket.create_connection(("127.0.0.1", self.port), timeout=5) as s:
            s.sendall(b"GET / HTTP/1.1\r\nHost: t\r\n\r\n")
            self.assertTrue(self.closed_within(s, 2))


class CommandLineCase(unittest.TestCase):
    def test_serves_the_given_root_on_the_given_port(self):
        tmp = tempfile.mkdtemp(prefix="update-page-cli.")
        self.addCleanup(shutil.rmtree, tmp)
        with open(os.path.join(tmp, "index.html"), "wb") as f:
            f.write(INDEX)
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        proc = subprocess.Popen(
            [sys.executable, "-I", "-B", SCRIPT, "--root", tmp,
             "--host", "127.0.0.1", "--port", str(port)],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.addCleanup(proc.stderr.close)
        self.addCleanup(proc.wait, 5)
        self.addCleanup(proc.terminate)
        deadline = time.monotonic() + 10
        while True:
            try:
                status, hdrs, body = raw_request(port, b"GET /x HTTP/1.1")
                break
            except OSError:
                if proc.poll() is not None or time.monotonic() > deadline:
                    self.fail("server did not answer: "
                              + proc.stderr.read().decode(errors="replace"))
                time.sleep(0.05)
        self.assertEqual(status, 200)
        self.assertEqual(body, INDEX)

    def test_refuses_a_root_without_index_html(self):
        tmp = tempfile.mkdtemp(prefix="update-page-cli.")
        self.addCleanup(shutil.rmtree, tmp)
        rc = subprocess.run(
            [sys.executable, "-I", "-B", SCRIPT, "--root", tmp,
             "--host", "127.0.0.1", "--port", "0"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
        self.assertEqual(rc, 2)


class PageCase(unittest.TestCase):
    """The shipped page is self-contained and reads the state it is given."""

    def setUp(self):
        with open(PAGE, encoding="utf-8") as f:
            self.html = f.read()

    def test_no_external_assets(self):
        for needle in ("http://", "https://", "//cdn", "<link", "src=\""):
            self.assertNotIn(needle, self.html, needle)

    def test_polls_health_and_state_without_cache(self):
        self.assertIn("/api/health", self.html)
        self.assertIn("/state.json", self.html)
        self.assertIn("no-store", self.html)
        self.assertIn("5000", self.html)

    def test_the_reviewed_texts_are_used_as_given(self):
        texts = [
            "Captua se está actualizando en este equipo",
            "Captua is being updated on this unit",
            "No apagues el equipo ni desconectes la corriente hasta que Captua vuelva, para no dañar la tarjeta de memoria.",
            "Do not turn off or unplug the unit until Captua is back, so that the memory card is not damaged.",
            "Captua volverá a funcionar solo cuando termine de actualizarse; no hace falta hacer nada.",
            "Captua will be back on its own when it has finished updating. Nothing needs to be done.",
            "No hace falta recargar: verás Captua aquí cuando vuelva.",
            "There is no need to reload: you will see Captua here when it is back.",
            "Captua no pudo terminar la actualización",
            "Captua could not finish the update",
            "Captua quedó detenido en este equipo.",
            "Captua is stopped on this unit.",
            "Un administrador tiene que revisar el equipo. Hasta entonces, Captua no se puede usar. Avisa al administrador.",
            "An administrator has to look at the unit. Until then, Captua cannot be used. Tell the administrator.",
        ]
        for t in texts:
            self.assertIn(t, self.html)
        self.assertNotIn("ES pending", self.html)

    def test_the_warning_sits_under_the_title_in_its_own_block(self):
        for lang, title, warning in (
                ("es", "Captua se está actualizando en este equipo",
                 "No apagues el equipo"),
                ("en", "Captua is being updated on this unit",
                 "Do not turn off or unplug")):
            start = self.html.index('data-state="updating" lang="%s"' % lang)
            section = self.html[start:self.html.index("</section>", start)]
            after_title = section[section.index("</h1>"):]
            first_p = after_title[after_title.index("<p"):]
            self.assertTrue(first_p.startswith('<p class="warning">'), lang)
            self.assertIn(warning, first_p.split("</p>")[0], lang)

    def test_has_both_states_in_both_languages(self):
        for state in ("updating", "failed"):
            for lang in ("es", "en"):
                self.assertIn('data-state="%s" lang="%s"' % (state, lang), self.html)
        self.assertLess(self.html.index('lang="es"'), self.html.index('lang="en"'))


if __name__ == "__main__":
    unittest.main()
