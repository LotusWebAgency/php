<?php

// Symfony 3.4 front controller: symfony/runtime, and the closure-returning
// index.php that goes with it, did not exist before 5.3.

use App\Kernel;
use Symfony\Component\Dotenv\Dotenv;
use Symfony\Component\HttpFoundation\Request;

require dirname(__DIR__).'/vendor/autoload.php';

(new Dotenv())->load(dirname(__DIR__).'/.env');

$kernel = new Kernel(getenv('APP_ENV') ?: 'prod', (bool) getenv('APP_DEBUG'));
$request = Request::createFromGlobals();
$response = $kernel->handle($request);
$response->send();
$kernel->terminate($request, $response);
