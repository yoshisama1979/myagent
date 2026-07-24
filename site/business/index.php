<?php
declare(strict_types=1);
require_once __DIR__ . '/_financial-lib.php';

$pl_25 = load_pl(2025);
$pl_26 = load_pl(2026);
$forecast_26 = forecast($pl_26);

const TOP_KPIS = [
    '売上高合計' => ['label' => '売上高', 'icon' => '💰', 'role' => 'revenue'],
    '営業利益' => ['label' => '営業利益', 'icon' => '📊', 'role' => 'op'],
    '経常利益' => ['label' => '経常利益', 'icon' => '📈', 'role' => 'recurring'],
];
?><!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ビジネスダッシュボード — 株式会社はなさか</title>
<script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-50 text-gray-900">
<div class="max-w-4xl mx-auto p-6 md:p-10">

  <nav class="text-sm text-gray-500 mb-4">
    <a href="../index.html" class="text-blue-600 hover:underline">← 株式会社はなさか</a>
  </nav>

  <h1 class="text-3xl font-bold mb-2">ビジネスダッシュボード</h1>
  <p class="text-gray-600 mb-6">経営方針・KPI・月次レビューの集約入口。「方針 → 行動 → 振り返り → 課題更新」の循環を回す。</p>

  <!-- ============================== 経営サマリー（常時表示） ============================== -->
  <div class="border-2 border-blue-400 bg-white rounded-lg p-5 mb-8 shadow-sm">
    <div class="flex flex-col md:flex-row md:items-baseline md:justify-between mb-3 gap-1">
      <h2 class="text-lg font-bold text-blue-800">📈 経営サマリー（FY2026予測 vs FY2025実績）</h2>
      <a href="annual-forecast.php" class="text-xs text-blue-600 hover:underline">→ 詳細を見る</a>
    </div>

    <?php if ($pl_26 === null && $pl_25 === null): ?>
      <p class="text-sm text-gray-500 py-2">財務データ未投入。<a href="annual-forecast.php" class="text-blue-600 hover:underline">年度通年予測</a> から MFクラウドCSV をアップロードしてください。</p>
    <?php else: ?>

      <!-- データ状態バッジ -->
      <div class="flex flex-wrap gap-2 mb-3 text-xs">
        <?php if ($pl_25 !== null): ?>
          <span class="bg-emerald-100 text-emerald-700 px-2 py-0.5 rounded">FY2025: 通年実績（<?= $pl_25['months'] ?>ヶ月）</span>
        <?php else: ?>
          <span class="bg-red-100 text-red-700 px-2 py-0.5 rounded">FY2025: 未投入</span>
        <?php endif; ?>
        <?php if ($pl_26 !== null): ?>
          <?php if ($pl_26['is_full_year']): ?>
            <span class="bg-emerald-100 text-emerald-700 px-2 py-0.5 rounded">FY2026: 通年実績</span>
          <?php else: ?>
            <span class="bg-amber-100 text-amber-700 px-2 py-0.5 rounded">FY2026: <?= $pl_26['months'] ?>ヶ月実績 → 通年予測</span>
          <?php endif; ?>
          <span class="text-gray-400">更新: <?= h(date('Y-m-d', $pl_26['file_mtime'])) ?></span>
        <?php else: ?>
          <span class="bg-red-100 text-red-700 px-2 py-0.5 rounded">FY2026: 未投入</span>
        <?php endif; ?>
      </div>

      <!-- KPI カード 3枚 -->
      <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
        <?php foreach (TOP_KPIS as $key => $cfg):
          $v25 = $pl_25['items'][$key] ?? null;
          $v26_fc = $forecast_26[$key] ?? null;
          $pct = diff_pct($v25, $v26_fc);
        ?>
        <div class="border border-gray-200 rounded p-3 bg-gray-50">
          <div class="text-xs text-gray-500 mb-1"><?= h($cfg['icon']) ?> <?= h($cfg['label']) ?></div>
          <div class="text-2xl font-bold mb-1"><?= jpy($v26_fc) ?></div>
          <div class="text-xs text-gray-500">FY2026 <?= ($pl_26 !== null && $pl_26['is_full_year']) ? '実績' : '通年予測' ?></div>
          <div class="mt-2 pt-2 border-t border-gray-300 text-xs text-gray-600">
            FY2025: <span class="font-semibold"><?= jpy($v25) ?></span>
          </div>
          <div class="mt-1">
            <?php if ($pct !== null): $j = judge($pct); ?>
              <span class="<?= $j['class'] ?> text-sm"><?= $j['icon'] ?> <?= sprintf('%+.1f%%', $pct) ?> <?= h($j['label']) ?></span>
            <?php else: ?>
              <span class="text-gray-400 text-xs">前年比 算出不可</span>
            <?php endif; ?>
          </div>
        </div>
        <?php endforeach; ?>
      </div>

    <?php endif; ?>
  </div>
  <!-- ============================== /経営サマリー ============================== -->

  <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mb-6">
    <a href="focus.html" class="block border-2 border-red-500 bg-red-50 rounded-lg p-5 hover:bg-red-100 transition">
      <h3 class="font-bold text-red-700 mb-1 text-lg">🎯 focus.html — フォーカスダッシュボード</h3>
      <p class="text-sm text-gray-700">今週/今月「やる」「やった」「決める」を強制的に絞り込む。毎日朝に開く。</p>
    </a>
    <a href="goals.html" class="block border-2 border-emerald-500 bg-emerald-50 rounded-lg p-5 hover:bg-emerald-100 transition">
      <h3 class="font-bold text-emerald-700 mb-1 text-lg">🌳 goals.html — 目標ツリー</h3>
      <p class="text-sm text-gray-700">経営目標→カテゴリ目標→サブ目標の樹形図。各ノードに数値目標。</p>
    </a>
    <a href="journey.html" class="block border-2 border-teal-500 bg-teal-50 rounded-lg p-5 hover:bg-teal-100 transition md:col-span-2">
      <h3 class="font-bold text-teal-700 mb-1 text-lg">🏔 journey.html — 歩みの記録</h3>
      <p class="text-sm text-gray-700">北極星に向かってどれだけ登ってきたかの振り返り。雛型誕生から50節目を before→after で。月初に経営パートナーが更新。</p>
    </a>
  </div>

  <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
    <a href="strategy.html" class="block border border-gray-300 rounded p-4 hover:bg-gray-100 transition">
      <h3 class="font-semibold text-blue-600 mb-1">経営方針</h3>
      <p class="text-sm text-gray-600">経営方針・重点課題・主要決定事項のログ（生きるドキュメント）</p>
    </a>
    <a href="kpi.html" class="block border border-gray-300 rounded p-4 hover:bg-gray-100 transition">
      <h3 class="font-semibold text-blue-600 mb-1">経営KPIダッシュボード</h3>
      <p class="text-sm text-gray-600">経営ダッシュボード理想形（7カテゴリのKPI定義＋整備ロードマップ）</p>
    </a>
    <a href="reviews/index.html" class="block border border-gray-300 rounded p-4 hover:bg-gray-100 transition">
      <h3 class="font-semibold text-blue-600 mb-1">月次・年次レビュー</h3>
      <p class="text-sm text-gray-600">月次レビューの記録一覧（FY2025決算振り返り含む）</p>
    </a>
    <a href="recurring-revenue.html" class="block border-2 border-emerald-400 bg-emerald-50 rounded p-4 hover:bg-emerald-100 transition">
      <h3 class="font-semibold text-emerald-700 mb-1">💰 月次ストック収益</h3>
      <p class="text-sm text-gray-700">月額契約の見える化（G0.2 達成のための基盤）</p>
    </a>
    <a href="projects-overview.php" class="block border-2 border-amber-400 bg-amber-50 rounded p-4 hover:bg-amber-100 transition">
      <h3 class="font-semibold text-amber-700 mb-1">📋 案件 状態別 & 月次見積額</h3>
      <p class="text-sm text-gray-700">請求漏れ・支払い漏れ・失注の把握（Sheetsからリアルタイム取得・60秒キャッシュ）</p>
    </a>
    <a href="annual-forecast.php" class="block border-2 border-blue-400 bg-blue-50 rounded p-4 hover:bg-blue-100 transition">
      <h3 class="font-semibold text-blue-700 mb-1">📈 年度通年予測（FY2025 vs FY2026）</h3>
      <p class="text-sm text-gray-700">MFクラウドPL CSV を投入 → 期中実績から通年を按分予測 → 前年比較で経営判定</p>
    </a>
    <a href="journal-check.php" class="block border-2 border-purple-400 bg-purple-50 rounded p-4 hover:bg-purple-100 transition">
      <h3 class="font-semibold text-purple-700 mb-1">📒 仕訳チェック（経理サポート）</h3>
      <p class="text-sm text-gray-700">MFクラウド仕訳帳CSVを月単位で投入 → 形式チェック・集計・異常検知（v1：アップロード機能のみ）</p>
    </a>
    <a href="monthly-status.php" class="block border border-gray-300 rounded p-4 hover:bg-gray-100 transition opacity-70">
      <h3 class="font-semibold text-gray-600 mb-1">📊 月次データ（将来用・未運用）</h3>
      <p class="text-sm text-gray-500">月次CSV投入の枠組み。将来「月単位で比較したい」となった時に使う</p>
    </a>
    <a href="internal-meetings/index.html" class="block border border-gray-300 rounded p-4 hover:bg-gray-100 transition">
      <h3 class="font-semibold text-blue-600 mb-1">社内会議</h3>
      <p class="text-sm text-gray-600">社内定例会議の議題・議事録</p>
    </a>
    <a href="doyukai-keikyo.html" class="block border border-gray-300 rounded p-4 hover:bg-gray-100 transition">
      <h3 class="font-semibold text-blue-600 mb-1">同友会 景況調査 回答控え</h3>
      <p class="text-sm text-gray-600">四半期ごとの景況調査の設問と回答メモ（固定回答を流用して入力を時短）</p>
    </a>
    <a href="skill-sheet/index.html" class="block border border-gray-300 rounded p-4 hover:bg-gray-100 transition">
      <h3 class="font-semibold text-blue-600 mb-1">skill-sheet/</h3>
      <p class="text-sm text-gray-600">社員教育・人事評価のスキル定義集（PC操作スキル他）</p>
    </a>
  </div>

  <h2 class="text-xl font-semibold border-b border-gray-300 pb-2 mb-4 mt-10">運用ルール</h2>
  <p class="text-sm">協働の進め方は <a href="../rules/partnership.md" class="text-blue-600 hover:underline font-mono">rules/partnership.md</a> 参照。</p>

  <h2 class="text-xl font-semibold border-b border-gray-300 pb-2 mb-4 mt-10">関連</h2>
  <ul class="list-disc list-inside space-y-1 text-sm">
    <li><a href="../notes.html" class="text-blue-600 hover:underline">日常メモ</a> — 横断的な気づき</li>
    <li><a href="../clients/index.html" class="text-blue-600 hover:underline">クライアント一覧</a> — クライアント・プロジェクト一覧</li>
  </ul>

</div>
</body>
</html>
