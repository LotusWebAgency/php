<?php
/*
 * Fills the freshly installed shop through ObjectModel so the tables, caches
 * and hooks see the same writes a busy shop would leave behind. Everything is
 * derived from counters and crc32(), never rand(): mt_rand sequences differ
 * between PHP versions, and a fixture built on 8.1 has to describe itself the
 * same way when it is rebuilt on anything else.
 *
 *   APPTEST_PHASES=categories,catalog,customers,pricing,orders,indexes
 *   APPTEST_PRODUCTS=1000 APPTEST_CUSTOMERS=200 APPTEST_ORDERS=100
 */
require __DIR__ . '/bootstrap.php';
require __DIR__ . '/lib.php';

$nProducts = (int) (getenv('APPTEST_PRODUCTS') ?: 1000);
$nCustomers = (int) (getenv('APPTEST_CUSTOMERS') ?: 200);
$nOrders = (int) (getenv('APPTEST_ORDERS') ?: 100);
$phases = array_filter(explode(',', getenv('APPTEST_PHASES') ?: 'categories,catalog,customers,pricing,orders,indexes'));
$idLang = (int) Configuration::get('PS_LANG_DEFAULT');
$legacy = version_compare(_PS_VERSION_, '1.7', '<');   // 1.6: no Symfony, no Hashing class, its own module set
$T0 = microtime(true);

function say(string $msg)
{
    global $T0;
    printf("[%6.1fs] %s\n", microtime(true) - $T0, $msg);
}

const ADJECTIVES = ['Classic', 'Modern', 'Rustic', 'Compact', 'Deluxe', 'Vintage', 'Nordic', 'Urban', 'Coastal', 'Alpine',
    'Minimal', 'Bold', 'Soft', 'Sturdy', 'Elegant', 'Playful', 'Handmade', 'Limited', 'Signature', 'Everyday'];
const NOUNS = ['Lamp', 'Mug', 'Notebook', 'Backpack', 'Chair', 'Blanket', 'Poster', 'Clock', 'Vase', 'Planter',
    'Shelf', 'Cushion', 'Tray', 'Bottle', 'Wallet', 'Candle', 'Frame', 'Stool', 'Rug', 'Basket',
    'Kettle', 'Bowl', 'Apron', 'Pouch', 'Hook', 'Coaster', 'Tote', 'Journal', 'Pen Set', 'Desk Mat'];
const TOPICS = ['Living', 'Kitchen', 'Office', 'Garden', 'Travel', 'Bath', 'Studio', 'Outdoor', 'Kids', 'Gifts'];
const SUBTOPICS = ['Essentials', 'Decor', 'Storage', 'Lighting', 'Textiles', 'Tools', 'Seasonal', 'Premium', 'Basics', 'Outlet'];
const GIVEN = ['Ada', 'Grace', 'Alan', 'Linus', 'Margaret', 'Dennis', 'Barbara', 'Ken', 'Edsger', 'Radia', 'Donald', 'Frances',
    'Tim', 'Hedy', 'Vint', 'Katherine', 'Guido', 'Sophie', 'Brian', 'Annie'];
const FAMILY = ['Lovelace', 'Hopper', 'Turing', 'Torvalds', 'Hamilton', 'Ritchie', 'Liskov', 'Thompson', 'Dijkstra', 'Perlman',
    'Knuth', 'Allen', 'Berners', 'Lamarr', 'Cerf', 'Johnson', 'Rossum', 'Wilson', 'Kernighan', 'Easley'];
const STREETS = ['Maple', 'Cedar', 'Elm', 'Pine', 'Lake', 'Hill', 'Sunset', 'River', 'Park', 'Oak', 'Highland', 'Church'];
const CITIES = ['Springfield', 'Riverton', 'Fairview', 'Madison', 'Georgetown', 'Clinton', 'Franklin', 'Salem', 'Ashland', 'Milton'];

function word(string $seed, array $list): string
{
    return pick($list, $seed);
}

/* --- categories -------------------------------------------------------------- */

