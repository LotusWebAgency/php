<?php
define('WP_INSTALLING', true);

$root = getenv('WP_ROOT');
if (!$root) {
    fwrite(STDERR, "FATAL: WP_ROOT not set\n");
    exit(1);
}

require $root.'/wp-load.php';
require ABSPATH.'wp-admin/includes/upgrade.php';

$result = wp_install('PGO training corpus', 'corpus', 'corpus@example.invalid', true, '', 'pgo-corpus-not-a-secret');
if (is_wp_error($result)) {
    fwrite(STDERR, 'FATAL: wp_install failed: '.$result->get_error_message()."\n");
    exit(1);
}

echo 'installed wordpress '.get_bloginfo('version').' as user id '.$result['user_id']."\n";
