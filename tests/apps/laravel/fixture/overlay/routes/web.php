<?php

use App\Http\Controllers\AuthController;
use App\Http\Controllers\HomeController;
use App\Http\Controllers\MediaController;
use App\Http\Controllers\PostController;
use App\Http\Controllers\SessionController;
use Illuminate\Support\Facades\Route;

// Before 8 a controller action is a 'Class@method' string, and the leading
// backslash keeps RouteServiceProvider's $namespace from being prefixed to it;
// 8+ takes [Class, 'method'].
$to = function ($controller, $method) {
    return version_compare(app()->version(), '8.0', '<') ? '\\'.$controller.'@'.$method : [$controller, $method];
};

Route::get('/', $to(HomeController::class, 'index'));
if (version_compare(app()->version(), '11.0', '<')) {
    Route::get('/up', $to(HomeController::class, 'up'));
}
Route::get('/tags/{slug}', $to(HomeController::class, 'tag'));
Route::get('/search', $to(HomeController::class, 'search'));
Route::get('/posts/{slug}', $to(PostController::class, 'show'));
Route::post('/posts/{slug}/comments', $to(PostController::class, 'comment'));
Route::get('/media/{id}/{file}', $to(MediaController::class, 'show'))->where('id', '[0-9]+');

Route::get('/login', $to(AuthController::class, 'showLogin'))->name('login');
Route::post('/login', $to(AuthController::class, 'login'));
Route::post('/logout', $to(AuthController::class, 'logout'));

Route::middleware('auth')->group(function () use ($to) {
    Route::get('/dashboard', $to(AuthController::class, 'dashboard'));
    Route::get('/dashboard/posts/create', $to(PostController::class, 'create'));
    Route::post('/dashboard/posts', $to(PostController::class, 'store'));
    Route::get('/dashboard/upload', $to(MediaController::class, 'form'));
    Route::post('/dashboard/upload', $to(MediaController::class, 'store'));
});

Route::get('/redis-session/hit', $to(SessionController::class, 'hit'));
Route::get('/redis-session/flash', $to(SessionController::class, 'flash'));
Route::get('/redis-session/read', $to(SessionController::class, 'read'));

Route::get('/boom', $to(\App\Http\Controllers\ApiController::class, 'boom'));
