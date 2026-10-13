<?php

namespace App\Http\Middleware;

use Closure;

// Puts one route prefix on the redis session driver, under its own cookie so
// it never trades session ids with the database-backed session next door.
class UseRedisSession
{
    public function handle($request, Closure $next)
    {
        if ($request->is('redis-session/*')) {
            config(['session.driver' => 'redis', 'session.cookie' => 'apptest_redis_session']);
        }

        return $next($request);
    }
}
