<?php

namespace App\Http\Controllers;

use App\Events\PostCreated;
use App\Models\Comment;
use App\Models\Post;
use App\Models\Tag;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Str;

class PostController extends Controller
{
    public function show($slug)
    {
        $post = Post::with(['user', 'tags'])->withCount('comments')->where('slug', $slug)->firstOrFail();
        $comments = $post->comments()->with('user')->orderBy('id')->paginate(10, ['*'], 'cpage');

        return view('posts.show', ['post' => $post, 'comments' => $comments]);
    }

    public function comment(Request $request, $slug)
    {
        $post = Post::where('slug', $slug)->firstOrFail();
        $data = $request->validate([
            'author' => 'required|string|max:100',
            'body' => 'required|string|min:3|max:2000',
        ]);
        Comment::create([
            'post_id' => $post->id,
            'user_id' => Auth::id(),
            'author' => $data['author'],
            'body' => $data['body'],
        ]);

        return redirect('/posts/'.$post->slug.'#comments')->with('status', 'Comment added');
    }

    public function create()
    {
        return view('dashboard.create', ['tags' => Tag::orderBy('id')->limit(20)->get()]);
    }

    public function store(Request $request)
    {
        $data = $request->validate([
            'title' => 'required|string|max:255',
            'body' => 'required|string|min:20',
            'tags' => 'array',
            'tags.*' => 'integer|exists:tags,id',
        ]);
        $slug = (Str::slug($data['title']) ?: 'post').'-'.strtolower(Str::random(8));
        $post = Post::create([
            'user_id' => Auth::id(),
            'title' => $data['title'],
            'slug' => $slug,
            'excerpt' => mb_substr($data['body'], 0, 140),
            'body' => $data['body'],
            'published_at' => now(),
        ]);
        if (!empty($data['tags'])) {
            $post->tags()->sync($data['tags']);
        }
        event(new PostCreated($post));

        return redirect('/posts/'.$post->slug)->with('status', 'Post created');
    }
}
