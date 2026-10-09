<?php

// Named class, not the anonymous `return new class extends Migration`: the
// anonymous form only works from Laravel 8 on, and this file has to migrate on
// every tier from 5.5 up. The rows are generated here rather than by a seeder
// because database/seeds (5.x) and database/seeders (8+) are different paths
// with different namespaces, and `artisan migrate` is one command on all of
// them.
//
// Same generator, same row count and same text as the Symfony corpus'
// bin/seed.php: two corpora built from this tree hold the same data, so a
// difference between two PGO profiles is the compiler's doing and not the
// fixtures'.

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

class CreateCorpusTables extends Migration
{
    public function up()
    {
        Schema::create('corpus_articles', function (Blueprint $table) {
            $table->increments('id');
            $table->string('title');
            $table->string('slug');
            $table->text('body');
            $table->string('published_at');
        });

        Schema::create('corpus_comments', function (Blueprint $table) {
            $table->increments('id');
            $table->unsignedInteger('article_id')->index();
            $table->string('author');
            $table->text('body');
            $table->string('created_at');
        });

        $words = array('lorem', 'ipsum', 'dolor', 'sit', 'amet', 'consectetur', 'adipiscing', 'elit',
                       'sed', 'eiusmod', 'tempor', 'incididunt', 'labore', 'magna', 'aliqua', 'enim');

        $articles = array();
        $comments = array();
        for ($i = 1; $i <= 50; ++$i) {
            $title = ucfirst($words[$i % 16]).' '.$words[($i * 3) % 16].' '.$i;
            $body = '';
            for ($w = 0; $w < 120; ++$w) {
                $body .= $words[($i * 7 + $w * 5) % 16].' ';
            }
            $articles[] = array(
                'id' => $i,
                'title' => $title,
                'slug' => strtolower(str_replace(' ', '-', $title)),
                'body' => trim($body),
                'published_at' => sprintf('2026-%02d-%02d 12:00:00', 1 + $i % 12, 1 + $i % 28),
            );
            for ($c = 0; $c < 10; ++$c) {
                $comments[] = array(
                    'article_id' => $i,
                    'author' => 'commenter'.$c,
                    'body' => $words[($i + $c) % 16].' '.$words[($i * 2 + $c) % 16].' '.$words[($i + $c * 3) % 16],
                    'created_at' => sprintf('2026-%02d-%02d 13:%02d:00', 1 + $i % 12, 1 + $i % 28, $c * 5),
                );
            }
        }

        foreach (array_chunk($articles, 25) as $chunk) {
            DB::table('corpus_articles')->insert($chunk);
        }
        foreach (array_chunk($comments, 100) as $chunk) {
            DB::table('corpus_comments')->insert($chunk);
        }
    }

    public function down()
    {
        Schema::dropIfExists('corpus_comments');
        Schema::dropIfExists('corpus_articles');
    }
}
