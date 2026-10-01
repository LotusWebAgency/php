<h1>Digest</h1>
@foreach ($posts as $post)
    <h2>{{ $post->title }}</h2>
    <p>{{ $post->excerpt }}</p>
@endforeach
