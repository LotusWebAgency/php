<?php

namespace App\Http\Controllers;

use App\Apptest\Goldens;
use App\Apptest\Mailbox;
use App\Apptest\Passwords;
use App\Jobs\FailingJob;
use App\Jobs\QueuedJob;
use App\Jobs\RecordJob;
use App\Mail\PostDigest;
use App\Models\JobLog;
use App\Models\Media;
use App\Models\Post;
use App\Models\Tag;
use App\Models\User;
use Carbon\Carbon;
use Illuminate\Cache\RedisStore;
use Illuminate\Cache\TaggableStore;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Crypt;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Event;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;

/*
 * One JSON endpoint per area. Each does the work server-side, inside the
 * image under test, and answers {ok, checks:{name:bool}, info:{...}}; the
 * suite fails on any false check and reports its name. Values a Python
 * oracle can compute (digests, big integers) come back in `info` too.
 */
class FeatureController extends Controller
{
    // name => why: checks this PHP or framework generation cannot run; the
    // suite reports them as SKIP lines.
    private $skipped = [];

    private function skip($name, $why)
    {
        $this->skipped[$name] = $why;
    }

    private function out(array $checks, array $info = [])
    {
        $failed = array_keys(array_filter($checks, function ($v) {
            return $v !== true;
        }));

        return response()->json(['ok' => !$failed, 'failed' => $failed, 'checks' => $checks, 'skipped' => $this->skipped, 'info' => $info], 200, [], JSON_UNESCAPED_UNICODE | JSON_PARTIAL_OUTPUT_ON_ERROR);
    }

    private function token(Request $request)
    {
        return preg_replace('/[^A-Za-z0-9_-]/', '', (string) $request->query('token', 'none'));
    }

    // ---------------------------------------------------------------- cache

    // Cross-request half: one request puts, a later one (usually another
    // worker) reads. That is what proves APCu's shared memory and the network
    // stores; the in-request suite below cannot.
    public function cachePut(Request $request, $store)
    {
        $key = 'apptest:x:'.$this->token($request);
        $ttl = (int) $request->query('ttl', 300);
        // A Carbon expiry: put()'s integer is minutes up to 5.7, seconds after.
        Cache::store($store)->put($key, ['store' => $store, 'text' => 'Привет 😀 世界', 'n' => 42], Carbon::now()->addSeconds($ttl));

        return response()->json(['stored' => $key, 'ttl' => $ttl]);
    }

    public function cacheGet(Request $request, $store)
    {
        return response()->json(['value' => Cache::store($store)->get('apptest:x:'.$this->token($request))], 200, [], JSON_UNESCAPED_UNICODE);
    }

    public function cacheSuite(Request $request, $store)
    {
        $c = Cache::store($store);
        $k = 'apptest:'.$this->token($request).':';
        $checks = [];

        $c->put($k.'s', 'значение 😀', 60);
        $checks['put_get'] = $c->get($k.'s') === 'значение 😀';
        $payload = ['a' => [1, 2, 3], 'u' => '日本語', 'n' => null, 'f' => 1.5, 't' => true, 'nested' => ['x' => ['y' => 'z']]];
        $c->put($k.'arr', $payload, 60);
        $checks['array_roundtrip'] = $c->get($k.'arr') === $payload;
        $checks['add_new'] = $c->add($k.'add', 1, 60) === true;
        $checks['add_existing'] = $c->add($k.'add', 2, 60) === false;
        $checks['add_kept_first'] = (int) $c->get($k.'add') === 1;
        // INCR needs a plain integer on the server; a phpredis serializer
        // (igbinary here) wraps every value, so that store cannot count.
        if ($store !== 'redis_igbinary') {
            $c->put($k.'n', 10, 60);
            $checks['increment'] = (int) $c->increment($k.'n', 5) === 15;
            $checks['decrement'] = (int) $c->decrement($k.'n', 3) === 12;
        }
        $calls = 0;
        $cb = function () use (&$calls) {
            $calls++;

            return ['x' => 1];
        };
        $c->remember($k.'rem', 60, $cb);
        $checks['remember'] = $c->remember($k.'rem', 60, $cb) === ['x' => 1] && $calls === 1;
        $c->putMany([$k.'m1' => 1, $k.'m2' => 2], 60);
        $checks['many'] = $c->many([$k.'m1', $k.'m2', $k.'m3']) == [$k.'m1' => 1, $k.'m2' => 2, $k.'m3' => null];
        $c->forget($k.'m1');
        $checks['forget'] = !$c->has($k.'m1') && $c->has($k.'m2');
        $c->forever($k.'f', 'x');
        $checks['forever'] = $c->get($k.'f') === 'x';
        $big = str_repeat('0123456789abcdef', 12800);
        $c->put($k.'big', $big, 60);
        $checks['large_value_200k'] = $c->get($k.'big') === $big;
        if ($store === 'redis_igbinary' && version_compare(app()->version(), '8.0', '<')) {
            // RedisLock's Lua release compares the raw owner string with a value phpredis stored serialized; PhpRedisLock is 8+.
            $this->skip('lock', 'Laravel '.app()->version().' cannot release a redis lock through a phpredis serializer');
        } elseif (interface_exists(\Illuminate\Contracts\Cache\LockProvider::class) && $c->getStore() instanceof \Illuminate\Contracts\Cache\LockProvider) {
            $lock = $c->lock($k.'lock', 10);
            $checks['lock_acquire'] = $lock->get() === true;
            $checks['lock_excludes'] = $c->lock($k.'lock', 10)->get() === false;
            $lock->release();
            $again = $c->lock($k.'lock', 10);
            $checks['lock_reacquire'] = $again->get() === true;
            $again->release();
        } else {
            $this->skip('lock', 'Laravel '.app()->version().' has no lock on the '.get_class($c->getStore()).' store');
        }
        if ($c->getStore() instanceof TaggableStore) {
            $c->tags(['apptest', $k])->put($k.'tagged', 'v', 60);
            $checks['tags_get'] = $c->tags(['apptest', $k])->get($k.'tagged') === 'v';
            // Laravel <= 10 scans a tag's entries from the string cursor '0',
            // which phpredis 6.3 takes for "finished" (6.0.2 still iterates):
            // the flush finds nothing. Fixed in 11; the stock images fail the
            // same way.
            if ($c->getStore() instanceof RedisStore && version_compare(app()->version(), '11.0', '<') && version_compare((string) phpversion('redis'), '6.1', '>=')) {
                $this->skip('tags_flush', 'Laravel '.app()->version().' cannot flush redis tags through phpredis '.phpversion('redis'));
            } else {
                $c->tags([$k])->flush();
                $checks['tags_flush'] = $c->tags(['apptest', $k])->get($k.'tagged') === null;
            }
        }

        return $this->out($checks, ['store' => $store, 'class' => get_class($c->getStore())]);
    }

    // ----------------------------------------------------------------- hash

