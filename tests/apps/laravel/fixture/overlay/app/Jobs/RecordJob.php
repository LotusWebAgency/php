<?php

namespace App\Jobs;

use App\Models\JobLog;
use Illuminate\Bus\Queueable;
use Illuminate\Foundation\Bus\Dispatchable;

class RecordJob
{
    use Dispatchable, Queueable;

    public $token;

    public function __construct($token)
    {
        $this->token = $token;
    }

    public function handle()
    {
        JobLog::record('sync', $this->token, 'sapi='.PHP_SAPI);
    }
}
