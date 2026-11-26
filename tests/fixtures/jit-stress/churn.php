<?php
// Gives COUNT random scripts a new mtime (in the past: opcache.file_update_protection
// refuses to cache a script modified in the last two seconds), so opcache revalidates
// them, recompiles them and counts the old copy as wasted memory.
//
//   php -n churn.php DIR FILES COUNT
$dir = $argv[1];
$files = (int) $argv[2];
for ($n = (int) $argv[3]; $n > 0; $n--) {
    touch($dir . '/f' . mt_rand(0, $files - 1) . '.php', time() - mt_rand(10, 1000000));
}