    public function hash()
    {
        $checks = [];
        $pw = 'pässwörd 😀 пароль';
        // Laravel names its argon2i driver 'argon'. PHP has argon2i from 7.2 and
        // argon2id from 7.3; Laravel has the manager from 5.6, 'argon' from 5.7
        // and 'argon2id' from 5.8.
        $manager = method_exists(app('hash'), 'driver');
        foreach (['bcrypt' => 'bcrypt', 'argon' => 'argon2i', 'argon2id' => 'argon2id'] as $driver => $algo) {
            if ($driver !== 'bcrypt') {
                $constant = Passwords::CONSTANTS[$algo];
                $since = $driver === 'argon' ? '7.2' : '7.3';
                if (!defined($constant)) {
                    if (version_compare(PHP_VERSION, $since, '>=') && $driver === 'argon2id') {
                        $checks['argon2id_available'] = false;
                    } else {
                        $this->skip($driver, "PHP before $since has no $algo");
                    }
                    continue;
                }
                if (!$manager) {
                    $this->skip($driver, 'Laravel '.app()->version().' hashes with bcrypt only');
                    continue;
                }
            }
            $h = Passwords::driver($driver)->make($pw);
            $checks["$driver.check"] = Passwords::driver($driver)->check($pw, $h);
            $checks["$driver.wrong"] = !Passwords::driver($driver)->check($pw.'x', $h);
            $checks["$driver.info"] = Passwords::info($h)['algoName'] === $algo;
            $checks["$driver.no_rehash"] = !Passwords::driver($driver)->needsRehash($h);
            $checks["$driver.password_verify"] = password_verify($pw, $h);
        }
        $weak = password_hash('x', PASSWORD_BCRYPT, ['cost' => 4]);
        $checks['bcrypt.needs_rehash_low_cost'] = Passwords::driver('bcrypt')->needsRehash($weak, ['rounds' => 10]);
        $checks['bcrypt.72_byte_limit'] = password_verify(str_repeat('a', 72).'b', password_hash(str_repeat('a', 72), PASSWORD_BCRYPT, ['cost' => 4])) === true;

        $m = "apptest \u{2713} message";
        $digests = [];
        foreach (['md5', 'sha1', 'sha256', 'sha512', 'sha3-256', 'crc32b'] as $a) {
            if (in_array($a, hash_algos(), true)) { // sha3 arrived in 7.1
                $digests[$a] = hash($a, $m);
            }
        }
        $digests['hmac_sha256'] = hash_hmac('sha256', $m, 'secret key');
        $digests['pbkdf2_sha256'] = hash_pbkdf2('sha256', 'password', 'salt', 2000, 64);
        if (function_exists('sodium_crypto_generichash')) {
            $digests['blake2b_256'] = sodium_bin2hex(sodium_crypto_generichash($m));
        }
        $digests['adler32'] = hash('adler32', $m);
        $digests['crc32_int'] = crc32($m);
        $checks['hash_equals'] = hash_equals($digests['sha256'], hash('sha256', $m)) && !hash_equals('a', 'b');
        if (!isset($digests['sha3-256'])) {
            $this->skip('sha3', 'hash() has no sha3 before PHP 7.1');
        }

        return $this->out($checks, ['message' => $m, 'digests' => $digests]);
    }

    // --------------------------------------------------------------- crypto

    public function crypto()
    {
        $checks = [];
        $manifest = json_decode(file_get_contents(base_path('.apptest/manifest.json')), true);
        $text = 'секрет 😀 秘密';

        $enc = Crypt::encryptString($text);
        $checks['crypt_roundtrip'] = Crypt::decryptString($enc) === $text;
        $checks['crypt_nondeterministic'] = Crypt::encryptString($text) !== $enc;
        $checks['crypt_array'] = Crypt::decrypt(Crypt::encrypt(['a' => [1, 2], 'b' => 'ü'])) === ['a' => [1, 2], 'b' => 'ü'];
        $checks['crypt_reads_stock_payload'] = Crypt::decryptString($manifest['blobs']['crypt']) === $manifest['blobs']['crypt_plain'];
        $tampered = json_decode(base64_decode($enc), true);
        $tampered['value'] = strrev($tampered['value']);
        try {
            Crypt::decryptString(base64_encode(json_encode($tampered)));
            $checks['crypt_rejects_tamper'] = false;
        } catch (\Illuminate\Contracts\Encryption\DecryptException $e) {
            $checks['crypt_rejects_tamper'] = true;
        }

        if (function_exists('sodium_crypto_secretbox')) {
            $key = sodium_crypto_secretbox_keygen();
            $nonce = random_bytes(SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);
            $checks['sodium_secretbox'] = sodium_crypto_secretbox_open(sodium_crypto_secretbox($text, $nonce, $key), $nonce, $key) === $text;
            $kp = sodium_crypto_sign_keypair();
            $sig = sodium_crypto_sign_detached('msg', sodium_crypto_sign_secretkey($kp));
            $checks['sodium_sign_verify'] = sodium_crypto_sign_verify_detached($sig, 'msg', sodium_crypto_sign_publickey($kp));
            $checks['sodium_sign_rejects'] = !sodium_crypto_sign_verify_detached($sig, 'msG', sodium_crypto_sign_publickey($kp));
            $checks['sodium_pwhash_str'] = sodium_crypto_pwhash_str_verify(sodium_crypto_pwhash_str('pw', SODIUM_CRYPTO_PWHASH_OPSLIMIT_INTERACTIVE, SODIUM_CRYPTO_PWHASH_MEMLIMIT_INTERACTIVE), 'pw');
            $a = sodium_crypto_box_keypair();
            $b = sodium_crypto_box_keypair();
            $n2 = random_bytes(SODIUM_CRYPTO_BOX_NONCEBYTES);
            $boxed = sodium_crypto_box('hi', $n2, sodium_crypto_box_secretkey($a).sodium_crypto_box_publickey($b));
            $checks['sodium_box'] = sodium_crypto_box_open($boxed, $n2, sodium_crypto_box_secretkey($b).sodium_crypto_box_publickey($a)) === 'hi';
        } else {
            $this->skip('sodium', 'ext-sodium is core from PHP 7.2');
        }

        $r1 = random_bytes(32);
        $checks['random_bytes'] = strlen($r1) === 32 && $r1 !== random_bytes(32);
        $checks['random_int'] = ($n = random_int(5, 9)) >= 5 && $n <= 9;
        $checks['openssl_random'] = strlen(openssl_random_pseudo_bytes(16, $strong)) === 16 && $strong;
        $checks['str_random'] = strlen(Str::random(40)) === 40 && Str::random(40) !== Str::random(40);
        $checks['uuid'] = (bool) preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/', (string) (method_exists(Str::class, 'uuid') ? Str::uuid() : \Ramsey\Uuid\Uuid::uuid4()));
        if (method_exists(Str::class, 'ulid')) {
            $checks['ulid'] = strlen((string) Str::ulid()) === 26;
        } else {
            $this->skip('ulid', 'Str::ulid() needs Laravel 9.2');
        }

        $rsa = openssl_pkey_new(['private_key_bits' => 2048, 'private_key_type' => OPENSSL_KEYTYPE_RSA]);
        $ok = $rsa !== false;
        $checks['openssl_rsa_generate'] = $ok;
        if ($ok) {
            openssl_pkey_export($rsa, $priv);
            $pub = openssl_pkey_get_details($rsa)['key'];
            openssl_sign('data', $s, $priv, OPENSSL_ALGO_SHA256);
            $checks['openssl_rsa_verify'] = openssl_verify('data', $s, $pub, OPENSSL_ALGO_SHA256) === 1;
            openssl_public_encrypt('oaep text', $ct, $pub, OPENSSL_PKCS1_OAEP_PADDING);
            openssl_private_decrypt($ct, $pt, $priv, OPENSSL_PKCS1_OAEP_PADDING);
            $checks['openssl_rsa_oaep'] = $pt === 'oaep text';
        }
        if (PHP_VERSION_ID >= 70100) {
            $ec = openssl_pkey_new(['curve_name' => 'prime256v1', 'private_key_type' => OPENSSL_KEYTYPE_EC]);
            $checks['openssl_ec_generate'] = $ec !== false;
        } else {
            $this->skip('openssl_ec_generate', 'openssl_pkey_new() takes no curve_name before PHP 7.1');
        }
        $checks['hmac'] = hash_hmac('sha256', 'a', 'k') === hash_hmac('sha256', 'a', 'k');

        return $this->out($checks, ['openssl' => OPENSSL_VERSION_TEXT, 'sodium' => defined('SODIUM_LIBRARY_VERSION') ? SODIUM_LIBRARY_VERSION : null]);
    }

