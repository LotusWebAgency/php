<?php

namespace App\Apptest;

use App\Models\Comment;
use App\Models\Post;
use App\Models\Tag;
use Carbon\Carbon;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;

/*
 * Values that must be byte-identical on any correct PHP build. The fixture
 * build records them on the stock PHP; /api/golden and `artisan apptest:verify`
 * recompute them on the image under test. Nothing ICU-formatted, nothing
 * time-dependent, nothing that depends on an image codec or a random source.
 *
 * Database aggregates only look at seeded rows (ids within the seed ranges),
 * because the suites add posts and comments and run twice on one stack.
 */
class Goldens
{
    const SEED_POSTS = 2000;
    const SEED_COMMENTS = 10000;
    const SEED_USERS = 50;
    const POST_IDS = [1, 1000, 2000];

    // Hash algorithms by the PHP that introduced them; see phpMin().
    const ALGO_SINCE = ['crc32c' => 70400, 'murmur3a' => 80100, 'xxh32' => 80100, 'xxh64' => 80100, 'xxh3' => 80100];

    // The goldens are recorded on the set's php-min and compared on every later
    // PHP of the set, so whatever only the newer ones have stays out of them.
    public static function phpMin()
    {
        $v = explode('.', (string) config('apptest.php_min'));

        return $v[0] === '' ? PHP_VERSION_ID : (int) $v[0] * 10000 + (int) ($v[1] ?? 0) * 100;
    }

    public static function compute(array $blobs = null)
    {
        $out = [];
        foreach (self::POST_IDS as $id) {
            $out["api_post_$id"] = Canon::hash(Post::forApi()->findOrFail($id)->toApi(true));
        }
        foreach (['aggregate', 'collection', 'bcmath', 'math', 'strings', 'mbstring', 'iconv', 'preg', 'dates', 'json',
                     'serialize_out', 'igbinary_out', 'hashes', 'crypto', 'sodium', 'crypt', 'validator', 'str_helpers',
                     'blade_card', 'xml'] as $name) {
            $out[$name] = Canon::hash(self::{'g_'.$name}());
        }
        if ($blobs) {
            foreach (self::fromBlobs($blobs) as $k => $v) {
                $out[$k] = $v;
            }
        }
        ksort($out);

        return $out;
    }

    public static function data()
    {
        $std = new \stdClass();
        $std->a = 1;
        $std->b = [1, 2, 3];
        $std->c = 'é';
        $shared = str_repeat('ab', 300);

        $data = [
            'int' => PHP_INT_MAX,
            'neg' => -42,
            'str' => 'Привет, мир 😀 世界',
            'bool' => true,
            'null' => null,
            'float' => 1.5,
            'nested' => ['x' => [1, 2, ['y' => 'z']], 'list' => range(1, 20)],
            'std' => $std,
            'point' => new Point(1, 'two', [3]),
        ];
        // __serialize/__unserialize exist from PHP 7.4
        if (self::phpMin() >= 70400) {
            $data['packed'] = new Packed(['k' => 'v', 5 => 6]);
        }
        $data['long'] = $shared;
        $data['dup'] = $shared;

        return $data;
    }

    // Blob checks: bytes the stock PHP wrote, read back on this one.
    public static function fromBlobs(array $blobs)
    {
        $out = [];
        $out['unserialize_blob'] = hash('sha256', serialize(unserialize(base64_decode($blobs['serialize']))));
        if (function_exists('igbinary_unserialize')) {
            $out['igbinary_blob'] = hash('sha256', serialize(igbinary_unserialize(base64_decode($blobs['igbinary']))));
        }
        $rsa = $blobs['rsa'];
        $ok = openssl_verify('apptest rsa message', base64_decode($rsa['signature']), $rsa['public'], OPENSSL_ALGO_SHA256);
        $sig = '';
        openssl_sign('apptest rsa message', $sig, $rsa['private'], OPENSSL_ALGO_SHA256);
        $out['rsa_verify'] = $ok === 1 ? 'ok' : 'bad';
        $out['rsa_sign'] = hash('sha256', $sig); // PKCS#1 v1.5 is deterministic
        $out['crypt_stock'] = hash('sha256', app('encrypter')->decryptString($blobs['crypt']));
        $out['hash_stock_bcrypt'] = password_verify($blobs['password'], $blobs['bcrypt']) ? 'ok' : 'bad';
        foreach (['argon2i', 'argon2id'] as $algo) {
            if (isset($blobs[$algo])) {
                $out["hash_stock_$algo"] = password_verify($blobs['password'], $blobs[$algo]) ? 'ok' : 'bad';
            }
        }

        return $out;
    }

