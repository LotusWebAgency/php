"""PrestaShop over HTTP: storefront, checkout, back office, webservice.

Runs against the fixture's populated shop (manifest.json says what is in it)
and only adds: every customer, order and product this creates carries a
per-run token in its email or name, because the same stack serves both the
default and the hardened config.
"""
import base64
import concurrent.futures
import copy
import hashlib
import html
import json
import os
import re
import sys
import uuid
import xml.etree.ElementTree as ET
from urllib.parse import quote, urlsplit

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
import apptest  # noqa: E402

args = apptest.parse_args("prestashop-http")
M = args.manifest_data
s = apptest.Suite("prestashop-http", args)
RUN = uuid.uuid4().hex[:10]
# names take letters only, so the per-run token has a letters-only twin
RUNW = "".join(chr(97 + int(ch, 16)) for ch in RUN).capitalize()
WS_KEY = M["webservice_key"]
ADMIN = M["admin"]
XHR = {"X-Requested-With": "XMLHttpRequest", "Accept": "application/json"}
# PrestaShop's own failure pages, on top of apptest's generic PHP markers.
PS_BAD = ["PrestaShopException", "PrestaShopDatabaseException", "Oops! An Error Occurred", "500 Server Error"]
S = "\\s*"
# What differs between the releases, keyed on the PrestaShop (major, minor) the fixture recorded.
# 9.x has the Hummingbird theme and a Symfony back office login; 8.x and 1.7 the classic theme and the legacy AdminLogin.
PSV = tuple(int(x) for x in M["app_version"].split(".")[:2])
SET9 = PSV >= (9, 0)
# 1.7.8: the old Symfony product catalog page (a filter form, not the v2 grid), no cash on delivery module, its own
# friendly URLs for a few pages (registration is a mode of /login, best sellers are /best-sales, suppliers /supplier).
PS17 = PSV < (8, 0)
# 1.6 shares almost no markup or flow with the later releases: suite/web16.py replaces those sections.
PS16 = PSV < (1, 7)
# The product pages moved to the "v2" routes in 8.x already (feature flag on by default in 8.2); 9.x dropped the suffix.
PRODUCTS = "/sell/catalog/products" if PS17 else ("/sell/catalog/products/" if SET9 else "/sell/catalog/products-v2/")
PRODUCT_EDIT = "/sell/catalog/products/%d" if PS17 else PRODUCTS + "%d/edit"
PRODUCT_EDIT_RX = r"sell/catalog/products/(\d+)\?" if PS17 else r"sell/catalog/products(?:-v2)?/(\d+)/edit"
NO_MATCH = "No search results" if SET9 else "No matches were found"
# the second signed-in checkout: 8.x and 9.x pay it on delivery, 1.7 has to use the bank wire again
PAY2 = "ps_wirepayment" if PS17 else "ps_cashondelivery"
REGISTRATION = "/login?create_account=1" if PS17 else "/registration"
BEST_SELLERS = "/best-sales" if PS17 else "/best-sellers"
PRICE_RX = r'(?:product-miniature__price"|<span class="price")[^>]*>\s*\$\s?([0-9][0-9,]*\.[0-9]{2})'


def client():
    return apptest.Client(args.base, args.host)


def P(name, resp, **kw):
    extra = kw.pop("not_contains", ())
    extra = [extra] if isinstance(extra, str) else list(extra)
    return s.page(name, resp, not_contains=extra + PS_BAD, **kw)


def scrubbed(resp, *needles):
    """resp with the given literal strings taken out of its body, for a page that legitimately contains a marker."""
    clone = copy.copy(resp)
    text = resp.text
    for n in needles:
        text = text.replace(n, "")
    clone.body = text.encode()
    return clone


def rx(pattern, text, group=1, flags=re.S):
    m = re.search(pattern, text, flags)
    return m.group(group) if m else None


def static_token(text):
    return rx(r'"static_token":"([0-9a-f]+)"', text)


def product_data(text):
    # classic (8.x) also puts data-product="<id>" on other elements of a sold out page: take the JSON one
    raw = rx(r'data-product="(\{[^"]*)"', text)
    return json.loads(html.unescape(raw)) if raw else {}


def listing_ids(text):
    return [int(x) for x in re.findall(r'<article[^>]*data-id-product="(\d+)"', text)]


def money(text):
    return [float(x.replace(",", "")) for x in re.findall(r"\$\s?([0-9][0-9,]*\.[0-9]{2})", text)]


def jpeg_size(data):
    """(width, height) from the first SOF marker, or None when it is not a JPEG."""
    if data[:3] != b"\xff\xd8\xff":
        return None
    i = 2
    while i + 9 < len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xC0, 0xC1, 0xC2):
            return int.from_bytes(data[i + 7:i + 9], "big"), int.from_bytes(data[i + 5:i + 7], "big")
        i += 2 + int.from_bytes(data[i + 2:i + 4], "big")
    return None


def form_fields(text, form_re):
    """name -> value for every input/select of the first form matching form_re."""
    m = re.search(r"<form[^>]*" + form_re + r"[^>]*>(.*?)</form>", text, re.S)
    if not m:
        return None
    body = m.group(1)
    out = {}
    for tag in re.findall(r"<input[^>]*>", body, re.S):
        n = rx(r'name="([^"]+)"', tag)
        if not n:
            continue
        t = rx(r'type="([^"]+)"', tag) or "text"
        if t in ("checkbox", "radio") and "checked" not in tag:
            continue
        if t in ("submit", "button"):
            continue
        out[n] = html.unescape(rx(r'value="([^"]*)"', tag) or "")
    for sel in re.findall(r"<select[^>]*name=\"([^\"]+)\"[^>]*>(.*?)</select>", body, re.S):
        chosen = rx(r'<option[^>]*value="([^"]*)"[^>]*selected', sel[1])
        first = rx(r'<option[^>]*value="([^"]*)"', sel[1])
        out[sel[0]] = chosen or first or ""
    return out


# -- storefront helpers ---------------------------------------------------------


def add_to_cart(c, product, attribute=0, qty=1, token=None):
    if token is None:
        token = static_token(c.get("/").text)
    r = c.post("/cart", data={"token": token, "id_product": product, "id_product_attribute": attribute,
                              "id_customization": 0, "qty": qty, "add": 1, "action": "update"}, headers=XHR)
    try:
        return r, r.json()
    except ValueError:
        return r, {}


def login(c, email, password):
    r = c.get("/login")
    fields = form_fields(r.text, 'id="login-form"') or {}
    fields.update({"email": email, "password": password, "submitLogin": 1})
    return c.post("/login", data=fields)


def logged_in(resp):
    return '"is_logged":true' in resp.text