    // ----------------------------------------------------------------- intl

    public function intl()
    {
        $c = [];
        $i = [];
        $nf = new \NumberFormatter('en_US', \NumberFormatter::DECIMAL);
        $s = $nf->format(1234567.891);
        $i['decimal'] = $s;
        $c['number_decimal'] = strpos($s, '1,234,567') === 0 && abs($nf->parse($s) - 1234567.891) < 0.001;
        $eur = new \NumberFormatter('de_DE', \NumberFormatter::CURRENCY);
        $s = $eur->formatCurrency(1234.5, 'EUR');
        $i['eur_de'] = $s;
        $c['number_currency'] = strpos($s, '€') !== false && strpos($s, '1.234,50') !== false;
        $c['number_spellout_en'] = stripos((new \NumberFormatter('en_US', \NumberFormatter::SPELLOUT))->format(123), 'hundred') !== false;
        $ru = (new \NumberFormatter('ru_RU', \NumberFormatter::SPELLOUT))->format(21);
        $i['ru_spellout'] = $ru;
        $c['number_spellout_ru'] = (bool) preg_match('/\p{Cyrillic}/u', $ru);
        $c['number_percent'] = strpos((new \NumberFormatter('en_US', \NumberFormatter::PERCENT))->format(0.256), '26') === 0;

        $df = new \IntlDateFormatter('en_US', \IntlDateFormatter::FULL, \IntlDateFormatter::FULL, 'UTC', \IntlDateFormatter::GREGORIAN, 'yyyy-MM-dd HH:mm:ss');
        $c['date_pattern'] = $df->format(86400 * 365) === '1971-01-01 00:00:00' && $df->parse('1971-01-01 00:00:00') === 86400 * 365;
        $month = (new \IntlDateFormatter('ru_RU', \IntlDateFormatter::NONE, \IntlDateFormatter::NONE, 'UTC', null, 'LLLL'))->format(86400 * 40);
        $i['ru_month'] = $month;
        $c['date_ru_month'] = (bool) preg_match('/^\p{Cyrillic}+$/u', $month);
        $tz = (new \IntlDateFormatter('en_US', \IntlDateFormatter::NONE, \IntlDateFormatter::NONE, 'Europe/Berlin', null, 'zzzz'))->format(1700000000);
        $i['berlin_zone_name'] = $tz;
        $c['date_timezone_name'] = $tz !== '' && $tz !== false;
        $cal = \IntlCalendar::createInstance('Asia/Tokyo', 'en_US@calendar=japanese');
        $c['calendar_japanese'] = $cal !== null && $cal->getType() === 'japanese';

        $col = new \Collator('ru_RU');
        $words = ['Яблоко', 'Арбуз', 'Вишня', 'Ёж', 'Банан'];
        $col->sort($words);
        $c['collator_ru'] = $words === ['Арбуз', 'Банан', 'Вишня', 'Ёж', 'Яблоко'];
        $en = ['b', 'A', 'a', 'B'];
        (new \Collator('en_US'))->sort($en);
        $c['collator_en'] = $en === ['a', 'A', 'b', 'B'];
        $c['collator_numeric'] = (function () {
            $x = ['file10', 'file2', 'file1'];
            $cl = new \Collator('en_US');
            $cl->setAttribute(\Collator::NUMERIC_COLLATION, \Collator::ON);
            $cl->sort($x);

            return $x === ['file1', 'file2', 'file10'];
        })();

        $c['normalizer_nfc'] = \Normalizer::normalize("e\u{0301}", \Normalizer::FORM_C) === "\u{e9}";
        $c['normalizer_nfd'] = strlen(\Normalizer::normalize("\u{e9}", \Normalizer::FORM_D)) === 3;
        $c['normalizer_nfkc'] = \Normalizer::normalize("\u{FB01}", \Normalizer::FORM_KC) === 'fi';
        $c['normalizer_is'] = \Normalizer::isNormalized("\u{e9}") && !\Normalizer::isNormalized("e\u{0301}");

        $tr = \Transliterator::create('Any-Latin; Latin-ASCII');
        $lat = $tr ? $tr->transliterate('Москва Санкт-Петербург') : '';
        $i['translit'] = $lat;
        $c['transliterator'] = $lat !== '' && !preg_match('/[^\x20-\x7e]/', $lat) && stripos($lat, 'mosk') === 0;
        $c['transliterator_upper'] = \Transliterator::create('Upper()')->transliterate('привет') === 'ПРИВЕТ';
        $c['idn_to_ascii'] = idn_to_ascii('пример.рф', IDNA_DEFAULT, INTL_IDNA_VARIANT_UTS46) === 'xn--e1afmkfd.xn--p1ai';
        $c['idn_to_utf8'] = idn_to_utf8('xn--e1afmkfd.xn--p1ai', IDNA_DEFAULT, INTL_IDNA_VARIANT_UTS46) === 'пример.рф';
        $c['grapheme'] = grapheme_strlen("e\u{0301}a\u{1F600}") === 3 && grapheme_substr("e\u{0301}a", 0, 1) === "e\u{0301}";
        $bi = \IntlBreakIterator::createCharacterInstance('en_US');
        $bi->setText("e\u{0301}\u{1F600}x");
        $n = 0;
        foreach ($bi as $_) {
            $n++;
        }
        $c['break_iterator_characters'] = $n === 4; // three graphemes -> boundaries 0,2,6,7 => 4 positions

        $c['locale_accept'] = \Locale::acceptFromHttp('ru-RU,ru;q=0.9,en;q=0.8') === 'ru_RU';
        $c['locale_canonicalize'] = \Locale::canonicalize('EN-us') === 'en_US';
        $c['locale_display'] = \Locale::getDisplayLanguage('ru', 'en') !== '' && \Locale::getDisplayLanguage('ru', 'ru') !== '';
        $plural = function ($locale, $pattern, $n) {
            return \MessageFormatter::formatMessage($locale, $pattern, [$n]);
        };
        $c['plural_en'] = $plural('en_US', '{0, plural, one{# file} other{# files}}', 1) === '1 file'
            && $plural('en_US', '{0, plural, one{# file} other{# files}}', 5) === '5 files';
        $ruP = '{0, plural, one{# файл} few{# файла} many{# файлов} other{# файла}}';
        $c['plural_ru_cldr'] = [$plural('ru_RU', $ruP, 1), $plural('ru_RU', $ruP, 2), $plural('ru_RU', $ruP, 5), $plural('ru_RU', $ruP, 11), $plural('ru_RU', $ruP, 21), $plural('ru_RU', $ruP, 22)]
            === ['1 файл', '2 файла', '5 файлов', '11 файлов', '21 файл', '22 файла'];
        $c['intl_char'] = \IntlChar::charName(0x41) === 'LATIN CAPITAL LETTER A' && \IntlChar::isalpha('ж') && \IntlChar::ord('ж') === 0x436;
        $c['timezone_id'] = \IntlTimeZone::createTimeZone('Europe/Moscow')->getID() === 'Europe/Moscow';
        $c['spoofchecker'] = class_exists('Spoofchecker') ? (new \Spoofchecker())->isSuspicious('paypal') === false : true;
        $i['icu'] = INTL_ICU_VERSION;
        $i['cldr'] = INTL_ICU_DATA_VERSION;

        return $this->out($c, $i);
    }

