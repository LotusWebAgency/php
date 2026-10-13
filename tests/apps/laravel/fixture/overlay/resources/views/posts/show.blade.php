@extends('layout')
@section('title', $post->title)
@section('content')
    <article dir="auto" data-post-id="{{ $post->id }}">
        <h1>{{ $post->title }}</h1>
        <p class="meta">by {{ $post->user->name }} | {{ $post->published_at->format('Y-m-d H:i') }}</p>
        <ul class="tags">
            @foreach ($post->tags->sortBy('id') as $tag)
                <li><a href="/tags/{{ $tag->slug }}">{{ $tag->name }}</a></li>
            @endforeach
        </ul>
        <div class="body">{!! nl2br(e($post->body)) !!}</div>
    </article>
    <section id="comments">
        <h2 id="comment-count" data-count="{{ $post->comments_count }}">{{ $post->comments_count }} comments</h2>
        @foreach ($comments as $comment)
            <div class="comment" id="comment-{{ $comment->id }}" dir="auto">
                <strong>{{ $comment->author }}</strong>
                <p>{{ $comment->body }}</p>
            </div>
        @endforeach
        {{ $comments->links() }}
        <form action="/posts/{{ $post->slug }}/comments" method="post" id="comment-form">
            {{ csrf_field() }}
            @if ($errors->any())
                <ul class="errors">
                    @foreach ($errors->all() as $error)
                        <li class="error">{{ $error }}</li>
                    @endforeach
                </ul>
            @endif
            <input name="author" value="{{ old('author') }}">
            <textarea name="body">{{ old('body') }}</textarea>
            <button>Comment</button>
        </form>
    </section>
@endsection
