<?php

namespace App\Apptest;

/*
 * Deterministic content. Nothing here may touch mt_rand/rand/shuffle or Faker:
 * their sequences differ between PHP versions, and the fixture has to be the
 * same bytes wherever it is built. Everything derives from a sha256 chain.
 */
class Content
{
    const LANGS = ['en', 'ru', 'zh', 'ja', 'ar', 'emoji'];

    const WORDS = [
        'en' => ['server', 'cache', 'request', 'kernel', 'socket', 'thread', 'buffer', 'stream', 'engine', 'module',
            'runtime', 'compile', 'profile', 'branch', 'signal', 'memory', 'garbage', 'opcode', 'router', 'queue',
            'worker', 'deploy', 'release', 'metric', 'latency', 'payload', 'header', 'cookie', 'session', 'token',
            'schema', 'record', 'index', 'commit', 'rollback', 'migrate', 'render', 'template', 'layout', 'widget',
            'pixel', 'vector', 'binary', 'string', 'number', 'object', 'closure', 'iterator', 'generator', 'monitor',
            'network', 'gateway', 'proxy', 'balance', 'cluster', 'replica', 'shard', 'backup', 'restore', 'upgrade'],
        'ru' => ['сервер', 'кеш', 'запрос', 'ядро', 'сокет', 'поток', 'буфер', 'движок', 'модуль', 'сборка',
            'профиль', 'ветка', 'сигнал', 'память', 'очередь', 'маршрут', 'воркер', 'релиз', 'метрика', 'задержка',
            'заголовок', 'сессия', 'токен', 'схема', 'запись', 'индекс', 'откат', 'шаблон', 'макет', 'пиксель',
            'вектор', 'строка', 'число', 'объект', 'замыкание', 'итератор', 'генератор', 'мониторинг', 'сеть', 'шлюз',
            'прокси', 'кластер', 'реплика', 'резерв', 'восстановление', 'обновление', 'Москва', 'Ёлка', 'Щука', 'Эхо'],
        'zh' => ['服务器', '缓存', '请求', '内核', '套接字', '线程', '缓冲', '引擎', '模块', '编译',
            '配置', '分支', '信号', '内存', '队列', '路由', '部署', '发布', '指标', '延迟',
            '会话', '令牌', '模式', '记录', '索引', '提交', '回滚', '模板', '布局', '像素',
            '向量', '字符串', '数字', '对象', '闭包', '迭代器', '生成器', '监控', '网络', '网关'],
        'ja' => ['サーバー', 'キャッシュ', 'リクエスト', 'カーネル', 'ソケット', 'スレッド', 'バッファ', 'エンジン', 'モジュール', 'コンパイル',
            '設定', '分岐', '信号', '記憶', '待ち行列', '経路', '配備', '公開', '指標', '遅延',
            'セッション', 'トークン', 'スキーマ', '記録', '索引', 'コミット', '巻き戻し', 'テンプレート', 'レイアウト', 'ピクセル',
            'ベクトル', '文字列', '数値', 'オブジェクト', 'クロージャ', 'ジェネレータ', 'ネットワーク', 'ゲートウェイ', 'こんにちは', '世界'],
        'ar' => ['خادم', 'ذاكرة', 'طلب', 'نواة', 'مقبس', 'خيط', 'مخزن', 'محرك', 'وحدة', 'ترجمة',
            'ملف', 'فرع', 'إشارة', 'طابور', 'مسار', 'نشر', 'إصدار', 'مقياس', 'تأخير', 'جلسة',
            'رمز', 'مخطط', 'سجل', 'فهرس', 'التزام', 'قالب', 'تخطيط', 'شبكة', 'بوابة', 'مرحبا'],
        'emoji' => ['😀', '🚀', '🔥', '✨', '☕', '❤', '👍', '🎉', '🐘', '🐍', '🌍', '⚡', '🔒', '📦', '🧪', '🛠'],
    ];

    // '' for the scripts that do not put spaces between words.
    const JOINER = ['en' => ' ', 'ru' => ' ', 'zh' => '', 'ja' => '', 'ar' => ' ', 'emoji' => ' '];
    const STOP = ['en' => '.', 'ru' => '.', 'zh' => '。', 'ja' => '。', 'ar' => '.', 'emoji' => '!'];

    public static function stream($seed)
    {
        return new Stream($seed);
    }

    public static function lang($i)
    {
        return self::LANGS[$i % count(self::LANGS)];
    }

    public static function words(Stream $s, $lang, $count)
    {
        $list = self::WORDS[$lang];
        $out = [];
        for ($k = 0; $k < $count; $k++) {
            $out[] = $list[$s->int(count($list))];
        }

        return implode(self::JOINER[$lang], $out);
    }

    // Emoji and Arabic posts get English words mixed in so they still read as text.
    private static function sentence(Stream $s, $lang)
    {
        $n = 5 + $s->int(7);
        $text = self::words($s, $lang, $n);
        if ($lang === 'emoji' || $lang === 'ar') {
            $text = self::words($s, 'en', 3).' '.$text;
        }

        return $text.self::STOP[$lang];
    }

    public static function title($i)
    {
        $s = self::stream("post-title:$i");
        $lang = self::lang($i);
        $t = self::words($s, $lang, 3 + $s->int(4));

        return mb_strtoupper(mb_substr($t, 0, 1)).mb_substr($t, 1)." #$i";
    }

    public static function slug($i)
    {
        $s = self::stream("post-slug:$i");

        return "p$i-".self::WORDS['en'][$s->int(60)].'-'.self::WORDS['en'][$s->int(60)];
    }

    public static function body($i)
    {
        $s = self::stream("post-body:$i");
        $lang = self::lang($i);
        $paragraphs = [];
        for ($p = 0, $np = 3 + $s->int(6); $p < $np; $p++) {
            $sentences = [];
            for ($k = 0, $ns = 2 + $s->int(4); $k < $ns; $k++) {
                $sentences[] = self::sentence($s, $lang);
            }
            $paragraphs[] = implode($lang === 'zh' || $lang === 'ja' ? '' : ' ', $sentences);
        }

        return implode("\n\n", $paragraphs);
    }

    public static function excerpt($body)
    {
        return mb_substr($body, 0, 140);
    }

    public static function comment($i)
    {
        $s = self::stream("comment:$i");
        $lang = self::lang($i + 2);

        return self::sentence($s, $lang).' '.self::sentence($s, $lang);
    }

    public static function author($i)
    {
        $s = self::stream("comment-author:$i");

        return ucfirst(self::WORDS['en'][$s->int(60)]).' '.ucfirst(self::WORDS['en'][$s->int(60)]);
    }

    public static function tagName($n)
    {
        $s = self::stream("tag:$n");
        $lang = self::lang($n);

        return self::words($s, $lang, 1 + ($lang === 'zh' || $lang === 'ja' ? 1 : 0))." $n";
    }

    public static function tagSlug($n)
    {
        $s = self::stream("tag-slug:$n");

        return "t$n-".self::WORDS['en'][$s->int(60)];
    }

    public static function userName($n)
    {
        $s = self::stream("user:$n");
        $lang = self::lang($n);
        $name = self::words($s, $lang, $lang === 'zh' || $lang === 'ja' ? 2 : 1);

        return mb_strtoupper(mb_substr($name, 0, 1)).mb_substr($name, 1)." $n";
    }

    public static function password($n)
    {
        return "Password-$n!";
    }

    public static function email($n)
    {
        return "user$n@apptest.test";
    }
}
