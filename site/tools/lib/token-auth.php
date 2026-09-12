<?php
declare(strict_types=1);

/*
 * 共有：Bearer トークンの検証と、最終使用の記録。
 *
 * 受け口が2つある（tools/mailbox/＝投函と受信、tools/rules/＝ルールの配信）。
 * **ホワイトリストの取り消しは、どちらから来ても同じように効かなければ意味がない**ので、
 * トークン表の読み方・失効（revoked）・期限（expires_at）・最終使用の記録はここ1箇所に置く。
 * 片方だけ直すと「失効させたのに、もう片方からは使える」という気づきにくい形で壊れる。
 *
 * 使う側：
 *   require_once __DIR__ . '/../lib/token-auth.php';
 *   $tokens = load_token_table($TOKENS_FILE);
 *   $auth   = authenticate($tokens, bearer_token());   // 失敗時はこの中で応答して終了
 *   $agent = $auth['agent']; $role = $auth['role']; $entry = $auth['entry'];
 */

// 直接 URL で叩かれたら何も出さない（関数定義だけのファイル）
if (($_SERVER['SCRIPT_FILENAME'] ?? '') !== '' &&
    realpath((string)$_SERVER['SCRIPT_FILENAME']) === realpath(__FILE__)) {
    http_response_code(404);
    exit;
}

const JSON_OPT    = JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT;
const VALID_ROLES = ['agent', 'admin', 'reporter'];

/** エラー応答して終了（本文・トークンなど秘密はログに出さない） */
function fail(int $code, string $error, array $extra = []): void {
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');   // 配信系は本来 gzip を返すため明示し直す
    echo json_encode(['ok' => false, 'error' => $error] + $extra, JSON_OPT);
    exit;
}

/** id・宛先などに使える安全な文字だけか（英数・_・- のみ。'.' '/' を許さずパストラバーサルを構造的に排除） */
function is_safe_token(string $s): bool {
    return $s !== '' && (bool)preg_match('/^[A-Za-z0-9_-]+$/', $s);
}

/**
 * 最終使用の記録と、投函数のカウント（best-effort）。
 *
 * 目的は「漏れても気づけない」を塞ぐこと＝いつ・どこから使われたトークンかを残す。
 * Tailscale 内からしか届かないので last_ip（100.x.x.x）で拠点の見当がつく。
 *
 * 記録に失敗しても本体は止めない（通信の可用性 > 記録）。$limit を超えていれば over=true を
 * 返すが、読めなければ over=false＝**fail-open**。上限は漏洩時の被害を抑える保険であって
 * 認証の代わりではないので、記録が壊れて通信が止まるほうが害が大きい。
 *
 * 判定と加算は同じ flock の中で行う＝上限に達していたら**増やさずに** over を返す
 * （増やしてから弾くと、超過中に叩かれ続けたぶん通算が汚れる）。
 *
 * $extra は同じ書き込みに混ぜる追加の記録（例: 最後に取りに来たルールの版）。別ファイルに
 * 分けると、同じ「この案件が最後に何をしたか」を2箇所から集める羽目になる。
 *
 * 認証を通った全リクエストで1回書く。1リクエスト1回に抑えてあり、ファイルも 200 バイト弱・
 * 呼び出し元は cron 単位なので間引かない。間引くと「最後にいつ使われたか」の精度が落ち、
 * この記録の目的（把握していない場所からの使用に気づく）そのものを削ることになる。
 */
