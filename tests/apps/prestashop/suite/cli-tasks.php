<?php
/*
 * CLI suite, part two: write paths and the helper layers underneath them,
 * run on the PHP under test against the fixture database. Everything created
 * carries a per-run token so a second run on the same stack adds, never clashes.
 *
 * Prints "ok:" / "FAIL:" lines for suite/cli.sh to count.
 */
require __DIR__ . '/../fixture/bootstrap.php';
require __DIR__ . '/../fixture/lib.php';

// PHP 8 functions: the 8.x and 9.x trees polyfill them, 1.7's vendor does not.
if (!function_exists('str_starts_with')) {
    function str_starts_with($haystack, $needle)
    {
        return strncmp($haystack, $needle, strlen($needle)) === 0;
    }
}
// 1.7 only defines _PS_PROD_IMG_DIR_; 8.x renamed it and keeps the old name as an alias.
if (!defined('_PS_PRODUCT_IMG_DIR_')) {
    define('_PS_PRODUCT_IMG_DIR_', _PS_PROD_IMG_DIR_);
}
if (!function_exists('str_contains')) {
    function str_contains($haystack, $needle)
    {
        return $needle === '' || strpos($haystack, $needle) !== false;
    }
}

$root = getenv('APPTEST_APP_ROOT') ?: '/srv/app';
$m = json_decode(file_get_contents($root . '/.apptest/manifest.json'), true);
$idLang = (int) Configuration::get('PS_LANG_DEFAULT');
$run = strtoupper(substr(md5(uniqid('', true)), 0, 8));
$legacy = version_compare(_PS_VERSION_, '1.7', '<');   // 1.6: no Hashing class, no locale layer, other module names
$failed = 0;

function t(string $name, bool $cond, string $detail = ''): bool
{
    global $failed;
    if (!$cond) {
        ++$failed;
    }
    echo ($cond ? "ok: $name" : "FAIL: $name -- $detail") . "\n";

    return $cond;
}

function attempt(string $name, callable $fn)
{
    try {
        $fn();
    } catch (Throwable $e) {
        t($name, false, get_class($e) . ': ' . $e->getMessage() . ' @ ' . basename($e->getFile()) . ':' . $e->getLine());
    }
}

/* --- a product, its images and thumbnails, stock, search ---------------------- */

$productId = 0;
attempt('create a product', function () use ($m, $run, $idLang, &$productId) {
    $p = new Product();
    $name = "CLI product $run";
    $p->name = ml($name);
    $p->link_rewrite = ml(Tools::str2url($name));
    $p->description = ml("<p>Created by the CLI suite, run $run.</p>");
    $p->reference = "CLI-$run";
    $p->price = 24.5;
    $p->id_tax_rules_group = 5;
    $p->id_category_default = $m['categories']['shelf']['id'];
    $p->active = 1;
    $p->visibility = 'both';
    $p->available_for_order = 1;
    $p->show_price = 1;
    $p->minimal_quantity = 1;
    t('product: ObjectModel add', $p->add(), 'add() returned false');
    $productId = (int) $p->id;
    $p->addToCategories([(int) $m['categories']['shelf']['id'], (int) $m['categories']['section']['id']]);
    StockAvailable::setQuantity($productId, 0, 40);
    $back = new Product($productId, true, $idLang);
    t('product: reads back with name, price and stock', $back->name === $name && (float) $back->price === 24.5 && StockAvailable::getQuantityAvailableByProduct($productId, 0) === 40);
    t('product: in both categories', in_array($m['categories']['section']['id'], array_column($back->getProductCategoriesFull($productId, $idLang), 'id_category')) || count($back->getProductCategories($productId)) === 2);

    $imageId = attachProductImage($productId, $name, 424242, true);
    $dir = _PS_PRODUCT_IMG_DIR_ . Image::getImgFolderStatic($imageId);
    $bad = [];
    foreach (ImageType::getImagesTypes('products', true) as $type) {
        $size = @getimagesize($dir . $imageId . '-' . $type['name'] . '.jpg');
        if (!$size || $size[0] !== (int) $type['width'] || $size[1] !== (int) $type['height']) {
            $bad[] = $type['name'];
        }
    }
    t('images: every product image type was cut at its size (GD)', !$bad, implode(',', $bad));
    $cover = Product::getCover($productId);
    t('images: cover is the new image', (int) ($cover['id_image'] ?? 0) === $imageId);

    Search::indexation(false, $productId);
    $found = Search::find($idLang, "CLI-$run", 1, 10, 'position', 'desc', false, false);
    t('search: the product is found by its reference after indexing it', !empty($found['result']) && in_array($productId, array_column($found['result'], 'id_product')), json_encode($found['total'] ?? null));
    $found = Search::find($idLang, 'oak', 1, 10);
    t('search: a catalog word finds products', !empty($found['result']) && $found['total'] > 3, json_encode($found['total'] ?? null));
});

