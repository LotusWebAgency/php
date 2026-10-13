<?php

namespace App;

use Illuminate\Database\Eloquent\Model;

class Comment extends Model
{
    public $timestamps = false;

    protected $table = 'corpus_comments';

    public function article()
    {
        return $this->belongsTo(Article::class, 'article_id');
    }
}
