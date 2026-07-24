<?php
declare(strict_types=1);
date_default_timezone_set('Asia/Tokyo');

const FINANCIAL_PROJECT_ROOT = '/home/vpsuser/projects/myagent';
const FINANCIAL_ROOT = FINANCIAL_PROJECT_ROOT . '/data/financial';

const TARGET_FYS = [2025, 2026];

const SUMMARY_KEYS = [
    '売上高合計' => ['label' => '売上高', 'big' => true, 'role' => 'revenue'],
    '売上総利益' => ['label' => '売上総利益', 'role' => 'gross'],
    '販売費及び一般管理費合計' => ['label' => '販管費合計', 'role' => 'sga'],
    '営業利益' => ['label' => '営業利益', 'big' => true, 'role' => 'op'],
    '経常利益' => ['label' => '経常利益', 'big' => true, 'role' => 'recurring'],
    '当期純利益' => ['label' => '当期純利益', 'big' => true, 'role' => 'net'],
];

function fy_dir(int $fy): string { return FINANCIAL_ROOT . '/' . $fy; }

function load_pl(int $fy): ?array {
    $file = fy_dir($fy) . '/pl.csv';
    if (!is_file($file)) return null;
    $contents = file_get_contents($file);
    if ($contents === false || $contents === '') return null;
    if (!mb_check_encoding($contents, 'UTF-8')) {
        $converted = mb_convert_encoding($contents, 'UTF-8', 'SJIS-win,SJIS,UTF-8');
        if ($converted !== false) $contents = $converted;
    }

    $rows = [];
    $stream = fopen('php://memory', 'r+');
    fwrite($stream, $contents);
    rewind($stream);
    while (($row = fgetcsv($stream)) !== false) {
        if ($row === [null] || $row === false) continue;
        $rows[] = $row;
    }
    fclose($stream);
    if (count($rows) < 2) return null;

    $header = $rows[0];
    $dates = [];
    foreach ($header as $h) {
        if (preg_match('/(\d{4})-(\d{2})-(\d{2})/', (string)$h, $m)) $dates[] = $m[0];
    }
    if (count($dates) < 2) return null;
    [$start_date, $end_date] = [$dates[0], $dates[1]];

    $items = [];
    $major_expenses = [];
    $in_sga = false;
    foreach (array_slice($rows, 1) as $row) {
        $top = trim((string)($row[0] ?? ''));
        $name = trim((string)($row[1] ?? ''));
        $sub = trim((string)($row[2] ?? ''));

        if (count($row) < 4) {
            if ($top === '販売費及び一般管理費') $in_sga = true;
            continue;
        }

        if (count($row) < 7) continue;
        $balance = (int)str_replace([',', '"'], '', (string)$row[6]);

        if ($sub !== '') continue;

        if ($top !== '' && $name === '') {
            $items[$top] = $balance;
            if ($top === '販売費及び一般管理費合計' || $top === '営業利益') $in_sga = false;
            continue;
        }

        if ($top === '' && $name !== '') {
            $items[$name] = $balance;
            if ($in_sga) $major_expenses[$name] = $balance;
        }
    }

    $start_y = (int)substr($start_date, 0, 4);
    $start_m = (int)substr($start_date, 5, 2);
    $end_y = (int)substr($end_date, 0, 4);
    $end_m = (int)substr($end_date, 5, 2);
    $months = ($end_y - $start_y) * 12 + ($end_m - $start_m) + 1;

    return [
        'fy' => $fy,
        'start' => $start_date,
        'end' => $end_date,
        'months' => $months,
        'is_full_year' => $months >= 12,
        'items' => $items,
        'major_expenses' => $major_expenses,
        'file_mtime' => filemtime($file),
    ];
}

function forecast(?array $pl): ?array {
    if ($pl === null || $pl['months'] <= 0) return null;
    if ($pl['is_full_year']) return $pl['items'];
    $factor = 12 / $pl['months'];
    $forecast = [];
    foreach ($pl['items'] as $k => $v) {
        $forecast[$k] = (int)round($v * $factor);
    }
    return $forecast;
}

function diff_pct(?int $base, ?int $cur): ?float {
    if ($base === null || $base === 0 || $cur === null) return null;
    return ($cur - $base) / abs($base) * 100;
}

function judge(float $pct, bool $expense = false): array {
    $good = $expense ? ($pct < 0) : ($pct > 0);
    if (abs($pct) < 5) return ['icon' => '🟡', 'label' => 'ほぼ同等', 'class' => 'text-amber-600'];
    if ($good) return ['icon' => '🟢', 'label' => $expense ? '改善' : '順調', 'class' => 'text-emerald-600 font-bold'];
    return ['icon' => '🔴', 'label' => $expense ? '増加' : '未達ペース', 'class' => 'text-red-600 font-bold'];
}

/**
 * 経理入力の健全性チェック（2026-07-24 追加）。
 *
 * 期中PLを12倍する通年予測は、費用の入力が遅れていると利益を極端に過大表示する
 * （実測：FY2026 の 2ヶ月PLは人件費が丸ごと未入力で、営業利益率 86.5% → 12倍予測で
 *  営業利益 ¥65M・前年比 +8,121% と表示されていた）。予測値そのものは残すが、
 * 数字を見た瞬間に「これは信用できない」と分かる警告を必ず添えるための判定。
 *
 * 詳細な集計は bin/finance-snapshot.py（T-019）が一次。ここは表示に必要な最小限だけ。
 */