def pick_delivery_and_pay(c, resp, module):
    """Steps 3 and 4 of the checkout, from the page that shows the delivery step."""
    fields = form_fields(resp.text, 'id="js-delivery"') or {}
    fields.update({"delivery_message": f"apptest {RUN}", "confirmDeliveryOption": 1})
    r = c.post("/order", data=fields)
    s.ok(f"checkout: payment step offers {module} [{r.url}]", f'data-module-name="{module}"' in r.text, r.text[:200])
    r = c.post(f"/module/{module}/validation", data={})
    return r


def place_order(c, module, name, voucher=None):
    """Whatever is in c's cart -> order confirmation, through the real checkout."""
    r = c.get("/cart?action=show")
    if voucher:
        tok = static_token(r.text)
        r = c.post("/cart", data={"token": tok, "addDiscount": 1, "discount_name": voucher})
        s.ok(f"{name}: voucher {voucher} applied", voucher in r.text or "APPTEST" in r.text.upper(), r.text[:200])
    r = c.get("/order")
    if 'id="customer-form"' in r.text and "submitCreate" in r.text:
        # anonymous: personal information as a guest
        r = c.post("/order", data={"id_gender": 1, "firstname": "Guest", "lastname": f"Shopper{RUNW}",
                                   "email": f"guest-{RUN}-{name.replace(' ', '')}@apptest.test", "birthday": "",
                                   "customer_privacy": 1, "psgdpr": 1, "submitCreate": 1, "continue": 1})
        P(f"{name}: guest personal information accepted", r, contains="checkout-addresses-step")   # classic renders id = "..." with spaces
        # hummingbird 2.1 (9.2.0) puts an empty id="checkout-addresses-form" with the same action ahead of the real one
        f = next((m.group(0) for m in re.finditer(r'<form[^>]*action="[^"]*order\?id_address=0"[^>]*>.*?</form>', r.text, re.S)
                  if 'name="address1"' in m.group(0)), None)
        if not f:
            s.ok(f"{name}: address form present", False, r.text[:300])
            return None
        data = apptest.hidden_inputs(f)
        data.update({"firstname": "Guest", "lastname": f"Shopper{RUNW}", "company": "", "address1": "1 Test Street",
                     "address2": "", "city": "Testville", "id_state": "5", "postcode": "99501", "id_country": "21",
                     "phone": "555-0100", "use_same_address": "1", "confirm-addresses": "1"})
        r = c.post("/order?id_address=0", data=data)
    else:
        # signed in with a saved address
        fields = form_fields(r.text, 'id="checkout-addresses-step"') or {}
        addr = rx(r'name="id_address_delivery"[^>]*value="(\d+)"', r.text) or rx(r'value="(\d+)"[^>]*name="id_address_delivery"', r.text)
        if addr:
            fields.update({"id_address_delivery": addr, "id_address_invoice": addr, "confirm-addresses": 1})
            r = c.post("/order", data=fields)
    P(f"{name}: delivery step reached", r, contains=["js-delivery"])
    r = pick_delivery_and_pay(c, r, module)
    return r


# -- storefront -----------------------------------------------------------------


