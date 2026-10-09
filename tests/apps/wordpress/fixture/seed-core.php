<?php
// Core content, written through WordPress's own APIs (wp eval-file).
require __DIR__ . '/lib.php';
require_once ABSPATH . 'wp-admin/includes/image.php';
require_once ABSPATH . 'wp-admin/includes/file.php';
require_once ABSPATH . 'wp-admin/includes/media.php';
require_once ABSPATH . 'wp-admin/includes/taxonomy.php';

function must($v, string $what)
{
    if (is_wp_error($v)) {
        fwrite(STDERR, "FATAL: {$what}: " . $v->get_error_message() . "\n");
        exit(1);
    }
    return $v;
}

$core = [];

// -- settings ------------------------------------------------------------
update_option('blogname', 'Apptest Journal');
update_option('blogdescription', 'Ünïcödé тест 测试 🚀');
update_option('timezone_string', 'UTC');
update_option('date_format', 'j F Y');
update_option('posts_per_page', 10);
update_option('posts_per_rss', 10);
update_option('default_ping_status', 'closed');
update_option('default_pingback_flag', '');
update_option('comment_moderation', 0);
update_option('comment_previously_approved', 0);
// Its name before 5.5: without it the first comment of every new commenter would be held for moderation.
update_option('comment_whitelist', 0);
update_option('require_name_email', 1);
update_option('page_comments', 1);
update_option('comments_per_page', 20);
update_option('default_comments_page', 'oldest');
update_option('thread_comments', 1);
update_option('thread_comments_depth', 5);
global $wp_rewrite;
$wp_rewrite->set_permalink_structure('/%postname%/');

// The install's own sample post and page (and its comment) would make the
// published counts 1001 and 51.
wp_delete_post(1, true);
wp_delete_post(2, true);

$admin = get_user_by('login', 'admin');
wp_set_current_user($admin->ID);

// -- users ---------------------------------------------------------------
$users = [['login' => 'admin', 'password' => 'Apptest!admin', 'role' => 'administrator', 'id' => $admin->ID, 'email' => $admin->user_email, 'nicename' => $admin->user_nicename]];
$roles = ['editor' => 2, 'author' => 5, 'contributor' => 3, 'subscriber' => 9];
$display = ['Иван Петров', 'Мария Иванова', '田中 太郎', 'Zoë Ångström', 'محمد علي', 'דנה כהן', 'Alice Smith', 'Bob Jones', 'Claire Dubois', 'Dmitri Volkov', 'Emma Wilson', 'Fatima Noor', 'Grace Lee', 'Hiro Sato', 'Ivan Horvat'];
$i = 0;
foreach ($roles as $role => $count) {
    for ($k = 1; $k <= $count; $k++, $i++) {
        $login = sprintf('%s_%02d', $role, $k);
        $name = $display[$i % count($display)];
        $parts = explode(' ', $name, 2);
        $id = must(wp_insert_user([
            'user_login' => $login,
            'user_pass' => 'Apptest!' . $login,
            'user_email' => $login . '@apptest.test',
            'role' => $role,
            'display_name' => $name,
            'first_name' => $parts[0],
            'last_name' => $parts[1] ?? '',
            'description' => Gen::words(12, 'bio', $i, Gen::lang($i)),
            'user_url' => 'https://example.test/' . $login,
            'user_registered' => gmdate('Y-m-d H:i:s', 1660000000 + $i * 86400),
        ]), "user $login");
        update_user_meta($id, 'apptest_favourite', Gen::words(2, 'fav', $i));
        $users[] = ['login' => $login, 'password' => 'Apptest!' . $login, 'role' => $role, 'id' => $id, 'email' => $login . '@apptest.test', 'nicename' => get_userdata($id)->user_nicename];
    }
}
// One account with a legacy phpass hash: sites migrated from old installs
// still carry them, and wp_check_password() has to keep accepting them.
// wp_hash_password() only writes the new format, hence the direct update.
require_once ABSPATH . WPINC . '/class-phpass.php';
$legacy = end($users);
$phpass = new PasswordHash(8, true);
global $wpdb;
$wpdb->update($wpdb->users, ['user_pass' => $phpass->HashPassword($legacy['password'])], ['ID' => $legacy['id']]);
clean_user_cache($legacy['id']);
$core['users'] = $users;
$core['legacy_hash_user'] = $legacy['login'];
$authorIds = array_map(function ($u) { return $u['id']; }, array_filter($users, function ($u) { return in_array($u['role'], ['administrator', 'editor', 'author'], true); }));
$authorIds = array_values($authorIds);
$commenterIds = array_values(array_map(function ($u) { return $u['id']; }, array_filter($users, function ($u) { return $u['role'] !== 'administrator'; })));