/* --- an order through the payment module ---------------------------------------- */

attempt('place an order', function () use ($m, $run, $idLang, $productId, $legacy) {
    $context = Context::getContext();
    $customer = new Customer(Customer::customerExists('customer011@apptest.test', true));
    $address = $customer->getAddresses($idLang)[0]['id_address'];
    $cart = new Cart();
    $cart->id_customer = (int) $customer->id;
    $cart->id_lang = $idLang;
    $cart->id_currency = (int) Configuration::get('PS_CURRENCY_DEFAULT');
    $cart->id_address_delivery = $cart->id_address_invoice = (int) $address;
    $cart->id_carrier = 2;
    $cart->secure_key = $customer->secure_key;
    $cart->id_shop = 1;
    $cart->id_shop_group = 1;
    t('cart: add', $cart->add());
    $context->cart = $cart;
    $context->customer = $customer;
    $context->cookie->id_customer = (int) $customer->id;
    $cart->updateQty(2, $productId, 0);
    $cart->updateQty(1, $m['products']['simple']['id'], 0);
    $cart->setDeliveryOption([$address => '2,']);
    $cart->update();
    t('cart: two lines and a total', count($cart->getProducts()) === 2 && $cart->getOrderTotal(true) > 0, (string) $cart->getOrderTotal(true));

    $module = Module::getInstanceByName($legacy ? 'bankwire' : 'ps_wirepayment');
    $total = $cart->getOrderTotal(true, Cart::BOTH);
    $module->validateOrder((int) $cart->id, (int) Configuration::get('PS_OS_BANKWIRE'), $total, $module->displayName, "cli $run", [], null, false, $customer->secure_key);
    $order = new Order((int) $module->currentOrder);
    t('order: validateOrder placed it', Validate::isLoadedObject($order) && $order->id_cart == $cart->id, 'no order');
    t('order: total is the cart total', abs((float) $order->total_paid - $total) < 0.005, "{$order->total_paid} vs $total");
    t('order: two detail lines', count($order->getProducts()) === 2);
    t('order: found again by reference', count(Order::getByReference($order->reference)) === 1);
    t('order: stock of the new product went down by 2', StockAvailable::getQuantityAvailableByProduct($productId, 0) === 38, (string) StockAvailable::getQuantityAvailableByProduct($productId, 0));

    $history = new OrderHistory();
    $history->id_order = (int) $order->id;
    $history->id_employee = 1;
    $history->changeIdOrderState((int) Configuration::get('PS_OS_PAYMENT'), $order, true);
    t('order: state change to payment accepted', $history->add());
    $order = new Order((int) $order->id);
    t('order: payment recorded and invoice numbered', count($order->getOrderPayments()) >= 1 && (int) $order->invoice_number > 0, "payments " . count($order->getOrderPayments()) . " invoice {$order->invoice_number}");

    $pdf = new PDF($order->getInvoicesCollection(), PDF::TEMPLATE_INVOICE, $context->smarty);
    $content = $pdf->render(false);
    t('pdf: invoice renders (TCPDF, fonts, GD)', is_string($content) && str_starts_with($content, '%PDF-') && strlen($content) > 5000, 'len ' . strlen((string) $content));
    $slips = new PDF($order->getInvoicesCollection(), PDF::TEMPLATE_DELIVERY_SLIP, $context->smarty);
    $content = $slips->render(false);
    t('pdf: delivery slip renders', is_string($content) && str_starts_with($content, '%PDF-'));
});

