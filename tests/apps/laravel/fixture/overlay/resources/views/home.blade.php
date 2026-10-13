@extends('layout')
@section('title', $heading)
@section('content')
    <h1>{{ $heading }}</h1>
    <p id="total" data-total="{{ $posts->total() }}">{{ $posts->total() }} posts</p>
    @foreach ($posts as $post)
        @include('posts.card', ['post' => $post])
    @endforeach
    {{ $posts->links() }}
@endsection
