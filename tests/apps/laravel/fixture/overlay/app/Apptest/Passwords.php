<?php

namespace App\Apptest;

/*
 * The hashing drivers each framework generation has. 5.5 has one hasher
 * (bcrypt, no manager); 5.6+ has the manager, argon2i ('argon') from 5.7 and
 * argon2id from 5.8, and PHP itself has argon2i from 7.2 and argon2id from 7.3.
 */
class Passwords
{
    const DRIVERS = ['bcrypt' => 'bcrypt', 'argon2i' => 'argon', 'argon2id' => 'argon2id'];

    const CONSTANTS = ['argon2i' => 'PASSWORD_ARGON2I', 'argon2id' => 'PASSWORD_ARGON2ID'];

    public static function driver($name)
    {
        $hash = app('hash');

        return method_exists($hash, 'driver') ? $hash->driver($name) : $hash;
    }

    public static function info($hash)
    {
        $manager = app('hash');

        return method_exists($manager, 'info') ? $manager->info($hash) : password_get_info($hash);
    }

    // Laravel's driver name for a password_get_info() algoName.
    public static function driverFor($algo)
    {
        return self::DRIVERS[$algo];
    }

    // The non-bcrypt algorithm this PHP and this Laravel can both do, best
    // first: [algoName, constant, driver], or null.
    public static function second()
    {
        if (!method_exists(app('hash'), 'driver')) {
            return null;
        }
        foreach (['argon2id', 'argon2i'] as $algo) {
            if (defined(self::CONSTANTS[$algo]) && class_exists($algo === 'argon2id' ? \Illuminate\Hashing\Argon2IdHasher::class : \Illuminate\Hashing\ArgonHasher::class)) {
                return ['algo' => $algo, 'constant' => self::CONSTANTS[$algo], 'driver' => self::DRIVERS[$algo]];
            }
        }

        return null;
    }
}
