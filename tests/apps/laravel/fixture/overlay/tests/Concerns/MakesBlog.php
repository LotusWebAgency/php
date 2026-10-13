<?php

namespace Tests\Concerns;

use App\Apptest\Content;
use App\Apptest\Passwords;
use App\Models\Comment;
use App\Models\Post;
use App\Models\Tag;
use App\Models\User;

trait MakesBlog
{
    protected function makeUser($n = 1, $driver = 'bcrypt')
    {
        return User::create([
            'name' => Content::userName($n),
            'email' => Content::email($n),
            'password' => Passwords::driver($driver)->make(Content::password($n)),
        ]);
    }

    protected function makePost(User $user, $i = 1, array $tags = [])
    {
        $body = Content::body($i);
        $post = Post::create([
            'user_id' => $user->id,
            'title' => Content::title($i),
            'slug' => Content::slug($i),
            'excerpt' => Content::excerpt($body),
            'body' => $body,
            'published_at' => '2024-01-01 00:00:00',
        ]);
        if ($tags) {
            $post->tags()->attach($tags);
        }

        return $post;
    }

    protected function makeTag($n = 1)
    {
        return Tag::create(['name' => Content::tagName($n), 'slug' => Content::tagSlug($n)]);
    }

    protected function makeComment(Post $post, $i = 1)
    {
        return Comment::create(['post_id' => $post->id, 'author' => Content::author($i), 'body' => Content::comment($i)]);
    }
}
