<?php
/*
 * Writes /srv/app/.apptest/manifest.json: what the fixture contains and the
 * golden values the suites compare against. Goldens are computed here, on the
 * stock builder PHP, from things that must come out byte-identical on any
 * correct build: rounding, price and tax arithmetic, URL slugs, the cookie
 * cipher, and the webservice payload. Nothing time-dependent, nothing that
 * goes through ICU/CLDR (localized price strings), no image bytes.
 *
 * Needs the shop answering on http://127.0.0.1:8081 (build.sh starts php -S)
 * for the webservice payloads.
 */
require __DIR__ . '/bootstrap.php';
require_once __DIR__ . '/lib.php';

$idLang = (int) Configuration::get('PS_LANG_DEFAULT');
$db = Db::getInstance();

$legacy = version_compare(_PS_VERSION_, '1.7', '<');
$manifest = [
    'app_version' => _PS_VERSION_,
    'built_on_php' => PHP_VERSION,
    'cipher' => $legacy
        ? ['cookie' => 'Rijndael AES-128-CBC via openssl', 'PS_CIPHER_ALGORITHM' => (int) Configuration::get('PS_CIPHER_ALGORITHM'), 'mcrypt_loaded_at_build' => extension_loaded('mcrypt')]
        : ['cookie' => 'defuse/php-encryption (openssl)'],
    'admin' => [
        'dir' => getenv('APPTEST_ADMIN_DIR') ?: 'admin-apptest',
        'email' => getenv('APPTEST_ADMIN_EMAIL'),
        'password' => getenv('APPTEST_ADMIN_PASSWORD'),
    ],
    'webservice_key' => WS_KEY,
    'counts' => fixtureCounts(),
    'customer_password_shared' => 'Shared-Pass-2026!',
    'vouchers' => ['percent' => 'APPTEST10', 'amount' => 'APPTEST5OFF', 'shipping' => 'APPTESTSHIP', 'big' => 'APPTESTBIG'],
];

// Customers with a known password, and which of them have orders.
$manifest['customers'] = [];
foreach (range(1, 10) as $i) {
    $email = sprintf('customer%03d@apptest.test', $i);
    $id = (int) Customer::customerExists($email, true);
    $c = new Customer($id);
    $orders = array_column($db->executeS((new DbQuery())->select('reference')->from('orders')->where('id_customer = ' . $id)->orderBy('id_order')), 'reference');
    $manifest['customers'][] = [
        'id' => $id,
        'email' => $email,
        'password' => sprintf(AT_PASSWORD_KNOWN, $i),
        'firstname' => $c->firstname,
        'lastname' => $c->lastname,
        'default_group' => (int) $c->id_default_group,
        'addresses' => count($c->getAddresses($idLang)),
        'order_references' => $orders,
    ];
}

// Products the suites go and look at by name.
$link = Context::getContext()->link;
// Closures, not arrow functions, and list() for destructuring: this file has to parse on the 7.0 builder.
$path = function (string $url): string {
    return (parse_url($url, PHP_URL_PATH) ?: '/') . (($q = parse_url($url, PHP_URL_QUERY)) ? '?' . $q : '');
};
$productByRef = function (string $reference) use ($db, $idLang, $link, $path): array {
    $id = (int) $db->getValue((new DbQuery())->select('id_product')->from('product')->where("reference = '" . pSQL($reference) . "'"));
    $p = new Product($id, false, $idLang);
    $category = new Category((int) $p->id_category_default, $idLang);
    $combos = $db->executeS((new DbQuery())->select('id_product_attribute, reference')->from('product_attribute')->where('id_product = ' . $id)->orderBy('id_product_attribute'));

    return [
        'id' => $id,
        'reference' => $reference,
        'name' => $p->name,
        'link_rewrite' => $p->link_rewrite,
        'category_id' => (int) $p->id_category_default,
        'category_name' => $category->name,
        'category_rewrite' => $category->link_rewrite,
        'price' => Tools::ps_round($p->price, 6),
        'quantity' => (int) StockAvailable::getQuantityAvailableByProduct($id, 0),
        'combinations' => array_map(function ($c) {
            return ['id' => (int) $c['id_product_attribute'], 'reference' => $c['reference']];
        }, $combos),
        'ean13' => $p->ean13,
        'url' => $path($link->getProductLink($id, null, null, null, $idLang, 1, $combos ? (int) Product::getDefaultAttribute($id) : 0)),
        'cover_image' => (int) (Product::getCover($id)['id_image'] ?? 0),
        'features' => count($p->getFrontFeatures($idLang)),
    ];
};
$manifest['products'] = [
    'simple' => $productByRef('AT-0001'),
    'simple2' => $productByRef('AT-0002'),
    'combo' => $productByRef('AT-0005'),
    'combo2' => $productByRef('AT-0010'),
    'sale' => $productByRef('AT-0025'),          // 10-25% catalog price rule
    'quantity_sale' => $productByRef('AT-0100'), // extra price from quantity 5
    'sold_out' => $productByRef('AT-0037'),
];
$manifest['search'] = [
    'reference_query' => 'AT-0042',
    'reference_product' => $productByRef('AT-0042')['id'],
    'word_query' => strtolower(pick(MATERIALS, 'm1')),
    'nothing_query' => 'zzqxyvwk',
];

