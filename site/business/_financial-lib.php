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

function h(string $s): string { return htmlspecialchars($s, ENT_QUOTES, 'UTF-8'); }

function jpy(?int $v): string {
    if ($v === null) return '<span class="text-gray-300">—</span>';
    return '¥' . number_format($v);
}
