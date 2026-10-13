"""Shared HTTP client and assertion helpers for tests/apps/<app>/suite/web.py.

Standard library only, so the suites run on any host with python3 and
nothing installed.

The client talks to the stack's published port on 127.0.0.1 and sends the
fixture's canonical Host header (apptest.test). Redirects are followed by
hand: a Location pointing at the canonical host is mapped back onto the
published port, so WordPress and PrestaShop can keep their absolute URLs.

Output follows the rest of tests/: one "ok: <name>" or "FAIL: <name> -- <why>"
line per check, "SKIP: <name> -- <why>" for a check that does not apply, and
a final summary line. Exit status is 1 when anything failed.
"""

import argparse
import http.client
import json
import os
import re
import sys
import time
import uuid
from http.cookies import SimpleCookie
from urllib.parse import urlencode, urljoin, urlsplit

# Markers of a PHP-level failure rendered into a page. A page that answers
# 200 but carries one of these is a failure: display_errors is off on every
# image, so seeing one means something printed it on purpose (framework
# error pages) or the app is running with debug on, and either is wrong here.
ERROR_MARKERS = [
    re.compile(p)
    for p in (
        r"<b>(Fatal error|Parse error|Warning|Notice|Deprecated)</b>:",
        r"\bPHP (Fatal error|Parse error|Warning)\b",
        r"Stack trace:\s*#0",
        r"Whoops, looks like something went wrong",
        r"There has been a critical error on this website",
        r"Error establishing a database connection",
        r"An error occurred while processing your request",
        r"Uncaught (Error|Exception|TypeError)",
        r"SQLSTATE\[",
    )
]


def parse_args(description):
    p = argparse.ArgumentParser(description=description)
    p.add_argument("--base", required=True, help="http://127.0.0.1:<port>")
    p.add_argument("--host", required=True, help="canonical Host header")
    p.add_argument("--manifest", required=True, help="fixture manifest.json")
    p.add_argument("--set", required=True)
    p.add_argument("--php", required=True)
    p.add_argument("--config", default="default")
    p.add_argument("--stock", default="0")
    args = p.parse_args()
    with open(args.manifest) as fh:
        args.manifest_data = json.load(fh)
    args.stock = args.stock == "1"
    return args


def php_at_least(args, version):
    have = tuple(int(x) for x in args.php.split("."))
    want = tuple(int(x) for x in version.split("."))
    return have >= want


class Response:
    def __init__(self, status, headers, body, url, elapsed):
        self.status = status
        self.headers = headers  # list of (name, value), names lowercased
        self.body = body
        self.url = url
        self.elapsed = elapsed

    def header(self, name, default=None):
        name = name.lower()
        for k, v in self.headers:
            if k == name:
                return v
        return default

    def header_all(self, name):
        name = name.lower()
        return [v for k, v in self.headers if k == name]

    @property
    def text(self):
        return self.body.decode("utf-8", "replace")

    def json(self):
        return json.loads(self.body.decode("utf-8"))

    def error_marker(self):
        """The first PHP/framework error marker in the body, or None."""
        ctype = (self.header("content-type") or "").lower()
        if not any(t in ctype for t in ("html", "json", "xml", "text")):
            return None
        text = self.text
        for rx in ERROR_MARKERS:
            m = rx.search(text)
            if m:
                start = max(0, m.start() - 80)
                return text[start : m.end() + 160].replace("\n", " ")
        return None

    def __repr__(self):
        return f"<{self.status} {self.url} {len(self.body)}B {self.elapsed:.2f}s>"


class Client:
    """A cookie-keeping browser stand-in. One per logical user session."""

    def __init__(self, base, host, timeout=120, user_agent=None):
        parts = urlsplit(base)
        self.addr = parts.hostname
        self.port = parts.port or 80
        self.host = host
        self.timeout = timeout
        self.cookies = {}
        self.user_agent = user_agent or "apptest/1 (+lotuswebagency/php)"
        self.history = []

    # -- url helpers -----------------------------------------------------
    def url(self, path):
        return f"http://{self.host}{path}"

    def _local_path(self, url):
        """Map an absolute URL on the canonical host back to a request path."""
        parts = urlsplit(url)
        if parts.scheme and parts.hostname and parts.hostname not in (self.host, self.addr):
            raise ValueError(f"redirect off-site: {url}")
        path = parts.path or "/"
        if parts.query:
            path += "?" + parts.query
        return path

    # -- cookies ---------------------------------------------------------
    def _store_cookies(self, headers):
        for k, v in headers:
            if k != "set-cookie":
                continue
            c = SimpleCookie()
            try:
                c.load(v)
            except Exception:
                name, _, rest = v.partition("=")
                self.cookies[name.strip()] = rest.split(";", 1)[0]
                continue
            for name, morsel in c.items():
                expires = morsel.get("expires", "")
                max_age = morsel.get("max-age", "")
                if morsel.value in ("", "deleted") or max_age == "0" or (
                    expires and re.search(r"19[0-9]{2}|1970", expires)
                ):
                    self.cookies.pop(name, None)
                else:
                    self.cookies[name] = morsel.value

    def cookie_header(self):
        return "; ".join(f"{k}={v}" for k, v in self.cookies.items())

    # -- requests --------------------------------------------------------
    def request(self, method, path, data=None, json_body=None, files=None, headers=None,
                follow=True, max_redirects=10):
        hdrs = {"Host": self.host, "User-Agent": self.user_agent, "Accept": "*/*"}
        body = None
        if json_body is not None:
            body = json.dumps(json_body).encode()
            hdrs["Content-Type"] = "application/json"
        elif files:
            body, ctype = encode_multipart(data or {}, files)
            hdrs["Content-Type"] = ctype
        elif data is not None:
            if isinstance(data, (bytes, str)):
                body = data.encode() if isinstance(data, str) else data
            else:
                body = urlencode(data, doseq=True).encode()
                hdrs["Content-Type"] = "application/x-www-form-urlencoded"
        if headers:
            hdrs.update(headers)

        for _ in range(max_redirects + 1):
            if self.cookies:
                hdrs["Cookie"] = self.cookie_header()
            t0 = time.monotonic()
            conn = http.client.HTTPConnection(self.addr, self.port, timeout=self.timeout)
            try:
                conn.request(method, path, body=body, headers=hdrs)
                r = conn.getresponse()
                raw = r.read()
                resp_headers = [(k.lower(), v) for k, v in r.getheaders()]
            finally:
                conn.close()
            resp = Response(r.status, resp_headers, raw, path, time.monotonic() - t0)
            self.history.append(resp)
            self._store_cookies(resp_headers)
            loc = resp.header("location")
            if follow and resp.status in (301, 302, 303, 307, 308) and loc:
                path = self._local_path(urljoin(self.url(path), loc))
                if resp.status in (301, 302, 303) and method != "HEAD":
                    method, body = "GET", None
                    hdrs.pop("Content-Type", None)
                continue
            return resp
        raise RuntimeError(f"more than {max_redirects} redirects from {path}")

    def get(self, path, **kw):
        return self.request("GET", path, **kw)

    def post(self, path, data=None, **kw):
        return self.request("POST", path, data=data, **kw)