// Categories: a department, a section, a shelf, plus how many products each lists.
$categoryInfo = function (string $name) use ($db, $idLang, $link, $path): array {
    $id = (int) $db->getValue((new DbQuery())->select('cl.id_category')->from('category_lang', 'cl')->where("cl.name = '" . pSQL($name) . "' AND cl.id_lang = " . $idLang));
    $c = new Category($id, $idLang);

    return [
        'id' => $id,
        'name' => $name,
        'link_rewrite' => $c->link_rewrite,
        'url' => $path($link->getCategoryLink($c)),
        'has_image' => file_exists(_PS_CAT_IMG_DIR_ . $id . '.jpg'),
        'depth' => (int) $c->level_depth,
        'products' => (int) $c->getProducts($idLang, 1, 1, null, null, true),
        'children' => count($c->getSubCategories($idLang)),
    ];
};
$manifest['categories'] = [
    'department' => $categoryInfo('Living'),
    'section' => $categoryInfo('Living Essentials'),
    'shelf' => $categoryInfo('Living Essentials Small'),
    'home' => ['id' => (int) Configuration::get('PS_HOME_CATEGORY'), 'products' => (int) (new Category(2, $idLang))->getProducts($idLang, 1, 1, null, null, true)],
];
$manifest['category_with_most_products'] = (function () use ($db, $idLang, $link, $path) {
    $row = $db->getRow((new DbQuery())->select('cp.id_category, COUNT(*) n')->from('category_product', 'cp')->where('cp.id_category > 2')->groupBy('cp.id_category')->orderBy('n DESC, cp.id_category ASC'));
    $c = new Category((int) $row['id_category'], $idLang);

    return ['id' => (int) $c->id, 'name' => $c->name, 'link_rewrite' => $c->link_rewrite, 'url' => $path($link->getCategoryLink($c)), 'products' => (int) $row['n']];
})();

$manifest['cms'] = array_map(function ($p) use ($path, $link, $idLang) {
    return ['id' => (int) $p['id_cms'], 'title' => $p['meta_title'], 'url' => $path($link->getCMSLink(new CMS((int) $p['id_cms'], $idLang)))];
}, CMS::getCMSPages($idLang, null, true));
$manifest['manufacturers'] = array_map(function ($m) use ($path, $link) {
    return ['id' => (int) $m['id_manufacturer'], 'name' => $m['name'], 'url' => $path($link->getManufacturerLink((int) $m['id_manufacturer']))];
}, array_slice(Manufacturer::getManufacturers(false, $idLang, true), 0, 3));
$manifest['carriers'] = array_map(function ($c) {
    return ['id' => (int) $c['id_carrier'], 'name' => $c['name']];
}, Carrier::getCarriers($idLang, true, false, false, null, Carrier::ALL_CARRIERS));

