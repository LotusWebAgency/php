<?php

namespace App\Console\Commands;

use Illuminate\Console\Command;

// Tinker without psysh: evaluates one expression inside the booted app.
class ApptestEval extends Command
{
    protected $signature = 'apptest:eval {code : PHP statements; the return value is printed as JSON}';

    protected $description = 'Evaluate PHP inside the application';

    public function handle()
    {
        $result = eval($this->argument('code'));
        $this->line(json_encode($result, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));

        return 0;
    }
}