    private static function g_aggregate()
    {
        $posts = Post::query()->where('id', '<=', self::SEED_POSTS);
        $perUser = Post::query()->where('id', '<=', self::SEED_POSTS)->groupBy('user_id')->orderBy('user_id')
            ->selectRaw('user_id, COUNT(*) AS c, SUM(views) AS v, MAX(views) AS mx, AVG(views) AS av') // raw: no builder aggregate does a grouped multi-select
            ->get()->map(function ($r) {
                return $r->getAttributes();
            })->all();
        $perTag = DB::table('post_tag')->where('post_id', '<=', self::SEED_POSTS)->groupBy('tag_id')->orderBy('tag_id')
            ->select('tag_id', DB::raw('COUNT(*) AS c'))->get()->map(function ($r) {
                return [$r->tag_id, $r->c];
            })->all();
        $perPost = Comment::query()->where('id', '<=', self::SEED_COMMENTS)->groupBy('post_id')->orderBy('post_id')
            ->selectRaw('post_id, COUNT(*) AS c')->get()->map(function ($r) {
                return [$r->post_id, $r->c];
            })->all();

        return [
            'posts' => $posts->count(),
            'views_sum' => $posts->sum('views'),
            'views_avg' => DB::table('posts')->where('id', '<=', self::SEED_POSTS)->avg('views'),
            'views_max' => $posts->max('views'),
            'null_user_comments' => Comment::whereNull('user_id')->where('id', '<=', self::SEED_COMMENTS)->count(),
            'per_user' => $perUser,
            'per_tag' => $perTag,
            'per_post' => $perPost,
            // typed rows, straight off mysqlnd: ints must stay ints, DECIMAL a string
            'typed' => hash('sha256', serialize(DB::select(
                'SELECT id, user_id, views, published_at, CAST(views AS DECIMAL(10,2)) AS d, views / 7 AS q FROM posts WHERE id <= 50 ORDER BY id'
            ))),
        ];
    }

    private static function g_collection()
    {
        $posts = Post::query()->where('id', '<=', 300)->orderBy('id')->get(['id', 'user_id', 'title', 'views']);

        return [
            'by_user' => $posts->groupBy('user_id')->map->count()->map(function ($c, $k) {
                return [$k, $c];
            })->sortBy(0)->values()->all(),
            'top' => $posts->sortByDesc('views')->take(5)->pluck('id')->values()->all(),
            'chunks' => $posts->pluck('id')->chunk(64)->map->sum()->all(),
            'titles' => $posts->pluck('title')->map(function ($t) {
                return mb_strlen($t);
            })->sum(),
            'unique_users' => $posts->pluck('user_id')->unique()->sort()->values()->all(),
            'partition' => $posts->partition(function ($p) {
                return $p->views % 2 === 0;
            })->map->count()->all(),
        ];
    }

    private static function g_bcmath()
    {
        $a = '123456789012345678901234567890.123456789';
        $b = '-987654321.987654321';

        return [
            bcadd($a, $b, 9), bcsub($a, $b, 9), bcmul($a, $b, 18), bcdiv($a, '7', 30),
            bcmod('1234567890123456789012345678901234567890', '97'), bcpow('3', '100'), bcsqrt('2', 40),
            bcpowmod('4', '13', '497'), bccomp($a, $b, 9), bcadd('0.1', '0.2', 1), bcdiv('1', '3', 50),
            bcmul('99999999999999999999', '99999999999999999999', 0),
        ];
    }

