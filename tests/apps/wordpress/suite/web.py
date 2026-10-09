"""WordPress + WooCommerce over HTTP, against the fixture behind nginx.

Additive by construction: it runs twice on one stack (default, then
hardened), so everything it writes carries a per-run suffix, is never
deleted, and never touches what the totals in the manifest count (published
posts, products, seeded orders). Drafts, comments, media, users and orders
are added freely; assertions on those use >=.
"""
import hashlib
import json
import os
import re
import struct
import sys
import uuid
import zlib
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal
from urllib.parse import quote, urlsplit

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
import apptest  # noqa: E402

args = apptest.parse_args("wordpress")
M = args.manifest_data
W = M["woo"]
s = apptest.Suite("wordpress-http", args)
RUN = uuid.uuid4().hex[:8]
USERS = {u["login"]: u for u in M["users"]}
POSTS_PER_PAGE = 10
# Cart and Checkout are blocks on shops created by WooCommerce 8.3+, shortcode pages before.
BLOCKS = bool(W.get("checkout_blocks"))
CLASSIC_CHECKOUT = int(W["version"].split(".")[0]) < 7
HPOS = W.get("hpos") == "yes"


def vt(v):
    return tuple(int(x) for x in re.findall(r"\d+", v)[:2])


# What the WordPress and WooCommerce releases under test have. Every gate below is a version
# threshold, named after the release that added the feature, so the newer sets keep asserting all of it.
WP = vt(M["app_version"])
WOO = vt(W["version"])


def since(version):
    return WP >= vt(version)


# The block editor is 5.0; before it every edit screen is the classic one (and the Classic Editor plugin is set to leave the block editor alone).
EDITOR_DEFAULT = "block-editor" if since("5.0") else "postdivrich"
BLOCK_THEME = since("5.9")          # Twenty Twenty-Two, the first block theme bundled as the default
TITLE = "wp-block-post-title" if BLOCK_THEME else "entry-title"
CONTENT = "wp-block-post-content" if BLOCK_THEME else "entry-content"
COMMENT = "wp-block-comment" if since("6.0") else "comment-body"   # 6.0 added the comments query loop; 5.9's block theme still prints the classic list
SITEMAPS = since("5.5")             # core sitemaps (wp-sitemap.xml)
STORE_API = WOO >= (6, 0)           # wc/store/v1 in WooCommerce core
WC_ADMIN = WOO >= (4, 0)            # wc-admin (the analytics / customers SPA) merged into WooCommerce
PLUGINS = M["plugins"]
# Orders live on their own admin screens with HPOS, and are plain posts before it.
ORDER_LIST = "/wp-admin/admin.php?page=wc-orders" if HPOS else "/wp-admin/edit.php?post_type=shop_order"
ORDER_EDIT = "/wp-admin/admin.php?page=wc-orders&action=edit&id={id}" if HPOS else "/wp-admin/post.php?post={id}&action=edit"


def client():
    return apptest.Client(args.base, args.host)


# WordPress localizes this sentence into every admin page that loads
# wp-ajax-response.js, and apptest.py's generic error markers include it.
BENIGN = b"An error occurred while processing your request. Please try again later."


def scrub(resp):
    resp.body = resp.body.replace(BENIGN, b"[wp-ajax broken message]")
    return resp


def page(name, resp, **kw):
    return s.page(name, scrub(resp), **kw)


