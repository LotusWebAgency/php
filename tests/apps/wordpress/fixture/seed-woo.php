<?php
// WooCommerce data through its CRUD classes (wp eval-file). Two stages,
// because a global attribute's taxonomy is only registered by the *next*
// process after wc_create_attribute(): stage1 sets the shop up, stage2 fills it.
require __DIR__ . '/lib.php';

function must($v, string $what)
{
    if (is_wp_error($v)) {
        fwrite(STDERR, "FATAL: {$what}: " . $v->get_error_message() . "\n");
        exit(1);
    }
    return $v;
}

$stage = $args[0] ?? '';
wp_set_current_user(get_user_by('login', 'admin')->ID);

if ($stage === 'stage1') {
    // Fires on the first admin request of a real site; nothing here is one.
    // Among other things it switches HPOS on (Woo's default for a shop that has no orders yet).
    // Releases before it existed (8.x introduced it) keep orders as posts.
    if (method_exists('WC_Install', 'newly_installed')) {
        WC_Install::newly_installed();
    }
    // Before WooCommerce 4 only the setup wizard creates the shop, cart, checkout and account pages.
    if ((int) wc_get_page_id('shop') < 1 && method_exists('WC_Install', 'create_pages')) {
        WC_Install::create_pages();
    }
    // Nothing here may call out: the site is offline and a stalled wizard or
    // marketplace fetch would slow every admin page.
    foreach ([
        'woocommerce_currency' => 'USD',
        'woocommerce_default_country' => 'US:CA',
        'woocommerce_store_address' => '1 Test Street',
        'woocommerce_store_city' => 'Testville',
        'woocommerce_store_postcode' => '90001',
        'woocommerce_calc_taxes' => 'no',
        'woocommerce_manage_stock' => 'yes',
        'woocommerce_enable_guest_checkout' => 'yes',
        'woocommerce_enable_signup_and_login_from_checkout' => 'yes',
        'woocommerce_enable_myaccount_registration' => 'yes',
        'woocommerce_allow_tracking' => 'no',
        'woocommerce_show_marketplace_suggestions' => 'no',
        'woocommerce_coming_soon' => 'no',
        'woocommerce_store_pages_only' => 'no',
        'woocommerce_task_list_hidden' => 'yes',
        'woocommerce_task_list_complete' => 'yes',
        'woocommerce_task_list_welcome_modal_dismissed' => 'yes',
        'woocommerce_admin_customize_store_completed' => 'yes',
    ] as $k => $v) {
        update_option($k, $v);
    }
    update_option('woocommerce_onboarding_profile', ['skipped' => true, 'completed' => true]);
    update_option('woocommerce_cod_settings', ['enabled' => 'yes', 'title' => 'Cash on delivery', 'description' => 'Pay on delivery.', 'instructions' => 'Pay on delivery.', 'enable_for_methods' => [], 'enable_for_virtual' => 'yes']);

    $zone = new WC_Shipping_Zone();
    $zone->set_zone_name('Test zone');
    foreach (['US', 'CA', 'GB', 'DE', 'FR', 'JP', 'RU'] as $cc) {
        $zone->add_location($cc, 'country');
    }
    $zone->save();
    $instance = $zone->add_shipping_method('flat_rate');
    $method = WC_Shipping_Zones::get_shipping_method($instance);
    $method->init_instance_settings();
    $method->instance_settings = array_merge($method->instance_settings, ['title' => 'Flat rate', 'tax_status' => 'none', 'cost' => '5.00']);
    update_option($method->get_instance_option_key(), $method->instance_settings);

    $coupon = new WC_Coupon();
    $coupon->set_code('welcome10');
    $coupon->set_discount_type('percent');
    $coupon->set_amount('10');
    $coupon->save();

    $wcCats = [];
    foreach (['Clothing', 'Gadgets', 'Home', 'Books', 'Одежда'] as $c) {
        $wcCats[] = must(wp_insert_term($c, 'product_cat'), "product_cat $c")['term_id'];
    }
    foreach (['T-shirts' => 0, 'Hoodies' => 0, 'Phones' => 1, 'Audio' => 1, 'Kitchen' => 2, 'Novels' => 3] as $c => $parent) {
        $wcCats[] = must(wp_insert_term($c, 'product_cat', ['parent' => $wcCats[$parent]]), "product_cat $c")['term_id'];
    }
    $wcTags = [];
    for ($k = 1; $k <= 20; $k++) {
        $wcTags[] = must(wp_insert_term(sprintf('%s %02d', Gen::pick(['sale', 'new', 'eco', 'limited', 'bestseller'], 'wt', $k), $k), 'product_tag'), "product_tag $k")['term_id'];
    }
    wc_create_attribute(['name' => 'Color', 'slug' => 'color', 'type' => 'select', 'order_by' => 'menu_order', 'has_archives' => false]);

    $customers = [];
    for ($k = 1; $k <= 5; $k++) {
        $login = sprintf('customer_%02d', $k);
        $id = must(wc_create_new_customer($login . '@apptest.test', $login, 'Apptest!' . $login, ['first_name' => ['Ann', 'Ben', 'Кира', 'Dai', 'Eli'][$k - 1], 'last_name' => ['Lee', 'Ford', 'Орлова', 'Woo', 'Park'][$k - 1]]), "customer $k");
        $c = new WC_Customer($id);
        foreach (['billing', 'shipping'] as $type) {
            $c->{"set_{$type}_first_name"}($c->get_first_name());
            $c->{"set_{$type}_last_name"}($c->get_last_name());
            $c->{"set_{$type}_address_1"}("{$k} Customer Road");
            $c->{"set_{$type}_city"}('Testville');
            $c->{"set_{$type}_state"}('CA');
            $c->{"set_{$type}_postcode"}('90001');
            $c->{"set_{$type}_country"}('US');
        }
        $c->set_billing_email($login . '@apptest.test');
        $c->set_billing_phone('555-010' . $k);
        $c->save();
        $customers[] = ['id' => $id, 'login' => $login, 'password' => 'Apptest!' . $login, 'email' => $login . '@apptest.test'];
    }
    $shopManager = must(wp_insert_user(['user_login' => 'shop_manager_01', 'user_pass' => 'Apptest!shop_manager_01', 'user_email' => 'shop_manager_01@apptest.test', 'role' => 'shop_manager', 'display_name' => 'Shop Manager']), 'shop manager');

    apptest_write_json(apptest_part_path('woo1'), [
        'product_categories' => $wcCats, 'product_tags' => $wcTags, 'customers' => $customers,
        'shop_manager' => ['id' => $shopManager, 'login' => 'shop_manager_01', 'password' => 'Apptest!shop_manager_01'],
        'shipping_instance' => $instance, 'coupon' => 'welcome10',
    ]);
    fwrite(STDERR, "woo stage1 done\n");
    return;
}