    private static function g_math()
    {
        return [
            intdiv(-7, 2), -7 % 3, 7 % -3, 2 ** 62, var_export(PHP_INT_MAX + 1, true),
            var_export(0.1 + 0.2, true), json_encode([1 / 3, 1e100, -0.0, 1.0]), floor(-0.5) === -0.0,
            sprintf('%.15g|%e|%08.3f|%x|%b|%o|%c', sqrt(2), 12345.6789, 3.14159, 255, 5, 64, 65),
            base_convert('zz', 36, 2), bin2hex(pack('J', 1234567890123)), bin2hex(pack('e', 1.5)),
            unpack('N', "\x00\x00\x01\x00")[1], array_sum([0.5, 0.25, 0.125]), round(2.5), round(-3.5), round(7.0, 0),
            fmod(10, 3), is_nan(NAN), PHP_INT_SIZE, (int) '9223372036854775808', 0.1 + 0.7 === 0.8,
            max('apple', 'banana', 'cherry'), min([3, '2', 1.5]), array_product([2, 3, 7]),
        ];
    }

    private static function g_strings()
    {
        $s = 'The quick brown fox jumps over the lazy dog';
        $nat = ['b10', 'b9', 'B1', 'a'];
        sort($nat, SORT_NATURAL | SORT_FLAG_CASE);

        return [
            strrev($s), ucwords($s), wordwrap($s, 15, "|", true), str_word_count($s), similar_text('World', 'Word'),
            levenshtein('kitten', 'sitting'), soundex('Robert'), metaphone('Thompson'), substr_count($s, 'o'),
            strtr($s, 'abc', 'xyz'), nl2br("a\nb"), htmlspecialchars('<a href="x">Tom & "Jerry"</a>'),
            html_entity_decode('&lt;p&gt;&euro;&nbsp;&#8364;&hearts;'), strip_tags('<b>bold</b> <i>it</i>alic'),
            number_format(1234567.891, 2, ',', ' '), number_format(-0.5), vsprintf('%2$s-%1$04d', [7, 'x']),
            str_pad('7', 3, '0', STR_PAD_LEFT), ltrim('0012', '0'), chunk_split('abcdefgh', 3, '-'),
            base64_encode("\x00\xff binary \x80"), bin2hex(md5('a', true)), urlencode('a b&c=d/é'), rawurlencode('a b+é'),
            http_build_query(['a' => [1, 2], 'b' => 'é ü']), quoted_printable_encode('héllo=wörld'),
            array_map('strval', array_map('ord', str_split('AZaz09'))), sprintf('%s', true),
            implode(',', $nat), strnatcasecmp('img12', 'IMG10'),
            parse_url('https://user:pw@example.com:8080/p/a/t/h?query=1#frag'), pathinfo('/a/b/file.tar.gz'),
        ];
    }

    private static function g_mbstring()
    {
        $t = 'Привет, Ёжик! Hello, 世界 😀 ｈａｌｆ';

        // The emoji is width 1 up to 8.0 and 2 from 8.1 (mbstring's width table), and a fixture is
        // built on the row's lowest PHP, so it stays out of the width.
        $out = [
            mb_strlen($t), mb_strtoupper($t), mb_strtolower($t), mb_substr($t, 3, 8), mb_strpos($t, '世'),
            mb_strwidth(str_replace('😀', '', $t)), array_map('implode', array_chunk(preg_split('//u', '日本語テキスト', -1, PREG_SPLIT_NO_EMPTY), 3)), mb_convert_case('hello wörld привет', MB_CASE_TITLE),
            mb_substr_count($t, 'l'), bin2hex(mb_convert_encoding($t, 'UTF-16BE', 'UTF-8')),
            bin2hex(mb_convert_encoding('Привет', 'Windows-1251', 'UTF-8')), bin2hex(mb_convert_encoding('Привет', 'KOI8-R', 'UTF-8')),
            bin2hex(mb_convert_encoding('日本語', 'SJIS', 'UTF-8')), bin2hex(mb_convert_encoding('日本語', 'EUC-JP', 'UTF-8')),
            bin2hex(mb_convert_encoding('中文', 'GB18030', 'UTF-8')), mb_convert_encoding("\xcf\xf0\xe8\xe2\xe5\xf2", 'UTF-8', 'Windows-1251'),
            mb_detect_encoding('Привет', ['ASCII', 'UTF-8'], true), mb_check_encoding("\xff\xfe", 'UTF-8'),
            mb_strimwidth('Привет мир, как дела', 0, 12, '...'),
            mb_preferred_mime_name('SJIS'), mb_substitute_character(), mb_internal_encoding(),
            bin2hex(mb_encode_mimeheader('Тема письма', 'UTF-8', 'B')), mb_decode_numericentity('&#1055;&#1088;', [0x0, 0x10ffff, 0, 0xffffff], 'UTF-8'),
        ];
        if (function_exists('mb_ord')) { // 7.2
            $out[] = mb_ord('😀');
            $out[] = mb_chr(0x1F600);
        }

        return $out;
    }

