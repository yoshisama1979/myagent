<?php
declare(strict_types=1);

/*
 * エージェントオフィス 状態API ── Phase 1（読み取り専用・書き込みゼロ）
 *
 * 3D「エージェントオフィス」UI（site/office/）のためのデータ源。
 * 既存の運用ファイルを読んで JSON にまとめるだけで、何も書き込まない。
 *
 *   データ源:
 *     - site/overseer/last-tick.txt   … agent-tick の心拍（2分毎・エージェント別 pending/action）
 *     - data/overseer/tick.log        … 末尾だけ読む（実行中 [run] の検知・直近の timeout/fail）
 *     - data/mailbox/new/*.json       … 宛先(to)別の未読件数（本文・件名は返さない）
 *     - data/mailbox/hold/*.json      … 社長の承認待ち件数
 *     - hana-tools /api/external/office-status … 人間の社員の在席・作業（読み取り専用・5分キャッシュ）
 *
 *   認証: なし（網境界＝Tailscale。last-tick.txt が既に同条件で公開されているのと同レベル）
 *         ※ hold の件名・社員の作業内容にはクライアント名が含まれる。Tailscale 内限定・社長の
 *           内部ダッシュボード専用という前提で返している（外部公開しないこと）。
 *           API トークンはサーバサイドで .env から読むだけで、レスポンスには一切出さない。
 *
 *   返却: {"ok":true,"ts":...,"tick":{...},"hold":N,"agents":[...],"employees":[...]}
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');

const JSON_OPT = JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT;

$ROOT     = realpath(__DIR__ . '/../../..');           // プロジェクトルート
$HEARTBEAT = $ROOT . '/site/overseer/last-tick.txt';
$TICKLOG   = $ROOT . '/data/overseer/tick.log';
$MAILBOX   = $ROOT . '/data/mailbox';

// ── VPS常駐エージェントの台帳（tick のラベル → 表示情報）──────────────────
// nextWake は crontab の daily 起動時刻（変更したらここも直す。Phase 1 は静的でよい）
$VPS_AGENTS = [
    // tickラベル            id(=mailbox宛先)      表示名                       島          daily起床
    'chat'              => ['id' => 'hanasaka-main',      'label' => '会話窓口',             'island' => 'office',   'wake' => null],
    'memo-triage'       => ['id' => 'memo',               'label' => 'メモ係',               'island' => 'office',   'wake' => '23:00'],
    'comms'             => ['id' => 'comms',              'label' => '会話整理｜Chatwork',   'island' => 'office',   'wake' => '2時間おき 6-22時'],
    'finance'           => ['id' => 'finance',            'label' => '経理',                 'island' => 'office',   'wake' => null],
    'overseer'          => ['id' => 'overseer',           'label' => '統括',                 'island' => 'exec',     'wake' => '01:00'],
    'partner'           => ['id' => 'partner',            'label' => '経営パートナー',        'island' => 'exec',     'wake' => '07:00'],
    'hp-loop:ycom'      => ['id' => 'hp-loop-ycom',       'label' => '解析｜自社YCOM',        'island' => 'analysis', 'wake' => '02:00'],
    'hp-loop:yoshida'   => ['id' => 'hp-loop-yoshida',    'label' => '解析｜よしだ歯科',      'island' => 'analysis', 'wake' => '02:30'],
    'hp-loop:fujisaka'  => ['id' => 'hp-loop-fujisaka',   'label' => '解析｜藤阪ガス',        'island' => 'analysis', 'wake' => '03:00'],
    'hp-loop:yokohawaii'=> ['id' => 'hp-loop-yokohawaii', 'label' => '解析｜ヨーコハワイ',    'island' => 'analysis', 'wake' => '03:30'],
    'hp-loop:rally'     => ['id' => 'hp-loop-rally',      'label' => '解析｜スタンプラリー',  'island' => 'analysis', 'wake' => '月 04:00'],
    'hp-loop:konjaku'   => ['id' => 'hp-loop-konjaku',    'label' => '解析｜今昔写語',        'island' => 'analysis', 'wake' => '月 04:30'],
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

/** JSONを1階層だけ安全に読んで "to" を返す（壊れたファイル・巨大ファイル・symlink は無視） */
function mail_to(string $file): ?string {
    if (!is_file($file) || is_link($file)) return null;
    $sz = @filesize($file);
    if ($sz === false || $sz > 65536) return null;   // 1メッセージ64KB上限（mailbox API と同じ）
    $j = json_decode((string)@file_get_contents($file), true);
    return (is_array($j) && isset($j['to']) && is_string($j['to'])) ? $j['to'] : null;
}