// -- stage 2 ----------------------------------------------------------------------
$core = apptest_read_json(apptest_part_path('core'));
$w1 = apptest_read_json(apptest_part_path('woo1'));
$images = $core['attachments'];
$cats = $w1['product_categories'];
$tags = $w1['product_tags'];
$colorTax = taxonomy_exists('pa_color');
if (!$colorTax) {
    fwrite(STDERR, "FATAL: pa_color taxonomy is not registered in stage 2\n");
    exit(1);
}
$colorTerms = [];
foreach (['Red', 'Green', 'Blue', 'Black', 'White'] as $name) {
    $t = must(wp_insert_term($name, 'pa_color'), "pa_color $name");
    $colorTerms[$name] = get_term($t['term_id'])->slug;
}

$price = function (string $salt, int $n): string {
    $cents = 500 + Gen::h($salt, $n) % 19500;
    return sprintf('%d.%02d', intdiv($cents, 100), $cents % 100);
};

$total = Gen::n(300);
$simple = [];
$variable = [];
$variations = 0;
for ($p = 1; $p <= $total; $p++) {
    $isVariable = $p % 5 === 0;
    $product = $isVariable ? new WC_Product_Variable() : new WC_Product_Simple();
    $product->set_name(Gen::title($p, 'Product'));
    $product->set_status('publish');
    $product->set_catalog_visibility('visible');
    $product->set_sku(sprintf('APPT-%04d', $p));
    $product->set_description(Blocks::article(4000 + $p, $images));
    $product->set_short_description(Gen::words(14, 'sd', $p, Gen::lang($p)));
    $product->set_category_ids([$cats[Gen::h('pc', $p) % count($cats)], $cats[Gen::h('pd', $p) % count($cats)]]);
    $product->set_tag_ids(array_values(array_unique([$tags[Gen::h('ptg', $p) % count($tags)], $tags[Gen::h('pth', $p) % count($tags)]])));
    $product->set_image_id($images[$p % count($images)]);
    if ($p % 4 === 0) {
        $product->set_gallery_image_ids([$images[($p + 1) % count($images)], $images[($p + 2) % count($images)]]);
    }
    $product->set_weight((string) (1 + $p % 9));
    $product->set_length((string) (10 + $p % 20));
    $product->set_width((string) (5 + $p % 10));
    $product->set_height((string) (2 + $p % 7));
    $product->set_date_created(Gen::date($p, 61860));
    $product->update_meta_data('apptest_note', Gen::words(3, 'pn', $p, Gen::lang($p)));

    if (!$isVariable) {
        $regular = $price('pr', $p);
        $product->set_regular_price($regular);
        if ($p % 5 === 1) {
            $product->set_sale_price(sprintf('%.2f', intdiv((int) round($regular * 100) * 8, 10) / 100));
        }
        $product->set_manage_stock(true);
        $qty = $p % 17 === 0 ? 0 : Gen::between(5, 500, 'pq', $p);
        $product->set_stock_quantity($qty);
        $product->set_stock_status($qty > 0 ? 'instock' : 'outofstock');
        $simple[] = $product->save();
        continue;
    }

    $sizes = array_slice(['S', 'M', 'L', 'XL'], 0, Gen::between(2, 3, 'sz', $p));
    $useGlobal = $p % 10 === 0;
    $colors = array_slice($useGlobal ? array_keys($colorTerms) : ['Red', 'Green', 'Blue'], 0, 2);
    $sizeAttr = new WC_Product_Attribute();
    $sizeAttr->set_name('Size');
    $sizeAttr->set_options($sizes);
    $sizeAttr->set_position(0);
    $sizeAttr->set_visible(true);
    $sizeAttr->set_variation(true);
    $colorAttr = new WC_Product_Attribute();
    if ($useGlobal) {
        $colorAttr->set_id(wc_attribute_taxonomy_id_by_name('pa_color'));
        $colorAttr->set_name('pa_color');
        $colorAttr->set_options(array_map(function ($c) use ($colorTerms) { return get_term_by('slug', $colorTerms[$c], 'pa_color')->term_id; }, $colors));
    } else {
        $colorAttr->set_name('Color');
        $colorAttr->set_options($colors);
    }
    $colorAttr->set_position(1);
    $colorAttr->set_visible(true);
    $colorAttr->set_variation(true);
    $product->set_attributes([$sizeAttr, $colorAttr]);
    $parentId = $product->save();

    $base = $price('pr', $p);
    $v = 0;
    foreach ($sizes as $size) {
        foreach ($colors as $color) {
            $var = new WC_Product_Variation();
            $var->set_parent_id($parentId);
            $var->set_attributes(['size' => $size, $useGlobal ? 'pa_color' : 'color' => $useGlobal ? $colorTerms[$color] : $color]);
            $var->set_sku(sprintf('APPT-%04d-%s-%s', $p, $size, strtoupper(substr($color, 0, 3))));
            $var->set_regular_price(sprintf('%.2f', (int) round($base * 100) / 100 + $v));
            $var->set_manage_stock(true);
            $var->set_stock_quantity(Gen::between(3, 100, 'vq', $p * 10 + $v));
            $var->set_status('publish');
            if ($v % 2 === 0) {
                $var->set_image_id($images[($p + $v) % count($images)]);
            }
            $var->save();
            $v++;
            $variations++;
        }
    }
    WC_Product_Variable::sync($parentId);
    wc_delete_product_transients($parentId);
    $variable[] = $parentId;
    apptest_progress('products', $p, $total);
}
$products = array_merge($simple, $variable);
sort($products);

