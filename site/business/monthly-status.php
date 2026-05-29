<?php
declare(strict_types=1);
date_default_timezone_set('Asia/Tokyo');

const PROJECT_ROOT = '/home/vpsuser/projects/myagent';
const DATA_ROOT = PROJECT_ROOT . '/data/monthly';

const CATEGORIES = [
    'revenue' => [
        'label' => '売上系',
        'icon' => '💰',
        'color' => 'emerald',
        'columns' => ['売上', '新規受注金額', 'ストック収益'],
    ],
    'cost' => [
        'label' => 'コスト系',
        'icon' => '💸',
        'color' => 'rose',
        'columns' => ['外注費', '広告費', 'その他経費'],
    ],
];

const FISCAL_YEARS = [
    ['fy' => 2025, 'label' => 'FY2025（前年度）', 'start_year' => 2025],
    ['fy' => 2026, 'label' => 'FY2026（今期）', 'start_year' => 2026, 'highlight' => true],
];

function fiscal_year_months(int $start_year): array {
    $months = [];
    for ($i = 0; $i < 12; $i++) {
        $m = 4 + $i;
        $y = $start_year + intdiv($m - 1, 12);
        $mm = (($m - 1) % 12) + 1;
        $months[] = sprintf('%04d-%02d', $y, $mm);
    }
    return $months;
}

function load_record(string $category, string $ym): ?array {
    $file = DATA_ROOT . '/' . $category . '/' . $ym . '.json';
    if (!is_file($file)) return null;
    $data = json_decode((string)file_get_contents($file), true);
    return is_array($data) ? $data : null;
}

function current_ym(): string {
    return date('Y-m');
}

function format_money(float $v): string {
    return number_format((int)round($v));
}

$current = current_ym();

$fy_data = [];
foreach (FISCAL_YEARS as $fy) {
    $months = fiscal_year_months($fy['start_year']);
    $rows = [];
    foreach ($months as $ym) {
        $row = ['ym' => $ym, 'is_current' => $ym === $current, 'is_future' => $ym > $current];
        foreach (array_keys(CATEGORIES) as $cat) {
            $row[$cat] = load_record($cat, $ym);
        }
        $rows[] = $row;
    }
    $fy_data[] = ['meta' => $fy, 'rows' => $rows];
}

$current_status = [];
foreach (CATEGORIES as $cat => $meta) {
    $current_status[$cat] = load_record($cat, $current);
}

