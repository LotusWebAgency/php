@extends('layout')
@section('title', 'Dashboard')
@section('content')
    <h1>Dashboard</h1>
    <p id="whoami">{{ $user->name }} ({{ $user->email }})</p>
    <p id="hash-algo">{{ $algo }}</p>
    <p id="post-count" data-count="{{ $count }}">{{ $count }} posts</p>
    <ul>
        @foreach ($recent as $post)
            <li><a href="/posts/{{ $post->slug }}">{{ $post->title }}</a></li>
        @endforeach
    </ul>
    <a href="/dashboard/posts/create">New post</a> <a href="/dashboard/upload">Upload</a>
@endsection
