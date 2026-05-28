<?php
declare(strict_types=1);

const PROJECT_ROOT = '/home/vpsuser/projects/myagent';
const CACHE_FILE = PROJECT_ROOT . '/data/cache/projects-overview.json';
const CACHE_TTL = 60;

function fetch_data(): array {
    $cache_age = is_file(CACHE_FILE) ? (time() - filemtime(CACHE_FILE)) : PHP_INT_MAX;
    $force = isset($_GET['refresh']);

    if (!$force && $cache_age < CACHE_TTL) {
        $json = (string)file_get_contents(CACHE_FILE);
        $data = json_decode($json, true);
        if (is_array($data)) {
            return [$data, 'cache', $cache_age];
        }
    }

    $cmd = 'cd ' . escapeshellarg(PROJECT_ROOT) . ' && python3 bin/projects-overview-data.py 2>&1';
    $output = (string)shell_exec($cmd);
    $data = json_decode($output, true);

    if (!is_array($data)) {
        if (is_file(CACHE_FILE)) {
            $stale = json_decode((string)file_get_contents(CACHE_FILE), true);
            if (is_array($stale)) {
                return [$stale, 'stale', $cache_age, $output];
            }
        }
        return [null, 'error', null, $output];
    }

    file_put_contents(CACHE_FILE, $output);
    return [$data, 'fresh', 0];
}

[$data, $source, $age, $err] = array_pad(fetch_data(), 4, null);

if ($data === null) {
    http_response_code(500);
    echo '<pre>データ取得エラー: ' . htmlspecialchars((string)$err) . '</pre>';
    exit;
}

$total = (int)$data['total_count'];
$state_data = $data['state_data'];
$months = $data['months'];
$series = $data['series'];
$details = $data['details'] ?? [];
$quality = $data['quality'] ?? [];
$thresholds = $data['quality_thresholds'] ?? ['bill_overdue_days' => 30, 'pay_overdue_days' => 60];
$fetched_at = $data['fetched_at'];

