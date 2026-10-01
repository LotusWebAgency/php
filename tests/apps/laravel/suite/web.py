"""Laravel over HTTP: real routes of the fixture app, behind nginx and php-fpm.

Every check is additive (unique tokens, nothing seeded is deleted) because the
suite runs once per config on one stack. Values with a known-good origin come
from the manifest the stock PHP wrote; values any correct PHP must produce
(digests, big integers, archives) are recomputed here in Python.
"""
import base64
import gzip
import hashlib
import hmac
import io
import json
import math
import os
import re
import struct
import sys
import time
import uuid
import zipfile
import zlib
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import quote, urlencode

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
import apptest  # noqa: E402

args = apptest.parse_args("laravel http suite")
M = args.manifest_data
s = apptest.Suite("laravel-http", args)
RUN = uuid.uuid4().hex[:10]
SESSION_COOKIE = "apptest-session"
LARAVEL = int(M["app_version"].split(".")[0])
LV = tuple(int(x) for x in M["app_version"].split(".")[:2])
# 10 reworded the validation messages: "The body field must be ..." (8: "The body must be ...").
FIELD = "field " if LARAVEL >= 10 else ""
# 7 reworded max: "may not be greater than" before, "must not be greater than" after.
MAXMSG = "must not be greater than" if LARAVEL >= 7 else "may not be greater than"
# 5.5's error views carry words; 5.8+ ones carry the status code.
E404, E419 = ("404", "419") if LV >= (5, 8) else ("Page Not Found", "The page has expired due to inactivity")


# The second hash algorithm the fixture holds a user for: argon2id (PHP 7.3+),
# argon2i (7.2), and none on the older sets, which are bcrypt only.
SECOND = next((k for k in ("argon2id", "argon2i") if k in M["users"]), None)


def new():
    return apptest.Client(args.base, args.host)


def framework_page(name, resp, status, contains=(), not_contains=()):
    """s.page() minus the 'Whoops, looks like something went wrong' marker, for
    the error pages that say exactly that themselves: 5.5's 500 view and the
    Symfony fallback page an unmapped status (405) gets before Laravel 8."""
    text = resp.text
    problems = []
    if resp.status != status:
        problems.append(f"status {resp.status} (want {status})")
    problems += [f"missing {c!r}" for c in ([contains] if isinstance(contains, str) else contains) if c not in text]
    problems += [f"unexpected {c!r}" for c in ([not_contains] if isinstance(not_contains, str) else not_contains) if c in text]
    return s.ok(f"{name} [{resp.url}]", not problems, "; ".join(problems) + (f" | body: {text[:300]!r}" if problems else ""))


def esc(text):
    """What Blade's e() does."""
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;").replace("'", "&#039;"))


def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def token_of(html):
    return apptest.hidden_inputs(html).get("_token", "")


def total_of(html, ident="total"):
    m = re.search(r'id="%s"[^>]*data-total="(\d+)"' % ident, html)
    return int(m.group(1)) if m else -1


