<?php
declare(strict_types=1);
require_once __DIR__ . '/_financial-lib.php';

const JOURNAL_DIR = FINANCIAL_ROOT . '/journal';
const JOURNAL_MAX_FILE_SIZE = 5 * 1024 * 1024;
const JOURNAL_TARGET_FYS = [2025, 2026];

const CARD_STATEMENT_DIR = FINANCIAL_ROOT . '/card-statements';
const CARD_MAX_FILE_SIZE = 5 * 1024 * 1024;
const CARD_SOURCES = [
    'sbi-debit'    => '住信SBI VISAデビット',
    'resona-debit' => 'りそな VISAデビット',
    'smbc-card'    => '三井住友カード',
    'mirai-card'   => 'ミライノカード (MasterCard)',
    'other'        => 'その他',
];

const JOURNAL_RULES_FILE = FINANCIAL_ROOT . '/journal-rules.json';

const JOURNAL_REQUIRED_HEADERS = ['取引No', '取引日', '借方勘定科目', '借方金額(円)', '貸方勘定科目', '貸方金額(円)', '摘要'];
const CARD_RESONA_REQUIRED_HEADERS = ['利用日', '利用内容', '金額', '承認番号', 'ステータス'];
const CARD_SBI_REQUIRED_HEADERS = ['お取引日', 'お取引内容', 'お取引金額'];

function read_csv_rows(string $file): array {
    if (!is_file($file)) return [];
    $contents = file_get_contents($file);
    if ($contents === false || $contents === '') return [];
    if (substr($contents, 0, 3) === "\xEF\xBB\xBF") $contents = substr($contents, 3);
    if (!mb_check_encoding($contents, 'UTF-8')) {
        $converted = mb_convert_encoding($contents, 'UTF-8', 'SJIS-win,SJIS,UTF-8');
        if ($converted !== false) $contents = $converted;
    }
    $rows = [];
    $stream = fopen('php://memory', 'r+');
    fwrite($stream, $contents);
    rewind($stream);
    while (($row = fgetcsv($stream, 0, ',', '"', '')) !== false) {
        if ($row === [null] || $row === false) continue;
        $rows[] = $row;
    }
    fclose($stream);
    return $rows;
}

function validate_csv_headers(string $file, array $required): ?string {
    $rows = read_csv_rows($file);
    if (count($rows) < 1) return 'CSVが空またはパースできません';
    foreach ($required as $col) {
        if (array_search($col, $rows[0], true) === false) {
            return "必須列が見つかりません：「{$col}」（CSVの形式が想定と違う可能性があります）";
        }
    }
    return null;
}

function safe_save_uploaded(string $tmp_name, string $dest, ?callable $validate = null): array {
    $dir = dirname($dest);
    if (!is_dir($dir)) mkdir($dir, 0755, true);
    $tmp_dest = $dest . '.tmp.' . bin2hex(random_bytes(4));
    if (!move_uploaded_file($tmp_name, $tmp_dest)) {
        return ['type' => 'error', 'text' => '一時保存に失敗しました'];
    }
    if ($validate !== null) {
        $err = $validate($tmp_dest);
        if ($err !== null) {
            @unlink($tmp_dest);
            return ['type' => 'error', 'text' => $err];
        }
    }
    if (!rename($tmp_dest, $dest)) {
        @unlink($tmp_dest);
        return ['type' => 'error', 'text' => '保存に失敗しました（rename）'];
    }
    return ['type' => 'success', 'text' => ''];
}

function handle_journal_upload(): array {
    $fy = (int)($_POST['fy'] ?? 0);
    if ($fy < 2020 || $fy > 2100) return ['type' => 'error', 'text' => '年度の指定が不正です'];

    if (!isset($_FILES['journal_csv']) || $_FILES['journal_csv']['error'] === UPLOAD_ERR_NO_FILE) {
        return ['type' => 'error', 'text' => 'ファイルが選択されていません'];
    }
    $f = $_FILES['journal_csv'];
    if ($f['error'] !== UPLOAD_ERR_OK) return ['type' => 'error', 'text' => "アップロードエラー (code: {$f['error']})"];
    if ($f['size'] > JOURNAL_MAX_FILE_SIZE) return ['type' => 'error', 'text' => 'ファイルサイズが5MBを超えています'];

    $dest = JOURNAL_DIR . "/FY{$fy}.csv";
    $result = safe_save_uploaded(
        $f['tmp_name'],
        $dest,
        fn(string $p) => validate_csv_headers($p, JOURNAL_REQUIRED_HEADERS)
    );
    if ($result['type'] === 'success') {
        $result['text'] = "✅ FY{$fy}.csv を保存しました（" . number_format($f['size']) . "バイト）";
    }
    return $result;
}

function detect_sbi_period(string $file): ?string {
    $rows = read_csv_rows($file);
    if (count($rows) < 2) return null;
    $months = [];
    foreach (array_slice($rows, 1) as $row) {
        $date = trim((string)($row[1] ?? ''));
        if (preg_match('#^(\d{4})/(\d{1,2})/\d{1,2}$#', $date, $m)) {
            $ym = sprintf('%04d-%02d', (int)$m[1], (int)$m[2]);
            $months[$ym] = ($months[$ym] ?? 0) + 1;
        }
    }
    if (empty($months)) return null;
    arsort($months);
    $top_ym = array_key_first($months);
    $top_count = $months[$top_ym];
    $total = array_sum($months);
    if ($total > 0 && $top_count / $total >= 0.6) return $top_ym;
    return null;
}

function handle_card_upload(): array {
    $source = (string)($_POST['card_source'] ?? '');
    if (!array_key_exists($source, CARD_SOURCES)) {
        return ['type' => 'error', 'text' => 'カード種別の指定が不正です'];
    }
    $label = trim((string)($_POST['card_label'] ?? ''));
    $label_auto = false;

    if (!isset($_FILES['card_csv']) || $_FILES['card_csv']['error'] === UPLOAD_ERR_NO_FILE) {
        return ['type' => 'error', 'text' => 'ファイルが選択されていません'];
    }
    $f = $_FILES['card_csv'];
    if ($f['error'] !== UPLOAD_ERR_OK) return ['type' => 'error', 'text' => "アップロードエラー (code: {$f['error']})"];
    if ($f['size'] > CARD_MAX_FILE_SIZE) return ['type' => 'error', 'text' => 'ファイルサイズが5MBを超えています'];

    $validator = match ($source) {
        'resona-debit' => fn(string $p) => validate_csv_headers($p, CARD_RESONA_REQUIRED_HEADERS),
        'sbi-debit'    => fn(string $p) => validate_csv_headers($p, CARD_SBI_REQUIRED_HEADERS),
        default        => null,
    };

    if ($label === '') {
        if ($source === 'sbi-debit') {
            $detected = detect_sbi_period($f['tmp_name']);
            if ($detected === null) {
                return ['type' => 'error', 'text' => 'ラベルを自動推定できませんでした。「2026-04」形式で手動指定してください'];
            }
            $label = $detected;
            $label_auto = true;
        } else {
            return ['type' => 'error', 'text' => 'ラベル（「FY2026」または「2026-04」）を指定してください'];
        }
    }
    if (!preg_match('/^(FY\d{4}|\d{4}-\d{2})$/', $label)) {
        return ['type' => 'error', 'text' => 'ラベルは「FY2026」または「2026-04」の形式で指定してください'];
    }

    $dest = CARD_STATEMENT_DIR . '/' . $source . "/{$label}.csv";
    $result = safe_save_uploaded($f['tmp_name'], $dest, $validator);
    if ($result['type'] === 'success') {
        $src_label = CARD_SOURCES[$source];
        $auto_note = $label_auto ? '（中身から自動推定）' : '';
        $result['text'] = "✅ {$src_label} / {$label}.csv を保存しました{$auto_note}（" . number_format($f['size']) . "バイト）";
    }
    return $result;
}