$quality_critical = [
    'billing_overdue'    => ['label' => "請求待ち & 完了から{$thresholds['bill_overdue_days']}日以上経過",  'hint' => '請求漏れの可能性'],
    'payment_overdue'    => ['label' => "支払待ち & 請求から{$thresholds['pay_overdue_days']}日以上経過",   'hint' => '入金漏れ → 督促検討'],
    'completed_no_bill'  => ['label' => '完了なのに請求日(date_bill)が空',                                  'hint' => 'ステータス入力ミス'],
    'completed_no_pay'   => ['label' => '完了なのに入金額(sum_pay)が0/空',                                  'hint' => '入金記録漏れ'],
];
$quality_warn = [
    'empty_state'           => ['label' => '状態(state)が空',                                'hint' => '集計から漏れる'],
    'empty_name'            => ['label' => 'クライアント名 or 案件名 が空',                  'hint' => '検索・集計困難'],
    'date_inconsistent'     => ['label' => '日付の論理矛盾 (見積>受注 / 受注>完了 / 完了>請求)', 'hint' => '入力ミス'],
    'lost_with_received'    => ['label' => '受注できず/未受注なのに受注日あり',              'hint' => '状態とデータの矛盾'],
    'completed_no_received' => ['label' => '完了なのに受注日(date_received)が空',            'hint' => '受注日不明'],
];
$critical_total = array_sum(array_map(fn($k) => (int)($quality[$k] ?? 0), array_keys($quality_critical)));
$warn_total     = array_sum(array_map(fn($k) => (int)($quality[$k] ?? 0), array_keys($quality_warn)));
?>
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>案件 状態別割合＆月次見積額 — 株式会社はなさか</title>
<script src="https://cdn.tailwindcss.com"></script>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
</head>
<body class="bg-gray-50 text-gray-900">
<div class="max-w-5xl mx-auto p-6 md:p-10">

  <nav class="text-sm text-gray-500 mb-4">
    <a href="../index.html" class="text-blue-600 hover:underline">← 株式会社はなさか</a>
    /
    <a href="index.html" class="text-blue-600 hover:underline">ビジネスダッシュボード</a>
  </nav>

  <h1 class="text-3xl font-bold mb-2">案件 状態別割合 & 月次見積額</h1>
  <p class="text-gray-600 mb-2">スプレッドシート「案件リスト」の見える化。請求漏れ・支払い漏れ・失注の把握が目的。</p>
  <p class="text-xs text-gray-500 mb-8">
    取得時刻: <?= htmlspecialchars((string)$fetched_at) ?>
    ／ 全 <?= number_format($total) ?> 件
    ／ ソース:
    <?php if ($source === 'fresh'): ?>
      <span class="text-emerald-600">🟢 最新取得</span>
    <?php elseif ($source === 'cache'): ?>
      <span class="text-blue-600">🔵 キャッシュ（<?= (int)$age ?>秒前）</span>
    <?php elseif ($source === 'stale'): ?>
      <span class="text-amber-600">🟡 古いキャッシュ（API取得失敗）</span>
    <?php endif; ?>
    ／ <a href="?refresh=1" class="text-blue-600 hover:underline">🔄 強制再取得</a>
  </p>

  <!-- ① 状態別割合 -->
  <section class="bg-white rounded-lg shadow p-6 mb-8">
    <h2 class="text-xl font-bold mb-1">① 案件の状態別割合</h2>
    <p class="text-sm text-gray-600 mb-4">全 <?= number_format($total) ?> 件の状態別件数と見積額。「受注できず」は失注分。</p>
    <div class="grid grid-cols-1 md:grid-cols-2 gap-6 items-center">
      <div class="relative" style="height: 320px;">
        <canvas id="stateChart"></canvas>
      </div>
      <div>
        <table class="w-full text-sm">
          <thead>
            <tr class="border-b text-gray-600">
              <th class="text-left py-2">状態</th>
              <th class="text-right py-2">件数</th>
              <th class="text-right py-2">割合</th>
              <th class="text-right py-2">見積額合計</th>
            </tr>
          </thead>
          <tbody>
            <?php foreach ($state_data as $s): ?>
              <?php $pct = $total ? $s['count'] / $total * 100 : 0; ?>
              <tr class="border-b">
                <td class="py-2">
                  <span class="inline-block w-3 h-3 rounded-full mr-2 align-middle" style="background:<?= htmlspecialchars($s['color']) ?>"></span>
                  <?= htmlspecialchars($s['label']) ?>
                </td>
                <td class="text-right py-2 font-mono"><?= number_format($s['count']) ?></td>
                <td class="text-right py-2 text-gray-500"><?= number_format($pct, 1) ?>%</td>
                <td class="text-right py-2 font-mono">¥<?= number_format($s['money']) ?></td>
              </tr>
            <?php endforeach; ?>
          </tbody>
        </table>
      </div>
    </div>
  </section>

  <!-- ② 月次見積額 -->
  <section class="bg-white rounded-lg shadow p-6 mb-8">
    <h2 class="text-xl font-bold mb-1">② 月次見積額の推移</h2>
    <p class="text-sm text-gray-600 mb-4">
      見積発生月（<code>date_estimate</code>）ベース。受注（売上対象）／失注／その他の積み上げ。
      <span class="text-emerald-700">💡 バーをクリックするとその月の案件一覧が下に展開されます。</span>
    </p>
    <div style="height: 420px;">
      <canvas id="monthlyChart"></canvas>
    </div>
  </section>

  <!-- ③ 月の明細（クリックで展開） -->
  <section id="monthDetailsPanel" class="bg-white rounded-lg shadow p-6 mb-8 hidden">
    <div class="flex items-center justify-between mb-4">
      <h2 class="text-xl font-bold" id="monthDetailsTitle">月の案件</h2>
      <button type="button" id="monthDetailsClose" class="text-sm text-gray-500 hover:text-gray-700 px-3 py-1 border rounded">✕ 閉じる</button>
    </div>
    <div id="monthDetailsSummary" class="text-sm text-gray-600 mb-3"></div>
    <div class="overflow-x-auto">
      <table class="w-full text-sm">
        <thead>
          <tr class="border-b text-gray-600 text-left">
            <th class="py-2">状態</th>
            <th class="py-2">クライアント</th>
            <th class="py-2">案件</th>
            <th class="py-2">カテゴリ</th>
            <th class="py-2 text-right">見積額</th>
            <th class="py-2 whitespace-nowrap">見積日</th>
          </tr>
        </thead>
        <tbody id="monthDetailsTable"></tbody>
      </table>
    </div>
  </section>

  <!-- ④ データ品質チェック -->
  <section class="bg-white rounded-lg shadow p-6 mb-8 border-l-4 border-amber-400">
    <h2 class="text-xl font-bold mb-1">⚠️ データ品質チェック</h2>
    <p class="text-sm text-gray-600 mb-4">
      入力ルールから逸脱しているデータの件数。クレンジング・運用ルール見直しの優先順位付けに使う。
      <span class="text-gray-500">（明細表示は未実装。件数のみ）</span>
    </p>

    <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
      <!-- 🔴 重大 -->
      <div>
        <h3 class="font-semibold text-red-700 mb-2 flex items-center justify-between">
          <span>🔴 重大：請求・入金漏れに直結</span>
          <span class="text-sm font-mono"><?= number_format($critical_total) ?> 件</span>
        </h3>
        <table class="w-full text-sm">
          <tbody>
            <?php foreach ($quality_critical as $key => $meta): $n = (int)($quality[$key] ?? 0); ?>
              <tr class="border-b">
                <td class="py-2 align-top">
                  <div><?= htmlspecialchars($meta['label']) ?></div>
                  <div class="text-xs text-gray-500"><?= htmlspecialchars($meta['hint']) ?></div>
                </td>
                <td class="py-2 text-right font-mono align-top whitespace-nowrap <?= $n > 0 ? 'text-red-700 font-semibold' : 'text-gray-400' ?>">
                  <?= number_format($n) ?> 件
                </td>
              </tr>
            <?php endforeach; ?>
          </tbody>
        </table>
      </div>

      <!-- 🟡 中 -->
      <div>
        <h3 class="font-semibold text-amber-700 mb-2 flex items-center justify-between">
          <span>🟡 中：データ整合性</span>
          <span class="text-sm font-mono"><?= number_format($warn_total) ?> 件</span>
        </h3>
        <table class="w-full text-sm">
          <tbody>
            <?php foreach ($quality_warn as $key => $meta): $n = (int)($quality[$key] ?? 0); ?>
              <tr class="border-b">
                <td class="py-2 align-top">
                  <div><?= htmlspecialchars($meta['label']) ?></div>
                  <div class="text-xs text-gray-500"><?= htmlspecialchars($meta['hint']) ?></div>
                </td>
                <td class="py-2 text-right font-mono align-top whitespace-nowrap <?= $n > 0 ? 'text-amber-700 font-semibold' : 'text-gray-400' ?>">
                  <?= number_format($n) ?> 件
                </td>
              </tr>
            <?php endforeach; ?>
          </tbody>
        </table>
      </div>
    </div>

    <p class="text-xs text-gray-500 mt-4">
      閾値: 請求漏れ判定 = <?= (int)$thresholds['bill_overdue_days'] ?>日 ／ 入金漏れ判定 = <?= (int)$thresholds['pay_overdue_days'] ?>日<br>
      ※ 同じ案件が複数項目に重複カウントされる可能性あり（例：完了&請求日空&入金額0 → 2つに該当）
    </p>
  </section>

  <p class="text-xs text-gray-500 mt-8">
    データソース: スプレッドシート「案件リスト」 / Google Sheets API（<?= CACHE_TTL ?>秒キャッシュ）<br>
    関連: <a href="recurring-revenue.html" class="text-blue-600 hover:underline">月次ストック収益</a>
  </p>

