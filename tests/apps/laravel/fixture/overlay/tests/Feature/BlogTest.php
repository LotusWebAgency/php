<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\Concerns\MakesBlog;
use Tests\TestCase;

class BlogTest extends TestCase
{
    use MakesBlog, RefreshDatabase;

    public function test_home_lists_posts_newest_first_with_pagination()
    {
        $user = $this->makeUser();
        for ($i = 1; $i <= 15; $i++) {
            $this->makePost($user, $i);
        }
        $r = $this->get('/');
        $r->assertStatus(200)->assertSee('15 posts', false)->assertSee(e(\App\Apptest\Content::title(15)), false);
        $r->assertDontSee(e(\App\Apptest\Content::title(1)), false);
        $this->get('/?page=2')->assertStatus(200)->assertSee(e(\App\Apptest\Content::title(1)), false);
    }

    public function test_post_page_shows_comments_and_tags()
    {
        $user = $this->makeUser();
        $tag = $this->makeTag(1);
        $post = $this->makePost($user, 2, [$tag->id]);
        $this->makeComment($post, 1);
        $this->get('/posts/'.$post->slug)->assertStatus(200)->assertSee('1 comments', false)->assertSee($tag->slug, false);
        $this->get('/tags/'.$tag->slug)->assertStatus(200)->assertSee(e($post->title), false);
        $this->get('/posts/no-such-post')->assertStatus(404);
    }

    public function test_search_matches_utf8_case_insensitively()
    {
        $user = $this->makeUser();
        $post = $this->makePost($user, 1);
        $word = mb_substr($post->title, 0, 4);
        $this->get('/search?q='.rawurlencode(mb_strtoupper($word)))->assertStatus(200)->assertSee(e($post->title), false);
        $this->get('/search?q=zzzz-not-there')->assertStatus(200)->assertSee('0 results', false);
    }

    public function test_api_returns_the_documented_shape()
    {
        $user = $this->makeUser();
        $post = $this->makePost($user, 3);
        $this->makeComment($post, 2);
        // assertJsonPath() is 6/7+; assertJson() takes the same subset before it.
        $this->getJson('/api/posts/'.$post->id)->assertStatus(200)->assertJsonStructure(['id', 'slug', 'title', 'body', 'author' => ['id', 'name'], 'tags', 'comments'])
            ->assertJson(['comments_count' => 1]);
        $this->getJson('/api/posts')->assertStatus(200)->assertJson(['meta' => ['total' => 1]]);
        $this->getJson('/api/posts/999999')->assertStatus(404);
    }

    public function test_comment_form_validates_and_stores()
    {
        $post = $this->makePost($this->makeUser(), 4);
        $this->post('/posts/'.$post->slug.'/comments', ['author' => '', 'body' => 'x'])->assertSessionHasErrors(['author', 'body']);
        $this->post('/posts/'.$post->slug.'/comments', ['author' => 'Иван', 'body' => 'Отличный пост'])->assertRedirect('/posts/'.$post->slug.'#comments');
        $this->assertSame(1, $post->comments()->count());
    }

    public function test_unhandled_exception_renders_laravels_error_response()
    {
        $this->getJson('/api/boom')->assertStatus(500)->assertJson(['message' => 'Server Error']);
    }
}
