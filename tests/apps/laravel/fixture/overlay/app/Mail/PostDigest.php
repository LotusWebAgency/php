<?php

namespace App\Mail;

use Illuminate\Mail\Mailable;

class PostDigest extends Mailable
{
    public $posts;

    public function __construct($posts)
    {
        $this->posts = $posts;
    }

    public function build()
    {
        return $this->subject('Дайджест / 摘要 / Digest')->view('mail.digest');
    }
}
