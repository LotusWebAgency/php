<?php
header('Content-Type: application/json');
$ini = [];
foreach (['opcache.jit', 'opcache.jit_buffer_size', 'opcache.memory_consumption', 'opcache.interned_strings_buffer',
          'opcache.enable', 'opcache.validate_timestamps', 'opcache.revalidate_freq', 'opcache.huge_code_pages', 'opcache.preload',
          'memory_limit'] as $k) {
    $v = ini_get($k);
    if ($v !== false) {
        $ini[$k] = $v;
    }
}
$s = function_exists('opcache_get_status') ? @opcache_get_status(false) : false;
$s = is_array($s) ? $s : [];
echo json_encode([
    'php' => PHP_VERSION,
    'ini' => $ini,
    'opcache_enabled' => !empty($s['opcache_enabled']),
    'jit' => $s['jit'] ?? null,
    'opcache' => [
        'scripts' => $s['opcache_statistics']['num_cached_scripts'] ?? null,
        'hits' => $s['opcache_statistics']['hits'] ?? null,
        'misses' => $s['opcache_statistics']['misses'] ?? null,
        'oom_restarts' => $s['opcache_statistics']['oom_restarts'] ?? null,
        'cache_full' => $s['cache_full'] ?? null,
        'mem_used' => $s['memory_usage']['used_memory'] ?? null,
        'mem_free' => $s['memory_usage']['free_memory'] ?? null,
        'mem_wasted' => $s['memory_usage']['wasted_memory'] ?? null,
    ],
]);