function h(string $s): string { return htmlspecialchars($s, ENT_QUOTES, 'UTF-8'); }
?><!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>月次データ アップロード状況 — 株式会社はなさか</title>
<script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-50 text-gray-900">
<div class="max-w-6xl mx-auto p-6 md:p-10">

  <nav class="text-sm text-gray-500 mb-4">
    <a href="../index.html" class="text-blue-600 hover:underline">← 株式会社はなさか</a> &gt;
    <a href="index.html" class="text-blue-600 hover:underline">ビジネスダッシュボード</a>
  </nav>

  <div class="flex flex-col md:flex-row md:items-center md:justify-between mb-6 gap-3">
    <div>
      <h1 class="text-3xl font-bold mb-1">月次データ アップロード状況</h1>
      <p class="text-gray-600 text-sm">2025年度（前年）/ 2026年度（今期）の月次データ整備状況</p>
    </div>
    <a href="monthly-upload.php"
       class="whitespace-nowrap bg-blue-600 hover:bg-blue-700 text-white font-bold py-2 px-4 rounded shadow text-center">
      📤 CSVをアップロード
    </a>
  </div>

  <!-- 今月の状況（大きく強調） -->
  <div class="border-2 border-amber-400 bg-amber-50 rounded-lg p-5 mb-8">
    <h2 class="text-lg font-bold text-amber-800 mb-3">📅 今月（<?= h($current) ?>）のアップロード状況</h2>
    <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
      <?php foreach (CATEGORIES as $cat => $meta): ?>
        <?php $rec = $current_status[$cat]; $ok = $rec !== null; ?>
        <div class="border rounded p-4 <?= $ok ? 'border-emerald-400 bg-emerald-50' : 'border-red-400 bg-red-50' ?>">
          <div class="flex items-center justify-between mb-2">
            <strong class="text-base"><?= h($meta['icon']) ?> <?= h($meta['label']) ?></strong>
            <span class="text-2xl"><?= $ok ? '✅' : '❌' ?></span>
          </div>
          <?php if ($ok): ?>
            <p class="text-xs text-gray-600">
              アップロード済み<br>
              <span class="text-gray-500">（<?= h((string)($rec['uploaded_at'] ?? '')) ?>）</span>
            </p>
            <ul class="text-xs text-gray-700 mt-2 space-y-0.5">
              <?php foreach ($meta['columns'] as $col): ?>
                <li><?= h($col) ?>：<strong>¥<?= format_money((float)($rec['data'][$col] ?? 0)) ?></strong></li>
              <?php endforeach; ?>
            </ul>
          <?php else: ?>
            <p class="text-sm text-red-700 font-semibold">未アップロード</p>
            <p class="text-xs text-gray-600 mt-1"><?= h($current) ?> のデータを投入してください</p>
          <?php endif; ?>
        </div>
      <?php endforeach; ?>
    </div>
  </div>

  <!-- 年度別マトリクス -->
  <?php foreach ($fy_data as $fy): ?>
    <?php $is_current_fy = !empty($fy['meta']['highlight']); ?>
    <div class="mb-8">
      <h2 class="text-xl font-bold mb-3 <?= $is_current_fy ? 'text-emerald-700' : 'text-gray-700' ?>">
        <?= h($fy['meta']['label']) ?>
      </h2>
      <div class="overflow-x-auto border border-gray-300 rounded bg-white">
        <table class="w-full text-sm">
          <thead class="bg-gray-100">
            <tr>
              <th class="px-3 py-2 text-left">年月</th>
              <?php foreach (CATEGORIES as $cat => $meta): ?>
                <th class="px-3 py-2 text-center"><?= h($meta['icon']) ?> <?= h($meta['label']) ?></th>
              <?php endforeach; ?>
              <th class="px-3 py-2 text-center">状態</th>
            </tr>
          </thead>
          <tbody>
            <?php foreach ($fy['rows'] as $row): ?>
              <?php
                $tr_class = '';
                if ($row['is_current']) $tr_class = 'bg-amber-50 font-semibold';
                elseif ($row['is_future']) $tr_class = 'bg-gray-50 text-gray-400';
                $total = 0; $missing = 0;
                foreach (CATEGORIES as $cat => $_) {
                  if ($row[$cat] !== null) $total++; else $missing++;
                }
                $all_ok = $missing === 0;
                $any = $total > 0;
              ?>
              <tr class="border-t border-gray-200 <?= $tr_class ?>">
                <td class="px-3 py-2">
                  <?= h($row['ym']) ?>
                  <?php if ($row['is_current']): ?><span class="text-xs text-amber-700 ml-1">（今月）</span><?php endif; ?>
                  <?php if ($row['is_future']): ?><span class="text-xs text-gray-400 ml-1">（未来）</span><?php endif; ?>
                </td>
                <?php foreach (CATEGORIES as $cat => $meta): ?>
                  <?php $rec = $row[$cat]; ?>
                  <td class="px-3 py-2 text-center">
                    <?php if ($rec !== null): ?>
                      <span class="text-emerald-600 text-lg" title="<?= h((string)($rec['uploaded_at'] ?? '')) ?>">✅</span>
                    <?php elseif ($row['is_future']): ?>
                      <span class="text-gray-300">—</span>
                    <?php else: ?>
                      <span class="text-red-500 text-lg">❌</span>
                    <?php endif; ?>
                  </td>
                <?php endforeach; ?>
                <td class="px-3 py-2 text-center text-xs">
                  <?php if ($row['is_future']): ?>
                    <span class="text-gray-400">—</span>
                  <?php elseif ($all_ok): ?>
                    <span class="text-emerald-700 font-semibold">完了</span>
                  <?php elseif ($any): ?>
                    <span class="text-amber-700 font-semibold">一部のみ</span>
                  <?php else: ?>
                    <span class="text-red-700 font-semibold">未投入</span>
                  <?php endif; ?>
                </td>
              </tr>
            <?php endforeach; ?>
          </tbody>
        </table>
      </div>
    </div>
  <?php endforeach; ?>

  <div class="bg-gray-100 border border-gray-300 rounded p-4 text-xs text-gray-600">
    <strong>運用ルール</strong>
    <ul class="list-disc list-inside mt-1 space-y-0.5">
      <li>毎月初に前月分をアップロード（売上・コスト各1ファイル）</li>
      <li>FY2025（前年）データも順次投入 → 前年同月比較が可能になる</li>
      <li>同じ年月を再アップロードすると上書き保存</li>
      <li>保存先：<code>data/monthly/{revenue|cost}/YYYY-MM.json</code>（gitignored）</li>
    </ul>
  </div>

</div>
</body>
</html>
