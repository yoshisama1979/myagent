<?php
declare(strict_types=1);

/*
 * エージェントオフィス 共有台帳 ── status.php / activity.php が両方読む「名簿」
 *
 * 二重管理を避けるための切り出し（2026-08-05）。ここに載っているのは
 * 「誰がいるか」「どの掲示板が誰のものか」という**変わりにくい構造**だけで、
 * 状態（稼働中・件数）は一切持たない。状態は各APIが都度読む。
 *
 * ⚠️ このファイルは出力を持たない（require 専用）。直接叩かれても空の200を返すだけ。
 * ⚠️ モード・サイトを増やしたら、ここに1行足せば両APIに同時に反映される。
 */

if (!defined('JSON_OPT')) {
    define('JSON_OPT', JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT);
}

// ── VPS常駐エージェントの台帳（tick のラベル → 表示情報）──────────────────
// nextWake は crontab の daily 起動時刻（変更したらここも直す。Phase 1 は静的でよい）
$VPS_AGENTS = [
    // tickラベル            id(=mailbox宛先)      表示名                       島          daily起床
    'chat'              => ['id' => 'hanasaka-main',      'label' => '会話窓口',             'island' => 'office',   'wake' => null],
    'talk'              => ['id' => 'talk',               'label' => '相談窓口',             'island' => 'office',   'wake' => null],   // talk-tick.sh（毎分・応答中はビーコン点灯）
    'memo-triage'       => ['id' => 'memo',               'label' => 'メモ係',               'island' => 'office',   'wake' => '23:00'],
    'intake'            => ['id' => 'intake',             'label' => '取り込み係',           'island' => 'office',   'wake' => null],   // /intake＝対話型・無人不可
    'comms'             => ['id' => 'comms',              'label' => '会話整理｜Chatwork',   'island' => 'office',   'wake' => '2時間おき 6-22時'],
    'finance'           => ['id' => 'finance',            'label' => '経理',                 'island' => 'office',   'wake' => null],
    'overseer'          => ['id' => 'overseer',           'label' => '統括',                 'island' => 'exec',     'wake' => '01:00'],
    'partner'           => ['id' => 'partner',            'label' => '経営パートナー',        'island' => 'exec',     'wake' => '07:00'],
    'triage'            => ['id' => 'triage',             'label' => '残課題の仕分け',        'island' => 'exec',     'wake' => null],   // /triage＝社長が呼んだときだけ（定時実行しない）
    'hp-loop:ycom'      => ['id' => 'hp-loop-ycom',       'label' => '解析｜自社YCOM',        'island' => 'analysis', 'wake' => '02:00'],
    'hp-loop:yoshida'   => ['id' => 'hp-loop-yoshida',    'label' => '解析｜よしだ歯科',      'island' => 'analysis', 'wake' => '02:30'],
    'hp-loop:fujisaka'  => ['id' => 'hp-loop-fujisaka',   'label' => '解析｜藤阪ガス',        'island' => 'analysis', 'wake' => '03:00'],
    'hp-loop:yokohawaii'=> ['id' => 'hp-loop-yokohawaii', 'label' => '解析｜ヨーコハワイ',    'island' => 'analysis', 'wake' => '03:30'],
    'hp-loop:rally'     => ['id' => 'hp-loop-rally',      'label' => '解析｜スタンプラリー',  'island' => 'analysis', 'wake' => '月 04:00'],
    'hp-loop:konjaku'   => ['id' => 'hp-loop-konjaku',    'label' => '解析｜今昔写語',        'island' => 'analysis', 'wake' => '月 04:30'],
    'hp-improve'        => ['id' => 'hp-improve',         'label' => 'HP改善（単発）',        'island' => 'analysis', 'wake' => null],   // /hp-improve＝社長が呼んだときだけ
    'hp-prospect'       => ['id' => 'hp-prospect',        'label' => '営業レポート',          'island' => 'analysis', 'wake' => null],   // /hp-prospect＝営業用単発
    'hp-reply'          => ['id' => 'hp-reply',           'label' => '回答の代筆',            'island' => 'analysis', 'wake' => null],   // /hp-reply＝社長コメントの書記
    'reviewer'          => ['id' => 'reviewer',           'label' => 'プロジェクトレビュー',  'island' => 'analysis', 'wake' => null],   // /reviewer-cycle（ビーコン未搭載＝書込禁止の規律を優先）
    'blog-loop:ycom'    => ['id' => 'blog-loop-ycom',     'label' => 'ブログ分析｜YCOM',      'island' => 'blog',     'wake' => '05:00'],
    'blog-write:ycom'   => ['id' => 'blog-write-ycom',    'label' => 'ブログ執筆｜YCOM',      'island' => 'blog',     'wake' => '月 05:30'],
    'blog-improve:ycom' => ['id' => 'blog-improve-ycom',  'label' => 'ブログ改善｜YCOM',      'island' => 'blog',     'wake' => '月 06:00'],
];
// daily モードの tick では memo-triage が「memo」と表示される（同一人物として扱う）
$LABEL_ALIAS = ['memo' => 'memo-triage'];