    private static function g_iconv()
    {
        return [
            bin2hex(iconv('UTF-8', 'Windows-1251', 'Привет')), iconv('Windows-1251', 'UTF-8', "\xcf\xf0\xe8\xe2\xe5\xf2"),
            bin2hex(iconv('UTF-8', 'UTF-16LE', 'a😀')), iconv_strlen('Привет 😀'), iconv_substr('Привет мир', 3, 4, 'UTF-8'),
            iconv_strpos('Привет мир', 'мир', 0, 'UTF-8'), bin2hex(iconv('UTF-8', 'ISO-8859-1', 'café')),
            iconv_mime_encode('Subject', 'Тема', ['scheme' => 'B', 'input-charset' => 'UTF-8', 'output-charset' => 'UTF-8']),
        ];
    }

    private static function g_preg()
    {
        $t = "Москва 2024, Tokyo 東京 5, القاهرة 12, emoji 😀 x9. user@example.com https://a.b/c?d=e #tag_1 #тег";
        preg_match_all('/\p{Cyrillic}+/u', $t, $cyr);
        preg_match_all('/\p{Han}+/u', $t, $han);
        preg_match_all('/\p{Arabic}+/u', $t, $ar);
        preg_match_all('/\b\d+\b/', $t, $nums);
        preg_match_all('/#([\p{L}\p{N}_]+)/u', $t, $tags);
        preg_match('/(?<user>[\w.]+)@(?<host>[\w.]+)/', $t, $mail);

        return [
            $cyr[0], $han[0], $ar[0], $nums[0], $tags[1], [$mail['user'], $mail['host']],
            preg_replace_callback('/\d+/', function ($m) {
                return $m[0] * 2;
            }, $t),
            preg_split('/[\s,]+/u', 'a, b  c,d', -1, PREG_SPLIT_NO_EMPTY), preg_quote('a.b*c?d[e]f(g)h{i}j+k^l$m|n\\o/p#'),
            preg_match('/^(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?!$)|$)){4}$/', '192.168.1.255'),
            preg_replace('/(?<=\d)(?=(\d{3})+$)/', ',', '1234567890'), preg_last_error(),
            preg_match('/^\X$/u', "e\u{0301}"), preg_match_all('/./su', "a\u{1F600}\n"), preg_grep('/^\p{Lu}/u', ['Абв', 'абв', 'Xyz', 'xyz']),
        ];
    }

    private static function g_dates()
    {
        $c = Carbon::create(2024, 1, 31, 23, 59, 59, 'UTC');
        $berlin = Carbon::create(2023, 3, 26, 1, 30, 0, 'Europe/Berlin');
        $ny = Carbon::create(2023, 11, 5, 1, 30, 0, 'America/New_York');
        $d1 = new \DateTimeImmutable('2020-02-29 12:00:00', new \DateTimeZone('UTC'));
        $period = new \DatePeriod(new \DateTime('2024-01-29', new \DateTimeZone('UTC')), new \DateInterval('P1M'), 4);
        $months = [];
        foreach ($period as $p) {
            $months[] = $p->format('Y-m-d');
        }

        return [
            $c->copy()->addMonth()->toIso8601String(), $c->copy()->addMonthNoOverflow()->toDateString(), $c->copy()->endOfMonth()->toDateTimeString(),
            $c->copy()->startOfWeek()->toDateString(), $c->dayOfYear, $c->weekOfYear, $c->isLeapYear(), $c->copy()->setTimezone('Asia/Tokyo')->toDateTimeString(),
            $berlin->copy()->addHour()->toIso8601String(), $berlin->copy()->setTimezone('UTC')->toDateTimeString(), $ny->copy()->addHours(2)->toIso8601String(), $ny->timestamp,
            $d1->add(new \DateInterval('P1Y'))->format('Y-m-d'), $d1->diff(new \DateTimeImmutable('2024-03-01', new \DateTimeZone('UTC')))->format('%y-%m-%d %a'),
            $months, gmdate('D, d M Y H:i:s \G\M\T N jS z t L o W', 1709164799), date_create('@86400')->format('c'),
            (new \DateTime('last day of february 2024', new \DateTimeZone('UTC')))->format('Y-m-d'), strtotime('2024-05-05 05:05:05 UTC'),
            (new \DateTime('first monday of january 2025', new \DateTimeZone('UTC')))->format('Y-m-d'), checkdate(2, 30, 2024),
            Carbon::parse('2024-06-15T10:00:00+05:30')->setTimezone('UTC')->toIso8601String(), Carbon::createFromFormat('d/m/Y H:i', '15/06/2024 08:30', 'UTC')->timestamp,
            Carbon::create(2024, 1, 1, 0, 0, 0, 'UTC')->diffInDays(Carbon::create(2024, 12, 31, 0, 0, 0, 'UTC')),
        ];
    }

