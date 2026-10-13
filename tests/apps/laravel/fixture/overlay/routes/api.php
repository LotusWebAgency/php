<?php

use App\Http\Controllers\ApiController;
use App\Http\Controllers\FeatureController;
use Illuminate\Support\Facades\Route;

// See routes/web.php.
$to = function ($controller, $method) {
    return version_compare(app()->version(), '8.0', '<') ? '\\'.$controller.'@'.$method : [$controller, $method];
};

Route::get('/posts', $to(ApiController::class, 'posts'));
Route::get('/posts/{id}', $to(ApiController::class, 'post'))->where('id', '[0-9]+');
Route::get('/search', $to(ApiController::class, 'search'));
Route::get('/golden', $to(ApiController::class, 'golden'));
Route::get('/info', $to(ApiController::class, 'info'));
Route::get('/boom', $to(ApiController::class, 'boom'));

Route::prefix('features')->group(function () use ($to) {
    Route::get('/cache/{store}/suite', $to(FeatureController::class, 'cacheSuite'));
    Route::post('/cache/{store}', $to(FeatureController::class, 'cachePut'));
    Route::get('/cache/{store}', $to(FeatureController::class, 'cacheGet'));
    Route::get('/hash', $to(FeatureController::class, 'hash'));
    Route::get('/crypto', $to(FeatureController::class, 'crypto'));
    Route::get('/intl', $to(FeatureController::class, 'intl'));
    Route::get('/xml', $to(FeatureController::class, 'xml'));
    Route::get('/archive', $to(FeatureController::class, 'archive'));
    Route::get('/text', $to(FeatureController::class, 'text'));
    Route::get('/misc', $to(FeatureController::class, 'misc'));
    Route::get('/db', $to(FeatureController::class, 'db'));
    Route::get('/gmp', $to(FeatureController::class, 'gmp'));
    Route::post('/queue/dispatch', $to(FeatureController::class, 'queueDispatch'));
    Route::post('/queue/drain', $to(FeatureController::class, 'queueDrain'));
    Route::get('/queue/status', $to(FeatureController::class, 'queueStatus'));
    Route::get('/queue/stock', $to(FeatureController::class, 'stockJob'));
    Route::post('/upload', $to(\App\Http\Controllers\MediaController::class, 'store'));
});
