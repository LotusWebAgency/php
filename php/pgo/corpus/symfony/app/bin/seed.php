<?php
// Deterministic corpus data: same rows on every rebuild, so two PGO profiles
// taken from two builds of the same corpus differ only by what the compiler did.

$dir = dirname(__DIR__).'/var';
if (!is_dir($dir) && !mkdir($dir, 0775, true) && !is_dir($dir)) {
    fwrite(STDERR, "FATAL: cannot create $dir\n");
    exit(1);
}

$path = $dir.'/corpus.sqlite';
@unlink($path);

$pdo = new PDO('sqlite:'.$path, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$pdo->exec('CREATE TABLE article (
    id INTEGER PRIMARY KEY, title TEXT NOT NULL, slug TEXT NOT NULL,
    body TEXT NOT NULL, published_at TEXT NOT NULL)');
$pdo->exec('CREATE TABLE comment (
    id INTEGER PRIMARY KEY, article_id INTEGER NOT NULL, author TEXT NOT NULL,
    body TEXT NOT NULL, created_at TEXT NOT NULL)');
$pdo->exec('CREATE INDEX comment_article ON comment (article_id)');

$words = ['lorem', 'ipsum', 'dolor', 'sit', 'amet', 'consectetur', 'adipiscing', 'elit',
          'sed', 'eiusmod', 'tempor', 'incididunt', 'labore', 'magna', 'aliqua', 'enim'];

$article = $pdo->prepare('INSERT INTO article (id, title, slug, body, published_at) VALUES (?, ?, ?, ?, ?)');
$comment = $pdo->prepare('INSERT INTO comment (article_id, author, body, created_at) VALUES (?, ?, ?, ?)');

$pdo->beginTransaction();
for ($i = 1; $i <= 50; ++$i) {
    $title = ucfirst($words[$i % 16]).' '.$words[($i * 3) % 16].' '.$i;
    $body = '';
    for ($w = 0; $w < 120; ++$w) {
        $body .= $words[($i * 7 + $w * 5) % 16].' ';
    }
    $article->execute([$i, $title, strtolower(str_replace(' ', '-', $title)), trim($body),
        sprintf('2026-%02d-%02d 12:00:00', 1 + $i % 12, 1 + $i % 28)]);

    for ($c = 0; $c < 10; ++$c) {
        $comment->execute([$i, 'commenter'.$c,
            $words[($i + $c) % 16].' '.$words[($i * 2 + $c) % 16].' '.$words[($i + $c * 3) % 16],
            sprintf('2026-%02d-%02d 13:%02d:00', 1 + $i % 12, 1 + $i % 28, $c * 5)]);
    }
}
$pdo->commit();

$n = $pdo->query('SELECT COUNT(*) FROM article')->fetchColumn();
$m = $pdo->query('SELECT COUNT(*) FROM comment')->fetchColumn();
if (50 != $n || 500 != $m) {
    fwrite(STDERR, "FATAL: seeded $n articles and $m comments, expected 50 and 500\n");
    exit(1);
}
echo "seeded $n articles, $m comments into $path\n";
