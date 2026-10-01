<?php
/*
 * Plugin Name: Apptest support
 * Description: Test-fixture glue: keeps the offline site quiet and observable.
 */

// Registered so REST exposes the seeded custom fields.
add_action('init', function () {
    register_post_meta('post', 'apptest_rating', ['type' => 'integer', 'single' => true, 'show_in_rest' => true]);
    register_post_meta('post', 'apptest_source', ['type' => 'string', 'single' => true, 'show_in_rest' => true]);
});

// The suites reach the site over plain http; application passwords are
// otherwise refused there.
add_filter('wp_is_application_passwords_available', '__return_true');

// Suites post several comments from one address within seconds.
add_filter('comment_flood_filter', '__return_false');

// No MTA in the image. Mail is appended to a file the suites can fetch
// (uploads are served statically), which is how the password-reset flow is
// followed to its link without a mail server.
add_filter('pre_wp_mail', function ($short, $atts) {
    $to = is_array($atts['to']) ? implode(',', $atts['to']) : $atts['to'];
    $line = json_encode(['to' => $to, 'subject' => $atts['subject'], 'message' => $atts['message']], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    @file_put_contents(WP_CONTENT_DIR . '/uploads/apptest-mail.log', $line . "\n", FILE_APPEND | LOCK_EX);
    return true;
}, 10, 2);

// Woo's remote catalogue, inbox and tracking calls would only fail against WP_HTTP_BLOCK_EXTERNAL.
add_filter('woocommerce_allow_marketplace_suggestions', '__return_false');
add_filter('woocommerce_helper_suppress_admin_notices', '__return_true');

// What the Redis object cache is doing, as the suites see it from outside:
// GET /wp-json/apptest/v1/cache[?post=ID]. Every request is a fresh PHP
// process, so anything found in the cache here was put there by an earlier one.
add_action('rest_api_init', function () {
    register_rest_route('apptest/v1', '/cache', [
        'methods' => 'GET',
        'permission_callback' => '__return_true',
        'callback' => function (WP_REST_Request $req) {
            global $wp_object_cache;
            $out = ['ext' => wp_using_ext_object_cache(), 'connected' => false];
            if (!method_exists($wp_object_cache, 'redis_instance')) {
                return $out;
            }
            $redis = $wp_object_cache->redis_instance();
            $info = $wp_object_cache->info();
            $out['connected'] = $wp_object_cache->redis_status();
            $out['client'] = $info->meta['Client'];
            $out['redis_version'] = $wp_object_cache->redis_version();
            $out['igbinary'] = defined('WP_REDIS_IGBINARY') && WP_REDIS_IGBINARY && function_exists('igbinary_serialize');
            $out['hits'] = (int) $info->hits;
            $out['misses'] = (int) $info->misses;
            $stats = $redis->info();
            $out['redis'] = ['keys' => (int) $redis->dbSize(), 'keyspace_hits' => (int) $stats['keyspace_hits'], 'keyspace_misses' => (int) $stats['keyspace_misses']];
            if ($req->get_param('post')) {
                $id = (int) $req->get_param('post');
                $before = $wp_object_cache->info();
                $cached = wp_cache_get($id, 'posts');
                $after = $wp_object_cache->info();
                $raw = $redis->get($wp_object_cache->build_key($id, 'posts'));
                $out['post'] = [
                    'cached' => $cached !== false,
                    'title' => $cached !== false ? $cached->post_title : null,
                    'hit_delta' => $after->hits - $before->hits,
                    'miss_delta' => $after->misses - $before->misses,
                    // igbinary's header is the four bytes 00 00 00 02.
                    'igbinary' => is_string($raw) && substr($raw, 0, 4) === "\x00\x00\x00\x02",
                    'bytes' => is_string($raw) ? strlen($raw) : 0,
                ];
            }
            return $out;
        },
    ]);
});