def png(w, h, alpha=False):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    rows = []
    for y in range(h):
        row = bytearray([0])
        for x in range(w):
            row += bytes(((x * 255) // max(1, w - 1), (y * 255) // max(1, h - 1), ((x + y) * 3) & 255))
            if alpha:
                row.append(60 + (x * 190) // max(1, w - 1))
        rows.append(bytes(row))
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6 if alpha else 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(b"".join(rows), 6)) + chunk(b"IEND", b"")


def jpeg_size(data):
    if data[:2] != b"\xff\xd8":
        return None
    i = 2
    while i + 9 < len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            h, w = struct.unpack(">HH", data[i + 5:i + 9])
            return w, h
        i += 2 + struct.unpack(">H", data[i + 2:i + 4])[0]
    return None


def webp_size(data):
    if data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        return None
    kind = data[12:16]
    if kind == b"VP8 ":
        w, h = struct.unpack("<HH", data[26:30])
        return w & 0x3FFF, h & 0x3FFF
    if kind == b"VP8L":
        bits = struct.unpack("<I", data[21:25])[0]
        return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
    if kind == b"VP8X":
        return int.from_bytes(data[24:27], "little") + 1, int.from_bytes(data[27:30], "little") + 1
    return None


def feature(area, path, client=None, method="GET", **kw):
    """Call a /api/features endpoint and turn each server-side check into its own line."""
    client = client or new()
    r = client.request(method, path, headers={"Accept": "application/json"}, **kw)
    if not s.page("feature " + area, r, ctype="json"):
        return None
    j = r.json()
    for name, val in j["checks"].items():
        s.ok(f"{area}: {name}", val is True, f"got {val!r}")
    for name, why in (j.get("skipped") or {}).items():
        s.skip(f"{area}: {name}", why)
    return j


# ---------------------------------------------------------------- preflight
def preflight():
    c = new()
    s.page("health /up", c.get("/up"), min_bytes=20)
    r = c.get("/api/info")
    s.page("api info", r, ctype="json")
    return r.json()


info = s.guard("preflight", preflight)
if not info:
    s.finish()
exts = set(info["extensions"])
print(f"info: php {info['php']} {info['sapi']} zts={info['zts']} laravel {info['laravel']} {info['env']}")
print(f"info: opcache {json.dumps(info['opcache'])} jit={info['ini'].get('opcache.jit')} memory_limit={info['ini'].get('memory_limit')}")
print(f"info: {len(exts)} extensions: {' '.join(sorted(exts))}")
s.ok("php version matches the image", info["php"].startswith(args.php + "."), info["php"])
s.eq("laravel version is the fixture's", info["laravel"], M["app_version"])
s.ok("production mode: config and routes cached", info["config_cached"] and info["routes_cached"] and info["env"] == "production")
s.ok("sapi is fpm", "fpm" in info["sapi"], info["sapi"])
s.ok("opcache enabled", bool(info["opcache"] and info["opcache"]["enabled"]), json.dumps(info["opcache"]))
required = ["bcmath", "ctype", "curl", "dom", "fileinfo", "filter", "gd", "hash", "iconv", "igbinary", "imagick", "intl", "json",
            "libxml", "mbstring", "memcached", "mysqlnd", "openssl", "pcntl", "pcre", "pdo_mysql", "posix", "redis", "session",
            "simplexml", "tokenizer", "xml", "xmlreader", "xmlwriter", "zip", "zlib", "zstd", "zend opcache"]
if tuple(int(x) for x in args.php.split(".")) >= (7, 2):
    required.append("sodium")  # core from 7.2, no stock or from-source build has it before
if not args.stock:
    required += ["apcu", "gmp", "xsl", "sockets", "calendar", "gettext", "exif", "soap"]
    required += ["brotli", "lz4", "msgpack"]  # opt-in through php.env
s.ok("required extensions are loaded", all(e in exts for e in required), "missing: " + " ".join(e for e in required if e not in exts))
if not args.stock:
    r = new().get("/")
    s.ok("expose_php is off", r.header("x-powered-by") is None, r.header("x-powered-by"))


# --------------------------------------------------------------- pages
def pages():
    c = new()
    r = c.get("/")
    s.page("home", r, contains=['<h1>Latest posts</h1>', 'id="total"', "?page=2", "<title>Latest posts | Apptest Blog</title>", 'name="csrf-token"'],
           ctype="text/html", min_bytes=8000)
    total = total_of(r.text)
    s.ok("home total covers the seeded posts", total >= M["counts"]["posts"], total)
    s.eq("home shows 12 cards", r.text.count('class="post-card"'), 12)
    s.ok("home cards carry authors, dates and comment counts", len(re.findall(r"by [^|<]+ \| \d{4}-\d\d-\d\d \d\d:\d\d \| \d+ comments", r.text)) == 12)
    s.ok("charset is utf-8", "charset=utf-8" in (r.header("content-type") or "").lower(), r.header("content-type"))
    # config/session.php's same_site is null until 7 makes it 'lax'
    lax = LV >= (7, 0)
    s.ok("session cookie is httponly" + (" + samesite" if lax else ""),
         any(SESSION_COOKIE in v and "httponly" in v.lower() and (not lax or "samesite=lax" in v.lower()) for v in r.header_all("set-cookie")),
         r.header_all("set-cookie"))
    r2 = c.get("/?page=2")
    s.page("home page 2", r2, contains="?page=3")
    s.ok("page 2 is different from page 1", re.findall(r'id="post-(\d+)"', r.text) != re.findall(r'id="post-(\d+)"', r2.text))
    last = math.ceil(total / 12)
    s.page("home last page", c.get(f"/?page={last}"), contains='class="post-card"')
    s.page("home past the end is an empty page, not an error", c.get(f"/?page={last + 50}"), not_contains='class="post-card"')
    s.page("home with junk page number", c.get("/?page=abc%00x"), status=(200, 400))

    for lang, p in M["posts"]["by_lang"].items():
        r = c.get("/posts/" + p["slug"])
        s.page(f"post detail ({lang})", r, contains=[esc(p["title"]), 'dir="auto"', 'id="comments"', 'class="body"'])
    first = M["posts"]["first"]
    r = c.get("/posts/" + first["slug"])
    s.eq("seeded posts have 5 comments each", int(re.search(r'data-count="(\d+)"', r.text).group(1)), 5)
    s.eq("post detail lists its comments", r.text.count('class="comment"'), 5)
    s.ok("post detail lists its tags", r.text.count('href="/tags/') >= 2)
    s.page("last seeded post", c.get("/posts/" + M["posts"]["last"]["slug"]), contains=esc(M["posts"]["last"]["title"]))

    tag = M["tag"]
    r = c.get("/tags/" + tag["slug"])
    s.page("tag page", r, contains=["Tag: " + esc(tag["name"])])
    s.eq("tag page total is the manifest's", total_of(r.text), tag["posts"])
    s.page("tag page 2", c.get(f"/tags/{tag['slug']}?page=2"), contains='class="post-card"')

    s.page("unknown post is Laravel's 404", c.get("/posts/no-such-post"), status=404, contains=E404)
    s.page("unknown route is Laravel's 404", c.get("/no/such/route"), status=404, contains=E404)
    s.page("unknown tag is a 404", c.get("/tags/none"), status=404)
    r = c.request("POST", "/tags/none", data={})
    if LARAVEL >= 8:
        s.page("wrong method is a 405", r, status=405)
    else:
        framework_page("wrong method is a 405", r, 405)
    r = c.get("/boom")
    if LV >= (5, 8):
        s.page("deliberate 500 is Laravel's page", r, status=500, contains=["500", "Server Error"], not_contains=["deliberate failure", "Stack trace"])
    else:
        framework_page("deliberate 500 is Laravel's page", r, 500, contains="Whoops, looks like something went wrong", not_contains=["deliberate failure", "Stack trace"])
    r = c.get("/api/boom", headers={"Accept": "application/json"})
    s.page("deliberate 500 as JSON", r, status=500, ctype="json")
    s.eq("500 JSON body hides the exception", r.json().get("message"), "Server Error")
    s.page("robots.txt from public/", c.get("/robots.txt"), contains="User-agent")
    r = c.get("/.env")
    s.ok(".env is not served", r.status in (403, 404) and "APP_KEY" not in r.text, r.status)
    s.ok("composer.json is not served", c.get("/composer.json").status == 404)
    s.page("HEAD /", c.request("HEAD", "/"), status=200)
    s.page("very long query string", c.get("/search?q=" + quote("я" * 700)), contains='id="result-count"')


s.guard("pages", pages)


# --------------------------------------------------------------- search
def search():
    c = new()
    for item in M["searches"]:
        q = item["q"]
        r = c.get("/search?q=" + quote(q, safe=""))
        s.page(f"search html {q!r}", r, contains='id="result-count"')
        s.eq(f"search html total {q!r}", total_of(r.text, "result-count"), item["total"])
        j = c.get("/api/search?" + urlencode({"q": q})).json()
        s.eq(f"search json total {q!r}", j["total"], item["total"])
        s.ok(f"search json page size {q!r}", len(j["ids"]) == min(15, item["total"]), len(j["ids"]))
    r = c.get("/search?q=" + quote("kernel", safe="") + "&page=3")
    s.page("search page 3 keeps the query in its links", r, contains="q=kernel")
    s.eq("search: upper and lower case agree", c.get("/api/search?q=KERNEL").json()["total"], c.get("/api/search?q=kernel").json()["total"])
    r = c.get("/search?q=" + quote("<script>alert(1)</script>", safe=""))
    s.page("search reflects input escaped", r, contains="&lt;script&gt;", not_contains="<script>alert")
    s.eq("search survives SQL metacharacters", c.get("/api/search?q=" + quote("' OR 1=1 --", safe="")).json()["total"], 0)
    s.ok("search with % matches everything, not an error", c.get("/api/search?q=%25").json()["total"] >= M["counts"]["posts"])


s.guard("search", search)


# ------------------------------------------------------------------ api
def api():
    c = new()
    r = c.get("/api/posts?per_page=10&page=3")
    s.page("api list", r, ctype="json")
    j = r.json()
    s.eq("api list ids", [p["id"] for p in j["data"]], list(range(21, 31)))
    s.ok("api list meta", j["meta"]["current_page"] == 3 and j["meta"]["per_page"] == 10 and j["meta"]["total"] >= M["counts"]["posts"], j["meta"])
    s.ok("api list rows carry author, tags and counts", all(p["author"]["name"] and p["tags"] and "comments_count" in p for p in j["data"]))
    r = c.get("/api/posts?per_page=100")
    s.page("api list, 100 rows", r, ctype="json", min_bytes=50000)
    s.eq("api per_page is capped", len(c.get("/api/posts?per_page=5000").json()["data"]), 100)
    for pid in (1, 1000, 2000):
        r = c.get(f"/api/posts/{pid}")
        s.page(f"api detail {pid}", r, ctype="json")
        s.eq(f"api detail {pid} equals the stock PHP's golden", sha(canonical(r.json())), M["golden"][f"api_post_{pid}"])
    r = c.get("/api/posts/999999", headers={"Accept": "application/json"})
    s.page("api detail 404", r, status=404, ctype="json")
    r = c.get("/api/golden")
    s.page("golden endpoint", r, ctype="json")
    live = r.json()
    for name, want in M["golden"].items():
        s.eq(f"golden {name}", live.get(name), want)
    s.ok("golden: no unexpected keys", sorted(live) == sorted(M["golden"]))


s.guard("api", api)


# ------------------------------------------------------------ sessions
def login_flow(kind, label=None):
    u = M["users"][kind]
    tag = label or kind
    c = new()
    r = c.get("/login")
    s.page(f"login form ({tag})", r, contains=['id="login-form"', 'name="_token"'])
    token = token_of(r.text)
    r = c.request("POST", "/login", data={"email": u["email"], "password": "wrong"}, follow=False)
    s.eq(f"login without CSRF token is refused ({tag})", r.status, 419)
    r = c.post("/login", {"_token": token, "email": u["email"], "password": "wrong-" + RUN})
    s.page(f"wrong password shows the error ({tag})", r, contains=["These credentials do not match", esc(u["email"])])
    r = c.post("/login", {"_token": token_of(r.text), "email": u["email"], "password": u["password"]})
    s.page(f"login redirects to the dashboard ({tag})", r, contains=['id="whoami"', esc(u["email"]), esc(u["name"])])
    s.ok(f"dashboard reports the hash algorithm ({tag})", f'id="hash-algo">{kind}<' in r.text)
    s.ok(f"session id was regenerated ({tag})", c.cookies.get(SESSION_COOKIE) is not None)
    return c


def sessions():
    a = login_flow("bcrypt")
    if SECOND:
        b = login_flow(SECOND)
    else:
        s.skip("login with an argon2 user", "PHP or Laravel of this set has no argon2; every user is bcrypt")
        b = login_flow("bcrypt", "bcrypt, second session")
    # logout, then the dashboard bounces to the login form
    r = a.get("/dashboard")
    token = token_of(r.text)
    r = a.post("/logout", {"_token": token})
    s.page("logout lands on home", r, contains="Latest posts")
    r = a.request("GET", "/dashboard", follow=False)
    s.ok("dashboard after logout redirects to /login", r.status == 302 and r.header("location", "").endswith("/login"), (r.status, r.header("location")))
    r = new().request("GET", "/dashboard/posts/create", follow=False)
    s.ok("guest cannot open the post form", r.status == 302 and r.header("location", "").endswith("/login"))
    r = new().request("POST", "/dashboard/posts", data={"title": "x"}, follow=False)
    s.ok("guest POST is refused before validation (CSRF first)", r.status in (302, 419), r.status)

    # The session the stock PHP wrote at fixture build time, over the real form.
    stock = new()
    sc = M["session_cookie"]
    stock.cookies[sc["name"]] = sc["value"]
    r = stock.get("/dashboard")
    s.page("stock-written session is still logged in", r, contains=['id="whoami"', esc(M["users"]["bcrypt"]["email"])])
    tok = token_of(r.text)
    s.ok("stock session's CSRF token is served", len(tok) == 40, tok)
    title = "Сессия из стока " + RUN
    r = stock.post("/dashboard/posts", {"_token": tok, "title": title, "body": "Запись создана сессией, записанной другим PHP. " * 2})
    s.page("form POST with the stock session's token", r, contains=[esc(title), "Post created"])

    # redis-backed sessions under their own cookie
    rc = new()
    hits = [rc.get("/redis-session/hit").json() for _ in range(3)]
    s.eq("redis session counter", [h["hits"] for h in hits], [1, 2, 3])
    s.ok("redis session driver in use", hits[0]["driver"] == "redis" and hits[0]["id_length"] == 40, hits[0])
    s.ok("redis session has its own cookie", "apptest_redis_session" in rc.cookies and SESSION_COOKIE not in rc.cookies, list(rc.cookies))
    rc.get("/redis-session/flash?v=" + RUN)
    first = rc.get("/redis-session/read").json()
    s.eq("flash data arrives once", first["note"], "flash ✓ " + RUN)
    s.eq("session payload survives (unicode array)", first["payload"], {"текст": "日本語 😀", "n": 3})
    s.eq("flash data is gone on the next request", rc.get("/redis-session/read").json()["note"], None)
    other = new()
    s.eq("sessions are isolated", other.get("/redis-session/hit").json()["hits"], 1)
    return b


authed = s.guard("sessions", sessions)


# ------------------------------------------------------- authed content
def content(c):
    r = c.get("/dashboard/posts/create")
    s.page("new post form", r, contains=['id="post-form"', 'name="tags[]"', "New post"])
    tok = token_of(r.text)
    tag_ids = re.findall(r'name="tags\[\]" value="(\d+)"', r.text)[:2]
    title = f"Тест 日本語 حروف {RUN}"
    body = "Тело записи с юникодом: Привет, 世界, مرحبا. " * 3
    r = c.post("/dashboard/posts", {"_token": tok, "title": title, "body": body, "tags[]": tag_ids})
    s.page("create post redirects to the new post", r, contains=[esc(title), "Post created", 'class="body"'])
    pid = int(re.search(r'data-post-id="(\d+)"', r.text).group(1))
    j = new().get(f"/api/posts/{pid}").json()
    s.ok("created post reads back through the API", j["title"] == title and j["body"] == body.strip() and sorted(t["id"] for t in j["tags"]) == sorted(map(int, tag_ids)), j["title"])
    s.eq("created post has no comments yet", j["comments_count"], 0)
    s.page("created post is first on the home page", new().get("/"), contains=esc(title))

    # validation: redirect back with errors and old input
    r = c.get("/dashboard/posts/create")
    r = c.post("/dashboard/posts", {"_token": token_of(r.text), "title": "", "body": "too short"})
    s.page("validation errors come back on the form", r, contains=['class="error"', "The title field is required.", f"The body {FIELD}must be at least 20 characters", "too short"])
    r = c.get("/dashboard/posts/create")
    tok = token_of(r.text)
    r = c.post("/dashboard/posts", {"_token": tok, "title": "x" * 300, "body": "y" * 30, "tags[]": ["999999"]})
    s.page("max length and unknown tag id are rejected", r, contains=[MAXMSG + " 255 characters", "The selected tags.0 is invalid"])
    r = c.request("POST", "/dashboard/posts", data={"_token": tok, "title": "", "body": ""}, headers={"Accept": "application/json"}, follow=False)
    s.eq("JSON validation failure is a 422", r.status, 422)
    errs = r.json().get("errors", {})
    s.ok("422 body lists the fields", "title" in errs and "body" in errs, errs)
    r = c.request("POST", "/dashboard/posts", data={"title": "no token", "body": "z" * 30}, follow=False)
    s.page("missing CSRF token is Laravel's 419", r, status=419, contains=E419)


if authed:
    s.guard("authed content", content, authed)


# -------------------------------------------------------------- comments
def comments():
    c = new()
    post3 = M["posts"]["by_lang"]["ja"]
    r = c.get("/posts/" + post3["slug"])
    tok = token_of(r.text)
    before = int(re.search(r'data-count="(\d+)"', r.text).group(1))
    r = c.post(f"/posts/{post3['slug']}/comments", {"_token": tok, "author": "", "body": "x"})
    s.page("empty comment is rejected", r, contains=["The author field is required.", f"The body {FIELD}must be at least 3 characters"])
    for n in range(6):
        text = f"Комментарий {n} {RUN} 日本語 😀 مرحبا"
        r = c.post(f"/posts/{post3['slug']}/comments", {"_token": token_of(r.text), "author": f"Автор {n}", "body": text})
        if n == 0:
            s.page("commenting redirects back with a status message", r, contains=["Comment added", 'id="comment-form"'])
    r = c.get("/posts/" + post3["slug"])
    after = int(re.search(r'data-count="(\d+)"', r.text).group(1))
    s.eq("comment count grew by six", after - before, 6)
    last = math.ceil(after / 10)
    r = c.get(f"/posts/{post3['slug']}?cpage={last}")
    s.page("comment pagination (last cpage)", r, contains=[esc(f"Комментарий 5 {RUN} 日本語 😀 مرحبا"), "cpage="])
    both = r.text + (c.get(f"/posts/{post3['slug']}?cpage={last - 1}").text if last > 1 else "")
    s.ok("all six new comments are listed, unicode intact", all(esc(f"Комментарий {n} {RUN} 日本語 😀 مرحبا") in both for n in range(6)))
    s.ok("emoji survives the utf8mb4 round trip", "😀" in r.text)


s.guard("comments", comments)


# --------------------------------------------------------------- uploads
def uploads(c):
    tok = token_of(c.get("/dashboard/upload").text)
    s.page("upload form", c.get("/dashboard/upload"), contains='enctype="multipart/form-data"')
    for label, w, h, alpha in (("rgb 64x48", 64, 48, False), ("rgba 100x40", 100, 40, True)):
        data = png(w, h, alpha)
        r = c.request("POST", "/dashboard/upload", data={"_token": tok}, files={"image": (f"{label.split()[0]}.png", data, "image/png")}, headers={"Accept": "application/json"})
        s.page(f"upload {label}", r, ctype="json")
        j = r.json()
        th = max(1, round(h * 32 / w))
        s.ok(f"{label}: original dimensions", (j["original"]["width"], j["original"]["height"], j["original"]["mime"]) == (w, h, "image/png"), j["original"])
        s.ok(f"{label}: GD jpeg", (j["gd_jpeg"]["width"], j["gd_jpeg"]["height"], j["gd_jpeg"]["mime"]) == (32, th, "image/jpeg"), j["gd_jpeg"])
        if "gd_webp" in j:
            s.ok(f"{label}: GD webp", (j["gd_webp"]["width"], j["gd_webp"]["height"]) == (32, th), j["gd_webp"])
        else:
            s.skip(f"{label}: GD webp", "imagewebp() not available")
        s.ok(f"{label}: GD rotate", (j["gd_rotated"]["width"], j["gd_rotated"]["height"]) == (h, w), j["gd_rotated"])
        ih = max(1, round(h * 24 / w))
        s.ok(f"{label}: Imagick jpeg", (j["imagick_jpeg"]["width"], j["imagick_jpeg"]["height"]) == (24, ih), j["imagick_jpeg"])
        s.ok(f"{label}: Imagick webp", (j["imagick_webp"]["width"], j["imagick_webp"]["height"], j["imagick_webp"]["mime"]) == (24, ih, "image/webp"), j["imagick_webp"])
        s.ok(f"{label}: Imagick rotate", (j["imagick_rotated"]["width"], j["imagick_rotated"]["height"]) == (ih, 24), j["imagick_rotated"])
        s.ok(f"{label}: Imagick reads GD's jpeg", (j["imagick_reads_gd"]["width"], j["imagick_reads_gd"]["height"], j["imagick_reads_gd"]["format"]) == (32, th, "JPEG"), j["imagick_reads_gd"])
        s.ok(f"{label}: stored through Storage", sorted(j["files"]) == sorted(["original.png", "gd.jpg", "im.jpg", "im.webp"] + (["gd.webp"] if "gd_webp" in j else [])), j["files"])
        # what was stored is served back, and parses in a decoder that is not ours
        r = new().get(f"/media/{j['id']}/gd.jpg")
        s.page(f"{label}: stored jpeg is served", r, ctype="image/jpeg")
        s.eq(f"{label}: served jpeg dimensions (python parse)", jpeg_size(r.body), (32, th))
        r = new().get(f"/media/{j['id']}/im.webp")
        s.page(f"{label}: stored webp is served", r, ctype="image/webp")
        s.eq(f"{label}: served webp dimensions (python parse)", webp_size(r.body), (24, ih))
        if label.startswith("rgb"):
            jpg = new().get(f"/media/{j['id']}/gd.jpg").body
    r = c.request("POST", "/dashboard/upload", data={"_token": tok}, files={"image": ("again.jpg", jpg, "image/jpeg")}, headers={"Accept": "application/json"})
    s.page("re-upload of the generated jpeg", r, ctype="json")
    j = r.json()
    s.ok("jpeg in, jpeg recognised", j["original"]["mime"] == "image/jpeg" and j["original"]["width"] == 32, j["original"])
    s.ok("imagick thumbnail of a small jpeg", j["imagick_jpeg"]["width"] == 24, j["imagick_jpeg"])
    for name, body, mime in (("notes.png", b"not an image at all " * 50, "image/png"), ("doc.pdf", b"%PDF-1.4\n%%EOF\n", "application/pdf"),
                              ("big.png", b"\x89PNG\r\n\x1a\n" + os.urandom(5 * 1024 * 1024), "image/png")):
        r = c.request("POST", "/dashboard/upload", data={"_token": tok}, files={"image": (name, body, mime)}, headers={"Accept": "application/json"}, follow=False)
        s.ok(f"upload of {name} is rejected by validation", r.status == 422, (r.status, r.text[:200]))
    r = c.request("POST", "/dashboard/upload", data={"_token": tok}, headers={"Accept": "application/json"}, follow=False)
    s.eq("upload with no file is a 422", r.status, 422)
    s.page("upload media 404", new().get("/media/999999/gd.jpg"), status=404)
    s.page("upload media only serves known names", new().get(f"/media/{j['id']}/original.png"), status=404)


if authed:
    s.guard("uploads", uploads, authed)


# ----------------------------------------------------------------- cache
def cache_all():
    stores = ["redis", "memcached", "file", "database", "redis_igbinary"]
    if "apcu" in exts:
        stores.append("apc")
    else:
        s.skip("cache: apc store", "apcu is not loaded in this image")

    def one(store):
        c = new()
        tok = f"{RUN}{store}"
        j = feature(f"cache {store}", f"/api/features/cache/{store}/suite?token={tok}", c)
        r = c.request("POST", f"/api/features/cache/{store}?token={tok}", headers={"Accept": "application/json"})
        s.page(f"cache {store}: put", r, ctype="json")
        v = new().get(f"/api/features/cache/{store}?token={tok}").json()["value"]
        s.eq(f"cache {store}: a different worker reads it", v, {"store": store, "text": "Привет 😀 世界", "n": 42})
        c.request("POST", f"/api/features/cache/{store}?token={tok}ttl&ttl=1", headers={"Accept": "application/json"})
        time.sleep(2.2)
        s.eq(f"cache {store}: entry expires after its ttl", new().get(f"/api/features/cache/{store}?token={tok}ttl").json()["value"], None)
        return j

    with ThreadPoolExecutor(len(stores)) as pool:
        list(pool.map(one, stores))


s.guard("cache", cache_all)


# --------------------------------------------------------------- features
def hash_area():
    j = feature("hash", "/api/features/hash")
    if not j:
        return
    m = j["info"]["message"].encode()
    d = j["info"]["digests"]
    want = {
        "md5": hashlib.md5(m).hexdigest(), "sha1": hashlib.sha1(m).hexdigest(), "sha256": hashlib.sha256(m).hexdigest(),
        "sha512": hashlib.sha512(m).hexdigest(), "sha3-256": hashlib.sha3_256(m).hexdigest(), "crc32b": "%08x" % (zlib.crc32(m) & 0xFFFFFFFF),
        "hmac_sha256": hmac.new(b"secret key", m, hashlib.sha256).hexdigest(),
        "pbkdf2_sha256": hashlib.pbkdf2_hmac("sha256", b"password", b"salt", 2000, 32).hex(),
        "blake2b_256": hashlib.blake2b(m, digest_size=32).hexdigest(), "adler32": "%08x" % (zlib.adler32(m) & 0xFFFFFFFF),
        "crc32_int": zlib.crc32(m) & 0xFFFFFFFF,
    }
    for k, v in want.items():
        if k in d:  # sha3 and blake2b need PHP 7.1 and 7.2
            s.eq(f"hash {k} matches Python", d[k], v)


def crypto_area():
    j = feature("crypto", "/api/features/crypto")
    if j:
        print(f"info: {j['info']['openssl']} / libsodium {j['info']['sodium']}")


def intl_area():
    j = feature("intl", "/api/features/intl")
    if j:
        print(f"info: ICU {j['info']['icu']} CLDR {j['info']['cldr']} decimal={j['info']['decimal']!r} eur_de={j['info']['eur_de']!r} translit={j['info']['translit']!r}")


def xml_area():
    j = feature("xml", "/api/features/xml")
    if j:
        if not j["info"]["xsl"]:
            s.skip("xml: XSL transform", "xsl extension not loaded")


def archive_area():
    j = feature("archive", "/api/features/archive")
    if not j:
        return
    i = j["info"]
    data = "".join(hashlib.md5(f"chunk{n}".encode()).hexdigest() for n in range(16384)).encode()
    s.eq("archive: data digest equals Python's", i["data_sha256"], hashlib.sha256(data).hexdigest())
    s.eq("archive: python gunzips PHP's gzip", gzip.decompress(base64.b64decode(i["gzip_b64"])).decode(), i["sample"])
    zf = zipfile.ZipFile(io.BytesIO(base64.b64decode(i["zip_b64"])))
    s.ok("archive: python opens PHP's zip, UTF-8 names intact", zf.namelist() == ["файл.txt", "日本語/テスト.txt", "emoji-😀.txt", "big.bin", "empty/"], zf.namelist())
    s.ok("archive: zip CRCs check out", zf.testzip() is None)
    s.eq("archive: zip member content", zf.read("日本語/テスト.txt").decode(), "テスト")
    s.eq("archive: zip big member digest", hashlib.sha256(zf.read("big.bin")).hexdigest(), i["data_sha256"])
    print(f"info: zstd={i.get('zstd')} brotli={i.get('brotli')} lz4={i.get('lz4')}")
    if not i.get("brotli"):
        s.skip("archive: brotli round trip", "brotli extension not loaded (opt-in)")
    if not i.get("zstd"):
        s.skip("archive: zstd round trip", i.get("zstd_why", "zstd extension not loaded"))


def gmp_area():
    r = new().get("/api/features/gmp")
    s.page("feature gmp", r, ctype="json")
    j = r.json()
    if not j["loaded"]:
        s.skip("gmp: big integer arithmetic", "gmp extension not loaded")
        return
    a, b = 123456789012345678901234567890, 987654321098765432109876543210
    s.eq("gmp pow", j["pow"], str(3 ** 200))
    s.eq("gmp fact", j["fact"], str(math.factorial(60)))
    s.eq("gmp powm", j["powm"], str(pow(2, a, 1000000007)))
    s.eq("gmp gcd", j["gcd"], str(math.gcd(a, b)))
    s.eq("gmp sqrt", j["sqrt"], str(math.isqrt(10 ** 38)))
    s.eq("gmp div", j["div"], str(10 ** 30 // 7))
    s.eq("gmp prime (2^127-1)", j["prime"], True)
    s.eq("bcmath mul matches Python", j["bcmath_mul"], str(a * b))


def area_parallel():
    jobs = [hash_area, crypto_area, intl_area, xml_area, archive_area, gmp_area,
            lambda: feature("text", "/api/features/text"),
            lambda: feature("misc", f"/api/features/misc?token={RUN}misc"),
            lambda: feature("db", f"/api/features/db?token={RUN}db")]
    names = ["hash", "crypto", "intl", "xml", "archive", "gmp", "text", "misc", "db"]
    with ThreadPoolExecutor(len(jobs)) as pool:
        futures = [pool.submit(lambda f=f: f()) for f in jobs]
        for name, fut in zip(names, futures):
            try:
                fut.result()
            except Exception as e:  # noqa: BLE001
                s.ok(f"feature {name}", False, f"{type(e).__name__}: {e}")


s.guard("features", area_parallel)


# ----------------------------------------------------------------- queue
def queue():
    c = new()
    tok = RUN + "queue"
    r = c.request("POST", f"/api/features/queue/dispatch?token={tok}", headers={"Accept": "application/json"})
    s.page("dispatch sync + queued job", r, ctype="json")
    j = r.json()
    s.eq("sync job ran inside the request", j["sync_recorded"], 1)
    s.eq("queued job waits on the database queue", j["pending"], 1)
    r = c.request("POST", "/api/features/queue/drain?queue=web", headers={"Accept": "application/json"})
    s.page("queue:work drains the queue under fpm", r, ctype="json")
    d = r.json()
    s.ok("worker exited cleanly and left nothing behind", d["exit"] == 0 and d["left"] == 0, d)
    s.ok("failing job landed in failed_jobs", d["failed"] >= 1, d)
    log = c.get(f"/api/features/queue/status?token={tok}").json()["log"]
    s.eq("job side effects recorded", sorted(x["kind"] for x in log), ["queued", "sync"])
    queued = json.loads([x for x in log if x["kind"] == "queued"][0]["payload"])
    s.ok("model, Carbon and array survived the payload", queued["post"] == 1 and queued["when"] == "2024-05-06T07:08:09Z" and queued["extra"] == {"текст": "日本語 😀", "n": [1, 2]}, queued)
    s.ok("job ran on the fpm sapi", queued["sapi"].startswith("fpm"), queued["sapi"])
    # the job the stock PHP queued at build time
    c.request("POST", "/api/features/queue/drain?queue=stock", headers={"Accept": "application/json"})
    log = c.get("/api/features/queue/stock").json()["log"]
    s.eq("stock-queued job was handled (once, across configs)", len(log), 1)
    if log:
        st = json.loads(log[0]["payload"])
        s.ok("stock-serialized job payload decoded", st["post"] == 2 and st["when"] == "2024-01-02T03:04:05Z" and st["extra"] == {"ключ": "値 😀", "list": [1, 2, 3]}, st)


s.guard("queue", queue)


# ----------------------------------------------------------- concurrency
def burst():
    slugs = [M["posts"]["first"]["slug"], M["posts"]["last"]["slug"]] + [p["slug"] for p in M["posts"]["by_lang"].values()]
    paths = []
    for n in range(50):
        paths.append(["/", f"/?page={n % 20 + 1}", "/posts/" + slugs[n % len(slugs)], f"/api/posts/{n * 37 % 2000 + 1}",
                      "/search?q=" + quote("server", safe=""), "/api/posts?per_page=20&page=%d" % (n % 50 + 1)][n % 6])

    def hit(p):
        r = new().get(p)
        return p, r.status, r.error_marker(), len(r.body)

    with ThreadPoolExecutor(50) as pool:
        out = list(pool.map(hit, paths))
    bad = [o for o in out if o[1] != 200 or o[2] or o[3] < 100]
    s.ok("50 parallel GETs all succeed", not bad, bad[:3])

    def cached(n):
        r = new().get(f"/api/features/cache/{'redis' if n % 2 else 'file'}/suite?token={RUN}b{n}")
        return r.status == 200 and r.json()["ok"]

    with ThreadPoolExecutor(50) as pool:
        res = list(pool.map(cached, range(50)))
    s.ok("50 parallel cache suites (redis + file) all pass", all(res), res.count(False))

    post = M["posts"]["by_lang"]["zh"]
    before = int(re.search(r'data-count="(\d+)"', new().get("/posts/" + post["slug"]).text).group(1))

    def comment(n):
        c = new()
        tok = token_of(c.get("/posts/" + post["slug"]).text)
        r = c.post(f"/posts/{post['slug']}/comments", {"_token": tok, "author": f"Параллельный {n}", "body": f"Одновременный комментарий {n} {RUN}"}, follow=False)
        return r.status

    with ThreadPoolExecutor(30) as pool:
        codes = list(pool.map(comment, range(30)))
    s.ok("30 parallel comment POSTs (session + CSRF + insert) all redirect", codes.count(302) == 30, codes)
    after = int(re.search(r'data-count="(\d+)"', new().get("/posts/" + post["slug"]).text).group(1))
    s.eq("every concurrent comment was stored", after - before, 30)

    def login(n):
        kind = "bcrypt" if n % 2 or not SECOND else SECOND
        u = M["users"][kind]
        c = new()
        tok = token_of(c.get("/login").text)
        r = c.post("/login", {"_token": tok, "email": u["email"], "password": u["password"]})
        return u["email"] in r.text

    with ThreadPoolExecutor(20) as pool:
        res = list(pool.map(login, range(20)))
    s.ok("20 parallel logins (" + ("bcrypt/" + SECOND if SECOND else "bcrypt") + ")", all(res), res.count(False))
    s.ok("golden values are stable after the burst", new().get("/api/golden").json() == M["golden"])


s.guard("burst", burst)

# a last look at the workers: nothing above may have left the app unable to answer
s.page("app still healthy after the suite", new().get("/up"), min_bytes=20)
s.finish()