// -- taxonomies ----------------------------------------------------------
$parents = ['News', 'Guides', 'Reviews', 'Notes', 'Releases', 'Новости'];
$children = ['Announcements', 'Tutorials', 'Hardware', 'Essays', 'Changelogs', 'Интервью', 'Benchmarks', 'Culture', '技术', 'Security', 'Travel', 'Archive', 'Tips', 'Q&A'];
$catIds = [];
$cats = [];
foreach ($parents as $p) {
    $t = must(wp_insert_term($p, 'category', ['description' => "About {$p}"]), "cat $p");
    $catIds[] = $t['term_id'];
    $cats[] = ['id' => $t['term_id'], 'parent' => 0];
}
foreach ($children as $k => $c) {
    $parent = $catIds[$k % count($parents)];
    $t = must(wp_insert_term($c, 'category', ['parent' => $parent, 'description' => "Posts about {$c}"]), "cat $c");
    $catIds[] = $t['term_id'];
}
$tagIds = [];
$tagCount = Gen::n(200);
for ($k = 1; $k <= $tagCount; $k++) {
    $base = Gen::pick(($k % 10 === 0) ? ['лиса', 'сервер', 'данные', 'мир'] : ['amber', 'basalt', 'copper', 'delta', 'ember', 'fjord', 'granite', 'harbor'], 'tagname', $k);
    $t = must(wp_insert_term(sprintf('%s %03d', $base, $k), 'post_tag'), "tag $k");
    $tagIds[] = $t['term_id'];
}
$uncategorized = (int) get_option('default_category');

// -- media, generated with GD ---------------------------------------------
$tmp = sys_get_temp_dir() . '/apptest-img';
@mkdir($tmp);
$attachments = [];
$imageCount = Gen::n(30);
$dims = [[1600, 900], [1200, 1200], [800, 600], [2000, 1200], [1024, 768]];
for ($k = 1; $k <= $imageCount; $k++) {
    list($w, $h) = $dims[$k % count($dims)];
    $ext = ['jpg', 'png', 'jpg', 'gif', 'jpg', 'png'][$k % 6];
    // WordPress accepts WebP uploads from 5.8 on.
    if ($k % 15 === 7 && function_exists('imagewebp') && version_compare(get_bloginfo('version'), '5.8', '>=')) {
        $ext = 'webp';
    }
    $im = imagecreatetruecolor($w, $h);
    $r0 = Gen::h('r', $k) % 200;
    $g0 = Gen::h('g', $k) % 200;
    $b0 = Gen::h('b', $k) % 200;
    for ($y = 0; $y < $h; $y++) {
        $f = $y / $h;
        imageline($im, 0, $y, $w, $y, imagecolorallocate($im, (int) ($r0 + 55 * $f), (int) ($g0 + 55 * (1 - $f)), (int) ($b0 + 55 * $f)));
    }
    for ($s = 0; $s < 6; $s++) {
        $c = imagecolorallocate($im, 40 + Gen::h('sc', $k * 10 + $s) % 200, 40 + Gen::h('sd', $k * 10 + $s) % 200, 40 + Gen::h('se', $k * 10 + $s) % 200);
        imagefilledellipse($im, Gen::h('ex', $k * 10 + $s) % $w, Gen::h('ey', $k * 10 + $s) % $h, 80 + Gen::h('ew', $k * 10 + $s) % 300, 60 + Gen::h('eh', $k * 10 + $s) % 200, $c);
    }
    imagestring($im, 5, 20, 20, "apptest image $k {$w}x{$h}", imagecolorallocate($im, 255, 255, 255));
    $file = sprintf('%s/apptest-image-%02d.%s', $tmp, $k, $ext);
    switch ($ext) {
        case 'jpg': imagejpeg($im, $file, 88); break;
        case 'png': imagepng($im, $file, 6); break;
        case 'gif': imagegif($im, $file); break;
        case 'webp': imagewebp($im, $file, 85); break;
    }
    imagedestroy($im);
    $id = must(media_handle_sideload(
        ['name' => basename($file), 'tmp_name' => $file],
        0,
        null,
        ['post_title' => 'Image ' . Gen::words(2, 'mt', $k, Gen::lang($k)) . ' #' . $k, 'post_excerpt' => Gen::words(5, 'mc', $k), 'post_content' => Gen::words(9, 'md', $k)]
    ), "image $k");
    update_post_meta($id, '_wp_attachment_image_alt', Gen::words(4, 'alt', $k));
    $attachments[] = $id;
}
$core['attachments'] = $attachments;