def storefront():
    c = client()
    r = c.get("/")
    P("home", r, contains=["Apptest Shop", "product-miniature"], min_bytes=20000)
    token = static_token(r.text)
    s.ok("home: static token present", bool(token))
    s.ok("home: friendly product links", bool(re.search(r'href="http://apptest\.test/(?:[a-z0-9-]+/)?\d+(?:-\d+)?-[a-z0-9-]+\.html', r.text)))
    s.ok("home: canonical host kept", "apptest.test" in r.text and "127.0.0.1" not in r.text)

    # category tree, pagination and sort
    top = M["categories"]["department"]
    r = c.get(top["url"])
    P("category: department", r, contains=top["name"])
    big = M["category_with_most_products"]
    per_page = 12
    r = c.get(big["url"])
    P(f"category: {big['name']} page 1", r, contains=big["name"])
    ids1 = listing_ids(r.text)
    s.ok("category: first page lists a full page or all products", len(ids1) == min(per_page, big["products"]), f"{len(ids1)} vs {big['products']}")
    total = rx(r"There (?:are|is) (\d+) product", r.text)
    s.ok("category: product count matches the fixture", total is not None and int(total) == big["products"], f"{total} vs {big['products']}")
    if big["products"] > per_page:
        r2 = c.get(big["url"] + "?page=2")
        ids2 = listing_ids(r2.text)
        P("category: page 2", r2, contains="product-miniature")
        s.ok("category: page 2 has other products", bool(ids2) and not set(ids1) & set(ids2), f"{ids1} / {ids2}")
    r = c.get(big["url"] + "?order=product.price.asc")
    P("category: sorted by price ascending", r, contains="product-miniature")
    asc = [float(x.replace(",", "")) for x in re.findall(PRICE_RX, r.text)]
    s.ok("category: price ascending order holds", asc == sorted(asc) and len(asc) > 1, str(asc))
    r = c.get(big["url"] + "?order=product.price.desc")
    desc = [float(x.replace(",", "")) for x in re.findall(PRICE_RX, r.text)]
    s.ok("category: price descending order holds", desc == sorted(desc, reverse=True) and len(desc) > 1, str(desc))
    r = c.get(big["url"] + "?order=product.name.asc", headers=XHR)
    try:
        j = r.json()
        s.ok("category: listing ajax json", "rendered_products" in j and "product-miniature" in j["rendered_products"], list(j)[:8])
        s.ok("category: ajax json carries facets and pagination", "rendered_facets" in j and "pagination" in j, list(j))
    except ValueError:
        s.ok("category: listing ajax json", False, r.text[:200])
    r = c.get(f"/{M['categories']['home']['id']}-home?q=Availability-In+stock", headers=XHR)
    s.ok("category: faceted filter answers", r.status == 200 and "rendered_products" in r.text, f"{r.status} {r.text[:120]}")

    # products
    for key in ("simple", "simple2", "sale", "sold_out"):
        p = M["products"][key]
        r = c.get(p["url"])
        P(f"product: {key} ({p['reference']})", r, contains=[p["name"], p["reference"], "add-to-cart"], min_bytes=30000)
        d = product_data(r.text)
        want = M["golden"]["visitor_prices"][key]["incl"]
        s.ok(f"product: {key} price_amount is the golden {want}", abs(float(d.get("price_amount", -1)) - float(want)) < 1e-6, f"{d.get('price_amount')}")
        s.ok(f"product: {key} data-product carries the reference", d.get("reference") == p["reference"], d.get("reference"))
        if key == "sold_out":
            s.ok("product: sold out product is not purchasable", d.get("availability") == "unavailable" and not d.get("add_to_cart_url"), str(d.get("availability")))
        if key == "simple":
            ids = re.findall(r'<img[^>]*src="(http://apptest\.test/\d+-[a-z_0-9]+/[^"]+\.jpg)"', r.text)
            s.ok("product: image urls are friendly", bool(ids), r.text[:100])
    combo = M["products"]["combo"]
    r = c.get(combo["url"])
    P("product: with combinations", r, contains=[combo["name"], 'name="group['])
    d = product_data(r.text)
    groups = re.findall(r'name="(group\[\d+\])"', r.text)
    s.ok("product: combination groups rendered", len(set(groups)) >= 2, str(set(groups)))
    s.ok("product: default combination selected", int(d.get("id_product_attribute", 0)) in [x["id"] for x in combo["combinations"]], str(d.get("id_product_attribute")))
    tok = static_token(r.text)
    sel = {}
    for g in sorted(set(groups)):
        opts = re.findall(r'name="' + re.escape(g) + r'"[^>]*value="(\d+)"', r.text) or re.findall(r'<option[^>]*value="(\d+)"', rx(r'name="' + re.escape(g) + r'"[^>]*>(.*?)</select>', r.text) or "")
        sel[g] = opts[-1] if opts else "0"
    r = c.post(f"/index.php?controller=product&token={tok}&id_product={combo['id']}&id_customization=0",
               data={**sel, "qty": 1, "action": "refresh", "ajax": 1}, headers=XHR)
    try:
        j = r.json()
        s.ok("product: variant refresh answers with a combination", int(j.get("id_product_attribute", 0)) in [x["id"] for x in combo["combinations"]], str({k: j.get(k) for k in ("id_product_attribute", "product_url")}))
        s.ok("product: variant refresh renders prices", "product_prices" in j and "$" in j["product_prices"], list(j)[:8])
    except ValueError:
        s.ok("product: variant refresh answers with a combination", False, r.text[:200])
    qs = M["products"]["quantity_sale"]
    r = c.get(qs["url"])
    P("product: quantity discount product", r, contains=qs["name"])

    # search
    q = M["search"]
    r = c.get(f"/search?controller=search&s={quote(q['reference_query'])}")
    P("search: by reference", r, contains="product-miniature")
    s.ok("search: reference finds the product", q["reference_product"] in listing_ids(r.text), str(listing_ids(r.text)))
    r = c.get(f"/search?controller=search&s={q['word_query']}")
    P("search: by word", r, contains="product-miniature")
    s.ok("search: a word finds several products", len(listing_ids(r.text)) >= 5, str(len(listing_ids(r.text))))
    # 8.x's fuzzy search maps a word to the closest indexed one within levenshtein 8 (Search::PS_DISTANCE_MAX), so a
    # short nonsense word still finds products there; twice as long is out of reach.
    r = c.get(f"/search?controller=search&s={q['nothing_query'] * (1 if SET9 else 2)}")
    P("search: no match page", r, contains=NO_MATCH)
    r = c.get(f"/search?controller=search&s={q['word_query']}&resultsPerPage=5", headers=XHR)
    try:
        j = r.json()
        s.ok("search: ajax suggestions", bool(j.get("products")), list(j))
    except ValueError:
        s.ok("search: ajax suggestions", False, r.text[:200])

    # listing pages, CMS, contact, brands
    for name, path, extra in (("new products", "/new-products", "product-miniature"),
                              ("prices drop", "/prices-drop", "product-miniature"),
                              ("best sellers", BEST_SELLERS, "product-miniature"),
                              ("brands", "/brands", M["manufacturers"][0]["name"]),
                              ("suppliers", "/supplier" if PS17 else "/suppliers", "Apptest Supplier"),
                              ("sitemap", "/sitemap", "Sitemap"),
                              ("stores", "/stores", None)):
        r = c.get(path)
        if name == "stores" and r.status == 404:
            s.skip("stores page", "the theme/shop has no store page")
            continue
        P(name, r, contains=[extra] if extra else ())
    r = c.get("/prices-drop")
    s.ok("prices drop: lists the discounted products", M["products"]["sale"]["id"] in listing_ids(r.text), str(listing_ids(r.text))[:100])
    mf = M["manufacturers"][0]
    r = c.get(mf["url"])
    P(f"brand page {mf['name']}", r, contains=mf["name"])
    for page in M["cms"]:
        r = c.get(page["url"])
        P(f"cms: {page['title']}", r, contains=page["title"])
    r = c.get("/contact-us")
    P("contact: form", r, contains=["contact-form", "message"])
    f = form_fields(r.text, r'action="[^"]*/contact-us"[^>]*method') or {}
    f.pop("fileUpload", None)
    f.update({"id_contact": 2, "from": f"contact-{RUN}@apptest.test", "message": f"Hello from the application test {RUN}, please ignore.", "submitMessage": 1})
    r = c.post("/contact-us", data=f)
    P("contact: message accepted", r, contains="successfully sent")
    r = c.get("/no-such-page-" + RUN)
    P("404 page is the shop's own", r, status=404, contains="Apptest Shop")

    # static assets and the images the fixture generated
    r = c.get("/robots.txt")
    P("robots.txt", r, contains="User-agent")
    css = rx(r'href="(http://apptest\.test/themes/[^"]+\.css[^"]*)"', c.get("/").text)
    if css:
        r = c.get(urlsplit(css).path + ("?" + urlsplit(css).query if urlsplit(css).query else ""))
        P("theme stylesheet", r, ctype="css", min_bytes=1000)
    simple = M["products"]["simple"]
    page = c.get(simple["url"]).text
    thumb = rx(r'src="http://apptest\.test(/\d+-(?:default_md|home_default|large_default|product_main)/[^"]+\.jpg)"', page)
    if thumb:
        r = c.get(thumb)
        size = jpeg_size(r.body)
        want = {"default_md": 261, "home_default": 250, "large_default": 800, "product_main": 720}[rx(r"/\d+-([a-z_]+)/", thumb)]
        s.ok(f"image: friendly thumbnail {thumb} is a {want}px jpeg", r.status == 200 and size == (want, want), f"{r.status} {size} {r.header('content-type')}")
    else:
        s.ok("image: product page carries a thumbnail", False, "no thumbnail url")
    cover = simple["cover_image"]
    digits = "/".join(str(cover))
    r = c.get(f"/img/p/{digits}/{cover}-home_default.jpg")
    s.ok("image: direct product image path", r.status == 200 and jpeg_size(r.body) == (250, 250) and r.header("content-type", "").startswith("image/jpeg"), f"{r.status} {jpeg_size(r.body)}")
    cat = M["categories"]["department"]
    if cat["has_image"]:
        r = c.get(f"/c/{cat['id']}-category_default/{cat['link_rewrite']}.jpg")
        s.ok("image: friendly category image", r.status == 200 and jpeg_size(r.body) is not None, f"{r.status} {jpeg_size(r.body)}")

    # things that must not be served
    for path in ("/composer.lock", "/composer.json", "/.env", "/app/config/parameters.php", "/vendor/autoload.php",
                 "/var/logs/", "/config/config.inc.php", "/classes/Product.php", "/src/Core/Version.php", "/install/index.php",
                 "/admin-apptest/themes/default/template/layout.tpl"):
        r = c.get(path)
        s.ok(f"private: {path} is not served", r.status in (403, 404) and b"<?php" not in r.body and b"DB_PASSWD" not in r.body, f"{r.status} {r.body[:80]!r}")


