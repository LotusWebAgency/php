<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

class CreateBlogTables extends Migration
{
    public function up()
    {
        Schema::create('posts', function (Blueprint $table) {
            $table->bigIncrements('id');
            $table->unsignedBigInteger('user_id');
            $table->string('title');
            $table->string('slug', 191)->unique();
            $table->string('excerpt', 500);
            $table->longText('body');
            $table->unsignedInteger('views')->default(0);
            $table->timestamp('published_at')->nullable()->index();
            $table->timestamps();
            $table->foreign('user_id')->references('id')->on('users');
        });

        Schema::create('comments', function (Blueprint $table) {
            $table->bigIncrements('id');
            $table->unsignedBigInteger('post_id')->index();
            $table->unsignedBigInteger('user_id')->nullable();
            $table->string('author', 100);
            $table->text('body');
            $table->timestamps();
            $table->foreign('post_id')->references('id')->on('posts')->onDelete('cascade');
        });

        Schema::create('tags', function (Blueprint $table) {
            $table->bigIncrements('id');
            $table->string('name', 100);
            $table->string('slug', 120)->unique();
        });

        Schema::create('post_tag', function (Blueprint $table) {
            $table->unsignedBigInteger('post_id');
            $table->unsignedBigInteger('tag_id')->index();
            $table->primary(['post_id', 'tag_id']);
            $table->foreign('post_id')->references('id')->on('posts')->onDelete('cascade');
            $table->foreign('tag_id')->references('id')->on('tags')->onDelete('cascade');
        });

        Schema::create('media', function (Blueprint $table) {
            $table->bigIncrements('id');
            $table->unsignedBigInteger('user_id')->nullable();
            $table->string('disk', 20);
            $table->string('path');
            $table->string('original_name');
            $table->string('mime', 100);
            $table->unsignedInteger('size');
            $table->text('meta')->nullable();
            $table->timestamps();
        });

        Schema::create('job_log', function (Blueprint $table) {
            $table->bigIncrements('id');
            $table->string('kind', 40);
            $table->string('token', 64)->index();
            $table->text('payload')->nullable();
            $table->timestamp('created_at')->nullable();
        });
    }

    public function down()
    {
        foreach (['job_log', 'media', 'post_tag', 'tags', 'comments', 'posts'] as $t) {
            Schema::dropIfExists($t);
        }
    }
}