// A few orders for the back office and the customer history page.
$manifest['orders'] = array_map(function ($o) {
    return [
        'id' => (int) $o['id_order'],
        'reference' => $o['reference'],
        'id_customer' => (int) $o['id_customer'],
        'module' => $o['module'],
        'state' => (int) $o['current_state'],
        'total_paid_tax_incl' => number_format((float) $o['total_paid_tax_incl'], 6, '.', ''),
        'total_shipping_tax_incl' => number_format((float) $o['total_shipping_tax_incl'], 6, '.', ''),
    ];
}, $db->executeS((new DbQuery())->select('*')->from('orders')->where("id_customer IN (SELECT id_customer FROM " . _DB_PREFIX_ . "customer WHERE email LIKE 'customer%@apptest.test')")->orderBy('id_order')->limit(8)));
$manifest['order_states'] = [];
foreach ($db->executeS((new DbQuery())->select('current_state, COUNT(*) n')->from('orders')->groupBy('current_state')->orderBy('current_state')) as $row) {
    $manifest['order_states'][(string) $row['current_state']] = (int) $row['n'];
}

/* --- goldens ---------------------------------------------------------------- */

$golden = [];

$modes = [PS_ROUND_UP, PS_ROUND_DOWN, PS_ROUND_HALF_UP, PS_ROUND_HALF_DOWN, PS_ROUND_HALF_EVEN, PS_ROUND_HALF_ODD];
$values = [0.5, 1.5, 2.5, -0.5, -1.5, 1.005, 2.675, 1.0049999, 19.995, 0.285, 1234.56785, 99.999999, 0.1 + 0.2, 8.325, 1.955];
foreach ($modes as $mode) {
    foreach ([0, 2, 4, 6] as $precision) {
        $row = [];
        foreach ($values as $v) {
            $row[] = number_format(Tools::ps_round($v, $precision, $mode), 6, '.', '');
        }
        $golden['ps_round'][$mode . ':' . $precision] = $row;
    }
}

// Price arithmetic: tax rules by state, catalog price rules, quantity breaks,
// group reductions, combination impacts, all through the static price API.
$addresses = [];
foreach ([1, 2, 3, 4, 5, 10] as $n) {
    $c = new Customer((int) Customer::customerExists(sprintf('customer%03d@apptest.test', $n), true));
    $addr = $c->getAddresses($idLang);
    $addresses[$n] = ['customer' => (int) $c->id, 'address' => (int) $addr[0]['id_address'], 'state' => $addr[0]['state_iso'] ?? ''];
}
$golden['tax_rates'] = [];
$golden['prices'] = [];
foreach (['simple', 'simple2', 'combo', 'combo2', 'sale', 'quantity_sale'] as $key) {
    $pr = $manifest['products'][$key];
    $idAttr = $pr['combinations'] ? $pr['combinations'][min(1, count($pr['combinations']) - 1)]['id'] : 0;
    foreach ($addresses as $n => $who) {
        $golden['tax_rates'][$key . '@' . $n] = number_format((float) Tax::getProductTaxRate($pr['id'], $who['address']), 6, '.', '');
        foreach ([[true, 1], [false, 1], [true, 5], [true, 12]] as list($useTax, $qty)) {
            $p = Product::getPriceStatic($pr['id'], $useTax, $idAttr ?: null, 6, null, false, true, $qty, false, $who['customer'], null, $who['address']);
            $golden['prices'][] = [
                'product' => $pr['id'], 'attribute' => $idAttr, 'customer' => $who['customer'], 'address' => $who['address'],
                'tax' => $useTax, 'quantity' => $qty, 'price' => number_format((float) $p, 6, '.', ''),
            ];
        }
    }
}
$golden['tax_customers'] = $addresses;

// Cases where a state's tax rules group really applies: a catalog product with
// that group priced for a seeded address in that state.
$golden['tax_cases'] = [];
$stateGroups = ['AL' => 1, 'CA' => 5, 'FL' => 9, 'IL' => 13, 'NY' => 32, 'TX' => 43, 'WA' => 47];
foreach ($stateGroups as $iso => $group) {
    $addr = $db->getRow((new DbQuery())->select('a.id_address, a.id_customer')->from('address', 'a')->innerJoin('state', 's', 's.id_state = a.id_state')
        ->where("s.iso_code = '$iso' AND a.id_customer IN (SELECT id_customer FROM " . _DB_PREFIX_ . "customer WHERE email LIKE 'customer%@apptest.test')")->orderBy('a.id_address'));
    $prod = (int) $db->getValue((new DbQuery())->select('id_product')->from('product')->where("reference LIKE 'AT-%' AND id_tax_rules_group = $group")->orderBy('id_product'));
    if (!$addr || !$prod) {
        continue;
    }
    $row = ['state' => $iso, 'product' => $prod, 'customer' => (int) $addr['id_customer'], 'address' => (int) $addr['id_address']];
    $row['rate'] = number_format((float) Tax::getProductTaxRate($prod, $row['address']), 6, '.', '');
    foreach ([true, false] as $useTax) {
        foreach ([1, 5] as $qty) {
            $row['prices'][($useTax ? 'incl' : 'excl') . ":$qty"] = number_format((float) Product::getPriceStatic($prod, $useTax, null, 6, null, false, true, $qty, false, $row['customer'], null, $row['address']), 6, '.', '');
        }
    }
    $golden['tax_cases'][] = $row;
}

