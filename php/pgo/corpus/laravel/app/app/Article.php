<?php

namespace App;

use Illuminate\Database\Eloquent\Model;

class Article extends Model
{
    public $timestamps = false;

    protected $table = 'corpus_articles';

    public function comments()
    {
        return $this->hasMany(Comment::class, 'article_id');
    }
}
