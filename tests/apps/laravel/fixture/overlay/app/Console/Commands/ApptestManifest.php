<?php

namespace App\Console\Commands;

use App\Apptest\Content;
use App\Apptest\Goldens;
use App\Apptest\Passwords;
use App\Jobs\QueuedJob;
use App\Models\Comment;
use App\Models\Post;
use App\Models\Tag;
use App\Models\User;
use Carbon\Carbon;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Crypt;
use Illuminate\Support\Facades\DB;

// Fixture build only: writes what the known-good PHP knows (cache entries,
// a pending queue job, blobs) and records the manifest the suites compare to.
class ApptestManifest extends Command
{
    protected $signature = 'apptest:manifest {--session-cookie= : name=value of a logged-in session made by the build}';

    protected $description = 'Write .apptest/manifest.json (fixture build only)';

    public function handle()
    {
        $stockCache = ['n' => 12345, 's' => 'стоковый кеш 😀 世界', 'list' => [1, 2, 3], 'nested' => ['a' => ['b' => null, 'c' => true]]];
        Cache::store('database')->forever('apptest:stock', $stockCache);
        Cache::store('file')->forever('apptest:stock', $stockCache);
        QueuedJob::dispatch(Post::findOrFail(2), Carbon::create(2024, 1, 2, 3, 4, 5, 'UTC'), 'stock-queued', ['ключ' => '値 😀', 'list' => [1, 2, 3]])->onQueue('stock');

        $rsa = openssl_pkey_new(['private_key_bits' => 2048, 'private_key_type' => OPENSSL_KEYTYPE_RSA]);
        openssl_pkey_export($rsa, $private);
        openssl_sign('apptest rsa message', $signature, $private, OPENSSL_ALGO_SHA256);
        $blobs = [
            'serialize' => base64_encode(serialize(Goldens::data())),
            'igbinary' => function_exists('igbinary_serialize') ? base64_encode(igbinary_serialize(Goldens::data())) : null,
            'rsa' => ['private' => $private, 'public' => openssl_pkey_get_details($rsa)['key'], 'signature' => base64_encode($signature)],
            'crypt_plain' => 'stock-crypt-plain ✓ секрет',
            'password' => 'apptest-pw',
            'bcrypt' => password_hash('apptest-pw', PASSWORD_BCRYPT),
        ];
        // argon2id from PHP 7.3, argon2i from 7.2, neither on the older sets
        $second = Passwords::second();
        if ($second) {
            $blobs[$second['algo']] = password_hash('apptest-pw', constant($second['constant']));
        }
        $blobs['crypt'] = Crypt::encryptString($blobs['crypt_plain']);

        $byLang = [];
        foreach (Content::LANGS as $lang) {
            for ($i = 1; $i <= 6; $i++) {
                if (Content::lang($i) === $lang) {
                    $p = Post::findOrFail($i);
                    $byLang[$lang] = ['id' => $p->id, 'slug' => $p->slug, 'title' => $p->title];
                    break;
                }
            }
        }
        $searches = [];
        foreach (['kernel', 'сервер', 'СЕРВЕР', '服务器', 'サーバー', 'خادم', '🚀', 'nonexistent-term-xyz'] as $term) {
            $searches[] = ['q' => $term, 'total' => Post::search($term)->count()];
        }
        $tag = Tag::findOrFail(7);
        $bcrypt = User::findOrFail(1);
        $first = Post::findOrFail(1);
        $last = Post::findOrFail(Goldens::SEED_POSTS);
        $cookie = (string) $this->option('session-cookie');
        list($cname, $cvalue) = strpos($cookie, '=') !== false ? explode('=', $cookie, 2) : ['', ''];
        $users = ['bcrypt' => ['id' => $bcrypt->id, 'email' => $bcrypt->email, 'name' => $bcrypt->name, 'password' => Content::password($bcrypt->id)]];
        if ($second) {
            $argon = User::findOrFail(\Database\Seeders\ApptestSeeder::BCRYPT_USERS + 1);
            $users[$second['algo']] = ['id' => $argon->id, 'email' => $argon->email, 'name' => $argon->name, 'password' => Content::password($argon->id)];
        }

        $manifest = [
            'app_version' => $this->laravel->version(),
            'built_on_php' => PHP_VERSION,
            'counts' => [
                'users' => User::count(), 'posts' => Post::count(), 'comments' => Comment::count(),
                'tags' => Tag::count(), 'post_tag' => DB::table('post_tag')->count(),
            ],
            'users' => $users,
            'posts' => [
                'first' => ['id' => $first->id, 'slug' => $first->slug, 'title' => $first->title],
                'last' => ['id' => $last->id, 'slug' => $last->slug, 'title' => $last->title],
                'by_lang' => $byLang,
            ],
            'tag' => ['id' => $tag->id, 'slug' => $tag->slug, 'name' => $tag->name, 'posts' => $tag->posts()->count()],
            'searches' => $searches,
            'session_cookie' => ['name' => $cname, 'value' => $cvalue],
            'stock_cache' => $stockCache,
            'blobs' => $blobs,
        ];
        $manifest['golden'] = Goldens::compute($blobs);

        $dir = base_path('.apptest');
        if (!is_dir($dir)) {
            mkdir($dir, 0755, true);
        }
        file_put_contents($dir.'/manifest.json', json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)."\n");
        $this->info('manifest written: '.count($manifest['golden']).' goldens');

        return 0;
    }
}
