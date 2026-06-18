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
 * 【スライス3以降・現在は 501】
 *   POST ?action=approve&id=<id>       社長(admin)だけ hold/ → new/
 *
 * 規約・メッセージ書式・needs_approval の運用は .claude/rules/mailbox.md を参照。
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

const JSON_OPT      = JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT;
const MAX_BODY_SIZE = 65536;                 // 1メッセージの上限（64KB）
const VALID_TYPES   = ['request', 'report', 'ack', 'fyi'];

$ROOT        = realpath(__DIR__ . '/../../..');            // プロジェクトルート
$MAILBOX     = $ROOT . '/data/mailbox';
$TOKENS_FILE = $ROOT . '/data/secrets/mailbox-tokens.json';

/** エラー応答して終了（本文・トークンなど秘密はログに出さない） */
function fail(int $code, string $error, array $extra = []): void {
    http_response_code($code);
    echo json_encode(['ok' => false, 'error' => $error] + $extra, JSON_OPT);
    exit;
}

/** id・宛先などに使える安全な文字だけか（英数・_・- のみ。'.' '/' を許さずパストラバーサルを構造的に排除） */
function is_safe_token(string $s): bool {
    return $s !== '' && (bool)preg_match('/^[A-Za-z0-9_-]+$/', $s);
}

// ── 認証：Bearer トークン → agent_id / role ──────────────────────────────
$authHeader = $_SERVER['HTTP_AUTHORIZATION'] ?? ($_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? '');
if (!preg_match('/^Bearer\s+(\S+)$/', (string)$authHeader, $m)) {
    fail(401, 'missing_bearer_token', ['hint' => 'Authorization: Bearer <token> を付けてください']);
}
$token = $m[1];

if (!is_file($TOKENS_FILE)) {
    fail(503, 'token_file_not_configured',
        ['hint' => 'data/secrets/mailbox-tokens.json を作成してください（.claude/rules/mailbox.md 参照）']);
}
$tokens = json_decode((string)file_get_contents($TOKENS_FILE), true);
if (!is_array($tokens) || !isset($tokens[$token]) || !is_array($tokens[$token])) {
    fail(403, 'invalid_token');
}
$agent = (string)($tokens[$token]['agent_id'] ?? '');
$role  = (string)($tokens[$token]['role'] ?? 'agent');
if ($agent === '' || !is_safe_token($agent)) {
    fail(500, 'token_agent_id_invalid');           // agent_id はファイル名/ID生成に使うため安全文字に限定
}
if (!in_array($role, ['agent', 'admin'], true)) {
    $role = 'agent';                                // 未知ロールは最小権限（agent）に倒す
}
// 既知エージェント集合（宛先の存在チェック用）
$known_agents = [];
foreach ($tokens as $t) {
    if (is_array($t) && !empty($t['agent_id'])) {
        $known_agents[(string)$t['agent_id']] = true;
    }
}

// ── アクション振り分け ───────────────────────────────────────────────────
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$action = (string)($_GET['action'] ?? $_POST['action'] ?? 'inbox');

// ---- inbox（読み取り） ----------------------------------------------------
if ($action === 'inbox' && $method === 'GET') {
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

    $type = (string)($in['type'] ?? 'request');
    if (!in_array($type, VALID_TYPES, true)) {
        fail(400, 'invalid_type', ['allowed' => VALID_TYPES]);
    }

    $thread = trim((string)($in['thread'] ?? ''));
    if ($thread !== '' && !is_safe_token($thread)) {
        fail(400, 'invalid_thread');
    }

    $needs_approval = filter_var($in['needs_approval'] ?? false, FILTER_VALIDATE_BOOLEAN);
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
