<?php

namespace App\Controller;

use App\Corpus\Database;
use Symfony\Bundle\FrameworkBundle\Controller\AbstractController;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Response;

class CorpusController extends AbstractController
{
    /** @var Database */
    private $db;

    public function __construct(Database $db)
    {
        $this->db = $db;
    }

    public function index(): Response
    {
        return $this->render('index.html.twig', [
            'articles' => $this->db->articles(20),
        ]);
    }

    public function article(int $id): Response
    {
        $article = $this->db->article($id);
        if (null === $article) {
            throw $this->createNotFoundException('no such article');
        }

        return $this->render('article.html.twig', [
            'article' => $article,
            'comments' => $this->db->comments($id),
        ]);
    }

    public function apiArticles(): JsonResponse
    {
        return new JsonResponse(['articles' => $this->db->articles(50)]);
    }
}