$leafCategories = [];
$categoryNames = [];
if (in_array('categories', $phases, true)) {
    $home = (int) Configuration::get('PS_HOME_CATEGORY');
    $made = 0;
    $mk = function (string $name, int $parent) use (&$made, &$categoryNames): int {
        $c = new Category();
        $c->name = ml($name);
        $c->link_rewrite = ml(Tools::str2url($name));
        $c->description = ml("<p>$name: a browsing category of the application test shop.</p>");
        $c->meta_title = ml($name);
        $c->id_parent = $parent;
        $c->active = 1;
        mustSave($c, "category $name");
        $categoryNames[(int) $c->id] = $name;
        ++$made;

        return (int) $c->id;
    };
    // 10 departments, 30 sections, 60 shelves = 100 categories, three levels deep.
    foreach (TOPICS as $ti => $topic) {
        $l1 = $mk($topic, $home);
        if ($ti < 4) {
            attachCategoryImage($l1, $topic, 9000 + $ti);
        }
        for ($si = 0; $si < 3; $si++) {
            $section = "$topic " . SUBTOPICS[($ti + $si * 3) % count(SUBTOPICS)];
            $l2 = $mk($section, $l1);
            for ($k = 0; $k < 2; $k++) {
                $l3 = $mk("$section " . ['Small', 'Large'][$k], $l2);
                $leafCategories[] = $l3;
            }
        }
    }
    Category::regenerateEntireNtree();
    say("categories: $made created, " . count($leafCategories) . ' leaves');
}
if (!$leafCategories) {
    $leafCategories = array_map('intval', array_column(Db::getInstance()->executeS(
        (new DbQuery())->select('c.id_category')->from('category', 'c')
            ->where('c.level_depth = 4')->orderBy('c.id_category')
    ) ?: [], 'id_category'));
}

/* --- catalog ------------------------------------------------------------------ */

