<?php
declare(strict_types=1);

/*
 * エージェントオフィス 活動API ── 「何が起きたか」を時系列で返す（読み取り専用・書き込みゼロ）
 *
 * 契機＝3Dオフィスは「今どうか」しか映さず、**夜のうちに働いた分が朝には消えている**
 *      （設計メモ「夜型が朝に消える」）。そこで活動ティッカー／夜ダイジェスト用に
 *      「出来事」を都度組み立てて返す。台帳は新設しない＝既存の運用ファイルを読むだけ。
 *
 *   データ源（すべて既存・読むだけ）:
 *     - data/overseer/tick.log     … [run] 起動と、直後の [tick] 行から結果・所要時間を復元
 *                                     [ALERT] 行＝警報を鳴らした事実
 *     - data/mailbox/{cur,new,hold} … 誰から誰へどんな便が動いたか（件名は120字まで）
 *     - 掲示板ファイルの更新時刻      … 成果が出た事実（_agents.php の $QUESTION_BOARDS ＋ $EXTRA_OUTPUTS）
 *
 *   認証: なし（網境界＝Tailscale。status.php と同条件）
 *         ※ 件名・掲示板名にはクライアント名が含まれる。**社長の内部ダッシュボード専用**。
 *           外部公開しないこと。ここでも本文は返さない（件名まで）。
 *
 *   パラメータ: ?window=night | ?hours=N（1〜168・既定24）
 *               night ＝ 直近の 18:00 から現在まで（朝に開いて「昨夜の働き」を見るための窓）
 *   返却: {"ok":true,"ts":..,"window":{..},"events":[..],"digest":{..}}
 *
 *   負荷の約束: 3Dの状態ポーリング（status.php・5秒）とは別物で、こちらは**60秒に1回**の想定。
 *              走査は tick.log 末尾1MB（＝切り詰め運用の保持上限）＋mailbox は mtime で
 *              窓外を捨ててから読む（上限200件・超過分は digest.mailsSkipped で返す）。
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');

require_once __DIR__ . '/_agents.php';   // $VPS_AGENTS / $LABEL_ALIAS / $REMOTE_AGENTS / $QUESTION_BOARDS / JSON_OPT

$ROOT    = realpath(__DIR__ . '/../../..');
$TICKLOG = $ROOT . '/data/overseer/tick.log';
$MAILBOX = $ROOT . '/data/mailbox';
$JST     = new DateTimeZone('Asia/Tokyo');

const MAX_EVENTS   = 150;     // 返すイベント数の上限（古い方から捨てる）
const MAX_MAILS    = 200;     // mailbox の読み込み上限（窓内のうち新しい方から）
// tick.log は1MB超で末尾512KBに切り詰められる運用＝**保持されている全量が高々1MB**。
// そこで1MBまで読み切る（切り詰め直後は約1.3日・直前は約2.5日分が残っている）。
// 読めた最古の時刻は digest.runsSince として返し、足りない分を「0回」と偽らない。
const TAIL_BYTES   = 1048576;

// ── 掲示板以外の「成果物」置き場（更新時刻＝働いた証拠）─────────────────────
// path はプロジェクトルートからの相対。glob を含む場合は最新ファイルの時刻を採る。
$EXTRA_OUTPUTS = [
    ['path' => 'site/overseer/index.html',           'agent' => 'overseer',          'text' => '統括レポートを更新',       'url' => '/overseer/'],
    ['path' => 'site/notes.html',                    'agent' => 'memo',              'text' => '日常メモを清書',           'url' => '/notes.html'],
    ['path' => 'site/comms/index.html',              'agent' => 'comms',             'text' => 'Chatwork整理板を更新',     'url' => '/comms/'],
    ['path' => 'site/business/partner/index.html',   'agent' => 'partner',           'text' => '経営パートナー掲示板を更新', 'url' => '/business/partner/'],
    ['path' => 'site/business/partner/backlog.html', 'agent' => 'partner',           'text' => '案件一覧（誰のボールか）を再生成', 'url' => '/business/partner/backlog.html'],
    ['path' => 'site/drafts/blog/ycom/*.html',       'agent' => 'blog-write-ycom',   'text' => '記事ドラフトを作成',       'url' => '/drafts/blog/ycom/'],
    ['path' => 'site/drafts/blog/ycom/improve/*.html','agent' => 'blog-improve-ycom','text' => '既存記事の改善版を作成',   'url' => '/drafts/blog/ycom/improve/'],
];

// ── 窓（期間）を決める ────────────────────────────────────────────────────
$now   = time();
$dtNow = new DateTime('now', $JST);
$mode  = (isset($_GET['window']) && $_GET['window'] === 'night') ? 'night' : 'hours';
if ($mode === 'night') {
    // 直近の 18:00（今が18時前なら昨日の18:00）から現在まで＝「昨夜の働き」
    $base = (clone $dtNow)->setTime(18, 0, 0);
    if ((int)$dtNow->format('G') < 18) $base->modify('-1 day');
    $from = $base->getTimestamp();
    $windowLabel = $base->format('n/j H:i') . ' 〜 現在';
} else {
    $hours = isset($_GET['hours']) ? (int)$_GET['hours'] : 24;
    $hours = max(1, min(168, $hours));
    $from  = $now - $hours * 3600;
    $windowLabel = '直近' . $hours . '時間';
}

/** UNIX秒 → ISO8601（JST） */
function iso(int $t): string {
    return (new DateTime('@' . $t))->setTimezone($GLOBALS['JST'])->format(DATE_ATOM);
}
/** 文字列を安全に切る（表示側で必ずエスケープする前提） */
function cut(?string $s, int $n): ?string {
    if (!is_string($s) || $s === '') return null;
    $s = preg_replace('/\s+/u', ' ', $s) ?? $s;
    return mb_substr($s, 0, $n);
}
/** 分の丸め表記 */
function dur(int $sec): string {
    if ($sec < 60) return $sec . '秒';
    $m = (int)round($sec / 60);
    return ($m < 60) ? $m . '分' : intdiv($m, 60) . '時間' . ($m % 60) . '分';
}