// -- pages: 5 roots, 20 children, 25 grandchildren ---------------------------
$pageIds = [];
$pageTotal = Gen::n(50);
for ($k = 0; $k < $pageTotal; $k++) {
    $parent = 0;
    if ($k >= 25) {
        $parent = $pageIds[5 + (($k - 25) % 20)] ?? 0;
    } elseif ($k >= 5) {
        $parent = $pageIds[($k - 5) % 5] ?? 0;
    }
    $pageIds[$k] = must(wp_insert_post([
        'post_type' => 'page',
        'post_status' => 'publish',
        'post_title' => Gen::title($k + 1, 'Page'),
        'post_content' => Blocks::article(2000 + $k, $attachments),
        'post_parent' => $parent,
        'menu_order' => $k,
        'post_author' => $admin->ID,
        'post_date' => Gen::date($k, 500000),
        'post_date_gmt' => Gen::date($k, 500000),
    ], true), "page $k");
}
$core['pages'] = ['ids' => $pageIds];

// -- posts -------------------------------------------------------------------
$postTotal = Gen::n(1000);
$postIds = [];
$postDate = [];
$customCats = array_merge($catIds, [$uncategorized]);
for ($n = 1; $n <= $postTotal; $n++) {
    $date = Gen::date($n);
    $args = [
        'post_type' => 'post',
        'post_status' => 'publish',
        'post_title' => Gen::title($n),
        'post_content' => Blocks::article($n, $attachments),
        'post_author' => $authorIds[Gen::h('au', $n) % count($authorIds)],
        'post_date' => $date,
        'post_date_gmt' => $date,
        'comment_status' => 'open',
        'ping_status' => 'closed',
    ];
    if ($n === 14) {
        $args['post_content'] = file_get_contents(__DIR__ . '/render-fixture.html');
        $args['post_excerpt'] = "Quotes \"here\" -- and 'there'... (c) :) http://example.test/a?b=1&c=2";
    }
    if ($n % 4 === 0 && $n !== 14) {
        $args['post_excerpt'] = Gen::words(15, 'ex', $n, Gen::lang($n));
    }
    $id = must(wp_insert_post($args, true), "post $n");
    $postIds[$n] = $id;
    $postDate[$n] = $date;

    $picked = [];
    $want = Gen::between(1, 3, 'nc', $n);
    for ($k = 0; count($picked) < $want; $k++) {
        $picked[Gen::pick($customCats, 'c' . $k, $n)] = true;
    }
    wp_set_object_terms($id, array_map('intval', array_keys($picked)), 'category');
    $tags = [];
    $want = Gen::between(0, 5, 'nt', $n);
    for ($k = 0; count($tags) < $want; $k++) {
        $tags[Gen::pick($tagIds, 't' . $k, $n)] = true;
    }
    if ($tags) {
        wp_set_object_terms($id, array_map('intval', array_keys($tags)), 'post_tag');
    }

    if ($n % 3 === 0) {
        set_post_thumbnail($id, $attachments[$n % count($attachments)]);
    }
    update_post_meta($id, 'apptest_rating', 1 + $n % 5);
    update_post_meta($id, 'apptest_source', Gen::words(3, 'src', $n, Gen::lang($n)));
    if ($n % 5 === 0) {
        update_post_meta($id, 'apptest_data', ['n' => $n, 'tags' => ['a', 'b', 'ü'], 'nested' => ['x' => true, 'y' => null, 'z' => 'тест']]);
    }
    if ($n % 10 === 0) {
        // JSON in a meta value needs its backslashes and quotes protected from the slash-stripping API.
        update_post_meta($id, 'apptest_json', wp_slash(wp_json_encode(['n' => $n, 'text' => "line\n\"quoted\" \\ back", 'emoji' => '🚀'], JSON_UNESCAPED_UNICODE)));
    }
    apptest_progress('posts', $n, $postTotal);
}
$stickyN = array_slice([100, 200, 300, 400, 500], 0, $postTotal >= 500 ? 5 : 1);
foreach ($stickyN as $n) {
    stick_post($postIds[$n] ?? $postIds[1]);
}
// Non-published posts, so the admin lists and the "publish only" counts have something to tell apart.
$extra = ['draft' => 12, 'pending' => 6, 'private' => 8, 'future' => 4];
$e = 0;
foreach ($extra as $status => $count) {
    for ($k = 1; $k <= $count; $k++, $e++) {
        $args = ['post_type' => 'post', 'post_status' => $status, 'post_title' => ucfirst($status) . ' ' . Gen::words(3, 'x' . $status, $k) . ' #' . $k, 'post_content' => Blocks::article(3000 + $e), 'post_author' => $authorIds[$e % count($authorIds)]];
        if ($status === 'future') {
            $args['post_date'] = gmdate('Y-m-d H:i:s', 2051222400 + $k * 86400);
            $args['post_date_gmt'] = $args['post_date'];
        }
        must(wp_insert_post($args, true), "extra $status $k");
    }
}