def cart_flow():
    c = client()
    simple = M["products"]["simple"]
    combo = M["products"]["combo"]
    tok = static_token(c.get("/").text)
    r, j = add_to_cart(c, simple["id"], 0, 2, tok)
    s.ok("cart: add a simple product (ajax)", r.status == 200 and j.get("success") is True and j.get("quantity") == 2, f"{r.status} {str(j)[:200]}")
    attr = combo["combinations"][1]["id"] if len(combo["combinations"]) > 1 else combo["combinations"][0]["id"]
    r, j = add_to_cart(c, combo["id"], attr, 1, tok)
    s.ok("cart: add a combination (ajax)", r.status == 200 and j.get("success") is True and j.get("id_product_attribute") == attr, f"{r.status} {str(j)[:200]}")
    r = c.get("/cart?action=show")
    P("cart: page", r, contains=[simple["name"], combo["name"], "cart-summary"])
    r, j = add_to_cart(c, M["products"]["sold_out"]["id"], 0, 1, tok)
    s.ok("cart: sold out product is refused", j.get("success") is False or bool(j.get("errors")), str(j)[:200])
    r = c.post("/cart", data={"token": tok, "update": 1, "id_product": simple["id"], "id_product_attribute": 0, "op": "up", "qty": 1, "action": "update", "ajax": 1}, headers=XHR)
    s.ok("cart: quantity up", r.status == 200 and '"success":true' in r.text.replace(" ", "") and '"quantity":3' in r.text.replace(" ", ""), r.text[:200])
    r = c.post("/cart", data={"token": tok, "addDiscount": 1, "discount_name": M["vouchers"]["percent"]})
    P("cart: percentage voucher", r, contains=M["vouchers"]["percent"])
    r = c.post("/cart", data={"token": tok, "addDiscount": 1, "discount_name": "NOSUCHCODE"})
    s.ok("cart: unknown voucher is refused", "doesn't exist" in r.text or "does not exist" in r.text or "not exist" in r.text or "invalid" in r.text.lower(), r.text[:100])
    r = c.get(f"/cart?delete=1&id_product={simple['id']}&id_product_attribute=0&token={tok}&action=update", headers=XHR)
    s.ok("cart: line removed", r.status == 200, r.text[:100])


def account_flow():
    c = client()
    email = f"reg-{RUN}@apptest.test"
    password = f"Reg-{RUN}-Pass1"
    r = c.get(REGISTRATION)
    P("registration: form", r, contains="submitCreate")
    f = form_fields(r.text, 'id="customer-form"') or {}
    f.update({"id_gender": 1, "firstname": "Reggie", "lastname": f"Newcomer{RUNW}", "email": email, "password": password,
              "birthday": "", "customer_privacy": 1, "psgdpr": 1, "submitCreate": 1, "continue": 1})
    r = c.post(REGISTRATION, data=f)
    P("registration: new customer lands in the account", r, contains="Reggie")
    s.ok("registration: signed in afterwards", logged_in(r), r.text[:100])
    r = c.get("/my-account")
    P("my account", r, contains=["Information", "Sign out"])
    r = c.get("/index.php?mylogout")
    s.ok("logout leaves the account", not logged_in(c.get("/login")), "still logged in")
    r = login(c, email, "wrong-" + password)
    s.ok("login: wrong password is refused", "Authentication failed" in r.text, r.text[:100])
    r = login(c, email, password)
    P("login: the new customer signs in again", r, contains="Reggie")

    known = M["customers"][0]
    c2 = client()
    r = login(c2, known["email"], known["password"])
    P(f"login: seeded customer {known['email']}", r, contains=known["firstname"])
    s.ok("login: seeded customer is signed in", logged_in(r), r.text[:100])
    r = c2.get("/my-account")
    P("seeded customer: my account", r, contains="Information")
    r = c2.get("/order-history")
    P("seeded customer: order history", r, contains="Order")
    with_orders = [x for x in M["customers"] if x["order_references"]]
    if with_orders:
        c3 = client()
        k = with_orders[0]
        login(c3, k["email"], k["password"])
        r = c3.get("/order-history")
        P(f"order history of {k['email']}", r, contains=k["order_references"][0])
        detail = rx(r'href="([^"]*order-detail[^"]*)"', r.text[r.text.find(k["order_references"][0]):])
        s.ok("order history links to the order detail", bool(detail), r.text[:100])
        if detail:
            link = urlsplit(html.unescape(detail))
            r = c3.get(link.path + ("?" + link.query if link.query else ""))
            P("order detail page", r, contains=[k["order_references"][0], "Order details"])
    r = c2.get("/addresses")
    P("seeded customer: addresses", r, contains="Address")
    r = c2.get("/address")
    P("seeded customer: new address form", r, contains=["address1", "id_country", "postcode"])
    r = c2.get("/identity")
    P("seeded customer: identity page", r, contains=known["email"])
    r = c2.get("/discount")
    P("seeded customer: vouchers page", r)
    r = c2.get("/index.php?controller=history")
    P("history via legacy controller url", r)


def checkout_flows():
    # 1. guest, bank wire
    c = client()
    add_to_cart(c, M["products"]["simple2"]["id"], 0, 1)
    add_to_cart(c, M["products"]["simple"]["id"], 0, 2)
    r = place_order(c, "ps_wirepayment", "guest wire")
    if r is not None:
        P("checkout: guest wire order confirmation", r, contains="confirmed")
        s.ok("checkout: confirmation url", "order-confirmation" in r.url, r.url)
        ref = rx(r"Order reference:\s*([A-Z]{5,12})", r.text)
        s.ok("checkout: confirmation shows the order reference", bool(ref), r.text[:100])
        globals()["GUEST_REF"] = ref
    # 2. seeded customer, cash on delivery, with a voucher
    known = M["customers"][2]
    c2 = client()
    login(c2, known["email"], known["password"])
    add_to_cart(c2, M["products"]["simple"]["id"], 0, 1)
    combo = M["products"]["combo"]
    add_to_cart(c2, combo["id"], combo["combinations"][0]["id"], 1)
    r = place_order(c2, PAY2, "customer wire" if PS17 else "customer cod", voucher=M["vouchers"]["percent"])
    if r is not None:
        P("checkout: customer order confirmation", r, contains="confirmed")
        ref = rx(r"Order reference:\s*([A-Z]{5,12})", r.text)
        globals()["CUSTOMER_REF"] = ref
        s.ok("checkout: customer order reference shown", bool(ref), r.text[:100])
        r = c2.get("/order-history")
        s.ok("checkout: the new order is in the customer's history", bool(ref) and ref in r.text, ref)
    # 3. seeded customer, cheque
    known = M["customers"][3]
    c3 = client()
    login(c3, known["email"], known["password"])
    add_to_cart(c3, M["products"]["simple2"]["id"], 0, 3)
    r = place_order(c3, "ps_checkpayment", "customer cheque")
    if r is not None:
        P("checkout: cheque order confirmation", r, contains="confirmed")


