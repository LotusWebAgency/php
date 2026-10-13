<?php

namespace Tests\Unit;

use App\Apptest\Passwords;
use Carbon\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Str;
use Tests\TestCase;

class PlatformTest extends TestCase
{
    public function test_carbon_arithmetic_across_a_dst_change()
    {
        $t = Carbon::create(2023, 3, 26, 1, 30, 0, 'Europe/Berlin');
        $this->assertSame('2023-03-26T03:30:00+02:00', $t->copy()->addHour()->toIso8601String());
        $this->assertSame('2024-03-01', Carbon::parse('2024-02-29')->addDay()->toDateString());
        $this->assertTrue(Carbon::parse('2024-01-01')->isBefore(Carbon::parse('2024-01-02')));
    }

    public function test_collections()
    {
        $c = new Collection([3, 1, 2]);
        $this->assertSame([1, 2, 3], $c->sort()->values()->all());
        $this->assertSame(6, $c->sum());
        $this->assertSame(['a' => 2], collect(['a' => 1])->map(function ($v) {
            return $v * 2;
        })->all());
    }

    public function test_hashing_drivers()
    {
        $second = Passwords::second();
        foreach ($second ? [['bcrypt', 'bcrypt'], [$second['driver'], $second['algo']]] : [['bcrypt', 'bcrypt']] as $one) {
            list($driver, $algo) = $one;
            $hash = Passwords::driver($driver)->make('sécret пароль');
            $this->assertTrue(Passwords::driver($driver)->check('sécret пароль', $hash));
            $this->assertFalse(Passwords::driver($driver)->check('other', $hash));
            $this->assertSame($algo, Passwords::info($hash)['algoName']);
        }
    }

    public function test_string_helpers_with_utf8()
    {
        $this->assertSame('privet-mir', Str::slug('Привет мир'));
        $this->assertSame('ПРИВЕТ', Str::upper('привет'));
        $this->assertSame(3, Str::length('日本語'));
    }

    public function test_encrypter_round_trips_and_rejects_tampering()
    {
        $enc = app('encrypter');
        $this->assertSame('тайна', $enc->decryptString($enc->encryptString('тайна')));
        $this->expectException(\Illuminate\Contracts\Encryption\DecryptException::class);
        $enc->decryptString('eyJpdiI6IngiLCJ2YWx1ZSI6InkiLCJtYWMiOiJ6IiwidGFnIjoiIn0=');
    }
}
