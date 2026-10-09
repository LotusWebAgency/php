@extends('layout')
@section('title', 'New post')
@section('content')
    <h1>New post</h1>
    @if ($errors->any())
        <ul class="errors">
            @foreach ($errors->all() as $error)
                <li class="error">{{ $error }}</li>
            @endforeach
        </ul>
    @endif
    <form action="/dashboard/posts" method="post" id="post-form">
        {{ csrf_field() }}
        <input name="title" value="{{ old('title') }}">
        <textarea name="body">{{ old('body') }}</textarea>
        @foreach ($tags as $tag)
            <label><input type="checkbox" name="tags[]" value="{{ $tag->id }}"> {{ $tag->name }}</label>
        @endforeach
        <button>Publish</button>
    </form>
@endsection