def pages_for(count):
    return -(-count // POSTS_PER_PAGE)


def login(name, password=None):
    c = client()
    u = USERS[name]
    r = c.get("/wp-login.php")
    r = c.post("/wp-login.php", data={
        "log": u["login"], "pwd": password or u["password"], "wp-submit": "Log In",
        "redirect_to": f"http://{args.host}/wp-admin/", "testcookie": "1",
    })
    if not any(k.startswith("wordpress_logged_in_") for k in c.cookies):
        raise RuntimeError(f"login as {name} set no auth cookie (status {r.status})")
    return c, r


def landed(name, resp):
    """Where a login ends up: the dashboard, or, for roles that cannot use it,
    the shop's account page."""
    resp = scrub(resp)
    good = resp.status == 200 and ("wpadminbar" in resp.text or "woocommerce-MyAccount-navigation" in resp.text)
    return s.ok(f"{name} [{resp.url}]", good and resp.error_marker() is None, f"status {resp.status}, {len(resp.body)} bytes, marker {resp.error_marker()}")


def rest_nonce(c):
    r = c.get("/wp-admin/admin-ajax.php?action=rest-nonce")
    if r.status != 200 or not re.fullmatch(r"[0-9a-f]{10}", r.text.strip()):
        raise RuntimeError(f"rest-nonce: {r.status} {r.text[:80]!r}")
    return r.text.strip()


def api(c, method, path, nonce=None, **kw):
    headers = kw.pop("headers", {})
    if nonce:
        headers["X-WP-Nonce"] = nonce
    r = c.request(method, path, headers=headers, **kw)
    try:
        body = r.json()
    except ValueError:
        body = None
    return r, body


def canon(v):
    """The same canonical form fixture/golden.php hashes: sorted keys, no
    whitespace, unescaped unicode; an empty object and an empty array are one
    thing on the PHP side."""
    if isinstance(v, dict):
        return [] if not v else {k: canon(v[k]) for k in sorted(v)}
    if isinstance(v, list):
        return [canon(x) for x in v]
    return v


def canon_json(v):
    return json.dumps(canon(v), ensure_ascii=False, separators=(",", ":"))


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def make_png(width, height):
    """A gradient RGB PNG built from nothing but zlib and struct."""
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        g = y * 255 // height
        rows += bytes(b for x in range(width) for b in ((x * 255 // width) & 255, g, (x + y) & 255))
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b""))


def image_size(data):
    """(width, height) of a PNG, GIF, JPEG or WebP from its header, or None."""
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", data[16:24])
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return struct.unpack("<HH", data[6:10])
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        if data[12:16] == b"VP8 ":
            w, h = struct.unpack("<HH", data[26:30])
            return w & 0x3FFF, h & 0x3FFF
        if data[12:16] == b"VP8L":
            bits = struct.unpack("<I", data[21:25])[0]
            return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
        if data[12:16] == b"VP8X":
            return int.from_bytes(data[24:27], "little") + 1, int.from_bytes(data[27:30], "little") + 1
    if data[:2] == b"\xff\xd8":
        i = 2
        while i < len(data) - 9:
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                h, w = struct.unpack(">HH", data[i + 5:i + 9])
                return w, h
            i += 2 + struct.unpack(">H", data[i + 2:i + 4])[0]
    return None


def xml_items(resp, tag):
    root = ET.fromstring(resp.body)
    return root, [e for e in root.iter() if e.tag.split("}")[-1] == tag]


# ---------------------------------------------------------------------------
# Front end

def sec_front():
    c = client()
    home = c.get("/")
    page("home", home, contains=["Apptest Journal", TITLE], min_bytes=20000)
    stickies = M["posts"]["sticky"]
    if not BLOCK_THEME or since("6.0"):
        s.ok("home: sticky posts are on the first page", any(st["title"] in home.text for st in stickies))
    else:
        s.skip("home: sticky posts are on the first page", "the 5.9 Query Loop of the default block theme does not float them (measured on 5.9.18)")
    s.ok("home: paginated links present", "/page/2/" in home.text and f"/page/{pages_for(M['counts']['posts_published'])}/" in home.text)
    last = pages_for(M["counts"]["posts_published"])
    page("home page 2", c.get("/page/2/"), contains=TITLE)
    page("home last page", c.get(f"/page/{last}/"), contains=TITLE)
    page("home past the last page is 404", c.get(f"/page/{last + 1}/"), status=404)
    page("unknown path is 404", c.get("/no-such-page-" + RUN + "/"), status=404)

    for kind in ("plain", "russian", "cjk", "arabic", "hebrew", "emoji", "with_more", "with_image"):
        p = M["posts"][kind]
        r = c.get(p["path"])
        page(f"single post ({kind})", r, contains=[p["title"], CONTENT], min_bytes=8000)
    mc = M["posts"]["most_commented"]
    r = c.get(mc["path"])
    page("single post with comments", r, contains=[COMMENT], min_bytes=20000)
    rendered = re.findall(r'id="comment-\d+"', r.text)
    s.ok("comments rendered on the post page", len(rendered) >= 5, f"{len(rendered)} comments")
    if mc["comments"] > 20:
        r2 = c.get(mc["path"] + "comment-page-2/")
        page("comment page 2", r2, contains='id="comment-')
        s.ok("comment page 2 differs from page 1",
             set(re.findall(r'id="comment-(\d+)"', r.text)).isdisjoint(re.findall(r'id="comment-(\d+)"', r2.text)))
    page("post embed template", c.get(M["posts"]["plain"]["path"] + "embed/"), contains="wp-embed")
    r = c.get(f"/?p={M['posts']['plain']['id']}", follow=False)
    s.ok("?p=ID redirects to the pretty permalink", r.status == 301 and M["posts"]["plain"]["slug"] in (r.header("location") or ""), f"{r.status} {r.header('location')}")
    page("post comment feed", c.get(M["posts"]["most_commented"]["path"] + "feed/"), ctype="xml")

    # Pages: root, child, grandchild.
    for kind in ("root", "child", "grandchild"):
        p = M["pages"][kind]
        page(f"page ({kind})", c.get(p["path"]), contains=CONTENT, min_bytes=6000)
    gp = M["pages"]["grandchild"]
    s.ok("grandchild page lives under its ancestors", gp["path"].count("/") == 4, gp["path"])
    r = c.get(f"/?page_id={gp['id']}", follow=False)
    s.ok("?page_id=ID redirects to the hierarchical permalink", r.status == 301 and (r.header("location") or "").endswith(gp["path"]), f"{r.status} {r.header('location')}")

    # Archives with pagination, counts from the manifest.
    small = M["category_small"]
    page("category archive", c.get(small["path"]), contains=[small["name"], TITLE])
    page("category archive last page", c.get(f"{small['path']}page/{pages_for(small['count'])}/"), contains=TITLE)
    page("category archive past the end is 404", c.get(f"{small['path']}page/{pages_for(small['count']) + 1}/"), status=404)
    page("parent category archive", c.get(M["category"]["path"]), contains=TITLE)
    page("category feed", c.get(small["path"] + "feed/"), ctype="xml")
    t = M["tag"]
    page("tag archive", c.get(t["path"]), contains=TITLE)
    page("tag archive last page", c.get(f"{t['path']}page/{pages_for(t['count'])}/"), contains=TITLE)
    a = M["author"]
    page("author archive", c.get(a["path"]), contains=[TITLE])
    page("author archive last page", c.get(f"{a['path']}page/{pages_for(a['posts'])}/"), contains=TITLE)
    page("author archive past the end is 404", c.get(f"{a['path']}page/{pages_for(a['posts']) + 1}/"), status=404)
    mo = M["month"]
    page("month archive", c.get(mo["path"]), contains=TITLE)
    page("month archive last page", c.get(f"{mo['path']}page/{mo['pages']}/"), contains=TITLE)
    page("month archive past the end is 404", c.get(f"{mo['path']}page/{mo['pages'] + 1}/"), status=404)
    page("year archive", c.get(M["year"]["path"]), contains=TITLE)
    page("day archive", c.get("/2023/01/05/"), contains=TITLE)
    page("date with no posts is 404", c.get("/1999/01/"), status=404)

    # Search, UTF-8 included.
    for key in ("latin", "cyrillic", "cjk", "arabic", "hebrew", "emoji"):
        sr = M["search"][key]
        r = c.get("/?s=" + quote(sr["term"]))
        page(f"search {key}", r, contains=TITLE)
        s.ok(f"search {key}: hits are posts", len(re.findall(r'class="[^"]*' + re.escape(TITLE) + r'[^"]*"', r.text)) >= 2)
    sr = M["search"]["cyrillic"]
    page("search last page", c.get(f"/page/{sr['pages']}/?s=" + quote(sr["term"])), contains=TITLE)
    page("search past the end is 404", c.get(f"/page/{sr['pages'] + 1}/?s=" + quote(sr["term"])), status=404)
    page("pretty search url", c.get("/search/" + quote(M["search"]["latin"]["term"]) + "/"), contains=TITLE)
    r = c.get("/?s=" + quote(M["search"]["none"]["term"]))
    # The no-results text is worded differently in each bundled theme; Twenty Twenty-Two has none (an empty query loop).
    if M["theme"]["slug"] == "twentytwentytwo":
        s.ok("search with no hits lists no posts", r.status == 200 and not re.search(r'class="[^"]*wp-block-post-title[^"]*"', r.text), f"{r.status}")
    else:
        page("search with no hits", r, contains="Sorry, but nothing matched your search terms" if M["theme"]["slug"] == "twentyseventeen" else "nothing was found")
    page("search with markup is escaped", c.get("/?s=" + quote('"><script>alert(1)</script>')), not_contains="<script>alert(1)</script>")

    # Feeds.
    r = c.get("/feed/")
    page("rss2 feed", r, ctype="application/rss+xml", contains="<rss")
    root, items = xml_items(r, "item")
    s.ok("rss2 feed parses with a full page of items", len(items) == 10, f"{len(items)} items")
    s.ok("rss2 feed channel title", root.find("channel/title").text == "Apptest Journal")
    s.ok("rss2 feed carries content:encoded", any(e.tag.endswith("encoded") for e in root.iter()))
    lm = r.header("last-modified")
    if lm:
        r304 = c.get("/feed/", headers={"If-Modified-Since": lm})
        s.ok("rss2 feed answers a conditional GET with 304", r304.status == 304, str(r304.status))
    else:
        s.skip("feed conditional GET", "no Last-Modified header")
    r = c.get("/feed/atom/")
    page("atom feed", r, ctype="application/atom+xml", contains="<feed")
    _, entries = xml_items(r, "entry")
    s.ok("atom feed parses with a full page of entries", len(entries) == 10, f"{len(entries)} entries")
    r = c.get("/feed/rdf/")
    page("rdf feed", r, ctype="xml", contains="rdf:RDF")
    xml_items(r, "item")
    r = c.get("/comments/feed/")
    page("comments feed", r, ctype="application/rss+xml")
    _, items = xml_items(r, "item")
    s.ok("comments feed has items", len(items) >= 1)

    # Sitemaps, robots, static and PHP-served assets.
    if SITEMAPS:
        r = c.get("/wp-sitemap.xml")
        page("sitemap index", r, ctype="xml", contains="wp-sitemap-posts-post-1.xml")
        r = c.get("/wp-sitemap-posts-post-1.xml")
        page("posts sitemap", r, ctype="xml")
        _, urls = xml_items(r, "url")
        s.eq("posts sitemap lists every published post", len(urls), M["counts"]["posts_published"])
        r = c.get("/wp-sitemap-posts-page-1.xml")
        _, urls = xml_items(r, "url")
        s.ok("pages sitemap lists every published page", len(urls) in (M["counts"]["pages"], M["counts"]["pages"] + 1), f"{len(urls)} urls")
        for name in ("users-1", "taxonomies-category-1", "taxonomies-post_tag-1"):
            r = c.get(f"/wp-sitemap-{name}.xml")
            page(f"sitemap {name}", r, ctype="xml")
            xml_items(r, "url")
        page("sitemap stylesheet", c.get("/wp-sitemap.xsl"), ctype="xml")
        page("robots.txt", c.get("/robots.txt"), contains="Sitemap:")
    else:
        s.skip("core sitemaps", "WordPress 5.5 added them")
        page("robots.txt", c.get("/robots.txt"), contains="User-agent")
    page("core script served statically", c.get("/wp-includes/js/jquery/jquery.min.js" if since("5.5") else "/wp-includes/js/jquery/jquery.js"), ctype="javascript", min_bytes=50000)
    for name, path, needle in (("load-scripts.php", "/wp-admin/load-scripts.php?c=1&load%5Bchunk_0%5D=jquery-core,jquery-migrate", b"jQuery"),
                               ("load-styles.php", "/wp-admin/load-styles.php?c=1&dir=ltr&load%5Bchunk_0%5D=dashicons,admin-bar", b"dashicons")):
        r = c.get(path)
        s.ok(f"{name} concatenates its handles", r.status == 200 and needle in r.body and len(r.body) > 5000, f"{r.status} {len(r.body)} bytes")
        r2 = c.get(path, headers={"If-None-Match": r.header("etag") or ""})
        s.ok(f"{name} answers a conditional GET with 304", r2.status == 304, str(r2.status))
    page("install.php refuses to run twice", c.get("/wp-admin/install.php"), contains="Already Installed")
    r = c.get("/wp-admin/admin-ajax.php", headers={})
    s.ok("admin-ajax without an action is 400 '0'", r.status == 400 and r.text.strip() == "0", f"{r.status} {r.text[:40]!r}")
    page("wp-cron.php answers", c.get("/wp-cron.php"), status=200)
    r = c.get("/wp-content/uploads/apptest-mail.log")
    s.ok("uploads directory is served", r.status == 200, str(r.status))
    r = c.get("/.apptest/manifest.json")
    s.ok("fixture bookkeeping is not served", r.status == 404, str(r.status))


# ---------------------------------------------------------------------------
# REST API

def sec_rest():
    c = client()
    r, j = api(c, "GET", "/wp-json/")
    page("REST index", r, ctype="application/json", min_bytes=10000)
    ns = set(j["namespaces"]) if j else set()
    s.ok("REST namespaces: core, oembed, WooCommerce", ({"wp/v2", "oembed/1.0", "wc/v3"} | ({"wc/store/v1"} if STORE_API else set())) <= ns, str(sorted(ns)))
    s.ok("REST index names the site", j and j["name"] == "Apptest Journal")
    r, j = api(c, "GET", "/?rest_route=/wp/v2/types")
    page("REST via ?rest_route=", r, ctype="application/json", contains='"post"')

    total = M["counts"]["posts_published"]
    r, j = api(c, "GET", "/wp-json/wp/v2/posts?per_page=10")
    page("posts list", r, ctype="application/json")
    s.eq("posts list X-WP-Total", r.header("x-wp-total"), str(total))
    s.eq("posts list X-WP-TotalPages", r.header("x-wp-totalpages"), str(pages_for(total)))
    s.ok("posts list has a full page, newest first", j and len(j) == 10 and j[0]["date"] >= j[-1]["date"])
    r, j = api(c, "GET", f"/wp-json/wp/v2/posts?per_page=10&page={pages_for(total) + 1}")
    s.ok("posts list past the end is a 400", r.status == 400 and j and j["code"] == "rest_post_invalid_page_number", f"{r.status}")
    r, j = api(c, "GET", "/wp-json/wp/v2/posts?per_page=100&orderby=date&order=asc")
    s.ok("posts list oldest first starts at post 1", j and j[0]["id"] == M["posts"]["ids"]["1"])
    r, j = api(c, "GET", "/wp-json/wp/v2/posts?sticky=true&per_page=100")
    s.eq("sticky posts", sorted(p["id"] for p in j), sorted(p["id"] for p in M["posts"]["sticky"]))
    r, j = api(c, "GET", f"/wp-json/wp/v2/posts?categories={M['category_small']['id']}&per_page=1")
    s.eq("posts in a category", r.header("x-wp-total"), str(M["category_small"]["count"]))
    r, j = api(c, "GET", f"/wp-json/wp/v2/posts?tags={M['tag']['id']}&per_page=1")
    s.eq("posts with a tag", r.header("x-wp-total"), str(M["tag"]["count"]))
    r, j = api(c, "GET", f"/wp-json/wp/v2/posts?author={M['author']['id']}&per_page=1")
    s.eq("posts by an author", r.header("x-wp-total"), str(M["author"]["posts"]))
    r, j = api(c, "GET", "/wp-json/wp/v2/posts?after=2024-03-01T00:00:00&before=2024-04-01T00:00:00&per_page=1")
    s.eq("posts in a date range", r.header("x-wp-total"), str(M["month"]["count"]))
    for key in ("latin", "cyrillic", "cjk", "arabic", "hebrew", "emoji", "none"):
        sr = M["search"][key]
        r, j = api(c, "GET", "/wp-json/wp/v2/posts?per_page=1&search=" + quote(sr["term"]))
        s.eq(f"REST search {key} total", r.header("x-wp-total"), str(sr["rest_total"]))
    p = M["posts"]["russian"]
    r, j = api(c, "GET", "/wp-json/wp/v2/posts?slug=" + p["slug"])
    s.ok("posts by (percent-encoded UTF-8) slug", j and len(j) == 1 and j[0]["id"] == p["id"] and j[0]["title"]["rendered"] == p["title"])

    # Single post against the value the stock PHP produced.
    g = M["golden"]["rest_post"]
    r, j = api(c, "GET", f"/wp-json/wp/v2/posts/{g['id']}")
    page("single post", r, ctype="application/json")
    if j:
        j.pop("modified", None)
        j.pop("modified_gmt", None)
        # Yoast SEO adds its head to every REST post; that is its own output (checked on the page itself), not core's.
        yoast = {k: j.pop(k) for k in ("yoast_head", "yoast_head_json") if k in j}
        got = sha(canon_json(j))
        s.ok("single post matches golden", got == g["sha256"], f"expected {g['sha256']}, got {got}; keys {sorted(j)}; yoast fields {sorted(yoast)}")
        s.ok("single post: registered custom fields exposed", set(j["meta"]) >= {"apptest_rating", "apptest_source"}, str(j["meta"]))
    g = M["golden"]["rest_render"]
    r, j = api(c, "GET", f"/wp-json/wp/v2/posts/{g['id']}")
    if j:
        s.eq("kses/texturize/blocks rendering matches golden",
             sha(j["content"]["rendered"] + "\n--\n" + j["excerpt"]["rendered"] + "\n--\n" + j["title"]["rendered"]), g["sha256"])
        s.ok("rendering: texturize ran, the raw HTML block kept its script (author has unfiltered_html)", "&#8220;Quoted&#8221;" in j["content"]["rendered"] and "&#215;" in j["content"]["rendered"] and "<script" in j["content"]["rendered"])
    r, j = api(c, "GET", f"/wp-json/wp/v2/posts/{M['posts']['with_more']['id']}?_embed=1")
    s.ok("_embed brings author and terms", j and "author" in j.get("_embedded", {}) and "wp:term" in j["_embedded"], str(list(j.get("_embedded", {}))) if j else "")

    r, j = api(c, "GET", "/wp-json/wp/v2/categories?per_page=100&orderby=id&order=asc")
    s.eq("categories X-WP-Total", r.header("x-wp-total"), str(M["counts"]["categories"]))
    rows = [[t["id"], t["slug"], t["name"], t["count"], t["parent"]] for t in j]
    s.eq("category counts match golden", sha(json.dumps(rows, ensure_ascii=False, separators=(",", ":"))), M["golden"]["categories"]["sha256"])
    r, j = api(c, "GET", "/wp-json/wp/v2/tags?per_page=100")
    s.eq("tags X-WP-Total", r.header("x-wp-total"), str(M["counts"]["tags"]))
    r, j = api(c, "GET", "/wp-json/wp/v2/users")
    page("users list (anonymous)", r, ctype="application/json")
    s.ok("users list shows authors only", j and all("email" not in u for u in j) and len(j) >= 1)
    r, j = api(c, "GET", "/wp-json/wp/v2/users/me")
    s.ok("users/me needs auth", r.status == 401, str(r.status))
    r, j = api(c, "GET", f"/wp-json/wp/v2/comments?post={M['posts']['most_commented']['id']}&per_page=100")
    s.eq("comments of the busiest post", r.header("x-wp-total"), str(M["posts"]["most_commented"]["comments"]))
    r, j = api(c, "GET", "/wp-json/wp/v2/pages?per_page=100")
    s.eq("pages X-WP-Total", r.header("x-wp-total"), str(M["counts"]["pages"]))
    r, j = api(c, "GET", f"/wp-json/wp/v2/pages/{M['pages']['grandchild']['id']}")
    s.ok("page hierarchy: grandchild has a parent chain", j and j["parent"] != 0 and j["link"].endswith(M["pages"]["grandchild"]["path"]))
    r, j = api(c, "GET", "/wp-json/wp/v2/media?per_page=100")
    s.ok("media list", r.status == 200 and int(r.header("x-wp-total") or 0) >= M["counts"]["attachments"] - 1, r.header("x-wp-total"))
    mimes = {}
    for m in j or []:
        mimes.setdefault(m["mime_type"], m)
    s.ok("seeded media covers jpeg, png and gif", {"image/jpeg", "image/png", "image/gif"} <= set(mimes), str(sorted(mimes)))
    for mime, m in mimes.items():
        sizes = m["media_details"].get("sizes", {})
        s.ok(f"seeded {mime}: thumbnails were generated", "thumbnail" in sizes and "medium" in sizes, str(list(sizes)))
        thumb = c.get(urlsplit(sizes["thumbnail"]["source_url"]).path) if "thumbnail" in sizes else None
        if thumb is not None:
            s.ok(f"seeded {mime}: thumbnail is a valid image of the recorded size",
                 thumb.status == 200 and image_size(thumb.body) == (sizes["thumbnail"]["width"], sizes["thumbnail"]["height"]),
                 f"{thumb.status} {image_size(thumb.body)}")
    page("types", c.get("/wp-json/wp/v2/types"), ctype="application/json")
    page("taxonomies", c.get("/wp-json/wp/v2/taxonomies"), ctype="application/json")
    if since("5.0"):
        page("search endpoint", c.get("/wp-json/wp/v2/search?search=" + quote("лиса")), ctype="application/json")
    else:
        s.skip("REST search endpoint", "WordPress 5.0 added /wp/v2/search")
    r, j = api(c, "POST", "/wp-json/wp/v2/posts", json_body={"title": "anon"})
    s.ok("anonymous create is refused", r.status == 401 and j["code"] == "rest_cannot_create", str(r.status))

    # oEmbed, both formats.
    plain = M["posts"]["plain"]
    permalink = f"http://{args.host}{plain['path']}"
    r, j = api(c, "GET", "/wp-json/oembed/1.0/embed?url=" + quote(permalink, safe=""))
    page("oEmbed (json)", r, ctype="application/json")
    # Yoast SEO appends the site name to the title it prints, oEmbed's included.
    s.ok("oEmbed describes the post", j and j["type"] == "rich" and "<iframe" in j["html"] and (j["title"] == plain["title"] or ("wordpress-seo" in PLUGINS and j["title"] == plain["title"] + " - Apptest Journal")), str(j)[:200])
    r = c.get("/wp-json/oembed/1.0/embed?format=xml&url=" + quote(permalink, safe=""))
    page("oEmbed (xml)", r, ctype="xml", contains="<oembed>")
    ET.fromstring(r.body)
    r, j = api(c, "GET", "/wp-json/oembed/1.0/embed?url=" + quote(f"http://{args.host}/nope-{RUN}/", safe=""))
    s.ok("oEmbed of a missing post is 404", r.status == 404, str(r.status))
    r = c.get("/?rest_route=/oembed/1.0/embed&url=" + quote(permalink, safe=""))
    s.ok("oEmbed via ?rest_route=", r.status == 200)

    # WooCommerce's Store API is public.
    if not STORE_API:
        s.skip("Store API", f"WooCommerce {W['version']} predates wc/store/v1 (in core from 6.0)")
        return
    r, j = api(c, "GET", "/wp-json/wc/store/v1/products?per_page=5")
    page("Store API products", r, ctype="application/json")
    s.eq("Store API product total", r.header("x-wp-total"), str(M["counts"]["products"]))
    ss = W["simple_sample"]
    r, j = api(c, "GET", f"/wp-json/wc/store/v1/products/{ss['id']}")
    s.ok("Store API single product", j and j["sku"] == ss["sku"] and j["name"] == ss["name"] and j["prices"]["price"] == str(int(Decimal(ss["price"]) * 100)), str(j)[:200] if j else str(r.status))
    vs = W["variable_sample"]
    r, j = api(c, "GET", f"/wp-json/wc/store/v1/products/{vs['id']}")
    s.ok("Store API variable product lists its variations", j and j["type"] == "variable" and len(j["variations"]) >= 2, str(r.status))
    page("Store API product categories", c.get("/wp-json/wc/store/v1/products/categories"), ctype="application/json")
    r, j = api(c, "GET", "/wp-json/wc/store/v1/products?search=" + quote(ss["sku"]))
    s.ok("Store API search by SKU", j is not None and any(p["id"] == ss["id"] for p in j), str(r.status))


# ---------------------------------------------------------------------------
# Login, sessions, password reset

def sec_auth():
    c = client()
    r = c.get("/wp-login.php")
    page("login form", r, contains=['id="loginform"', 'name="pwd"'])
    r = c.post("/wp-login.php", data={"log": "admin", "pwd": "wrong", "wp-submit": "Log In", "testcookie": "1"})
    page("wrong password is refused", r, contains='id="login_error"')
    s.ok("wrong password sets no auth cookie", not any(k.startswith("wordpress_logged_in_") for k in c.cookies))
    r = c.get("/wp-admin/", follow=False)
    s.ok("wp-admin redirects anonymous visitors to the login", r.status == 302 and "wp-login.php" in (r.header("location") or ""), f"{r.status} {r.header('location')}")

    admin, r = login("admin")
    page("admin login lands on the dashboard", r, contains=["Dashboard", "wpadminbar"], min_bytes=50000)
    if "wpadminbar" not in r.text:
        print("    | landed on: " + re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", re.sub(r"(?s)<(script|style).*?</\1>", "", r.text)))[:500])
    author, r = login("author_01")
    page("author login lands on the dashboard", r, contains="Dashboard")
    sub, r = login("subscriber_01")
    landed("subscriber login lands somewhere logged in", r)
    r = sub.get("/wp-admin/edit.php", follow=False)
    s.ok("subscriber cannot open the post list", r.status in (302, 403), str(r.status))
    legacy, r = login(M["legacy_hash_user"])
    landed("account with a legacy phpass hash can log in", r)
    for who in ("editor_01", "contributor_01"):
        cc, r = login(who)
        landed(f"{who} login", r)

    # Log out through the admin bar link, then the session is gone.
    m = re.search(r"""href=['"]([^'"]*action=logout[^'"]*)['"]""", admin.get("/wp-admin/").text.replace("&#038;", "&").replace("&amp;", "&"))
    if s.ok("admin bar carries a logout link", m):
        tmp, _ = login("editor_01")
        m2 = re.search(r"""href=['"]([^'"]*action=logout[^'"]*)['"]""", tmp.get("/wp-admin/").text.replace("&#038;", "&").replace("&amp;", "&"))
        r = tmp.get(urlsplit(m2.group(1)).path + "?" + urlsplit(m2.group(1)).query, follow=False)
        s.ok("logout redirects to loggedout=true", r.status == 302 and "loggedout=true" in (r.header("location") or ""), f"{r.status} {r.header('location')}")
        r = tmp.get("/wp-admin/", follow=False)
        s.ok("after logout wp-admin wants a login again", r.status == 302 and "wp-login.php" in (r.header("location") or ""))

    # Password reset, end to end, on an account made for the purpose. The mail
    # goes to a file (fixture mu-plugin) instead of an MTA.
    nonce = rest_nonce(admin)
    name = f"reset_{RUN}"
    r, j = api(admin, "POST", "/wp-json/wp/v2/users", nonce, json_body={"username": name, "email": f"{name}@apptest.test", "password": "Apptest!first1", "roles": ["subscriber"], "name": "Reset Ünï"})
    s.ok("admin creates a user over REST", r.status == 201 and j["slug"] == name, f"{r.status} {str(j)[:200]}")
    fresh = client()
    fresh.get("/wp-login.php")
    r = fresh.post("/wp-login.php?action=lostpassword", data={"user_login": name, "redirect_to": "", "wp-submit": "Get New Password"}, follow=False)
    s.ok("lost password form is accepted", r.status == 302 and "checkemail=confirm" in (r.header("location") or ""), f"{r.status} {r.header('location')} {r.text[:200]!r}")
    log = client().get("/wp-content/uploads/apptest-mail.log").text.strip().splitlines()
    mails = [json.loads(line) for line in log if f"{name}@apptest.test" in line]
    link = None
    for mail in mails:
        found = re.search(r"https?://[^\s<>\"]*action=rp[^\s<>\"]*", mail["message"])
        if found:
            link = found.group(0)
    if s.ok("the reset mail carries a reset link", link, f"{len(mails)} mails"):
        r = fresh.get(urlsplit(link).path + "?" + urlsplit(link).query)
        page("reset link opens the new-password form", r, contains="pass1")
        hidden = apptest.hidden_inputs(r.text, "resetpassform")
        newpw = "Apptest!second2"
        r = fresh.post("/wp-login.php?action=resetpass", data={**hidden, "pass1": newpw, "pass2": newpw, "wp-submit": "Save Password"})
        page("password reset completes", r, contains="Your password has been reset")
        USERS[name] = {"login": name, "password": newpw}
        cc, r = login(name)
        landed("login with the new password works", r)
        try:
            login(name, "Apptest!first1")
            s.ok("the old password is dead", False, "old password still logs in")
        except RuntimeError:
            s.ok("the old password is dead", True)


# ---------------------------------------------------------------------------
# The admin area

def sec_admin():
    admin, _ = login("admin")
    dash = admin.get("/wp-admin/")
    screens = [
        ("dashboard", "/wp-admin/", "Dashboard"),
        ("post list", "/wp-admin/edit.php", 'id="the-list"'),
        ("post list page 3", "/wp-admin/edit.php?paged=3", 'id="the-list"'),
        ("post list, drafts", "/wp-admin/edit.php?post_status=draft&post_type=post", 'id="the-list"'),
        ("post list, search", "/wp-admin/edit.php?s=" + quote("лиса"), 'id="the-list"'),
        ("post list by category", f"/wp-admin/edit.php?cat={M['category_small']['id']}", 'id="the-list"'),
        ("page list", "/wp-admin/edit.php?post_type=page", 'id="the-list"'),
        ("post editor", f"/wp-admin/post.php?post={M['posts']['with_image']['id']}&action=edit", EDITOR_DEFAULT),
        ("new post", "/wp-admin/post-new.php", EDITOR_DEFAULT),
        ("page editor", f"/wp-admin/post.php?post={M['pages']['root']['id']}&action=edit", EDITOR_DEFAULT),
        ("media library", "/wp-admin/upload.php?mode=list", 'id="the-list"'),
        ("comments", "/wp-admin/edit-comments.php", 'id="the-comment-list"'),
        ("comments awaiting moderation", "/wp-admin/edit-comments.php?comment_status=moderated", "the-comment-list"),
        ("categories", "/wp-admin/edit-tags.php?taxonomy=category", 'id="the-list"'),
        ("tags", "/wp-admin/edit-tags.php?taxonomy=post_tag", 'id="the-list"'),
        ("users", "/wp-admin/users.php", 'id="the-list"'),
        ("user profile", f"/wp-admin/user-edit.php?user_id={M['author']['id']}", "user_login"),
        ("plugins", "/wp-admin/plugins.php", "WooCommerce"),
        ("themes", "/wp-admin/themes.php", M["theme"]["name"]),
        ("site editor", "/wp-admin/site-editor.php", "site-editor", "5.9"),
        ("general settings", "/wp-admin/options-general.php", "blogname"),
        ("reading settings", "/wp-admin/options-reading.php", "posts_per_page"),
        ("discussion settings", "/wp-admin/options-discussion.php", "comment_moderation"),
        ("permalink settings", "/wp-admin/options-permalink.php", "permalink_structure"),
        ("tools", "/wp-admin/tools.php", "Tools"),
        ("export", "/wp-admin/export.php", "Export"),
        ("site health", "/wp-admin/site-health.php", "Site Health", "5.2"),
        ("Redis Object Cache settings", "/wp-admin/options-general.php?page=redis-cache", "Redis Object Cache"),
        ("profile", "/wp-admin/profile.php", "Profile"),
    ]
    for name, path, marker, *floor in screens:
        if floor and not since(floor[0]):
            s.skip(f"admin: {name}", f"WordPress {floor[0]} added it")
            continue
        s.guard(f"admin: {name}", lambda p=path, m=marker, n=name: page(f"admin: {n}", admin.get(p), contains=m, min_bytes=8000))

    # Heartbeat with the nonce the dashboard printed.
    hb = re.search(r'heartbeatSettings\s*=\s*\{"nonce":"(\w+)"', dash.text)
    if s.ok("dashboard prints a heartbeat nonce", hb):
        r = admin.post("/wp-admin/admin-ajax.php", data={"action": "heartbeat", "_nonce": hb.group(1), "interval": "60", "screen_id": "dashboard", "has_focus": "true", "data[apptest]": RUN})
        j = r.json() if r.status == 200 else {}
        s.ok("heartbeat answers with the server time", r.status == 200 and "server_time" in j, f"{r.status} {r.text[:120]!r}")
        s.ok("heartbeat keeps the session (wp-auth-check)", j.get("wp-auth-check") is True, str(j)[:200])
    r = admin.post("/wp-admin/admin-ajax.php", data={"action": "query-attachments", "query[posts_per_page]": "5", "query[post_mime_type]": "image"})
    j = r.json() if r.status == 200 else {}
    s.ok("media library query (ajax)", j.get("success") is True and len(j.get("data", [])) == 5, f"{r.status} {r.text[:120]!r}")

    # Editor-facing REST endpoints, as the block editor calls them.
    nonce = rest_nonce(admin)
    for name, path, *floor in [
        ("settings", "/wp-json/wp/v2/settings"),
        ("plugins", "/wp-json/wp/v2/plugins", "5.5"),
        ("themes", "/wp-json/wp/v2/themes?status=active", "5.0"),
        ("block types", "/wp-json/wp/v2/block-types", "5.0"),
        ("templates", "/wp-json/wp/v2/templates", "5.8"),
        ("template parts", "/wp-json/wp/v2/template-parts", "5.9"),
        ("global styles", "/wp-json/wp/v2/global-styles/themes/" + M["theme"]["slug"], "5.9"),
        ("block renderer", "/wp-json/wp/v2/block-renderer/core/latest-posts?context=edit&attributes%5BpostsToShow%5D=3", "5.0"),
        ("post, edit context", f"/wp-json/wp/v2/posts/{M['posts']['plain']['id']}?context=edit"),
        ("users, edit context", "/wp-json/wp/v2/users?context=edit&per_page=100"),
        ("navigation", "/wp-json/wp/v2/navigation", "5.9"),
        ("menus", "/wp-json/wp/v2/menus", "5.9"),
        ("menu items", "/wp-json/wp/v2/menu-items?per_page=100&menus=" + str(M["menu"]["id"]), "5.9"),
        ("autosaves", f"/wp-json/wp/v2/posts/{M['posts']['plain']['id']}/autosaves", "5.0"),
        ("revisions", f"/wp-json/wp/v2/posts/{M['posts']['plain']['id']}/revisions"),
        ("site health", "/wp-json/wp-site-health/v1/tests/background-updates", "5.6"),
    ]:
        if floor and not since(floor[0]):
            s.skip(f"REST (admin): {name}", f"WordPress {floor[0]} added it")
            continue

        def one(name=name, path=path):
            r, j = api(admin, "GET", path, nonce)
            s.ok(f"REST (admin): {name}", r.status == 200 and j is not None and r.error_marker() is None, f"{r.status} {r.text[:200]!r}")
        s.guard(f"REST (admin): {name}", one)
    r, j = api(admin, "GET", "/wp-json/wp/v2/users?context=edit&per_page=100", nonce)
    s.ok("users, edit context: every seeded account", j and len(j) >= M["counts"]["users"], f"{len(j or [])}")
    r, j = api(admin, "GET", "/wp-json/wp/v2/comments?status=hold&per_page=1", nonce)
    s.ok("pending comments are visible to an admin", r.status == 200 and int(r.header("x-wp-total") or 0) >= M["counts"]["comments_pending"], r.header("x-wp-total"))
    r, j = api(admin, "GET", "/wp-json/wp/v2/posts?status=draft,pending,private&per_page=1", nonce)
    s.ok("non-published posts are visible to an admin", int(r.header("x-wp-total") or 0) >= M["counts"]["posts_draft"] + M["counts"]["posts_pending"] + M["counts"]["posts_private"], r.header("x-wp-total"))


# ---------------------------------------------------------------------------
# Writes: posts, comments, media, XML-RPC, application passwords

XMLRPC_ESC = lambda t: t.replace("&", "&amp;").replace("<", "&lt;")


def xr_encode(v):
    if isinstance(v, bool):
        return f"<value><boolean>{int(v)}</boolean></value>"
    if isinstance(v, int):
        return f"<value><int>{v}</int></value>"
    if isinstance(v, dict):
        return "<value><struct>" + "".join(f"<member><name>{k}</name>{xr_encode(x)}</member>" for k, x in v.items()) + "</struct></value>"
    if isinstance(v, list):
        return "<value><array><data>" + "".join(xr_encode(x) for x in v) + "</data></array></value>"
    return f"<value><string>{XMLRPC_ESC(str(v))}</string></value>"


def xr_decode(v):
    child = v[0] if len(v) else None
    if child is None:
        return v.text or ""
    t = child.tag
    if t == "array":
        return [xr_decode(x) for x in child.find("data")]
    if t == "struct":
        return {m.find("name").text: xr_decode(m.find("value")) for m in child}
    if t in ("int", "i4"):
        return int(child.text)
    if t == "boolean":
        return child.text == "1"
    return child.text or ""


def xmlrpc(c, method, *params):
    body = "<?xml version=\"1.0\"?><methodCall><methodName>" + method + "</methodName><params>" + "".join(f"<param>{xr_encode(p)}</param>" for p in params) + "</params></methodCall>"
    r = c.post("/xmlrpc.php", data=body.encode(), headers={"Content-Type": "text/xml"})
    root = ET.fromstring(r.body)
    fault = root.find("fault/value")
    if fault is not None:
        return r, {"__fault__": xr_decode(fault)}
    return r, xr_decode(root.find("params/param/value"))


def sec_write():
    admin, _ = login("admin")
    nonce = rest_nonce(admin)

    # A post over REST with cookie + nonce, read back through the edit context.
    title = f"Suite post {RUN} Ünïcödé тест 测试 🚀"
    body = f"<!-- wp:paragraph -->\n<p>Written by the suite {RUN}: \"quotes\", <strong>bold</strong> & ampersand, emoji 🚀.</p>\n<!-- /wp:paragraph -->"
    r, j = api(admin, "POST", "/wp-json/wp/v2/posts", nonce, json_body={"title": title, "content": body, "status": "draft", "categories": [M["category_small"]["id"]], "meta": {"apptest_rating": 4, "apptest_source": f"suite {RUN}"}})
    if not s.ok("create a post over REST (cookie + nonce)", r.status == 201 and j and j["id"], f"{r.status} {r.text[:300]!r}"):
        return
    pid = j["id"]
    r, j = api(admin, "GET", f"/wp-json/wp/v2/posts/{pid}?context=edit", nonce)
    s.ok("read it back: title, content and meta survive", j and j["title"]["raw"] == title and j["content"]["raw"] == body and j["meta"]["apptest_rating"] == 4 and j["meta"]["apptest_source"] == f"suite {RUN}", str(j)[:300])
    r, j = api(admin, "POST", f"/wp-json/wp/v2/posts/{pid}", nonce, json_body={"title": title + " (edited)", "excerpt": "Ünï excerpt"})
    s.ok("update it", r.status == 200 and j["title"]["raw"] == title + " (edited)", str(r.status))
    r, j = api(admin, "GET", f"/wp-json/wp/v2/posts/{pid}/revisions", nonce)
    s.ok("the edit made a revision", r.status == 200 and len(j) >= 1, f"{r.status} {len(j or [])}")
    r, j = api(client(), "GET", f"/wp-json/wp/v2/posts/{pid}")
    s.ok("the draft is not public over REST", r.status in (401, 403), str(r.status))
    page("the draft is not public on the site", client().get(f"/?p={pid}"), status=404)
    page("the draft previews for its author", admin.get(f"/?p={pid}&preview=true"), contains="Suite post " + RUN)

    # Application password + HTTP Basic, the way integrations call in.
    if since("5.6"):
        r, j = api(admin, "POST", "/wp-json/wp/v2/users/me/application-passwords", nonce, json_body={"name": f"suite {RUN}"})
    else:
        s.skip("application passwords", "WordPress 5.6 added them")
        r, j = None, None
    if r is not None and s.ok("create an application password", r.status == 201 and j and j["password"], f"{r.status} {r.text[:200]!r}"):
        import base64
        auth = {"Authorization": "Basic " + base64.b64encode(f"admin:{j['password']}".encode()).decode()}
        cc = client()
        r, jj = api(cc, "GET", "/wp-json/wp/v2/users/me", headers=auth)
        s.ok("Basic auth with the application password", r.status == 200 and jj["slug"] == "admin", f"{r.status} {r.text[:120]!r}")
        r, jj = api(cc, "POST", "/wp-json/wp/v2/posts", headers=auth, json_body={"title": f"Basic post {RUN}", "status": "draft"})
        s.ok("create a post with Basic auth", r.status == 201, f"{r.status} {r.text[:120]!r}")
        r, jj = api(cc, "GET", "/wp-json/wp/v2/users/me", headers={"Authorization": "Basic " + base64.b64encode(b"admin:wrong").decode()})
        s.ok("a wrong application password is refused", r.status == 401, str(r.status))

    # Comments through wp-comments-post.php.
    target = M["comment_target"]
    guest = client()
    form = guest.get(target["path"])
    hidden = apptest.hidden_inputs(form.text, 'id="commentform"')
    text = f"Suite comment {RUN}: Ünïcödé тест 测试 🚀"
    r = guest.post("/wp-comments-post.php", data={**hidden, "comment": text, "author": "Suite Guest ✓", "email": f"guest-{RUN}@example.test", "url": "https://example.test", "wp-comment-cookies-consent": "yes", "submit": "Post Comment"}, follow=False)
    loc = r.header("location") or ""
    s.ok("guest comment is accepted and redirected to its anchor", r.status == 302 and "#comment-" in loc, f"{r.status} {loc} {r.text[:200]!r}")
    m = re.search(r"#comment-(\d+)", loc)
    if m:
        cid = int(m.group(1))
        r = guest.get(guest._local_path(loc.split("#")[0]))
        page("the new comment shows on the post page", r, contains=f"Suite comment {RUN}")
        r = guest.post("/wp-comments-post.php", data={**hidden, "comment": text, "author": "Suite Guest ✓", "email": f"guest-{RUN}@example.test", "submit": "Post Comment"}, follow=False)
        s.ok("posting the same comment twice is refused", r.status == 409, str(r.status))
        r = guest.post("/wp-comments-post.php", data={**hidden, "comment": f"Suite markup {RUN}: <b>bold</b> <script>alert(1)</script> & <a href='https://example.test' onclick='x()'>link</a>", "author": "Suite Guest ✓", "email": f"guest-{RUN}@example.test", "submit": "Post Comment"}, follow=False)
        s.ok("a comment with markup is accepted", r.status == 302 and "#comment-" in (r.header("location") or ""), str(r.status))
        r = guest.get(guest._local_path((r.header("location") or "/").split("#")[0]))
        s.ok("comment markup is filtered on output", f"Suite markup {RUN}" in r.text and "<script>alert(1)</script>" not in r.text and "onclick=" not in r.text.split(f"Suite markup {RUN}")[0][-400:])
        r = guest.post("/wp-comments-post.php", data={**hidden, "comment_parent": str(cid), "comment": f"Suite reply {RUN}", "author": "Suite Guest ✓", "email": f"guest-{RUN}@example.test", "submit": "Post Comment"}, follow=False)
        s.ok("a threaded reply is accepted", r.status == 302 and "#comment-" in (r.header("location") or ""), f"{r.status}")
        r, j = api(client(), "GET", f"/wp-json/wp/v2/comments?post={target['id']}&search=" + quote(RUN))
        s.ok("the comments are visible over REST", int(r.header("x-wp-total") or 0) == 3, r.header("x-wp-total"))
        if j:
            reply = [x for x in j if x["parent"] == cid]
            s.ok("the reply is threaded under the comment", len(reply) == 1)
    r = guest.post("/wp-comments-post.php", data={**hidden, "comment": "", "author": "x", "email": "x@example.test"}, follow=False)
    s.ok("an empty comment is refused", r.status in (400, 409) or "please type" in r.text.lower(), str(r.status))
    r = guest.post("/wp-comments-post.php", data={**hidden, "comment": "no mail " + RUN, "author": "x", "email": "not-an-address"}, follow=False)
    s.ok("a comment with a bad email is refused", r.status == 409 or "valid email" in r.text.lower() or r.status == 400, str(r.status))
    author, _ = login("author_02")
    r = author.post("/wp-comments-post.php", data={"comment_post_ID": target["id"], "comment_parent": "0", "comment": f"Author comment {RUN} — тест"}, follow=False)
    s.ok("a logged-in comment is accepted without name or email", r.status == 302 and "#comment-" in (r.header("location") or ""), f"{r.status} {r.text[:200]!r}")

    # Media through the REST media endpoint: generated PNG, and every seeded
    # format re-uploaded so the image editor decodes and resizes each one.
    png = make_png(1200, 800)
    r, j = api(admin, "POST", "/wp-json/wp/v2/media", nonce, data={"title": f"Suite image {RUN}", "alt_text": "suite"}, files={"file": (f"suite-{RUN}.png", png, "image/png")})
    if s.ok("upload a PNG over REST", r.status == 201 and j and j["id"], f"{r.status} {r.text[:300]!r}"):
        sizes = j["media_details"].get("sizes", {})
        s.ok("upload: thumbnails were generated", {"thumbnail", "medium", "large"} <= set(sizes), str(list(sizes)))
        s.eq("upload: recorded full size", (j["media_details"]["width"], j["media_details"]["height"]), (1200, 800))
        for name in ("thumbnail", "medium", "large"):
            if name in sizes:
                t = client().get(urlsplit(sizes[name]["source_url"]).path)
                s.ok(f"upload: {name} file is a PNG of {sizes[name]['width']}x{sizes[name]['height']}", t.status == 200 and image_size(t.body) == (sizes[name]["width"], sizes[name]["height"]), f"{t.status} {image_size(t.body)}")
        full = client().get(urlsplit(j["source_url"]).path)
        s.ok("upload: the original comes back byte for byte", full.status == 200 and full.body == png)
    lst = client().get("/wp-json/wp/v2/media?per_page=100&media_type=image").json()
    seen = set()
    for m in lst:
        ext = m["mime_type"]
        if ext in seen or ext not in ("image/jpeg", "image/gif", "image/webp"):
            continue
        seen.add(ext)
        src = client().get(urlsplit(m["source_url"]).path)
        suffix = {"image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp"}[ext]
        r, j = api(admin, "POST", "/wp-json/wp/v2/media", nonce, files={"file": (f"suite-{RUN}.{suffix}", src.body, ext)})
        ok = r.status == 201 and j and "thumbnail" in j["media_details"].get("sizes", {})
        s.ok(f"re-upload a seeded {ext}: thumbnails generated", ok, f"{r.status} {r.text[:200]!r}")
        if ok:
            t = client().get(urlsplit(j["media_details"]["sizes"]["thumbnail"]["source_url"]).path)
            s.ok(f"re-upload {ext}: thumbnail decodes", t.status == 200 and image_size(t.body) == (150, 150), f"{t.status} {image_size(t.body)}")
    r, j = api(admin, "POST", "/wp-json/wp/v2/media", nonce, files={"file": (f"suite-{RUN}.php", b"<?php echo 1;", "application/x-php")})
    if args.config == "hardened":
        # Snuffleupagus's upload_validation rejects the file before WordPress runs,
        # so the refusal is fpm's (a 502 through nginx), not WordPress's JSON error.
        s.ok("an upload of a .php file is refused", r.status >= 400, f"{r.status} {r.text[:120]!r}")
        found = client().get(f"/wp-json/wp/v2/media?search=suite-{RUN}&media_type=application").json()
        s.ok("the refused .php upload was not stored", isinstance(found, list) and not any(str(m.get("source_url", "")).endswith(".php") for m in found), str(found)[:200])
    else:
        s.ok("an upload of a .php file is refused", j and j["code"] == "rest_upload_unknown_error" and r.status >= 400, f"{r.status} {r.text[:120]!r}")

    # XML-RPC.
    anon = client()
    r, res = xmlrpc(anon, "system.listMethods")
    page("xmlrpc.php system.listMethods", r, ctype="xml")
    s.ok("listMethods knows the WordPress and blogger APIs", isinstance(res, list) and {"wp.getUsersBlogs", "metaWeblog.newPost", "demo.sayHello", "pingback.ping"} <= set(res), str(res)[:200])
    r, res = xmlrpc(anon, "demo.sayHello")
    s.eq("demo.sayHello", res, "Hello!")
    r, res = xmlrpc(anon, "wp.getUsersBlogs", "admin", USERS["admin"]["password"])
    s.ok("wp.getUsersBlogs authenticates", isinstance(res, list) and res and res[0]["blogName"] == "Apptest Journal" and res[0]["url"].startswith(f"http://{args.host}"), str(res)[:200])
    r, res = xmlrpc(anon, "wp.getUsersBlogs", "admin", "wrong")
    s.ok("wp.getUsersBlogs refuses a wrong password", isinstance(res, dict) and res.get("__fault__", {}).get("faultCode") == 403, str(res)[:200])
    r, res = xmlrpc(anon, "wp.newPost", 1, "admin", USERS["admin"]["password"], {"post_title": f"XML-RPC post {RUN} Ünï", "post_content": "<p>xmlrpc & body</p>", "post_status": "draft"})
    if s.ok("wp.newPost creates a draft", isinstance(res, str) and res.isdigit(), str(res)[:200]):
        r, got = xmlrpc(anon, "wp.getPost", 1, "admin", USERS["admin"]["password"], int(res))
        s.ok("wp.getPost reads it back", isinstance(got, dict) and got["post_title"] == f"XML-RPC post {RUN} Ünï" and got["post_status"] == "draft", str(got)[:200])
    r, res = xmlrpc(anon, "wp.getOptions", 1, "admin", USERS["admin"]["password"], ["blog_title"])
    s.ok("wp.getOptions", isinstance(res, dict) and res["blog_title"]["value"] == "Apptest Journal", str(res)[:200])
    r, res = xmlrpc(anon, "system.multicall", [{"methodName": "demo.sayHello", "params": []}, {"methodName": "demo.addTwoNumbers", "params": [2, 3]}])
    s.ok("system.multicall", res == [["Hello!"], [5]], str(res)[:200])
    page("xmlrpc.php via GET says it wants POST", client().get("/xmlrpc.php"), contains="XML-RPC server accepts POST requests only", status=405)


# ---------------------------------------------------------------------------
# WooCommerce

def sec_woo():
    c = client()
    for name, key in (("shop", "shop"), ("cart", "cart"), ("my account", "myaccount")):
        page(f"Woo {name} page", c.get(W["pages"][key]["path"]), min_bytes=20000)
    r = c.get(W["pages"]["shop"]["path"])
    s.ok("shop lists products", len(set(re.findall(r'href="http://[^"]*/product/([^/"]+)/"', r.text))) >= 8, "")
    page("shop, page 2", c.get(W["pages"]["shop"]["path"] + "page/2/"), contains="/product/")
    page("shop, sorted by price", c.get(W["pages"]["shop"]["path"] + "?orderby=price"), contains="/product/")
    cat = W["category"]
    page("product category", c.get(cat["path"]), contains=cat["name"])
    ss, vs = W["simple_sample"], W["variable_sample"]
    r = c.get(ss["path"])
    page("simple product", r, contains=[ss["name"], ss["sku"], "add-to-cart"], min_bytes=20000)
    r = c.get(vs["path"])
    page("variable product", r, contains=[vs["name"], vs["sku"], "Size"], min_bytes=20000)
    s.ok("variable product carries its variations", r.text.count("variation") >= 4)
    page("product search", c.get("/?s=" + quote("#" + ss["name"].split("#")[1])), contains=ss["name"])
    if BLOCKS:
        page("checkout with an empty cart bounces to the cart", c.get(W["pages"]["checkout"]["path"]), contains="wc-block-cart")
    else:
        r = c.get(W["pages"]["checkout"]["path"])
        page("checkout with an empty cart", r)
        s.ok("checkout with an empty cart says so", re.search(r"cart is (currently )?empty", r.text) is not None)

    # Classic add-to-cart URLs share one session cookie with the Store API.
    shopper = client()
    r = shopper.get(f"/?add-to-cart={ss['id']}&quantity=2")
    s.ok("add-to-cart (simple) starts a session", r.status == 200 and any(k.startswith("wp_woocommerce_session_") for k in shopper.cookies) and shopper.cookies.get("woocommerce_items_in_cart") == "1", f"{r.status} {list(shopper.cookies)}")
    attrs = "&".join(f"attribute_{k}={quote(v)}" for k, v in vs["variation_attributes"].items())
    r = shopper.get(f"/?add-to-cart={vs['id']}&variation_id={vs['variation_id']}&quantity=1&{attrs}")
    s.ok("add-to-cart (variation)", r.status == 200, str(r.status))
    r = shopper.get(W["pages"]["cart"]["path"])
    page("cart page lists both", r, contains=[ss["name"]], min_bytes=20000)
    if STORE_API:
        r, j = api(shopper, "GET", "/wp-json/wc/store/v1/cart")
        s.ok("Store API sees the same cart", j and j["items_count"] == 3 and len(j["items"]) == 2, str(j)[:200] if j else str(r.status))
        if j:
            var = [i for i in j["items"] if i["id"] == vs["variation_id"]]
            s.ok("the variation keeps its attributes in the cart", var and {a["value"].lower() for a in var[0]["variation"]} >= {v.lower() for v in vs["variation_attributes"].values()}, str(var)[:200])
    else:
        s.skip("Store API sees the same cart", f"WooCommerce {W['version']} has no wc/store/v1")
    r = shopper.get(W["pages"]["checkout"]["path"])
    page("checkout page with items", r, contains="wc-block-checkout" if BLOCKS else "woocommerce-checkout", min_bytes=20000)

    address = {"first_name": "Suite", "last_name": "Buyer Ünï", "address_1": "1 Test Street", "city": "Testville", "state": "CA", "postcode": "90001", "country": "US", "email": f"buyer-{RUN}@example.test", "phone": "555-0199"}
    expected_total = None
    coupon = W["coupon"]
    api_shopper = client()
    st = {"nonce": None, "token": None}

    def store(method, path, body=None):
        headers = {"Nonce": st["nonce"]}
        if st["token"]:
            headers["Cart-Token"] = st["token"]
        r, j = api(api_shopper, method, "/wp-json/wc/store/v1" + path, headers=headers, json_body=body)
        st["nonce"] = r.header("nonce") or st["nonce"]
        st["token"] = r.header("cart-token") or st["token"]
        return r, j

    if CLASSIC_CHECKOUT:
        # The Store API of a 6.x shop leaves a cash-on-delivery order pending with an empty payment
        # result (measured on 6.4.2), so that era is checked the way its shortcode checkout is used:
        # the form, its nonce and wc-ajax=checkout, on the cart the add-to-cart URLs filled.
        coupon = None
        r = shopper.get(W["pages"]["checkout"]["path"])
        form = apptest.hidden_inputs(r.text, "woocommerce-checkout")
        rate = re.search(r'name="shipping_method\[0\]"[^>]*value="([^"]+)"', r.text)
        s.ok("classic checkout form carries its nonce and a flat rate", "woocommerce-process-checkout-nonce" in form and rate, str(list(form)))
        fields = {**form, "payment_method": "cod", "order_comments": f"suite {RUN}", "terms": "on", "shipping_method[0]": rate.group(1) if rate else "",
                  **{f"billing_{k}": v for k, v in address.items()}, **{f"shipping_{k}": v for k, v in address.items() if k not in ("email", "phone")}}
        r = shopper.post("/?wc-ajax=checkout", data=fields)
        res = r.json() if r.status == 200 else {}
        found = re.search(r"/order-received/(\d+)/\?key=(wc_order_\w+)", res.get("redirect", "") or "")
        ok = s.ok("classic checkout with cash on delivery", res.get("result") == "success" and found, f"{r.status} {r.text[:400]!r}")
        if ok:
            j = {"order_id": int(found.group(1)), "order_key": found.group(2), "status": "processing"}
    else:
        # A checkout through the Store API: coupon, shipping, cash on delivery.
        r, j = api(api_shopper, "GET", "/wp-json/wc/store/v1/cart")
        st.update(nonce=r.header("nonce"), token=r.header("cart-token"))
        # The Cart-Token header is newer than the nonce; older shops keep the cart in the session cookie the client already holds.
        s.ok("Store API hands out a nonce and a cart token", st["nonce"] and (st["token"] or not BLOCKS), f"nonce={st['nonce']} token={bool(st['token'])}")

        r, j = store("POST", "/cart/add-item", {"id": ss["id"], "quantity": 2})
        s.ok("Store API add-item", r.status in (200, 201) and j["items_count"] == 2, f"{r.status} {r.text[:200]!r}")
        r, j = store("POST", "/cart/add-item", {"id": vs["variation_id"], "quantity": 1, "variation": [{"attribute": k, "value": v} for k, v in vs["variation_attributes"].items()]})
        s.ok("Store API add-item (variation)", r.status in (200, 201) and j["items_count"] == 3, f"{r.status} {r.text[:200]!r}")
        r, j = store("POST", "/cart/apply-coupon", {"code": W["coupon"]})
        s.ok("Store API apply-coupon", r.status == 200 and j["coupons"] and j["coupons"][0]["code"] == W["coupon"], f"{r.status} {r.text[:200]!r}")
        address = {"first_name": "Suite", "last_name": "Buyer Ünï", "address_1": "1 Test Street", "city": "Testville", "state": "CA", "postcode": "90001", "country": "US", "email": f"buyer-{RUN}@example.test", "phone": "555-0199"}
        r, j = store("POST", "/cart/update-customer", {"billing_address": address, "shipping_address": {k: v for k, v in address.items() if k not in ("email", "phone")}})
        rates = j["shipping_rates"][0]["shipping_rates"] if r.status == 200 and j["shipping_rates"] else []
        s.ok("Store API offers the flat rate", r.status == 200 and rates and rates[0]["rate_id"].startswith("flat_rate:"), f"{r.status} {r.text[:300]!r}")
        if rates:
            r, j = store("POST", "/cart/select-shipping-rate", {"package_id": 0, "rate_id": rates[0]["rate_id"]})
            s.ok("Store API select-shipping-rate", r.status == 200, f"{r.status} {r.text[:200]!r}")
        r, cart = store("GET", "/cart")
        expected_total = Decimal(cart["totals"]["total_price"]) / (10 ** cart["totals"]["currency_minor_unit"]) if cart else None
        r, j = store("POST", "/checkout", {"billing_address": address, "shipping_address": {k: v for k, v in address.items() if k not in ("email", "phone")}, "customer_note": f"suite {RUN}", "payment_method": "cod", "payment_data": []})
        ok = s.ok("Store API checkout with cash on delivery", r.status == 200 and j and j["order_id"] and j["payment_result"]["payment_status"] == "success", f"{r.status} {r.text[:400]!r}")
    if ok:
        oid, key = j["order_id"], j["order_key"]
        s.ok("the order is processing", j["status"] == "processing", j["status"])
        buyer = shopper if CLASSIC_CHECKOUT else api_shopper
        r = buyer.get(f"/checkout/order-received/{oid}/?key={key}")
        page("order-received page", r, contains=[str(oid)], min_bytes=10000)
        if STORE_API:
            r, cart = api(buyer, "GET", "/wp-json/wc/store/v1/cart") if CLASSIC_CHECKOUT else store("GET", "/cart")
            s.ok("the cart is empty after checkout", cart and cart["items_count"] == 0)
        else:
            r = buyer.get(W["pages"]["cart"]["path"])
            s.ok("the cart is empty after checkout", re.search(r"cart is (currently )?empty", r.text) is not None)
        admin, _ = login("admin")
        nonce = rest_nonce(admin)
        r, o = api(admin, "GET", f"/wp-json/wc/v3/orders/{oid}", nonce)
        s.ok("Woo REST: the order exists with the right status and gateway", o and o["status"] == "processing" and o["payment_method"] == "cod" and o["billing"]["email"] == address["email"], str(o)[:200] if o else str(r.status))
        if expected_total is not None:
            s.ok("Woo REST: total matches what the cart showed", o and Decimal(o["total"]) == expected_total, f"{o and o['total']} vs {expected_total}")
        s.ok("Woo REST: coupon, shipping and two lines recorded", o and [x["code"] for x in o["coupon_lines"]] == ([coupon] if coupon else []) and o["shipping_lines"][0]["method_id"] == "flat_rate" and len(o["line_items"]) == 2, str(o)[:200] if o else "")
        s.ok("Woo REST: the customer note survived", o and o["customer_note"] == f"suite {RUN}")
        page("admin: order screen", admin.get(ORDER_EDIT.format(id=oid)), contains=[address["email"], str(oid)])
        page("admin: orders list", admin.get(ORDER_LIST), contains=str(oid))
        r, notes = api(admin, "GET", f"/wp-json/wc/v3/orders/{oid}/notes", nonce)
        s.ok("Woo REST: order notes were written", notes and len(notes) >= 1, str(r.status))

    admin, _ = login("admin")
    nonce = rest_nonce(admin)
    r, j = api(admin, "GET", "/wp-json/wc/v3/products?per_page=1", nonce)
    s.eq("Woo REST: product total", r.header("x-wp-total"), str(M["counts"]["products"]))
    r, j = api(admin, "GET", "/wp-json/wc/v3/orders?per_page=1", nonce)
    s.ok("Woo REST: order total", int(r.header("x-wp-total") or 0) >= M["counts"]["orders"], r.header("x-wp-total"))
    r, j = api(admin, "GET", f"/wp-json/wc/v3/products/{vs['id']}/variations?per_page=100", nonce)
    s.ok("Woo REST: variations of a variable product", j and len(j) >= 2 and all(v["sku"].startswith(vs["sku"]) for v in j), str(r.status))
    r, j = api(admin, "GET", "/wp-json/wc/v3/system_status", nonce)
    s.ok("Woo REST: system status reports this PHP", j and j["environment"]["php_version"].startswith(args.php + "."), (j or {}).get("environment", {}).get("php_version", str(r.status)))
    r, j = api(admin, "GET", "/wp-json/wc/v3/payment_gateways/cod", nonce)
    s.ok("Woo REST: cash on delivery is enabled", j and j["enabled"] is True, str(r.status))
    r, j = api(admin, "GET", "/wp-json/wc/v3/shipping/zones", nonce)
    s.ok("Woo REST: the shipping zone", j and any(z["name"] == "Test zone" for z in j), str(r.status))
    r, j = api(admin, "GET", "/wp-json/wc/v3/customers?per_page=100&role=all", nonce)
    s.ok("Woo REST: customers", r.status == 200 and len(j) >= M["counts"]["customers"], str(r.status))
    r, j = api(admin, "GET", "/wp-json/wc/v3/coupons?code=" + W["coupon"], nonce)
    s.ok("Woo REST: the coupon", j and len(j) == 1 and j[0]["discount_type"] == "percent", str(r.status))
    r, j = api(admin, "GET", "/wp-json/wc/v3/reports/sales", nonce)
    s.ok("Woo REST: sales report", r.status == 200, str(r.status))
    r, j = api(admin, "POST", "/wp-json/wc/v3/products/categories", nonce, json_body={"name": f"Suite category {RUN}"})
    s.ok("Woo REST: create a product category", r.status == 201, f"{r.status} {r.text[:120]!r}")
    r, j = api(admin, "POST", "/wp-json/wc/v3/orders", nonce, json_body={"payment_method": "cod", "status": "on-hold", "billing": {"first_name": "REST", "last_name": RUN, "email": f"rest-{RUN}@example.test", "country": "US", "state": "CA"}, "line_items": [{"product_id": ss["id"], "quantity": 1}], "shipping_lines": [{"method_id": "flat_rate", "method_title": "Flat rate", "total": "5.00"}]})
    s.ok("Woo REST: create an order", r.status == 201 and j["status"] == "on-hold" and len(j["line_items"]) == 1, f"{r.status} {r.text[:200]!r}")
    for name, path, marker, *wc_admin_only in [
        ("settings", "/wp-admin/admin.php?page=wc-settings&tab=general", "woocommerce_currency"),
        ("shipping", "/wp-admin/admin.php?page=wc-settings&tab=shipping", "Test zone"),
        ("payments", "/wp-admin/admin.php?page=wc-settings&tab=checkout", "wc-settings"),
        ("status", "/wp-admin/admin.php?page=wc-status", "WordPress environment"),
        ("products", "/wp-admin/edit.php?post_type=product", 'id="the-list"'),
        ("product edit", f"/wp-admin/post.php?post={ss['id']}&action=edit", ss["sku"]),
        ("orders", ORDER_LIST, "wc-orders" if HPOS else 'id="the-list"'),
        ("customers", "/wp-admin/admin.php?page=wc-admin&path=/customers", "wc-admin", True),
        ("coupons", "/wp-admin/edit.php?post_type=shop_coupon", 'id="the-list"'),
    ]:
        if wc_admin_only and not WC_ADMIN:
            s.skip(f"admin: WooCommerce {name}", f"WooCommerce {W['version']} predates wc-admin (merged in 4.0)")
            continue
        s.guard(f"admin: WooCommerce {name}", lambda p=path, m=marker, n=name: page(f"admin: WooCommerce {n}", admin.get(p), contains=m, min_bytes=5000))

    # A customer's own account.
    cust = W["customers"][0]
    cc = client()
    r = cc.get(W["pages"]["myaccount"]["path"])
    page("my-account login form", r, contains="woocommerce-form-login")
    hidden = apptest.hidden_inputs(r.text, "woocommerce-form-login")
    r = cc.post(W["pages"]["myaccount"]["path"], data={**hidden, "username": cust["login"], "password": cust["password"], "login": "Log in"})
    page("customer login shows the account dashboard", r, contains=["Log out", "woocommerce-MyAccount-navigation"])
    r = cc.get(W["pages"]["myaccount"]["path"] + "orders/")
    mine = W["customer_orders"][str(cust["id"])]
    page("customer's order history", r, contains=[f"#{mine[0]}"])
    page("customer's address book", cc.get(W["pages"]["myaccount"]["path"] + "edit-address/"), contains="woocommerce-Address")
    page("customer's account details", cc.get(W["pages"]["myaccount"]["path"] + "edit-account/"), contains="account_first_name")
    bad = client()
    hidden = apptest.hidden_inputs(bad.get(W["pages"]["myaccount"]["path"]).text, "woocommerce-form-login")
    r = bad.post(W["pages"]["myaccount"]["path"], data={"username": cust["login"], "password": "wrong", "login": "Log in", **hidden})
    # The error notice is a block notice banner from 8.x on, a plain woocommerce-error list before.
    s.ok("wrong customer password is refused", r.status == 200 and ("is-error" in r.text or "woocommerce-error" in r.text) and "incorrect" in r.text)
    sm, r = login("shop_manager_01")
    page("shop manager reaches the orders screen", sm.get(ORDER_LIST), contains="wc-orders" if HPOS else 'id="the-list"')
    page("customer cannot reach wp-admin's product list", cc.get("/wp-admin/edit.php?post_type=product", follow=False), status=(302, 403))


# ---------------------------------------------------------------------------
# The rest of the plugin set (the manifest lists what this release installed)

# slug -> (name on the Plugins screen, an admin screen the plugin adds, a marker on it)
PLUGIN_SCREENS = {
    "akismet": ("Akismet", "/wp-admin/options-general.php?page=akismet-key-config", "akismet"),
    "contact-form-7": ("Contact Form 7", "/wp-admin/admin.php?page=wpcf7", "wpcf7"),
    "wordpress-seo": ("Yoast SEO", "/wp-admin/admin.php?page=wpseo_dashboard", "wpseo"),
    "classic-editor": ("Classic Editor", f"/wp-admin/post.php?post={M['posts']['with_image']['id']}&action=edit&classic-editor&classic-editor__forget", "postdivrich"),
    "wordfence": ("Wordfence", "/wp-admin/admin.php?page=Wordfence", "Wordfence"),
    "wpforms-lite": ("WPForms", "/wp-admin/admin.php?page=wpforms-overview", "wpforms"),
    "all-in-one-wp-migration": ("All-in-One WP Migration", "/wp-admin/admin.php?page=ai1wm_export", "ai1wm"),
}


def sec_plugins():
    admin, _ = login("admin")
    listing = admin.get("/wp-admin/plugins.php").text
    for slug, version in PLUGINS.items():
        row = re.search(r'<tr[^>]*\bactive\b[^>]*data-plugin="' + re.escape(slug) + r'/', listing)
        s.ok(f"plugin {slug} {version}: active on the Plugins screen", row is not None)
    if since("5.5"):
        nonce = rest_nonce(admin)
        r, j = api(admin, "GET", "/wp-json/wp/v2/plugins?per_page=100", nonce)
        have = {p["plugin"].split("/")[0]: (p["status"], p["version"]) for p in j} if r.status == 200 and isinstance(j, list) else {}
        for slug, version in PLUGINS.items():
            s.ok(f"REST plugin {slug}: active at {version}", have.get(slug) == ("active", version), str(have.get(slug)))
    else:
        s.skip("REST plugin list", "WordPress 5.5 added /wp/v2/plugins")
    for slug, (name, path, marker) in PLUGIN_SCREENS.items():
        if slug not in PLUGINS:
            continue
        s.guard(f"plugin {slug}: admin screen", lambda p=path, m=marker, n=name: page(f"plugin {n}: its admin screen", admin.get(p), contains=m, min_bytes=3000))
    anon = client()
    if "wordpress-seo" in PLUGINS:
        r = anon.get(M["posts"]["plain"]["path"])
        page("Yoast SEO: the head carries its comment and Open Graph tags", r, contains=["Yoast SEO", 'property="og:title"'])
    if "contact-form-7" in PLUGINS:
        cf = M["plugin_pages"]["contact_form"]
        r = anon.get(cf["path"])
        page("Contact Form 7: the shortcode renders its form", r, contains=["wpcf7-form", "wpcf7-submit"])
    if "classic-editor" in PLUGINS:
        r = admin.get("/wp-admin/post-new.php?classic-editor&classic-editor__forget")
        page("Classic Editor: the classic screen for a new post", r, contains="postdivrich")
        r = admin.get("/wp-admin/post-new.php")
        s.ok("Classic Editor: the block editor stays the default", EDITOR_DEFAULT in r.text, "")
    if "wordfence" in PLUGINS:
        # Wordfence's firewall runs in WordPress's own process here (no auto_prepend_file): a normal request passes it.
        page("Wordfence: a normal front page request passes its firewall", client().get("/"), contains=TITLE)
        r = client().get("/wp-login.php")
        page("Wordfence: the login page renders with its login security", r, contains='id="loginform"')


# ---------------------------------------------------------------------------
# Concurrency

def sec_concurrency():
    admin, _ = login("admin")
    plain, mc = M["posts"]["plain"], M["posts"]["most_commented"]
    jobs = [
        ("/", TITLE, None),
        (plain["path"], CONTENT, None),
        (mc["path"], "comment-", None),
        (M["category_small"]["path"], TITLE, None),
        ("/?s=" + quote("лиса"), TITLE, None),
        ("/wp-json/wp/v2/posts?per_page=10", '"id"', None),
        ("/feed/", "<rss", None),
        ("/wp-sitemap-posts-post-1.xml" if SITEMAPS else "/feed/atom/", "<urlset" if SITEMAPS else "<feed", None),
        (W["pages"]["shop"]["path"], "/product/", None),
        (W["simple_sample"]["path"], W["simple_sample"]["sku"], None),
        ("/wp-login.php", "loginform", None),
        ("/wp-admin/", "Dashboard", admin),
        ("/wp-admin/edit.php", "the-list", admin),
    ]
    tasks = [jobs[i % len(jobs)] for i in range(50)]

    def run(task):
        path, needle, who = task
        c = client()
        if who is not None:
            c.cookies = dict(who.cookies)
        r = scrub(c.get(path))
        problems = []
        if r.status != 200:
            problems.append(f"status {r.status}")
        if needle not in r.text:
            problems.append(f"missing {needle!r}")
        if r.error_marker():
            problems.append("error marker " + r.error_marker()[:120])
        return path, problems, r.elapsed

    with ThreadPoolExecutor(max_workers=16) as pool:
        results = list(pool.map(run, tasks))
    bad = [(p, pr) for p, pr, _ in results if pr]
    s.ok(f"50 parallel requests across 13 pages all succeed (slowest {max(t for _, _, t in results):.1f}s)", not bad, str(bad[:3]))
    # Through REST rather than profile.php: WooCommerce before 8.x sends subscribers away from wp-admin.
    sessions = [login(f"subscriber_0{i}") for i in range(1, 6)]
    nonces = [rest_nonce(c) for c, _ in sessions]
    with ThreadPoolExecutor(max_workers=5) as pool:
        rs = list(pool.map(lambda cn: api(cn[0][0], "GET", "/wp-json/wp/v2/users/me?context=edit", cn[1]), zip(sessions, nonces)))
    s.ok("5 simultaneous logged-in sessions each see their own account", all(r.status == 200 and j and j["slug"] == f"subscriber_0{i + 1}" for i, (r, j) in enumerate(rs)), str([r.status for r, _ in rs]))


# ---------------------------------------------------------------------------
# Redis object cache

def cache_report(c, post=None):
    """The mu-plugin's view of the object cache (fixture/mu-plugins/apptest.php)."""
    r, j = api(c, "GET", "/wp-json/apptest/v1/cache" + (f"?post={post}" if post else ""))
    if r.status != 200 or not isinstance(j, dict):
        raise RuntimeError(f"apptest/v1/cache: {r.status} {r.text[:200]!r}")
    return j


def sec_cache():
    c = client()
    rep = cache_report(c)
    s.ok("object cache: the drop-in is in use and Redis is connected", rep["ext"] and rep["connected"], str(rep))
    s.ok("object cache: phpredis client, igbinary on", "PhpRedis" in rep["client"] and rep["igbinary"], f"{rep['client']} igbinary={rep['igbinary']}")

    # The stack's Redis started empty, so the first requests of the run filled it.
    # Each request is a new PHP process: whatever it finds was left by another one.
    plain = M["posts"]["plain"]
    for i in (1, 2):
        page(f"object cache: warm-up request {i}", c.get(plain["path"]), contains=plain["title"])
    rep = cache_report(c, plain["id"])
    p = rep["post"]
    s.ok("object cache: a post cached by an earlier request is a hit", p["cached"] and p["title"] == plain["title"] and p["hit_delta"] >= 1 and p["miss_delta"] == 0, str(p))
    s.ok("object cache: the stored post is igbinary", p["igbinary"] and p["bytes"] > 100, str(p))
    s.ok("object cache: Redis holds the site's keys", rep["redis"]["keys"] >= 50, str(rep["redis"]))
    before = rep["redis"]["keyspace_hits"]
    for path in ("/", plain["path"], M["posts"]["russian"]["path"], M["category_small"]["path"]):
        c.get(path)
    after = cache_report(c)["redis"]["keyspace_hits"]
    s.ok("object cache: page requests are served from Redis", after - before >= 20, f"{after - before} keyspace hits")
    if W:
        page("object cache: a WooCommerce page renders through the cache", c.get(W["simple_sample"]["path"]), contains=W["simple_sample"]["sku"])
        page("object cache: the same page again", c.get(W["simple_sample"]["path"]), contains=W["simple_sample"]["sku"])

    # Invalidation: an edit must be what the next request sees, never the cached copy.
    admin, _ = login("admin")
    nonce = rest_nonce(admin)
    first, second = f"Cache probe {RUN} alpha", f"Cache probe {RUN} bravo"
    r, j = api(admin, "POST", "/wp-json/wp/v2/posts", nonce, json_body={"title": first, "content": "<!-- wp:paragraph -->\n<p>cache</p>\n<!-- /wp:paragraph -->", "status": "draft"})
    if not s.ok("object cache: create a draft to edit", r.status == 201 and j and j["id"], f"{r.status} {r.text[:200]!r}"):
        return
    pid = j["id"]
    page("object cache: the draft renders (and is cached)", admin.get(f"/?p={pid}&preview=true"), contains=first)
    p = cache_report(c, pid)["post"]
    s.ok("object cache: the draft is in Redis", p["cached"] and p["title"] == first, str(p))
    r, j = api(admin, "POST", f"/wp-json/wp/v2/posts/{pid}", nonce, json_body={"title": second})
    s.ok("object cache: update the post", r.status == 200 and j["title"]["raw"] == second, f"{r.status}")
    p = cache_report(c, pid)["post"]
    s.ok("object cache: after the update the cache holds no stale copy", not p["cached"] or p["title"] == second, str(p))
    page("object cache: the next request shows the new title", admin.get(f"/?p={pid}&preview=true"), contains=second, not_contains=first)
    p = cache_report(c, pid)["post"]
    s.ok("object cache: and it re-caches the new copy", p["cached"] and p["title"] == second, str(p))

    # An option lives in the cached `alloptions` blob: the same rule.
    r, j = api(admin, "GET", "/wp-json/wp/v2/settings", nonce)
    old = j["description"] if j else None
    tagline = f"Tagline {RUN}"
    try:
        r, j = api(admin, "POST", "/wp-json/wp/v2/settings", nonce, json_body={"description": tagline})
        s.ok("object cache: update an option over REST", r.status == 200 and j["description"] == tagline, f"{r.status} {r.text[:120]!r}")
        r, j = api(client(), "GET", "/wp-json/")
        s.ok("object cache: the next request sees the new option", j and j["description"] == tagline, str(j and j["description"]))
    finally:
        if old is not None:
            api(admin, "POST", "/wp-json/wp/v2/settings", nonce, json_body={"description": old})
    r, j = api(client(), "GET", "/wp-json/")
    s.ok("object cache: the option is restored for the next reader", j and j["description"] == old, str(j and j["description"]))


for name, section in (("front end", sec_front), ("REST API", sec_rest), ("auth", sec_auth), ("admin", sec_admin),
                      ("writes", sec_write), ("WooCommerce", sec_woo), ("object cache", sec_cache), ("plugins", sec_plugins), ("concurrency", sec_concurrency)):
    s.guard(f"section {name}", section)
s.finish()
