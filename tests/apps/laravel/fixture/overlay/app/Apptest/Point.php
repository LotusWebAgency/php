<?php

namespace App\Apptest;

// Public, protected and private properties serialize differently (NUL-prefixed
// names); Packed goes through __serialize/__unserialize instead.
class Point
{
    public $x;
    protected $y;
    private $z;

    public function __construct($x, $y, $z)
    {
        $this->x = $x;
        $this->y = $y;
        $this->z = $z;
    }
}
