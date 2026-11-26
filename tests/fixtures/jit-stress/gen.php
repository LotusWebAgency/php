<?php
// Writes the JIT stress workload: FILES independent scripts f<i>.php, each a class
// plus a function with hot loops (what the tracing JIT compiles) and PAD unused
// literal-heavy functions (what makes a script big enough to fill a small opcache),
// and expect.php with the result of every function, computed here without opcache.
//
//   php -n gen.php DIR FILES ITER PAD

$dir = $argv[1];
$files = (int) $argv[2];
$iter = (int) $argv[3];
$pad = (int) $argv[4];

$template = <<<'TPL'
<?php
final class J@I@
{
    private $a;

    public function __construct($a)
    {
        $this->a = $a;
    }

    public function step($x)
    {
        return ($x * @M@ + $this->a) % 1000003;
    }
}

function jit_f@I@($n, $seed)
{
    $o = new J@I@($seed);
    $x = $seed;
    $arr = [];
    $s = 0.0;
    $str = '';
    for ($k = 0; $k < $n; $k++) {
        $x = $o->step($x);
        $arr[$k & 63] = $x;
        $s += sqrt($x) * 0.5;
        if (($k & 255) === 0) {
            $str = md5($str . $x);
        }
        switch ($x & 3) {
            case 0:
                $s -= 1.25;
                break;
            case 1:
                $s += 2.5;
                break;
            default:
                $s *= 1.0000001;
        }
    }
    $t = 0;
    foreach ($arr as $v) {
        $t = ($t + $v) % 65521;
    }
    $w = 0;
    $j = 0;
    while ($j < $n) {
        $w = ($w ^ ($j * @M@)) & 0xffff;
        $j += 3;
    }
    return $x . '/' . $t . '/' . round($s, 3) . '/' . substr($str, 0, 8) . '/' . $w;
}

TPL;

$want = [];
for ($i = 0; $i < $files; $i++) {
    $body = str_replace(['@I@', '@M@'], [(string) $i, (string) (17 + ($i * 7) % 90)], $template);
    for ($k = 0; $k < $pad; $k++) {
        $lits = [];
        for ($l = 0; $l < 24; $l++) {
            $lits[] = ($i * 31 + $k * 17 + $l * 13) % 100003;
        }
        $body .= "function pad_{$i}_{$k}(\$a) { return [\$a + $k, \$a * $i, 'pad-$i-$k', [" . implode(', ', $lits) . "], 'x$i.$k']; }\n";
    }
    file_put_contents("$dir/f$i.php", $body);
    require "$dir/f$i.php";
    $fn = "jit_f$i";
    $want[$i] = $fn($iter, $i + 7);
}
file_put_contents("$dir/expect.php", '<?php return ' . var_export(['iter' => $iter, 'files' => $files, 'want' => $want], true) . ";\n");
echo "generated $files files, pad $pad\n";