// ── 1) mailbox: 宛先別の未読件数・承認待ち件数 ────────────────────────────
$inbox = [];                                    // to => count
foreach (array_slice(glob($MAILBOX . '/new/*.json') ?: [], 0, 500) as $f) {   // 走査上限500（Codex🟡）
    $to = mail_to($f);
    if ($to !== null) $inbox[$to] = ($inbox[$to] ?? 0) + 1;
}
$holdCount = count(glob($MAILBOX . '/hold/*.json') ?: []);
// 承認待ちの中身（3Dポップアップ・hold.html 用＝社長要望 2026-07-18）。閲覧のみで承認操作は無い。
// Tailscale内限定の前提で件名＋本文冒頭を返す（本文は1200字で打ち切り・走査20件上限・mail_to と同じ防御）
// mtime降順に並べてから20件に絞る＝21件以上あっても「最新20件」を保証（Codexレビュー 2026-07-28）
$holdItems = [];
$holdFiles = glob($MAILBOX . '/hold/*.json') ?: [];
usort($holdFiles, fn($a, $b) => (@filemtime($b) ?: 0) <=> (@filemtime($a) ?: 0));
foreach (array_slice($holdFiles, 0, 20) as $f) {
    if (!is_file($f) || is_link($f)) continue;
    $sz = @filesize($f);
    if ($sz === false || $sz > 65536) continue;
    $j = json_decode((string)@file_get_contents($f), true);
    if (!is_array($j)) continue;
    $s = fn($k) => is_string($j[$k] ?? null) ? $j[$k] : '';
    $holdItems[] = [
        'id'      => $s('id') !== '' ? $s('id') : basename($f, '.json'),
        'from'    => $s('from'), 'to' => $s('to'), 'type' => $s('type'), 'ts' => $s('ts'),
        'subject' => mb_substr($s('subject') !== '' ? $s('subject') : '(件名なし)', 0, 120),
        'preview' => mb_substr($s('body'), 0, 1200),
    ];
}
usort($holdItems, fn($a, $b) => strcmp($b['ts'], $a['ts']));   // 新しい順

// ── 1.5) 解析掲示板の「🔔 社長への質問」────────────────────────────────
// 各掲示板 index.html の 🔔 セクションから ID 付きの未対応項目（Q-NNN / Q-Y07 / PI-009 等）を抽出。
// ✅/解決/回答済 の文脈にある ID は除外。番号なしの質問は拾えない（制約＝UI側にも明示）。
// 'agent' ＝ 3Dオフィスでその質問を吹き出しで知らせるキャラクター（$AGENTS の id）。
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
function board_questions(string $path): array {
    if (!is_file($path) || is_link($path)) return [];
    $sz = @filesize($path);
    if ($sz === false || $sz > 400000) return [];
    $html = (string)@file_get_contents($path);
    // 🔔 見出し（コメント行でなく本文側）からセクション末尾（次の ===== コメント）までを切り出す
    $pos = strpos($html, '🔔');
    if ($pos === false) return [];
    $next = strpos($html, '🔔', $pos + 4);            // 1つ目がHTMLコメントのことが多い→2つ目を優先
    if ($next !== false && $next - $pos < 400) $pos = $next;
    $end = strpos($html, '<!-- =====', $pos + 10);
    $slice = substr($html, $pos, ($end !== false ? $end - $pos : 14000));
    // タグ除去→エンティティ復元（&lt;等の二重表示防止。表示側で再エスケープされるので安全）→空白圧縮
    $text = html_entity_decode(strip_tags($slice), ENT_QUOTES | ENT_HTML5, 'UTF-8');
    $text = preg_replace('/\s+/u', ' ', $text) ?? '';
    // ID付き項目を拾い、「解決済みの言及」を除外する（掲示板は散文なのでヒューリスティック）：
    //   (a) 直前180バイト（約60字）に解決系キーワード … 「✅ Q-001 確定」型。バイト窓のため
    //       UTF-8の途中切りが起き得る＝正規表現は /u を付けない（不正UTF-8で判定不能に落ちない）
    //   (b) IDの直後30字（mb）に解決系キーワード      … 「Q-J05（…）は解決済み」型
    //   (c) スニペット90字内に「アーカイブ」           … 「Q-Y02・Q-Y03…は アーカイブ」型の列挙
    //   seen は「未対応として採用した時だけ」立てる＝先に解決済み言及があっても、後方に同IDの
    //   未対応項目があれば拾う（Codexレビュー 2026-07-28）
    $items = [];
    if (preg_match_all('/(?:Q|PI)-[A-Z]{0,3}\d{1,4}/u', $text, $mm, PREG_OFFSET_CAPTURE)) {
        $seen = [];
        $done = '✅|解決|解消|決着|完了|クローズ|回答済|対応済|アーカイブ';
        foreach ($mm[0] as [$id, $bytePos]) {
            if (isset($seen[$id])) continue;
            $before = substr($text, max(0, $bytePos - 180), min(180, $bytePos));
            if (preg_match('/' . $done . '/', $before)) continue;
            $snippet = mb_substr(substr($text, $bytePos), 0, 90);
            $head = mb_substr($snippet, 0, 30);
            if (preg_match('/' . $done . '|確定|登録済/u', $head)) continue;
            if (mb_strpos($snippet, 'アーカイブ') !== false) continue;
            $seen[$id] = true;
            $items[] = ['id' => $id, 'text' => $snippet];
        }
    }
    return $items;
}
$qBoards = []; $qTotal = 0;
foreach ($QUESTION_BOARDS as $b) {
    $items = board_questions($ROOT . '/' . $b['file']);
    $qTotal += count($items);
    $qBoards[] = ['key' => $b['key'], 'label' => $b['label'], 'url' => $b['url'],
                  'agent' => $b['agent'], 'count' => count($items), 'items' => $items];
}

