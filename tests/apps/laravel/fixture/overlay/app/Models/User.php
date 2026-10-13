<?php

namespace App\Models;

use Illuminate\Foundation\Auth\User as Authenticatable;
use Illuminate\Notifications\Notifiable;

// No 'hashed' cast: the seeder writes bcrypt and argon2id hashes side by side
// and the cast would try to verify one against the other's configuration.
class User extends Authenticatable
{
    use Notifiable;

    protected $fillable = ['name', 'email', 'password'];

    protected $hidden = ['password', 'remember_token'];

    protected $casts = ['email_verified_at' => 'datetime'];

    public function posts()
    {
        return $this->hasMany(Post::class);
    }
}