function list_card_statements(): array {
    if (!is_dir(CARD_STATEMENT_DIR)) return [];
    $result = [];
    foreach (CARD_SOURCES as $slug => $label) {
        $dir = CARD_STATEMENT_DIR . '/' . $slug;
        if (!is_dir($dir)) continue;
        $files = glob($dir . '/*.csv') ?: [];
        foreach ($files as $f) {
            if (!preg_match('/\/(FY\d{4}|\d{4}-\d{2})\.csv$/', $f, $m)) continue;
            $result[] = [
                'source' => $slug,
                'source_label' => $label,
                'period' => $m[1],
                'path' => $f,
                'size' => filesize($f),
                'mtime' => filemtime($f),
            ];
        }
    }
    usort($result, function ($a, $b) {
        if ($a['source'] !== $b['source']) return strcmp($a['source'], $b['source']);
        return strcmp($b['period'], $a['period']);
    });
    return $result;
}

function list_journal_files(): array {
    if (!is_dir(JOURNAL_DIR)) return [];
    $files = glob(JOURNAL_DIR . '/FY????.csv') ?: [];
    sort($files);
    $result = [];
    foreach ($files as $f) {
        if (preg_match('/FY(\d{4})\.csv$/', $f, $m)) {
            $fy = (int)$m[1];
            $result[$fy] = [
                'path' => $f,
                'size' => filesize($f),
                'mtime' => filemtime($f),
            ];
        }
    }
    return $result;
}

function load_journal(int $fy): ?array {
    $file = JOURNAL_DIR . "/FY{$fy}.csv";
    if (!is_file($file)) return null;
    $rows = read_csv_rows($file);
    if (count($rows) < 2) return null;

    $header = $rows[0];
    $idx = [];
    foreach (['取引No', '取引日', '借方勘定科目', '借方補助科目', '借方部門', '借方取引先', '借方税区分', '借方金額(円)', '貸方勘定科目', '貸方補助科目', '貸方部門', '貸方取引先', '貸方税区分', '貸方金額(円)', '摘要'] as $col) {
        $i = array_search($col, $header, true);
        $idx[$col] = $i === false ? null : (int)$i;
    }
    foreach (JOURNAL_REQUIRED_HEADERS as $col) {
        if ($idx[$col] === null) return null;
    }

    $entries = [];
    foreach (array_slice($rows, 1) as $row) {
        $get = fn(string $col) => $idx[$col] !== null ? trim((string)($row[$idx[$col]] ?? '')) : '';
        $to_int = fn(string $s): int => (int)str_replace([',', '"', ' ', '　'], '', $s);
        $entries[] = [
            'tx_no' => $get('取引No'),
            'date' => $get('取引日'),
            'dr_acct' => $get('借方勘定科目'),
            'dr_sub' => $get('借方補助科目'),
            'dr_dept' => $get('借方部門'),
            'dr_partner' => $get('借方取引先'),
            'dr_tax' => $get('借方税区分'),
            'dr_amount' => $to_int($get('借方金額(円)')),
            'cr_acct' => $get('貸方勘定科目'),
            'cr_sub' => $get('貸方補助科目'),
            'cr_dept' => $get('貸方部門'),
            'cr_partner' => $get('貸方取引先'),
            'cr_tax' => $get('貸方税区分'),
            'cr_amount' => $to_int($get('貸方金額(円)')),
            'memo' => $get('摘要'),
        ];
    }
    return [
        'fy' => $fy,
        'file_mtime' => filemtime($file),
        'header' => $header,
        'entries' => $entries,
    ];
}

const CARD_DESC_DICT = [
    'ｴﾂｸｽｻ-ﾊﾞ-'        => 'エックスサーバー',
    'ｻｸﾗｲﾝﾀ-ﾈﾂﾄ'       => 'さくらインターネット',
    'ﾑ-ﾑ-ﾄﾞﾒｲﾝ'        => 'ムームードメイン',
    'ｶ)ｼｰｴｽｱｰﾙ'         => '株式会社CSR',
    'ｴﾌｲ-ﾙｳｵ-ﾀ-ﾏｲﾂｷﾊﾂｶｼﾞﾒ' => 'エフィールウォーター（毎月初日定期）',
    'ｶﾌﾞｼｷｶﾞｲｼｬｸﾗｳﾄﾞﾜｰｸｽ' => 'クラウドワークス',
    'CROWDWORKS'         => 'クラウドワークス',
    'タイムズパーキング／ｉＤ'  => 'タイムズパーキング',
    'ｽｲｶ(ｹ-ﾀｲｹﾂｻｲ)'    => 'スイカ',
    'ＥＮＥＯＳ－ＳＳ／ｉＤ'    => 'ＥＮＥＯＳ－ＳＳ',
    'ﾍﾟｲﾍﾟｲ ｹｲﾊﾝｼﾃｨﾓｰﾙ' => '京阪シティモール',
    'ＭＩＣＲＯＳＯＦＴ－Ｇ１６１１６５２５９' => 'Microsoft',
    'MICROSOFT#G154934155' => 'Microsoft',
    'ＡＤＳ１５１２７８８３５６' => 'GoogleAds',
    'AMAZON WEB SERVICES JAP' => 'AMAZON WEB SERVICES',
    'ＡＭＡＺＯＮ　ＷＥＢ　ＳＥＲＶＩＣＥＳ' => 'AMAZON WEB SERVICES',
];

// 末尾にランダムなトークンが付き、literal置換では正規化できない明細用（str_replace後・かな正規化前に適用）
const CARD_DESC_REGEX = [
    '/^GOOGLE\*CLOUD\s+[A-Z0-9]+$/u' => 'GOOGLE CLOUD',
];

function pretty_card_desc(string $desc): string {
    foreach (CARD_DESC_DICT as $from => $to) {
        $desc = str_replace($from, $to, $desc);
    }
    foreach (CARD_DESC_REGEX as $pat => $to) {
        $desc = preg_replace($pat, $to, $desc);
    }
    return mb_convert_kana($desc, 'KV');
}

function extract_visa_debit_code(string $memo): ?string {
    if (preg_match('/VISAデビ\s+0?(\d{6,7})A?/u', $memo, $m)) {
        $code = ltrim($m[1], '0');
        if ($code === '') $code = $m[1];
        return $code;
    }
    return null;
}

function parse_card_statement_resona(string $file): array {
    $rows = read_csv_rows($file);
    if (count($rows) < 2) return [];
    $result = [];
    foreach (array_slice($rows, 1) as $row) {
        if (count($row) < 5) continue;
        $auth = trim((string)($row[3] ?? ''));
        if ($auth === '') continue;
        $raw = trim((string)($row[1] ?? ''));
        $result[ltrim($auth, '0')] = [
            'date' => trim((string)($row[0] ?? '')),
            'desc' => pretty_card_desc($raw),
            'desc_raw' => $raw,
            'amount' => (int)str_replace([',', '"', ' '], '', (string)($row[2] ?? '')),
            'status' => trim((string)($row[4] ?? '')),
            'source' => 'resona-debit',
            'source_label' => 'りそなVISAデビ',
        ];
    }
    return $result;
}