if (in_array('catalog', $phases, true)) {
    $manufacturerIds = [];
    for ($i = 1; $i <= 10; $i++) {
        $m = new Manufacturer();
        $m->name = "Apptest Maker $i";
        $m->active = 1;
        $m->description = ml("Maker number $i.");
        $m->short_description = ml("Maker $i");
        $m->meta_title = ml("Apptest Maker $i");
        mustSave($m, "manufacturer $i");
        $manufacturerIds[] = (int) $m->id;
    }
    $supplierIds = [];
    for ($i = 1; $i <= 5; $i++) {
        $s = new Supplier();
        $s->name = "Apptest Supplier $i";
        $s->active = 1;
        $s->description = ml("Supplier number $i.");
        $s->meta_title = ml("Apptest Supplier $i");
        mustSave($s, "supplier $i");
        $supplierIds[] = (int) $s->id;
    }

    $features = [];
    foreach (['Material' => MATERIALS, 'Season' => ['Spring', 'Summer', 'Autumn', 'Winter', 'All year'],
        'Origin' => ['Portugal', 'Japan', 'Denmark', 'Italy', 'Vietnam', 'Canada'],
        'Warranty' => ['1 year', '2 years', '5 years', 'Lifetime'],
        'Care' => ['Machine wash', 'Hand wash', 'Wipe clean', 'Dishwasher safe']] as $fname => $values) {
        $f = new Feature();
        $f->name = ml($fname);
        mustSave($f, "feature $fname");
        foreach ($values as $v) {
            $fv = new FeatureValue();
            $fv->id_feature = (int) $f->id;
            $fv->value = ml($v);
            mustSave($fv, "feature value $v");
            $features[(int) $f->id][] = (int) $fv->id;
        }
    }
    $featureIds = array_keys($features);

    // Extra Size/Color values already ship with the demo data; combinations reuse those.
    // (1.6 has a Shoes Size group in between: Size 1, Shoes Size 2, Color 3.)
    $sizeGroup = 1;
    $colorGroup = $legacy ? 3 : 2;
    $sizeValues = array_map('intval', array_column(Db::getInstance()->executeS(
        (new DbQuery())->select('id_attribute')->from('attribute')->where('id_attribute_group = ' . $sizeGroup)->orderBy('id_attribute')
    ), 'id_attribute'));
    $colorValues = array_map('intval', array_column(Db::getInstance()->executeS(
        (new DbQuery())->select('id_attribute')->from('attribute')->where('id_attribute_group = ' . $colorGroup)->orderBy('id_attribute')
    ), 'id_attribute'));

    $taxGroups = [1, 5, 9, 13, 32, 43, 47];   // AL, CA, FL, IL, NY, TX, WA
    $homeCategory = (int) Configuration::get('PS_HOME_CATEGORY');
    $comboProducts = 0;
    $comboTotal = 0;
    $imageTotal = 0;
    for ($i = 1; $i <= $nProducts; $i++) {
        $name = sprintf('%s %s %s %d', word("a$i", ADJECTIVES), word("m$i", MATERIALS), word("n$i", NOUNS), $i);
        $p = new Product();
        $p->name = ml($name);
        $p->link_rewrite = ml(Tools::str2url($name));
        $p->description = ml("<p>$name is product number $i of the application test catalog. "
            . 'Made of ' . strtolower(word("m$i", MATERIALS)) . ', finished by hand and packed flat.</p>'
            . '<ul><li>Reference ' . sprintf('AT-%04d', $i) . '</li><li>Batch ' . h("batch$i", 900) . '</li></ul>');
        $p->description_short = ml("<p>{$name}, everyday quality.</p>");
        $p->meta_title = ml($name);
        $p->meta_description = ml("Buy $name at the Apptest Shop.");
        $p->reference = sprintf('AT-%04d', $i);
        $base = 12 + h("price$i", 240) + [0, 0.25, 0.5, 0.75, 0.9, 0.95][h("cents$i", 6)];
        $p->price = $base;
        $p->wholesale_price = round($base * 0.55, 2);
        $p->weight = 0.1 * (1 + h("wt$i", 40));
        $p->id_tax_rules_group = $taxGroups[h("tax$i", count($taxGroups))];
        $p->id_manufacturer = $manufacturerIds[h("mf$i", count($manufacturerIds))];
        $p->id_supplier = $supplierIds[h("sp$i", count($supplierIds))];
        $p->id_category_default = $leafCategories[($i - 1) % count($leafCategories)];
        $p->active = 1;
        $p->visibility = 'both';
        $p->available_for_order = 1;
        $p->show_price = 1;
        $p->condition = ['new', 'new', 'new', 'used', 'refurbished'][h("cond$i", 5)];
        $p->redirect_type = $legacy ? '' : '301-category';
        $p->minimal_quantity = 1;
        $p->ean13 = (function (int $n): string {
            $body = sprintf('200%09d', $n);
            $sum = 0;
            foreach (str_split($body) as $pos => $d) {
                $sum += (int) $d * ($pos % 2 ? 3 : 1);
            }

            return $body . ((10 - $sum % 10) % 10);
        })($i);
        mustSave($p, "product $i");
        $id = (int) $p->id;

        $cats = [$p->id_category_default, $leafCategories[($i * 7) % count($leafCategories)]];
        if ($i % 25 === 0) {
            $cats[] = $homeCategory;
        }
        $p->addToCategories(array_values(array_unique($cats)));

        foreach (array_slice($featureIds, 0, 2 + h("nf$i", 3)) as $fid) {
            $p->addFeaturesToDB($fid, $features[$fid][h("fv$i-$fid", count($features[$fid]))]);
        }

        $qty = ($i % 37 === 0) ? 0 : 20 + h("qty$i", 300);
        $firstImage = attachProductImage($id, $name, $i, true);
        ++$imageTotal;
        if ($i % 3 === 0) {
            attachProductImage($id, "$name (detail)", $i + 100000, false);
            ++$imageTotal;
        }

        if ($i % 5 === 0) {
            // A fifth of the catalog is sold in sizes and colors.
            $sizes = array_slice($sizeValues, 0, 2 + h("ns$i", 3));
            $colors = array_slice($colorValues, h("c0$i", 4), 1 + h("nc$i", 3));
            $first = true;
            $comboQty = 0;
            foreach ($sizes as $si => $sv) {
                foreach ($colors as $cv) {
                    $combo = new Combination();
                    $combo->id_product = $id;
                    $combo->reference = sprintf('AT-%04d-%d-%d', $i, $sv, $cv);
                    $combo->price = $si * 1.5;
                    $combo->weight = $si * 0.05;
                    $combo->minimal_quantity = 1;
                    $combo->default_on = $first ? 1 : null;
                    mustSave($combo, "combination of product $i");
                    $combo->setAttributes([$sv, $cv]);
                    $combo->setImages([$firstImage]);
                    $q = $qty ? 5 + h("cq$i-$sv-$cv", 60) : 0;
                    StockAvailable::setQuantity($id, (int) $combo->id, $q);
                    $comboQty += $q;
                    $first = false;
                    ++$comboTotal;
                }
            }
            ++$comboProducts;
            $qty = $comboQty;
        } else {
            StockAvailable::setQuantity($id, 0, $qty);
        }
        if ($i % 100 === 0) {
            say("products: $i/$nProducts ($comboProducts with combinations, $comboTotal combinations, $imageTotal images)");
        }
    }
    say("catalog done: $nProducts products, $comboProducts with combinations ($comboTotal), $imageTotal images");
}

