<?php
// PGO training corpus. Not a site: no secrets here are secret, and nothing
// here is reachable from outside the build that trains against it.

$corpus_host = getenv('CORPUS_WP_HOST');
if (!$corpus_host && isset($_SERVER['HTTP_HOST'])) {
    $corpus_host = $_SERVER['HTTP_HOST'];
}
if (!preg_match('/^(127\.0\.0\.1|localhost)(:[0-9]{1,5})?$/', (string) $corpus_host)) {
    $corpus_host = '127.0.0.1:18103';
}
define('WP_HOME', 'http://'.$corpus_host);
define('WP_SITEURL', 'http://'.$corpus_host);

define('DB_DIR', __DIR__.'/wp-content/database/');
define('DB_FILE', '.ht.sqlite');
define('DB_NAME', 'corpus');
define('DB_USER', 'corpus');
define('DB_PASSWORD', 'corpus');
define('DB_HOST', 'localhost');
define('DB_CHARSET', 'utf8mb4');
define('DB_COLLATE', '');

define('AUTH_KEY',         'pgo-corpus-auth-key');
define('SECURE_AUTH_KEY',  'pgo-corpus-secure-auth-key');
define('LOGGED_IN_KEY',    'pgo-corpus-logged-in-key');
define('NONCE_KEY',        'pgo-corpus-nonce-key');
define('AUTH_SALT',        'pgo-corpus-auth-salt');
define('SECURE_AUTH_SALT', 'pgo-corpus-secure-auth-salt');
define('LOGGED_IN_SALT',   'pgo-corpus-logged-in-salt');
define('NONCE_SALT',       'pgo-corpus-nonce-salt');

$table_prefix = 'wp_';

define('WP_DEBUG', false);
define('WP_ENVIRONMENT_TYPE', 'production');
define('AUTOMATIC_UPDATER_DISABLED', true);
define('WP_AUTO_UPDATE_CORE', false);
define('DISALLOW_FILE_MODS', true);
define('WP_CRON_LOCK_TIMEOUT', 60);
define('DISABLE_WP_CRON', true);

if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__.'/');
}

require_once ABSPATH.'wp-settings.php';
