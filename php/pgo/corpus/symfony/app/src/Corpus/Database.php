<?php

namespace App\Corpus;

use PDO;

class Database
{
    /** @var string */
    private $dsn;

    /** @var PDO|null */
    private $pdo;

    public function __construct(string $dsn)
    {
        $this->dsn = $dsn;
    }

    public function pdo(): PDO
    {
        if (null === $this->pdo) {
            $this->pdo = new PDO($this->dsn, null, null, [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            ]);
        }

        return $this->pdo;
    }

    public function articles(int $limit): array
    {
        $stmt = $this->pdo()->prepare(
            'SELECT a.id, a.title, a.slug, a.body, a.published_at,
                    (SELECT COUNT(*) FROM comment c WHERE c.article_id = a.id) AS comment_count
             FROM article a ORDER BY a.published_at DESC LIMIT :limit'
        );
        $stmt->bindValue(':limit', $limit, PDO::PARAM_INT);
        $stmt->execute();

        return $stmt->fetchAll();
    }

    public function article($id)
    {
        $stmt = $this->pdo()->prepare('SELECT * FROM article WHERE id = :id');
        $stmt->bindValue(':id', $id, PDO::PARAM_INT);
        $stmt->execute();
        $row = $stmt->fetch();

        return false === $row ? null : $row;
    }

    public function comments(int $articleId): array
    {
        $stmt = $this->pdo()->prepare(
            'SELECT author, body, created_at FROM comment WHERE article_id = :id ORDER BY created_at'
        );
        $stmt->bindValue(':id', $articleId, PDO::PARAM_INT);
        $stmt->execute();

        return $stmt->fetchAll();
    }
}
