<?php
// Golden values: computed on the stock PHP that built the fixture, recomputed
// on the PHP under test and compared. Everything hashed here is a function of
// the database and of WordPress's own string/regex/block code, never of image
// bytes, the clock, ICU or a suite run: suites add drafts, comments, media,
// users and orders, so only rows the fixture wrote are covered.
//
//   wp eval-file golden.php write      merge into manifest.json (fixture build)
//   wp eval-file golden.php verify     print "ok:"/"FAIL:" lines (suite/cli.sh)
require __DIR__ . '/lib.php';

// Sorted-key JSON of already-decoded data, so PHP and Python agree byte for byte.
function apptest_canon($v)
{
    if (is_array($v)) {
        if ($v === [] || array_keys($v) === range(0, count($v) - 1)) {
            return array_map('apptest_canon', $v);
        }
        ksort($v, SORT_STRING);
        return array_map('apptest_canon', $v);
    }
    return $v;
}

function apptest_canon_json($data): string
{
    $decoded = json_decode(wp_json_encode($data), true);
    return json_encode(apptest_canon($decoded), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_LINE_TERMINATORS | JSON_PRESERVE_ZERO_FRACTION);
}

function apptest_compute_golden(array $core, array $woo): array
{
    wp_set_current_user(0);
    $g = [];

    // REST responses, as an anonymous visitor sees them.
    $rest = function (string $route, array $params = []) {
        $req = new WP_REST_Request('GET', $route);
        $req->set_query_params($params);
        $res = rest_do_request($req);
        return rest_get_server()->response_to_data($res, false);
    };
    $withMore = $core['posts']['with_more']['id'];
    $post = $rest('/wp/v2/posts/' . $withMore);
    unset($post['modified'], $post['modified_gmt']);
    // Yoast SEO's head is its own output, checked on the page; the golden value is core's REST serialization.
    unset($post['yoast_head'], $post['yoast_head_json']);
    $g['rest_post'] = ['id' => $withMore, 'sha256' => hash('sha256', apptest_canon_json($post))];

    $render = $rest('/wp/v2/posts/' . $core['posts']['ids'][14]);
    $g['rest_render'] = ['id' => $core['posts']['ids'][14], 'sha256' => hash('sha256', $render['content']['rendered'] . "\n--\n" . $render['excerpt']['rendered'] . "\n--\n" . $render['title']['rendered'])];

    // Term counts: an aggregate the database computed, listed in id order.
    $terms = get_terms(['taxonomy' => 'category', 'hide_empty' => false, 'orderby' => 'id', 'order' => 'ASC']);
    $rows = array_map(function ($t) { return [$t->term_id, $t->slug, $t->name, (int) $t->count, (int) $t->parent]; }, $terms);
    $g['categories'] = ['count' => count($rows), 'sha256' => hash('sha256', json_encode($rows, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES))];

    $g['archives'] = hash('sha256', wp_get_archives(['type' => 'monthly', 'echo' => false, 'format' => 'custom', 'before' => '', 'after' => '|', 'show_post_count' => true]));

    // Every published post: catches any byte the database or mysqlnd would mangle.
    $rows = [];
    foreach (get_posts(['post_type' => 'post', 'post_status' => 'publish', 'numberposts' => -1, 'orderby' => 'ID', 'order' => 'ASC', 'suppress_filters' => true]) as $p) {
        $rows[] = [$p->ID, $p->post_name, $p->post_title, $p->post_date, $p->post_author, md5($p->post_content), md5($p->post_excerpt)];
    }
    $g['posts'] = ['count' => count($rows), 'sha256' => hash('sha256', json_encode($rows, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES))];

    $maxId = max($core['comments']['ids']);
    $rows = [];
    foreach (get_comments(['number' => 0, 'status' => 'all', 'orderby' => 'comment_ID', 'order' => 'ASC', 'type' => 'comment']) as $c) {
        if ((int) $c->comment_ID > $maxId) {
            continue;
        }
        $rows[] = [(int) $c->comment_ID, (int) $c->comment_post_ID, (int) $c->comment_parent, (int) $c->user_id, $c->comment_author, $c->comment_approved, md5($c->comment_content)];
    }
    $g['comments'] = ['count' => count($rows), 'sha256' => hash('sha256', json_encode($rows, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES))];

    // WordPress's text pipeline (PCRE-heavy) over fixed input.
    $in = "\"Quoted\" text -- dash... 'single' 10x10 (c) (tm) it's the 1990's. :) 8-)\n\nSecond paragraph with wordpress and http://example.test/a?b=1&c=2 mail a@example.test\nline break <b>bold</b> <script>alert(1)</script> <a href=\"javascript:x()\" onclick=\"y()\">bad</a> <img src=x onerror=z()> Ünïcödé тест 测试 مرحبا 🚀";
    $blocks = "<!-- wp:paragraph -->\n<p>Block \"text\" -- here</p>\n<!-- /wp:paragraph -->\n<!-- wp:heading {\"level\":3} -->\n<h3 class=\"wp-block-heading\">Head</h3>\n<!-- /wp:heading -->\n<!-- wp:list -->\n<ul class=\"wp-block-list\"><!-- wp:list-item -->\n<li>a</li>\n<!-- /wp:list-item --></ul>\n<!-- /wp:list -->\n<!-- wp:categories {\"showPostCounts\":true} /-->";
    $parts = [
        wptexturize($in), wpautop($in), wp_kses_post($in), wp_kses($in, ['b' => [], 'a' => ['href' => true]], ['http', 'https']),
        make_clickable($in), convert_smilies($in), capital_P_dangit($in), wp_trim_words($in, 8), wp_strip_all_tags($in),
        sanitize_title('Ünïcödé тест 测试 — ok?'), sanitize_file_name('Тест файл (1).JPG'), remove_accents('Ünïcödé Ångström çà'),
        esc_html($in), esc_attr($in), esc_url('http://example.test/тест?a=1&b=2'), sanitize_text_field($in), wp_html_excerpt($in, 40, '…'),
        mb_strimwidth($in, 0, 30, '…', 'UTF-8'), (function_exists('do_blocks') ? do_blocks($blocks) : ''), do_shortcode('[caption id="a" align="alignnone" width="10"]x[/caption]'),
        wp_json_encode(['ü' => '🚀', 'a' => [1, 2.5, true, null]]), size_format(123456789, 2), number_format_i18n(1234567.891, 2),
        date_i18n('D, d M Y H:i', 1700000000, true), human_time_diff(1700000000, 1700003600), wp_unslash(wp_slash("a'b\"c\\d")),
    ];
    $g['render'] = hash('sha256', implode("\n--\n", $parts));

    $g['serialized'] = hash('sha256', serialize(get_option('apptest_serialized')));

    // WooCommerce: the catalog and the seeded orders (suites add orders of their own).
    $rows = [];
    foreach (wc_get_products(['limit' => -1, 'orderby' => 'ID', 'order' => 'ASC', 'status' => 'publish', 'return' => 'objects']) as $pr) {
        $rows[] = [$pr->get_id(), $pr->get_sku(), $pr->get_type(), $pr->get_regular_price(), $pr->get_name(), count($pr->get_children()), $pr->get_category_ids()];
    }
    $g['woo_products'] = ['count' => count($rows), 'sha256' => hash('sha256', json_encode($rows, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES))];
    $rows = [];
    foreach ($woo['orders'] as $id) {
        $o = wc_get_order($id);
        $rows[] = [$id, $o->get_status(), $o->get_total(), count($o->get_items()), $o->get_customer_id(), $o->get_date_created()->date('Y-m-d H:i:s'), $o->get_payment_method(), $o->get_billing_email(), $o->get_total_refunded()];
    }
    $g['woo_orders'] = ['count' => count($rows), 'sha256' => hash('sha256', json_encode($rows, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES))];
    return $g;
}