/* --- customers ---------------------------------------------------------------- */

$customerIds = [];
if (in_array('customers', $phases, true)) {
    if ($legacy) {
        $hashPassword = function ($plain) {
            return Tools::encrypt($plain);   // md5(_COOKIE_KEY_ . $plain), what Customer::getByEmail() compares
        };
    } else {
        $hashing = new PrestaShop\PrestaShop\Core\Crypto\Hashing();
        $hashPassword = function ($plain) use ($hashing) {
            return $hashing->hash($plain, _COOKIE_KEY_);
        };
    }
    // Only the states that have a tax rules group among the products' (see $taxGroups), so tax actually applies to a good share of the orders.
    $states = Db::getInstance()->executeS(
        (new DbQuery())->select('id_state, iso_code')->from('state')->where('id_country = 21 AND iso_code IN ("AL","CA","FL","IL","NY","TX","WA")')->orderBy('id_state')
    );
    $wholesale = new Group();
    $wholesale->name = ml('Wholesale');
    $wholesale->reduction = 10;
    $wholesale->price_display_method = 1;
    $wholesale->show_prices = 1;
    mustSave($wholesale, 'wholesale group');
    foreach (Db::getInstance()->executeS((new DbQuery())->select('id_category')->from('category')->where('id_category > 1')) as $row) {
        Db::getInstance()->execute('INSERT IGNORE INTO ' . _DB_PREFIX_ . 'category_group (id_category, id_group) VALUES (' . (int) $row['id_category'] . ', ' . (int) $wholesale->id . ')');   // raw: Category::addGroups() only takes one category at a time and rewrites its whole group list
    }
    $sharedHash = $hashPassword('Shared-Pass-2026!');
    for ($i = 1; $i <= $nCustomers; $i++) {
        $c = new Customer();
        $c->firstname = word("gn$i", GIVEN);
        $c->lastname = word("fn$i", FAMILY);
        $c->email = sprintf('customer%03d@apptest.test', $i);
        $c->passwd = $i <= 10 ? $hashPassword(sprintf(AT_PASSWORD_KNOWN, $i)) : $sharedHash;
        $c->id_gender = 1 + h("g$i", 2);
        $c->birthday = sprintf('%d-%02d-%02d', 1960 + h("by$i", 40), 1 + h("bm$i", 12), 1 + h("bd$i", 28));
        $c->newsletter = h("nl$i", 3) === 0 ? 1 : 0;
        $c->optin = 0;
        $c->active = 1;
        $c->id_default_group = 3;
        mustSave($c, "customer $i");
        $groups = [3];
        if ($i % 10 === 0) {
            $groups[] = (int) $wholesale->id;
            $c->id_default_group = (int) $wholesale->id;
            $c->update();
        }
        $c->updateGroup($groups);
        $customerIds[$i] = (int) $c->id;

        for ($a = 0; $a < 1 + ($i % 3 === 0 ? 1 : 0); $a++) {
            $state = $states[h("st$i-$a", count($states))];
            $addr = new Address();
            $addr->id_customer = (int) $c->id;
            $addr->id_country = 21;
            $addr->id_state = (int) $state['id_state'];
            $addr->alias = $a ? 'Office' : 'Home';
            $addr->firstname = $c->firstname;
            $addr->lastname = $c->lastname;
            $addr->address1 = (100 + h("no$i-$a", 900)) . ' ' . word("s$i-$a", STREETS) . ' Street';
            $addr->city = word("ci$i-$a", CITIES);
            $addr->postcode = sprintf('%05d', 10000 + h("zip$i-$a", 80000));
            $addr->phone = sprintf('555-%04d', $i * 10 + $a);
            mustSave($addr, "address for customer $i");
        }
    }
    say("customers: $nCustomers with addresses, 10 with known passwords, " . floor($nCustomers / 10) . ' in Wholesale');
}

/* --- pricing rules --------------------------------------------------------------- */

