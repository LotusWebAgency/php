<?php

namespace App\Console\Commands;

use App\Models\JobLog;
use Illuminate\Console\Command;

class ApptestHeartbeat extends Command
{
    protected $signature = 'apptest:heartbeat {token=scheduled}';

    protected $description = 'Record that the scheduler ran this command';

    public function handle()
    {
        JobLog::record('heartbeat', $this->argument('token'), 'sapi='.PHP_SAPI);
        $this->info('beat');

        return 0;
    }
}