    private static function g_json()
    {
        $v = ['s' => "Привет \"мир\" \n\t 😀 / </script>", 'i' => [1, 2, 3], 'o' => ['a' => null, 'b' => false], 'e' => [], 'n' => 12345678901234567890];

        $out = [
            json_encode($v), json_encode($v, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT),
            json_encode($v, JSON_HEX_TAG | JSON_HEX_AMP), json_encode(['a' => 1.0, 'b' => 0.1], JSON_PRESERVE_ZERO_FRACTION),
            json_decode('{"big":12345678901234567890,"f":1.5e3,"u":"😀"}', true, 512, JSON_BIGINT_AS_STRING),
            json_decode('[1,{"a":{"b":[true,null]}}]', true), json_last_error_msg(), json_decode('{bad', true) === null ? json_last_error() : -1,
            json_encode((object) []), json_encode([1 => 'a', 2 => 'b']), json_encode(range(0, 3)),
        ];
        if (defined('JSON_INVALID_UTF8_SUBSTITUTE')) { // 7.2
            $out[] = json_encode("\xff", JSON_INVALID_UTF8_SUBSTITUTE);
        }

        return $out;
    }

    private static function g_serialize_out()
    {
        return serialize(self::data());
    }

    private static function g_igbinary_out()
    {
        return function_exists('igbinary_serialize') ? bin2hex(igbinary_serialize(self::data())) : 'no-igbinary';
    }

    private static function g_hashes()
    {
        $m = "apptest \u{1F600} message";
        $out = [];
        foreach (['md5', 'sha1', 'sha256', 'sha384', 'sha512', 'sha3-256', 'sha3-512', 'crc32', 'crc32b', 'crc32c', 'adler32', 'fnv132', 'fnv1a64', 'joaat', 'ripemd160', 'whirlpool', 'murmur3a', 'xxh32', 'xxh64', 'xxh3', 'md4', 'tiger192,3', 'gost'] as $algo) {
            if (in_array($algo, hash_algos(), true) && (self::ALGO_SINCE[$algo] ?? 0) <= self::phpMin()) {
                $out[$algo] = hash($algo, $m);
            }
        }
        $out['hmac'] = hash_hmac('sha256', $m, 'key');
        $out['pbkdf2'] = hash_pbkdf2('sha256', 'password', 'salt', 1000, 32);
        if (function_exists('hash_hkdf')) { // 7.1.2
            $out['hkdf'] = bin2hex(hash_hkdf('sha256', 'input key material', 32, 'info', 'salt'));
        }
        $out['crc32'] = crc32($m);
        $out['md5_file'] = md5(str_repeat("line\n", 100000));

        return $out;
    }

    private static function g_crypto()
    {
        $key = hash('sha256', 'apptest', true);
        $iv12 = substr(hash('sha256', 'iv', true), 0, 12);
        $iv16 = substr(hash('sha256', 'iv', true), 0, 16);
        $out = [
            bin2hex(openssl_encrypt('block cipher text', 'aes-256-cbc', $key, OPENSSL_RAW_DATA, $iv16)),
            bin2hex(openssl_encrypt('ctr mode', 'aes-128-ctr', substr($key, 0, 16), OPENSSL_RAW_DATA, $iv16)),
            openssl_digest('abc', 'sha256'), bin2hex(openssl_pbkdf2('password', 'salt', 32, 1000, 'sha256')),
            in_array('aes-256-gcm', openssl_get_cipher_methods(), true),
        ];
        if (PHP_VERSION_ID >= 70100) { // openssl_encrypt() takes the AEAD tag from 7.1
            $tag = '';
            $gcm = openssl_encrypt("secret текст 😀", 'aes-256-gcm', $key, OPENSSL_RAW_DATA, $iv12, $tag, 'aad');
            $out[] = bin2hex($gcm).bin2hex($tag);
        }

        return $out;
    }