function parse_card_statement_sbi(string $file): array {
    $rows = read_csv_rows($file);
    if (count($rows) < 2) return [];
    $result = [];
    foreach (array_slice($rows, 1) as $row) {
        if (count($row) < 5) continue;
        $marker = trim((string)($row[0] ?? ''));
        if ($marker !== '2') continue;
        $date = trim((string)($row[1] ?? ''));
        $desc = trim((string)($row[2] ?? ''));
        $amount = (int)round((float)str_replace([',', '"', ' '], '', (string)($row[4] ?? '')));
        if ($date === '' || $amount === 0) continue;
        $result[] = [
            'date' => $date,
            'desc' => pretty_card_desc($desc),
            'desc_raw' => $desc,
            'amount' => $amount,
            'source' => 'sbi-debit',
            'source_label' => '住信SBI VISAデビ',
        ];
    }
    return $result;
}

function build_sbi_index(array $stmts): array {
    $idx = [];
    foreach ($stmts as $i => $s) {
        $key = $s['date'] . '|' . $s['amount'];
        $idx[$key][] = $i;
    }
    return $idx;
}

function is_sbi_debit_entry(array $e): bool {
    return mb_strpos($e['cr_sub'], '住信SBI') !== false
        && mb_strpos($e['memo'], 'デビット') !== false;
}

const SBI_NEAR_DAYS_MAX = 6;
const SBI_FUZZY_AMOUNT_RATIO = 0.03;
const SBI_FUZZY_AMOUNT_ABS_MAX = 500;

function build_pending_list(array $journal, array $card_lookup, array $sbi_stmts): array {
    $sbi_idx = build_sbi_index($sbi_stmts);
    $sbi_used = [];
    $pending = [];
    foreach ($journal['entries'] as $i => $e) {
        if (mb_strpos($e['dr_acct'], '要確認') === false) continue;
        $code = extract_visa_debit_code($e['memo']);
        $card = null;
        $match_kind = null;

        if ($code !== null && isset($card_lookup[$code])) {
            $card = $card_lookup[$code];
            $match_kind = 'auth';
        }

        $pending[] = [
            'line' => $i + 2,
            'tx_no' => $e['tx_no'],
            'date' => $e['date'],
            'amount' => $e['dr_amount'],
            'memo' => $e['memo'],
            'code' => $code,
            'card' => $card,
            'match_kind' => $match_kind,
            '_entry' => $e,
        ];
    }

    $try_sbi_match = function (int $k, int $delta) use (&$pending, &$sbi_used, $sbi_idx, $sbi_stmts): bool {
        $p = $pending[$k];
        $ts = strtotime(str_replace('/', '-', $p['date']));
        if ($ts === false) return false;
        $nd = date('Y/m/d', $ts + 86400 * $delta);
        $key = $nd . '|' . $p['amount'];
        if (!isset($sbi_idx[$key])) return false;
        foreach ($sbi_idx[$key] as $j) {
            if (isset($sbi_used[$j])) continue;
            $sbi_used[$j] = true;
            $pending[$k]['card'] = $sbi_stmts[$j];
            if ($delta === 0) {
                $pending[$k]['match_kind'] = count($sbi_idx[$key]) > 1 ? 'date-amount-multi' : 'date-amount';
            } else {
                $pending[$k]['match_kind'] = 'date-amount-near' . abs($delta);
            }
            return true;
        }
        return false;
    };

    // パス1：同日同額（完全一致）
    foreach ($pending as $k => $p) {
        if ($p['card'] !== null) continue;
        if (!is_sbi_debit_entry($p['_entry'])) continue;
        $try_sbi_match($k, 0);
    }

    // パス2：±1〜N日同額（距離の近い順）
    for ($dist = 1; $dist <= SBI_NEAR_DAYS_MAX; $dist++) {
        foreach ($pending as $k => $p) {
            if ($pending[$k]['card'] !== null) continue;
            if (!is_sbi_debit_entry($pending[$k]['_entry'])) continue;
            if ($try_sbi_match($k, -$dist)) continue;
            $try_sbi_match($k, $dist);
        }
    }

    // パス3：金額近似マッチ（為替レート差等。同日 → ±N日 の順、金額差最小を選択）
    $try_sbi_fuzzy = function (int $k, int $delta) use (&$pending, &$sbi_used, $sbi_stmts): bool {
        $p = $pending[$k];
        $ts = strtotime(str_replace('/', '-', $p['date']));
        if ($ts === false || $p['amount'] === 0) return false;
        $target_date = date('Y/m/d', $ts + 86400 * $delta);
        $best_j = null;
        $best_diff = PHP_INT_MAX;
        foreach ($sbi_stmts as $j => $s) {
            if (isset($sbi_used[$j])) continue;
            if ($s['date'] !== $target_date) continue;
            $diff = abs($s['amount'] - $p['amount']);
            if ($diff === 0) continue;
            if ($diff > SBI_FUZZY_AMOUNT_ABS_MAX) continue;
            if ($diff / $p['amount'] > SBI_FUZZY_AMOUNT_RATIO) continue;
            if ($diff < $best_diff) {
                $best_diff = $diff;
                $best_j = $j;
            }
        }
        if ($best_j === null) return false;
        $sbi_used[$best_j] = true;
        $card = $sbi_stmts[$best_j];
        $card['amount_diff'] = $card['amount'] - $p['amount'];
        $pending[$k]['card'] = $card;
        $pending[$k]['match_kind'] = $delta === 0 ? 'fuzzy' : 'fuzzy-near' . abs($delta);
        return true;
    };

    foreach ($pending as $k => $p) {
        if ($pending[$k]['card'] !== null) continue;
        if (!is_sbi_debit_entry($pending[$k]['_entry'])) continue;
        $try_sbi_fuzzy($k, 0);
    }
    for ($dist = 1; $dist <= SBI_NEAR_DAYS_MAX; $dist++) {
        foreach ($pending as $k => $p) {
            if ($pending[$k]['card'] !== null) continue;
            if (!is_sbi_debit_entry($pending[$k]['_entry'])) continue;
            if ($try_sbi_fuzzy($k, -$dist)) continue;
            $try_sbi_fuzzy($k, $dist);
        }
    }

    foreach ($pending as &$p) unset($p['_entry']);
    return $pending;
}

function load_journal_rules(): array {
    if (!is_file(JOURNAL_RULES_FILE)) return [];
    $json = file_get_contents(JOURNAL_RULES_FILE);
    if ($json === false || $json === '') return [];
    $data = json_decode($json, true);
    if (!is_array($data) || !isset($data['rules']) || !is_array($data['rules'])) return [];
    return $data['rules'];
}

function apply_rule(string $desc, array $rules): ?array {
    foreach ($rules as $r) {
        $m = $r['match'] ?? '';
        if ($m === '') continue;
        $type = $r['match_type'] ?? 'exact';
        $hit = match ($type) {
            'exact'    => $desc === $m,
            'contains' => mb_strpos($desc, $m) !== false,
            'prefix'   => str_starts_with($desc, $m),
            default    => false,
        };
        if ($hit) return $r;
    }
    return null;
}

function group_pending_by_pattern(array $pending): array {
    $groups = [];
    foreach ($pending as $p) {
        $key = $p['card']['desc'] ?? '(カード明細未マッチ)';
        if (!isset($groups[$key])) {
            $groups[$key] = ['count' => 0, 'total' => 0, 'items' => [], 'matched' => $p['card'] !== null, 'desc_raws' => []];
        }
        $groups[$key]['count']++;
        $groups[$key]['total'] += $p['amount'];
        $groups[$key]['items'][] = $p;
        $raw = $p['card']['desc_raw'] ?? null;
        if ($raw !== null && $raw !== $key) {
            $groups[$key]['desc_raws'][$raw] = true;
        }
    }
    uasort($groups, fn($a, $b) => $b['total'] <=> $a['total']);
    return $groups;
}