$events = [];

// ══ 1) tick.log：起動（[run]）とその結果・所要時間、警報（[ALERT]）════════════
// 直列実行（flock）なので「[run] の次に来た [tick] 行」がその実行の終了時刻＋結果になる。
// 行頭タイムスタンプ付きの制御行だけを見る＝claude の出力（「» 」接頭辞）に混ざる文字列で
// 状態を偽装されない（status.php と同じ前提。/u は付けない＝不正UTF-8で全滅しないため）。
// ログが読めたかどうかを持ち回る：読めていないのに「起動0回」と表示しないため（Codex🔴）
$tail = '';
$logReadable = false;
$fp = (is_file($TICKLOG) && !is_link($TICKLOG)) ? @fopen($TICKLOG, 'rb') : false;
if ($fp) {
    $logReadable = true;
    $st   = fstat($fp);
    $size = is_array($st) ? (int)($st['size'] ?? 0) : 0;
    $len  = min($size, TAIL_BYTES);
    if ($len > 0) {
        fseek($fp, $size - $len);
        $tail = (string)fread($fp, $len);
        if ($len < $size) {                       // 途中から読んだ＝先頭の欠け行を捨てる
            $nl = strpos($tail, "\n");
            $tail = ($nl === false) ? '' : substr($tail, $nl + 1);
        }
    }
    fclose($fp);
}

/** "2026-08-05 02:00:21" → UNIX秒（JST）。読めなければ null */
function log_ts(string $s): ?int {
    $dt = DateTime::createFromFormat('Y-m-d H:i:s', $s, $GLOBALS['JST']);
    return $dt ? $dt->getTimestamp() : null;
}

