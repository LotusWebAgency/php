<?php
/*
 * Shared by manifest.php (fixture build) and check-golden.php (CLI suite):
 * the data constants populate.php seeds from, and the canonical form the
 * webservice golden is hashed in.
 */
const AT_PASSWORD_KNOWN = 'Customer-Pass-%03d!';
const MATERIALS = ['Oak', 'Linen', 'Steel', 'Ceramic', 'Cotton', 'Bamboo', 'Leather', 'Glass', 'Wool', 'Copper',
    'Walnut', 'Canvas', 'Brass', 'Marble', 'Recycled'];

function pick(array $list, string $key)
{
    return $list[crc32($key) % count($list)];
}

const WS_KEY = 'APPTESTWSKEYAPPTESTWSKEY12345678';

/** What the fixture holds, counted the same way at build time and when the CLI suite checks it. */
function fixtureCounts(): array
{
    $db = Db::getInstance();
    $count = function (string $table, string $where = '1') use ($db) {
        return (int) $db->getValue((new DbQuery())->select('COUNT(*)')->from($table)->where($where));
    };
    $seededCustomers = "email LIKE 'customer%@apptest.test'";

    return [
        'categories' => $count('category', 'id_category > 2'),
        'catalog_products' => $count('product', "reference LIKE 'AT-%'"),
        'combinations' => $count('product_attribute', 'id_product IN (SELECT id_product FROM ' . _DB_PREFIX_ . "product WHERE reference LIKE 'AT-%')"),
        'catalog_images' => $count('image', 'id_product IN (SELECT id_product FROM ' . _DB_PREFIX_ . "product WHERE reference LIKE 'AT-%')"),
        'customers' => $count('customer', $seededCustomers),
        'addresses' => $count('address', 'id_customer IN (SELECT id_customer FROM ' . _DB_PREFIX_ . "customer WHERE $seededCustomers)"),
        'orders' => $count('orders'),
        'order_details' => $count('order_detail'),
        'cart_rules' => $count('cart_rule'),
        'specific_prices' => $count('specific_price'),
        'manufacturers' => $count('manufacturer'),
        'features' => $count('feature'),
        'search_words' => $count('search_word'),
        'layered_price_rows' => $count('layered_price_index'),
    ];
}

function h(string $key, int $mod): int
{
    return crc32($key) % $mod;
}

function ml(string $text): array
{
    $out = [];
    foreach (Language::getLanguages(false) as $lang) {
        $out[(int) $lang['id_lang']] = $text;
    }

    return $out;
}

// no `: void` here or anywhere the 1.6 set loads: PHP 7.0 has no void
function mustSave(ObjectModel $o, string $what)
{
    if (!$o->add()) {
        fwrite(STDERR, "FATAL: could not add $what\n");
        exit(1);
    }
}

/* --- images ---------------------------------------------------------------- */

function gdSource(int $seed, string $label, int $size = 1000): string
{
    $im = imagecreatetruecolor($size, $size);
    $base = [40 + h("r$seed", 180), 40 + h("g$seed", 180), 40 + h("b$seed", 180)];
    for ($y = 0; $y < $size; $y += 8) {
        $f = $y / $size;
        $c = imagecolorallocate($im, (int) ($base[0] * (1 - $f * 0.5)), (int) ($base[1] * (1 - $f * 0.4)), (int) ($base[2] + (255 - $base[2]) * $f * 0.5));
        imagefilledrectangle($im, 0, $y, $size, $y + 8, $c);
    }
    for ($k = 0; $k < 6; $k++) {
        $c = imagecolorallocatealpha($im, 255 - $base[($k) % 3], 200 - $base[($k + 1) % 3] / 2, 120 + $k * 20, 60);
        imagefilledellipse($im, h("x$seed$k", $size), h("y$seed$k", $size), 150 + h("w$seed$k", 400), 150 + h("v$seed$k", 400), $c);
    }
    $white = imagecolorallocate($im, 255, 255, 255);
    imagestring($im, 5, 24, 24, $label, $white);
    $path = tempnam(_PS_TMP_IMG_DIR_, 'at_src');
    imagejpeg($im, $path, 85);
    imagedestroy($im);

    return $path;
}

/** Registers a product image and cuts every product image type from it, as the BO uploader does. */
function attachProductImage(int $idProduct, string $legend, int $seed, bool $cover): int
{
    $image = new Image();
    $image->id_product = $idProduct;
    $image->position = Image::getHighestPosition($idProduct) + 1;
    $image->cover = $cover ? 1 : null;
    $image->legend = ml($legend);
    mustSave($image, "image for product $idProduct");
    $src = gdSource($seed, $legend);
    $path = $image->getPathForCreation();
    ImageManager::resize($src, $path . '.jpg', null, null, 'jpg');
    foreach (ImageType::getImagesTypes('products', true) as $type) {
        ImageManager::resize($src, $path . '-' . stripslashes($type['name']) . '.jpg', (int) $type['width'], (int) $type['height'], 'jpg');
    }
    @unlink($src);
    Hook::exec('actionWatermark', ['id_image' => $image->id, 'id_product' => $idProduct]);

    return (int) $image->id;
}

function attachCategoryImage(int $idCategory, string $label, int $seed)
{
    $src = gdSource($seed, $label, 1000);
    ImageManager::resize($src, _PS_CAT_IMG_DIR_ . $idCategory . '.jpg', null, null, 'jpg');
    foreach (ImageType::getImagesTypes('categories', true) as $type) {
        ImageManager::resize($src, _PS_CAT_IMG_DIR_ . $idCategory . '-' . stripslashes($type['name']) . '.jpg', (int) $type['width'], (int) $type['height'], 'jpg');
    }
    @unlink($src);
}


const WS_VOLATILE = ['date_add' => 1, 'date_upd' => 1];

/** path=value lines, keys sorted, scalars as strings, volatile fields dropped. Python's twin is in suite/web.py. */
function wsFlatten($node, string $path): array
{
    $out = [];
    if (is_array($node)) {
        $keys = array_keys($node);
        if (array_keys($node) !== range(0, count($node) - 1)) {
            sort($keys, SORT_STRING);
        }
        foreach ($keys as $k) {
            if (isset(WS_VOLATILE[$k])) {
                continue;
            }
            $out = array_merge($out, wsFlatten($node[$k], $path . '.' . $k));
        }
    } else {
        $out[] = $path . '=' . ($node === null ? '' : (is_bool($node) ? ($node ? '1' : '0') : (string) $node));
    }

    return $out;
}

function wsCanonicalHash(string $json): string
{
    $data = json_decode($json, true);
    if (!is_array($data) || !$data) {
        fwrite(STDERR, "FATAL: webservice answer is not a JSON object\n");
        exit(1);
    }
    $keys = array_keys($data);   // array_key_first() and JSON_THROW_ON_ERROR are 7.3; this file runs on 7.0
    $root = $keys[0];

    return hash('sha256', implode("\n", wsFlatten($data[$root], $root)));
}

function wsGet(string $resource, string $base = 'http://127.0.0.1:8081'): string
{
    $key = WS_KEY;
    $ctx = stream_context_create(['http' => ['header' => "Host: apptest.test\r\n", 'timeout' => 120, 'ignore_errors' => true]]);
    $body = file_get_contents($base . '/webservice/dispatcher.php?url=' . $resource . '&output_format=JSON&ws_key=' . $key, false, $ctx);
    if ($body === false || strpos(ltrim($body), '{') !== 0) {
        fwrite(STDERR, "FATAL: webservice $resource did not answer JSON: " . substr((string) $body, 0, 300) . "\n");
        exit(1);
    }

    return $body;
}