function input_health(?array $cur, ?array $prev): array {
    $out = ['lag_months' => 0, 'missing' => [], 'missing_amount' => 0,
            'unclassified' => [], 'unclassified_amount' => 0,
            'no_data' => false, 'has_issue' => false];
    // 当期PLが1件も無いのは「入力異常の最上位」。黙って通さない（Python 側と同じ扱い）
    if ($cur === null) {
        $out['no_data'] = true;
        $out['has_issue'] = true;
        return $out;
    }

    // 締めるべき月＝前月。FY に依存せず「入力済みの終了月」との差だけで測る。
    // 月末どうしの日数差（2/28 と 6/30 等）で端数が出ないよう、月インデックスの差で数える
    $end = new DateTimeImmutable($cur['end']);
    $due = (new DateTimeImmutable('first day of this month'))->modify('-1 month');
    $out['lag_months'] = max(0,
        ((int)$due->format('Y') * 12 + (int)$due->format('n'))
        - ((int)$end->format('Y') * 12 + (int)$end->format('n')));

    // 未分類（マネーフォワードが判定を保留した残高）
    foreach ($cur['major_expenses'] as $name => $val) {
        if ($val > 0 && preg_match('/要確認|不明|仮受|仮払|未確定/u', $name)) {
            $out['unclassified'][] = $name;
            $out['unclassified_amount'] += $val;
        }
    }

    // 前年にあった主要費目（売上比1%以上）が今期ゼロ＝入力漏れの疑い
    if ($prev !== null && $prev['months'] > 0) {
        $prev_rev = $prev['items']['売上高合計'] ?? 0;
        foreach ($prev['major_expenses'] as $name => $val) {
            if ($val <= 0 || preg_match('/要確認|不明|仮受|仮払|未確定/u', $name)) continue;
            if ($prev_rev > 0 && ($val / $prev_rev) < 0.01) continue;
            if (($cur['major_expenses'][$name] ?? 0) === 0) {
                $out['missing'][] = $name;
                $out['missing_amount'] += (int)round($val / $prev['months'] * $cur['months']);
            }
        }
    }

    $out['has_issue'] = $out['lag_months'] > 0 || $out['missing'] || $out['unclassified'];
    return $out;
}

/** 入力の遅れ・費目欠落を伝える警告バナー。問題がなければ空文字を返す。 */
function input_health_banner(array $hl, bool $with_forecast_note = true): string {
    if (!$hl['has_issue']) return '';
    $lines = [];
    if (!empty($hl['no_data'])) {
        $lines[] = '当期の損益計算書が <strong>1件も投入されていません</strong>'
            . '（マネーフォワードから書き出して <code class="bg-white px-1 rounded">data/financial/&lt;年度&gt;/pl.csv</code> へ）';
    }
    if ($hl['lag_months'] > 0) {
        $lines[] = '会計の入力が <strong>' . $hl['lag_months'] . 'ヶ月 遅れ</strong>ています';
    }
    if ($hl['missing']) {
        $lines[] = '前年にあった主要費目 <strong>' . count($hl['missing']) . '件</strong>（'
            . h(implode('・', array_slice($hl['missing'], 0, 5)))
            . (count($hl['missing']) > 5 ? ' ほか' : '')
            . '）が今期ゼロ＝入力漏れの疑い（前年ペースなら約 <strong>' . jpy($hl['missing_amount'])
            . '</strong> 相当）';
    }
    if ($hl['unclassified']) {
        $lines[] = '未分類の勘定（' . h(implode('・', $hl['unclassified'])) . '）が <strong>'
            . jpy($hl['unclassified_amount']) . '</strong> 残っています';
    }

    $html = '<div class="border-2 border-red-500 bg-red-50 rounded-lg p-4 mb-6">'
        . '<p class="font-bold text-red-800 mb-2">⚠️ 下の数字は信用しないでください（経理の入力が済んでいません）</p>'
        . '<ul class="list-disc list-inside text-sm text-red-900 space-y-1">';
    foreach ($lines as $l) $html .= '<li>' . $l . '</li>';
    $html .= '</ul>';
    if ($with_forecast_note) {
        $html .= '<p class="text-sm text-red-900 mt-2">'
            . '費用が抜けたまま期中実績を12倍しているため、<strong>利益は実態より大きく出ます</strong>。'
            . 'マネーフォワードから最新CSVを書き出して <code class="bg-white px-1 rounded">data/financial/</code> に置くと解消します'
            . '（正しい見方は <code class="bg-white px-1 rounded">python3 bin/finance-snapshot.py</code>）。</p>';
    }
    return $html . '</div>';
}

function h(string $s): string { return htmlspecialchars($s, ENT_QUOTES, 'UTF-8'); }

function jpy(?int $v): string {
    if ($v === null) return '<span class="text-gray-300">—</span>';
    return '¥' . number_format($v);
}
