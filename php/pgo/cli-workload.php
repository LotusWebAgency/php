<?php
/*
 * The CLI half of the PGO training workload (task 17), run by php/pgo/train.sh
 * against the instrumented binary from pass 1.
 *
 * Why this file exists rather than a framework console command: the corpus's
 * tested contract is its HTTP manifest -- corpus/verify.sh proves those paths
 * serve, and tests/test-corpus-tiers.sh proves they serve on every PHP in the
 * tier. Nothing has ever checked that Laravel 6's artisan runs on PHP 8.0, so
 * requiring it in a training run that is not allowed to fail quietly would
 * fail builds for reasons that have nothing to do with the compiler. This file
 * is ours, is committed, and its absence is fatal in train.sh.
 *
 * PHP 7.0 syntax, deliberately: it has to run unchanged on every version in
 * matrix.json. No scalar type hints, no return types, no ??=, no arrow fns.
 *
 * Only extensions every image is required to carry are used -- core, pcre,
 * json, hash, mbstring, pdo_sqlite. If one of them is missing this dies with a
 * fatal error and the build stops, which is the correct outcome: a php image
 * without pdo_sqlite is broken whether or not PGO is involved.
 *
 * What it is meant to weight, in the order a `composer install` or an
 * `artisan` invocation spends its time: CLI SAPI startup and shutdown (5 runs,
 * not 1, so the startup path is not a rounding error), the VM's arithmetic and
 * string opcodes, hash table growth and lookup, string building and formatting,
 * preg, json encode/decode, serialize round-trips, sorting, userland function
 * and method dispatch including a magic call, exception throw/catch, closures,
 * and a real PDO sqlite prepare/execute/fetch loop against an in-memory
 * database.
 */

$scale = getenv('PGO_CLI_SCALE');
$scale = ($scale === false || (int) $scale < 1) ? 1 : (int) $scale;

$checks = array();

// --- VM: arithmetic, branches, loops ---------------------------------------
$sum = 0;
for ($i = 0; $i < 400000 * $scale; $i++) {
    $sum += ($i % 7) * 3 - ($i & 15);
    if (($i & 1023) === 0) {
        $sum ^= $i;
    }
}
$checks['arith'] = $sum;

// --- Hash tables: insert, lookup, delete, iterate ---------------------------
$map = array();
for ($i = 0; $i < 60000 * $scale; $i++) {
    $map['key-' . $i] = $i * 2;
}
$hits = 0;
for ($i = 0; $i < 60000 * $scale; $i++) {
    if (isset($map['key-' . $i])) {
        $hits += $map['key-' . $i] & 1;
    }
}
for ($i = 0; $i < 60000 * $scale; $i += 3) {
    unset($map['key-' . $i]);
}
$walk = 0;
foreach ($map as $k => $v) {
    $walk += strlen($k) + $v;
}
$checks['hash'] = $hits + $walk + count($map);

// --- Strings: concat, interpolation, sprintf, case, substr, explode ---------
$buf = '';
$words = array();
for ($i = 0; $i < 40000 * $scale; $i++) {
    $piece = sprintf('%05d:%s;', $i, strtoupper(substr(md5((string) $i), 0, 8)));
    $buf .= $piece;
    if (($i % 500) === 0) {
        $words[] = trim($piece, ';');
    }
}
$parts = explode(';', $buf);
$checks['string'] = strlen($buf) + count($parts) + count($words);

// --- pcre -------------------------------------------------------------------
$matched = 0;
$re = '/^(?P<num>\d{5}):(?P<hex>[0-9A-F]{8})$/';
foreach ($words as $w) {
    if (preg_match($re, $w, $m)) {
        $matched += hexdec(substr($m['hex'], 0, 4)) & 0xff;
    }
}
$replaced = preg_replace('/[0-9]{3}/', '#', substr($buf, 0, 200000));
$checks['pcre'] = $matched + strlen($replaced);

// --- json + serialize -------------------------------------------------------
$rows = array();
for ($i = 0; $i < 4000 * $scale; $i++) {
    $rows[] = array(
        'id' => $i,
        'name' => 'row-' . $i,
        'tags' => array('a', 'b', 'c'),
        'meta' => array('score' => $i / 3.0, 'ok' => ($i & 1) === 0, 'note' => null),
    );
}
$json = json_encode($rows);
$back = json_decode($json, true);
$blob = serialize($rows);
$unblob = unserialize($blob);
$checks['json'] = strlen($json) + count($back) + strlen($blob) + count($unblob);

