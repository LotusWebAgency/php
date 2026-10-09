<?php

namespace App\Apptest;

class Stream
{
    private $seed;
    private $block = '';
    private $pos = 0;
    private $counter = 0;

    public function __construct($seed)
    {
        $this->seed = $seed;
    }

    public function int($max)
    {
        if ($this->pos + 4 > strlen($this->block)) {
            $this->block = hash('sha256', $this->seed.'#'.$this->counter++, true);
            $this->pos = 0;
        }
        $n = unpack('N', substr($this->block, $this->pos, 4))[1];
        $this->pos += 4;

        return $n % $max;
    }
}
