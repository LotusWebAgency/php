<?php

namespace App\Console\Commands;

use App\Jobs\FailingJob;
use App\Jobs\QueuedJob;
use App\Models\Post;
use Carbon\Carbon;
use Illuminate\Console\Command;

class ApptestDispatch extends Command
{
    protected $signature = 'apptest:dispatch {token} {--queue=cli} {--fail}';

    protected $description = 'Put a job on the database queue';

    public function handle()
    {
        QueuedJob::dispatch(Post::findOrFail(3), Carbon::create(2025, 6, 7, 8, 9, 10, 'UTC'), $this->argument('token'), ['текст' => '日本語 😀', 'n' => [1, 2]])
            ->onQueue($this->option('queue'));
        if ($this->option('fail')) {
            FailingJob::dispatch()->onQueue($this->option('queue'));
        }
        $this->info('dispatched '.$this->argument('token'));

        return 0;
    }
}
