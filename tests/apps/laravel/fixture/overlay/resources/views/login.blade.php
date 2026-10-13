@extends('layout')
@section('title', 'Login')
@section('content')
    <h1>Login</h1>
    @if ($errors->has('email'))
        <p class="error">{{ $errors->first('email') }}</p>
    @endif
    <form action="/login" method="post" id="login-form">
        {{ csrf_field() }}
        <input type="email" name="email" value="{{ old('email') }}">
        <input type="password" name="password">
        <button>Sign in</button>
    </form>
@endsection
