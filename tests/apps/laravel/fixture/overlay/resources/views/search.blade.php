@extends('layout')
@section('title', 'Search')
@section('content')
    <h1>Search</h1>
    <p id="result-count" data-total="{{ $posts->total() }}" data-q="{{ $q }}">{{ $posts->total() }} results</p>
    @foreach ($posts as $post)
        @include('posts.card', ['post' => $post])
    @endforeach
    {{ $posts->links() }}
@endsection
