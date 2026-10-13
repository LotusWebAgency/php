<article class="post-card" id="post-{{ $post->id }}" dir="auto">
    <h2><a href="/posts/{{ $post->slug }}">{{ $post->title }}</a></h2>
    <p class="meta">by {{ $post->user->name }} | {{ $post->published_at->format('Y-m-d H:i') }} | {{ $post->comments_count }} comments</p>
    <p>{{ $post->excerpt }}</p>
    <ul class="tags">
        @foreach ($post->tags->sortBy('id') as $tag)
            <li><a href="/tags/{{ $tag->slug }}">{{ $tag->name }}</a></li>
        @endforeach
    </ul>
</article>
