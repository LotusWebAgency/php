<?php
declare(strict_types=1);

// Framework-shaped, not microbenchmark-shaped: autoloading-ish string
// building, array/collection manipulation, both directions of
// serialization, and routing-ish regex -- what a request actually spends
// its time on. This is the held-out workload; a number pulled from the PGO
// training corpus apps is a different, optimistic measurement and must be
// labeled as such wherever it's quoted.
//
// Two call shapes:
//   php workload.php fingerprint   -> print the settings fingerprint (JSON,
//                                     one line, stdout) and exit; no timing.
//   php workload.php <iterations>  -> run the workload <iterations> times
//                                     and print elapsed wall time in
//                                     seconds (stdout, one line, 6dp).
//
// bench.sh calls fingerprint mode once per image per mode to prove both
// sides are running an identical effective configuration before it
// trusts any timing from this file. The fingerprint carries the full
// ini_get_all() dump for opcache and pcre (every jit_*, memory/interned/
// accelerated_files/wasted/validate_timestamps/revalidate_freq/optimization_
// level/file_cache directive included) plus the handful of core directives
// ini_get_all() can't group by extension (memory_limit, zend.assertions,
// zend.enable_gc, realpath_cache_size/ttl, output_buffering), so any ini
// setting able to move a CPU-bound number is compared, not just the ones
// bench.sh happens to pass explicitly on the command line.

// ini_get_all()'s $extension argument takes the extension's registry name,
// not its display name -- "zend opcache" (lowercase) is what actually
// resolves; "Zend OPcache", the string get_loaded_extensions() returns, does
// not. Returns [] when the extension isn't loaded at all instead of raising
// a warning, so a mode that genuinely has no opcache (shouldn't happen --
// every mode loads it, enable=0 just idles it) still fingerprints cleanly.
function iniGroup(string $extension): array
{
    if (!extension_loaded($extension)) {
        return [];
    }
    $values = ini_get_all($extension, false) ?: [];
    ksort($values);

    return $values;
}

// PHP has no "Core" extension name ini_get_all() will accept, so the
// core/session directives that can move a CPU-bound number are read
// individually instead of grouped.
function coreIni(): array
{
    $names = [
        'memory_limit',
        'zend.assertions',
        'zend.enable_gc',
        'realpath_cache_size',
        'realpath_cache_ttl',
        'output_buffering',
    ];
    $out = [];
    foreach ($names as $name) {
        $out[$name] = ini_get($name);
    }

    return $out;
}

function fingerprint(): array
{
    $status = function_exists('opcache_get_status') ? @opcache_get_status(false) : false;
    $jit = (is_array($status) && isset($status['jit']) && is_array($status['jit'])) ? $status['jit'] : null;

    $modules = get_loaded_extensions(false);
    $zendExts = get_loaded_extensions(true);
    $allExtensions = array_values(array_unique(array_merge($modules, $zendExts)));
    sort($allExtensions, SORT_STRING);

    return [
        'php_version' => PHP_VERSION,
        // Whether opcache is actually accelerating this SAPI right now --
        // not just "the module is loaded", which on 8.5 it always is
        // (opcache is compiled into the engine, ini.enable off just means
        // idle). opcache_get_status() returns false when the accelerator
        // is disabled.
        'opcache_enabled' => $status !== false,
        'jit_on' => $jit !== null ? (bool)($jit['on'] ?? false) : false,
        'jit_kind' => $jit['kind'] ?? null,
        'jit_opt_level' => $jit['opt_level'] ?? null,
        // Full ini_get_all() dumps for the three extensions that own every
        // directive able to move this workload's wall time, compared
        // key-for-key by bench.sh -- not a hand-picked subset, so a knob
        // nobody thought to name explicitly still gets caught.
        'opcache_ini' => iniGroup('zend opcache'),
        'pcre_ini' => iniGroup('pcre'),
        'core_ini' => coreIni(),
        // Printed for the diff, not compared field-for-field by bench.sh --
        // ours ships more extensions by design.
        'extensions' => $allExtensions,
    ];
}

$arg = $argv[1] ?? 'fingerprint';

if ($arg === 'fingerprint') {
    echo json_encode(fingerprint(), JSON_UNESCAPED_SLASHES), "\n";
    exit(0);
}

$iterations = (int)$arg;
if ($iterations <= 0) {
    fwrite(STDERR, "usage: workload.php fingerprint | workload.php <iterations>\n");
    exit(1);
}

// Written to run unchanged on every version matrix.json ships (7.0-8.5): no
// arrow functions (7.4+), no str_contains (8.0+), and hrtime (7.3+) with a
// microtime fallback, so a legacy row measures the same code as a modern one.
$clock = function_exists('hrtime')
    ? static function () { return hrtime(true) / 1e9; }
    : static function () { return microtime(true); };
$start = $clock();

for ($i = 0; $i < $iterations; $i++) {
    // template-ish string building
    $out = '';
    for ($j = 0; $j < 500; $j++) {
        $out .= sprintf('<li class="item-%d">%s</li>', $j, htmlspecialchars("row {$j} & co"));
    }

    // collection-ish array work
    $rows = [];
    for ($j = 0; $j < 1000; $j++) {
        $rows[] = ['id' => $j, 'name' => "name{$j}", 'tags' => ['a', 'b', 'c']];
    }
    usort($rows, static function ($a, $b) { return $b['id'] <=> $a['id']; });
    $names = array_column($rows, 'name', 'id');
    $filtered = array_filter($names, static function ($n) { return strpos($n, '7') !== false; });

    // serialization, both directions
    $blob = serialize($rows);
    $back = unserialize($blob);
    $json = json_encode($rows);
    json_decode($json, true);

    // routing-ish regex
    foreach (['/users/42/posts', '/api/v1/orders', '/'] as $path) {
        preg_match('#^/(?P<seg>[a-z0-9]+)(?:/(?P<id>\d+))?(?:/(?P<sub>[a-z]+))?$#', $path, $m);
    }

    unset($out, $rows, $names, $filtered, $blob, $back, $json, $m);
}

$elapsed = $clock() - $start;
printf("%.6f\n", $elapsed);
