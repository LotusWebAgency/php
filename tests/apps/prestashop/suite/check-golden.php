<?php
/*
 * CLI suite, part one: recompute on the PHP under test everything the
 * fixture recorded on the stock builder, and compare. Rounding, tax and
 * price arithmetic, slugs, validators, the cookie cipher, password hashes and
 * (with APPTEST_WS_BASE set) the webservice payloads are all deterministic,
 * so any difference is the build's, not the data's.
 *
 * Prints "ok:" / "FAIL:" lines for suite/cli.sh to count.
 */
require __DIR__ . '/../fixture/bootstrap.php';
require __DIR__ . '/../fixture/lib.php';

$root = getenv('APPTEST_APP_ROOT') ?: '/srv/app';
$m = json_decode(file_get_contents($root . '/.apptest/manifest.json'), true);
$g = $m['golden'];
$idLang = (int) Configuration::get('PS_LANG_DEFAULT');
$failed = 0;

function t(string $name, bool $cond, string $detail = '')
{
    global $failed;
    if (!$cond) {
        ++$failed;
    }
    echo ($cond ? "ok: $name" : "FAIL: $name -- $detail") . "\n";
}

t('version is the fixture\'s', _PS_VERSION_ === $m['app_version'], _PS_VERSION_ . ' vs ' . $m['app_version']);
t('shop domain is the fixture\'s', Configuration::get('PS_SHOP_DOMAIN') === 'apptest.test', (string) Configuration::get('PS_SHOP_DOMAIN'));

foreach (fixtureCounts() as $what => $n) {
    t("count: $what = {$m['counts'][$what]}", $n === $m['counts'][$what], "got $n");
}

$modes = [PS_ROUND_UP, PS_ROUND_DOWN, PS_ROUND_HALF_UP, PS_ROUND_HALF_DOWN, PS_ROUND_HALF_EVEN, PS_ROUND_HALF_ODD];
$values = [0.5, 1.5, 2.5, -0.5, -1.5, 1.005, 2.675, 1.0049999, 19.995, 0.285, 1234.56785, 99.999999, 0.1 + 0.2, 8.325, 1.955];
$bad = [];
foreach ($modes as $mode) {
    foreach ([0, 2, 4, 6] as $precision) {
        $row = [];
        foreach ($values as $v) {
            $row[] = number_format(Tools::ps_round($v, $precision, $mode), 6, '.', '');
        }
        if ($row !== $g['ps_round'][$mode . ':' . $precision]) {
            $bad[] = "$mode:$precision";
        }
    }
}
t('Tools::ps_round matches in every mode and precision', !$bad, implode(',', $bad));

// Rates before prices, as the manifest computed them: 1.6 caches one tax manager per (address state, zip, group) and the
// first caller decides what getProductTaxRate() sees afterwards (a manager first built inside getPriceStatic() answers 0).
$bad = [];
foreach ($g['tax_rates'] as $key => $rate) {
    list($product, $n) = explode('@', $key);
    $id = $m['products'][$product]['id'];
    $got = number_format((float) Tax::getProductTaxRate($id, $g['tax_customers'][$n]['address']), 6, '.', '');
    if ($got !== $rate) {
        $bad[] = "$key: $got vs $rate";
    }
}
t('Tax::getProductTaxRate matches by state', !$bad, implode(',', $bad));

$bad = [];
foreach ($g['prices'] as $row) {
    $p = Product::getPriceStatic($row['product'], $row['tax'], $row['attribute'] ?: null, 6, null, false, true, $row['quantity'], false, $row['customer'], null, $row['address']);
    if (number_format((float) $p, 6, '.', '') !== $row['price']) {
        $bad[] = "{$row['product']}/{$row['attribute']}/c{$row['customer']}/tax" . (int) $row['tax'] . "/q{$row['quantity']}: " . number_format((float) $p, 6, '.', '') . " vs {$row['price']}";
    }
}
t('Product::getPriceStatic matches ' . count($g['prices']) . ' recorded prices (tax rules, price rules, quantity breaks, group reduction)', !$bad, implode('; ', array_slice($bad, 0, 4)));

$bad = [];
foreach ($g['tax_cases'] as $row) {
    $got = number_format((float) Tax::getProductTaxRate($row['product'], $row['address']), 6, '.', '');
    if ($got !== $row['rate']) {
        $bad[] = "{$row['state']} rate $got vs {$row['rate']}";
    }
    foreach ($row['prices'] as $key => $want) {
        list($k, $qty) = explode(':', $key);
        $got = number_format((float) Product::getPriceStatic($row['product'], $k === 'incl', null, 6, null, false, true, (int) $qty, false, $row['customer'], null, $row['address']), 6, '.', '');
        if ($got !== $want) {
            $bad[] = "{$row['state']} $key $got vs $want";
        }
    }
}
t('state tax rules apply as recorded (' . count($g['tax_cases']) . ' states)', !$bad, implode('; ', $bad));

$bad = [];
foreach ($g['visitor_prices'] as $key => $row) {
    $id = $m['products'][$key]['id'];
    foreach (['incl' => true, 'excl' => false] as $k => $tax) {
        if (number_format((float) Product::getPriceStatic($id, $tax, null, 6), 6, '.', '') !== $row[$k]) {
            $bad[] = "$key/$k";
        }
    }
}
t('visitor prices match', !$bad, implode(',', $bad));

