<?php

namespace App\Console\Commands;

use App\Apptest\Goldens;
use App\Apptest\Passwords;
use App\Models\Comment;
use App\Models\Post;
use App\Models\Tag;
use App\Models\User;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;

// Recomputes on this PHP what the fixture build recorded on the stock one.
// Output uses the suites' line format so cli.sh can relay it as checks.
class ApptestVerify extends Command
{
    protected $signature = 'apptest:verify';

    protected $description = 'Compare live values with .apptest/manifest.json';

    private $failed = 0;

    private function line_check($name, $cond, $detail = '')
    {
        if ($cond) {
            $this->line("ok: $name");
        } else {
            $this->failed++;
            $this->line("FAIL: $name".($detail !== '' ? " -- $detail" : ''));
        }
    }

    public function handle()
    {
        $m = json_decode(file_get_contents(base_path('.apptest/manifest.json')), true);

        $this->line_check('verify: laravel version', $this->laravel->version() === $m['app_version'], $this->laravel->version().' vs '.$m['app_version']);
        $this->line_check('verify: users', User::where('id', '<=', Goldens::SEED_USERS)->count() === $m['counts']['users']);
        $this->line_check('verify: posts', Post::where('id', '<=', Goldens::SEED_POSTS)->count() === $m['counts']['posts']);
        $this->line_check('verify: comments', Comment::where('id', '<=', Goldens::SEED_COMMENTS)->count() === $m['counts']['comments']);
        $this->line_check('verify: tags', Tag::count() === $m['counts']['tags']);
        $this->line_check('verify: post_tag', DB::table('post_tag')->where('post_id', '<=', Goldens::SEED_POSTS)->count() === $m['counts']['post_tag']);
        foreach ($m['searches'] as $s) {
            $this->line_check('verify: search '.$s['q'], Post::search($s['q'])->where('id', '<=', Goldens::SEED_POSTS)->count() === $s['total']);
        }

        $live = Goldens::compute($m['blobs']);
        foreach ($m['golden'] as $name => $want) {
            $got = $live[$name] ?? null;
            $this->line_check("golden: $name", $got === $want, 'stock '.substr((string) $want, 0, 16).' vs here '.substr((string) $got, 0, 16));
        }
        $this->line_check('golden: no extra keys', array_keys($live) === array_keys($m['golden']));

        $this->line_check('verify: stock database cache entry', Cache::store('database')->get('apptest:stock') === $m['stock_cache']);
        $this->line_check('verify: stock file cache entry', Cache::store('file')->get('apptest:stock') === $m['stock_cache']);
        foreach ($m['users'] as $kind => $want) {
            $u = User::find($want['id']);
            $this->line_check("verify: $kind user hash", $u && Passwords::info($u->password)['algoName'] === $kind
                && Passwords::driver(Passwords::driverFor($kind))->check($want['password'], $u->password));
        }

        return $this->failed ? 1 : 0;
    }
}
