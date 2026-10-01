<?php

namespace App\Apptest;

/*
 * Canonical JSON: keys sorted by byte value, no whitespace, UTF-8 and slashes
 * left alone. tests/apps/apptest.py's canonical() produces the same bytes, so
 * a hash taken here can be compared with one taken over an HTTP response.
 */
class Canon
{
    public static function json($value)
    {
        return json_encode(self::sort($value), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    }

    public static function hash($value)
    {
        return hash('sha256', self::json($value));
    }

    private static function sort($v)
    {
        if (!is_array($v)) {
            return $v;
        }
        foreach ($v as $k => $item) {
            $v[$k] = self::sort($item);
        }
        if ($v !== [] && array_keys($v) !== range(0, count($v) - 1)) {
            ksort($v, SORT_STRING);
        }

        return $v;
    }
}
