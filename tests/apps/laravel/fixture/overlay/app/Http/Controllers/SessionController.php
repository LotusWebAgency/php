<?php

namespace App\Http\Controllers;

use Illuminate\Http\Request;

// Everything under /redis-session runs on the redis session driver (see
// App\Http\Middleware\UseRedisSession).
class SessionController extends Controller
{
    public function hit(Request $request)
    {
        $count = (int) $request->session()->get('hits', 0) + 1;
        $request->session()->put('hits', $count);
        $request->session()->put('payload', ['текст' => '日本語 😀', 'n' => $count]);

        return response()->json([
            'hits' => $count,
            'driver' => config('session.driver'),
            'handler' => get_class($request->session()->getHandler()),
            'id_length' => strlen($request->session()->getId()),
        ]);
    }

    public function flash(Request $request)
    {
        $request->session()->flash('note', 'flash ✓ '.$request->query('v', ''));

        return response()->json(['flashed' => true]);
    }

    public function read(Request $request)
    {
        return response()->json([
            'note' => $request->session()->get('note'),
            'payload' => $request->session()->get('payload'),
            'hits' => $request->session()->get('hits'),
            'token_length' => strlen($request->session()->token()),
        ], 200, [], JSON_UNESCAPED_UNICODE);
    }
}