function seen_touch(string $dir, string $agent, string $ip, bool $count, int $limit = 0,
                    array $extra = []): array {
    $none = ['day' => '', 'today' => 0, 'total' => 0, 'over' => false];
    if (!is_dir($dir) && !@mkdir($dir, 0700, true) && !is_dir($dir)) {
        return $none;
    }
    $fh = @fopen($dir . '/seen-' . $agent . '.json', 'c+');   // $agent は is_safe_token 済み
    if (!$fh) {
        return $none;
    }
    try {
        if (!flock($fh, LOCK_EX)) {
            return $none;
        }
        $cur = json_decode((string)stream_get_contents($fh), true);
        if (!is_array($cur)) {
            $cur = [];
        }
        $now   = new DateTime('now', new DateTimeZone('Asia/Tokyo'));
        $today = $now->format('Y-m-d');
        if (($cur['day'] ?? '') !== $today) {
            $cur['day']   = $today;
            $cur['today'] = 0;                       // 日が変わったら当日分だけ戻す（total は通算で残す）
        }
        $over = false;
        if ($count) {
            if ($limit > 0 && (int)($cur['today'] ?? 0) >= $limit) {
                $over = true;                        // 上限に達している＝加算せず超過だけ伝える
            } else {
                $cur['today'] = (int)($cur['today'] ?? 0) + 1;
                $cur['total'] = (int)($cur['total'] ?? 0) + 1;
            }
        }
        $cur['agent_id']  = $agent;
        $cur['last_seen'] = $now->format('c');
        $cur['last_ip']   = $ip;
        // 集計と身元のキーは追加記録から守る（呼び出し側の取り違えで today/total が消えない）
        $reserved = ['day', 'today', 'total', 'agent_id', 'last_seen', 'last_ip'];
        foreach ($extra as $k => $v) {
            if (!in_array((string)$k, $reserved, true)) {
                $cur[(string)$k] = $v;
            }
        }
        rewind($fh);
        ftruncate($fh, 0);
        fwrite($fh, json_encode($cur, JSON_OPT));
        fflush($fh);
        return ['day' => (string)$cur['day'], 'today' => (int)$cur['today'],
                'total' => (int)$cur['total'], 'over' => $over];
    } finally {
        flock($fh, LOCK_UN);
        fclose($fh);
    }
}

/** Authorization ヘッダから Bearer トークンを取り出す（無ければ 401 で終了） */
function bearer_token(): string {
    $authHeader = $_SERVER['HTTP_AUTHORIZATION'] ?? ($_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? '');
    if (!preg_match('/^Bearer\s+(\S+)$/', (string)$authHeader, $m)) {
        fail(401, 'missing_bearer_token', ['hint' => 'Authorization: Bearer <token> を付けてください']);
    }
    return $m[1];
}

/** トークン表を読む（無ければ 503 で終了） */
function load_token_table(string $file): array {
    if (!is_file($file)) {
        fail(503, 'token_file_not_configured',
            ['hint' => 'data/secrets/mailbox-tokens.json を作成してください（rules/modes/mailbox.md 参照）']);
    }
    $tokens = json_decode((string)file_get_contents($file), true);
    if (!is_array($tokens)) {
        fail(503, 'token_file_not_configured', ['hint' => 'トークン表の形式が不正です']);
    }
    return $tokens;
}

/**
 * トークンを引き当て、失効・期限を見る（通らなければこの中で応答して終了）。
 *
 * 表から行を消しても失効はするが、それだと後から「そんな番号あったか」が分からない。
 * revoked で無効化して理由ごと残す。expires_at は放置トークンが永久に生きるのを構造的に防ぐ。
 *
 * @return array{token:string, entry:array, agent:string, role:string}
 */
function authenticate(array $tokens, string $token): array {
    if (!isset($tokens[$token]) || !is_array($tokens[$token])) {
        fail(403, 'invalid_token');
    }
    $entry = $tokens[$token];
    $agent = (string)($entry['agent_id'] ?? '');
    $role  = (string)($entry['role'] ?? 'agent');
    if ($agent === '' || !is_safe_token($agent)) {
        fail(500, 'token_agent_id_invalid');       // agent_id はファイル名/ID生成に使うため安全文字に限定
    }
    if (!in_array($role, VALID_ROLES, true)) {
        $role = 'reporter';                         // 未知ロールは最小権限（reporter＝投函専用）に倒す
    }
    if (filter_var($entry['revoked'] ?? false, FILTER_VALIDATE_BOOLEAN)) {
        fail(403, 'token_revoked');                 // 失効理由は返さない（外へ出す情報を増やさない）
    }
    $expires_at = trim((string)($entry['expires_at'] ?? ''));
    if ($expires_at !== '') {
        $TZ  = new DateTimeZone('Asia/Tokyo');
        $exp = date_create($expires_at, $TZ);
        if (!$exp) {
            fail(500, 'token_expires_at_invalid');  // 読めない期限を「期限なし」に倒さない（fail-closed）
        }
        if (preg_match('/^\d{4}-\d{2}-\d{2}$/', $expires_at)) {
            $exp->setTime(23, 59, 59);              // 日付だけなら「その日の終わりまで有効」と読む
        }
        if ($exp < new DateTime('now', $TZ)) {
            fail(403, 'token_expired', ['expired_at' => $exp->format('c')]);
        }
    }
    return ['token' => $token, 'entry' => $entry, 'agent' => $agent, 'role' => $role];
}
