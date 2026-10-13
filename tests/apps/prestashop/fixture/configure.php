<?php
/*
 * Post-install shop settings, through Configuration/Module/WebserviceKey so
 * every side effect the admin would trigger (cache invalidation, hooks) runs.
 * Fixed values on purpose: the suites log in and call the API with them.
 */
require __DIR__ . '/bootstrap.php';

require __DIR__ . '/lib.php';

Configuration::updateGlobalValue('PS_REWRITING_SETTINGS', 1);
Configuration::updateGlobalValue('PS_CANONICAL_REDIRECT', 1);
Configuration::updateGlobalValue('PS_SSL_ENABLED', 0);
Configuration::updateGlobalValue('PS_SSL_ENABLED_EVERYWHERE', 0);
Configuration::updateGlobalValue('PS_SHOP_ENABLE', 1);
Configuration::updateGlobalValue('PS_MAIL_METHOD', 3); // never send: there is no MTA, and validateOrder mails on every order
Configuration::updateGlobalValue('PS_SMARTY_CACHE', 1);
Configuration::updateGlobalValue('PS_SMARTY_FORCE_COMPILE', 0);
Configuration::updateGlobalValue('PS_CSS_THEME_CACHE', 1);
Configuration::updateGlobalValue('PS_JS_THEME_CACHE', 1);
Configuration::updateGlobalValue('PS_HTACCESS_CACHE_CONTROL', 1);
Configuration::updateGlobalValue('PS_GUEST_CHECKOUT_ENABLED', 1);
Configuration::updateGlobalValue('PS_DISPLAY_SUPPLIERS', 1);
Configuration::updateGlobalValue('PS_PASSWD_TIME_FRONT', 0);
Configuration::updateGlobalValue('PS_PASSWD_TIME_BACK', 0);
Configuration::updateGlobalValue('PS_REGISTRATION_PROCESS_TYPE', 1);
Configuration::updateGlobalValue('PS_WEBSERVICE', 1);
Configuration::updateGlobalValue('PS_WEBSERVICE_CGI_HOST', 1);

if (!WebserviceKey::keyExists(WS_KEY)) {
    $key = new WebserviceKey();
    $key->key = WS_KEY;
    $key->description = 'apptest';
    $key->active = 1;
    $key->add();
    $permissions = [];
    foreach (array_keys(WebserviceRequest::getResources()) as $resource) {
        $permissions[$resource] = ['GET' => 1, 'POST' => 1, 'PUT' => 1, 'DELETE' => 1, 'HEAD' => 1];
    }
    WebserviceKey::setPermissionForAccount($key->id, $permissions);
}

// 1.6's installer writes _RIJNDAEL_KEY_/_RIJNDAEL_IV_ only when mcrypt is loaded (install/models/install.php), but
// 1.6.1.24's Cookie always builds a Rijndael from them and the class runs on openssl_encrypt when mcrypt is missing.
// Left out, the cookies are keyed by the constants' own names and a 9-byte IV. Written the way AdminPerformance's
// "ciphering" form writes them, so the cipher under test is a real AES-128-CBC with a 16-byte IV.
if (version_compare(_PS_VERSION_, '1.7', '<') && !defined('_RIJNDAEL_KEY_')) {
    $file = _PS_ROOT_DIR_ . '/config/settings.inc.php';
    $settings = file_get_contents($file);
    $settings = preg_replace("/define\('_COOKIE_KEY_', '[^']+'\);/", "\$0\ndefine('_RIJNDAEL_KEY_', '" . Tools::passwdGen(32) . "');", $settings, 1, $n1);
    $settings = preg_replace("/define\('_COOKIE_IV_', '[^']+'\);/", "\$0\ndefine('_RIJNDAEL_IV_', '" . base64_encode(random_bytes(16)) . "');", $settings, 1, $n2);
    if ($n1 !== 1 || $n2 !== 1 || !file_put_contents($file, $settings)) {
        fwrite(STDERR, "FATAL: could not add the Rijndael constants to settings.inc.php\n");
        exit(1);
    }
    echo "cookie cipher: _RIJNDAEL_KEY_/_IV_ added to settings.inc.php\n";
}

// 1.6 ships no robots.txt; the BO's SEO page writes it. The admin controller's constructor wants a logged-in
// employee and a token, so build it without one and give it the two properties the constructor would set.
if (version_compare(_PS_VERSION_, '1.7', '<') && !file_exists(_PS_ROOT_DIR_ . '/robots.txt')) {
    $meta = (new ReflectionClass('AdminMetaController'))->newInstanceWithoutConstructor();
    $meta->rb_file = _PS_ROOT_DIR_ . '/robots.txt';
    $meta->rb_data = $meta->getRobotsContent();
    $meta->generateRobotsFile();
    if ($meta->errors || !file_exists(_PS_ROOT_DIR_ . '/robots.txt')) {
        fwrite(STDERR, "FATAL: could not write robots.txt\n");
        exit(1);
    }
}

Shop::setContext(Shop::CONTEXT_ALL);
echo "configured: ws key " . WS_KEY . ", " . count(WebserviceRequest::getResources()) . " resources\n";
