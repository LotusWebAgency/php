<?php

// Replaces the skeleton's single closure route. Two reasons, both load-bearing:
// a closure cannot be serialised, so `artisan route:cache` -- which every
// production Laravel deployment runs, and which the profile should therefore
// reflect -- refuses to run against the stock file; and the stock route renders
// a static welcome view, so nothing the corpus serves would touch Eloquent, the
// query builder or pdo_sqlite.
//
// String actions with a leading backslash, not [Controller::class, 'method']:
// the array form arrived after Laravel 5.5, and one routes file has to work on
// every tier from 5.5 to 12. A leading backslash is what tells Laravel 5.x's
// group namespace not to prepend App\Http\Controllers a second time.

use Illuminate\Support\Facades\Route;

Route::get('/', '\App\Http\Controllers\CorpusController@index');
Route::get('/articles/{id}', '\App\Http\Controllers\CorpusController@show');
Route::get('/api/articles', '\App\Http\Controllers\CorpusController@api');