    // ------------------------------------------------------------------ xml

    public function xml()
    {
        $c = [];
        $dom = new \DOMDocument('1.0', 'UTF-8');
        $root = $dom->createElementNS('urn:apptest', 't:root');
        $dom->appendChild($root);
        $item = $dom->createElement('item');
        $item->setAttribute('lang', 'ru');
        $item->appendChild($dom->createTextNode('Привет & 世界 😀 <tag>'));
        $root->appendChild($item);
        $root->appendChild($dom->createCDATASection('<raw>'));
        $xml = $dom->saveXML();
        $c['dom_build_roundtrip'] = simplexml_load_string($xml)->children()->item == 'Привет & 世界 😀 <tag>';
        $xp = new \DOMXPath($dom);
        $c['dom_xpath'] = $xp->query('//item[@lang="ru"]')->length === 1 && $xp->evaluate('string-length(//item)') == 19;

        $html = new \DOMDocument();
        libxml_use_internal_errors(true);
        $html->loadHTML('<?xml encoding="UTF-8"><html><body><p class="a">Привет <b>мир</b></p><p>два</p></body></html>');
        $c['dom_load_html'] = $html->getElementsByTagName('p')->length === 2 && $html->getElementsByTagName('b')->item(0)->textContent === 'мир';

        libxml_clear_errors();
        $bad = new \DOMDocument();
        $loaded = $bad->loadXML('<a><b></a>');
        $errs = libxml_get_errors();
        libxml_clear_errors();
        $c['libxml_errors'] = $loaded === false && count($errs) > 0;

        // No external entities: file:// in a DOCTYPE must not be read.
        $xxe = new \DOMDocument();
        $xxe->loadXML('<!DOCTYPE r [<!ENTITY x SYSTEM "file:///etc/passwd">]><r>&x;</r>');
        $c['xxe_not_expanded'] = strpos($xxe->documentElement ? (string) $xxe->documentElement->textContent : '', 'root:') === false;
        libxml_clear_errors();

        $sx = simplexml_load_string('<library><book id="1"><t>Война и мир</t></book><book id="2"><t>吾輩は猫である</t></book></library>');
        $c['simplexml_xpath'] = (string) $sx->xpath('//book[@id="2"]/t')[0] === '吾輩は猫である' && count($sx->book) === 2;
        $sx->addChild('book')->addChild('t', 'new');
        $c['simplexml_modify'] = count($sx->book) === 3 && strpos($sx->asXML(), '<t>new</t>') !== false;

        $w = new \XMLWriter();
        $w->openMemory();
        $w->setIndent(true);
        $w->startDocument('1.0', 'UTF-8');
        $w->startElement('feed');
        $w->writeAttribute('n', '2');
        $w->writeElement('title', 'Заголовок & <ok>');
        $w->startElement('raw');
        $w->writeCdata('x < y');
        $w->endElement();
        $w->endElement();
        $out = $w->outputMemory();
        $c['xmlwriter'] = strpos($out, '<title>Заголовок &amp; &lt;ok&gt;</title>') !== false && strpos($out, '<![CDATA[x < y]]>') !== false;

        $r = new \XMLReader();
        $r->XML($out);
        $names = [];
        while ($r->read()) {
            if ($r->nodeType === \XMLReader::ELEMENT) {
                $names[] = $r->name;
            }
        }
        $c['xmlreader'] = $names === ['feed', 'title', 'raw'];

        $xsd = '<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"><xs:element name="n" type="xs:integer"/></xs:schema>';
        $good = new \DOMDocument();
        $good->loadXML('<n>42</n>');
        $badn = new \DOMDocument();
        $badn->loadXML('<n>forty-two</n>');
        $c['schema_validate'] = @$good->schemaValidateSource($xsd) && !@$badn->schemaValidateSource($xsd);
        libxml_clear_errors();

        $c['dom_c14n'] = strpos($dom->C14N(), '<t:root xmlns:t="urn:apptest">') === 0;
        $info = ['libxml' => LIBXML_DOTTED_VERSION];
        if (class_exists('XSLTProcessor')) {
            $xsl = new \DOMDocument();
            $xsl->loadXML('<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"><xsl:output method="text"/><xsl:template match="/"><xsl:for-each select="//book"><xsl:value-of select="t"/>|</xsl:for-each></xsl:template></xsl:stylesheet>');
            $p = new \XSLTProcessor();
            $p->importStylesheet($xsl);
            $c['xsl_transform'] = $p->transformToXml(dom_import_simplexml($sx)->ownerDocument) === 'Война и мир|吾輩は猫である|new|';
            $info['xsl'] = true;
        } else {
            $info['xsl'] = false;
        }

        return $this->out($c, $info);
    }

    // -------------------------------------------------------------- archive

