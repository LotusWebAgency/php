<?php
// Shared by the seeders (wp eval-file). Everything here is deterministic:
// rand()/mt_rand() sequences differ across PHP versions, so every "random"
// choice is derived from a hash of a salt and a counter instead.

final class Gen
{
    // Dev-only knob to shrink the volumes while iterating on the recipe.
    // Fixtures are always built with it unset.
    public static function n(int $count): int
    {
        $scale = (int) (getenv('APPTEST_SCALE') ?: 1);
        return max(1, intdiv($count, max(1, $scale)));
    }

    // 28 bits, so it is a plain int on every platform.
    public static function h(string $salt, int $n): int
    {
        return hexdec(substr(md5($salt . ':' . $n), 0, 7));
    }

    public static function pick(array $list, string $salt, int $n)
    {
        return $list[self::h($salt, $n) % count($list)];
    }

    public static function between(int $lo, int $hi, string $salt, int $n): int
    {
        return $lo + self::h($salt, $n) % ($hi - $lo + 1);
    }

    const EN = ['amber', 'basalt', 'copper', 'delta', 'ember', 'fjord', 'granite', 'harbor', 'indigo', 'juniper',
        'kelp', 'lantern', 'meadow', 'nickel', 'orchard', 'prairie', 'quartz', 'ridge', 'saffron', 'tundra',
        'umber', 'valley', 'willow', 'xenon', 'yarrow', 'zephyr', 'anchor', 'bridge', 'canyon', 'dune',
        'engine', 'forest', 'glacier', 'horizon', 'island', 'journey', 'kernel', 'library', 'mirror', 'network',
        'quickly', 'slowly', 'carefully', 'brightly', 'often', 'never', 'always', 'rarely', 'and', 'with', 'over', 'under'];
    const RU = ['Быстрая', 'коричневая', 'лиса', 'прыгает', 'через', 'ленивую', 'собаку', 'Съешь', 'ещё', 'этих',
        'мягких', 'французских', 'булок', 'да', 'выпей', 'чаю', 'Привет', 'мир', 'сервер', 'отвечает', 'быстро', 'база', 'данных'];
    const ZH = ['你好', '世界', '快速', '的', '棕色', '狐狸', '跳过', '懒惰', '狗', '服务器', '响应', '数据库', '测试', '内容', 'こんにちは', 'データベース'];
    const AR = ['مرحبا', 'بالعالم', 'الثعلب', 'السريع', 'قاعدة', 'البيانات', 'اختبار', 'الخادم'];
    const HE = ['שלום', 'עולם', 'השועל', 'המהיר', 'בדיקה', 'מסד', 'נתונים'];
    const EMOJI = ['🚀', '🎉', '🦊', '📦', '✅', '🌍', '🔥', '💡'];

    public static function words(int $count, string $salt, int $n, int $lang = 0): string
    {
        $pools = [self::EN, self::RU, self::ZH, self::AR, self::HE, self::EMOJI];
        $out = [];
        for ($i = 0; $i < $count; $i++) {
            $pool = $lang === 0 ? self::EN : $pools[$lang];
            // Sprinkle a foreign word into English text now and then so
            // mixed-script paragraphs exist too.
            if ($lang === 0 && self::h($salt . 'x', $n * 100 + $i) % 9 === 0) {
                $pool = $pools[1 + self::h($salt . 'l', $n * 100 + $i) % 5];
            }
            $out[] = self::pick($pool, $salt, $n * 100 + $i);
        }
        return implode(' ', $out);
    }

    // The script of item $n: mostly English, with every kind of non-Latin
    // text represented at a fixed cadence.
    public static function lang(int $n): int
    {
        if ($n % 13 === 0) return 5;
        if ($n % 11 === 0) return 3;
        if ($n % 10 === 0) return 4;
        if ($n % 7 === 0) return 2;
        if ($n % 5 === 0) return 1;
        return 0;
    }

    public static function title(int $n, string $kind = 'Post'): string
    {
        $words = self::words(self::between(3, 6, 't', $n), 'title' . $kind, $n, self::lang($n));
        return ($kind === 'Post' ? '' : $kind . ' ') . $words . ' #' . sprintf('%04d', $n);
    }

    public static function date(int $n, int $stepSeconds = 61860): string
    {
        // 2023-01-01 00:00:00 UTC plus a step that lands the newest of a
        // thousand items in late 2024, spread across every month.
        return gmdate('Y-m-d H:i:s', 1672531200 + $n * $stepSeconds);
    }
}

final class Blocks
{
    public static function p(string $text): string
    {
        return "<!-- wp:paragraph -->\n<p>{$text}</p>\n<!-- /wp:paragraph -->";
    }

    public static function h(string $text, int $level = 2): string
    {
        $attr = $level === 2 ? '' : ' {"level":' . $level . '}';
        return "<!-- wp:heading{$attr} -->\n<h{$level} class=\"wp-block-heading\">{$text}</h{$level}>\n<!-- /wp:heading -->";
    }

    public static function ul(array $items): string
    {
        $li = '';
        foreach ($items as $item) {
            $li .= "<!-- wp:list-item -->\n<li>{$item}</li>\n<!-- /wp:list-item -->";
        }
        return "<!-- wp:list -->\n<ul class=\"wp-block-list\">{$li}</ul>\n<!-- /wp:list -->";
    }

    public static function quote(string $text, string $cite): string
    {
        return "<!-- wp:quote -->\n<blockquote class=\"wp-block-quote\"><!-- wp:paragraph -->\n<p>{$text}</p>\n<!-- /wp:paragraph --><cite>{$cite}</cite></blockquote>\n<!-- /wp:quote -->";
    }

