<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class JobLog extends Model
{
    protected $table = 'job_log';

    public $timestamps = false;

    protected $guarded = [];

    public static function record($kind, $token, $payload = null)
    {
        return static::create([
            'kind' => $kind,
            'token' => $token,
            'payload' => $payload,
            'created_at' => date('Y-m-d H:i:s'),
        ]);
    }
}