    public function archive()
    {
        $c = [];
        $i = [];
        $chunks = [];
        for ($n = 0; $n < 16384; $n++) {
            $chunks[] = md5("chunk$n");
        }
        $data = implode('', $chunks);
        $sha = hash('sha256', $data);
        $i['data_bytes'] = strlen($data);
        $i['data_sha256'] = $sha;

        $c['gzip'] = hash('sha256', gzdecode(gzencode($data, 6))) === $sha;
        $c['gzip_levels'] = hash('sha256', gzdecode(gzencode($data, 1))) === $sha && hash('sha256', gzdecode(gzencode($data, 9))) === $sha;
        $c['gzdeflate'] = hash('sha256', gzinflate(gzdeflate($data))) === $sha;
        $c['gzcompress'] = hash('sha256', gzuncompress(gzcompress($data))) === $sha;
        $c['zlib_encode_raw'] = hash('sha256', zlib_decode(zlib_encode($data, ZLIB_ENCODING_RAW))) === $sha;
        $inc = inflate_init(ZLIB_ENCODING_GZIP);
        $gz = gzencode($data);
        $plain = '';
        foreach (str_split($gz, 4096) as $part) {
            $plain .= inflate_add($inc, $part);
        }
        $c['inflate_streaming'] = hash('sha256', $plain) === $sha;
        $dc = deflate_init(ZLIB_ENCODING_DEFLATE);
        $zz = deflate_add($dc, $data, ZLIB_NO_FLUSH).deflate_add($dc, '', ZLIB_FINISH);
        $c['deflate_streaming'] = hash('sha256', gzuncompress($zz)) === $sha;
        $tmp = tempnam(sys_get_temp_dir(), 'apptest');
        $h = gzopen($tmp.'.gz', 'wb6');
        gzwrite($h, $data);
        gzclose($h);
        $c['gzopen_file'] = hash('sha256', implode('', gzfile($tmp.'.gz'))) === $sha && hash('sha256', file_get_contents('compress.zlib://'.$tmp.'.gz')) === $sha;
        unlink($tmp.'.gz');
        unlink($tmp);
        $c['filter_zlib'] = hash('sha256', gzinflate(file_get_contents('php://filter/read=zlib.deflate/resource=data://text/plain;base64,'.base64_encode($data)))) === $sha;

        // The stock 7.0 image's zstd extension spins forever in zstd_compress(). FPM
        // workers do not see APPTEST_STOCK (clear_env), so the tell is proc_open
        // being disabled, which only the stock images do; ours keep it for Composer.
        $zstdWhy = PHP_VERSION_ID < 70100 && !function_exists('proc_open') ? 'the stock 7.0 image\'s zstd_compress() never returns' : null;
        if (function_exists('zstd_compress') && !$zstdWhy) {
            $z = zstd_compress($data, 3);
            $c['zstd'] = hash('sha256', zstd_uncompress($z)) === $sha && strlen($z) < strlen($data);
            $c['zstd_levels'] = hash('sha256', zstd_uncompress(zstd_compress($data, 19))) === $sha;
            $i['zstd'] = true;
        } else {
            $i['zstd'] = false;
            $i['zstd_why'] = $zstdWhy ?: 'zstd extension not loaded';
        }
        if (function_exists('brotli_compress')) {
            $b = brotli_compress($data, 5);
            $c['brotli'] = hash('sha256', brotli_uncompress($b)) === $sha && strlen($b) < strlen($data);
            $i['brotli'] = true;
        } else {
            $i['brotli'] = false;
        }
        if (function_exists('msgpack_pack')) {
            $mp = ['a' => [1, 2, 'я'], 'b' => null, 'c' => 1.5, 'd' => str_repeat('x', 70000)];
            $c['msgpack'] = msgpack_unpack(msgpack_pack($mp)) === $mp;
            $i['msgpack'] = true;
        }
        if (function_exists('lz4_compress')) {
            $c['lz4'] = hash('sha256', lz4_uncompress(lz4_compress($data))) === $sha;
            $i['lz4'] = true;
        }

        // A small gzip and zip for the suite to open with Python's own readers.
        $sample = "Привет, мир\n日本語\n😀\n";
        $i['gzip_b64'] = base64_encode(gzencode($sample));
        $i['sample'] = $sample;

        $zipPath = tempnam(sys_get_temp_dir(), 'apptestzip');
        $zip = new \ZipArchive();
        $c['zip_open'] = $zip->open($zipPath, \ZipArchive::CREATE | \ZipArchive::OVERWRITE) === true;
        $zip->addFromString('файл.txt', 'содержимое');
        $zip->addFromString('日本語/テスト.txt', 'テスト');
        $zip->addFromString('emoji-😀.txt', 'ok');
        $zip->addFromString('big.bin', $data);
        $zip->setCompressionName('big.bin', \ZipArchive::CM_DEFLATE);
        $zip->addEmptyDir('empty');
        $c['zip_close'] = $zip->close();
        $zip = new \ZipArchive();
        $zip->open($zipPath);
        $names = [];
        for ($n = 0; $n < $zip->numFiles; $n++) {
            $names[] = $zip->getNameIndex($n);
        }
        $c['zip_names'] = $names === ['файл.txt', '日本語/テスト.txt', 'emoji-😀.txt', 'big.bin', 'empty/'];
        $c['zip_read'] = $zip->getFromName('файл.txt') === 'содержимое' && hash('sha256', $zip->getFromName('big.bin')) === $sha;
        $dir = sys_get_temp_dir().'/apptest-'.bin2hex(random_bytes(4));
        $c['zip_extract'] = $zip->extractTo($dir) && file_get_contents($dir.'/日本語/テスト.txt') === 'テスト';
        $zip->close();
        $i['zip_b64'] = base64_encode(file_get_contents($zipPath));
        $i['zip_size'] = filesize($zipPath);
        foreach (['файл.txt', '日本語/テスト.txt', 'emoji-😀.txt', 'big.bin'] as $f) {
            @unlink($dir.'/'.$f);
        }
        @unlink($dir.'/日本語/テスト.txt');
        @rmdir($dir.'/日本語');
        @rmdir($dir.'/empty');
        @rmdir($dir);
        unlink($zipPath);

        return $this->out($c, $i);
    }

    // ----------------------------------------------------------------- text

