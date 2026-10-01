<?php

namespace App\Apptest;

class Packed
{
    public $items;

    public function __construct(array $items)
    {
        $this->items = $items;
    }

    public function __serialize(): array
    {
        return ['i' => $this->items, 'v' => 2];
    }

    public function __unserialize(array $data): void
    {
        $this->items = $data['i'];
    }
}