# -- back office ----------------------------------------------------------------


class BO:
    def __init__(self):
        self.c = client()
        self.base = "/" + ADMIN["dir"]
        self.token = None

    def url(self, path):
        sep = "&" if "?" in path else "?"
        return f"{self.base}{path}{sep}_token={self.token}"

    def get(self, path, **kw):
        return self.c.get(self.url(path), **kw)

    def post(self, path, data, **kw):
        return self.c.post(self.url(path), data=data, **kw)

    def legacy(self, controller):
        """A legacy controller's own link, token included, as the dashboard's menu carries it."""
        m = re.search(r'href="([^"]*controller=' + controller + r'&(?:amp;)?token=[0-9a-f]+)"', self.menu)
        return html.unescape(m.group(1)).replace("http://" + args.host, "") if m else None


def bo_login(bo, password, **extra):
    """9.x: the Symfony login form. 8.x: the legacy AdminLogin controller, whose redirect field is left to its default (the dashboard)."""
    r = bo.c.get(bo.base + "/")
    if SET9:
        fields = apptest.hidden_inputs(r.text, 'id="login_form"')
        url = bo.base + "/login?_token="
    else:
        fields = {"submitLogin": 1}
        url = bo.base + "/index.php?controller=AdminLogin"
    return bo.c.post(url, data={**fields, "email": ADMIN["email"], "passwd": password, **extra})


def backoffice():
    bo = BO()
    r = bo.c.get(bo.base + "/")
    P("bo: login page", r, contains=["login_form", "passwd"])
    r = bo_login(bo, "wrong-" + ADMIN["password"])
    s.ok("bo: wrong password is refused", r.status == 200 and "login_form" in r.text, f"{r.status}")
    r = bo_login(bo, ADMIN["password"], stay_logged_in=1)
    P("bo: dashboard after login", r, contains=["Dashboard", "sidebar"], min_bytes=50000)
    token = rx(r"[?&]_token=([A-Za-z0-9._-]+)", r.text)
    if not token:
        s.ok("bo: session token found", False, r.text[:200])
        return
    bo.token = token
    bo.menu = r.text

    # 8.x still serves carts, cart rules and image settings from legacy controllers; "legacy:<Controller>" paths
    pages = (("products", PRODUCTS if PS17 else "/sell/catalog/products/", "Products"),
             ("categories", "/sell/catalog/categories", "Categories"),
             ("brands", "/sell/catalog/brands/", "Brands"),
             ("attributes", "/sell/catalog/attribute-groups/", "Attributes"),
             ("stock", "/sell/stocks/", "Stock"),
             ("orders", "/sell/orders/", "Orders"),
             ("carts", "/sell/orders/carts/" if SET9 else "legacy:AdminCarts", "Shopping Carts"),
             ("invoices", "/sell/orders/invoices/", "Invoices"),
             ("customers", "/sell/customers/", "Customers"),
             ("addresses", "/sell/addresses/", "Addresses"),
             ("customer service", "/sell/customer-service/order-messages/", "Order messages"),
             ("cart rules", "/index.php?controller=AdminCartRules" if SET9 else "legacy:AdminCartRules", "Cart Rules"),
             ("cms pages", "/improve/design/cms-pages/", "Pages"),
             ("themes", "/improve/design/themes/", "Theme"),
             ("image settings", "/improve/design/image-settings/" if SET9 else "legacy:AdminImages", "Image Settings"),
             ("positions", "/improve/design/modules/positions/", "Positions"),
             ("carriers", "/improve/shipping/carriers/", "Carriers"),
             ("payment methods", "/improve/payment/payment_methods", "Payment"),
             ("localization", "/improve/international/localization/", "Localization"),
             ("taxes", "/improve/international/taxes/", "Taxes"),
             ("shop parameters: general", "/configure/shop/preferences/preferences", "Preferences"),
             ("shop parameters: product settings", "/configure/shop/product-preferences/", "Product settings" if SET9 else "Product Settings"),
             ("shop parameters: seo", "/configure/shop/seo-urls/", "SEO"),
             ("performance", "/configure/advanced/performance/", "Performance"),
             ("system information", "/configure/advanced/system-information/", "Information"),
             ("webservice keys", "/configure/advanced/webservice-keys/", "Webservice"),
             ("logs", "/configure/advanced/logs/", "Logs"),
             ("employees", "/configure/advanced/employees/", "Employees"),
             ("module manager", "/improve/modules/manage", "Module"))
    for name, path, title in pages:
        if path.startswith("legacy:"):
            link = bo.legacy(path[7:])
            r = bo.c.get(link) if link else bo.c.get(bo.base + "/index.php?controller=" + path[7:])
        else:
            r = bo.get(path)
        if PS17 and name == "module manager":
            # its addons login form carries the generic AJAX error string in a data attribute, which is not an error
            r = scrubbed(r, 'data-error-message="An error occurred while processing your request."')
        P(f"bo: {name}", r, contains=[title] if title else (), min_bytes=20000)

    # product grid: filter by reference, then the edit page of what it found
    p = M["products"]["simple"]
    r = bo.get(PRODUCTS)
    if PS17:
        # the old catalog page filters through its list form: every filter_column_* field posted back to the form's own action
        form = apptest.hidden_inputs(r.text, 'id="product_catalog_list"')
        action = rx(r'id="product_catalog_list"[^>]*action="([^"]+)"', r.text)
        r = bo.c.post(html.unescape(action), data={**form, "filter_column_reference": p["reference"], "products_filter_submit": 1}) if action else r
    else:
        form = apptest.hidden_inputs(r.text, 'id="product_filter_form"')
        r = bo.post(PRODUCTS, {**form, "product[reference]": p["reference"], "product[actions][search]": ""}, follow=False)
        loc = r.header("location")
        if loc:
            r = bo.c.get(loc.replace("http://" + args.host, ""))
    P("bo: product grid filtered by reference", r, contains=[p["reference"], p["name"]])
    rows = set(re.findall(PRODUCT_EDIT_RX, r.text))
    s.ok("bo: product grid filter narrows to one row", len(rows) == 1, str(rows))
    r = bo.get(PRODUCT_EDIT % p["id"])
    P("bo: product edit page", r, contains=[p["reference"], p["name"]], min_bytes=50000)
    c2 = M["products"]["combo"]
    r = bo.get(PRODUCT_EDIT % c2["id"])
    P("bo: product with combinations edit page", r, contains=[c2["reference"]])
    if PS17:
        # "new product" in the old catalog creates a draft row and redirects to its edit form
        r = bo.get(PRODUCTS + "/new", follow=False)
        loc = r.header("location") or ""
        s.ok("bo: new product form", r.status == 302 and bool(re.search(r"/sell/catalog/products/\d+\?", loc)), f"{r.status} {loc}")
        if loc:
            P("bo: the new product's edit form opens", bo.c.get(loc.replace("http://" + args.host, "")), contains="Basic settings")
    else:
        r = bo.get(PRODUCTS + "create")
        s.ok("bo: new product form", r.status in (200, 302), f"{r.status}")

    # orders and customers
    o = M["orders"][0]
    r = bo.get("/sell/orders/")
    form = apptest.hidden_inputs(r.text, 'id="order_filter_form"')
    r = bo.post("/sell/orders/", {**form, "order[reference]": o["reference"], "order[actions][search]": ""}, follow=False)
    loc = r.header("location")
    if loc:
        r = bo.c.get(loc.replace("http://" + args.host, ""))
    P("bo: orders grid filtered by reference", r, contains=o["reference"])
    r = bo.get(f"/sell/orders/{o['id']}/view")
    P("bo: order detail", r, contains=[o["reference"], "Order"], min_bytes=50000)
    k = M["customers"][0]
    r = bo.get("/sell/customers/")
    form = apptest.hidden_inputs(r.text, 'id="customer_filter_form"')
    r = bo.post("/sell/customers/", {**form, "customer[email]": k["email"], "customer[actions][search]": ""}, follow=False)
    loc = r.header("location")
    if loc:
        r = bo.c.get(loc.replace("http://" + args.host, ""))
    P("bo: customers grid filtered by email", r, contains=k["email"])
    r = bo.get(f"/sell/customers/{k['id']}/view")
    P("bo: customer detail", r, contains=[k["email"], k["lastname"]])
    if globals().get("CUSTOMER_REF"):
        r = bo.get("/sell/orders/")
        form = apptest.hidden_inputs(r.text, 'id="order_filter_form"')
        r = bo.post("/sell/orders/", {**form, "order[reference]": globals()["CUSTOMER_REF"], "order[actions][search]": ""}, follow=False)
        loc = r.header("location")
        if loc:
            r = bo.c.get(loc.replace("http://" + args.host, ""))
        P("bo: the order placed at the storefront shows up", r, contains=globals()["CUSTOMER_REF"])

    # a back office write: a category through the Symfony form
    r = bo.get("/sell/catalog/categories/new")
    P("bo: new category form", r, contains="category")
    f = form_fields(r.text, r'name="category"') or {}
    name = f"Apptest BO category {RUN}"
    if f:
        f.update({"category[name][1]": name, "category[active]": "1", "category[id_parent]": "2", "category[description][1]": "created by the application test",
                  "category[link_rewrite][1]": f"apptest-bo-{RUN}", "category[meta_title][1]": name})
        r = bo.post("/sell/catalog/categories/new", f, follow=False)
        s.ok("bo: category created through the form", r.status in (302, 303), f"{r.status} {r.text[:200]}")
        if r.header("location"):
            r = bo.c.get(r.header("location").replace("http://" + args.host, ""))
            P("bo: created category is listed", r, contains=name)
    else:
        s.ok("bo: category form has fields", False, r.text[:200])

    # performance: the clear cache action, then everything renders from cold
    r = bo.get("/configure/advanced/performance/")
    href = rx(r'(/' + ADMIN["dir"] + r'/configure/advanced/performance/clear-cache\?_token=[^"]+)"', r.text)
    if href:
        r = bo.c.get(html.unescape(href), follow=False)
        s.ok("bo: clear cache action redirects back", r.status in (302, 303), f"{r.status} {r.text[:150]}")
        r = bo.c.get(html.unescape(r.header("location") or "").replace("http://" + args.host, "") or bo.url("/configure/advanced/performance/"))
        P("bo: performance page after clearing the cache", r, contains="Performance")
    else:
        s.ok("bo: clear cache link found", False, "no link")
    r = bo.get(PRODUCTS)
    P("bo: products after cache clear (cold Symfony container)", r, contains="Products")
    r = bo.c.get(M["products"]["simple"]["url"])
    P("front: product after cache clear (cold Smarty)", r, contains=M["products"]["simple"]["name"])

    r = bo.c.get(bo.url("/logout") if SET9 else bo.base + "/index.php?controller=AdminLogin&logout=1")
    r = bo.c.get(bo.base + "/")
    s.ok("bo: logout ends the session", "login_form" in r.text, r.text[:100])