    public function text()
    {
        $c = [];
        $c['mb_len'] = mb_strlen('😀') === 1 && strlen('😀') === 4 && mb_strlen('日本語') === 3;
        $c['mb_case'] = mb_strtoupper('привет') === 'ПРИВЕТ' && mb_strtolower('ЁЖИК') === 'ёжик' && mb_convert_case('hello wörld', MB_CASE_TITLE) === 'Hello Wörld';
        $c['mb_substr'] = mb_substr('日本語テキスト', 2, 3) === '語テキ';
        $c['mb_width'] = mb_strwidth('日本') === 4 && mb_strwidth('abc') === 3;
        $c['mb_encode_cp1251'] = bin2hex(mb_convert_encoding('Привет', 'Windows-1251', 'UTF-8')) === 'cff0e8e2e5f2';
        $c['mb_encode_sjis'] = bin2hex(mb_convert_encoding('日本語', 'SJIS', 'UTF-8')) === '93fa967b8cea';
        $c['mb_encode_utf16'] = mb_convert_encoding(mb_convert_encoding('a😀я', 'UTF-16LE', 'UTF-8'), 'UTF-8', 'UTF-16LE') === 'a😀я';
        $c['mb_encode_gb18030'] = mb_convert_encoding(mb_convert_encoding('中文😀', 'GB18030', 'UTF-8'), 'UTF-8', 'GB18030') === '中文😀';
        $c['mb_detect'] = mb_detect_encoding('Привет', ['ASCII', 'UTF-8'], true) === 'UTF-8' && !mb_check_encoding("\xff\xfe", 'UTF-8');
        if (function_exists('mb_str_split')) {
            $c['mb_split'] = mb_str_split('a😀я') === ['a', '😀', 'я'];
        } else {
            $this->skip('mb_split', 'mb_str_split() needs PHP 7.4');
        }
        if (function_exists('mb_ord')) {
            $c['mb_ord_chr'] = mb_ord('😀') === 0x1F600 && mb_chr(0x44F) === 'я';
        } else {
            $this->skip('mb_ord_chr', 'mb_ord() needs PHP 7.2');
        }
        $c['iconv_cp1251'] = bin2hex(iconv('UTF-8', 'Windows-1251', 'Привет')) === 'cff0e8e2e5f2' && iconv('Windows-1251', 'UTF-8', "\xcf\xf0\xe8\xe2\xe5\xf2") === 'Привет';
        $c['iconv_strlen'] = iconv_strlen('Привет 😀') === 8 && iconv_substr('Привет мир', 7, 3, 'UTF-8') === 'мир';
        $c['iconv_latin1'] = bin2hex(iconv('UTF-8', 'ISO-8859-1', 'café')) === '636166e9';
        $c['str_slug'] = Str::slug('Привет мир') === 'privet-mir' && preg_match('/^[a-z-]+$/', Str::slug('Ёжик & Щука')) === 1;
        $c['str_ascii'] = (bool) preg_match('/^(Yo|Jo|E)z(h)?ik$/', Str::ascii('Ёжик'));
        $c['str_limit'] = Str::limit('Привет мир, как дела?', 10) === 'Привет мир...';
        $c['str_title'] = Str::title('привет мир') === 'Привет Мир';
        $c['html_entities'] = htmlspecialchars('<a href="x">&</a>') === '&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;' && html_entity_decode('&euro;&hearts;') === '€♥';
        $c['filter_var'] = filter_var('a@b.co', FILTER_VALIDATE_EMAIL) === 'a@b.co' && filter_var('x', FILTER_VALIDATE_EMAIL) === false
            && filter_var('12', FILTER_VALIDATE_INT) === 12 && filter_var('yes', FILTER_VALIDATE_BOOLEAN) === true
            && filter_var('::1', FILTER_VALIDATE_IP, FILTER_FLAG_IPV6) === '::1' && filter_var('https://a.b/c', FILTER_VALIDATE_URL) === 'https://a.b/c';
        parse_str('a[]=1&a[]=2&b[c]=%D1%8F', $q);
        $c['parse_str'] = $q === ['a' => ['1', '2'], 'b' => ['c' => 'я']];
        $c['preg_unicode'] = preg_match_all('/\p{Lu}/u', 'Привет Мир Hello World', $m) === 4 && preg_replace('/\s+/u', ' ', "a\u{00A0}\u{2003}b") === 'a b';
        $c['preg_named'] = preg_match('/(?<y>\d{4})-(?<m>\d{2})/', 'on 2024-05-06', $d) === 1 && $d['y'] === '2024' && $d['m'] === '05';
        // Catastrophic backtracking must end in an error return, not a crash.
        $r = @preg_match('/^(\w+\s?)*$/', str_repeat('a', 40).'!');
        $c['preg_backtrack_limit_survives'] = $r === false || $r === 0;
        // PCRE1 (PHP < 7.3) has a 32 KB JIT stack and answers this subject with an error return; a crash is what must not happen.
        $r = preg_match('/^(?:[a-z]+ )+end$/', str_repeat('word ', 20000).'end');
        $c['preg_jit_big_subject'] = $r !== false || (PHP_VERSION_ID < 70300 && preg_last_error() === PREG_JIT_STACKLIMIT_ERROR);
        $c['ctype'] = ctype_digit('123') && !ctype_digit('12a') && ctype_alpha('abc') && ctype_xdigit('fF0');
        $c['sprintf'] = sprintf('%05.1f|%-5s|%+d|%\'*8s|%u', 3.14159, 'ab', 5, 'x', 3) === '003.1|ab   |+5|*******x|3';
        $c['number_format'] = number_format(1234567.891, 2) === '1,234,567.89' && number_format(0.5) === '1';
        $c['strtotime'] = strtotime('2024-02-29 12:00:00 UTC') === 1709208000 && gmdate('Y-m-d', strtotime('2024-01-31 UTC +1 month')) === '2024-03-02';
        $c['base_convert'] = base_convert('ff', 16, 2) === '11111111' && bin2hex(pack('nvN', 1, 2, 3)) === '00010200'.'00000003';
        $c['array_funcs'] = array_sum(array_map(function ($x) {
            return $x ** 2;
        }, range(1, 10))) === 385 && array_slice([1, 2, 3, 4], 1, 2) === [2, 3] && array_unique([1, '1', 2, 2.0]) === [0 => 1, 2 => 2];
        $c['sort_stable'] = (function () {
            $a = [['k' => 1, 'v' => 'a'], ['k' => 0, 'v' => 'b'], ['k' => 1, 'v' => 'c'], ['k' => 0, 'v' => 'd']];
            usort($a, function ($x, $y) {
                return $x['k'] <=> $y['k'];
            });

            return implode('', array_column($a, 'v')) === 'bdac';
        })();
        $c['serialize_roundtrip'] = unserialize(serialize(Goldens::data())) == Goldens::data();
        $c['igbinary_roundtrip'] = !function_exists('igbinary_serialize') || igbinary_unserialize(igbinary_serialize(Goldens::data())) == Goldens::data();
        $c['json_unicode'] = json_encode('Привет 😀', JSON_UNESCAPED_UNICODE) === '"Привет 😀"' && str_replace(chr(92), '|', json_encode('😀')) === '"|ud83d|ude00"' && json_decode('"'.chr(92).'ud83d'.chr(92).'ude00"') === '😀';
        $c['uniqid'] = strlen(uniqid()) === 13 && uniqid() !== uniqid();
        $c['spl'] = (function () {
            $h = new \SplMinHeap();
            foreach ([5, 1, 3] as $x) {
                $h->insert($x);
            }
            $q = new \SplPriorityQueue();
            $q->insert('lo', 1);
            $q->insert('hi', 9);

            return $h->extract() === 1 && $q->extract() === 'hi' && iterator_count(new \ArrayIterator([1, 2, 3])) === 3;
        })();

        return $this->out($c);
    }

    // ----------------------------------------------------------------- misc