</div>

<script>
const stateData = <?= json_encode($state_data, JSON_UNESCAPED_UNICODE) ?>;
const months = <?= json_encode($months, JSON_UNESCAPED_UNICODE) ?>;
const seriesSales = <?= json_encode($series['受注']) ?>;
const seriesLost  = <?= json_encode($series['失注']) ?>;
const seriesOther = <?= json_encode($series['その他']) ?>;
const detailsByMonth = <?= json_encode($details, JSON_UNESCAPED_UNICODE) ?>;

new Chart(document.getElementById('stateChart'), {
  type: 'doughnut',
  data: {
    labels: stateData.map(s => s.label),
    datasets: [{
      data: stateData.map(s => s.count),
      backgroundColor: stateData.map(s => s.color),
      borderWidth: 1
    }]
  },
  options: {
    responsive: true,
    maintainAspectRatio: false,
    plugins: {
      legend: { position: 'bottom' },
      tooltip: {
        callbacks: {
          label: (ctx) => `${ctx.label}: ${ctx.parsed.toLocaleString()}件`
        }
      }
    }
  }
});

new Chart(document.getElementById('monthlyChart'), {
  type: 'bar',
  data: {
    labels: months,
    datasets: [
      { label: '受注', data: seriesSales, backgroundColor: '#10b981' },
      { label: '失注', data: seriesLost,  backgroundColor: '#ef4444' },
      { label: 'その他', data: seriesOther, backgroundColor: '#9ca3af' }
    ]
  },
  options: {
    responsive: true,
    maintainAspectRatio: false,
    onClick: (evt, elements, chart) => {
      // クリック位置のX軸インデックスを取得（バーの空白をクリックしても効くように）
      const canvasPos = Chart.helpers.getRelativePosition(evt, chart);
      const xIdx = chart.scales.x.getValueForPixel(canvasPos.x);
      if (xIdx == null || xIdx < 0 || xIdx >= months.length) return;
      showMonthDetails(months[xIdx]);
    },
    onHover: (evt, elements, chart) => {
      evt.native.target.style.cursor = 'pointer';
    },
    scales: {
      x: { stacked: true },
      y: {
        stacked: true,
        ticks: { callback: (v) => '¥' + v.toLocaleString() }
      }
    },
    plugins: {
      tooltip: {
        callbacks: {
          label: (ctx) => `${ctx.dataset.label}: ¥${ctx.parsed.y.toLocaleString()}`,
          footer: () => 'クリックで案件一覧を表示'
        }
      }
    }
  }
});