// -- comments: threaded, mostly approved --------------------------------------
wp_defer_comment_counting(true);
$commentTotal = Gen::n(5000);
$threads = [];
$commentIds = [];
for ($c = 1; $c <= $commentTotal; $c++) {
    // Product of two uniform picks: heavily skewed towards the oldest posts, like real traffic.
    $n = 1 + intdiv((Gen::h('cp', $c) % $postTotal) * (Gen::h('cq', $c) % $postTotal), $postTotal);
    $post = $postIds[$n];
    $parent = 0;
    if (!empty($threads[$n]) && Gen::h('par', $c) % 3 !== 0) {
        $cand = $threads[$n][Gen::h('pk', $c) % count($threads[$n])];
        if ($cand[1] < 4) {
            $parent = $cand[0];
            $depth = $cand[1] + 1;
        }
    }
    $depth = $parent ? $depth : 0;
    $data = [
        'comment_post_ID' => $post,
        'comment_content' => Gen::words(Gen::between(8, 30, 'cc', $c), 'cw', $c, Gen::lang($c)),
        'comment_parent' => $parent,
        'comment_date' => gmdate('Y-m-d H:i:s', strtotime($postDate[$n] . ' UTC') + 600 + (Gen::h('cd', $c) % (30 * 86400))),
        'comment_author_IP' => '203.0.113.' . (1 + $c % 250),
        'comment_agent' => 'apptest',
        'comment_approved' => $c % 170 === 0 ? 'spam' : ($c % 100 === 0 ? '0' : '1'),
    ];
    $data['comment_date_gmt'] = $data['comment_date'];
    if (Gen::h('reg', $c) % 5 < 3) {
        $uid = $commenterIds[Gen::h('cu', $c) % count($commenterIds)];
        $u = get_userdata($uid);
        $data += ['user_id' => $uid, 'comment_author' => $u->display_name, 'comment_author_email' => $u->user_email, 'comment_author_url' => $u->user_url];
    } else {
        $data += ['user_id' => 0, 'comment_author' => 'Guest ' . Gen::words(1, 'gn', $c, Gen::lang($c) % 3), 'comment_author_email' => "guest{$c}@example.test", 'comment_author_url' => $c % 4 === 0 ? "https://example.test/g/{$c}" : ''];
    }
    $id = wp_insert_comment(wp_slash($data));
    $threads[$n][] = [$id, $depth];
    $commentIds[] = $id;
    if ($c % 7 === 0) {
        add_comment_meta($id, 'apptest_helpful', $c % 13);
    }
    apptest_progress('comments', $c, $commentTotal);
}
wp_defer_comment_counting(false);