// What an anonymous visitor's product page carries as price_amount (tax rules
// of the default country, no state), for the HTTP suite to compare against.
$golden['visitor_prices'] = [];
foreach (['simple', 'simple2', 'sale', 'sold_out'] as $key) {
    $pr = $manifest['products'][$key];
    $golden['visitor_prices'][$key] = [
        'incl' => number_format((float) Product::getPriceStatic($pr['id'], true, null, 6), 6, '.', ''),
        'excl' => number_format((float) Product::getPriceStatic($pr['id'], false, null, 6), 6, '.', ''),
    ];
}

$golden['str2url'] = [];
foreach (['Crème Brûlée — Ünïcödé Přeložit / ß', 'Straße & Café #1', 'Ωmega Ελληνικά 100%', 'A  B   C'] as $s) {
    $golden['str2url'][$s] = Tools::str2url($s);
}
$golden['validate'] = [];
$dateCheck = method_exists('Validate', 'isDateOrNull') ? 'isDateOrNull' : 'isDate';   // 1.6 has only isDate
foreach (['a@b.co' => 'isEmail', 'not an email' => 'isEmail', '2026-02-30' => $dateCheck, 'John O\'Neil' => 'isName', 'AT-0001' => 'isReference', '12345' => 'isPostCode'] as $v => $fn) {
    $golden['validate'][$fn . ':' . $v] = (bool) Validate::$fn($v);
}
$plain = 'apptest cookie plaintext / ' . str_repeat('x', 200);
$golden['cookie_plaintext'] = $plain;
if ($legacy) {
    // 1.6.1.24's Cookie is always Rijndael (Blowfish is deprecated since 1.6.1.20): AES-128-CBC through openssl_encrypt
    // when there is no mcrypt, with the fixed IV of _RIJNDAEL_IV_, so the ciphertext is the same bytes on any correct build.
    $golden['cookie_ciphertext'] = (new Rijndael(_RIJNDAEL_KEY_, _RIJNDAEL_IV_))->encrypt($plain);
    $golden['hash_iv'] = Tools::encryptIV('apptest');   // md5(_COOKIE_IV_ . data)
} else {
    $golden['cookie_ciphertext'] = (new PhpEncryption(_NEW_COOKIE_KEY_))->encrypt($plain);
    $golden['hash_iv'] = Tools::hashIV('apptest');   // md5-based, keyed by the fixture's cookie iv
}

// Webservice payloads, fetched through PrestaShop's own dispatcher.
$golden['webservice'] = [];
foreach (['simple', 'combo', 'sale', 'sold_out'] as $key) {
    $id = $manifest['products'][$key]['id'];
    $body = wsGet('products/' . $id);
    $golden['webservice'][$key] = ['id' => $id, 'sha256' => wsCanonicalHash($body), 'fields' => wsFlatten(json_decode($body, true)['product'], 'product')];
}
$catBody = wsGet('categories/' . $manifest['categories']['shelf']['id']);
$golden['webservice']['category'] = ['id' => $manifest['categories']['shelf']['id'], 'sha256' => wsCanonicalHash($catBody)];

$manifest['golden'] = $golden;
$json = json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
if ($json === false) {
    fwrite(STDERR, 'FATAL: manifest does not encode: ' . json_last_error_msg() . "\n");
    exit(1);
}
file_put_contents(($root ?? '/srv/app') . '/.apptest/manifest.json', $json . "\n");
echo 'manifest: ' . strlen($json) . " bytes, " . count($golden['prices']) . " price goldens, webservice " . implode(',', array_keys($golden['webservice'])) . "\n";