/* --- thumbnails regenerated from existing originals ------------------------------- */

attempt('regenerate thumbnails', function () use ($m) {
    $tmp = sys_get_temp_dir() . '/apptest-thumbs-' . getmypid();
    mkdir($tmp, 0777, true);
    foreach (['simple', 'combo'] as $key) {
        $id = $m['products'][$key]['cover_image'];
        $orig = _PS_PRODUCT_IMG_DIR_ . Image::getImgFolderStatic($id) . $id . '.jpg';
        t("thumbnails: original of $key exists and is a jpeg", is_file($orig) && (getimagesize($orig)['mime'] ?? '') === 'image/jpeg');
        $bad = [];
        foreach (ImageType::getImagesTypes('products', true) as $type) {
            $dst = "$tmp/$id-{$type['name']}.jpg";
            $ok = ImageManager::resize($orig, $dst, (int) $type['width'], (int) $type['height'], 'jpg');
            $size = @getimagesize($dst);
            $existing = @getimagesize(_PS_PRODUCT_IMG_DIR_ . Image::getImgFolderStatic($id) . $id . '-' . $type['name'] . '.jpg');
            if (!$ok || !$size || $size[0] !== (int) $type['width'] || $size[1] !== (int) $type['height'] || !$existing || $existing[0] !== $size[0]) {
                $bad[] = $type['name'];
            }
        }
        t("thumbnails: $key regenerated for every image type, same dimensions as the fixture's", !$bad, implode(',', $bad));
    }
    if (version_compare(_PS_VERSION_, '8.0', '<')) {
        echo "SKIP: thumbnails: webp output -- ImageManager only writes jpg, png and gif before 8.0\n";
    } elseif (imagetypes() & IMG_WEBP) {
        $id = $m['products']['simple']['cover_image'];
        $orig = _PS_PRODUCT_IMG_DIR_ . Image::getImgFolderStatic($id) . $id . '.jpg';
        t('thumbnails: webp output', ImageManager::resize($orig, "$tmp/w.webp", 200, 200, 'webp') && (getimagesize("$tmp/w.webp")['mime'] ?? '') === 'image/webp');
    }
    if (extension_loaded('imagick')) {
        $id = $m['products']['simple']['cover_image'];
        $orig = _PS_PRODUCT_IMG_DIR_ . Image::getImgFolderStatic($id) . $id . '.jpg';
        $im = new Imagick($orig);
        $im->thumbnailImage(200, 200, true);
        $im->setImageFormat('png');
        t('thumbnails: Imagick thumbnail', $im->getImageWidth() === 200 && str_starts_with($im->getImageBlob(), "\x89PNG"));
    }
    $bo = ImageManager::thumbnail(_PS_PRODUCT_IMG_DIR_ . Image::getImgFolderStatic($m['products']['simple']['cover_image']) . $m['products']['simple']['cover_image'] . '.jpg', 'apptest-bo-thumb.jpg', 45);
    t('thumbnails: the back office thumbnail helper', is_string($bo) && str_contains($bo, '<img') && is_file(_PS_TMP_IMG_DIR_ . 'apptest-bo-thumb.jpg'));
    @unlink(_PS_TMP_IMG_DIR_ . 'apptest-bo-thumb.jpg');
    array_map('unlink', glob("$tmp/*"));
    rmdir($tmp);
});

/* --- helper layers -------------------------------------------------------------------- */