function escapeHtml(s) {
  const div = document.createElement('div');
  div.textContent = s == null ? '' : String(s);
  return div.innerHTML;
}

function showMonthDetails(month) {
  const items = detailsByMonth[month] || [];
  const panel = document.getElementById('monthDetailsPanel');
  const title = document.getElementById('monthDetailsTitle');
  const summary = document.getElementById('monthDetailsSummary');
  const tbody = document.getElementById('monthDetailsTable');

  const bucketSum = { '受注': 0, '失注': 0, 'その他': 0 };
  items.forEach(it => { bucketSum[it.bucket] = (bucketSum[it.bucket] || 0) + it.money; });
  const totalSum = items.reduce((a, b) => a + b.money, 0);

  title.textContent = `📅 ${month} の案件（${items.length} 件 / 合計 ¥${totalSum.toLocaleString()}）`;
  summary.innerHTML = [
    `<span class="inline-block px-2 py-0.5 rounded bg-emerald-100 text-emerald-800 mr-2">受注 ¥${bucketSum['受注'].toLocaleString()}</span>`,
    `<span class="inline-block px-2 py-0.5 rounded bg-red-100 text-red-800 mr-2">失注 ¥${bucketSum['失注'].toLocaleString()}</span>`,
    `<span class="inline-block px-2 py-0.5 rounded bg-gray-100 text-gray-700">その他 ¥${bucketSum['その他'].toLocaleString()}</span>`,
  ].join('');

  if (items.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6" class="py-4 text-gray-500 text-center">この月の案件はありません</td></tr>';
  } else {
    tbody.innerHTML = items.map(it => `
      <tr class="border-b hover:bg-gray-50">
        <td class="py-2">
          <span class="inline-block w-2 h-2 rounded-full mr-1 align-middle" style="background:${it.color}"></span>
          ${escapeHtml(it.state)}
        </td>
        <td class="py-2">${escapeHtml(it.client)}</td>
        <td class="py-2">${escapeHtml(it.project)}</td>
        <td class="py-2 text-gray-500">${escapeHtml(it.category)}</td>
        <td class="py-2 text-right font-mono">¥${it.money.toLocaleString()}</td>
        <td class="py-2 text-gray-500 whitespace-nowrap">${escapeHtml(it.date)}</td>
      </tr>
    `).join('');
  }

  panel.classList.remove('hidden');
  panel.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

document.getElementById('monthDetailsClose').addEventListener('click', () => {
  document.getElementById('monthDetailsPanel').classList.add('hidden');
});
</script>

</body>
</html>