function analyze_journal(array $journal): array {
    $entries = $journal['entries'];
    $tx_nos = [];
    $dr_total = 0;
    $cr_total = 0;
    $dr_by_acct = [];
    $cr_by_acct = [];
    $dr_by_acct_sub = [];
    $cr_by_acct_sub = [];
    $by_month = [];
    $tax_kinds = [];
    $date_min = null; $date_max = null;
    $issues = [];

    $tx_totals = [];

    foreach ($entries as $i => $e) {
        $line = $i + 2;
        if ($e['tx_no'] !== '') $tx_nos[$e['tx_no']] = true;

        $dr_total += $e['dr_amount'];
        $cr_total += $e['cr_amount'];

        if ($e['dr_acct'] !== '' && $e['dr_amount'] > 0) {
            $dr_by_acct[$e['dr_acct']] = ($dr_by_acct[$e['dr_acct']] ?? 0) + $e['dr_amount'];
            $dsub = $e['dr_sub'] !== '' ? $e['dr_sub'] : '（補助科目なし）';
            $dr_by_acct_sub[$e['dr_acct']][$dsub] = ($dr_by_acct_sub[$e['dr_acct']][$dsub] ?? 0) + $e['dr_amount'];
        }
        if ($e['cr_acct'] !== '' && $e['cr_amount'] > 0) {
            $cr_by_acct[$e['cr_acct']] = ($cr_by_acct[$e['cr_acct']] ?? 0) + $e['cr_amount'];
            $csub = $e['cr_sub'] !== '' ? $e['cr_sub'] : '（補助科目なし）';
            $cr_by_acct_sub[$e['cr_acct']][$csub] = ($cr_by_acct_sub[$e['cr_acct']][$csub] ?? 0) + $e['cr_amount'];
        }

        if ($e['dr_tax'] !== '') $tax_kinds[$e['dr_tax']] = ($tax_kinds[$e['dr_tax']] ?? 0) + 1;
        if ($e['cr_tax'] !== '' && $e['cr_tax'] !== $e['dr_tax']) $tax_kinds[$e['cr_tax']] = ($tax_kinds[$e['cr_tax']] ?? 0) + 1;

        if (preg_match('#^(\d{4})/(\d{1,2})/(\d{1,2})$#', $e['date'], $m)) {
            $ym = sprintf('%04d-%02d', (int)$m[1], (int)$m[2]);
            if (!isset($by_month[$ym])) $by_month[$ym] = ['dr' => 0, 'cr' => 0, 'count' => 0];
            $by_month[$ym]['dr'] += $e['dr_amount'];
            $by_month[$ym]['cr'] += $e['cr_amount'];
            $by_month[$ym]['count']++;
            $d = sprintf('%04d-%02d-%02d', (int)$m[1], (int)$m[2], (int)$m[3]);
            if ($date_min === null || $d < $date_min) $date_min = $d;
            if ($date_max === null || $d > $date_max) $date_max = $d;
        } elseif ($e['date'] !== '') {
            $issues[] = ['line' => $line, 'severity' => 'warn', 'type' => '日付形式', 'detail' => "解釈不能な日付：「{$e['date']}」"];
        }

        if ($e['tx_no'] !== '') {
            if (!isset($tx_totals[$e['tx_no']])) $tx_totals[$e['tx_no']] = ['dr' => 0, 'cr' => 0, 'lines' => []];
            $tx_totals[$e['tx_no']]['dr'] += $e['dr_amount'];
            $tx_totals[$e['tx_no']]['cr'] += $e['cr_amount'];
            $tx_totals[$e['tx_no']]['lines'][] = $line;
        }

        if ($e['dr_amount'] === 0 && $e['cr_amount'] === 0) {
            $issues[] = ['line' => $line, 'severity' => 'warn', 'type' => '金額空欄', 'detail' => '借方・貸方とも金額0'];
        }
    }

    foreach ($tx_totals as $no => $t) {
        if ($t['dr'] !== $t['cr']) {
            $diff = $t['dr'] - $t['cr'];
            $issues[] = ['line' => $t['lines'][0], 'severity' => 'error', 'type' => '貸借不一致', 'detail' => "取引No {$no}：借方 ¥" . number_format($t['dr']) . " ≠ 貸方 ¥" . number_format($t['cr']) . "（差額 ¥" . number_format($diff) . "）"];
        }
    }

    arsort($dr_by_acct);
    arsort($cr_by_acct);
    foreach ($dr_by_acct_sub as &$_subs) arsort($_subs); unset($_subs);
    foreach ($cr_by_acct_sub as &$_subs) arsort($_subs); unset($_subs);
    ksort($by_month);
    arsort($tax_kinds);

    $dup_buckets = [];
    foreach ($entries as $i => $e) {
        if ($e['date'] === '') continue;
        $amount = max($e['dr_amount'], $e['cr_amount']);
        if ($amount === 0) continue;
        $key = $e['date'] . '|' . $e['dr_acct'] . '|' . $e['cr_acct'] . '|' . $amount;
        $dup_buckets[$key][] = ['line' => $i + 2, 'entry' => $e];
    }
    $dups = [];
    foreach ($dup_buckets as $key => $items) {
        if (count($items) >= 2) $dups[] = ['key' => $key, 'items' => $items];
    }

    return [
        'tx_count' => count($tx_nos),
        'line_count' => count($entries),
        'dr_total' => $dr_total,
        'cr_total' => $cr_total,
        'balance_ok' => $dr_total === $cr_total,
        'dr_by_acct' => $dr_by_acct,
        'cr_by_acct' => $cr_by_acct,
        'dr_by_acct_sub' => $dr_by_acct_sub,
        'cr_by_acct_sub' => $cr_by_acct_sub,
        'by_month' => $by_month,
        'tax_kinds' => $tax_kinds,
        'date_min' => $date_min,
        'date_max' => $date_max,
        'issues' => $issues,
        'dups' => $dups,
    ];
}

$message = null;
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $upload_type = (string)($_POST['upload_type'] ?? 'journal');
    if ($upload_type === 'card') {
        $message = handle_card_upload();
    } else {
        $message = handle_journal_upload();
    }
}

$files = list_journal_files();
$card_files = list_card_statements();
$selected_fy = isset($_GET['fy']) ? (int)$_GET['fy'] : (array_key_last($files) ?: 0);
$journal = ($selected_fy && isset($files[$selected_fy])) ? load_journal($selected_fy) : null;
$analysis = $journal ? analyze_journal($journal) : null;

$card_lookup = [];
$sbi_stmts = [];
if ($journal && $selected_fy) {
    $resona_file = CARD_STATEMENT_DIR . "/resona-debit/FY{$selected_fy}.csv";
    if (is_file($resona_file)) {
        $card_lookup += parse_card_statement_resona($resona_file);
    }
    $sbi_dir = CARD_STATEMENT_DIR . '/sbi-debit';
    if (is_dir($sbi_dir)) {
        $sbi_files = glob($sbi_dir . '/*.csv') ?: [];
        $fy_start = sprintf('%04d/04/01', $selected_fy);
        $fy_end   = sprintf('%04d/03/31', $selected_fy + 1);
        foreach ($sbi_files as $sf) {
            foreach (parse_card_statement_sbi($sf) as $st) {
                if ($st['date'] >= $fy_start && $st['date'] <= $fy_end) {
                    $sbi_stmts[] = $st;
                }
            }
        }
    }
}
$journal_rules = load_journal_rules();
$pending = $journal ? build_pending_list($journal, $card_lookup, $sbi_stmts) : [];
$pending_groups = group_pending_by_pattern($pending);
foreach ($pending_groups as $desc => &$g) {
    $g['rule'] = apply_rule($desc, $journal_rules);
}
unset($g);
$pending_matched_count = count(array_filter($pending, fn($p) => $p['card'] !== null));