$TS = '(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) JST ';
$openRun = null;                                  // 終了待ちの [run]（直列なので高々1つ）
$runs = [];                                       // 完了・実行中の実行イベント
$logFrom = null;                                  // ログに残っている最古の時刻（切り詰めで失われた分を偽らない）
foreach (explode("\n", $tail) as $line) {
    if ($line === '' || $line[0] !== '2') continue;          // 制御行は必ず年で始まる（高速フィルタ）
    if ($logFrom === null && preg_match('/^' . $TS . '\[/', $line, $m0)) $logFrom = log_ts($m0[1]);

    // [run] claude -p /hp-loop ycom 起動（label=hp-loop:ycom pending=0 force=1 timeout=1500s）
    if (preg_match('/^' . $TS . '\[run\] claude -p (\/[\w-]+(?: [\w:.-]+)?).*?label=(\S+) pending=(\S+) force=(\S+)/', $line, $m)) {
        $t = log_ts($m[1]);
        if ($t === null) continue;
        // 前の実行が閉じられないまま次が始まった＝ディスパッチャの再起動・強制終了などで
        // 終了の記録が失われている。所要時間を捏造せず「中断」として残す（Codex🟡）
        if ($openRun !== null) { $openRun['interrupted'] = true; $runs[] = $openRun; }
        $label = $GLOBALS['LABEL_ALIAS'][$m[3]] ?? $m[3];
        $openRun = ['ts' => $t, 'cmd' => $m[2], 'label' => $label,
                    'pending' => $m[4], 'force' => ($m[5] === '1')];
        continue;
    }
    // [tick] ... | label:pending:action ... ＝直前の実行の終了時刻と結果
    if (preg_match('/^' . $TS . '\[tick\] (.*)$/', $line, $m)) {
        if ($openRun === null) continue;
        $t = log_ts($m[1]);
        if ($t === null) continue;
        $action = null;
        if (preg_match_all('/(\S+?):([0-9-]+):(\S+)/', $m[2], $mm, PREG_SET_ORDER)) {
            foreach ($mm as $tok) {
                $lb = $GLOBALS['LABEL_ALIAS'][$tok[1]] ?? $tok[1];
                if ($lb === $openRun['label']) { $action = $tok[3]; break; }
            }
        }
        $openRun['end'] = $t;
        $openRun['action'] = $action;
        $runs[] = $openRun;
        $openRun = null;
        continue;
    }
    // [ALERT] / [ALERT:partner] ＝社長に鳴らした警報（鳴った事実は活動として見せる）
    if (preg_match('/^' . $TS . '\[ALERT(?::\w+)?\] (.*)$/', $line, $m)) {
        $t = log_ts($m[1]);
        if ($t === null || $t < $from) continue;
        $events[] = ['ts' => iso($t), 'sort' => $t, 'kind' => 'alert', 'agent' => null,
                     'label' => '⚠️ 警報', 'text' => cut($m[2], 140), 'url' => null, 'bad' => true];
    }
}
if ($openRun !== null) $runs[] = $openRun;        // 末尾＝まだ実行中

$runMinutes = [];                                 // id => 稼働秒（ダイジェスト用）
foreach ($runs as $r) {
    if (($r['end'] ?? $r['ts']) < $from) continue;
    $meta   = $GLOBALS['VPS_AGENTS'][$r['label']] ?? null;
    $id     = $meta['id'] ?? $r['label'];
    $name   = $meta['label'] ?? $r['label'];
    $action = $r['action'] ?? null;
    $bad    = is_string($action) && (str_contains($action, 'TIMEOUT') || preg_match('/ERR\d/', $action)
              || str_contains($action, 'OOMKILL') || str_contains($action, 'NOCREDIT'));
    if (!empty($r['interrupted'])) {
        // 終了の記録が無いまま次の実行が始まっていた＝所要時間は出せない（0分と偽らない）
        $text = '起動 → 終了の記録がありません（ディスパッチャの再起動・強制終了の可能性）';
        $bad = true;
    } elseif (!isset($r['end'])) {
        $text = '実行中…（' . dur(max(0, $now - $r['ts'])) . '経過）';
    } else {
        $sec = max(0, $r['end'] - $r['ts']);
        $runMinutes[$id] = ($runMinutes[$id] ?? 0) + $sec;
        $why  = $r['force'] ? '定時' : '新着' . ($r['pending'] !== '0' && $r['pending'] !== '-' ? $r['pending'] . '件' : '');
        $text = $why . '起動 → ' . ($bad ? '異常終了（' . $action . '）' : '完了') . '・' . dur($sec);
    }
    $events[] = ['ts' => iso($r['ts']), 'sort' => $r['ts'], 'kind' => 'run', 'agent' => $id,
                 'label' => $name, 'text' => $text, 'url' => null, 'bad' => (bool)$bad];
}