    public function misc(Request $request)
    {
        $c = [];
        $token = $this->token($request);

        $c['carbon_math'] = Carbon::parse('2024-02-29')->addYear()->toDateString() === '2025-03-01'
            && Carbon::parse('2024-01-31')->addMonthNoOverflow()->toDateString() === '2024-02-29'
            && Carbon::parse('2000-01-01 UTC')->diffInDays(Carbon::parse('2000-03-01 UTC')) == 60;
        $c['carbon_human'] = Carbon::parse('2000-01-01')->diffForHumans(Carbon::parse('2000-01-02')) === '1 day before';
        $c['carbon_timezone'] = Carbon::parse('2024-06-15 12:00:00', 'UTC')->setTimezone('Asia/Kolkata')->format('H:i P') === '17:30 +05:30';
        $c['carbon_test_now'] = (function () {
            Carbon::setTestNow('2030-01-01 00:00:00');
            $r = now()->year === 2030;
            Carbon::setTestNow();

            return $r;
        })();

        $col = collect([['n' => 'b', 'v' => 2], ['n' => 'a', 'v' => 1], ['n' => 'b', 'v' => 3]]);
        $c['collection'] = $col->groupBy('n')->map->sum('v')->all() === ['b' => 5, 'a' => 1]
            && $col->sortBy('v')->pluck('n')->values()->all() === ['a', 'b', 'b']
            && $col->pluck('v')->flip()->keys()->all() === [2, 1, 3]
            && collect([1, [2, [3]]])->flatten()->all() === [1, 2, 3]
            && collect(range(1, 10))->chunk(4)->map->count()->all() === [4, 4, 2]
            && collect(['a' => 1])->merge(['b' => 2])->keys()->all() === ['a', 'b'];
        if (class_exists(\Illuminate\Support\LazyCollection::class)) {
            $c['lazy_collection'] = \Illuminate\Support\LazyCollection::make(function () {
                for ($i = 1; $i <= 1000; $i++) {
                    yield $i;
                }
            })->filter(function ($x) {
                return $x % 7 === 0;
            })->take(5)->sum() === 105;
        } else {
            $this->skip('lazy_collection', 'LazyCollection needs Laravel 6');
        }

        $v = Validator::make(
            ['email' => 'bad', 'age' => 'x', 'name' => 'Ив', 'slug' => Post::find(1)->slug],
            ['email' => 'required|email', 'age' => 'integer', 'name' => 'required|min:3', 'slug' => 'required|exists:posts,slug']
        );
        $errors = $v->errors();
        $c['validator_messages'] = $v->fails() && $errors->has('email') && $errors->has('age') && $errors->has('name') && !$errors->has('slug');
        $c['validator_exists_unique'] = Validator::make(['s' => 'p1-nonexistent'], ['s' => 'exists:posts,slug'])->fails()
            && Validator::make(['e' => 'user1@apptest.test'], ['e' => 'unique:users,email'])->fails()
            && Validator::make(['e' => 'nobody@apptest.test'], ['e' => 'unique:users,email'])->passes();
        $c['translator'] = __('validation.required', ['attribute' => 'x']) === 'The x field is required.' && trans_choice('{1} one item|[2,*] :count items', 3) === '3 items';

        $fired = [];
        Event::listen('apptest.misc', function ($payload) use (&$fired) {
            $fired[] = $payload;
        });
        Event::dispatch('apptest.misc', ['ü']);
        $c['events'] = $fired === ['ü'];

        $posts = Post::forApi()->orderBy('id')->limit(3)->get();
        $mail = new PostDigest($posts);
        $html = $mail->render();
        $c['mail_render'] = collect($posts)->every(function ($p) use ($html) {
            return strpos($html, e($p->title)) !== false;
        });
        $subjects = Mailbox::deliver('reader@apptest.test', new PostDigest($posts));
        $c['mail_array_transport'] = count($subjects) >= 1 && strpos(end($subjects), 'Digest') !== false;

        $c['rate_limiter'] = (function () use ($token) {
            $key = 'apptest:rl:'.$token;
            $ok = [];
            // The RateLimiter facade is 8+; the class behind it is older.
            $limiter = app(\Illuminate\Cache\RateLimiter::class);
            if (method_exists($limiter, 'attempt')) {
                for ($i = 0; $i < 4; $i++) {
                    $ok[] = $limiter->attempt($key, 3, function () {
                    }, 60);
                }
                $limiter->clear($key);
            } else {
                // No attempt() before 8: the same three-then-refuse by hand.
                for ($i = 0; $i < 4; $i++) {
                    if ($limiter->tooManyAttempts($key, 3)) {
                        $ok[] = false;
                    } else {
                        $limiter->hit($key, 60);
                        $ok[] = true;
                    }
                }
                $limiter->clear($key);
            }

            return $ok === [true, true, true, false];
        })();

        $disk = Storage::disk('local');
        $path = "apptest/$token.txt";
        $disk->put($path, "Привет\n");
        $c['storage_local'] = $disk->exists($path) && $disk->get($path) === "Привет\n" && $disk->size($path) === 13 && $disk->delete($path) && !$disk->exists($path);
        // Channels are 5.6+; before that the Log facade is the single writer.
        (method_exists(app('log'), 'channel') ? Log::channel('single') : Log::getFacadeRoot())->info('apptest misc', ['token' => $token, 'text' => 'Привет 😀']);
        $c['log_channel'] = true;
        $c['artisan_inspire'] = Artisan::call('inspire') === 0 && trim(Artisan::output()) !== '';
        $c['config_env'] = app()->environment('production') && config('app.debug') === false && config('app.timezone') === 'UTC';

        $self = rtrim(config('apptest.self_url'), '/');
        if (class_exists(\Illuminate\Support\Facades\Http::class)) {
            try {
                $resp = \Illuminate\Support\Facades\Http::withHeaders(['Host' => 'apptest.test'])->timeout(10)->get($self.'/up');
                $c['http_client_self'] = $resp->successful();
            } catch (\Throwable $e) {
                $c['http_client_self'] = false;
            }
            $c['http_fake'] = (function () {
                \Illuminate\Support\Facades\Http::fake(['example.test/*' => \Illuminate\Support\Facades\Http::response(['ok' => true, 'msg' => 'Привет'], 201)]);
                $r = \Illuminate\Support\Facades\Http::get('http://example.test/api');

                return $r->status() === 201 && $r->json('msg') === 'Привет';
            })();
        } else {
            // The Http facade is 7+: the same two checks straight on Guzzle (curl).
            try {
                $resp = (new \GuzzleHttp\Client(['timeout' => 10, 'http_errors' => false, 'headers' => ['Host' => 'apptest.test']]))->get($self.'/up');
                $c['http_client_self'] = $resp->getStatusCode() === 200;
            } catch (\Throwable $e) {
                $c['http_client_self'] = false;
            }
            $c['http_fake'] = (function () {
                $mock = new \GuzzleHttp\Handler\MockHandler([new \GuzzleHttp\Psr7\Response(201, ['Content-Type' => 'application/json'], json_encode(['ok' => true, 'msg' => 'Привет'], JSON_UNESCAPED_UNICODE))]);
                $r = (new \GuzzleHttp\Client(['handler' => \GuzzleHttp\HandlerStack::create($mock)]))->get('http://example.test/api');

                return $r->getStatusCode() === 201 && json_decode((string) $r->getBody(), true)['msg'] === 'Привет';
            })();
        }

        return $this->out($c);
    }

    // ------------------------------------------------------------------- db

