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
 *
 *   認証: なし（返すのは件数と状態だけ・秘密情報ゼロ。網境界＝Tailscale。
 *         last-tick.txt が既に同条件で公開されているのと同レベル）
 *
 *   返却: {"ok":true,"ts":...,"tick":{...},"hold":N,"agents":[{id,label,island,kind,status,...}]}
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
        fseek($fp, $size - $tailLen);
        $tail = (string)fread($fp, $tailLen);
    } else {
        $tail = '';
    }
    fclose($fp);
    $LINE = '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \S+ ';
    $lastRunPos = -1; $lastRunLabel = null; $lastTickPos = -1;
    if (preg_match_all('/' . $LINE . '\[run\] .*?label=(\S+?)\s+pending/mu', $tail, $mm, PREG_OFFSET_CAPTURE | PREG_SET_ORDER)) {
        $last = end($mm);
        $lastRunPos = $last[0][1];
        $lastRunLabel = $last[1][0];
    }
    if (preg_match_all('/' . $LINE . '\[tick\] /mu', $tail, $mm, PREG_OFFSET_CAPTURE)) {
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

    if ($runningLabel === $tickLabel)              $status = 'working';
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
    'unknownInbox' => $unknownInbox,             // 台帳に無い宛先の滞留（内容は出さず件数だけ）
    'agents'=> $agents,
], JSON_OPT | JSON_INVALID_UTF8_SUBSTITUTE);
if ($out === false) {                            // 不正UTF-8等での空200を防ぐ（Codex🟡）
    http_response_code(500);
    $out = '{"ok":false,"error":"encode_failed"}';
}
echo $out;
