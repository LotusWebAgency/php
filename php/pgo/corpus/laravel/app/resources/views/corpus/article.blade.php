<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>{{ $article->title }} &mdash; PGO training corpus</title>
</head>
<body>
<h1>{{ $article->title }}</h1>
<article><p>{{ $article->body }}</p></article>
<section>
    @foreach ($article->comments as $comment)
        <blockquote>
            <p>{{ $comment->body }}</p>
            <cite>{{ $comment->author }} &mdash; {{ $comment->created_at }}</cite>
        </blockquote>
    @endforeach
</section>
</body>
</html>