// ── 1.6) Chatwork整理板（Comms モード）: 台帳から社長のボール数を数える ──────────
// data/comms/chatwork/ledger.md（source of truth）の C-NNN 行を状態絵文字で集計するだけ。
// 件名・ルーム名（クライアント名を含む）はここでは返さない＝件数とリンクのみ（詳細は /comms/ で見る）。
// 台帳が無い（未導入・蒸留前）は null＝画面には「—」を出す（0件と偽らない）。
$comms = null;
$commsLedger = $ROOT . '/data/comms/chatwork/ledger.md';
if (is_file($commsLedger) && !is_link($commsLedger)) {
    $sz = @filesize($commsLedger);
    if ($sz !== false && $sz < 200000) {
        $md = (string)@file_get_contents($commsLedger);
        $red   = preg_match_all('/^C-\d+\s*\|\s*🔴/mu', $md);
        $green = preg_match_all('/^C-\d+\s*\|\s*🟢/mu', $md);
        $updated = null;
        if (preg_match('/蒸留済み:\s*([0-9]{4}-[0-9]{2}-[0-9]{2}[ 0-9:]*)/u', $md, $m)) $updated = trim($m[1]);
        $comms = ['red' => (int)$red, 'green' => (int)$green, 'updated' => $updated];
    }
}

// ── 1.7) 在席ビーコン: 呼ばれて動くサブエージェント・会話窓口のリアルタイム在席 ─────
// bin/office-beacon.sh が data/office/live/<id>/<key>.json（リース）を書く（働いている間は更新され続ける）。
// リース方式＝同じ id に複数セッションが並行しても、各自のリースが別ファイルなので互いに消し合わない。
// 「有効なリースが1件でもあれば働き中」・表示（task/from）は最新のリースを採る（Codexレビュー 2026-07-29 🔴反映）。
// 走査は台帳（$VPS_AGENTS）の既知 id のディレクトリだけ＝未知 id・ゴミ蓄積で正規ビーコンが漏れない（同🟡反映）。
// mtime が TTL 以上古い・未来すぎるものは期限切れ＝落ちたセッションの残骸として無視（消しはしない＝ここは読み取り専用）。
$live = [];                                     // id => ['task'=>?, 'from'=>?]
foreach (array_column($VPS_AGENTS, 'id') as $lid) {
    $best = null; $bestMt = -1;
    foreach (array_slice(glob($ROOT . '/data/office/live/' . $lid . '/*.json') ?: [], 0, 20) as $f) {
        if (!is_file($f) || is_link($f)) continue;
        $sz = @filesize($f);
        if ($sz === false || $sz > 8192) continue;
        $j = json_decode((string)@file_get_contents($f), true);
        if (!is_array($j)) continue;
        $ttl = max(60, min(is_numeric($j['ttl'] ?? null) ? (int)$j['ttl'] : 600, 3600));
        $mt = @filemtime($f);
        if ($mt === false) continue;
        $age = time() - $mt;
        if ($age >= $ttl || $age < -60) continue;   // 期限切れ・大きな未来mtimeは拒否（Codex🟢）
        if ($mt > $bestMt) {
            $s = fn($k, $n) => is_string($j[$k] ?? null) ? mb_substr($j[$k], 0, $n) : null;
            $best = ['task' => $s('task', 120), 'from' => $s('from', 40)];
            $bestMt = $mt;
        }
    }
    if ($best !== null) $live[$lid] = $best;
}

