<?php
declare(strict_types=1);
require_once __DIR__ . '/_financial-lib.php';

const MAX_FILE_SIZE = 2 * 1024 * 1024;

function handle_upload(): array {
    $fy = (int)($_POST['fy'] ?? 0);
    if ($fy < 2020 || $fy > 2100) return ['type' => 'error', 'text' => '年度が不正です'];

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

    if (!$results) return ['type' => 'error', 'text' => 'ファイルが選択されていません'];
    $type = strpos(implode(' ', $results), '❌') !== false ? 'mixed' : 'success';
    return ['type' => $type, 'text' => implode(' / ', $results)];
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
        <button type="submit" class="bg-blue-600 hover:bg-blue-700 text-white font-bold py-2 px-5 rounded">
          アップロード
        </button>
        <p class="text-xs text-gray-500">保存先：<code>data/financial/{年度}/pl.csv</code>（gitignored）</p>
        <div class="text-xs text-gray-700 bg-gray-50 border border-gray-200 rounded p-2 mt-2">
          <strong>📥 MFクラウドでの取得手順</strong><br>
          会計帳簿 → <strong>残高試算表</strong> → 期間を指定（例：FY2026 4月末締めなら <code>2026-04-01〜2026-04-30</code>）→ エクスポート → ここにアップロード<br>
          <span class="text-gray-500">経過月数は CSV ヘッダーの「開始月／終了月」から自動判定します。</span>
        </div>
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
          </p>
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