// ══ 2) mailbox：便のやり取り（誰が誰に）════════════════════════════════════
// mtime で窓外を捨ててから中身を読む（343通あっても読むのは窓内だけ）。本文は返さない。
$TYPE_JA = ['request' => '依頼', 'report' => '報告', 'question' => '質問', 'fyi' => '共有',
            'answer' => '回答', 'approval' => '承認依頼'];
$mailFiles = [];
foreach (['cur', 'new', 'hold'] as $box) {
    foreach (glob($MAILBOX . '/' . $box . '/*.json') ?: [] as $f) {
        if (!is_file($f) || is_link($f)) continue;
        $mt = @filemtime($f);
        if ($mt === false || $mt < $from) continue;
        $sz = @filesize($f);
        if ($sz === false || $sz > 65536) continue;
        $mailFiles[] = ['f' => $f, 'mt' => $mt, 'box' => $box];
    }
}
usort($mailFiles, fn($a, $b) => $b['mt'] <=> $a['mt']);
// 上限を超えた分は読まない＝落とした件数を隠さず返す（Codex🟡：黙って欠けると「便が無かった」に見える）
$mailSkipped = max(0, count($mailFiles) - MAX_MAILS);
foreach (array_slice($mailFiles, 0, MAX_MAILS) as $mf) {
    $j = json_decode((string)@file_get_contents($mf['f']), true);
    if (!is_array($j)) continue;
    $s = fn($k) => is_string($j[$k] ?? null) ? $j[$k] : '';
    $t = $mf['mt'];
    if ($s('ts') !== '') {                        // 本来の発生時刻（cur の mtime は処理時刻）
        // オフセットの無い ts はサーバ既定TZ（UTC）でなく JST として解釈する（Codex🟡）
        $dt = date_create_immutable($s('ts'), $JST);
        if ($dt) $t = $dt->getTimestamp();
    }
    if ($t < $from || $t > $now + 60) continue;
    $type = $TYPE_JA[$s('type')] ?? null;
    $to   = office_label($s('to'));
    $events[] = [
        'ts' => iso($t), 'sort' => $t, 'kind' => 'mail',
        'agent' => $s('from') !== '' ? $s('from') : null,
        'label' => office_label($s('from')),
        'text'  => '→ ' . cut($to, 40) . ($type ? '（' . $type . '）' : '') . '：'
                   . (cut($s('subject'), 120) ?? '(件名なし)')
                   . ($mf['box'] === 'hold' ? '　🗂承認待ち' : ($mf['box'] === 'new' ? '　📬未読' : '')),
        'url' => null, 'bad' => false,
    ];
}

// ══ 3) 成果物の更新（掲示板・ドラフト）══════════════════════════════════════
$outputs = [];
foreach ($QUESTION_BOARDS as $b) {
    if ($b['agent'] === null) continue;           // キャラ不在の掲示板は活動として出さない
    $outputs[] = ['path' => $b['file'], 'agent' => $b['agent'], 'text' => '掲示板を更新', 'url' => $b['url']];
}
foreach ($EXTRA_OUTPUTS as $o) $outputs[] = $o;