// --- sorting ----------------------------------------------------------------
$nums = array();
for ($i = 0; $i < 50000 * $scale; $i++) {
    $nums[] = ($i * 2654435761) % 1000003;
}
sort($nums);
usort($rows, function ($a, $b) {
    return strcmp($b['name'], $a['name']);
});
$checks['sort'] = $nums[0] + $nums[count($nums) - 1] + count($rows);

// --- userland dispatch: functions, methods, magic, closures, exceptions ------
class CorpusNode
{
    private $value;
    private $children = array();

    public function __construct($value)
    {
        $this->value = $value;
    }

    public function add(CorpusNode $child)
    {
        $this->children[] = $child;
        return $this;
    }

    public function total()
    {
        $t = $this->value;
        foreach ($this->children as $c) {
            $t += $c->total();
        }
        return $t;
    }

    public function __call($name, $args)
    {
        return $name . ':' . count($args);
    }
}

function corpus_fib($n)
{
    return $n < 2 ? $n : corpus_fib($n - 1) + corpus_fib($n - 2);
}

$root = new CorpusNode(1);
for ($i = 0; $i < 200 * $scale; $i++) {
    $branch = new CorpusNode($i);
    for ($j = 0; $j < 20; $j++) {
        $branch->add(new CorpusNode($j));
    }
    $root->add($branch);
}
$dispatch = 0;
for ($i = 0; $i < 20000 * $scale; $i++) {
    $dispatch += strlen($root->undefinedMethod($i, $i + 1));
}
$adder = function ($x) use (&$dispatch) {
    return $x + ($dispatch & 7);
};
for ($i = 0; $i < 50000 * $scale; $i++) {
    $dispatch += $adder($i) & 3;
}
$caught = 0;
for ($i = 0; $i < 20000 * $scale; $i++) {
    try {
        if (($i % 3) === 0) {
            throw new RuntimeException('corpus ' . $i);
        }
    } catch (RuntimeException $e) {
        $caught += strlen($e->getMessage());
    }
}
$checks['dispatch'] = $root->total() + $dispatch + $caught + corpus_fib(20 + ($scale > 1 ? 2 : 0));

// --- pdo_sqlite: prepare, bind, execute, fetch ------------------------------
$pdo = new PDO('sqlite::memory:', null, null, array(PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION));
$pdo->exec('CREATE TABLE corpus (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL NOT NULL)');
$pdo->beginTransaction();
$insert = $pdo->prepare('INSERT INTO corpus (name, score) VALUES (:name, :score)');
for ($i = 0; $i < 5000 * $scale; $i++) {
    $insert->execute(array(':name' => 'row-' . $i, ':score' => $i / 7.0));
}
$pdo->commit();
$select = $pdo->prepare('SELECT id, name, score FROM corpus WHERE score > :floor ORDER BY score DESC LIMIT 50');
$fetched = 0;
for ($i = 0; $i < 400 * $scale; $i++) {
    $select->execute(array(':floor' => $i));
    foreach ($select->fetchAll(PDO::FETCH_ASSOC) as $row) {
        $fetched += strlen($row['name']);
    }
}
$checks['pdo'] = (int) $pdo->query('SELECT COUNT(*) FROM corpus')->fetchColumn() + $fetched;

// --- hash + mbstring --------------------------------------------------------
$digest = '';
for ($i = 0; $i < 5000 * $scale; $i++) {
    $digest = hash('sha256', $digest . $i);
}
$mb = 0;
$text = 'Ünïcödé PGO tráining còrpus — ' . str_repeat('αβγδε ', 200);
for ($i = 0; $i < 5000 * $scale; $i++) {
    $mb += mb_strlen($text) + strlen(mb_substr($text, $i % 50, 20));
}
$checks['digest'] = strlen($digest) + $mb;

// Every stage has to have produced something. A stage that silently degraded
// to a no-op -- an empty result set, a regex that never matched -- would still
// let this script exit 0 and would still let train.sh call it a success, which
// is the same false green the `|| true` idiom this task removed produced.
foreach ($checks as $name => $value) {
    if (!is_int($value) && !is_float($value)) {
        fwrite(STDERR, "stage $name produced a non-numeric result\n");
        exit(1);
    }
    if ($value <= 0) {
        fwrite(STDERR, "stage $name produced $value -- it did no work\n");
        exit(1);
    }
}

echo 'CLI-WORKLOAD-OK ', count($checks), ' stages', PHP_EOL;