// -- orders through the CRUD API ---------------------------------------------------------
$orderIds = [];
$customerOrders = [];
$statuses = ['completed', 'processing', 'on-hold', 'cancelled', 'pending'];
$orderTotal = Gen::n(20);
for ($o = 1; $o <= $orderTotal; $o++) {
    $customer = $o % 6 === 0 ? 0 : $w1['customers'][$o % 5]['id'];
    $order = wc_create_order(['customer_id' => $customer, 'status' => 'pending']);
    $lines = Gen::between(1, 4, 'ol', $o);
    for ($l = 0; $l < $lines; $l++) {
        $pid = $products[Gen::h('op', $o * 10 + $l) % count($products)];
        $product = wc_get_product($pid);
        if ($product->is_type('variable')) {
            $children = $product->get_children();
            $product = wc_get_product($children[Gen::h('ov', $o * 10 + $l) % count($children)]);
        }
        $order->add_product($product, Gen::between(1, 3, 'oq', $o * 10 + $l));
    }
    $address = ['first_name' => 'Order' . $o, 'last_name' => 'Тест', 'address_1' => "{$o} Order Lane", 'city' => 'Testville', 'state' => 'CA', 'postcode' => '90001', 'country' => 'US', 'email' => "order{$o}@apptest.test", 'phone' => '555-0100'];
    $order->set_address($address, 'billing');
    $order->set_address(array_diff_key($address, ['email' => 1, 'phone' => 1]), 'shipping');
    $ship = new WC_Order_Item_Shipping();
    $ship->set_method_title('Flat rate');
    $ship->set_method_id('flat_rate');
    $ship->set_instance_id($w1['shipping_instance']);
    $ship->set_total('5.00');
    $order->add_item($ship);
    $order->set_payment_method('cod');
    $order->set_payment_method_title('Cash on delivery');
    $order->set_date_created(Gen::date($o * 40, 61860));
    $order->calculate_totals(false);
    $order->set_status($statuses[$o % 5], 'Seeded order ' . $o);
    $order->save();
    $order->add_order_note('Seed note ' . $o . ' ' . Gen::words(4, 'on', $o, Gen::lang($o)));
    $orderIds[] = $order->get_id();
    $customerOrders[$customer][] = $order->get_id();
    if ($o === 2 && $order->get_status() === 'processing') {
        must(wc_create_refund(['order_id' => $order->get_id(), 'amount' => '1.00', 'reason' => 'seed partial refund']), 'refund');
    }
}
$couponOrder = null;

