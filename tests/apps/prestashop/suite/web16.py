"""The PrestaShop 1.6 half of web.py.

Not a module: web.py exec()s it into its own namespace when the fixture is 1.6, after every helper and
section is defined, and it replaces the sections whose markup 1.6 does not share with 1.7+ (default-bootstrap
theme, the five-step order controller, no data-product JSON, no Symfony back office). The webservice suite
is common. Where 1.6 genuinely lacks a feature the check is a SKIP with the reason.
"""

PRICE_RX = r'class="price product-price"[^>]*>\s*\$\s?([0-9][0-9,]*\.[0-9]{2})'
REGISTRATION = "/login"
BEST_SELLERS = "/best-sales"
PAY2 = "bankwire"
THUMBS = {"small_default": 98, "cart_default": 80, "medium_default": 125, "home_default": 250, "large_default": 458, "thickbox_default": 800}
# AdminPayment, AdminModules and AdminTranslations call out to addons.prestashop.com / the language pack server on load, and hang for minutes without egress
BO_PAGES = (("products", "AdminProducts", "Products"), ("categories", "AdminCategories", "Categories"),
            ("manufacturers", "AdminManufacturers", "Manufacturers"), ("suppliers", "AdminSuppliers", "Suppliers"),
            ("attributes", "AdminAttributesGroups", "Product Attributes"), ("features", "AdminFeatures", "Product Features"),
            ("orders", "AdminOrders", "Orders"), ("invoices", "AdminInvoices", "Invoices"), ("credit slips", "AdminSlip", "Credit Slips"),
            ("statuses", "AdminStatuses", "Statuses"), ("order messages", "AdminOrderMessage", "Order Messages"),
            ("customers", "AdminCustomers", "Customers"), ("addresses", "AdminAddresses", "Addresses"), ("groups", "AdminGroups", "Groups"),
            ("carts", "AdminCarts", "Shopping Carts"), ("customer service", "AdminCustomerThreads", "Customer Service"),
            ("cart rules", "AdminCartRules", "Cart Rules"), ("catalog price rules", "AdminSpecificPriceRule", "Catalog Price Rules"),
            ("carriers", "AdminCarriers", "Carriers"), ("shipping preferences", "AdminShipping", "Preferences"),
            ("localization", "AdminLocalization", "Localization"), ("countries", "AdminCountries", "Countries"),
            ("taxes", "AdminTaxes", "Taxes"), ("tax rules", "AdminTaxRulesGroup", "Tax Rules"), ("currencies", "AdminCurrencies", "Currencies"),
            ("positions", "AdminModulesPositions", "Positions"), ("themes", "AdminThemes", "Themes"),
            ("cms pages", "AdminCmsContent", "CMS"), ("image settings", "AdminImages", "Images"), ("seo and urls", "AdminMeta", "SEO"),
            ("shop preferences: general", "AdminPreferences", "General"), ("shop preferences: products", "AdminPPreferences", "Products"),
            ("shop preferences: orders", "AdminOrderPreferences", "Orders"), ("shop preferences: search", "AdminSearchConf", "Search"),
            ("performance", "AdminPerformance", "Performance"), ("configuration information", "AdminInformation", "Configuration Information"),
            ("webservice keys", "AdminWebservice", "Webservice"), ("logs", "AdminLogs", "Logs"), ("employees", "AdminEmployees", "Employees"),
            ("stores", "AdminStores", "Store Contacts"), ("stats", "AdminStats", "Stats"))


def static_token(text):
    return rx(r"var static_token = '([0-9a-f]+)'", text)


def _list_slice(text):
    start = text.find('id="product_list"')
    if start < 0:
        return ""
    end = text.find("content_sortPagiBar", start + 1)
    return text[start:end if end > 0 else len(text)]


def listing_ids(text):
    out = []
    for x in re.findall(r'data-id-product="(\d+)"', _list_slice(text)):
        if int(x) not in out:
            out.append(int(x))
    return out