# -- webservice -------------------------------------------------------------------


def ws_request(c, method, path, body=None, fmt=None, key=True, headers=None, params=""):
    hdrs = {}
    if key:
        hdrs["Authorization"] = "Basic " + base64.b64encode((WS_KEY + ":").encode()).decode()
    if headers:
        hdrs.update(headers)
    q = params
    if fmt:
        q += ("&" if q else "") + f"output_format={fmt}"
    url = f"/api/{path}" + (f"?{q}" if q else "")
    if body is not None and "Content-Type" not in hdrs:
        hdrs["Content-Type"] = "text/xml"
    return c.request(method, url, data=body, headers=hdrs, follow=False)


def flatten(node, path, out):
    if isinstance(node, dict):
        if list(node) and False:
            pass
        for k in sorted(node):
            if k in ("date_add", "date_upd"):
                continue
            flatten(node[k], f"{path}.{k}", out)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            flatten(v, f"{path}.{i}", out)
    else:
        out.append(f"{path}=" + ("" if node is None else ("1" if node is True else "0" if node is False else str(node))))
    return out


def canonical_hash(payload):
    root = next(iter(payload))
    return hashlib.sha256("\n".join(flatten(payload[root], root, [])).encode()).hexdigest()


def xml_text(root, tag):
    e = root.find(f".//{tag}")
    return e.text if e is not None else None


