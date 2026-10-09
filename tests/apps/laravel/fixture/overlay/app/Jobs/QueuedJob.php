<?php

namespace App\Jobs;

use App\Models\JobLog;
use App\Models\Post;
use Carbon\Carbon;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;

// A model (ModelIdentifier), a Carbon and an array all go through the
// database queue's payload, so a worker on another PHP has to unserialize them.
class QueuedJob implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

    public $tries = 1;

    public $post;
    public $when;
    public $token;
    public $extra;

    public function __construct(Post $post, Carbon $when, $token, array $extra = [])
    {
        $this->post = $post;
        $this->when = $when;
        $this->token = $token;
        $this->extra = $extra;
    }

    public function handle()
    {
        JobLog::record('queued', $this->token, json_encode([
            'post' => $this->post->id,
            'slug' => $this->post->slug,
            'when' => $this->when->setTimezone('UTC')->format('Y-m-d\TH:i:s\Z'),
            'extra' => $this->extra,
            'sapi' => PHP_SAPI,
        ], JSON_UNESCAPED_UNICODE));
    }
}