// ── 2) heartbeat: エージェント別の pending / action ──────────────────────
// 形式: agent-tick alive: <ts> | mode=.. force=.. | label:pending:action ... | status=..
$hb = @file_get_contents($HEARTBEAT);
$tickTs = null; $tickMode = null; $tickStatus = null;
$hbStates = [];                                 // tickラベル => ['pending'=>, 'action'=>]
if (is_string($hb) && $hb !== '') {
    if (preg_match('/alive:\s*([0-9: JST\-]+)\s*\|/', $hb, $m)) $tickTs = trim($m[1]);
    if (preg_match('/mode=(\S+)/', $hb, $m))   $tickMode   = $m[1];
    if (preg_match('/status=(\S+)/', $hb, $m)) $tickStatus = $m[1];
    // ラベル本体に「:」を含む（hp-loop:ycom）ので、後ろ2要素を pending / action として切る。
    // 時刻等の誤キャプチャ・ログ混入対策として、台帳（$VPS_AGENTS）に実在するラベルだけ採用する（Codex🔴/🟡）
    if (preg_match_all('/(\S+?):([0-9-]+):(\S+)/', $hb, $mm, PREG_SET_ORDER)) {
        foreach ($mm as $t) {
            $label = $GLOBALS['LABEL_ALIAS'][$t[1]] ?? $t[1];
            if (!isset($GLOBALS['VPS_AGENTS'][$label])) continue;   // 未知ラベルは無視
            $hbStates[$label] = ['pending' => $t[2], 'action' => $t[3]];
        }
    }
}
$hbAgeSec = null;
if ($tickTs !== null) {
    $dt = DateTime::createFromFormat('Y-m-d H:i:s T', $tickTs, new DateTimeZone('Asia/Tokyo'));
    if ($dt) $hbAgeSec = max(0, time() - $dt->getTimestamp());
}

// ── 3) tick.log 末尾: 実行中の検知 ────────────────────────────────────────
// tick は直列（flock）なので「最後の [run] 行のあとに [tick] 行が無い」＝その run が今も実行中。
// claude の標準出力も同じログに混ざるため、「タイムスタンプで始まる行」の [run]/[tick] だけを
// 行頭アンカー付きで抽出し（ログ混入による偽 [run] を排除＝Codex🔴XSS対策）、
// さらにラベルは台帳に実在するものだけ採用する。
$runningLabel = null;
$fp = @fopen($TICKLOG, 'rb');
if ($fp) {
    $st = fstat($fp);                            // 切り詰めと競合しないよう開いたハンドルから取る
    $size = is_array($st) ? (int)($st['size'] ?? 0) : 0;
    $tailLen = min($size, 65536);                // 末尾64KBだけ読む（ログは512KBで切り詰め運用）
    if ($tailLen > 0) {
        // 切り口の直前1バイトも読む＝切り口が行頭ぴったりか判定する（完全な行を誤って捨てない＝Codex🔴）
        $extra = ($tailLen < $size) ? 1 : 0;
        fseek($fp, $size - $tailLen - $extra);
        $tail = (string)fread($fp, $tailLen + $extra);
        if ($extra) {
            if ($tail[0] === "\n") {
                $tail = substr($tail, 1);          // 切り口＝行頭。先頭行は完全なので残す
            } else {
                // 欠け行を行ごと捨てる（バイト切りでUTF-8文字が割れていても一緒に除去される）
                $nl = strpos($tail, "\n");
                $tail = ($nl === false) ? '' : substr($tail, $nl + 1);
            }
        }
    } else {
        $tail = '';
    }
    fclose($fp);
    $LINE = '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \S+ ';
    $lastRunPos = -1; $lastRunLabel = null; $lastTickPos = -1;
    // /u は付けない（バイト指向で照合）：バイト切りの端やclaude出力に不正UTF-8が混ざると、
    // /u は preg_match_all 全体が失敗し「実行中なし」に化ける（心拍誤警報の実バグ 2026-07-17）。
    // 照合対象（タイムスタンプ・[run]/[tick]・label）はすべてASCIIなのでバイト照合で同じ結果になる。
    if (preg_match_all('/' . $LINE . '\[run\] .*?label=(\S+?)\s+pending/m', $tail, $mm, PREG_OFFSET_CAPTURE | PREG_SET_ORDER)) {
        $last = end($mm);
        $lastRunPos = $last[0][1];
        $lastRunLabel = $last[1][0];
    }
    if (preg_match_all('/' . $LINE . '\[tick\] /m', $tail, $mm, PREG_OFFSET_CAPTURE)) {
        $lastTickPos = end($mm[0])[1];
    }
    if ($lastRunPos >= 0 && $lastRunPos > $lastTickPos && $lastRunLabel !== null) {
        $lbl = $GLOBALS['LABEL_ALIAS'][$lastRunLabel] ?? $lastRunLabel;
        if (isset($GLOBALS['VPS_AGENTS'][$lbl])) $runningLabel = $lbl;   // 台帳照合（未知は無視）
    }
}

