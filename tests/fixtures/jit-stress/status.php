<?php
$s = opcache_get_status(false);
echo json_encode([
    'jit' => isset($s['jit']) ? $s['jit'] : null,
    'stats' => $s['opcache_statistics'],
    'full' => $s['cache_full'],
    'memory' => $s['memory_usage'],
]);
