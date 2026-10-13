<?php

namespace Tests\Unit;

use App\Apptest\Canon;
use App\Apptest\Content;
use App\Apptest\Goldens;
use Tests\TestCase;

class ContentTest extends TestCase
{
    public function test_content_is_deterministic()
    {
        $this->assertSame(Content::body(17), Content::body(17));
        $this->assertNotSame(Content::body(17), Content::body(18));
        $this->assertSame(Content::slug(5), Content::slug(5));
    }

    public function test_languages_cycle_through_scripts()
    {
        // preg_match() rather than assertMatchesRegularExpression(), which is PHPUnit 9.1+.
        $this->assertSame(1, preg_match('/\p{Cyrillic}/u', Content::title(1)));
        $this->assertSame(1, preg_match('/\p{Han}/u', Content::title(2)));
        $this->assertSame(1, preg_match('/[\p{Hiragana}\p{Katakana}\p{Han}]/u', Content::title(3)));
        $this->assertSame(1, preg_match('/\p{Arabic}/u', Content::title(4)));
        $this->assertSame(1, preg_match('/[\x{1F300}-\x{1FAFF}\x{2600}-\x{27BF}]/u', Content::body(5)));
        $this->assertSame(1, preg_match('/^[A-Za-z #0-9]+$/', Content::title(6)));
    }

    public function test_canonical_json_sorts_keys_and_keeps_unicode()
    {
        $this->assertSame('{"a":1,"b":{"x":"я","y":[3,2,1]}}', Canon::json(['b' => ['y' => [3, 2, 1], 'x' => 'я'], 'a' => 1]));
        $this->assertSame(Canon::hash(['a' => 1, 'b' => 2]), Canon::hash(['b' => 2, 'a' => 1]));
    }

    public function test_golden_fixture_data_survives_serialize_and_igbinary()
    {
        $data = Goldens::data();
        $this->assertEquals($data, unserialize(serialize($data)));
        if (function_exists('igbinary_serialize')) {
            $this->assertEquals($data, igbinary_unserialize(igbinary_serialize($data)));
        }
    }
}