$sample = function (int $id) {
    $pr = wc_get_product($id);
    return ['id' => $id, 'slug' => $pr->get_slug(), 'name' => $pr->get_name(), 'sku' => $pr->get_sku(), 'price' => $pr->get_price(), 'path' => apptest_path(get_permalink($id))];
};
$firstSimpleInStock = null;
foreach ($simple as $id) {
    $pr = wc_get_product($id);
    if ($pr->is_in_stock() && $pr->get_stock_quantity() > 50 && !$pr->is_on_sale()) {
        $firstSimpleInStock = $id;
        break;
    }
}
$firstVariable = $variable[0];
$variationSample = wc_get_product($firstVariable)->get_children()[0];
$pages = [];
foreach (['shop', 'cart', 'checkout', 'myaccount'] as $pg) {
    $pid = wc_get_page_id($pg);
    $pages[$pg] = ['id' => $pid, 'path' => apptest_path(get_permalink($pid))];
}
$catInfo = get_term($cats[0], 'product_cat');
$woo = $w1 + [
    'version' => WC()->version,
    'products' => $products,
    'simple_products' => $simple,
    'variable_products' => $variable,
    'variation_count' => $variations,
    'orders' => $orderIds,
    'customer_orders' => $customerOrders,
    'pages' => $pages,
    'simple_sample' => $sample($firstSimpleInStock),
    'variable_sample' => $sample($firstVariable) + ['variation_id' => $variationSample, 'variation_attributes' => wc_get_product($variationSample)->get_attributes()],
    'category' => ['id' => $catInfo->term_id, 'slug' => $catInfo->slug, 'name' => $catInfo->name, 'path' => apptest_path(get_term_link($catInfo))],
    'hpos' => get_option('woocommerce_custom_orders_table_enabled') === 'yes' ? 'yes' : 'no',
    // New shops get the Cart and Checkout blocks from 8.3 on; older ones get the shortcode pages.
    'checkout_blocks' => function_exists('has_block') && has_block('woocommerce/checkout', get_post($pages['checkout']['id'])),
    'currency' => get_woocommerce_currency(),
];
apptest_write_json(apptest_part_path('woo'), $woo);
fwrite(STDERR, "woo seeded: " . count($products) . " products, " . count($orderIds) . " orders\n");
