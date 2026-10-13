<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class Post extends Model
{
    protected $guarded = [];

    protected $casts = ['published_at' => 'datetime'];

    public function user()
    {
        return $this->belongsTo(User::class);
    }

    public function comments()
    {
        return $this->hasMany(Comment::class);
    }

    public function tags()
    {
        return $this->belongsToMany(Tag::class, 'post_tag');
    }

    // The shape /api/posts serves and the goldens hash. Timestamps are
    // formatted by hand so a Carbon serialization change cannot move them.
    public function toApi($withComments = false)
    {
        $data = [
            'id' => (int) $this->id,
            'slug' => $this->slug,
            'title' => $this->title,
            'excerpt' => $this->excerpt,
            'body' => $this->body,
            'views' => (int) $this->views,
            'published_at' => $this->published_at->setTimezone('UTC')->format('Y-m-d\TH:i:s\Z'),
            'author' => ['id' => (int) $this->user->id, 'name' => $this->user->name],
            'tags' => $this->tags->sortBy('id')->map(function ($t) {
                return ['id' => (int) $t->id, 'name' => $t->name, 'slug' => $t->slug];
            })->values()->all(),
            'comments_count' => (int) $this->comments_count,
        ];
        if ($withComments) {
            $data['comments'] = $this->comments()->orderBy('id')->limit(5)->get()->map(function ($c) {
                return [
                    'id' => (int) $c->id,
                    'author' => $c->author,
                    'body' => $c->body,
                    'created_at' => $c->created_at->setTimezone('UTC')->format('Y-m-d\TH:i:s\Z'),
                ];
            })->all();
        }

        return $data;
    }

    // Same predicate for the page, the JSON search and the fixture manifest.
    public function scopeSearch($query, $term)
    {
        $like = '%'.$term.'%';

        return $query->where(function ($q) use ($like) {
            $q->where('title', 'like', $like)->orWhere('body', 'like', $like);
        });
    }

    public static function forApi()
    {
        return static::with(['user', 'tags'])->withCount('comments');
    }
}
