<?php

namespace Tests\Feature;

use App\Apptest\Content;
use App\Apptest\Passwords;
use App\Events\PostCreated;
use App\Models\Post;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Event;
use Tests\Concerns\MakesBlog;
use Tests\TestCase;

class AuthTest extends TestCase
{
    use MakesBlog, RefreshDatabase;

    public function test_guests_are_sent_to_the_login_form()
    {
        $this->get('/dashboard')->assertRedirect('/login');
        $this->post('/dashboard/posts', [])->assertRedirect('/login');
    }

    public function test_bcrypt_and_argon_users_can_log_in_and_out()
    {
        // argon2id where PHP and Laravel have it, argon2i on 7.2, none before
        $second = Passwords::second();
        $users = [['bcrypt', 'bcrypt', 1]];
        if ($second) {
            $users[] = [$second['driver'], $second['algo'], 2];
        }
        foreach ($users as $one) {
            list($driver, $algo, $n) = $one;
            $user = $this->makeUser($n, $driver);
            $this->post('/login', ['email' => $user->email, 'password' => Content::password($n)])->assertRedirect('/dashboard');
            $this->get('/dashboard')->assertStatus(200)->assertSee($user->email)->assertSee($algo);
            $this->post('/logout')->assertRedirect('/');
            $this->get('/dashboard')->assertRedirect('/login');
        }
    }

    public function test_wrong_password_is_rejected()
    {
        $user = $this->makeUser(1);
        $this->post('/login', ['email' => $user->email, 'password' => 'nope'])->assertRedirect('/login')->assertSessionHasErrors('email');
        $this->assertGuest();
    }

    public function test_creating_a_post_validates_stores_and_fires_the_event()
    {
        $user = $this->makeUser(1);
        Event::fake([PostCreated::class]);
        $this->actingAs($user);
        $this->post('/dashboard/posts', ['title' => '', 'body' => 'short'])->assertSessionHasErrors(['title', 'body']);
        $this->postJson('/dashboard/posts', ['title' => 'x', 'body' => 'short'])->assertStatus(422)->assertJsonValidationErrors(['body']);
        $this->post('/dashboard/posts', ['title' => 'Заголовок поста', 'body' => 'Достаточно длинный текст записи'])->assertRedirect();
        $this->assertSame(1, Post::where('user_id', $user->id)->count());
        Event::assertDispatched(PostCreated::class);
    }
}
