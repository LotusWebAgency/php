<?php
// Every seeded account's password against the hash the stock PHP stored:
// bcrypt for most, phpass for the one legacy account. Prints ok:/FAIL: lines
// for suite/cli.sh (wp eval-file users.php).
$m = json_decode(file_get_contents(ABSPATH . '.apptest/manifest.json'), true);
$formats = [];
foreach ($m['users'] as $u) {
    $user = get_user_by('login', $u['login']);
    $hash = $user ? $user->user_pass : '';
    $formats[substr($hash, 0, 4)] = true;
    $good = $user && wp_check_password($u['password'], $hash, $user->ID);
    echo ($good ? 'ok' : 'FAIL') . ": password of {$u['login']} ({$u['role']}) verifies against its stored " . substr($hash, 0, 4) . " hash\n";
    if ($good && wp_check_password($u['password'] . 'x', $hash, $user->ID)) {
        echo "FAIL: password of {$u['login']} also accepts a wrong password\n";
    }
}
$legacy = get_user_by('login', $m['legacy_hash_user']);
echo (str_starts_with($legacy->user_pass, '$P$') ? 'ok' : 'FAIL') . ": {$m['legacy_hash_user']} still carries a phpass hash\n";
// WordPress switched its default hash to bcrypt in 6.8.
$bcrypt = version_compare($GLOBALS['wp_version'], '6.8', '>=');
if ($bcrypt) {
    echo (wp_password_needs_rehash($legacy->user_pass, $legacy->ID) ? 'ok' : 'FAIL') . ": a phpass hash is flagged for rehash\n";
}
$fresh = wp_hash_password('Ünï 🚀 password');
echo (wp_check_password('Ünï 🚀 password', $fresh) && !wp_check_password('Ünï 🚀 passworD', $fresh) ? 'ok' : 'FAIL') . ": a fresh hash of a UTF-8 password round-trips (" . substr($fresh, 0, 4) . ")\n";
if ($bcrypt) {
    echo (count($formats) >= 2 ? 'ok' : 'FAIL') . ": the fixture holds both hash formats (" . implode(' ', array_keys($formats)) . ")\n";
}
$token = wp_generate_password(40, false);
echo (strlen($token) === 40 && ctype_alnum($token) ? 'ok' : 'FAIL') . ": wp_generate_password\n";
echo (preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/', wp_generate_uuid4()) ? 'ok' : 'FAIL') . ": wp_generate_uuid4\n";
echo (wp_verify_nonce(wp_create_nonce('apptest'), 'apptest') === 1 ? 'ok' : 'FAIL') . ": nonce round trip\n";