// ── 4) エージェント一覧を組み立て ─────────────────────────────────────────
$agents = [];
foreach ($VPS_AGENTS as $tickLabel => $meta) {
    $st      = $hbStates[$tickLabel] ?? null;
    $pending = ($st && $st['pending'] !== '-') ? (int)$st['pending'] : 0;
    $action  = $st['action'] ?? 'unknown';
    $mailboxPending = $inbox[$meta['id']] ?? 0;  // heartbeat が古い場合に備え mailbox 実測も見る
    $pend    = max($pending, $mailboxPending);

    // 異常判定：action の (TIMEOUT)/(ERR<rc>)、または tick status の <tickラベル>-timeout/-fail(rc)
    // ※ status はラベル基準（id ではない）＝agent-tick.sh の fail "$label-..." に合わせる（Codex🔴）
    $failed = str_contains($action, 'TIMEOUT') || preg_match('/ERR\d/', $action)
        || str_contains((string)$tickStatus, $tickLabel . '-timeout')
        || str_contains((string)$tickStatus, $tickLabel . '-fail');

    // 在席ビーコン＝「今この瞬間、実際に動いている」ので過去の失敗表示より優先する
    $liveRec = $live[$meta['id']] ?? null;
    if ($runningLabel === $tickLabel)              $status = 'working';
    elseif ($liveRec !== null)                     $status = 'working';
    elseif ($failed)                               $status = 'error';
    elseif ($pend > 0)                             $status = 'inbox';
    else                                           $status = 'idle';

    $agents[] = [
        'id'       => $meta['id'],
        'label'    => $meta['label'],
        'island'   => $meta['island'],
        'kind'     => 'vps',
        'status'   => $status,
        'inbox'    => $pend,
        'nextWake' => $meta['wake'],
        'live'     => $liveRec,                  // 在席ビーコン（task/from）。無ければ null
    ];
}
// 別拠点：台帳にある既知の宛先だけ机を出す。未知の宛先は昇格させず件数だけ集約する
// （任意の "to" 文字列を id/label として画面へ流さない＝Codex🔴）
$unknownInbox = 0;
$knownIds = array_column($agents, 'id');
foreach ($inbox as $to => $n) {
    if (!isset($REMOTE_AGENTS[$to]) && !in_array($to, $knownIds, true)) $unknownInbox += $n;
}
foreach ($REMOTE_AGENTS as $id => $label) {
    $agents[] = [
        'id'       => $id,
        'label'    => $label,
        'island'   => 'dev-remote',
        'kind'     => 'remote',
        'status'   => 'remote',                  // 中身は見えない（受信箱の山だけ描く）
        'inbox'    => $inbox[$id] ?? 0,
        'nextWake' => null,
    ];
}

// ── 5) hana-tools オフィス状況（人間の社員の在席・作業）──────────────────────
// 読み取り専用 GET。トークンは .env からサーバサイドで読むだけで、返却JSONには出さない。
// hana-tools に毎回叩きに行かないよう 5 分キャッシュ（社長方針 2026-07-23：負荷軽減）。
// 取得できないときは直前のキャッシュを stale 付きで返す（数字を捏造しない＝「未取得」を明示）。

