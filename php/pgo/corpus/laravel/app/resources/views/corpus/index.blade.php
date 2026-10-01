<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>PGO training corpus</title>
</head>
<body>
<h1>PGO training corpus</h1>
<ul>
    @foreach ($articles as $article)
        <li>
            <a href="/articles/{{ $article->id }}">{{ $article->title }}</a>
            <span>{{ $article->published_at }}</span>
            <span>{{ $article->comments_count }} comments</span>
            <p>{{ \Illuminate\Support\Str::limit($article->body, 120) }}</p>
        </li>
    @endforeach
</ul>
</body>
</html>