def encode_multipart(fields, files):
    """files: {name: (filename, bytes, content_type)}"""
    boundary = "----apptest" + uuid.uuid4().hex
    out = []
    for k, v in (fields.items() if isinstance(fields, dict) else fields):
        out.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n".encode())
        out.append(str(v).encode() + b"\r\n")
    for k, (fname, content, ctype) in files.items():
        out.append(
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"; filename=\"{fname}\"\r\n"
            f"Content-Type: {ctype}\r\n\r\n".encode()
        )
        out.append(content + b"\r\n")
    out.append(f"--{boundary}--\r\n".encode())
    return b"".join(out), f"multipart/form-data; boundary={boundary}"


def hidden_inputs(html, form_match=None):
    """Every <input type=hidden> name/value in html (or in the first <form>
    whose opening tag matches form_match)."""
    if form_match:
        m = re.search(r"<form[^>]*" + form_match + r"[^>]*>(.*?)</form>", html, re.S | re.I)
        html = m.group(1) if m else ""
    out = {}
    for tag in re.findall(r"<input[^>]+>", html, re.I):
        if not re.search(r"type=[\"']?hidden", tag, re.I):
            continue
        n = re.search(r"name=[\"']([^\"']+)", tag)
        v = re.search(r"value=[\"']([^\"']*)", tag)
        if n:
            out[n.group(1)] = v.group(1) if v else ""
    return out


class Suite:
    """Collects checks. Every check records, never raises: one broken page
    must not hide the rest of the suite's results."""

    def __init__(self, name, args=None):
        self.name = name
        self.args = args
        self.passed = 0
        self.failed = []
        self.skipped = 0
        self.t0 = time.monotonic()

    def ok(self, name, cond, detail=""):
        if cond:
            self.passed += 1
            print(f"ok: {name}", flush=True)
        else:
            self.failed.append(name)
            print(f"FAIL: {name}" + (f" -- {detail}" if detail else ""), flush=True)
        return bool(cond)

    def skip(self, name, why):
        self.skipped += 1
        print(f"SKIP: {name} -- {why}", flush=True)

    def eq(self, name, got, want):
        return self.ok(name, got == want, f"expected {want!r}, got {got!r}")

    def page(self, name, resp, status=200, contains=(), not_contains=(), min_bytes=0,
             ctype=None):
        """The standard page assertion: status, content type, size, required
        and forbidden substrings, and no PHP error markers."""
        problems = []
        if isinstance(status, int):
            status = (status,)
        if resp.status not in status:
            problems.append(f"status {resp.status} (want {'/'.join(map(str, status))})")
        if ctype and ctype not in (resp.header("content-type") or ""):
            problems.append(f"content-type {resp.header('content-type')!r} (want {ctype})")
        if len(resp.body) < min_bytes:
            problems.append(f"{len(resp.body)} bytes (want >= {min_bytes})")
        text = resp.text
        for s in ([contains] if isinstance(contains, str) else contains):
            if s not in text:
                problems.append(f"missing {s!r}")
        for s in ([not_contains] if isinstance(not_contains, str) else not_contains):
            if s in text:
                problems.append(f"unexpected {s!r}")
        marker = resp.error_marker()
        if marker:
            problems.append(f"error marker: {marker[:300]}")
        detail = "; ".join(problems)
        if problems and resp.status >= 400 or marker:
            detail += f" | body: {text[:400]!r}"
        return self.ok(f"{name} [{resp.url}]", not problems, detail)

    def guard(self, name, fn, *a, **kw):
        """Run fn; an exception is a failure of this check, not of the suite."""
        try:
            return fn(*a, **kw)
        except Exception as e:  # noqa: BLE001 -- recorded, never swallowed silently
            self.ok(name, False, f"{type(e).__name__}: {e}")
            return None

    def finish(self):
        wall = time.monotonic() - self.t0
        total = self.passed + len(self.failed)
        status = "FAILED" if self.failed else "passed"
        print(
            f"{self.name}: {self.passed}/{total} passed, {len(self.failed)} failed, "
            f"{self.skipped} skipped in {wall:.0f}s -- {status}",
            flush=True,
        )
        sys.exit(1 if self.failed else 0)


def env_flag(name):
    return os.environ.get(name, "") in ("1", "true", "yes")
