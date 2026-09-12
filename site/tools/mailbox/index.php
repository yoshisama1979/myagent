<?php
declare(strict_types=1);

/*
 * 拠点横断メールボックス API ── スライス2（読み取り＋書き込み send/done）
 *
 * 別マシン（事務所・自宅・VPS）にいるエージェント同士が、Tailscale 経由で
 * 非同期にメッセージをやり取りするための共有受信箱。
 *
 *   保存先 : data/mailbox/{new,cur,hold}/  （docroot 外・gitignore・1メッセージ1JSON）
 *   認証   : Authorization: Bearer <token>  （token→agent_id は data/secrets/mailbox-tokens.json）
 *   ネット : Nginx + PHP-FPM。Tailscale 内からのみ到達する前提（網境界＝Tailscale）。
 *
 * 【有効】
 *   GET  ?action=inbox[&to=<agent>]    自分宛の new/ を一覧（既定は自分の inbox）
 *   POST ?action=send  （body=JSON）    メッセージ投函。needs_approval:true は hold/、それ以外 new/
 *   POST ?action=done&id=<id>          自分宛の new/<id> を cur/ へ移動（本文は編集しない）
 *
 * 【ロール】agent（既定）／admin（他人の inbox・done も可）／reporter（投函専用）
 *   reporter は REPORTER_TO 宛の send しかできない（inbox も done も 403）。claude-rules
 *   テンプレを使う各案件から「ルールの問題」を一方向で通知させるための細い経路で、
 *   解析↔開発のやり取り（agent ロール）とは目的も権限も分ける。漏洩時の被害を
 *   「この受信箱にゴミが入る」だけに閉じ込めるのが狙い。
 *
 * 【ホワイトリストの取り消し】トークン表に無いトークンは 403。加えて各エントリは
 *   revoked:true（失効・理由は表に残す）と expires_at（期限切れで自動停止）を持てる。
 *   最終使用（日時・接続元IP）は data/mailbox/.state/seen-<agent>.json に記録する＝
 *   「漏れても気づけない」を塞ぐための材料。
 *
 * 【スライス3以降・現在は 501】
 *   POST ?action=approve&id=<id>       社長(admin)だけ hold/ → new/
 *
 * 規約・メッセージ書式・needs_approval の運用は rules/modes/mailbox.md を参照。
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

// 認証（トークン表・失効・期限）と最終使用の記録は tools/rules/ と共有する。
// 取り消しは**どちらの受け口から来ても同じように効く**必要があるため、正は1箇所に置く。
require_once __DIR__ . '/../lib/token-auth.php';

const MAX_BODY_SIZE = 65536;                 // 1メッセージの上限（64KB）
const VALID_TYPES   = ['request', 'report', 'ack', 'fyi'];
const REPORTER_TO        = 'rule-kaizen';    // reporter が送れる唯一の宛先
const REPORTER_DAILY_MAX = 50;               // reporter 1トークンの1日あたり投函上限（漏洩時の被害を抑える保険）

$ROOT        = realpath(__DIR__ . '/../../..');            // プロジェクトルート
$MAILBOX     = $ROOT . '/data/mailbox';
$TOKENS_FILE = $ROOT . '/data/secrets/mailbox-tokens.json';
$STATE_DIR   = $MAILBOX . '/.state';                       // 最終使用・投函カウンタ（spool と混ざらない dot ディレクトリ）

// ── 認証：Bearer トークン → agent_id / role（失効・期限もここで見る） ──────────
$tokens = load_token_table($TOKENS_FILE);
$auth   = authenticate($tokens, bearer_token());
$agent  = $auth['agent'];
$role   = $auth['role'];

// 既知エージェント集合（宛先の存在チェック用）
$known_agents = [];
foreach ($tokens as $t) {
    if (!is_array($t) || empty($t['agent_id'])) {
        continue;
    }
    // 発行した投函専用トークン（reporter_id 持ち）は**宛先にしない**。reporter は受信箱を
    // 持たないので、宛先にできると誰も読まない new/ が永久に溜まる（inbox は new/ を全読み
    // するので全体のコストにもなる）。受信専用の sink（rule-kaizen）は reporter_id を
    // 持たないので、権限が reporter でも宛先としては残る。
    if (($t['role'] ?? '') === 'reporter' && !empty($t['reporter_id'])) {
        continue;
    }
    $known_agents[(string)$t['agent_id']] = true;
}

// ── アクション振り分け ───────────────────────────────────────────────────
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$action = (string)($_GET['action'] ?? $_POST['action'] ?? 'inbox');

// 最終使用の記録は1リクエスト1回。reporter の投函だけは、この同じ書き込みで当日分も数える
// （別に数えると同じファイルへ2回書くことになる）。数えるのは**投函の試行**であって成功した
// 分だけではない＝上限は濫用を抑える保険なので、弾かれた要求も濫用の一部として数える。
$client_ip        = (string)($_SERVER['REMOTE_ADDR'] ?? '');
$is_reporter_send = ($role === 'reporter' && $action === 'send' && $method === 'POST');
$seen = seen_touch($STATE_DIR, $agent, $client_ip, $is_reporter_send,
                   $is_reporter_send ? REPORTER_DAILY_MAX : 0);
if ($is_reporter_send && $seen['over']) {
    fail(429, 'daily_quota_exceeded', ['limit' => REPORTER_DAILY_MAX, 'day' => $seen['day']]);
}

// ---- inbox（読み取り） ----------------------------------------------------
if ($action === 'inbox' && $method === 'GET') {
    if ($role === 'reporter') {
        fail(403, 'forbidden_for_role', ['role' => $role, 'hint' => 'reporter は投函専用です（受信箱は持ちません）']);
    }
    $to = (string)($_GET['to'] ?? $agent);
    if ($to !== $agent && $role !== 'admin') {
        $to = $agent;                         // 他人の inbox は admin のみ
    }

    $messages = [];
    foreach (glob($MAILBOX . '/new/*.json') ?: [] as $file) {
        $msg = json_decode((string)file_get_contents($file), true);
        if (!is_array($msg)) {
            continue;                          // 壊れたファイルは飛ばす
        }
        if (($msg['to'] ?? '') === $to) {
            $messages[] = $msg;
        }
    }
    usort($messages, fn($a, $b) => strcmp((string)($a['ts'] ?? ''), (string)($b['ts'] ?? '')));

    echo json_encode([
        'ok' => true, 'agent' => $agent, 'inbox_of' => $to,
        'count' => count($messages), 'messages' => $messages,
    ], JSON_OPT);
    exit;
}

// ---- send（投函） ---------------------------------------------------------
if ($action === 'send' && $method === 'POST') {
    $raw = file_get_contents('php://input') ?: '';
    if (strlen($raw) > MAX_BODY_SIZE) {
        fail(413, 'message_too_large', ['max_bytes' => MAX_BODY_SIZE]);
    }
    $in = json_decode($raw, true);
    if (!is_array($in)) {
        fail(400, 'invalid_json_body');
    }

    // 宛先：必須・安全文字・既知エージェント
    $to = trim((string)($in['to'] ?? ''));
    if (!is_safe_token($to)) {
        fail(400, 'invalid_to');
    }
    if (!isset($known_agents[$to])) {
        fail(400, 'unknown_recipient', ['to' => $to, 'hint' => 'トークン表に無い宛先です']);
    }
    // reporter は宛先が固定。解析↔開発のやり取り（他の宛先）へは一通も入れない。
    if ($role === 'reporter' && $to !== REPORTER_TO) {
        fail(403, 'recipient_not_allowed', ['to' => $to, 'allowed' => REPORTER_TO]);
    }

    $type = (string)($in['type'] ?? 'request');
    if (!in_array($type, VALID_TYPES, true)) {
        fail(400, 'invalid_type', ['allowed' => VALID_TYPES]);
    }

    $thread = trim((string)($in['thread'] ?? ''));
    if ($thread !== '' && !is_safe_token($thread)) {
        fail(400, 'invalid_thread');
    }

    $needs_approval = filter_var($in['needs_approval'] ?? false, FILTER_VALIDATE_BOOLEAN);
    if ($role === 'reporter') {
        $needs_approval = false;                   // hold/ は社長承認待ちの置き場。通知は new/ に入れて棚卸しで読む
    }
    $subject = trim((string)($in['subject'] ?? ''));
    $body    = (string)($in['body'] ?? '');
    if ($subject === '' && $body === '') {
        fail(400, 'empty_message');
    }

    // ID・タイムスタンプはサーバ生成（from はトークンから＝詐称不可）。
    // 乱数は 64bit。同一秒・同一エージェントでも衝突は実質起きない。
    $now     = new DateTime('now', new DateTimeZone('Asia/Tokyo'));
    $idstamp = $now->format('Ymd\THis');
    $id      = "M-{$idstamp}-{$agent}-" . bin2hex(random_bytes(8));
    if (!is_safe_token($id)) {                 // 念のため（agent_id 由来）
        fail(500, 'generated_id_unsafe');
    }

    $msg = [
        'id' => $id, 'thread' => $thread, 'from' => $agent, 'to' => $to,
        'type' => $type, 'needs_approval' => $needs_approval,
        'ts' => $now->format('c'), 'subject' => $subject, 'body' => $body,
    ];

    // 一意な一時ファイルに書き、link() で no-clobber 公開する。
    // rename は既存を上書きするが link は既存があると失敗 → 万一のID衝突でも既存メッセージを潰さない。
    $destdir = $needs_approval ? 'hold' : 'new';
    $path    = "{$MAILBOX}/{$destdir}/{$id}.json";
    $tmp     = "{$MAILBOX}/{$destdir}/.{$id}." . bin2hex(random_bytes(4)) . '.tmp';
    if (file_put_contents($tmp, json_encode($msg, JSON_OPT), LOCK_EX) === false) {
        @unlink($tmp);
        fail(500, 'write_failed');
    }
    if (!@link($tmp, $path)) {                  // 既存IDがあれば上書きせず 409（消失防止）
        @unlink($tmp);
        fail(409, 'id_conflict');
    }
    @unlink($tmp);

    echo json_encode([
        'ok' => true, 'id' => $id, 'from' => $agent, 'to' => $to,
        'status' => $needs_approval ? 'held_for_approval' : 'queued',
        'location' => $destdir,
    ], JSON_OPT);
    exit;
}

// ---- done（処理済み → cur/ へ） -------------------------------------------
if ($action === 'done' && $method === 'POST') {
    if ($role === 'reporter') {
        fail(403, 'forbidden_for_role', ['role' => $role, 'hint' => 'reporter は投函専用です（処理済み化はしません）']);
    }
    $id = (string)($_GET['id'] ?? $_POST['id'] ?? '');
    if (!is_safe_token($id)) {
        fail(400, 'invalid_id');
    }
    $src = "{$MAILBOX}/new/{$id}.json";
    if (!is_file($src)) {
        fail(404, 'message_not_found', ['id' => $id]);
    }
    $msg = json_decode((string)file_get_contents($src), true);
    if (!is_array($msg)) {
        fail(500, 'message_corrupt', ['id' => $id]);
    }
    // 自分宛のメッセージだけ done にできる（admin は例外）。
    // 非宛先には存在を伏せて 404（IDから他人宛メッセージの存在を推測させない）。
    if (($msg['to'] ?? '') !== $agent && $role !== 'admin') {
        fail(404, 'message_not_found', ['id' => $id]);
    }
    $dst = "{$MAILBOX}/cur/{$id}.json";
    if (!@link($src, $dst)) {                  // cur/ 既存を上書きしない（本文は編集せず移動だけ）
        fail(409, 'already_done_or_conflict', ['id' => $id]);
    }
    @unlink($src);
    echo json_encode(['ok' => true, 'id' => $id, 'status' => 'done'], JSON_OPT);
    exit;
}

// ---- approve（社長承認・スライス3以降） -----------------------------------
if ($action === 'approve') {
    fail(501, 'not_implemented_in_slice2',
        ['note' => 'approve（hold/ → new/）はスライス3。社長用ブラウザビューと併せて実装']);
}

fail(400, 'unknown_action', ['action' => $action, 'method' => $method]);