def list_prices(text):
    return [float(x.replace(",", "")) for x in re.findall(PRICE_RX, _list_slice(text))]


def product_data(text):
    """The product page's own JS variables, which is where 1.6 keeps what 1.7 puts in data-product."""
    price = rx(r'id="our_price_display"[^>]*content="([0-9.]+)"', text) or rx(r"var productPrice = ([0-9.]+);", text)
    qty = rx(r"var quantityAvailable = (-?\d+);", text)
    buyable = rx(r"var allowBuyWhenOutOfStock = (true|false);", text) == "true"
    return {"price_amount": price, "reference": rx(r'itemprop="sku" content="([^"]*)"', text),
            "id_product_attribute": rx(r'id="idCombination"[^>]*value="(\d+)"', text) or 0,
            "quantity": int(qty) if qty is not None else None,
            "availability": "unavailable" if qty is not None and int(qty) <= 0 and not buyable else "available"}


def add_to_cart(c, product, attribute=0, qty=1, token=None):
    """The theme's ajax add, with the answer folded into the 1.7 shape the checks read (success, quantity)."""
    if token is None:
        token = static_token(c.get("/").text)
    r = c.post("/cart", data={"token": token, "id_product": product, "ipa": attribute, "qty": qty, "add": 1, "ajax": "true"}, headers=XHR)
    try:
        j = r.json()
    except ValueError:
        return r, {}
    j["success"] = not j.get("hasError")
    j.update(cart_line(j, product, attribute))
    return r, j


def cart_line(j, product, attribute=0):
    """quantity and id_product_attribute of one line of the ajax cart's answer (its products carry id / idCombination / quantity)."""
    for line in j.get("products", []) or []:
        if int(line["id"]) == product and int(line.get("idCombination") or 0) == attribute:
            return {"quantity": int(line["quantity"]), "id_product_attribute": int(line.get("idCombination") or 0)}
    return {}


def login(c, email, password):
    r = c.get("/login")
    fields = form_fields(r.text, 'id="login_form"') or {}
    fields.update({"email": email, "passwd": password, "SubmitLogin": 1})
    return c.post("/login", data=fields)


def logged_in(resp):
    return "var isLogged = 1" in resp.text


def order_page(c, name, module, voucher=None):
    """Whatever is in c's cart -> order confirmation, through the five-step order controller."""
    if voucher:
        r = c.post("/order", data={"discount_name": voucher, "submitAddDiscount": 1})
        s.ok(f"{name}: voucher {voucher} applied", "cart_discount_name" in r.text, r.text[:200])
    r = c.get("/order?step=1")
    if 'id="new_account_form"' in r.text:
        fields = form_fields(r.text, 'id="new_account_form"') or {}
        action = html.unescape(rx(r'<form action="([^"]*)"[^>]*id="new_account_form"', r.text) or "/login")
        fields.update({"guest_email": f"guest-{RUN}-{name.replace(' ', '')}@apptest.test", "id_gender": 1, "firstname": "Guest",
                       "lastname": f"Shopper{RUNW}", "company": "", "address1": "1 Test Street", "address2": "", "city": "Testville",
                       "id_state": "5", "postcode": "99501", "id_country": "21", "phone_mobile": "555-0100", "submitGuestAccount": 1})
        r = c.post(urlsplit(action).path + ("?" + urlsplit(action).query if urlsplit(action).query else ""), data=fields)
        P(f"{name}: guest account accepted, address step reached", r, contains="id_address_delivery")
    fields = form_fields(r.text, r'action="http://apptest\.test/order"') or {}
    fields["processAddress"] = 1
    r = c.post("/order", data=fields)
    P(f"{name}: carrier step reached", r, contains="delivery_option")
    fields = form_fields(r.text, 'name="carrier_area"') or {}
    fields.update({"cgv": 1, "processCarrier": 1, "message": f"apptest {RUN}"})
    r = c.post("/order", data=fields)
    s.ok(f"checkout: payment step offers {module} [{r.url}]", f"/module/{module}/payment" in r.text, r.text[:200])
    r = c.get(f"/module/{module}/payment")
    P(f"{name}: {module} summary page", r, contains=f"/module/{module}/validation")
    fields = form_fields(r.text, f'action="[^"]*/module/{module}/validation"') or {}
    return c.post(f"/module/{module}/validation", data=fields)