// ── 別拠点（VPS外）エージェント：中身は見えない・受信箱の山だけ見える ─────────
$REMOTE_AGENTS = [
    'web-hanasaka' => '開発｜自社YCOM',
    'yoshida-dev'  => '開発｜よしだ歯科',
    'fujisaka-dev' => '開発｜藤阪ガス',
];

// ── 人間の社員（hana-tools users.id → 3Dオフィスの表示）─────────────────────
// office-status API は在籍者を全員返す（テスト用アカウント・サブアカウントも含む）。
// ここに載せた id だけ 3D に机を出す＝誰を出すかは社長が決める（増やすときはこの表に1行足す）。
// note は台帳側の補足（APIからは分からない事情）。状況が変わったらこの行を直す。
$STAFF = [
    34 => ['label' => '社長',  'role' => 'president', 'note' => null],       // 松田 祥宗
    37 => ['label' => '長谷',  'role' => 'staff',     'note' => null],       // 長谷 優里奈
    36 => ['label' => '渡邉',  'role' => 'staff',     'note' => '休職中'],   // 渡邉 有沙（復職したら note を null に）
];

// ── 解析掲示板の台帳（status.php＝🔔質問の抽出元／activity.php＝更新イベントの検知元）──
// 'agent' ＝ 3Dオフィスでその掲示板を担当するキャラクター（$VPS_AGENTS の id）。
// tick に登場しないサイト（滋賀トヨタ・大阪トヨペット）はキャラ不在＝null（コルクボードのみ）。
$QUESTION_BOARDS = [
    ['key' => 'ycom',        'label' => '解析｜自社YCOM',     'file' => 'site/hp-analysis/ycom/index.html',       'url' => '/hp-analysis/ycom/',       'agent' => 'hp-loop-ycom'],
    ['key' => 'yoshida',     'label' => '解析｜よしだ歯科',   'file' => 'site/hp-analysis/yoshida/index.html',    'url' => '/hp-analysis/yoshida/',    'agent' => 'hp-loop-yoshida'],
    ['key' => 'fujisaka',    'label' => '解析｜藤阪ガス',     'file' => 'site/hp-analysis/fujisaka/index.html',   'url' => '/hp-analysis/fujisaka/',   'agent' => 'hp-loop-fujisaka'],
    ['key' => 'yokohawaii',  'label' => '解析｜ヨーコハワイ', 'file' => 'site/hp-analysis/yokohawaii/index.html', 'url' => '/hp-analysis/yokohawaii/', 'agent' => 'hp-loop-yokohawaii'],
    ['key' => 'rally',       'label' => '解析｜スタンプラリー', 'file' => 'site/hp-analysis/rally/index.html',    'url' => '/hp-analysis/rally/',      'agent' => 'hp-loop-rally'],
    ['key' => 'konjaku',     'label' => '解析｜今昔写語',     'file' => 'site/hp-analysis/konjaku/index.html',    'url' => '/hp-analysis/konjaku/',    'agent' => 'hp-loop-konjaku'],
    ['key' => 'shigatoyota', 'label' => '解析｜滋賀トヨタ',   'file' => 'site/hp-analysis/shigatoyota/index.html', 'url' => '/hp-analysis/shigatoyota/', 'agent' => null],
    ['key' => 'osakatoyopet','label' => '解析｜大阪トヨペット', 'file' => 'site/hp-analysis/osakatoyopet/index.html', 'url' => '/hp-analysis/osakatoyopet/', 'agent' => null],
    ['key' => 'ycom-blog',   'label' => 'ブログ｜YCOM',       'file' => 'site/hp-analysis/ycom/blog/index.html',  'url' => '/hp-analysis/ycom/blog/',  'agent' => 'blog-loop-ycom'],
];

// ── 表示名だけ持つ宛先（机は出さない）──────────────────────────────────────
// mailbox に現れるが 3D に机を出さない相手。**机を出す／出さないは社長の決め事**なので、
// 名前を読めるようにするだけの表（ここに足しても office には机が増えない）。
$NAME_ONLY = [
    'president'      => '社長',
    'yokohawaii-dev' => '開発｜ヨーコハワイ',
    'rule-kaizen'    => 'ルール改善',
    // 旧称（無印）＝宛名ドリフトの孤児。SYSTEM.md の定点監視項目なので、あえて見える名前にする
    'hp-loop'        => '⚠️ 解析（旧称・宛名ドリフト）',
];

/**
 * mailbox の宛先id・tickラベル → 表示名を引く（未知はそのまま返す）。
 * 表示側で必ずエスケープすること（未知idは外部由来の文字列になり得る）。
 */
function office_label(string $id): string {
    foreach ($GLOBALS['VPS_AGENTS'] as $meta) {
        if ($meta['id'] === $id) return $meta['label'];
    }
    if (isset($GLOBALS['REMOTE_AGENTS'][$id])) return $GLOBALS['REMOTE_AGENTS'][$id];
    if (isset($GLOBALS['NAME_ONLY'][$id]))     return $GLOBALS['NAME_ONLY'][$id];
    return $id;
}