/** .env から必要キーだけ安全に取り出す（source しない・他行のクオート崩れに巻き込まれない） */
function env_value(string $key, string $envFile): string {
    if (!is_file($envFile)) return '';
    $fp = @fopen($envFile, 'rb');
    if (!$fp) return '';
    $val = '';
    while (($line = fgets($fp)) !== false) {
        if (!preg_match('/^\s*' . preg_quote($key, '/') . '=(.*)$/', $line, $m)) continue;
        $v = rtrim($m[1], "\r\n");
        $v = trim($v);
        if (strlen($v) >= 2 && (($v[0] === '"' && substr($v, -1) === '"') || ($v[0] === "'" && substr($v, -1) === "'"))) {
            $v = substr($v, 1, -1);
        }
        $val = $v;
        break;                                   // 最初の一致のみ（hana-api.sh と同じ規約）
    }
    fclose($fp);
    return $val;
}

/** hana-tools の読み取りGETを1本にまとめる。戻り: ['json'=>array|null, 'error'=>string|null] */
function hana_api_get(string $path, string $root, int $timeout = 5): array {
    $envFile = $root . '/.env';
    $token = env_value('HANA_TOOLS_API_TOKEN', $envFile);
    $base  = env_value('HANA_TOOLS_BASE_URL', $envFile);
    if ($base === '') $base = 'https://stg.hana-tools.com';
    if ($token === '' || $token === 'your-token-here') return ['json' => null, 'error' => 'no_token'];
    if (!function_exists('curl_init'))                 return ['json' => null, 'error' => 'no_curl'];

    $ch = curl_init(rtrim($base, '/') . $path);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER     => ['X-API-TOKEN: ' . $token],
        CURLOPT_CONNECTTIMEOUT => 3,
        CURLOPT_TIMEOUT        => $timeout,   // ダッシュボードのポーリングを詰まらせない
        CURLOPT_SSL_VERIFYPEER => true,       // stg 証明書は現在有効（2026-07-28 実測）＝検証を無効化しない
        CURLOPT_SSL_VERIFYHOST => 2,
    ]);
    $body = curl_exec($ch);
    $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $cerr = curl_error($ch);
    curl_close($ch);
    if ($body === false || $cerr !== '') return ['json' => null, 'error' => 'network'];
    if ($code !== 200)                   return ['json' => null, 'error' => 'http_' . $code];
    $j = json_decode((string)$body, true);
    return is_array($j) ? ['json' => $j, 'error' => null] : ['json' => null, 'error' => 'bad_payload'];
}

/**
 * キャッシュ付きの取得。$fetch は ['payload'=>..,'error'=>..] を返すクロージャ。
 * 失敗時は直前の payload を stale で返し、fetchedAt は進める（＝APIが落ちている間、
 * 毎リクエストがタイムアウト待ちにならないバックオフ）。数字は決して作らない。
 */
function hana_cached(string $cacheFile, int $ttl, callable $fetch): array {
    $now = time();
    $cached = null;
    if (is_file($cacheFile) && !is_link($cacheFile)) {
        $j = json_decode((string)@file_get_contents($cacheFile), true);
        if (is_array($j) && array_key_exists('payload', $j)) $cached = $j;
    }
    $cachedAt = $cached ? (int)($cached['fetchedAt'] ?? 0) : 0;
    if ($cached && ($now - $cachedAt) < $ttl) {
        return ['payload' => $cached['payload'], 'fetchedAt' => $cachedAt,
                'stale' => (bool)($cached['stale'] ?? false), 'error' => $cached['error'] ?? null];
    }
    $r = $fetch();
    $payload = ($r['error'] === null) ? $r['payload'] : ($cached['payload'] ?? null);
    $rec = ['fetchedAt' => $now, 'payload' => $payload,
            'stale' => ($r['error'] !== null && $payload !== null), 'error' => $r['error']];
    // アトミック書き込み（読み手が壊れた JSON を掴まない）。書けなくても致命ではない＝無視して続行
    $dir = dirname($cacheFile);
    if (!is_dir($dir)) @mkdir($dir, 0775, true);   // 置き場が無い環境で毎回API直叩きになるのを防ぐ
    $tmp = $cacheFile . '.tmp' . getmypid();
    if (@file_put_contents($tmp, json_encode($rec, JSON_OPT | JSON_INVALID_UTF8_SUBSTITUTE)) !== false) {
        @rename($tmp, $cacheFile);
    } else {
        @unlink($tmp);
    }
    return ['payload' => $payload, 'fetchedAt' => $now, 'stale' => $rec['stale'], 'error' => $r['error']];
}