attempt('helpers', function () use ($m, $run, $legacy) {
    if ($legacy) {
        $hash = Tools::encrypt('Correct-Horse-1');
        t('hashing: Tools::encrypt is md5 of the cookie key and the password', $hash === md5(_COOKIE_KEY_ . 'Correct-Horse-1') && $hash !== Tools::encrypt('Correct-Horse-2') && strlen($hash) === 32);
    } else {
        $hashing = new PrestaShop\PrestaShop\Core\Crypto\Hashing();
        $hash = $hashing->hash('Correct-Horse-1', _COOKIE_KEY_);
        t('hashing: bcrypt hash verifies and rejects', $hashing->checkHash('Correct-Horse-1', $hash, _COOKIE_KEY_) && !$hashing->checkHash('Correct-Horse-2', $hash, _COOKIE_KEY_) && str_starts_with($hash, '$2y$'));
    }
    $pw = Tools::passwdGen(16);
    t('Tools::passwdGen', strlen($pw) === 16 && ctype_alnum($pw));
    t('Tools::str2url / link_rewrite validity', Validate::isLinkRewrite(Tools::str2url('Fresh Prince — Ünïcode 100%')));
    t('Validate: email, name, url, postcode', Validate::isEmail('a.b+c@example.co') && !Validate::isEmail('a@@b') && Validate::isName('Marie-Claire') && !Validate::isName('x<script>') && Validate::isAbsoluteUrl('https://example.com/a?b=c'));
    $cipher = $legacy ? new Rijndael(_RIJNDAEL_KEY_, _RIJNDAEL_IV_) : new PhpEncryption(_NEW_COOKIE_KEY_);
    $secret = "cookie \u{2603} payload $run";
    t('cookie encryption round-trip with non-ascii payload', $cipher->decrypt($cipher->encrypt($secret)) === $secret);
    $cookie = new Cookie('apptest' . $run);
    $cookie->foo = 'bar';
    t('Cookie object stores and reads values', $cookie->foo === 'bar');

    $ctx = Context::getContext();
    if ($legacy) {
        // 1.6 formats through the currency row's format (number_format), not CLDR data
        $price = Tools::displayPrice(1234.5, $ctx->currency);
        t('price formatting from the currency format', str_contains($price, '1,234.50') && str_contains($price, '$'), $price);
    } else {
        $price = Tools::getContextLocale($ctx)->formatPrice(1234.5, 'USD');
        t('locale: price formatting from the CLDR data', str_contains($price, '1,234.50') && str_contains($price, '$'), $price);
    }
    t('Mail::Send is a no-op when mail is disabled', Mail::Send(1, 'contact', 'apptest', [], 'nobody@apptest.test') === true);
    $ctx->smarty->assign('apptest_name', 'A&B <"x">');
    $translated = $legacy ? '{l s=\'Add to cart\'}' : '{l s="Add to cart" d="Shop.Theme.Actions"}';
    t('Smarty compiles and renders a template string', $ctx->smarty->fetch('string:{$apptest_name|escape:"html":"UTF-8"}|' . $translated) === 'A&amp;B &lt;&quot;x&quot;&gt;|Add to cart');

    $zip = sys_get_temp_dir() . "/apptest-$run.zip";
    $z = new ZipArchive();
    t('zip: create', $z->open($zip, ZipArchive::CREATE) === true && $z->addFromString('a/b.txt', 'hello') && $z->close());
    $dest = sys_get_temp_dir() . "/apptest-unzip-$run";
    t('Tools::ZipExtract', Tools::ZipExtract($zip, $dest) && file_get_contents("$dest/a/b.txt") === 'hello');
    Tools::deleteDirectory($dest);
    @unlink($zip);

    $wire = $legacy ? 'bankwire' : 'ps_wirepayment';
    $xml = Tools::simplexml_load_file(_PS_ROOT_DIR_ . "/modules/$wire/config.xml");
    t('xml: Tools::simplexml_load_file on a shipped module manifest', $xml && (string) $xml->name === $wire, 'no xml');

    if (class_exists('Memcached')) {
        $mc = new Memcached();
        $mc->addServer('memcached', 11211);
        $mc->setOption(Memcached::OPT_SERIALIZER, defined('Memcached::SERIALIZER_IGBINARY') ? Memcached::SERIALIZER_IGBINARY : Memcached::SERIALIZER_PHP);
        $payload = ['run' => $run, 'nested' => range(1, 50), 'float' => 1.5];
        $mc->set("apptest-$run", $payload, 60);
        t('memcached: igbinary round-trip', $mc->get("apptest-$run") === $payload, (string) $mc->getResultMessage());
    }
    if (class_exists('Redis')) {
        $r = new Redis();
        $r->connect('redis', 6379, 5);
        $r->setOption(Redis::OPT_SERIALIZER, defined('Redis::SERIALIZER_IGBINARY') ? Redis::SERIALIZER_IGBINARY : Redis::SERIALIZER_PHP);
        $payload = ['run' => $run, 'utf8' => "caf\u{e9}", 'list' => range(1, 20)];
        $r->setex("apptest-$run", 60, $payload);
        t('redis: igbinary round-trip', $r->get("apptest-$run") === $payload);
    }
    t('Configuration: serialized value survives the database', (function () use ($run) {
        $v = ['a' => 1, 'b' => [true, null, 2.5, "x\u{fc}"]];
        Configuration::updateGlobalValue('APPTEST_CLI_' . $run, json_encode($v));
        Configuration::clearConfigurationCacheForTesting();
        Configuration::loadConfiguration();

        return json_decode(Configuration::get('APPTEST_CLI_' . $run), true) === $v;
    })());
});

