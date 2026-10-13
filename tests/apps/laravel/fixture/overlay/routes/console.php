<?php

use Illuminate\Foundation\Inspiring;
use Illuminate\Support\Facades\Artisan;

$inspire = Artisan::command('inspire', function () {
    $this->comment(Inspiring::quote());
});
// purpose() replaced describe() in 6.
method_exists($inspire, 'purpose') ? $inspire->purpose('Display an inspiring quote') : $inspire->describe('Display an inspiring quote');