/** office-status（在席・作業）を5分キャッシュで取得（社長方針 2026-07-23：負荷軽減） */
function hana_office_status(string $root): array {
    return hana_cached($root . '/data/office/hana-office-status.json', 300, function () use ($root) {
        $r = hana_api_get('/api/external/office-status', $root);
        if ($r['error'] !== null) return ['payload' => null, 'error' => $r['error']];
        $j = $r['json'];
        if (!isset($j['employees']) || !is_array($j['employees'])) return ['payload' => null, 'error' => 'bad_payload'];
        return ['payload' => $j, 'error' => null];
    });
}

/**
 * 全社の未完了ToDoを1回だけ取得し、そこから
 *   ・担当者別の未完了／期日超過件数
 *   ・進行中の案件数（未完了ToDoを抱える work のうち status=in_progress の実数）
 *   ・全社合計
 * をまとめて算出する。**API呼び出しは1本**（担当者ごとに叩かない＝負荷軽減）。
 * TTL 30分（社長方針 2026-07-23：件数はリアルタイムでなくてよい）。
 *
 * 担当者の決め方：assignee_user_id が null のものは「作成者が担当」＝user_id に寄せる
 * （hana-tools 側の正規化仕様。bin/hana-api.sh の get_todos と同じ扱い）。
 * 期日は JST の日付で比較（due_date は UTC ISO8601 で返る）。
 * 「進行中の案件」は work.status を唯一の情報源とする（projects API は work の status を返さないため、
 * 未完了ToDoが1件も無い案件は数に入らない＝ボード上もその定義を明記する）。
 */
function hana_todo_counts(string $root): array {
    return hana_cached($root . '/data/office/hana-todo-counts.json', 1800, function () use ($root) {
        $r = hana_api_get('/api/external/todos?status=incomplete', $root, 8);
        if ($r['error'] !== null) return ['payload' => null, 'error' => $r['error']];
        $items = $r['json']['data'] ?? null;
        if (!is_array($items)) return ['payload' => null, 'error' => 'bad_payload'];

        $jst = new DateTimeZone('Asia/Tokyo');
        $today = (new DateTime('now', $jst))->format('Y-m-d');
        $per = []; $works = []; $open = 0; $overdue = 0;
        foreach ($items as $t) {
            if (!is_array($t)) continue;
            $uid = (int)($t['assignee_user_id'] ?? 0);
            if ($uid === 0) $uid = (int)($t['user_id'] ?? 0);
            if (!isset($per[$uid])) $per[$uid] = ['open' => 0, 'overdue' => 0];
            $per[$uid]['open']++; $open++;
            $due = $t['due_date'] ?? null;
            if (is_string($due) && $due !== '') {
                $dt = date_create_immutable($due);
                if ($dt && $dt->setTimezone($jst)->format('Y-m-d') < $today) {
                    $per[$uid]['overdue']++; $overdue++;
                }
            }
            $w = is_array($t['work'] ?? null) ? $t['work'] : null;
            if ($w && ($w['status'] ?? null) === 'in_progress' && !empty($w['id'])) $works[(int)$w['id']] = true;
        }
        return ['payload' => [
            'perUser'        => $per,
            'activeProjects' => count($works),
            'total'          => ['open' => $open, 'overdue' => $overdue],
        ], 'error' => null];
    });
}

$hana = hana_office_status($ROOT);
$todo = hana_todo_counts($ROOT);
$todoPer = (is_array($todo['payload']) && is_array($todo['payload']['perUser'] ?? null))
    ? $todo['payload']['perUser'] : null;
$employees = [];
$empSource = ['ok' => ($hana['error'] === null), 'stale' => $hana['stale'], 'error' => $hana['error'],
              'generatedAt' => null,
              'todo' => ['ok' => ($todo['error'] === null), 'stale' => $todo['stale'], 'error' => $todo['error']]];