$mode = $args[0] ?? 'verify';
$core = apptest_read_json(apptest_part_path('core'));
$woo = apptest_read_json(apptest_part_path('woo'));

if ($mode === 'write') {
    $counts = wp_count_posts('post');
    $comments = wp_count_comments();
    // Every plugin active now (the shop and the rest of the set; Redis Object Cache goes on after this),
    // as WordPress itself reports it: the suites check these against what is installed.
    require_once ABSPATH . 'wp-admin/includes/plugin.php';
    $plugins = [];
    foreach (get_option('active_plugins') as $file) {
        $plugins[dirname($file)] = get_plugin_data(WP_PLUGIN_DIR . '/' . $file, false, false)['Version'];
    }
    ksort($plugins);
    $manifest = [
        'app_version' => get_bloginfo('version'),
        'woocommerce' => $woo['version'],
        'plugins' => $plugins,
        'plugin_pages' => is_file(apptest_part_path('plugins')) ? apptest_read_json(apptest_part_path('plugins')) : [],
        'wp_cli' => getenv('APPTEST_WPCLI_VERSION') ?: '',
        'redis_cache' => getenv('APPTEST_REDIS_CACHE_VERSION') ?: '',
        'site' => ['url' => home_url(), 'title' => get_option('blogname')],
        'theme' => ['slug' => get_stylesheet(), 'name' => wp_get_theme()->get('Name')],
        'counts' => [
            'users' => (int) count_users()['total_users'],
            'posts_published' => (int) $counts->publish,
            'posts_draft' => (int) $counts->draft,
            'posts_pending' => (int) $counts->pending,
            'posts_private' => (int) $counts->private,
            'posts_future' => (int) $counts->future,
            'pages' => (int) wp_count_posts('page')->publish,
            'comments_approved' => (int) $comments->approved,
            'comments_pending' => (int) $comments->moderated,
            'comments_spam' => (int) $comments->spam,
            'categories' => count(get_terms(['taxonomy' => 'category', 'hide_empty' => false, 'fields' => 'ids'])),
            'tags' => count(get_terms(['taxonomy' => 'post_tag', 'hide_empty' => false, 'fields' => 'ids'])),
            'attachments' => (int) wp_count_posts('attachment')->inherit,
            'products' => count($woo['products']),
            'variable_products' => count($woo['variable_products']),
            'variations' => $woo['variation_count'],
            'orders' => count($woo['orders']),
            'customers' => count($woo['customers']),
        ],
        'users' => array_merge($core['users'], array_map(function ($c) { return ['login' => $c['login'], 'password' => $c['password'], 'role' => 'customer', 'id' => $c['id'], 'email' => $c['email']]; }, $woo['customers']), [['login' => $woo['shop_manager']['login'], 'password' => $woo['shop_manager']['password'], 'role' => 'shop_manager', 'id' => $woo['shop_manager']['id']]]),
        'legacy_hash_user' => $core['legacy_hash_user'],
        'posts' => $core['posts'],
        'pages' => $core['pages'],
        'menu' => $core['menu'],
        'attachments' => $core['attachments'],
        'woo' => $woo,
        'golden' => apptest_compute_golden($core, $woo),
    ];

    // Archive, search and author facts, computed the way the front end does.
    $catCounts = [];
    foreach (get_terms(['taxonomy' => 'category', 'hide_empty' => false]) as $t) {
        $catCounts[$t->term_id] = ['id' => $t->term_id, 'slug' => $t->slug, 'name' => $t->name, 'count' => (int) $t->count, 'parent' => (int) $t->parent, 'path' => apptest_path(get_term_link($t))];
    }
    uasort($catCounts, function ($a, $b) { return $b['count'] <=> $a['count'] ?: $a['id'] <=> $b['id']; });
    $manifest['category'] = reset($catCounts);
    $manifest['category_small'] = end($catCounts);
    $tagBest = null;
    foreach (get_terms(['taxonomy' => 'post_tag', 'hide_empty' => true]) as $t) {
        if ($tagBest === null || $t->count > $tagBest->count || ($t->count === $tagBest->count && $t->term_id < $tagBest->term_id)) {
            $tagBest = $t;
        }
    }
    $manifest['tag'] = ['id' => $tagBest->term_id, 'slug' => $tagBest->slug, 'name' => $tagBest->name, 'count' => (int) $tagBest->count, 'path' => apptest_path(get_term_link($tagBest))];

    $author = get_user_by('login', 'author_01');
    $manifest['author'] = ['id' => $author->ID, 'nicename' => $author->user_nicename, 'display_name' => $author->display_name, 'path' => apptest_path(get_author_posts_url($author->ID)), 'posts' => (int) count_user_posts($author->ID, 'post', true)];

    $q = new WP_Query(['year' => 2024, 'monthnum' => 3, 'post_status' => 'publish', 'posts_per_page' => 10]);
    $manifest['month'] = ['year' => 2024, 'month' => 3, 'path' => '/2024/03/', 'count' => (int) $q->found_posts, 'pages' => (int) $q->max_num_pages];
    $q = new WP_Query(['year' => 2023, 'post_status' => 'publish', 'posts_per_page' => 10]);
    $manifest['year'] = ['year' => 2023, 'path' => '/2023/', 'count' => (int) $q->found_posts];

    $searches = [];
    foreach (['latin' => 'granite', 'cyrillic' => 'лиса', 'cjk' => '数据库', 'arabic' => 'مرحبا', 'hebrew' => 'שלום', 'emoji' => '🚀', 'none' => 'zzzqxnothingmatches'] as $k => $term) {
        // The site search covers every searchable type (posts, pages, products);
        // the REST posts endpoint only posts.
        $q = new WP_Query(['s' => $term, 'post_status' => 'publish', 'posts_per_page' => 10]);
        $req = new WP_REST_Request('GET', '/wp/v2/posts');
        $req->set_query_params(['search' => $term, 'per_page' => 1]);
        $searches[$k] = ['term' => $term, 'total' => (int) $q->found_posts, 'pages' => (int) $q->max_num_pages, 'rest_total' => (int) rest_do_request($req)->get_headers()['X-WP-Total']];
    }
    $manifest['search'] = $searches;
    $manifest['comment_target'] = $core['posts']['plain'];

    apptest_write_json(apptest_manifest_path(), $manifest);
    fwrite(STDERR, "manifest written\n");
    return;
}

$manifest = apptest_read_json(apptest_manifest_path());
$now = apptest_compute_golden($core, $woo);
foreach ($manifest['golden'] as $key => $want) {
    $got = $now[$key];
    echo ($got === $want ? 'ok' : 'FAIL') . ": golden {$key}" . ($got === $want ? '' : ' -- expected ' . json_encode($want) . ', got ' . json_encode($got)) . "\n";
}
