<?php
/*
 * CLI bootstrap shared by the fixture build and the CLI suite: the same
 * request-shaped globals PrestaShop's front controllers see, then
 * config/config.inc.php, then a back-office employee and the default shop in
 * the context so ObjectModel writes behave as they would from the admin.
 */
$root = getenv('APPTEST_APP_ROOT') ?: '/srv/app';
$_SERVER['HTTP_HOST'] = $_SERVER['SERVER_NAME'] = getenv('APPTEST_HOST') ?: 'apptest.test';
$_SERVER['REQUEST_URI'] = '/';
$_SERVER['SCRIPT_NAME'] = '/index.php';
$_SERVER['SCRIPT_FILENAME'] = $root . '/index.php';
$_SERVER['REMOTE_ADDR'] = '127.0.0.1';
$_SERVER['REQUEST_METHOD'] = 'GET';

require_once $root . '/config/config.inc.php';

// PrestaShop's own handlers keep CLI failures quiet; a fixture build needs them loud.
set_exception_handler(function (Throwable $e) {
    fwrite(STDERR, 'FATAL: ' . $e . "\n");
    exit(1);
});
register_shutdown_function(function () {
    $e = error_get_last();
    if ($e && in_array($e['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR], true)) {
        fwrite(STDERR, "FATAL: {$e['message']} in {$e['file']}:{$e['line']}\n");
    }
});

$context = Context::getContext();
$context->employee = new Employee(1);
$context->shop = new Shop(1);
Shop::setContext(Shop::CONTEXT_SHOP, 1);
$context->currency = new Currency((int) Configuration::get('PS_CURRENCY_DEFAULT'));
$context->language = new Language((int) Configuration::get('PS_LANG_DEFAULT'));
$context->country = new Country((int) Configuration::get('PS_COUNTRY_DEFAULT'));
$context->cookie = new Cookie('apptest-cli');
$context->cookie->id_lang = $context->language->id;
$context->link = new Link();
// What FrontController::buildContainer() does; Cart, CartRule and the payment modules look it up.
// 1.6 has no Symfony container at all.
if (version_compare(_PS_VERSION_, '1.7', '>=')) {
    $context->container = PrestaShop\PrestaShop\Adapter\ContainerBuilder::getContainer('front', _PS_MODE_DEV_);
}