$default_fy = 2026;
?><!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>仕訳チェック — 株式会社はなさか</title>
<script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-50 text-gray-900">
<div class="max-w-6xl mx-auto p-6 md:p-10">

  <nav class="text-sm text-gray-500 mb-4">
    <a href="../index.html" class="text-blue-600 hover:underline">← 株式会社はなさか</a> &gt;
    <a href="index.php" class="text-blue-600 hover:underline">ビジネスダッシュボード</a>
  </nav>

  <h1 class="text-3xl font-bold mb-2">📒 仕訳チェック</h1>
  <p class="text-gray-600 mb-6 text-sm">
    MFクラウド「会計帳簿 → 仕訳帳」CSV を **年度単位（期首〜現時点）** でアップロードし、
    形式チェック・集計・重複検知を行う。
  </p>

  <?php if ($message): ?>
    <?php $bg = $message['type'] === 'success' ? 'bg-emerald-50 border-emerald-400 text-emerald-800' : 'bg-red-50 border-red-400 text-red-800'; ?>
    <div class="border-l-4 rounded p-3 mb-6 text-sm <?= $bg ?>"><?= h($message['text']) ?></div>
  <?php endif; ?>

  <!-- アップロード -->
  <details class="mb-8 bg-white border border-gray-300 rounded-lg" <?= empty($files) ? 'open' : '' ?>>
    <summary class="cursor-pointer p-4 font-semibold text-blue-700 hover:bg-blue-50">📤 仕訳帳CSVをアップロード</summary>
    <div class="p-4 border-t border-gray-200 space-y-3">
      <form method="POST" enctype="multipart/form-data" class="space-y-3">
        <input type="hidden" name="upload_type" value="journal">
        <div class="flex gap-4 items-center">
          <label class="font-semibold text-sm">対象年度：</label>
          <?php foreach (JOURNAL_TARGET_FYS as $fy): ?>
            <label class="inline-flex items-center gap-1">
              <input type="radio" name="fy" value="<?= $fy ?>" <?= $fy === $default_fy ? 'checked' : '' ?> required>
              <span>FY<?= $fy ?></span>
            </label>
          <?php endforeach; ?>
        </div>
        <div>
          <label class="block text-sm font-semibold mb-1">仕訳帳 CSV（期首〜現時点）</label>
          <input type="file" name="journal_csv" accept=".csv,text/csv" required
                 class="text-sm file:mr-3 file:py-1.5 file:px-3 file:rounded file:border-0 file:bg-blue-600 file:text-white file:font-semibold">
        </div>
        <button type="submit" class="bg-blue-600 hover:bg-blue-700 text-white font-bold py-2 px-5 rounded">アップロード</button>
        <p class="text-xs text-gray-500">保存先：<code>data/financial/journal/FY{年度}.csv</code>（gitignored）/ 最大5MB / 同年度は上書き</p>
        <div class="text-xs text-gray-700 bg-gray-50 border border-gray-200 rounded p-2">
          <strong>📥 MFクラウドでの取得手順</strong><br>
          会計帳簿 → <strong>仕訳帳</strong> → 期間を期首〜現時点（FY2026 なら 2026-04-01〜本日）に指定 → エクスポート → ここにアップロード
        </div>
      </form>
    </div>
  </details>

  <!-- カード明細アップロード -->
  <details class="mb-8 bg-white border border-gray-300 rounded-lg" <?= empty($card_files) ? 'open' : '' ?>>
    <summary class="cursor-pointer p-4 font-semibold text-purple-700 hover:bg-purple-50">💳 カード明細（VISAデビット等）CSVをアップロード</summary>
    <div class="p-4 border-t border-gray-200 space-y-3">
      <p class="text-xs text-gray-600">
        仕訳帳の「★要確認」（VISAデビット引落）の科目を特定するため、各カード／銀行のデビット・カード明細CSVを保管する。<br>
        保存先：<code>data/financial/card-statements/&lt;source&gt;/&lt;label&gt;.csv</code>（gitignored）／ 同カード種別×同ラベルは上書き
      </p>
      <form method="POST" enctype="multipart/form-data" class="space-y-3">
        <input type="hidden" name="upload_type" value="card">
        <div class="flex flex-wrap gap-4 items-center">
          <label class="font-semibold text-sm">カード種別：</label>
          <?php foreach (CARD_SOURCES as $slug => $label): ?>
            <label class="inline-flex items-center gap-1 text-sm">
              <input type="radio" name="card_source" value="<?= h($slug) ?>" <?= $slug === 'sbi-debit' ? 'checked' : '' ?> required>
              <span><?= h($label) ?></span>
            </label>
          <?php endforeach; ?>
        </div>
        <div class="flex gap-3 items-center flex-wrap">
          <label class="font-semibold text-sm whitespace-nowrap">ラベル：</label>
          <input type="text" name="card_label" value="" pattern="(FY\d{4}|\d{4}-\d{2})"
                 class="border border-gray-300 rounded px-2 py-1 text-sm font-mono w-32" placeholder="自動推定">
          <span class="text-xs text-gray-500">
            空欄=自動推定（住信SBIのみ対応）／ 年度通し: <code>FY2026</code> ／ 月単位: <code>2026-04</code>
          </span>
        </div>
        <div>
          <label class="block text-sm font-semibold mb-1">カード明細 CSV</label>
          <input type="file" name="card_csv" accept=".csv,text/csv" required
                 class="text-sm file:mr-3 file:py-1.5 file:px-3 file:rounded file:border-0 file:bg-purple-600 file:text-white file:font-semibold">
        </div>
        <button type="submit" class="bg-purple-600 hover:bg-purple-700 text-white font-bold py-2 px-5 rounded">アップロード</button>
        <p class="text-xs text-gray-500">同ラベル（同カード種別 × 同ラベル）は上書き。違うラベルは別ファイルとして保存。</p>
      </form>
    </div>
  </details>

  <!-- 投入済みカード明細一覧 -->
  <?php if (!empty($card_files)): ?>
    <h2 class="text-xl font-bold mb-3">💳 投入済みカード明細</h2>
    <div class="overflow-x-auto border border-gray-300 rounded mb-8">
      <table class="w-full text-sm bg-white">
        <thead class="bg-gray-100">
          <tr>
            <th class="px-3 py-2 text-left">カード種別</th>
            <th class="px-3 py-2 text-left">ラベル</th>
            <th class="px-3 py-2 text-right">サイズ</th>
            <th class="px-3 py-2 text-left">最終更新</th>
          </tr>
        </thead>
        <tbody>
          <?php foreach ($card_files as $cf): ?>
          <tr class="border-t border-gray-200">
            <td class="px-3 py-2"><?= h($cf['source_label']) ?></td>
            <td class="px-3 py-2 font-mono"><?= h($cf['period']) ?></td>
            <td class="px-3 py-2 text-right text-gray-600"><?= number_format($cf['size']) ?> バイト</td>
            <td class="px-3 py-2 text-gray-600"><?= h(date('Y-m-d H:i', $cf['mtime'])) ?></td>
          </tr>
          <?php endforeach; ?>
        </tbody>
      </table>
    </div>
  <?php endif; ?>

  <!-- 投入済みファイル一覧 -->
  <?php if (!empty($files)): ?>
    <h2 class="text-xl font-bold mb-3">📁 投入済みファイル</h2>
    <div class="overflow-x-auto border border-gray-300 rounded mb-8">
      <table class="w-full text-sm bg-white">
        <thead class="bg-gray-100">
          <tr>
            <th class="px-3 py-2 text-left">年度</th>
            <th class="px-3 py-2 text-right">サイズ</th>
            <th class="px-3 py-2 text-left">最終更新</th>
            <th class="px-3 py-2 text-center">アクション</th>
          </tr>
        </thead>
        <tbody>
          <?php foreach (array_reverse($files, true) as $fy => $f): ?>
          <tr class="border-t border-gray-200 <?= $selected_fy === $fy ? 'bg-blue-50' : '' ?>">
            <td class="px-3 py-2 font-mono">FY<?= h((string)$fy) ?></td>
            <td class="px-3 py-2 text-right text-gray-600"><?= number_format($f['size']) ?> バイト</td>
            <td class="px-3 py-2 text-gray-600"><?= h(date('Y-m-d H:i', $f['mtime'])) ?></td>
            <td class="px-3 py-2 text-center">
              <a href="?fy=<?= $fy ?>" class="text-blue-600 hover:underline text-xs">分析を見る</a>
            </td>
          </tr>
          <?php endforeach; ?>
        </tbody>
      </table>
    </div>
  <?php endif; ?>

  <!-- 分析結果 -->
  <?php if ($analysis !== null): ?>
    <h2 class="text-xl font-bold mb-3">📊 分析結果：<span class="font-mono">FY<?= $selected_fy ?></span></h2>

    <!-- サマリ -->
    <div class="grid grid-cols-2 md:grid-cols-4 gap-3 mb-6">
      <div class="bg-white border border-gray-300 rounded p-3">
        <div class="text-xs text-gray-500">取引件数</div>
        <div class="text-2xl font-bold"><?= number_format($analysis['tx_count']) ?></div>
        <div class="text-xs text-gray-500">明細 <?= number_format($analysis['line_count']) ?> 行</div>
      </div>
      <div class="bg-white border border-gray-300 rounded p-3">
        <div class="text-xs text-gray-500">期間</div>
        <div class="text-base font-bold"><?= h($analysis['date_min'] ?? '—') ?></div>
        <div class="text-base font-bold"><?= h($analysis['date_max'] ?? '—') ?></div>
      </div>
      <div class="bg-white border border-gray-300 rounded p-3">
        <div class="text-xs text-gray-500">借方合計</div>
        <div class="text-xl font-bold"><?= jpy($analysis['dr_total']) ?></div>
      </div>
      <div class="bg-white border <?= $analysis['balance_ok'] ? 'border-emerald-400 bg-emerald-50' : 'border-red-400 bg-red-50' ?> rounded p-3">
        <div class="text-xs text-gray-500">貸方合計 / 貸借</div>
        <div class="text-xl font-bold"><?= jpy($analysis['cr_total']) ?></div>
        <div class="text-xs <?= $analysis['balance_ok'] ? 'text-emerald-700' : 'text-red-700 font-bold' ?>">
          <?= $analysis['balance_ok'] ? '✅ 一致' : '❌ 不一致（差 ' . number_format($analysis['dr_total'] - $analysis['cr_total']) . '）' ?>
        </div>
      </div>
    </div>

    <!-- ★要確認 マッチング -->
    <?php if (!empty($pending)): ?>
      <h3 class="text-lg font-bold mb-2">⚠ ★要確認の仕訳とカード明細マッチング（<?= count($pending) ?>件 / マッチ <?= $pending_matched_count ?>件）</h3>
      <p class="text-xs text-gray-600 mb-3">
        借方が「★要確認」の仕訳に対し、承認番号でカード明細を引き当てて利用内容を表示。同じ利用内容でグルーピングしているので、頻度の高いものから仕訳ルール化していくのが効率的。
      </p>

      <!-- パターン別サマリ -->
      <div class="border border-amber-300 rounded mb-4 overflow-hidden">
        <table class="w-full text-sm bg-white">
          <thead class="bg-amber-50">
            <tr>
              <th class="px-3 py-2 text-left">利用内容（カード明細）</th>
              <th class="px-3 py-2 text-right">件数</th>
              <th class="px-3 py-2 text-right">合計金額</th>
              <th class="px-3 py-2 text-left">候補科目（参考）</th>
            </tr>
          </thead>
          <tbody>
            <?php $gi = 0; foreach ($pending_groups as $desc => $g): ?>
            <tr class="border-t border-gray-200 cursor-pointer hover:bg-amber-50" data-toggle-target="grp-<?= $gi ?>">
              <td class="px-3 py-2">
                <span class="toggle-icon inline-block w-4 text-gray-400 text-xs">▶</span>
                <?php if (!$g['matched']): ?>
                  <span class="text-red-600 font-bold"><?= h($desc) ?></span>
                <?php else: ?>
                  <?= h($desc) ?>
                  <?php if (!empty($g['desc_raws'])): ?>
                    <span class="text-xs text-gray-500 ml-1">（<?= h(implode(' / ', array_keys($g['desc_raws']))) ?>）</span>
                  <?php endif; ?>
                <?php endif; ?>
              </td>
              <td class="px-3 py-2 text-right font-mono"><?= number_format($g['count']) ?></td>
              <td class="px-3 py-2 text-right"><?= jpy($g['total']) ?></td>
              <td class="px-3 py-2 text-xs">
                <?php if ($g['rule']): ?>
                  <span class="font-semibold text-blue-700"><?= h($g['rule']['dr_acct']) ?></span>
                  <?php if (!empty($g['rule']['dr_sub'])): ?>
                    <span class="text-gray-700"> / <?= h($g['rule']['dr_sub']) ?></span>
                  <?php endif; ?>
                  <?php if (!empty($g['rule']['dr_partner'])): ?>
                    <span class="text-gray-500"> / 取引先: <?= h($g['rule']['dr_partner']) ?></span>
                  <?php endif; ?>
                  <?php if (!empty($g['rule']['note'])): ?>
                    <div class="text-gray-500 mt-0.5"><?= h($g['rule']['note']) ?></div>
                  <?php endif; ?>
                <?php else: ?>
                  <span class="text-gray-400">—（未設定）</span>
                <?php endif; ?>
              </td>
            </tr>
            <tr id="grp-<?= $gi ?>" class="hidden bg-gray-50">
              <td colspan="4" class="px-6 py-2">
                <table class="w-full text-xs">
                  <thead class="text-gray-500">
                    <tr>
                      <th class="text-left py-1">日付</th>
                      <th class="text-left py-1">取引No</th>
                      <th class="text-right py-1">金額</th>
                      <th class="text-left py-1">マッチ</th>
                      <th class="text-left py-1">元の摘要</th>
                    </tr>
                  </thead>
                  <tbody>
                    <?php
                    $kind_badge = [
                      'auth'               => '<span class="px-1.5 py-0.5 rounded bg-emerald-100 text-emerald-700 text-xs">承認番号</span>',
                      'date-amount'        => '<span class="px-1.5 py-0.5 rounded bg-blue-100 text-blue-700 text-xs">日付＋金額</span>',
                      'date-amount-multi'  => '<span class="px-1.5 py-0.5 rounded bg-amber-100 text-amber-700 text-xs">日付＋金額(候補複数)</span>',
                      'date-amount-near1'  => '<span class="px-1.5 py-0.5 rounded bg-cyan-100 text-cyan-700 text-xs">±1日</span>',
                      'date-amount-near2'  => '<span class="px-1.5 py-0.5 rounded bg-cyan-100 text-cyan-700 text-xs">±2日</span>',
                      'date-amount-near3'  => '<span class="px-1.5 py-0.5 rounded bg-cyan-100 text-cyan-700 text-xs">±3日</span>',
                      'date-amount-near4'  => '<span class="px-1.5 py-0.5 rounded bg-amber-100 text-amber-700 text-xs">⚠ ±4日</span>',
                      'date-amount-near5'  => '<span class="px-1.5 py-0.5 rounded bg-amber-100 text-amber-700 text-xs">⚠ ±5日</span>',
                      'date-amount-near6'  => '<span class="px-1.5 py-0.5 rounded bg-amber-100 text-amber-700 text-xs">⚠ ±6日</span>',
                      'fuzzy'              => '<span class="px-1.5 py-0.5 rounded bg-orange-100 text-orange-700 text-xs">⚠ 暫定(同日・金額近似)</span>',
                      'fuzzy-near1'        => '<span class="px-1.5 py-0.5 rounded bg-orange-100 text-orange-700 text-xs">⚠ 暫定(±1日・金額近似)</span>',
                      'fuzzy-near2'        => '<span class="px-1.5 py-0.5 rounded bg-orange-100 text-orange-700 text-xs">⚠ 暫定(±2日・金額近似)</span>',
                      'fuzzy-near3'        => '<span class="px-1.5 py-0.5 rounded bg-orange-100 text-orange-700 text-xs">⚠ 暫定(±3日・金額近似)</span>',
                      'fuzzy-near4'        => '<span class="px-1.5 py-0.5 rounded bg-orange-100 text-orange-700 text-xs">⚠ 暫定(±4日・金額近似)</span>',
                      'fuzzy-near5'        => '<span class="px-1.5 py-0.5 rounded bg-orange-100 text-orange-700 text-xs">⚠ 暫定(±5日・金額近似)</span>',
                      'fuzzy-near6'        => '<span class="px-1.5 py-0.5 rounded bg-orange-100 text-orange-700 text-xs">⚠ 暫定(±6日・金額近似)</span>',
                    ];
                    $is_fuzzy = fn($k) => str_starts_with((string)$k, 'fuzzy');
                    ?>
                    <?php foreach ($g['items'] as $it):
                      $diff = $it['card']['amount_diff'] ?? null;
                    ?>
                    <tr class="<?= $is_fuzzy($it['match_kind']) ? 'bg-orange-50' : '' ?>">
                      <td class="py-0.5 font-mono"><?= h($it['date']) ?></td>
                      <td class="py-0.5 font-mono"><?= h($it['tx_no']) ?></td>
                      <td class="py-0.5 text-right">
                        <?= jpy($it['amount']) ?>
                        <?php if ($diff !== null && $diff !== 0): ?>
                          <span class="text-orange-700 text-xs ml-1">(明細 <?= jpy($it['card']['amount']) ?> / 差 <?= ($diff > 0 ? '+' : '') . number_format($diff) ?>円)</span>
                        <?php endif; ?>
                      </td>
                      <td class="py-0.5"><?= $kind_badge[$it['match_kind']] ?? '<span class="text-gray-400 text-xs">—</span>' ?></td>
                      <td class="py-0.5 text-gray-600"><?= h($it['memo']) ?></td>
                    </tr>
                    <?php endforeach; ?>
                  </tbody>
                </table>
              </td>
            </tr>
            <?php $gi++; endforeach; ?>
          </tbody>
        </table>
      </div>

      <p class="text-xs text-gray-500 mb-6">
        💡 次のフェーズで「利用内容のパターン → 借方科目／取引先」のルールを登録できる画面を追加します。
      </p>
    <?php endif; ?>

    <!-- 問題点 -->
    <?php if (!empty($analysis['issues'])): ?>
      <h3 class="text-lg font-bold mb-2">🚨 形式チェック（<?= count($analysis['issues']) ?>件）</h3>
      <div class="overflow-x-auto border border-red-300 rounded mb-6 max-h-96 overflow-y-auto">
        <table class="w-full text-sm bg-white">
          <thead class="bg-red-50 sticky top-0">
            <tr>
              <th class="px-3 py-2 text-left">行</th>
              <th class="px-3 py-2 text-left">種類</th>
              <th class="px-3 py-2 text-left">内容</th>
            </tr>
          </thead>
          <tbody>
            <?php foreach ($analysis['issues'] as $iss): ?>
            <tr class="border-t border-gray-200">
              <td class="px-3 py-1 font-mono text-xs"><?= $iss['line'] ?></td>
              <td class="px-3 py-1"><?= $iss['severity'] === 'error' ? '🔴' : '🟡' ?> <?= h($iss['type']) ?></td>
              <td class="px-3 py-1 text-xs"><?= h($iss['detail']) ?></td>
            </tr>
            <?php endforeach; ?>
          </tbody>
        </table>
      </div>
    <?php else: ?>
      <div class="border border-emerald-300 bg-emerald-50 rounded p-3 mb-6 text-sm text-emerald-800">
        ✅ 形式チェックOK：貸借一致・日付形式・金額空欄なし
      </div>
    <?php endif; ?>

    <!-- 月別合計 -->
    <h3 class="text-lg font-bold mb-2">📅 月別合計</h3>
    <div class="overflow-x-auto border border-gray-300 rounded mb-6">
      <table class="w-full text-sm bg-white">
        <thead class="bg-gray-100">
          <tr>
            <th class="px-3 py-2 text-left">月</th>
            <th class="px-3 py-2 text-right">明細行数</th>
            <th class="px-3 py-2 text-right">借方合計</th>
            <th class="px-3 py-2 text-right">貸方合計</th>
            <th class="px-3 py-2 text-center">一致</th>
          </tr>
        </thead>
        <tbody>
          <?php foreach ($analysis['by_month'] as $ym => $row): ?>
          <tr class="border-t border-gray-200">
            <td class="px-3 py-2 font-mono"><?= h($ym) ?></td>
            <td class="px-3 py-2 text-right text-gray-600"><?= number_format($row['count']) ?></td>
            <td class="px-3 py-2 text-right"><?= jpy($row['dr']) ?></td>
            <td class="px-3 py-2 text-right"><?= jpy($row['cr']) ?></td>
            <td class="px-3 py-2 text-center"><?= $row['dr'] === $row['cr'] ? '<span class="text-emerald-600">✅</span>' : '<span class="text-red-600">❌</span>' ?></td>
          </tr>
          <?php endforeach; ?>
        </tbody>
      </table>
    </div>

    <!-- 科目別合計：上位15 -->
    <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mb-6">
      <div>
        <h3 class="text-lg font-bold mb-2">📥 借方科目 TOP 15</h3>
        <p class="text-xs text-gray-500 mb-1">▶ をクリックすると補助科目の内訳を表示</p>
        <div class="overflow-x-auto border border-gray-300 rounded">
          <table class="w-full text-sm bg-white">
            <thead class="bg-gray-100">
              <tr><th class="px-3 py-2 text-left">勘定科目</th><th class="px-3 py-2 text-right">合計</th></tr>
            </thead>
            <tbody>
              <?php $i = 0; foreach (array_slice($analysis['dr_by_acct'], 0, 15, true) as $acct => $amt):
                $subs = $analysis['dr_by_acct_sub'][$acct] ?? [];
                $real_sub = 0;
                foreach ($subs as $s => $_v) if ($s !== '（補助科目なし）') $real_sub++;
                $toggleable = count($subs) >= 2 || $real_sub >= 1;
                $rid = 'dr-sub-' . $i;
              ?>
              <tr class="border-t border-gray-200<?= $toggleable ? ' cursor-pointer hover:bg-gray-50' : '' ?>"<?= $toggleable ? ' data-toggle-target="' . $rid . '"' : '' ?>>
                <td class="px-3 py-1">
                  <?php if ($toggleable): ?><span class="toggle-icon inline-block w-4 text-gray-400 text-xs">▶</span><?php else: ?><span class="inline-block w-4"></span><?php endif; ?>
                  <?= h($acct) ?>
                </td>
                <td class="px-3 py-1 text-right"><?= jpy($amt) ?></td>
              </tr>
              <?php if ($toggleable): ?>
              <tr id="<?= $rid ?>" class="hidden bg-gray-50">
                <td colspan="2" class="px-6 py-2">
                  <table class="w-full text-xs">
                    <tbody>
                      <?php foreach ($subs as $sub => $samt): ?>
                      <tr>
                        <td class="py-0.5 text-gray-700"><?= h($sub) ?></td>
                        <td class="py-0.5 text-right text-gray-700"><?= jpy($samt) ?></td>
                      </tr>
                      <?php endforeach; ?>
                    </tbody>
                  </table>
                </td>
              </tr>
              <?php endif; ?>
              <?php $i++; endforeach; ?>
            </tbody>
          </table>
        </div>
      </div>
      <div>
        <h3 class="text-lg font-bold mb-2">📤 貸方科目 TOP 15</h3>
        <p class="text-xs text-gray-500 mb-1">▶ をクリックすると補助科目の内訳を表示</p>
        <div class="overflow-x-auto border border-gray-300 rounded">
          <table class="w-full text-sm bg-white">
            <thead class="bg-gray-100">
              <tr><th class="px-3 py-2 text-left">勘定科目</th><th class="px-3 py-2 text-right">合計</th></tr>
            </thead>
            <tbody>
              <?php $i = 0; foreach (array_slice($analysis['cr_by_acct'], 0, 15, true) as $acct => $amt):
                $subs = $analysis['cr_by_acct_sub'][$acct] ?? [];
                $real_sub = 0;
                foreach ($subs as $s => $_v) if ($s !== '（補助科目なし）') $real_sub++;
                $toggleable = count($subs) >= 2 || $real_sub >= 1;
                $rid = 'cr-sub-' . $i;
              ?>
              <tr class="border-t border-gray-200<?= $toggleable ? ' cursor-pointer hover:bg-gray-50' : '' ?>"<?= $toggleable ? ' data-toggle-target="' . $rid . '"' : '' ?>>
                <td class="px-3 py-1">
                  <?php if ($toggleable): ?><span class="toggle-icon inline-block w-4 text-gray-400 text-xs">▶</span><?php else: ?><span class="inline-block w-4"></span><?php endif; ?>
                  <?= h($acct) ?>
                </td>
                <td class="px-3 py-1 text-right"><?= jpy($amt) ?></td>
              </tr>
              <?php if ($toggleable): ?>
              <tr id="<?= $rid ?>" class="hidden bg-gray-50">
                <td colspan="2" class="px-6 py-2">
                  <table class="w-full text-xs">
                    <tbody>
                      <?php foreach ($subs as $sub => $samt): ?>
                      <tr>
                        <td class="py-0.5 text-gray-700"><?= h($sub) ?></td>
                        <td class="py-0.5 text-right text-gray-700"><?= jpy($samt) ?></td>
                      </tr>
                      <?php endforeach; ?>
                    </tbody>
                  </table>
                </td>
              </tr>
              <?php endif; ?>
              <?php $i++; endforeach; ?>
            </tbody>
          </table>
        </div>
      </div>
    </div>

    <!-- 税区分内訳 -->
    <h3 class="text-lg font-bold mb-2">📋 税区分内訳</h3>
    <div class="overflow-x-auto border border-gray-300 rounded mb-6">
      <table class="w-full text-sm bg-white">
        <thead class="bg-gray-100">
          <tr><th class="px-3 py-2 text-left">税区分</th><th class="px-3 py-2 text-right">明細件数</th></tr>
        </thead>
        <tbody>
          <?php foreach ($analysis['tax_kinds'] as $tax => $cnt): ?>
          <tr class="border-t border-gray-200">
            <td class="px-3 py-1"><?= h($tax) ?></td>
            <td class="px-3 py-1 text-right text-gray-600"><?= number_format($cnt) ?></td>
          </tr>
          <?php endforeach; ?>
        </tbody>
      </table>
    </div>

    <!-- 重複疑い -->
    <h3 class="text-lg font-bold mb-2">🔁 重複疑い（同日・同借方・同貸方・同金額）</h3>
    <?php if (empty($analysis['dups'])): ?>
      <div class="border border-emerald-300 bg-emerald-50 rounded p-3 mb-6 text-sm text-emerald-800">
        ✅ 完全重複の組合せは検出されませんでした
      </div>
    <?php else: ?>
      <div class="overflow-x-auto border border-amber-300 rounded mb-6 max-h-96 overflow-y-auto">
        <table class="w-full text-sm bg-white">
          <thead class="bg-amber-50 sticky top-0">
            <tr>
              <th class="px-3 py-2 text-left">日付</th>
              <th class="px-3 py-2 text-left">借方</th>
              <th class="px-3 py-2 text-left">貸方</th>
              <th class="px-3 py-2 text-right">金額</th>
              <th class="px-3 py-2 text-left">該当行</th>
            </tr>
          </thead>
          <tbody>
            <?php foreach ($analysis['dups'] as $dup):
              [$date, $dr, $cr, $amt] = explode('|', $dup['key']);
            ?>
            <tr class="border-t border-gray-200">
              <td class="px-3 py-1 font-mono text-xs"><?= h($date) ?></td>
              <td class="px-3 py-1 text-xs"><?= h($dr ?: '（空）') ?></td>
              <td class="px-3 py-1 text-xs"><?= h($cr ?: '（空）') ?></td>
              <td class="px-3 py-1 text-right"><?= jpy((int)$amt) ?></td>
              <td class="px-3 py-1 text-xs text-gray-600"><?= h(implode(', ', array_column($dup['items'], 'line'))) ?>（<?= count($dup['items']) ?>件）</td>
            </tr>
            <?php endforeach; ?>
          </tbody>
        </table>
      </div>
    <?php endif; ?>

  <?php elseif (!empty($files)): ?>
    <div class="bg-gray-100 border border-gray-300 rounded p-6 text-center text-gray-600">
      ↑ 投入済みファイル一覧から「分析を見る」を選んでください
    </div>
  <?php else: ?>
    <div class="bg-gray-100 border border-gray-300 rounded p-6 text-center text-gray-600">
      仕訳帳CSVをアップロードすると、ここに分析結果が表示されます
    </div>
  <?php endif; ?>

  <div class="bg-gray-100 border border-gray-300 rounded p-4 text-xs text-gray-600 mt-8">
    <strong>運用メモ</strong>
    <ul class="list-disc list-inside mt-1 space-y-0.5">
      <li>年度単位（期首〜現時点）で運用。最新版を再アップすると上書き</li>
      <li>仕訳帳には金額・取引先名など機密情報を含むため、保存先は git 追跡対象外（<code>data/financial/</code> 配下）</li>
      <li>CSV エンコーディングは Shift_JIS / UTF-8 どちらも自動判別</li>
      <li>「重複疑い」は同日・同借方・同貸方・同金額の完全一致のみ検出（実取引で同パターンが複数発生するケースも含むため要目視確認）</li>
    </ul>
  </div>

</div>
<script>
document.querySelectorAll('tr[data-toggle-target]').forEach(tr => {
  tr.addEventListener('click', () => {
    const target = document.getElementById(tr.dataset.toggleTarget);
    if (!target) return;
    target.classList.toggle('hidden');
    const icon = tr.querySelector('.toggle-icon');
    if (icon) icon.textContent = target.classList.contains('hidden') ? '▶' : '▼';
  });
});
</script>
</body>
</html>
