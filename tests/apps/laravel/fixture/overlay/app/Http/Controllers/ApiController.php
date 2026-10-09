<?php

namespace App\Http\Controllers;

use App\Apptest\Goldens;
use App\Models\Post;
use Illuminate\Http\Request;

class ApiController extends Controller
{
    public function posts(Request $request)
    {
        $perPage = min(100, max(1, (int) $request->query('per_page', 15)));
        $page = Post::forApi()->orderBy('id')->paginate($perPage);

        return response()->json([
            'data' => $page->getCollection()->map(function ($p) {
                return $p->toApi();
            })->all(),
            'meta' => [
                'current_page' => $page->currentPage(),
                'last_page' => $page->lastPage(),
                'per_page' => $page->perPage(),
                'total' => $page->total(),
            ],
        ], 200, [], JSON_UNESCAPED_UNICODE);
    }

    public function post($id)
    {
        return response()->json(Post::forApi()->findOrFail($id)->toApi(true), 200, [], JSON_UNESCAPED_UNICODE);
    }

    public function search(Request $request)
    {
        $q = trim((string) $request->query('q', ''));
        $page = Post::search($q)->orderBy('id')->paginate(15);

        return response()->json([
            'q' => $q,
            'total' => $page->total(),
            'ids' => $page->getCollection()->pluck('id')->all(),
        ], 200, [], JSON_UNESCAPED_UNICODE);
    }

    public function golden()
    {
        $manifest = json_decode(file_get_contents(base_path('.apptest/manifest.json')), true);

        return response()->json(Goldens::compute($manifest['blobs']));
    }

    public function info()
    {
        $opcache = function_exists('opcache_get_status') ? @opcache_get_status(false) : false;
        $ini = [];
        foreach (['memory_limit', 'opcache.enable', 'opcache.jit', 'opcache.jit_buffer_size', 'disable_functions', 'pcre.jit', 'zend.assertions', 'serialize_precision', 'date.timezone', 'apc.enabled'] as $k) {
            $ini[$k] = ini_get($k);
        }

        return response()->json([
            'php' => PHP_VERSION,
            'sapi' => PHP_SAPI,
            'zts' => PHP_ZTS,
            'os' => PHP_OS,
            'extensions' => array_map('strtolower', get_loaded_extensions()),
            'opcache' => $opcache ? [
                'enabled' => $opcache['opcache_enabled'],
                'cached_scripts' => $opcache['opcache_statistics']['num_cached_scripts'] ?? null,
                'hits' => $opcache['opcache_statistics']['hits'] ?? null,
                'jit_enabled' => $opcache['jit']['enabled'] ?? false,
                'jit_on' => $opcache['jit']['on'] ?? false,
            ] : null,
            'ini' => $ini,
            'laravel' => app()->version(),
            'env' => app()->environment(),
            'config_cached' => app()->configurationIsCached(),
            'routes_cached' => app()->routesAreCached(),
            'memory_peak' => memory_get_peak_usage(true),
        ]);
    }

    public function boom()
    {
        throw new \RuntimeException('apptest: deliberate failure');
    }
}