    public function db(Request $request)
    {
        $c = [];
        $token = $this->token($request);

        try {
            DB::transaction(function () use ($token) {
                JobLog::record('rolled-back', $token);
                throw new \RuntimeException('rollback');
            });
        } catch (\RuntimeException $e) {
        }
        $c['transaction_rollback'] = JobLog::where('kind', 'rolled-back')->where('token', $token)->count() === 0;
        DB::transaction(function () use ($token) {
            JobLog::record('committed', $token);
        });
        $c['transaction_commit'] = JobLog::where('kind', 'committed')->where('token', $token)->count() === 1;
        $c['nested_transaction_savepoint'] = (function () use ($token) {
            DB::beginTransaction();
            JobLog::record('outer', $token);
            DB::beginTransaction();
            JobLog::record('inner', $token);
            DB::rollBack();
            DB::commit();

            return JobLog::where('token', $token)->where('kind', 'outer')->count() === 1 && JobLog::where('token', $token)->where('kind', 'inner')->count() === 0;
        })();

        $text = 'Привет 😀 日本語 مرحبا ✨'.str_repeat('юникод ', 4000);
        $row = JobLog::record('utf8', $token, $text);
        $c['utf8mb4_roundtrip'] = JobLog::find($row->id)->payload === $text;
        $c['utf8mb4_emoji_where'] = JobLog::where('kind', 'utf8')->where('token', $token)->where('payload', 'like', '%😀%')->count() === 1;

        $media = Media::create(['user_id' => null, 'disk' => 'local', 'path' => 'x', 'original_name' => 'n', 'mime' => 'm', 'size' => 1,
            'meta' => ['a' => ['b' => [1, 2, '日本']], 'f' => 1.5, 'e' => []]]);
        $c['json_cast_roundtrip'] = Media::find($media->id)->meta === ['a' => ['b' => [1, 2, '日本']], 'f' => 1.5, 'e' => []];

        $seed = Post::query()->where('id', '<=', 500);
        $c['cursor'] = iterator_count((clone $seed)->cursor()) === 500; // a Generator before 6, a LazyCollection after
        if (method_exists(\Illuminate\Database\Eloquent\Builder::class, 'lazy')) {
            $c['lazy'] = (clone $seed)->lazy(100)->count() === 500;
        } else {
            $this->skip('lazy', 'lazy() needs Laravel 8');
        }
        $sum = 0;
        (clone $seed)->chunkById(64, function ($chunk) use (&$sum) {
            $sum += $chunk->sum('id');
        });
        $c['chunk_by_id'] = $sum === 500 * 501 / 2;
        $c['pluck_keyed'] = count(Post::query()->where('id', '<=', 10)->pluck('slug', 'id')) === 10;
        $c['eager_no_n_plus_one'] = (function () {
            DB::enableQueryLog();
            DB::flushQueryLog();
            $posts = Post::with(['user', 'tags'])->withCount('comments')->where('id', '<=', 30)->get();
            foreach ($posts as $p) {
                $p->user->name;
                $p->tags->count();
            }
            $n = count(DB::getQueryLog());
            DB::disableQueryLog();

            return $n === 3;
        })();
        $c['where_has_tag'] = Post::whereHas('tags', function ($q) {
            $q->where('tags.id', 1);
        })->where('id', '<=', 2000)->count() === DB::table('post_tag')->where('tag_id', 1)->where('post_id', '<=', 2000)->count();
        // A post of its own: the seeded pivot rows are what the goldens hash.
        $c['pivot_sync'] = (function () use ($token) {
            $post = Post::create(['user_id' => 1, 'title' => 'pivot '.$token, 'slug' => 'apptest-pivot-'.$token, 'excerpt' => 'x', 'body' => 'x', 'published_at' => now()]);
            $post->tags()->sync([3, 5, 8]);
            $post->tags()->sync([5, 9]);

            return $post->tags()->pluck('tags.id')->sort()->values()->all() === [5, 9];
        })();
        $c['aggregates_native_types'] = is_int(Post::where('id', '<=', 10)->max('views')) && is_int(Post::where('id', '<=', 10)->count());
        $c['paginate'] = Post::query()->orderBy('id')->paginate(7, ['*'], 'page', 3)->getCollection()->pluck('id')->all() === [15, 16, 17, 18, 19, 20, 21];
        $c['for_update_lock'] = DB::transaction(function () {
            return Post::where('id', 1)->lockForUpdate()->first() !== null;
        });
        $c['schema_introspection'] = \Illuminate\Support\Facades\Schema::hasTable('posts') && \Illuminate\Support\Facades\Schema::hasColumn('posts', 'slug')
            && in_array('utf8mb4', [DB::selectOne('SELECT @@character_set_connection AS c')->c]);
        $c['raw_typed_select'] = (function () {
            $r = DB::selectOne('SELECT 1 AS i, 1.5 AS d, 1e0 AS f, "s" AS s, NULL AS n, CAST("2024-01-01" AS DATE) AS dt');

            return $r->i === 1 && $r->s === 's' && $r->n === null && is_string($r->d) && is_float($r->f) && $r->dt === '2024-01-01';
        })();
        $c['big_int'] = DB::selectOne('SELECT 9223372036854775807 AS b')->b === PHP_INT_MAX;
        $c['user_model'] = User::find(1)->email === 'user1@apptest.test' && User::find(1)->posts()->count() > 0;

        return $this->out($c, ['server' => DB::selectOne('SELECT VERSION() AS v')->v]);
    }

    // ------------------------------------------------------------------ gmp

    public function gmp()
    {
        if (!extension_loaded('gmp')) {
            return response()->json(['loaded' => false]);
        }

        return response()->json([
            'loaded' => true,
            'pow' => gmp_strval(gmp_pow(3, 200)),
            'fact' => gmp_strval(gmp_fact(60)),
            'powm' => gmp_strval(gmp_powm(2, '123456789012345678901234567890', '1000000007')),
            'gcd' => gmp_strval(gmp_gcd('123456789012345678901234567890', '987654321098765432109876543210')),
            'prime' => gmp_prob_prime('170141183460469231731687303715884105727') > 0,
            'sqrt' => gmp_strval(gmp_sqrt('100000000000000000000000000000000000000')),
            'div' => gmp_strval(gmp_div_q('1000000000000000000000000000000', '7')),
            'bcmath_mul' => bcmul('123456789012345678901234567890', '987654321098765432109876543210', 0),
        ]);
    }

    // ---------------------------------------------------------------- queue

    public function queueDispatch(Request $request)
    {
        $token = $this->token($request);
        if (method_exists(RecordJob::class, 'dispatchSync')) {
            RecordJob::dispatchSync($token);
        } else {
            \Illuminate\Support\Facades\Bus::dispatchNow(new RecordJob($token)); // dispatchSync is 8+
        }
        $post = Post::findOrFail(1);
        QueuedJob::dispatch($post, Carbon::create(2024, 5, 6, 7, 8, 9, 'UTC'), $token, ['текст' => '日本語 😀', 'n' => [1, 2]])->onQueue('web');
        FailingJob::dispatch()->onQueue('web');

        return response()->json([
            'sync_recorded' => JobLog::where('kind', 'sync')->where('token', $token)->count(),
            'pending' => DB::table('jobs')->where('queue', 'web')->where('payload', 'like', '%'.$token.'%')->count(),
        ]);
    }

    public function queueDrain(Request $request)
    {
        $queue = preg_replace('/[^a-z]/', '', (string) $request->query('queue', 'web'));
        $options = ['--queue' => $queue, '--tries' => 1, '--sleep' => 0];
        if (version_compare(app()->version(), '8.0', '>=')) {
            $options['--stop-when-empty'] = true;
            $options['--max-time'] = 30;
            $code = Artisan::call('queue:work', $options);
        } else {
            // Before 8 a daemon that stops calls exit(), which would end this request, and 5.5 has no
            // --stop-when-empty at all: one job per call until the queue is dry.
            $options['--once'] = true;
            for ($n = 0; $n < 50 && DB::table('jobs')->where('queue', $queue)->count() > 0; $n++) {
                $code = Artisan::call('queue:work', $options);
            }
            $code = $code ?? 0;
        }

        return response()->json([
            'exit' => $code,
            'left' => DB::table('jobs')->where('queue', $queue)->count(),
            'queued_rows' => JobLog::where('kind', 'queued')->count(),
            'failed' => DB::table('failed_jobs')->count(),
        ]);
    }

    public function queueStatus(Request $request)
    {
        $token = $this->token($request);

        return response()->json(['log' => JobLog::where('token', $token)->orderBy('id')->get(['kind', 'payload'])->all()], 200, [], JSON_UNESCAPED_UNICODE);
    }

    public function stockJob()
    {
        return response()->json(['log' => JobLog::where('token', 'stock-queued')->get(['kind', 'payload'])->all()], 200, [], JSON_UNESCAPED_UNICODE);
    }
}