    private static function g_sodium()
    {
        if (!function_exists('sodium_crypto_secretbox')) { // core from 7.2
            return 'no-sodium';
        }
        $key = hash('sha256', 'apptest-sodium', true);
        $nonce = substr(hash('sha256', 'nonce', true), 0, SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);
        $seed = hash('sha256', 'seed', true);
        $kp = sodium_crypto_sign_seed_keypair($seed);
        $box1 = sodium_crypto_box_seed_keypair($seed);
        $box2 = sodium_crypto_box_seed_keypair(hash('sha256', 'seed2', true));
        $boxNonce = substr(hash('sha256', 'boxnonce', true), 0, SODIUM_CRYPTO_BOX_NONCEBYTES);
        $salt = substr(hash('sha256', 'pwsalt', true), 0, SODIUM_CRYPTO_PWHASH_SALTBYTES);

        return [
            sodium_bin2hex(sodium_crypto_secretbox('sodium текст 😀', $nonce, $key)),
            sodium_bin2hex(sodium_crypto_sign_detached('signed message', sodium_crypto_sign_secretkey($kp))),
            sodium_bin2hex(sodium_crypto_sign_publickey($kp)), sodium_bin2hex(sodium_crypto_generichash('hash me')),
            sodium_bin2hex(sodium_crypto_generichash('hash me', $key, 16)),
            sodium_bin2hex(sodium_crypto_box('boxed', $boxNonce, sodium_crypto_box_secretkey($box1).sodium_crypto_box_publickey($box2))),
            sodium_bin2hex(sodium_crypto_pwhash(32, 'password', $salt, SODIUM_CRYPTO_PWHASH_OPSLIMIT_INTERACTIVE, SODIUM_CRYPTO_PWHASH_MEMLIMIT_INTERACTIVE)),
            sodium_bin2hex(sodium_crypto_shorthash('short', substr($key, 0, 16))), sodium_bin2hex(sodium_crypto_auth('auth', $key)),
            sodium_bin2hex(sodium_crypto_kdf_derive_from_key(32, 1, 'apptest_', $key)),
            sodium_bin2hex(sodium_crypto_aead_xchacha20poly1305_ietf_encrypt('aead', 'ad', substr(hash('sha256', 'xn', true), 0, 24), $key)),
            sodium_bin2hex(sodium_crypto_scalarmult_base($key)),
        ];
    }

    private static function g_crypt()
    {
        return [
            crypt('password', '$2y$05$abcdefghijklmnopqrstuu'), crypt('password', '$6$rounds=5000$apptestsalt$'),
            crypt('password', '$5$rounds=5000$apptestsalt$'), crypt('password', '$1$apptest$'), crypt('password', 'ab'),
        ];
    }

    private static function g_validator()
    {
        $cases = [
            ['email', 'user@example.com'], ['email', 'not an email'], ['url', 'https://пример.рф/path'], ['url', 'nope'], ['alpha', 'Привет'], ['alpha', 'abc1'],
            ['alpha_num', 'abc123'], ['alpha_dash', 'a-b_c'], ['integer', '12'], ['integer', '1.5'], ['numeric', '1e3'], ['uuid', '123e4567-e89b-12d3-a456-426614174000'],
            ['uuid', 'zzz'], ['ip', '10.0.0.1'], ['ip', '999.1.1.1'], ['ipv6', '::1'], ['json', '{"a":1}'], ['json', '{a:1}'], ['date', '2024-02-30'], ['date', '2024-02-29'],
            ['date_format:Y-m-d H:i', '2024-01-01 10:30'], ['between:3,5', 'abcd'], ['between:3,5', 'ab'], ['size:4', '😀😀😀😀'], ['min:3|max:10', 'Привет'],
            ['regex:/^\p{Lu}\p{Ll}+$/u', 'Москва'], ['regex:/^\p{Lu}\p{Ll}+$/u', 'москва'], ['in:a,b,c', 'b'], ['not_in:a,b', 'a'], ['starts_with:foo', 'foobar'],
            ['ascii', 'plain'], ['ascii', 'plainé'], ['hex_color', '#ff00AA'], ['mac_address', '00:1A:2b:3c:4D:5e'], ['timezone', 'Europe/Moscow'], ['timezone', 'Mars/Base'],
            ['boolean', '0'], ['boolean', 'yes'], ['lowercase', 'abc'], ['uppercase', 'abc'], ['digits:4', '1234'], ['digits_between:2,3', '12345'],
        ];
        $out = [];
        foreach ($cases as $case) {
            list($rule, $value) = $case;
            // rules the framework generation does not have (ascii, hex_color, ...) are left out
            $known = true;
            foreach (explode('|', $rule) as $one) {
                $known = $known && method_exists(\Illuminate\Validation\Validator::class, 'validate'.Str::studly(explode(':', $one)[0]));
            }
            if (!$known) {
                continue;
            }
            $v = Validator::make(['f' => $value], ['f' => $rule]);
            $out[] = [$rule, $value, $v->passes(), $v->errors()->first('f')];
        }

        return $out;
    }

