<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="csrf-token" content="{{ csrf_token() }}">
    <title>@yield('title', 'Apptest') | Apptest Blog</title>
</head>
<body>
<header>
    <nav>
        <a href="/">Home</a>
        <form action="/search" method="get"><input type="search" name="q" value="{{ request('q') }}"><button>Search</button></form>
        @auth
            <a href="/dashboard">Dashboard</a>
            <form action="/logout" method="post" id="logout-form">{{ csrf_field() }}<button>Logout</button></form>
        @else
            <a href="/login">Login</a>
        @endauth
    </nav>
    @if (session('status'))
        <div class="status">{{ session('status') }}</div>
    @endif
</header>
<main>
    @yield('content')
</main>
<footer>Apptest fixture</footer>
</body>
</html>