def webservice():
    c = client()
    r = ws_request(c, "GET", "products", key=False)
    s.ok("ws: no key is refused", r.status == 401, f"{r.status}")
    r = ws_request(c, "GET", "products", key=False, params="ws_key=NOTAKEYNOTAKEYNOTAKEYNOTAKEY12")
    s.ok("ws: wrong key is refused", r.status == 401, f"{r.status}")
    r = ws_request(c, "GET", "")
    P("ws: resource index (xml)", r, contains=["<api", "products"], ctype="xml")
    r = ws_request(c, "GET", "", key=False, params=f"ws_key={WS_KEY}")
    s.ok("ws: key as query parameter works", r.status == 200 and "<api" in r.text, f"{r.status}")
    r = ws_request(c, "GET", "products", fmt="JSON", params="display=[id,name,reference]&limit=10&sort=[id_ASC]")
    try:
        j = r.json()
        rows = j.get("products", [])
        s.ok("ws: products list json", r.status == 200 and len(rows) == 10 and all(x.get("reference") for x in rows), f"{r.status} {str(j)[:200]}")
    except ValueError:
        s.ok("ws: products list json", False, r.text[:200])
    p = M["products"]["simple"]
    r = ws_request(c, "GET", "products", fmt="JSON", params=f"filter[reference]=[{p['reference']}]&display=[id,reference]")
    try:
        s.ok("ws: filter by reference finds the product", r.json()["products"][0]["id"] == p["id"], r.text[:200])
    except (ValueError, KeyError, IndexError):
        s.ok("ws: filter by reference finds the product", False, r.text[:200])
    r = ws_request(c, "GET", "products", fmt="JSON", params="display=[id]&limit=0")
    s.ok("ws: count of products in list", r.status == 200, f"{r.status}")

    # goldens: the payload the builder's PHP produced for these products
    for key, gold in M["golden"]["webservice"].items():
        resource = "categories" if key == "category" else "products"
        r = ws_request(c, "GET", f"{resource}/{gold['id']}", fmt="JSON")
        try:
            got = canonical_hash(r.json())
        except (ValueError, StopIteration) as e:
            got = f"unparsable: {e}"
        s.ok(f"ws: {key} payload matches the golden sha256", r.status == 200 and got == gold["sha256"], f"{r.status} got {got}")
        if key == "simple" and got != gold["sha256"]:
            mine = flatten(r.json()["product"], "product", [])
            diff = [x for x in mine if x not in gold["fields"]] + [x for x in gold["fields"] if x not in mine]
            print("    | field differences:", diff[:12], flush=True)
    r = ws_request(c, "GET", f"products/{p['id']}")
    P("ws: product xml", r, contains=[f"<reference><![CDATA[{p['reference']}]]></reference>"], ctype="xml")
    try:
        root = ET.fromstring(r.body)
        s.ok("ws: product xml parses and names the product", (xml_text(root, "name/language") or "").strip() == p["name"], xml_text(root, "name/language"))
    except ET.ParseError as e:
        s.ok("ws: product xml parses", False, str(e))
    r = ws_request(c, "GET", "categories", fmt="JSON", params="display=[id,name]&limit=5")
    s.ok("ws: categories json", r.status == 200 and len(r.json().get("categories", [])) == 5, f"{r.status} {r.text[:120]}")
    r = ws_request(c, "GET", "customers", fmt="JSON", params="display=[id,email,firstname]&limit=5&sort=[id_DESC]")
    s.ok("ws: customers json", r.status == 200 and len(r.json().get("customers", [])) == 5, f"{r.status} {r.text[:120]}")
    r = ws_request(c, "GET", "customers", params="display=full&limit=3")
    P("ws: customers xml", r, contains="<customers>", ctype="xml")
    r = ws_request(c, "GET", "orders", fmt="JSON", params="display=[id,reference,current_state,total_paid]&limit=5")
    s.ok("ws: orders json", r.status == 200 and len(r.json().get("orders", [])) == 5, f"{r.status} {r.text[:120]}")
    o = M["orders"][0]
    r = ws_request(c, "GET", f"orders/{o['id']}", fmt="JSON")
    try:
        got = r.json()["order"]
        s.ok("ws: order total matches the fixture", abs(float(got["total_paid_tax_incl"]) - float(o["total_paid_tax_incl"])) < 1e-6 and got["reference"] == o["reference"], f"{got.get('total_paid_tax_incl')} vs {o['total_paid_tax_incl']}")
    except (ValueError, KeyError) as e:
        s.ok("ws: order total matches the fixture", False, str(e))
    r = ws_request(c, "GET", "nosuchresource")
    s.ok("ws: unknown resource is refused", r.status in (400, 404), f"{r.status}")
    r = ws_request(c, "HEAD", "products")
    s.ok("ws: HEAD answers", r.status == 200, f"{r.status}")

    # writes: a customer, an address, a cart, a product, an image
    r = ws_request(c, "GET", "customers", params="schema=blank")
    P("ws: blank customer schema", r, contains="<customer>")
    email = f"ws-{RUN}@apptest.test"
    xml = (f'<prestashop xmlns:xlink="http://www.w3.org/1999/xlink"><customer><lastname><![CDATA[Api{RUNW}]]></lastname>'
           f"<firstname><![CDATA[Webservice]]></firstname><email><![CDATA[{email}]]></email><passwd><![CDATA[Ws-Pass-{RUN}]]></passwd>"
           "<id_default_group>3</id_default_group><active>1</active><id_gender>1</id_gender>"
           "<associations><groups><group><id>3</id></group></groups></associations></customer></prestashop>")
    r = ws_request(c, "POST", "customers", body=xml)
    cid = None
    try:
        cid = int(xml_text(ET.fromstring(r.body), "id"))
    except (ET.ParseError, TypeError, ValueError):
        pass
    s.ok("ws: customer created (201)", r.status == 201 and cid, f"{r.status} {r.text[:300]}")
    if cid:
        r = ws_request(c, "GET", f"customers/{cid}", fmt="JSON")
        s.ok("ws: created customer reads back", r.status == 200 and r.json()["customer"]["email"] == email, r.text[:150])
        upd = xml.replace("<customer>", f"<customer><id>{cid}</id>").replace(f"Api{RUNW}", f"Api{RUNW}Updated")
        r = ws_request(c, "PUT", f"customers/{cid}", body=upd)
        s.ok("ws: customer updated (PUT)", r.status == 200, f"{r.status} {r.text[:300]}")
        r = ws_request(c, "GET", f"customers/{cid}", fmt="JSON")
        s.ok("ws: update is visible", r.status == 200 and r.json()["customer"]["lastname"] == f"Api{RUNW}Updated", r.text[:150])
        addr = ('<prestashop xmlns:xlink="http://www.w3.org/1999/xlink"><address>'
                f"<id_customer>{cid}</id_customer><id_country>21</id_country><id_state>5</id_state><alias>Api</alias>"
                f"<lastname>Api{RUNW}</lastname><firstname>Webservice</firstname><address1>1 Api Road</address1>"
                "<city>Apiville</city><postcode>99501</postcode><phone>555-0100</phone></address></prestashop>")
        r = ws_request(c, "POST", "addresses", body=addr)
        aid = None
        try:
            aid = int(xml_text(ET.fromstring(r.body), "id"))
        except (ET.ParseError, TypeError, ValueError):
            pass
        s.ok("ws: address created (201)", r.status == 201 and aid, f"{r.status} {r.text[:300]}")
        cart = ('<prestashop xmlns:xlink="http://www.w3.org/1999/xlink"><cart>'
                f"<id_currency>1</id_currency><id_lang>1</id_lang><id_customer>{cid}</id_customer>"
                f"<id_address_delivery>{aid or 0}</id_address_delivery><id_address_invoice>{aid or 0}</id_address_invoice><id_carrier>2</id_carrier>"
                f"<associations><cart_rows><cart_row><id_product>{p['id']}</id_product><id_product_attribute>0</id_product_attribute>"
                "<id_address_delivery>0</id_address_delivery><quantity>2</quantity></cart_row></cart_rows></associations></cart></prestashop>")
        r = ws_request(c, "POST", "carts", body=cart)
        kid = None
        try:
            kid = int(xml_text(ET.fromstring(r.body), "id"))
        except (ET.ParseError, TypeError, ValueError):
            pass
        s.ok("ws: cart created (201)", r.status == 201 and kid, f"{r.status} {r.text[:300]}")
        if kid:
            r = ws_request(c, "GET", f"carts/{kid}", fmt="JSON")
            rows = (r.json().get("cart", {}).get("associations", {}) or {}).get("cart_rows", [])
            s.ok("ws: cart reads back with its line", r.status == 200 and len(rows) == 1 and str(rows[0]["id_product"]) == str(p["id"]) and str(rows[0]["quantity"]) == "2", r.text[:200])

    name = f"Webservice product {RUN}"
    prod = ('<prestashop xmlns:xlink="http://www.w3.org/1999/xlink"><product>'
            f"<id_category_default>{M['categories']['section']['id']}</id_category_default><price>19.99</price><id_tax_rules_group>1</id_tax_rules_group>"
            f"<reference>WS-{RUN}</reference><state>1</state><active>1</active><available_for_order>1</available_for_order><show_price>1</show_price>"
            "<minimal_quantity>1</minimal_quantity><visibility>both</visibility>"
            f'<name><language id="1"><![CDATA[{name}]]></language></name>'
            f'<link_rewrite><language id="1">webservice-product-{RUN}</language></link_rewrite>'
            '<description><language id="1"><![CDATA[<p>Created through the webservice.</p>]]></language></description>'
            f"<associations><categories><category><id>{M['categories']['section']['id']}</id></category></categories></associations></product></prestashop>")
    r = ws_request(c, "POST", "products", body=prod)
    pid = None
    try:
        pid = int(xml_text(ET.fromstring(r.body), "id"))
    except (ET.ParseError, TypeError, ValueError):
        pass
    s.ok("ws: product created (201)", r.status == 201 and pid, f"{r.status} {r.text[:400]}")
    if pid:
        r = ws_request(c, "GET", f"products/{pid}", fmt="JSON")
        s.ok("ws: created product reads back", r.status == 200 and r.json()["product"]["reference"] == f"WS-{RUN}", r.text[:150])
        # an image through the upload endpoint: PrestaShop resizes it with GD/Imagick into every product image type
        src = c.get(M["products"]["simple"]["url"]).text
        thumb = rx(r'src="http://apptest\.test(/\d+-large_default/[^"]+\.jpg)"', src) or rx(r'src="http://apptest\.test(/\d+-[a-z_]+/[^"]+\.jpg)"', src)
        img = c.get(thumb).body if thumb else b""
        body, ctype = apptest.encode_multipart({}, {"image": (f"apptest-{RUN}.jpg", img, "image/jpeg")})
        r = ws_request(c, "POST", f"images/products/{pid}", body=body, headers={"Content-Type": ctype})
        s.ok("ws: image uploaded (200/201)", r.status in (200, 201) and b"<image" in r.body or r.status in (200, 201), f"{r.status} {r.text[:300]}")
        iid = rx(r"<id>(?:<!\[CDATA\[)?(\d+)", r.text)
        if iid:
            r = ws_request(c, "GET", f"images/products/{pid}/{iid}")
            s.ok("ws: uploaded image is served", r.status == 200 and r.header("content-type", "").startswith("image/") and len(r.body) > 1000, f"{r.status} {r.header('content-type')}")
            r = ws_request(c, "GET", f"images/products/{pid}/{iid}/home_default")
            s.ok("ws: uploaded image has its thumbnails", r.status == 200 and jpeg_size(r.body) == (250, 250), f"{r.status} {jpeg_size(r.body)}")
            r = c.get(f"/img/p/{'/'.join(iid)}/{iid}-home_default.jpg")
            s.ok("ws: thumbnail is on disk and served by nginx", r.status == 200 and jpeg_size(r.body) == (250, 250), f"{r.status} {jpeg_size(r.body)}")
    if pid:
        # the shelf's payload is a golden: leave the catalog as the run found it
        r = ws_request(c, "DELETE", f"products/{pid}")
        s.ok("ws: created product deleted", r.status == 200, f"{r.status} {r.text[:150]}")
        r = ws_request(c, "GET", f"products/{pid}", fmt="JSON")
        s.ok("ws: deleted product is gone", r.status == 404, f"{r.status}")
    r = ws_request(c, "POST", "customers", body="<prestashop><customer><lastname>x")
    s.ok("ws: malformed xml is refused", r.status in (400, 500) and r.status != 201, f"{r.status}")


