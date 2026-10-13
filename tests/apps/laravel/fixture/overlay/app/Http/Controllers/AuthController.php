<?php

namespace App\Http\Controllers;

use App\Apptest\Passwords;
use App\Models\User;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;

class AuthController extends Controller
{
    public function showLogin()
    {
        return view('login');
    }

    // The hasher is chosen from the stored hash: the fixture holds bcrypt and
    // argon2id users, and a single-driver check would refuse the other one.
    public function login(Request $request)
    {
        $credentials = $request->validate(['email' => 'required|email', 'password' => 'required|string']);
        $user = User::where('email', $credentials['email'])->first();
        if ($user) {
            $algo = Passwords::info($user->password)['algoName'];
            if ($algo !== 'unknown' && Passwords::driver(Passwords::driverFor($algo))->check($credentials['password'], $user->password)) {
                Auth::login($user);
                $request->session()->regenerate();

                return redirect('/dashboard');
            }
        }

        return redirect('/login')->withInput($request->only('email'))
            ->withErrors(['email' => 'These credentials do not match our records.']);
    }

    public function logout(Request $request)
    {
        Auth::logout();
        $request->session()->invalidate();
        $request->session()->regenerateToken();

        return redirect('/');
    }

    public function dashboard(Request $request)
    {
        $user = Auth::user();

        return view('dashboard.index', [
            'user' => $user,
            'algo' => Passwords::info($user->password)['algoName'],
            'recent' => $user->posts()->orderByDesc('id')->limit(5)->get(['id', 'slug', 'title']),
            'count' => $user->posts()->count(),
        ]);
    }
}
