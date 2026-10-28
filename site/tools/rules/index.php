<?php
declare(strict_types=1);

/*
 * ルール配信 API ── 各案件が claude-rules テンプレートの最新版を「取りに来る」受け口。
 *
 * テンプレートはコピー配布なので、配ったあとは案件ごとに古びていく。手渡しで配り直すのは
 * 案件が増えるほど滞るため、**現場のエージェントが自分で取りに来られる**ようにする。
 *
 *   配る元 : data/cache/rules-release/<template>/（bin/rules-publish.py publish が作る）
 *   認証   : Authorization: Bearer <token>（ルール通知トークンと**同じ1本**）
 *   ネット : Nginx + PHP-FPM。Tailscale 内からのみ到達する前提（網境界＝Tailscale）。
 *
 * 【有効】いずれも GET のみ（この受け口は読み取り専用＝現場からこちらを書き換える手段は無い）
 *   GET ?action=version     配信中の版・公開日時・サイズ・SHA256
 *   GET ?action=changelog   そのテンプレを触ったコミット一覧（text/plain・新しい順）
 *   GET ?action=fetch       配布物一式（tar.gz）
 *
 * 【どのテンプレを取れるか】トークンに紐づけた `template` ひとつだけ。案件が自分の分以外を
 *   取れないので、漏れても「そのテンプレの配布物が1つ外に出る」以上にはならない（中身は
 *   ルール文書であって、鍵も顧客情報も含まない）。紐づけは bin/rule-reporter.py issue --template。
 *
 * 【投函（tools/mailbox/）とは別の受け口・同じ鍵】
 *   目的が違う（あちらは投函専用・こちらは配信専用）ので URL を分けるが、**ホワイトリストと
 *   失効は同じもの**が効く必要があるため、認証は site/tools/lib/token-auth.php を共有する。
 *   失効させれば通知も配信も同時に止まる。
 *
 * 【取得は数えない】投函には1日上限があるが、取得には設けていない。取得されるのは静的な
 *   配布物1つで、濫用されても増えるのは同じファイルの転送だけ。上限で通信を止めるより、
 *   「いつ・どこから・どの版を取ったか」を記録して気づけるようにするほうが実利がある。
 */

require_once __DIR__ . '/../lib/token-auth.php';

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

$ROOT        = realpath(__DIR__ . '/../../..');
$TOKENS_FILE = $ROOT . '/data/secrets/mailbox-tokens.json';
$STATE_DIR   = $ROOT . '/data/mailbox/.state';
$RELEASE_DIR = $ROOT . '/data/cache/rules-release';

// ── 認証（失効・期限は共有ライブラリが見る） ─────────────────────────────
$auth  = authenticate(load_token_table($TOKENS_FILE), bearer_token());
$agent = $auth['agent'];
$role  = $auth['role'];
$entry = $auth['entry'];

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$action = (string)($_GET['action'] ?? 'version');
if ($method !== 'GET') {
    fail(405, 'method_not_allowed', ['hint' => 'この受け口は読み取り専用です（GET のみ）']);
}

// 配布プロファイルの許可リスト。正は claude-rules/profiles.json ひとつ（Python 側の
// bin/distribute-rules.py ・ bin/rule-reporter.py も同じファイルを読む）。ここに一覧を
// 書き写すと、層を足した日に「配っているのに取りに来られない」が起きる。
// 🚨 読めないときは空にせず**停止する**：空の許可リストは全部を unknown_template で
//    弾くので、配信障害が「設定ミス」ではなく「そのテンプレは無い」と見えてしまう。
$PROFILES_FILE = $ROOT . '/claude-rules/profiles.json';
$profiles_raw  = @file_get_contents($PROFILES_FILE);
$profiles_json = $profiles_raw === false ? null : json_decode($profiles_raw, true);
if (!is_array($profiles_json) || !isset($profiles_json['profiles']) || !is_array($profiles_json['profiles'])
    || count($profiles_json['profiles']) === 0) {
    fail(500, 'profiles_unreadable',
        ['hint' => '配布プロファイルの定義（claude-rules/profiles.json）が読めません']);
}
// 🚨 キーの形まで見る。許可リストは**データ由来**になったので、ここが
//    `$RELEASE_DIR . '/' . $template` にそのまま入る前の唯一の関門
//    （Python 側 bin/distribute-rules.py の NAME_RE と同じ形。現場の bin/rule-report.sh も同じ）。
$TEMPLATES = [];
foreach (array_keys($profiles_json['profiles']) as $k) {
    if (is_string($k) && preg_match('/^[a-z0-9][a-z0-9_-]*\z/', $k)) {
        $TEMPLATES[] = $k;
    }
}
if (count($TEMPLATES) === 0) {
    fail(500, 'profiles_unreadable',
        ['hint' => '配布プロファイルの定義に、使える名前が1つもありません']);
}