foreach ($outputs as $o) {
    $abs = $ROOT . '/' . $o['path'];
    $mt = null;
    if (str_contains($o['path'], '*')) {          // 置き場＝最新ファイルの時刻を採る
        foreach (glob($abs) ?: [] as $f) {
            if (!is_file($f) || is_link($f)) continue;
            $m = @filemtime($f);
            if ($m !== false && ($mt === null || $m > $mt)) $mt = $m;
        }
    } elseif (is_file($abs) && !is_link($abs)) {
        $m = @filemtime($abs);
        if ($m !== false) $mt = $m;
    }
    if ($mt === null || $mt < $from || $mt > $now + 60) continue;
    $events[] = ['ts' => iso($mt), 'sort' => $mt, 'kind' => 'board', 'agent' => $o['agent'],
                 'label' => office_label($o['agent']), 'text' => $o['text'], 'url' => $o['url'], 'bad' => false];
}

// ══ 4) 並べ替え・集計 ═══════════════════════════════════════════════════════
// ⚠️ 集計は**切り捨てる前の全件**で行い、表示用の events だけを上限で切る。
//    （切った後で数えると「起動回数は150件分・のべ分数は全件分」という食い違いが出る＝Codex🔴）
usort($events, fn($a, $b) => $b['sort'] <=> $a['sort']);
$total = count($events);

$per = [];                                        // id => 集計
foreach ($events as $e) {
    $id = $e['agent'];
    if ($id === null) continue;
    if (!isset($per[$id])) $per[$id] = ['id' => $id, 'label' => $e['label'],
                                        'runs' => 0, 'mails' => 0, 'boards' => 0, 'minutes' => 0];
    if ($e['kind'] === 'run')   $per[$id]['runs']++;
    if ($e['kind'] === 'mail')  $per[$id]['mails']++;
    if ($e['kind'] === 'board') $per[$id]['boards']++;
}
foreach ($runMinutes as $id => $sec) {
    if (isset($per[$id])) $per[$id]['minutes'] = (int)round($sec / 60);
}
usort($per, fn($a, $b) => ($b['runs'] + $b['boards'] * 2 + $b['mails']) <=> ($a['runs'] + $a['boards'] * 2 + $a['mails']));

$count = fn(string $k) => count(array_filter($events, fn($e) => $e['kind'] === $k));
$digest = [
    'runs'    => $count('run'),
    'mails'   => $count('mail'),
    'boards'  => $count('board'),
    'alerts'  => $count('alert'),
    'errors'  => count(array_filter($events, fn($e) => $e['bad'])),
    'minutes' => (int)round(array_sum($runMinutes) / 60),
    'agents'  => array_values($per),
    'truncated'   => max(0, $total - MAX_EVENTS),   // 表示から落とした件数を隠さない
    'mailsSkipped' => $mailSkipped,                 // 走査上限で読まなかった便の件数
    // 起動系（回数・分数）を数えられているか。tick.log は1MB超で末尾512KBに切り詰められるため、
    // 窓がログより長ければその分だけ少なく出る。ログ自体が読めないときは 0 と出さず「不明」にする。
    'runsAvailable' => $logReadable && $logFrom !== null,
    'runsSince'     => ($logFrom !== null) ? iso(max($from, $logFrom)) : null,
    'runsPartial'   => ($logFrom !== null && $logFrom > $from),
];
if (!$digest['runsAvailable']) {                    // 読めていない＝数字を出さない（Codex🔴）
    $digest['runs'] = null; $digest['minutes'] = null;
    $digest['runsError'] = $logReadable ? 'no_control_lines' : 'log_unreadable';
}
echo json_encode([
    'ok' => true,
    'ts' => $dtNow->format(DATE_ATOM),
    'window' => ['mode' => $mode, 'label' => $windowLabel, 'from' => iso($from), 'to' => iso($now)],
    'digest' => $digest,
    'events' => array_map(fn($e) => array_diff_key($e, ['sort' => 1]),
                          array_slice($events, 0, MAX_EVENTS)),
], JSON_OPT | JSON_INVALID_UTF8_SUBSTITUTE);