if (in_array('pricing', $phases, true)) {
    $sp = 0;
    for ($i = 25; $i <= $nProducts; $i += 25) {
        $id = (int) Db::getInstance()->getValue((new DbQuery())->select('id_product')->from('product')->where("reference = '" . pSQL(sprintf('AT-%04d', $i)) . "'"));
        if (!$id) {
            continue;
        }
        $s = new SpecificPrice();
        $s->id_product = $id;
        $s->id_product_attribute = 0;
        $s->id_shop = 0;
        $s->id_shop_group = 0;
        $s->id_currency = 0;
        $s->id_country = 0;
        $s->id_group = 0;
        $s->id_customer = 0;
        $s->id_cart = 0;
        $s->price = -1;
        $s->from_quantity = 1;
        $s->reduction = [0.10, 0.15, 0.20, 0.25][h("sr$i", 4)];
        $s->reduction_type = 'percentage';
        $s->reduction_tax = 1;
        $s->from = '0000-00-00 00:00:00';
        $s->to = '0000-00-00 00:00:00';
        mustSave($s, "specific price for $id");
        ++$sp;
        if ($i % 100 === 0) {
            $q = clone $s;
            $q->id = null;
            $q->from_quantity = 5;
            $q->reduction = 0.30;
            mustSave($q, "quantity price for $id");
        }
    }
    $rules = [
        ['APPTEST10', 'Ten percent off', ['reduction_percent' => 10]],
        ['APPTEST5OFF', 'Five off', ['reduction_amount' => 5, 'reduction_tax' => 1, 'reduction_currency' => (int) Configuration::get('PS_CURRENCY_DEFAULT')]],
        ['APPTESTSHIP', 'Free shipping', ['free_shipping' => 1]],
        ['APPTESTBIG', 'Twenty off large baskets', ['reduction_percent' => 20, 'minimum_amount' => 300, 'minimum_amount_tax' => 1, 'minimum_amount_currency' => (int) Configuration::get('PS_CURRENCY_DEFAULT')]],
    ];
    foreach ($rules as list($code, $label, $fields)) {
        $r = new CartRule();
        $r->code = $code;
        $r->name = ml($label);
        $r->description = "$label (application test)";
        $r->quantity = 100000;
        $r->quantity_per_user = 100000;
        $r->date_from = '2020-01-01 00:00:00';
        $r->date_to = '2099-12-31 23:59:59';
        $r->active = 1;
        $r->highlight = 0;
        $r->partial_use = 1;
        $r->priority = 1;
        foreach ($fields as $k => $v) {
            $r->$k = $v;
        }
        mustSave($r, "cart rule $code");
    }
    say("pricing: $sp catalog price rules, " . count($rules) . ' cart rules');
}

/* --- orders ---------------------------------------------------------------------- */