    private static function g_str_helpers()
    {
        // [Str method, arguments...]; helpers the framework generation lacks are skipped
        $calls = [
            ['slug', 'Привет, мир! Hello World'], ['ascii', 'Ёжик Щука Эхо'], ['title', 'привет мир hello'], ['studly', 'foo_bar-baz qux'],
            ['snake', 'FooBarBaz'], ['camel', 'foo_bar'], ['kebab', 'FooBar'], ['plural', 'category'], ['singular', 'children'], ['limit', 'Привет мир, как дела?', 10],
            ['words', 'one two three four', 2], ['mask', '4111111111111111', '*', 4, 8], ['ucfirst', 'élan'], ['lower', 'ÀÉÎ'], ['upper', 'привет'],
            ['length', '😀日本'], ['substr', 'Привет', 1, 3], ['reverse', 'abc😀'], ['contains', 'Привет мир', 'мир'], ['is', 'a*z', 'abcz'], ['before', 'a@b', '@'],
            ['afterLast', 'a/b/c', '/'], ['between', '[x]', '[', ']'], ['padBoth', 'x', 5, '-'], ['wordCount', 'a b c'], ['isJson', '{"a":1}'],
            ['isUuid', '123e4567-e89b-12d3-a456-426614174000'], ['excerpt', 'Съешь ещё этих мягких французских булок', 'мягких', ['radius' => 6]],
            ['markdown', '**bold** _it_ `code`'],
        ];
        $out = [];
        foreach ($calls as $call) {
            $method = array_shift($call);
            if (method_exists(Str::class, $method)) {
                $out[$method] = Str::$method(...$call);
            }
        }
        if (method_exists(\Illuminate\Support\Stringable::class, 'squish')) {
            $out['squish_slug'] = Str::of('  Hello  World  ')->squish()->slug()->toString();
        }
        if (method_exists(\Illuminate\Support\Stringable::class, 'headline')) {
            $out['headline'] = (string) Str::of('привет')->headline();
        }

        return $out;
    }

    private static function g_blade_card()
    {
        $post = Post::forApi()->findOrFail(1);

        return view('posts.card', ['post' => $post])->render();
    }

    private static function g_xml()
    {
        $dom = new \DOMDocument('1.0', 'UTF-8');
        $dom->preserveWhiteSpace = false;
        $dom->loadXML('<?xml version="1.0" encoding="UTF-8"?><r xmlns:x="urn:x" b="2" a="1"><x:i k="v">Привет &amp; 😀</x:i><!-- c --><e/><t><![CDATA[<raw>]]></t></r>');
        $xp = new \DOMXPath($dom);
        $xp->registerNamespace('x', 'urn:x');
        $sx = simplexml_load_string('<a><b id="1">one</b><b id="2">two</b><c>ü</c></a>');

        return [
            $dom->C14N(), $xp->evaluate('string(//x:i)'), $xp->evaluate('count(//*)'), (string) $sx->b[1], (string) $sx->c, count($sx->b),
            $sx->xpath('//b[@id="2"]')[0]->asXML(), $dom->saveXML($dom->documentElement),
        ];
    }
}
