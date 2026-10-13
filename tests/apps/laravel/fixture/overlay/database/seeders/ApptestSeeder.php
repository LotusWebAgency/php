<?php

namespace Database\Seeders;

use App\Apptest\Content;
use App\Apptest\Passwords;
use App\Models\Comment;
use App\Models\Post;
use App\Models\Tag;
use App\Models\User;
use Illuminate\Database\Seeder;
use Illuminate\Support\Facades\DB;

class ApptestSeeder extends Seeder
{
    const USERS = 50;
    const POSTS = 2000;
    const COMMENTS = 10000;
    const TAGS = 100;
    const BCRYPT_USERS = 40; // users 41..50 get argon2id, or argon2i, or bcrypt where PHP or Laravel has no argon
    const BASE = 1704067200; // 2024-01-01T00:00:00Z

    public function run()
    {
        DB::connection()->disableQueryLog();

        $second = Passwords::second();
        User::unguarded(function () use ($second) {
            for ($n = 1; $n <= self::USERS; $n++) {
                $driver = $n <= self::BCRYPT_USERS || !$second ? 'bcrypt' : $second['driver'];
                $at = self::stamp($n * 60);
                User::create([
                    'name' => Content::userName($n),
                    'email' => Content::email($n),
                    'password' => Passwords::driver($driver)->make(Content::password($n)),
                    'created_at' => $at,
                    'updated_at' => $at,
                ]);
            }
        });

        for ($n = 1; $n <= self::TAGS; $n++) {
            Tag::create(['name' => Content::tagName($n), 'slug' => Content::tagSlug($n)]);
        }

        for ($i = 1; $i <= self::POSTS; $i++) {
            $body = Content::body($i);
            $at = self::stamp($i * 3600);
            $post = Post::create([
                'user_id' => ($i * 13) % self::USERS + 1,
                'title' => Content::title($i),
                'slug' => Content::slug($i),
                'excerpt' => Content::excerpt($body),
                'body' => $body,
                'views' => Content::stream("views:$i")->int(5000),
                'published_at' => $at,
                'created_at' => $at,
                'updated_at' => $at,
            ]);
            $post->tags()->attach(array_values(array_unique([
                ($i * 7) % self::TAGS + 1,
                ($i * 11 + 3) % self::TAGS + 1,
                ($i * 17 + 5) % self::TAGS + 1,
            ])));
        }

        // Comments go in as multi-row inserts through the model's builder:
        // ten thousand single inserts would triple the fixture build.
        $rows = [];
        for ($i = 1; $i <= self::COMMENTS; $i++) {
            $postId = ($i * 7) % self::POSTS + 1;
            $userId = $i % 3 === 0 ? null : ($i * 5) % self::USERS + 1;
            $at = self::stamp($postId * 3600 + $i % 3000);
            $rows[] = [
                'id' => $i,
                'post_id' => $postId,
                'user_id' => $userId,
                'author' => Content::author($i),
                'body' => Content::comment($i),
                'created_at' => $at,
                'updated_at' => $at,
            ];
            if (count($rows) === 500) {
                Comment::insert($rows);
                $rows = [];
            }
        }
        if ($rows) {
            Comment::insert($rows);
        }
    }

    private static function stamp($offset)
    {
        return gmdate('Y-m-d H:i:s', self::BASE + $offset);
    }
}