// -- menus ---------------------------------------------------------------------
$menu = must(wp_create_nav_menu('Primary Menu'), 'menu');
$items = [];
$items[] = wp_update_nav_menu_item($menu, 0, ['menu-item-title' => 'Home', 'menu-item-url' => home_url('/'), 'menu-item-type' => 'custom', 'menu-item-status' => 'publish']);
foreach (array_slice($pageIds, 0, 5) as $k => $pid) {
    $parentItem = wp_update_nav_menu_item($menu, 0, ['menu-item-title' => get_the_title($pid), 'menu-item-object' => 'page', 'menu-item-object-id' => $pid, 'menu-item-type' => 'post_type', 'menu-item-status' => 'publish', 'menu-item-position' => $k + 2]);
    $items[] = $parentItem;
    if (isset($pageIds[5 + $k])) {
        $items[] = wp_update_nav_menu_item($menu, 0, ['menu-item-title' => get_the_title($pageIds[5 + $k]), 'menu-item-object' => 'page', 'menu-item-object-id' => $pageIds[5 + $k], 'menu-item-type' => 'post_type', 'menu-item-status' => 'publish', 'menu-item-parent-id' => $parentItem]);
    }
}
foreach (array_slice($catIds, 0, 3) as $cid) {
    $items[] = wp_update_nav_menu_item($menu, 0, ['menu-item-title' => get_cat_name($cid), 'menu-item-object' => 'category', 'menu-item-object-id' => $cid, 'menu-item-type' => 'taxonomy', 'menu-item-status' => 'publish']);
}
set_theme_mod('nav_menu_locations', ['primary' => $menu]);
// The block theme draws its header from a wp_navigation post rather than a classic menu.
$links = '';
foreach (array_slice($pageIds, 0, 5) as $pid) {
    $links .= '<!-- wp:navigation-link ' . wp_json_encode(['label' => get_the_title($pid), 'type' => 'page', 'id' => $pid, 'url' => get_permalink($pid), 'kind' => 'post-type'], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) . " /-->\n";
}
must(wp_insert_post(['post_type' => 'wp_navigation', 'post_status' => 'publish', 'post_title' => 'Primary navigation', 'post_name' => 'primary-navigation', 'post_content' => $links], true), 'wp_navigation');
$core['menu'] = ['id' => $menu, 'items' => count($items)];

// -- options and transients ---------------------------------------------------------
update_option('apptest_serialized', [
    'string' => 'Ünïcödé тест 测试 🚀',
    'int' => 42,
    'bool' => true,
    'null' => null,
    'list' => [1, 2, 3, 'four'],
    'object' => (object) ['a' => 1, 'b' => ['c' => 'd']],
    'nested' => ['x' => ['y' => ['z' => 'deep']]],
]);
update_option('apptest_plain', 'plain value');
set_transient('apptest_transient', ['built' => 'by the fixture', 'n' => [1, 2, 3]], 3650 * 86400);

// -- facts for the suites -----------------------------------------------------------------------
$info = function (int $id) {
    $p = get_post($id);
    return ['id' => $id, 'slug' => $p->post_name, 'title' => $p->post_title, 'path' => apptest_path(get_permalink($id)), 'date' => $p->post_date, 'author' => (int) $p->post_author];
};
$posts = ['ids' => $postIds];
foreach (['plain' => 12, 'russian' => 5, 'cjk' => 7, 'arabic' => 11, 'hebrew' => 10, 'emoji' => 13, 'with_more' => 3, 'with_image' => 2] as $k => $n) {
    $posts[$k] = $info($postIds[min($n, $postTotal)]);
}
$best = 0;
$bestCount = -1;
foreach ($postIds as $n => $id) {
    $cnt = (int) get_comments_number($id);
    if ($cnt > $bestCount) {
        $best = $id;
        $bestCount = $cnt;
    }
}
$posts['most_commented'] = $info($best) + ['comments' => $bestCount];
$posts['sticky'] = array_map($info, array_values(array_map('intval', get_option('sticky_posts'))));
$core['posts'] = $posts;
$core['pages'] = ['ids' => $pageIds, 'root' => $info($pageIds[0]), 'child' => $info($pageIds[5] ?? $pageIds[0]), 'grandchild' => $info($pageIds[25] ?? $pageIds[0])];
$core['comments'] = ['ids' => $commentIds];
$core['categories'] = $catIds;
$core['tags'] = $tagIds;
apptest_write_json(apptest_part_path('core'), $core);
fwrite(STDERR, "core seeded\n");
