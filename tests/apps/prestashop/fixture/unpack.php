<?php
// Unpacks a PrestaShop release zip into a directory: php unpack.php <zip> <dest>
//
// The GitHub release assets are a zip in a zip (prestashop_<ver>.zip holds
// prestashop.zip, the web installer's index.php and a readme); 1.6 is a flat zip
// with everything under prestashop/. Either way <dest> ends up as the shop root.
// ZipArchive::extractTo() drops the unix modes, so they are put back from the
// archive's own attributes (bin/console, vendor/bin/* and the like stay executable).
// Only ZipArchive, because the stock images have no unzip (Alpine on 7.0-8.0).
//
// No `: void` and no short list syntax: the 1.6 fixture runs this on PHP 7.0.

function fail($message)
{
    fwrite(STDERR, "FATAL: unpack.php: $message\n");
    exit(1);
}

function extract_zip($zip, $dest)
{
    $archive = new ZipArchive();
    if ($archive->open($zip) !== true) {
        fail("$zip is not a zip archive");
    }
    if (!is_dir($dest) && !mkdir($dest, 0755, true)) {
        fail("cannot create $dest");
    }
    if (!$archive->extractTo($dest)) {
        fail("cannot extract $zip into $dest");
    }
    for ($i = 0; $i < $archive->numFiles; $i++) {
        $opsys = 0;
        $attr = 0;
        $archive->getExternalAttributesIndex($i, $opsys, $attr);
        $mode = ($attr >> 16) & 0777;
        if ($opsys !== ZipArchive::OPSYS_UNIX || $mode === 0) {
            continue;
        }
        $path = rtrim($dest, '/') . '/' . $archive->getNameIndex($i);
        if (is_link($path) || !file_exists($path)) {
            continue;
        }
        chmod($path, $mode | (is_dir($path) ? 0700 : 0600));
    }
    $archive->close();
}

if ($argc !== 3) {
    fail('usage: unpack.php <zip> <dest>');
}
$zip = $argv[1];
$dest = $argv[2];

$work = $dest . '.unpack';
extract_zip($zip, $work);

if (is_file("$work/prestashop.zip")) {
    extract_zip("$work/prestashop.zip", $dest);
} elseif (is_dir("$work/prestashop")) {
    rename("$work/prestashop", $dest) || fail("cannot move $work/prestashop to $dest");
} else {
    fail("$zip has neither prestashop.zip nor a prestashop/ directory");
}
exec('rm -rf ' . escapeshellarg($work));
if (!is_file("$dest/install/index_cli.php")) {
    fail("$dest is not a PrestaShop tree: no install/index_cli.php");
}
echo "unpacked $zip at $dest\n";