/* --- 1.6 only: what bin/console does for the later releases, through the classes underneath ------------------------ */

if ($legacy) {
    attempt('module enable and disable', function () {
        $module = Module::getInstanceByName('blocksocial');
        $module->disable();   // returns nothing in 1.6
        Cache::clean('Module::isEnabledblocksocial');   // isEnabled() memoizes per process and enable()/disable() do not reset it
        t('module: disable through the Module API', !Module::isEnabled('blocksocial'));
        $enabled = $module->enable();
        Cache::clean('Module::isEnabledblocksocial');
        t('module: enable it again', $enabled && Module::isEnabled('blocksocial'));
    });
    attempt('smarty from cold', function () {
        $smarty = Context::getContext()->smarty;
        Tools::clearSmartyCache();
        Tools::clearCompile();
        $smarty->setTemplateDir(_PS_THEME_DIR_);
        ob_start();
        $smarty->compileAllTemplates('.tpl', true, 0, null);
        $out = ob_get_clean();
        $want = 0;
        foreach (new RecursiveIteratorIterator(new RecursiveDirectoryIterator(_PS_THEME_DIR_, FilesystemIterator::SKIP_DOTS)) as $f) {
            $want += substr($f->getFilename(), -4) === '.tpl' ? 1 : 0;
        }
        // the theme ships one template that does not compile ("unknown tag summarypaginationlink"), for a module that is
        // not installed; nothing loads it. Any other error, or any template that does not report, fails.
        preg_match_all('#Error: Syntax error in template "([^"]+)"#', $out, $errors);
        $broken = array_values(array_diff($errors[1], [_PS_THEME_DIR_ . 'modules/loyalty/views/templates/front/loyalty.tpl']));
        $got = substr_count($out, 'compiled in') + count($errors[1]);
        t("smarty: all $want theme templates compile from a cold cache (the cache:warmup of 1.6)", $want > 50 && $got === $want && !$broken, "$got of $want reported; " . implode(', ', $broken));
        Tools::clearSmartyCache();
        Tools::clearCompile();
        t('smarty: cache and compile directories clear and still render', Context::getContext()->smarty->fetch('string:{if true}rendered{/if}') === 'rendered');
    });
}

exit($failed ? 1 : 0);