    public static function code(string $text): string
    {
        return "<!-- wp:code -->\n<pre class=\"wp-block-code\"><code>" . esc_html($text) . "</code></pre>\n<!-- /wp:code -->";
    }

    public static function table(array $rows): string
    {
        $body = '';
        foreach ($rows as $row) {
            $body .= '<tr>' . implode('', array_map(function ($c) { return "<td>{$c}</td>"; }, $row)) . '</tr>';
        }
        return "<!-- wp:table -->\n<figure class=\"wp-block-table\"><table><tbody>{$body}</tbody></table></figure>\n<!-- /wp:table -->";
    }

    public static function separator(): string
    {
        return "<!-- wp:separator -->\n<hr class=\"wp-block-separator has-alpha-channel-opacity\"/>\n<!-- /wp:separator -->";
    }

    public static function more(): string
    {
        return "<!-- wp:more -->\n<!--more-->\n<!-- /wp:more -->";
    }

    public static function image(int $id, string $alt): string
    {
        $url = wp_get_attachment_image_url($id, 'large') ?: wp_get_attachment_url($id);
        $alt = esc_attr($alt);
        return "<!-- wp:image {\"id\":{$id},\"sizeSlug\":\"large\",\"linkDestination\":\"none\"} -->\n<figure class=\"wp-block-image size-large\"><img src=\"" . esc_url($url) . "\" alt=\"{$alt}\" class=\"wp-image-{$id}\"/></figure>\n<!-- /wp:image -->";
    }

    public static function buttons(string $label, string $url): string
    {
        return "<!-- wp:buttons -->\n<div class=\"wp-block-buttons\"><!-- wp:button -->\n<div class=\"wp-block-button\"><a class=\"wp-block-button__link wp-element-button\" href=\"" . esc_url($url) . "\">{$label}</a></div>\n<!-- /wp:button --></div>\n<!-- /wp:buttons -->";
    }

    public static function columns(string $left, string $right): string
    {
        return "<!-- wp:columns -->\n<div class=\"wp-block-columns\"><!-- wp:column -->\n<div class=\"wp-block-column\">" . self::p($left) . "</div>\n<!-- /wp:column -->\n\n<!-- wp:column -->\n<div class=\"wp-block-column\">" . self::p($right) . "</div>\n<!-- /wp:column --></div>\n<!-- /wp:columns -->";
    }

    // An article of 4-12 blocks whose shape depends only on $n.
    public static function article(int $n, array $imageIds = []): string
    {
        $lang = Gen::lang($n);
        $parts = [self::p(Gen::words(Gen::between(20, 40, 'lead', $n), 'lead', $n, $lang))];
        if ($n % 3 === 0) {
            $parts[] = self::more();
        }
        $parts[] = self::h(Gen::words(3, 'h2', $n, $lang));
        $paragraphs = Gen::between(2, 4, 'np', $n);
        for ($i = 0; $i < $paragraphs; $i++) {
            $parts[] = self::p(Gen::words(Gen::between(30, 70, 'p' . $i, $n), 'p' . $i, $n, $i % 2 ? 0 : $lang));
        }
        if ($n % 2 === 0) {
            $parts[] = self::ul([Gen::words(4, 'l1', $n), Gen::words(5, 'l2', $n, $lang), Gen::words(3, 'l3', $n)]);
        }
        if ($n % 4 === 1) {
            $parts[] = self::quote(Gen::words(12, 'q', $n, $lang), Gen::words(2, 'qc', $n));
        }
        if ($imageIds && $n % 3 !== 1) {
            $parts[] = self::image($imageIds[$n % count($imageIds)], Gen::words(4, 'alt', $n));
        }
        if ($n % 6 === 2) {
            $parts[] = self::code("<?php\necho " . var_export(Gen::words(2, 'code', $n), true) . ";\n// {$n} & <tag>");
        }
        if ($n % 7 === 3) {
            $parts[] = self::table([['id', 'value'], [(string) $n, Gen::words(1, 'c1', $n)], [(string) ($n + 1), Gen::words(1, 'c2', $n, $lang)]]);
        }
        if ($n % 9 === 4) {
            $parts[] = self::columns(Gen::words(10, 'ca', $n), Gen::words(10, 'cb', $n, $lang));
        }
        if ($n % 8 === 5) {
            $parts[] = self::buttons('Read more', home_url('/'));
        }
        $parts[] = self::separator();
        $parts[] = self::p(Gen::words(Gen::between(10, 25, 'tail', $n), 'tail', $n, $lang));
        return implode("\n\n", $parts);
    }
}

function apptest_manifest_path(): string
{
    return ABSPATH . '.apptest/manifest.json';
}

function apptest_part_path(string $name): string
{
    return ABSPATH . '.apptest/' . $name . '.json';
}

function apptest_write_json(string $path, array $data)
{
    file_put_contents($path, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) . "\n");
}

function apptest_read_json(string $path): array
{
    $data = json_decode(file_get_contents($path), true);
    if (!is_array($data)) {
        throw new RuntimeException("{$path}: " . json_last_error_msg());
    }
    return $data;
}

// The path (and query) of a permalink, the form the HTTP suite requests.
function apptest_path(string $url): string
{
    $p = wp_parse_url($url);
    return ($p['path'] ?? '/') . (isset($p['query']) ? '?' . $p['query'] : '');
}

function apptest_progress(string $what, int $i, int $total)
{
    if ($i % 250 === 0 || $i === $total) {
        fwrite(STDERR, sprintf("  %s %d/%d\n", $what, $i, $total));
    }
}