# -- concurrency ---------------------------------------------------------------------


def concurrency(n=50):
    urls = [M["products"][k]["url"] for k in ("simple", "simple2", "combo", "sale")]
    urls += [M["category_with_most_products"]["url"], M["categories"]["department"]["url"], "/", "/new-products", BEST_SELLERS, "/prices-drop",
             f"/search?controller=search&s={M['search']['word_query']}"]

    def one(i):
        cl = client()
        out = []
        r = cl.get(urls[i % len(urls)])
        out.append((r.status, r.error_marker()))
        if i % 2 == 0:
            tok = static_token(r.text) or static_token(cl.get("/").text)
            pid = M["products"]["simple"]["id"]
            rr = cl.post("/cart", data={"token": tok, "id_product": pid, "id_product_attribute": 0, "id_customization": 0, "qty": 1, "add": 1, "action": "update"}, headers=XHR)
            out.append((rr.status, rr.error_marker()))
            rr = cl.get("/cart?action=show")
            out.append((rr.status, rr.error_marker()))
        return out

    with concurrent.futures.ThreadPoolExecutor(max_workers=n) as ex:
        results = list(ex.map(one, range(n)))
    flat = [x for out in results for x in out]
    bad = [x for x in flat if x[0] != 200 or x[1]]
    s.ok(f"concurrency: {n} parallel visitors, {len(flat)} requests, all 200 and clean", not bad, str(bad[:3]))


if PS16:
    exec(compile(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "web16.py")).read(), "web16.py", "exec"), globals())

for section in (storefront, cart_flow, account_flow, checkout_flows, webservice, concurrency, backoffice):
    s.guard(section.__name__, section)
s.finish()