if (in_array('orders', $phases, true)) {
    $context = Context::getContext();
    $modules = $legacy
        ? ['bankwire' => 'PS_OS_BANKWIRE', 'cheque' => 'PS_OS_CHEQUE', 'cashondelivery' => 'PS_OS_COD_VALIDATION']
        : ['ps_wirepayment' => 'PS_OS_BANKWIRE', 'ps_checkpayment' => 'PS_OS_CHEQUE', 'ps_cashondelivery' => 'PS_OS_COD_VALIDATION'];
    // 1.6.1 and 1.7.8 ship no cash on delivery module (8.x and 9.x do).
    foreach (array_keys($modules) as $moduleName) {
        if (!Module::isInstalled($moduleName)) {
            unset($modules[$moduleName]);
        }
    }
    // Where each order ends up, by position in the run; the payment module only decides the first state.
    $finalStates = array_merge(
        array_fill(0, 22, 'PS_OS_PAYMENT'),
        array_fill(0, 14, 'PS_OS_PREPARATION'),
        array_fill(0, 16, 'PS_OS_SHIPPING'),
        array_fill(0, 20, 'PS_OS_DELIVERED'),
        array_fill(0, 8, 'PS_OS_CANCELED'),
        array_fill(0, 5, 'PS_OS_REFUND'),
        array_fill(0, 15, null)   // stay in the module's own awaiting state
    );
    $inStock = Db::getInstance()->executeS(
        (new DbQuery())->select('p.id_product')->from('product', 'p')
            ->innerJoin('stock_available', 's', 's.id_product = p.id_product AND s.id_product_attribute = 0')
            ->where("p.reference LIKE 'AT-%' AND s.quantity > 30")->orderBy('p.id_product')
    );
    $inStock = array_map('intval', array_column($inStock, 'id_product'));
    $codes = ['APPTEST10', 'APPTESTSHIP', 'APPTEST5OFF'];
    $placed = 0;
    for ($k = 1; $k <= $nOrders; $k++) {
        $customer = new Customer((int) Db::getInstance()->getValue(
            (new DbQuery())->select('id_customer')->from('customer')->where("email = '" . pSQL(sprintf('customer%03d@apptest.test', 1 + (($k * 7) % $nCustomers))) . "'")
        ));
        $addresses = $customer->getAddresses($idLang);
        if (!$addresses) {
            continue;
        }
        $idAddress = (int) $addresses[0]['id_address'];

        $cart = new Cart();
        $cart->id_customer = (int) $customer->id;
        $cart->id_lang = $idLang;
        $cart->id_currency = (int) Configuration::get('PS_CURRENCY_DEFAULT');
        $cart->id_address_delivery = $idAddress;
        $cart->id_address_invoice = $idAddress;
        $cart->id_carrier = 2;
        $cart->secure_key = $customer->secure_key;
        $cart->id_shop = 1;
        $cart->id_shop_group = 1;
        mustSave($cart, "cart for order $k");
        $context->cart = $cart;
        $context->customer = $customer;
        $context->cookie->id_customer = (int) $customer->id;
        $context->cookie->id_cart = (int) $cart->id;

        $lines = 1 + h("lines$k", 4);
        for ($l = 0; $l < $lines; $l++) {
            $idProduct = $inStock[h("op$k-$l", count($inStock))];
            $idAttr = 0;
            $combo = Db::getInstance()->getValue((new DbQuery())->select('MIN(id_product_attribute)')->from('product_attribute')->where('id_product = ' . $idProduct));
            if ($combo) {
                continue;   // stock of combination products is per attribute; keep the order lines simple
            }
            $cart->updateQty(1 + h("oq$k-$l", 3), $idProduct, $idAttr);
        }
        if (!$cart->getProducts()) {
            $cart->updateQty(1, $inStock[$k % count($inStock)], 0);
        }
        $cart->setDeliveryOption([$idAddress => '2,']);
        $cart->update();
        if ($k % 6 === 0) {
            $cart->addCartRule((int) CartRule::getIdByCode($codes[$k % count($codes)]));
        }
        $context->cart = $cart;

        $moduleName = array_keys($modules)[$k % count($modules)];
        $module = Module::getInstanceByName($moduleName);
        $module->validateOrder(
            (int) $cart->id,
            (int) Configuration::get($modules[$moduleName]),
            $cart->getOrderTotal(true, Cart::BOTH),
            $module->displayName,
            "apptest order $k",
            [],
            null,
            false,
            $customer->secure_key
        );
        $order = new Order((int) $module->currentOrder);
        $final = $finalStates[($k - 1) % count($finalStates)];
        if ($final !== null) {
            $history = new OrderHistory();
            $history->id_order = (int) $order->id;
            $history->id_employee = 1;
            $history->changeIdOrderState((int) Configuration::get($final), $order, true);
            $history->add();
        }
        ++$placed;
        if ($k % 25 === 0) {
            say("orders: $k/$nOrders");
        }
    }
    say("orders: $placed placed");
}

/* --- indexes ------------------------------------------------------------------------ */

if (in_array('indexes', $phases, true)) {
    $t = microtime(true);
    Search::indexation(true);
    say(sprintf('search index rebuilt (%.1fs), %d words', microtime(true) - $t, Db::getInstance()->getValue('SELECT COUNT(*) FROM ' . _DB_PREFIX_ . 'search_word')));

    if ($legacy) {
        // 1.6's faceted navigation is blocklayered; its price indexer re-enters itself over HTTP unless driven as the ajax call
        $layered = Module::getInstanceByName('blocklayered');
        if ($layered && $layered->active) {
            $t = microtime(true);
            $layered->indexUrl();
            $layered->indexAttribute();
            $cursor = 0;
            while (($step = json_decode($layered->fullPricesIndexProcess($cursor, true), true)) && isset($step['cursor'])) {
                $cursor = (int) $step['cursor'];
            }
            say(sprintf('blocklayered indexes rebuilt (%.1fs)', microtime(true) - $t));
        }
    }
    $faceted = Module::getInstanceByName('ps_facetedsearch');
    if ($faceted && $faceted->active) {
        $t = microtime(true);
        $faceted->indexAttributes();
        $faceted->fullPricesIndexProcess(0, false, false);   // loops to the end by itself when not called over ajax
        say(sprintf('faceted search indexes rebuilt (%.1fs)', microtime(true) - $t));
    }
    if ($legacy) {
        Tools::clearSmartyCache();   // 1.6: clearAllCache() is Smarty's own, on the smarty object
        Tools::clearCompile();
    } else {
        Tools::clearAllCache();
        Tools::clearSmartyCache();
    }
}
