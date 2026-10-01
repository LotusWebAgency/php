<?php

namespace App\Events;

class PostCreated
{
    public $post;

    public function __construct($post)
    {
        $this->post = $post;
    }
}