// ── どのテンプレートを配るか ─────────────────────────────────────────────
// 正はトークン表の `template`。現場が指定した値で切り替えられると、紐づけの意味が無くなる。
// admin（社長）だけは疎通確認のために ?template= で選べる。
$assigned = trim((string)($entry['template'] ?? ''));
$asked    = trim((string)($_GET['template'] ?? ''));
if ($assigned !== '') {
    if ($asked !== '' && $asked !== $assigned) {
        fail(403, 'template_not_allowed', ['allowed' => $assigned]);
    }
    $template = $assigned;
} elseif ($role === 'admin' && $asked !== '') {
    $template = $asked;
} else {
    fail(403, 'template_not_assigned',
        ['hint' => 'このトークンにはテンプレートが紐づいていません。社長に再発行を依頼してください']);
}
if (!in_array($template, $TEMPLATES, true)) {
    // パスに入れる前に許可リストで潰す。🚨 **応答に一覧を出さない**＝ここへ来るのは設定の不整合で、
    // 呼び出し側は他のプロファイル名を知っても何もできない（自分の分は template_not_allowed が返す）
    fail(400, 'unknown_template',
        ['hint' => '配布プロファイルの定義に無い名前です。社長に確認してください']);
}

$dir  = $RELEASE_DIR . '/' . $template;
$meta = null;
// 公開中（bin/rules-publish.py が3ファイルを差し替えている最中）は隠す。途中を見せると
// 「meta の SHA256 と実体が違う」配布物を渡すことになり、受け取り側の照合が落ちる。
if (is_file($dir . '/.publishing')) {
    fail(503, 'not_published',
        ['template' => $template, 'hint' => 'いま配信版を更新しています。少し待ってから実行してください']);
}
if (is_file($dir . '/meta.json')) {
    $decoded = json_decode((string)file_get_contents($dir . '/meta.json'), true);
    if (is_array($decoded)) {
        $meta = $decoded;
    }
}
if ($meta === null) {
    fail(503, 'not_published',
        ['template' => $template,
         'hint' => 'この版はまだ配信されていません（社長が bin/rules-publish.py publish を実行すると配信されます）']);
}

// 最終使用の記録（1リクエスト1回）。取りに来たことと、そのとき配信中だった版を残す＝
// 「どの案件がいつ何版を取ったか」を、こちらから別に記録しなくても分かる。
$known_actions = ['version', 'changelog', 'fetch'];
seen_touch($STATE_DIR, $agent, (string)($_SERVER['REMOTE_ADDR'] ?? ''), false, 0, [
    // 記録に残すのは既知の action だけ。生の値を書くと、長い文字列を投げられて状態ファイルが膨らむ
    'last_rules_action'  => in_array($action, $known_actions, true) ? $action : 'unknown',
    'last_rules_at'      => (new DateTime('now', new DateTimeZone('Asia/Tokyo')))->format('c'),
    'last_rules_version' => (string)($meta['version'] ?? ''),
    'rules_template'     => $template,
]);

// ---- version（いま配られている版） ----------------------------------------
if ($action === 'version') {
    echo json_encode([
        'ok' => true, 'template' => $template,
        'version' => $meta['version'] ?? '', 'sha' => $meta['sha'] ?? '',
        'published_at' => $meta['published_at'] ?? '',
        'size' => $meta['size'] ?? 0, 'sha256' => $meta['sha256'] ?? '',
    ], JSON_OPT);
    exit;
}

// ---- changelog（自分の版より後に何が変わったかを、現場が自分で読めるように） ----
if ($action === 'changelog') {
    $path = $dir . '/changelog.tsv';
    if (!is_file($path)) {
        fail(503, 'not_published', ['template' => $template]);
    }
    header('Content-Type: text/plain; charset=utf-8');
    readfile($path);
    exit;
}

// ---- fetch（配布物一式） ---------------------------------------------------
if ($action === 'fetch') {
    $path = $dir . '/package.tar.gz';
    if (!is_file($path)) {
        fail(503, 'not_published', ['template' => $template]);
    }
    header('Content-Type: application/gzip');
    header('Content-Length: ' . (string)filesize($path));
    header('Content-Disposition: attachment; filename="' . $template . '.tar.gz"');
    header('X-Rules-Version: ' . (string)($meta['version'] ?? ''));
    header('X-Rules-Sha256: ' . (string)($meta['sha256'] ?? ''));   // 受け取り側が壊れた取得を検出できる
    readfile($path);
    exit;
}

fail(400, 'unknown_action', ['action' => $action, 'allowed' => ['version', 'changelog', 'fetch']]);