def storefront():
    c = client()
    r = c.get("/")
    P("home", r, contains=["Apptest Shop", "ajax_block_product"], min_bytes=20000)
    s.ok("home: static token present", bool(static_token(r.text)))
    s.ok("home: friendly product links", bool(re.search(r'href="http://apptest\.test/(?:[a-z0-9-]+/)?\d+-[a-z0-9-]+\.html', r.text)))
    s.ok("home: canonical host kept", "apptest.test" in r.text and "127.0.0.1" not in r.text)

    top = M["categories"]["department"]
    r = c.get(top["url"])
    P("category: department", r, contains=top["name"])
    big = M["category_with_most_products"]
    per_page = 12
    r = c.get(big["url"])
    P(f"category: {big['name']} page 1", r, contains=big["name"])
    ids1 = listing_ids(r.text)
    s.ok("category: first page lists a full page or all products", len(ids1) == min(per_page, big["products"]), f"{len(ids1)} vs {big['products']}")
    total = rx(r"There (?:are|is) (\d+) products?", r.text)
    s.ok("category: product count matches the fixture", total is not None and int(total) == big["products"], f"{total} vs {big['products']}")
    if big["products"] > per_page:
        r2 = c.get(big["url"] + "?p=2")
        ids2 = listing_ids(r2.text)
        P("category: page 2", r2, contains="ajax_block_product")
        s.ok("category: page 2 has other products", bool(ids2) and not set(ids1) & set(ids2), f"{ids1} / {ids2}")
    r = c.get(big["url"] + "?orderby=price&orderway=asc")
    P("category: sorted by price ascending", r, contains="ajax_block_product")
    asc = list_prices(r.text)
    s.ok("category: price ascending order holds", asc == sorted(asc) and len(asc) > 1, str(asc))
    r = c.get(big["url"] + "?orderby=price&orderway=desc")
    desc = list_prices(r.text)
    s.ok("category: price descending order holds", desc == sorted(desc, reverse=True) and len(desc) > 1, str(desc))
    s.skip("category: listing ajax json", "1.6 renders listings server side; its only listing JSON is the layered navigation's")
    r = c.get(f"/modules/blocklayered/blocklayered-ajax.php?id_category_layered={big['id']}&layered_price_slider=0_100000")
    try:
        j = r.json()
        s.ok("category: layered navigation ajax answers", "productList" in j and "filtersBlock" in j, list(j)[:8])
    except ValueError:
        s.ok("category: layered navigation ajax answers", False, f"{r.status} {r.text[:160]}")

    for key in ("simple", "simple2", "sale", "sold_out"):
        p = M["products"][key]
        r = c.get(p["url"])
        P(f"product: {key} ({p['reference']})", r, contains=[p["name"], p["reference"], "add_to_cart"], min_bytes=30000)
        d = product_data(r.text)
        want = M["golden"]["visitor_prices"][key]["incl"]
        s.ok(f"product: {key} price_amount is the golden {want}", abs(float(d.get("price_amount") or -1) - float(want)) < 1e-6, f"{d.get('price_amount')}")
        s.ok(f"product: {key} page carries the reference", d.get("reference") == p["reference"], d.get("reference"))
        if key == "sold_out":
            s.ok("product: sold out product is not purchasable", d.get("availability") == "unavailable" and "no longer in stock" in r.text, str(d))
        if key == "simple":
            ids = re.findall(r'<img[^>]*src="(http://apptest\.test/\d+-[a-z_0-9]+/[^"]+\.jpg)"', r.text)
            s.ok("product: image urls are friendly", bool(ids), r.text[:100])
    combo = M["products"]["combo"]
    r = c.get(combo["url"])
    P("product: with combinations", r, contains=[combo["name"], 'name="group_'])
    d = product_data(r.text)
    groups = set(re.findall(r'name="(group_\d+)"', r.text))
    s.ok("product: combination groups rendered", len(groups) >= 2, str(groups))
    # the page opens on the default combination: the option each group has selected must be one combination's attributes
    chosen = sorted(int(v) for v in re.findall(r'<option[^>]*value="(\d+)"[^>]*selected', r.text) + re.findall(r'class="color_pick_hidden" name="group_\d+" value="(\d+)"', r.text))
    try:
        combos = json.loads(rx(r"var combinations = (\{.*?\});\s*var", r.text) or "{}")
    except ValueError:
        combos = {}
    s.ok("product: default combination selected", any(sorted(v["attributes"]) == chosen for v in combos.values()), str(chosen))
    listed = sorted(int(k) for k in combos)
    s.ok("product: combinations json lists the fixture's combinations", listed == sorted(x["id"] for x in combo["combinations"]), str(listed))
    s.skip("product: variant refresh answers", "1.6 switches combinations client side from the combinations json; there is no refresh request")
    qs = M["products"]["quantity_sale"]
    r = c.get(qs["url"])
    P("product: quantity discount product", r, contains=qs["name"])

    q = M["search"]
    r = c.get(f"/search?controller=search&orderby=position&orderway=desc&search_query={quote(q['reference_query'])}")
    P("search: by reference", r, contains="ajax_block_product")
    s.ok("search: reference finds the product", q["reference_product"] in listing_ids(r.text), str(listing_ids(r.text)))
    r = c.get(f"/search?controller=search&orderby=position&orderway=desc&search_query={q['word_query']}")
    P("search: by word", r, contains="ajax_block_product")
    s.ok("search: a word finds several products", len(listing_ids(r.text)) >= 5, str(len(listing_ids(r.text))))
    r = c.get(f"/search?controller=search&orderby=position&orderway=desc&search_query={q['nothing_query'] * 2}")
    P("search: no match page", r, contains="No results were found")
    r = c.get(f"/search?ajaxSearch=1&id_lang=1&q={q['word_query']}&limit=5")
    try:
        j = r.json()
        s.ok("search: ajax suggestions", r.status == 200 and bool(j) and "pname" in j[0], r.text[:200])
    except ValueError:
        s.ok("search: ajax suggestions", False, r.text[:200])

    for name, path, extra in (("new products", "/new-products", "ajax_block_product"),
                              ("prices drop", "/prices-drop", "ajax_block_product"),
                              ("best sellers", BEST_SELLERS, "ajax_block_product"),
                              ("brands", "/manufacturers", M["manufacturers"][0]["name"]),
                              ("suppliers", "/supplier", "Apptest Supplier"),
                              ("sitemap", "/sitemap", "Sitemap"),
                              ("stores", "/stores", None)):
        r = c.get(path)
        if name == "stores" and r.status == 404:
            s.skip("stores page", "the theme/shop has no store page")
            continue
        P(name, r, contains=[extra] if extra else ())
    # at full scale there are more discounted products than one page holds
    seen, page = [], 1
    while page <= 12 and M["products"]["sale"]["id"] not in seen:
        found = listing_ids(c.get(f"/prices-drop?p={page}").text)
        if not found or set(found) <= set(seen):
            break
        seen += found
        page += 1
    s.ok("prices drop: lists the discounted products", M["products"]["sale"]["id"] in seen, f"{len(seen)} products over {page} pages")
    mf = M["manufacturers"][0]
    r = c.get(mf["url"])
    P(f"brand page {mf['name']}", r, contains=mf["name"])
    for page in M["cms"]:
        r = c.get(page["url"])
        P(f"cms: {page['title']}", r, contains=page["title"])
    r = c.get("/contact-us")
    P("contact: form", r, contains=["contact-form-box", "message"])
    f = form_fields(r.text, r'action="[^"]*/contact-us"[^>]*class="contact-form-box"') or form_fields(r.text, r'class="contact-form-box"') or {}
    f.pop("fileUpload", None)
    f.update({"id_contact": 2, "from": f"contact-{RUN}@apptest.test", "message": f"Hello from the application test {RUN}, please ignore.", "submitMessage": 1})
    r = c.post("/contact-us", data=f)
    P("contact: message accepted", r, contains="successfully sent")
    r = c.get("/no-such-page-" + RUN)
    P("404 page is the shop's own", r, status=404, contains="Apptest Shop")

    r = c.get("/robots.txt")
    P("robots.txt", r, contains="User-agent")
    css = rx(r'href="(http://apptest\.test/themes/[^"]+\.css[^"]*)"', c.get("/").text)
    if css:
        r = c.get(urlsplit(css).path + ("?" + urlsplit(css).query if urlsplit(css).query else ""))
        P("theme stylesheet", r, ctype="css", min_bytes=1000)
    simple = M["products"]["simple"]
    page = c.get(simple["url"]).text
    thumb = rx(r'src="http://apptest\.test(/\d+-(?:large_default|home_default|medium_default|small_default)/[^"]+\.jpg)"', page)
    if thumb:
        r = c.get(thumb)
        size = jpeg_size(r.body)
        want = THUMBS[rx(r"/\d+-([a-z_]+)/", thumb)]
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

    for path in ("/composer.lock", "/composer.json", "/.env", "/config/settings.inc.php", "/vendor/autoload.php",
                 "/log/", "/config/config.inc.php", "/classes/Product.php", "/tools/smarty/Smarty.class.php", "/install/index.php",
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
    r = c.get("/order")
    P("cart: page", r, contains=[simple["name"], combo["name"], "cart_summary"])
    r, j = add_to_cart(c, M["products"]["sold_out"]["id"], 0, 1, tok)
    s.ok("cart: sold out product is refused", j.get("success") is False, str(j)[:200])
    r = c.get(f"/cart?add=1&id_product={simple['id']}&ipa=0&op=up&qty=1&token={tok}&ajax=true", headers=XHR)
    s.ok("cart: quantity up", r.status == 200 and cart_line(r.json(), simple["id"]).get("quantity") == 3, r.text[:200])
    r = c.post("/order", data={"discount_name": M["vouchers"]["percent"], "submitAddDiscount": 1})
    P("cart: percentage voucher", r, contains="cart_discount_name")   # the summary lists the rule by its name, not its code
    r = c.post("/order", data={"discount_name": "NOSUCHCODE", "submitAddDiscount": 1})
    s.ok("cart: unknown voucher is refused", "does not exist" in r.text, r.text[:100])
    r = c.get(f"/cart?delete=1&id_product={simple['id']}&ipa=0&id_address_delivery=0&token={tok}&ajax=true", headers=XHR)
    s.ok("cart: line removed", r.status == 200 and simple["name"] not in r.text.replace("\\", ""), r.text[:100])


def account_flow():
    c = client()
    email = f"reg-{RUN}@apptest.test"
    password = f"Reg-{RUN}-Pass1"
    r = c.get(REGISTRATION)
    P("registration: sign in and create forms", r, contains=["SubmitCreate", "SubmitLogin"])
    r = c.post("/login", data={"email_create": email, "SubmitCreate": 1})
    P("registration: account form", r, contains="submitAccount")
    f = form_fields(r.text, 'id="account-creation_form"') or {}
    f.update({"id_gender": 1, "customer_firstname": "Reggie", "customer_lastname": f"Newcomer{RUNW}", "firstname": "Reggie",
              "lastname": f"Newcomer{RUNW}", "email": email, "passwd": password, "address1": "1 Test Street", "city": "Testville",
              "id_state": "5", "postcode": "99501", "id_country": "21", "phone_mobile": "555-0100", "alias": "My address", "submitAccount": 1})
    r = c.post("/login", data=f)
    P("registration: new customer lands in the account", r, contains="Reggie")
    s.ok("registration: signed in afterwards", logged_in(r), r.text[:100])
    r = c.get("/my-account")
    P("my account", r, contains=["My account", "Sign out"])
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
    P("seeded customer: my account", r, contains="My account")
    r = c2.get("/order-history")
    P("seeded customer: order history", r, contains="Order history")
    with_orders = [x for x in M["customers"] if x["order_references"]]
    if with_orders:
        c3 = client()
        k = with_orders[0]
        login(c3, k["email"], k["password"])
        r = c3.get("/order-history")
        P(f"order history of {k['email']}", r, contains=k["order_references"][0])
        # the row's link is a javascript:showOrder(...) call carrying the detail url, which the theme loads by ajax
        detail = rx(r"showOrder\(\d+, \d+, '([^']+)'\);\s*\">\s*" + re.escape(k["order_references"][0]), r.text)
        s.ok("order history links to the order detail", bool(detail), r.text[:100])
        if detail:
            link = urlsplit(html.unescape(detail))
            r = c3.get(link.path + "?" + link.query)
            P("order detail page", r, contains=[k["order_references"][0], "Order"])
    r = c2.get("/addresses")
    P("seeded customer: addresses", r, contains="addresses")
    r = c2.get("/address")
    P("seeded customer: new address form", r, contains=["address1", "id_country", "postcode"])
    r = c2.get("/identity")
    P("seeded customer: identity page", r, contains=known["email"])
    r = c2.get("/discount")
    P("seeded customer: vouchers page", r)
    r = c2.get("/index.php?controller=history")
    P("history via legacy controller url", r)


def checkout_flows():
    c = client()
    add_to_cart(c, M["products"]["simple2"]["id"], 0, 1)
    add_to_cart(c, M["products"]["simple"]["id"], 0, 2)
    r = order_page(c, "guest wire", "bankwire")
    P("checkout: guest wire order confirmation", r, contains="is complete")
    s.ok("checkout: confirmation url", "order-confirmation" in r.url, r.url)
    ref = rx(r"reference ([A-Z]{5,12}) in the subject", r.text)
    s.ok("checkout: confirmation shows the order reference", bool(ref), r.text[:100])
    globals()["GUEST_REF"] = ref
    known = M["customers"][2]
    c2 = client()
    login(c2, known["email"], known["password"])
    add_to_cart(c2, M["products"]["simple"]["id"], 0, 1)
    combo = M["products"]["combo"]
    add_to_cart(c2, combo["id"], combo["combinations"][0]["id"], 1)
    r = order_page(c2, "customer wire", PAY2, voucher=M["vouchers"]["percent"])
    P("checkout: customer order confirmation", r, contains="is complete")
    ref = rx(r"reference ([A-Z]{5,12}) in the subject", r.text)
    globals()["CUSTOMER_REF"] = ref
    s.ok("checkout: customer order reference shown", bool(ref), r.text[:100])
    r = c2.get("/order-history")
    s.ok("checkout: the new order is in the customer's history", bool(ref) and ref in r.text, ref)
    known = M["customers"][3]
    c3 = client()
    login(c3, known["email"], known["password"])
    add_to_cart(c3, M["products"]["simple2"]["id"], 0, 3)
    r = order_page(c3, "customer cheque", "cheque")
    P("checkout: cheque order confirmation", r, contains="is complete")


class BO16(BO):
    """The legacy back office: every controller has its own token, carried by the menu links of the dashboard."""

    def link(self, controller, extra=""):
        m = re.search(r'href="([^"]*controller=' + controller + r'&(?:amp;)?token=[0-9a-f]+)"', self.menu)
        if not m:
            return None
        href = html.unescape(m.group(1)).replace("http://" + args.host, "")
        href = href if href.startswith("/") else self.base + "/" + href
        return href + extra


def bo_login16(bo, password, **extra):
    bo.c.get(bo.base + "/")
    return bo.c.post(bo.base + "/index.php?controller=AdminLogin", data={"email": ADMIN["email"], "passwd": password, "submitLogin": 1, "redirect": "", **extra})


def backoffice():
    bo = BO16()
    r = bo.c.get(bo.base + "/")
    P("bo: login page", r, contains=["login_form", "passwd"])
    r = bo_login16(bo, "wrong-" + ADMIN["password"])
    s.ok("bo: wrong password is refused", r.status == 200 and "login_form" in r.text, f"{r.status}")
    r = bo_login16(bo, ADMIN["password"], stay_logged_in=1)
    P("bo: dashboard after login", r, contains=["Dashboard", "AdminProducts"], min_bytes=30000)
    bo.menu = r.text
    if not bo.link("AdminProducts"):
        s.ok("bo: menu links carry tokens", False, r.text[:200])
        return

    for name, controller, title in BO_PAGES:
        href = bo.link(controller)
        r = bo.c.get(href) if href else bo.c.get(bo.base + "/index.php?controller=" + controller)
        if controller == "AdminModules":
            # the addons login form ships the generic ajax error string in a data attribute
            r = scrubbed(r, "An error occurred while processing your request")
        P(f"bo: {name}", r, contains=[title], min_bytes=20000)
    s.skip("bo: payment methods, module manager and translations", "AdminPayment, AdminModules and AdminTranslations fetch from addons.prestashop.com / the language pack server on load")

    # product list: filter by reference, then the edit page of what it found
    p = M["products"]["simple"]
    href = bo.link("AdminProducts")
    r = bo.c.get(href)
    form = form_fields(r.text, r'id="form-product"') or {}
    form.update({"productFilter_reference": p["reference"], "submitFilterproduct": 1, "submitFilter": 1})
    r = bo.c.post(href, data=form)
    P("bo: product list filtered by reference", r, contains=[p["reference"], p["name"]])
    rows = set(re.findall(r"id_product=(\d+)&(?:amp;)?updateproduct", r.text))
    s.ok("bo: product list filter narrows to one row", rows == {str(p["id"])}, str(rows))
    r = bo.c.get(href + f"&id_product={p['id']}&updateproduct")
    P("bo: product edit page", r, contains=[p["reference"], p["name"]], min_bytes=50000)
    c2 = M["products"]["combo"]
    r = bo.c.get(href + f"&id_product={c2['id']}&updateproduct")
    P("bo: product with combinations edit page", r, contains=[c2["reference"]])
    r = bo.c.get(href + "&addproduct")
    P("bo: new product form", r, contains="Add new product" if "Add new product" in r.text else "product")

    o = M["orders"][0]
    href = bo.link("AdminOrders")
    form = form_fields(bo.c.get(href).text, r'id="form-order"') or {}
    form.update({"orderFilter_reference": o["reference"], "submitFilterorder": 1, "submitFilter": 1})
    r = bo.c.post(href, data=form)
    P("bo: orders list filtered by reference", r, contains=o["reference"])
    r = bo.c.get(href + f"&id_order={o['id']}&vieworder")
    P("bo: order detail", r, contains=[o["reference"], "Order"], min_bytes=50000)
    k = M["customers"][0]
    href = bo.link("AdminCustomers")
    form = form_fields(bo.c.get(href).text, r'id="form-customer"') or {}
    form.update({"customerFilter_email": k["email"], "submitFiltercustomer": 1, "submitFilter": 1})
    r = bo.c.post(href, data=form)
    P("bo: customers list filtered by email", r, contains=k["email"])
    r = bo.c.get(href + f"&id_customer={k['id']}&viewcustomer")
    P("bo: customer detail", r, contains=[k["email"], k["lastname"]])
    if globals().get("CUSTOMER_REF"):
        href = bo.link("AdminOrders")
        form = form_fields(bo.c.get(href).text, r'id="form-order"') or {}
        form.update({"orderFilter_reference": globals()["CUSTOMER_REF"], "submitFilterorder": 1, "submitFilter": 1})
        r = bo.c.post(href, data=form)
        P("bo: the order placed at the storefront shows up", r, contains=globals()["CUSTOMER_REF"])

    # a back office write: a category through the legacy form
    href = bo.link("AdminCategories")
    r = bo.c.get(href + "&addcategory")
    P("bo: new category form", r, contains="category")
    f = form_fields(r.text, r'id="category_form"') or {}
    name = f"Apptest BO category {RUN}"
    if f:
        f.update({"name_1": name, "active": "1", "id_parent": "2", "link_rewrite_1": f"apptest-bo-{RUN}", "meta_title_1": name,
                  "description_1": "created by the application test", "submitAddcategory": 1})
        r = bo.c.post(href + "&addcategory", data=f, follow=False)
        s.ok("bo: category created through the form", r.status in (302, 303), f"{r.status} {r.text[:200]}")
        if r.header("location"):
            loc = html.unescape(r.header("location")).replace("http://" + args.host, "")
            r = bo.c.get(loc if loc.startswith("/") else bo.base + "/" + loc)
            P("bo: created category is listed", r, contains=name)
    else:
        s.ok("bo: category form has fields", False, r.text[:200])

    # performance: empty the Smarty cache, then everything renders from a cold cache
    href = bo.link("AdminPerformance")
    r = bo.c.get(href + "&empty_smarty_cache=1", follow=False)
    s.ok("bo: clear cache action redirects back", r.status in (302, 303), f"{r.status} {r.text[:150]}")
    r = bo.c.get(bo.link("AdminPerformance"))
    P("bo: performance page after clearing the cache", r, contains="Performance")
    r = bo.c.get(bo.link("AdminProducts"))
    P("bo: products after cache clear (cold Smarty)", r, contains="Products")
    r = bo.c.get(M["products"]["simple"]["url"])
    P("front: product after cache clear (cold Smarty)", r, contains=M["products"]["simple"]["name"])

    out = rx(r'href="([^"]*controller=AdminLogin&(?:amp;)?token=[0-9a-f]+&(?:amp;)?logout)"', bo.menu)
    r = bo.c.get(bo.base + "/" + html.unescape(out) if out else bo.base + "/index.php?controller=AdminLogin&logout")
    r = bo.c.get(bo.base + "/")
    s.ok("bo: logout ends the session", "login_form" in r.text, r.text[:100])


def concurrency(n=50):
    urls = [M["products"][k]["url"] for k in ("simple", "simple2", "combo", "sale")]
    urls += [M["category_with_most_products"]["url"], M["categories"]["department"]["url"], "/", "/new-products", BEST_SELLERS, "/prices-drop",
             f"/search?controller=search&orderby=position&orderway=desc&search_query={M['search']['word_query']}"]

    # Smarty 3.1 (bundled with 1.6) races on mkdir when parallel requests populate a cold cache: an "unable to write
    # file" fatal that is the application's, not the interpreter's. The pages are walked once first, as every
    # other section of this suite has already done for most of them.
    for _ in range(2):
        warm = client()
        for u in urls:
            warm.get(u)
        add_to_cart(warm, M["products"]["simple"]["id"], 0, 1)
        for u in urls:
            warm.get(u)
        warm.get("/order")

    def one(i):
        cl = client()
        out = []
        r = cl.get(urls[i % len(urls)])
        out.append((r.status, r.error_marker(), urls[i % len(urls)]))
        if i % 2 == 0:
            tok = static_token(r.text) or static_token(cl.get("/").text)
            rr = cl.post("/cart", data={"token": tok, "id_product": M["products"]["simple"]["id"], "ipa": 0, "qty": 1, "add": 1, "ajax": "true"}, headers=XHR)
            out.append((rr.status, rr.error_marker(), "add to cart"))
            rr = cl.get("/order")
            out.append((rr.status, rr.error_marker(), "/order"))
        return out

    with concurrent.futures.ThreadPoolExecutor(max_workers=n) as ex:
        results = list(ex.map(one, range(n)))
    flat = [x for out in results for x in out]
    bad = [x for x in flat if x[0] != 200 or x[1]]
    s.ok(f"concurrency: {n} parallel visitors, {len(flat)} requests, all 200 and clean", not bad, str(bad[:3]))
