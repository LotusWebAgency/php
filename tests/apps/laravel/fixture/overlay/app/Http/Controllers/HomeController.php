<?php

namespace App\Http\Controllers;

use App\Models\Post;
use App\Models\Tag;
use Illuminate\Http\Request;

class HomeController extends Controller
{
    public function index()
    {
        $posts = Post::with(['user', 'tags'])->withCount('comments')->orderByDesc('id')->paginate(12);

        return view('home', ['posts' => $posts, 'heading' => 'Latest posts']);
    }

    // Health endpoint for the frameworks that predate withRouting(health: '/up').
    public function up()
    {
        return response('<!doctype html><title>Up</title><p>Application is up.</p>');
    }

    public function tag($slug)
    {
        $tag = Tag::where('slug', $slug)->firstOrFail();
        $posts = $tag->posts()->with(['user', 'tags'])->withCount('comments')->orderByDesc('posts.id')->paginate(12);

        return view('home', ['posts' => $posts, 'heading' => 'Tag: '.$tag->name]);
    }

    public function search(Request $request)
    {
        $q = trim((string) $request->query('q', ''));
        $posts = Post::search($q)->with(['user', 'tags'])->withCount('comments')->orderBy('id')->paginate(12)->appends(['q' => $q]);

        return view('search', ['posts' => $posts, 'q' => $q]);
    }
}
