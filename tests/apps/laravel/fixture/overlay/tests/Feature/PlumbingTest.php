<?php

namespace Tests\Feature;

use App\Jobs\QueuedJob;
use App\Mail\PostDigest;
use App\Models\Media;
use Carbon\Carbon;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Facades\Queue;
use Illuminate\Support\Facades\Storage;
use Tests\Concerns\MakesBlog;
use Tests\TestCase;

class PlumbingTest extends TestCase
{
    use MakesBlog, RefreshDatabase;

    public function test_mail_renders_and_is_sent_through_the_array_transport()
    {
        $post = $this->makePost($this->makeUser(), 1);
        $post = \App\Models\Post::forApi()->find($post->id);
        $html = (new PostDigest(collect([$post])))->render();
        $this->assertTrue(strpos($html, e($post->title)) !== false);

        Mail::fake();
        Mail::to('reader@apptest.test')->send(new PostDigest(collect([$post])));
        Mail::assertSent(PostDigest::class, function ($m) {
            return $m->hasTo('reader@apptest.test');
        });
    }

    public function test_queued_job_carries_a_model_and_a_carbon_through_the_payload()
    {
        $post = $this->makePost($this->makeUser(), 1);
        Queue::fake();
        QueuedJob::dispatch($post, Carbon::create(2024, 1, 1, 0, 0, 0, 'UTC'), 't', ['k' => 'значение'])->onQueue('web');
        Queue::assertPushedOn('web', QueuedJob::class);

        $job = new QueuedJob($post, Carbon::create(2024, 1, 1, 0, 0, 0, 'UTC'), 'real', ['k' => 'значение']);
        $copy = unserialize(serialize($job));
        $this->assertSame($post->id, $copy->post->id);
        $this->assertSame('2024-01-01', $copy->when->toDateString());
        $copy->handle();
        $this->assertDatabaseHas('job_log', ['kind' => 'queued', 'token' => 'real']);
    }

    public function test_image_upload_goes_through_gd_and_imagick()
    {
        Storage::fake('local');
        $r = $this->post('/api/features/upload', ['image' => UploadedFile::fake()->image('pic.png', 64, 48)]);
        $r->assertStatus(200)->assertJson(['original' => ['width' => 64], 'gd_jpeg' => ['width' => 32], 'gd_rotated' => ['width' => 48],
            'imagick_jpeg' => ['width' => 24], 'imagick_reads_gd' => ['format' => 'JPEG']]);
        $this->assertSame(1, Media::count());
        Storage::disk('local')->assertExists(Media::first()->path.'/gd.jpg');
    }

    public function test_upload_rejects_non_images()
    {
        Storage::fake('local');
        $this->postJson('/api/features/upload', ['image' => UploadedFile::fake()->create('x.pdf', 10, 'application/pdf')])->assertStatus(422);
    }

    public function test_cache_stores_that_need_no_services()
    {
        foreach (['array', 'file'] as $store) {
            $c = \Illuminate\Support\Facades\Cache::store($store);
            $c->put('k', ['a' => 'я'], 60);
            $this->assertSame(['a' => 'я'], $c->get('k'));
            $this->assertSame(3, $c->increment('n', 3));
        }
    }
}