if (is_array($hana['payload'])) {
    $empSource['generatedAt'] = is_string($hana['payload']['generated_at'] ?? null)
        ? $hana['payload']['generated_at'] : null;
    foreach ($hana['payload']['employees'] as $e) {
        if (!is_array($e)) continue;
        $id = (int)($e['id'] ?? 0);
        if (!isset($STAFF[$id])) continue;                    // 台帳に載せた人だけ机を出す
        $working = (bool)($e['working'] ?? false);
        $task = (is_array($e['task'] ?? null)) ? $e['task'] : null;
        $str = function ($v): ?string {
            return (is_string($v) && $v !== '') ? mb_substr($v, 0, 80) : null;
        };
        // 経過分（開始時刻から現在まで）。パースできなければ null＝画面には出さない
        $elapsed = null;
        if ($working && $task && is_string($task['started_at'] ?? null)) {
            $st = date_create_immutable($task['started_at']);
            if ($st) $elapsed = max(0, (int)floor((time() - $st->getTimestamp()) / 60));
        }
        $employees[] = [
            'id'      => $id,
            'label'   => $STAFF[$id]['label'],
            'name'    => $str($e['name'] ?? null) ?? $STAFF[$id]['label'],
            'role'    => $STAFF[$id]['role'],
            'note'    => $STAFF[$id]['note'] ?? null,   // 台帳側の補足（休職中 等）
            'working' => $working,
            'status'  => ($working ? 'working' : 'off'),
            'todayMinutes' => (int)($e['today_minutes'] ?? 0),
            'elapsedMin'   => $elapsed,
            'task'    => $task ? [
                'title'   => $str($task['title'] ?? null),
                'client'  => $str($task['client'] ?? null),
                'project' => $str($task['project'] ?? null),
            ] : null,
            // 担当ToDo（未完了・期日超過）。全社取得が成功していれば、その人の分が0件でも 0 を出す。
            // 取得自体ができていなければ null＝画面には出さない（0件と偽らない）
            'todos'   => ($todoPer === null) ? null : [
                'open'    => (int)($todoPer[(string)$id]['open'] ?? 0),
                'overdue' => (int)($todoPer[(string)$id]['overdue'] ?? 0),
            ],
        ];
    }
    // 台帳の並び順（社長→社員）で安定させる
    $order = array_keys($STAFF);
    usort($employees, fn($a, $b) => array_search($a['id'], $order, true) <=> array_search($b['id'], $order, true));
}

$out = json_encode([
    'ok'    => true,
    'ts'    => (new DateTime('now', new DateTimeZone('Asia/Tokyo')))->format(DATE_ATOM),
    'tick'  => [
        'lastSeen' => $tickTs,
        'ageSec'   => $hbAgeSec,
        'mode'     => $tickMode,
        'status'   => $tickStatus,
        'runningNow' => $runningLabel,
        // 心拍が読めない/古い（5分超）のに実行中でもない＝異常。心拍不在も「正常」に見せない（Codex🟡）
        'stale'    => (($hbAgeSec === null || $hbAgeSec > 300) && $runningLabel === null),
    ],
    'hold'  => $holdCount,                       // 社長の承認待ちトレイ
    'holdItems' => $holdItems,                   // 承認待ちの中身（新しい順・閲覧専用）
    'questions' => ['total' => $qTotal, 'boards' => $qBoards],   // 解析掲示板の社長への質問（ID付きのみ）
    'comms' => $comms,                           // Chatwork整理板（red=社長のボール/green=相手ボール/updated=蒸留時刻。未導入はnull）
    'unknownInbox' => $unknownInbox,             // 台帳に無い宛先の滞留（内容は出さず件数だけ）
    'agents'=> $agents,
    'employees' => $employees,                   // 人間の社員（hana-tools タイマー由来）
    'employeeSource' => $empSource,              // 取得できたか／古いか（捏造しないための状態）
    // 全社ボード（進行中の案件・未完了ToDo合計）。取得できていなければ null＝数字を出さない
    'company' => is_array($todo['payload']) ? [
        'activeProjects' => (int)($todo['payload']['activeProjects'] ?? 0),
        'todoOpen'       => (int)($todo['payload']['total']['open'] ?? 0),
        'todoOverdue'    => (int)($todo['payload']['total']['overdue'] ?? 0),
        'stale'          => $todo['stale'],
        'fetchedAt'      => $todo['fetchedAt'],
    ] : null,
], JSON_OPT | JSON_INVALID_UTF8_SUBSTITUTE);
if ($out === false) {                            // 不正UTF-8等での空200を防ぐ（Codex🟡）
    http_response_code(500);
    $out = '{"ok":false,"error":"encode_failed"}';
}
echo $out;
