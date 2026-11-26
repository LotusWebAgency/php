<?php
$dir = __DIR__;
$e = require $dir . '/expect.php';
mt_srand((int) $_SERVER['X_SEED']);
for ($j = 0; $j < 6; $j++) {
    $i = mt_rand(0, $e['files'] - 1);
    require_once $dir . "/f$i.php";
    $fn = "jit_f$i";
    $got = $fn($e['iter'], $i + 7);
    if ($got !== $e['want'][$i]) {
        http_response_code(500);
        echo "BAD f$i got=$got want={$e['want'][$i]}";
        exit;
    }
}
echo 'OK';