$bad = [];
foreach ($g['str2url'] as $in => $out) {
    if (Tools::str2url($in) !== $out) {
        $bad[] = "$in -> " . Tools::str2url($in) . " (want $out)";
    }
}
t('Tools::str2url slugs match', !$bad, implode('; ', $bad));

$bad = [];
foreach ($g['validate'] as $key => $want) {
    list($fn, $v) = explode(':', $key, 2);
    if ((bool) Validate::$fn($v) !== $want) {
        $bad[] = $key;
    }
}
t('Validate:: results match', !$bad, implode(',', $bad));

$legacy = version_compare(_PS_VERSION_, '1.7', '<');
if ($legacy) {
    // 1.6.1.24: Rijndael over openssl_encrypt with the fixed IV of _RIJNDAEL_IV_, so the bytes repeat. With mcrypt loaded the
    // class encrypts through it instead, with a random IV, and its HMAC mixes in mcrypt's own constant.
    $cipher = new Rijndael(_RIJNDAEL_KEY_, _RIJNDAEL_IV_);
    if (extension_loaded('mcrypt')) {
        echo "SKIP: cookie cipher: byte-exact golden -- mcrypt is loaded here, the builder had none\n";
    } else {
        t('cookie cipher (openssl AES-128-CBC) reproduces the builder\'s ciphertext byte for byte', $cipher->encrypt($g['cookie_plaintext']) === $g['cookie_ciphertext']);
        t('cookie cipher decrypts what the builder encrypted', $cipher->decrypt($g['cookie_ciphertext']) === $g['cookie_plaintext']);
    }
    $tampered = substr($g['cookie_ciphertext'], 0, -8) . 'AAAAAAA=';
    t('cookie cipher refuses a tampered ciphertext (HMAC)', $cipher->decrypt($tampered) === false);
    t('cookie cipher round-trips a non-ascii payload', $cipher->decrypt($cipher->encrypt("caf\u{e9} \u{2603} apptest")) === "caf\u{e9} \u{2603} apptest");
    t('Tools::encryptIV matches', Tools::encryptIV('apptest') === $g['hash_iv']);
} else {
    $cipher = new PhpEncryption(_NEW_COOKIE_KEY_);
    t('cookie cipher decrypts what the builder encrypted', $cipher->decrypt($g['cookie_ciphertext']) === $g['cookie_plaintext']);
    $a = $cipher->encrypt($g['cookie_plaintext']);
    $b = $cipher->encrypt($g['cookie_plaintext']);
    t('cookie cipher round-trips and is randomized', $a !== $b && $cipher->decrypt($a) === $g['cookie_plaintext'] && $cipher->decrypt($b) === $g['cookie_plaintext']);
    t('Tools::hashIV matches', Tools::hashIV('apptest') === $g['hash_iv']);
}

foreach ($m['customers'] as $c) {
    $found = (new Customer())->getByEmail($c['email'], $c['password']);
    t("password hash of {$c['email']} verifies", $found && (int) $found->id === $c['id'], 'not found');
    if ($c === $m['customers'][0]) {
        t('a wrong password is refused', !(new Customer())->getByEmail($c['email'], $c['password'] . 'x'));
    }
}
$found = (new Customer())->getByEmail('customer050@apptest.test', $m['customer_password_shared']);
t('shared password of a bulk customer verifies', (bool) $found);

foreach ($m['orders'] as $o) {
    $order = new Order($o['id']);
    t("order {$o['reference']} totals and state", $order->reference === $o['reference'] && number_format((float) $order->total_paid_tax_incl, 6, '.', '') === $o['total_paid_tax_incl'] && (int) $order->current_state === $o['state'], (string) $order->total_paid_tax_incl);
}
foreach (['simple', 'combo', 'sold_out'] as $key) {
    $p = new Product($m['products'][$key]['id'], true, $idLang);
    t("product $key loads with its name, category and stock", $p->name === $m['products'][$key]['name'] && (int) $p->id_category_default === $m['products'][$key]['category_id'] && StockAvailable::getQuantityAvailableByProduct($p->id, 0) === $m['products'][$key]['quantity']);
}
$cat = new Category($m['categories']['shelf']['id'], $idLang);
t('category tree: shelf product count', (int) $cat->getProducts($idLang, 1, 1, null, null, true) === $m['categories']['shelf']['products']);
t('category tree: nested set is consistent', (int) Db::getInstance()->getValue('SELECT COUNT(*) FROM ' . _DB_PREFIX_ . 'category c1 JOIN ' . _DB_PREFIX_ . 'category c2 ON c2.id_parent = c1.id_category WHERE NOT (c2.nleft > c1.nleft AND c2.nright < c1.nright)') === 0);

if ($base = getenv('APPTEST_WS_BASE')) {
    foreach ($g['webservice'] as $key => $w) {
        $resource = $key === 'category' ? 'categories/' : 'products/';
        $hash = wsCanonicalHash(wsGet($resource . $w['id'], $base));
        t("webservice payload of $key matches the golden sha256", $hash === $w['sha256'], "got $hash");
    }
}

exit($failed ? 1 : 0);
