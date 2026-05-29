<?php
declare(strict_types=1);
date_default_timezone_set('Asia/Tokyo');

const PROJECT_ROOT = '/home/vpsuser/projects/myagent';
const FINANCIAL_ROOT = PROJECT_ROOT . '/data/financial';
const MAX_FILE_SIZE = 2 * 1024 * 1024;

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

function fy_months_list(int $fy): array {
    $months = [];
    for ($i = 0; $i < 12; $i++) {
        $m = 4 + $i;
        $y = $fy + intdiv($m - 1, 12);
        $mm = (($m - 1) % 12) + 1;
        $months[] = sprintf('%04d-%02d', $y, $mm);
    }
    return $months;
}

function load_period_meta(int $fy): ?array {
    $file = fy_dir($fy) . '/period.json';
    if (!is_file($file)) return null;
    $data = json_decode((string)file_get_contents($file), true);
    if (!is_array($data) || !isset($data['end_ym'])) return null;
    if (!preg_match('/^\d{4}-\d{2}$/', (string)$data['end_ym'])) return null;
    return $data;
}

function handle_upload(): array {
    $fy = (int)($_POST['fy'] ?? 0);
    if ($fy < 2020 || $fy > 2100) return ['type' => 'error', 'text' => '年度が不正です'];

    $end_ym = trim((string)($_POST['end_ym'] ?? ''));
    if ($end_ym !== '' && !preg_match('/^\d{4}-\d{2}$/', $end_ym)) {
        return ['type' => 'error', 'text' => 'データ最終月の形式が不正です'];
    }
    if ($end_ym !== '' && !in_array($end_ym, fy_months_list($fy), true)) {
        return ['type' => 'error', 'text' => "データ最終月（{$end_ym}）が FY{$fy} の範囲外です"];
    }

    $results = [];
    foreach (['pl_csv' => 'pl.csv', 'bs_csv' => 'bs.csv'] as $field => $name) {
        if (!isset($_FILES[$field]) || $_FILES[$field]['error'] === UPLOAD_ERR_NO_FILE) continue;
        $f = $_FILES[$field];
        if ($f['error'] !== UPLOAD_ERR_OK) {
            $results[] = "❌ {$name}: アップロードエラー (code: {$f['error']})";
            continue;
        }
        if ($f['size'] > MAX_FILE_SIZE) {
            $results[] = "❌ {$name}: ファイルサイズが2MBを超えています";
            continue;
        }
        $dir = fy_dir($fy);
        if (!is_dir($dir)) mkdir($dir, 0755, true);
        if (move_uploaded_file($f['tmp_name'], $dir . '/' . $name)) {
            $results[] = "✅ FY{$fy} {$name} を保存しました（" . number_format($f['size']) . "バイト）";
        } else {
            $results[] = "❌ {$name}: 保存に失敗しました";
        }
    }

    if ($end_ym !== '') {
        $dir = fy_dir($fy);
        if (!is_dir($dir)) mkdir($dir, 0755, true);
        file_put_contents($dir . '/period.json', json_encode([
            'end_ym' => $end_ym,
            'uploaded_at' => date('Y-m-d H:i:s'),
        ], JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
        $results[] = "📅 データ最終月：{$end_ym} を記録";
    }

    if (!$results) return ['type' => 'error', 'text' => 'ファイルが選択されていません'];
    $type = strpos(implode(' ', $results), '❌') !== false ? 'mixed' : 'success';
    return ['type' => $type, 'text' => implode(' / ', $results)];
}

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

        // 見出し行（1要素のみ、データ列なし）：state 更新のみ
        if (count($row) < 4) {
            if ($top === '販売費及び一般管理費') $in_sga = true;
            continue;
        }

        // データ行は count>=7 が必要
        if (count($row) < 7) continue;
        $balance = (int)str_replace([',', '"'], '', (string)$row[6]);

        // 補助科目行（sub に値あり）→ 親に集約済みなのでスキップ
        if ($sub !== '') continue;

        // 合計・小計行（top に値、name 空）
        if ($top !== '' && $name === '') {
            $items[$top] = $balance;
            // SGA セクションの終端：販管費合計 or 営業利益で抜ける
            if ($top === '販売費及び一般管理費合計' || $top === '営業利益') $in_sga = false;
            continue;
        }

        // 子科目行（top 空、name に値）
        if ($top === '' && $name !== '') {
            $items[$name] = $balance;
            if ($in_sga) $major_expenses[$name] = $balance;
        }
    }

    $start_y = (int)substr($start_date, 0, 4);
    $start_m = (int)substr($start_date, 5, 2);
    $end_y = (int)substr($end_date, 0, 4);
    $end_m = (int)substr($end_date, 5, 2);
    $months_from_header = ($end_y - $start_y) * 12 + ($end_m - $start_m) + 1;

    $period_meta = load_period_meta($fy);
    $months = $months_from_header;
    $end_display = $end_date;
    $period_source = 'header';
    if ($period_meta !== null) {
        $end_ym = (string)$period_meta['end_ym'];
        $em_y = (int)substr($end_ym, 0, 4);
        $em_m = (int)substr($end_ym, 5, 2);
        $months = ($em_y - $fy) * 12 + ($em_m - 4) + 1;
        $end_display = $end_ym . '（指定）';
        $period_source = 'manual';
    }

    return [
        'fy' => $fy,
        'start' => $start_date,
        'end' => $end_display,
        'months' => $months,
        'months_from_header' => $months_from_header,
        'period_source' => $period_source,
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

$message = null;
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $message = handle_upload();
}

$pl_by_fy = [];
foreach (TARGET_FYS as $fy) {
    $pl_by_fy[$fy] = load_pl($fy);
}

$pl_25 = $pl_by_fy[2025];
$pl_26 = $pl_by_fy[2026];
$forecast_26 = forecast($pl_26);

function h(string $s): string { return htmlspecialchars($s, ENT_QUOTES, 'UTF-8'); }
function jpy(?int $v): string {
    if ($v === null) return '<span class="text-gray-300">—</span>';
    return '¥' . number_format($v);
}
?><!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>年度通年予測 — 株式会社はなさか</title>
<script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-50 text-gray-900">
<div class="max-w-6xl mx-auto p-6 md:p-10">

  <nav class="text-sm text-gray-500 mb-4">
    <a href="../index.html" class="text-blue-600 hover:underline">← 株式会社はなさか</a> &gt;
    <a href="index.html" class="text-blue-600 hover:underline">ビジネスダッシュボード</a>
  </nav>

  <h1 class="text-3xl font-bold mb-2">📈 年度通年予測</h1>
  <p class="text-gray-600 mb-6 text-sm">
    今期（FY2026）の途中までの実績から通年を単純按分予測し、前年（FY2025）と比較。<br>
    データソース：MFクラウド「損益計算書 PL」CSV（期間指定でエクスポート）
  </p>

  <?php if ($message): ?>
    <?php $bg = $message['type'] === 'success' ? 'bg-emerald-50 border-emerald-400 text-emerald-800' : ($message['type'] === 'mixed' ? 'bg-amber-50 border-amber-400 text-amber-800' : 'bg-red-50 border-red-400 text-red-800'); ?>
    <div class="border-l-4 rounded p-3 mb-6 text-sm <?= $bg ?>"><?= h($message['text']) ?></div>
  <?php endif; ?>

  <!-- アップロード -->
  <details class="mb-8 bg-white border border-gray-300 rounded-lg" <?= ($pl_25 === null || $pl_26 === null) ? 'open' : '' ?>>
    <summary class="cursor-pointer p-4 font-semibold text-blue-700 hover:bg-blue-50">📤 MFクラウドCSVをアップロード</summary>
    <div class="p-4 border-t border-gray-200">
      <?php
        $today = date('Y-m');
        $last_month = date('Y-m', strtotime('first day of last month'));
        $all_ym_options = array_merge(fy_months_list(2025), fy_months_list(2026));
        $default_end_ym = in_array($last_month, $all_ym_options, true) ? $last_month : $today;
      ?>
      <form method="POST" enctype="multipart/form-data" class="space-y-3">
        <div class="flex gap-4 items-center">
          <label class="font-semibold text-sm">対象年度：</label>
          <?php foreach (TARGET_FYS as $fy): ?>
            <label class="inline-flex items-center gap-1">
              <input type="radio" name="fy" value="<?= $fy ?>" <?= $fy === 2026 ? 'checked' : '' ?> required>
              <span>FY<?= $fy ?></span>
            </label>
          <?php endforeach; ?>
        </div>
        <div>
          <label class="block text-sm font-semibold mb-1">PL CSV（必須）</label>
          <input type="file" name="pl_csv" accept=".csv,text/csv"
                 class="text-sm file:mr-3 file:py-1.5 file:px-3 file:rounded file:border-0 file:bg-blue-600 file:text-white file:font-semibold">
        </div>
        <div>
          <label class="block text-sm font-semibold mb-1">BS CSV（任意）</label>
          <input type="file" name="bs_csv" accept=".csv,text/csv"
                 class="text-sm file:mr-3 file:py-1.5 file:px-3 file:rounded file:border-0 file:bg-gray-600 file:text-white file:font-semibold">
        </div>
        <div>
          <label class="block text-sm font-semibold mb-1">📅 データの最終月 <span class="text-red-600">*</span></label>
          <select name="end_ym" required class="border border-gray-300 rounded px-2 py-1.5 text-sm">
            <option value="">-- 選択してください --</option>
            <optgroup label="FY2025">
              <?php foreach (fy_months_list(2025) as $ym): ?>
                <option value="<?= h($ym) ?>" <?= $ym === '2026-03' ? 'selected' : '' ?>><?= h($ym) ?></option>
              <?php endforeach; ?>
            </optgroup>
            <optgroup label="FY2026">
              <?php foreach (fy_months_list(2026) as $ym): if ($ym > $today) break; ?>
                <option value="<?= h($ym) ?>" <?= $ym === $default_end_ym ? 'selected' : '' ?>><?= h($ym) ?></option>
              <?php endforeach; ?>
            </optgroup>
          </select>
          <p class="text-xs text-gray-600 mt-1">
            CSVに含まれている <strong>実績の最終月</strong>。例：4月末締めの数字をアップロードするなら「2026-04」を選択。<br>
            通年予測は「FY開始月〜この月までの実績」を「経過月数」で按分して計算します。
          </p>
        </div>
        <button type="submit" class="bg-blue-600 hover:bg-blue-700 text-white font-bold py-2 px-5 rounded">
          アップロード
        </button>
        <p class="text-xs text-gray-500">保存先：<code>data/financial/{年度}/pl.csv</code> ＋ <code>period.json</code>（gitignored）</p>
        <p class="text-xs text-gray-600">
          MFクラウド → レポート → 損益計算書 → <strong>期間を指定</strong>（例：FY2026は 2026-04-01〜現在月末）→ CSV出力 → ここにアップロード
        </p>
      </form>
    </div>
  </details>

  <!-- データ状況 -->
  <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mb-6">
    <?php foreach (TARGET_FYS as $fy): ?>
      <?php $pl = $pl_by_fy[$fy]; ?>
      <div class="border rounded p-4 <?= $pl === null ? 'border-red-300 bg-red-50' : ($pl['is_full_year'] ? 'border-emerald-300 bg-emerald-50' : 'border-amber-300 bg-amber-50') ?>">
        <div class="flex justify-between items-center mb-1">
          <strong class="text-base">FY<?= $fy ?> データ</strong>
          <span class="text-xl">
            <?php if ($pl === null) echo '❌'; elseif ($pl['is_full_year']) echo '✅ 通年'; else echo '⏳ 進行中'; ?>
          </span>
        </div>
        <?php if ($pl !== null): ?>
          <p class="text-sm text-gray-700">
            期間：<?= h($pl['start']) ?> 〜 <?= h($pl['end']) ?>（<strong><?= $pl['months'] ?>ヶ月分</strong>）<br>
            <span class="text-xs text-gray-500">最終更新：<?= h(date('Y-m-d H:i', $pl['file_mtime'])) ?></span>
            <?php if ($pl['period_source'] === 'manual'): ?>
              <span class="inline-block ml-2 px-1.5 py-0.5 bg-blue-100 text-blue-700 rounded text-xs">📅 期間指定済み</span>
            <?php elseif (!$pl['is_full_year'] && $pl['months_from_header'] < 12): ?>
              <span class="inline-block ml-2 px-1.5 py-0.5 bg-gray-100 text-gray-700 rounded text-xs">CSVヘッダーから自動判定</span>
            <?php endif; ?>
          </p>
          <?php if ($pl['period_source'] === 'header' && $pl['is_full_year'] && $fy >= 2026 && $pl['end'] > date('Y-m-d')): ?>
            <p class="text-xs text-red-700 mt-2 font-semibold">
              ⚠️ CSVヘッダーが会計期間全体になっており、按分計算が効いていません。<br>
              上のフォームから「📅 データの最終月」を指定して再送信してください（ファイル添付は不要）。
            </p>
          <?php endif; ?>
        <?php else: ?>
          <p class="text-sm text-red-700">未投入。上のフォームから FY<?= $fy ?> の PL CSV をアップロードしてください</p>
        <?php endif; ?>
      </div>
    <?php endforeach; ?>
  </div>

  <?php if ($pl_25 === null && $pl_26 === null): ?>
    <div class="bg-gray-100 border border-gray-300 rounded p-6 text-center text-gray-600">
      データを投入すると、ここに通年予測と比較が表示されます。
    </div>
  <?php else: ?>

    <!-- 進捗ゲージ -->
    <?php if ($pl_26 !== null && !$pl_26['is_full_year']): ?>
      <div class="bg-amber-50 border-2 border-amber-400 rounded-lg p-5 mb-6">
        <div class="flex justify-between items-center mb-2">
          <strong class="text-amber-800">FY2026 期中進捗</strong>
          <span class="text-sm text-amber-700"><?= $pl_26['months'] ?>ヶ月 / 12ヶ月 経過（<?= round($pl_26['months']/12*100) ?>%）</span>
        </div>
        <div class="w-full bg-white rounded-full h-4 border border-amber-300">
          <div class="bg-amber-400 h-full rounded-full" style="width: <?= round($pl_26['months']/12*100) ?>%"></div>
        </div>
        <p class="text-xs text-amber-700 mt-2">下表「通年予測」列は <strong>実績 × 12 ÷ <?= $pl_26['months'] ?>ヶ月</strong> による単純按分。季節性は加味していない。</p>
      </div>
    <?php endif; ?>

    <!-- 主要KPI比較 -->
    <h2 class="text-xl font-bold mb-3">📊 主要KPI（FY2025 vs FY2026予測）</h2>
    <div class="overflow-x-auto border border-gray-300 rounded mb-8">
      <table class="w-full text-sm bg-white">
        <thead class="bg-gray-100">
          <tr>
            <th class="px-3 py-2 text-left">項目</th>
            <th class="px-3 py-2 text-right">FY2025 通年実績</th>
            <th class="px-3 py-2 text-right">FY2026 期中実績<br><span class="text-xs text-gray-500"><?= $pl_26 !== null ? '('.$pl_26['months'].'ヶ月)' : '' ?></span></th>
            <th class="px-3 py-2 text-right">FY2026 通年予測</th>
            <th class="px-3 py-2 text-center">前年比</th>
            <th class="px-3 py-2 text-center">判定</th>
          </tr>
        </thead>
        <tbody>
          <?php foreach (SUMMARY_KEYS as $key => $cfg):
            $v25 = $pl_25['items'][$key] ?? null;
            $v26_ytd = $pl_26['items'][$key] ?? null;
            $v26_fc = $forecast_26[$key] ?? null;
            $pct = diff_pct($v25, $v26_fc);
            $is_expense = ($cfg['role'] ?? '') === 'sga';
            $big = !empty($cfg['big']);
          ?>
          <tr class="border-t border-gray-200 <?= $big ? 'bg-blue-50' : '' ?>">
            <td class="px-3 py-2 <?= $big ? 'font-bold' : '' ?>"><?= h($cfg['label']) ?></td>
            <td class="px-3 py-2 text-right"><?= jpy($v25) ?></td>
            <td class="px-3 py-2 text-right text-gray-600"><?= jpy($v26_ytd) ?></td>
            <td class="px-3 py-2 text-right font-semibold <?= $big ? 'text-lg' : '' ?>"><?= jpy($v26_fc) ?></td>
            <td class="px-3 py-2 text-right">
              <?php if ($pct !== null): ?>
                <span class="<?= $pct >= 0 ? 'text-emerald-700' : 'text-red-700' ?>"><?= sprintf('%+.1f%%', $pct) ?></span>
              <?php else: ?><span class="text-gray-300">—</span><?php endif; ?>
            </td>
            <td class="px-3 py-2 text-center">
              <?php if ($pct !== null): $j = judge($pct, $is_expense); ?>
                <span class="<?= $j['class'] ?>"><?= $j['icon'] ?> <?= h($j['label']) ?></span>
              <?php else: ?><span class="text-gray-300">—</span><?php endif; ?>
            </td>
          </tr>
          <?php endforeach; ?>
        </tbody>
      </table>
    </div>

    <!-- 主要販管費 -->
    <?php
    $sga_keys = [];
    if ($pl_25 && isset($pl_25['major_expenses'])) $sga_keys = array_keys($pl_25['major_expenses']);
    if ($pl_26 && isset($pl_26['major_expenses'])) $sga_keys = array_merge($sga_keys, array_keys($pl_26['major_expenses']));
    $sga_keys = array_unique($sga_keys);
    $sga_data = [];
    foreach ($sga_keys as $k) {
        $v25 = $pl_25['items'][$k] ?? null;
        $v26_fc = $forecast_26[$k] ?? null;
        $sga_data[$k] = ['v25' => $v25, 'v26_fc' => $v26_fc, 'max' => max((int)$v25, (int)$v26_fc)];
    }
    uasort($sga_data, fn($a, $b) => $b['max'] - $a['max']);
    $sga_data = array_slice($sga_data, 0, 15, true);
    ?>
    <h2 class="text-xl font-bold mb-3">💸 主要販管費（上位15・通年予測ベース）</h2>
    <div class="overflow-x-auto border border-gray-300 rounded mb-8">
      <table class="w-full text-sm bg-white">
        <thead class="bg-gray-100">
          <tr>
            <th class="px-3 py-2 text-left">勘定科目</th>
            <th class="px-3 py-2 text-right">FY2025 実績</th>
            <th class="px-3 py-2 text-right">FY2026 期中</th>
            <th class="px-3 py-2 text-right">FY2026 通年予測</th>
            <th class="px-3 py-2 text-center">前年比</th>
            <th class="px-3 py-2 text-center">判定</th>
          </tr>
        </thead>
        <tbody>
          <?php foreach ($sga_data as $k => $d):
            $v26_ytd = $pl_26['items'][$k] ?? null;
            $pct = diff_pct($d['v25'], $d['v26_fc']);
          ?>
          <tr class="border-t border-gray-200">
            <td class="px-3 py-2"><?= h($k) ?></td>
            <td class="px-3 py-2 text-right"><?= jpy($d['v25']) ?></td>
            <td class="px-3 py-2 text-right text-gray-600"><?= jpy($v26_ytd) ?></td>
            <td class="px-3 py-2 text-right font-semibold"><?= jpy($d['v26_fc']) ?></td>
            <td class="px-3 py-2 text-right">
              <?php if ($pct !== null): ?>
                <span class="<?= $pct <= 0 ? 'text-emerald-700' : 'text-red-700' ?>"><?= sprintf('%+.1f%%', $pct) ?></span>
              <?php else: ?><span class="text-gray-300">—</span><?php endif; ?>
            </td>
            <td class="px-3 py-2 text-center">
              <?php if ($pct !== null): $j = judge($pct, true); ?>
                <span class="<?= $j['class'] ?>"><?= $j['icon'] ?> <?= h($j['label']) ?></span>
              <?php else: ?><span class="text-gray-300">—</span><?php endif; ?>
            </td>
          </tr>
          <?php endforeach; ?>
        </tbody>
      </table>
    </div>

  <?php endif; ?>

  <div class="bg-gray-100 border border-gray-300 rounded p-4 text-xs text-gray-600">
    <strong>判定基準</strong>
    <ul class="list-disc list-inside mt-1 space-y-0.5">
      <li><strong>売上系</strong>：前年比 +5%以上 = 🟢順調 / ±5%以内 = 🟡ほぼ同等 / -5%以下 = 🔴未達ペース</li>
      <li><strong>経費系</strong>：前年比 -5%以下 = 🟢改善 / ±5%以内 = 🟡ほぼ同等 / +5%以上 = 🔴増加</li>
      <li>あくまで単純按分予測。季節要因（広告繁忙期・冬季賞与等）は反映していない</li>
    </ul>
  </div>

</div>
</body>
</html>
