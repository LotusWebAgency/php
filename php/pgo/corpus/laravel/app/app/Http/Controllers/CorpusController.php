<?php

namespace App\Http\Controllers;

use App\Article;

class CorpusController extends Controller
{
    public function index()
    {
        $articles = Article::withCount('comments')
            ->orderBy('published_at', 'desc')
            ->take(20)
            ->get();

        return view('corpus.index', array('articles' => $articles));
    }

    public function show($id)
    {
        $article = Article::with('comments')->findOrFail($id);

        return view('corpus.article', array('article' => $article));
    }

    public function api()
    {
        return response()->json(array(
            'articles' => Article::orderBy('id')->take(50)->get(),
        ));
    }
}
