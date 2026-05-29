<?php
declare(strict_types=1);
date_default_timezone_set('Asia/Tokyo');

const PROJECT_ROOT = '/home/vpsuser/projects/myagent';
const DATA_ROOT = PROJECT_ROOT . '/data/monthly';
const MAX_FILE_SIZE = 1024 * 1024;

const CATEGORIES = [
    'revenue' => [
        'label' => '売上系',
        'icon' => '💰',
        'color' => 'emerald',
        'columns' => ['年月', '売上', '新規受注金額', 'ストック収益'],
        'sample' => [
            ['2026-04', 1234567, 500000, 123456],
            ['2026-05', 1345678, 620000, 135000],
        ],
    ],
    'cost' => [
        'label' => 'コスト系',
        'icon' => '💸',
        'color' => 'rose',
        'columns' => ['年月', '外注費', '広告費', 'その他経費'],
        'sample' => [
            ['2026-04', 300000, 50000, 80000],
            ['2026-05', 280000, 45000, 90000],
        ],
    ],
];

function validate_year_month(string $ym): bool {
    return (bool)preg_match('/^\d{4}-(0[1-9]|1[0-2])$/', $ym);
}

function emit_csv_template(string $category): void {
    if (!isset(CATEGORIES[$category])) {
        http_response_code(404);
        echo 'Unknown category';
        exit;
    }
    $meta = CATEGORIES[$category];
    header('Content-Type: text/csv; charset=UTF-8');
    header('Content-Disposition: attachment; filename="' . $category . '-template.csv"');
    echo "\xEF\xBB\xBF";
    $out = fopen('php://output', 'w');
    fputcsv($out, $meta['columns']);
    foreach ($meta['sample'] as $row) {
        fputcsv($out, $row);
    }
    fclose($out);
    exit;
}

if (isset($_GET['template'])) {
    emit_csv_template((string)$_GET['template']);
}

function parse_csv_upload(string $tmp_name, array $expected_columns): array {
    $contents = file_get_contents($tmp_name);
    if ($contents === false) return ['error' => 'ファイル読込失敗'];
    if (substr($contents, 0, 3) === "\xEF\xBB\xBF") {
        $contents = substr($contents, 3);
    }
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

    if (count($rows) < 2) return ['error' => 'データ行がありません（ヘッダーのみ？）'];

    $header = array_map('trim', $rows[0]);
    foreach ($expected_columns as $col) {
        if (!in_array($col, $header, true)) {
            return ['error' => "ヘッダーに「{$col}」がありません。必要な列：" . implode(' / ', $expected_columns)];
        }
    }

    $header_idx = array_flip($header);
    $data_rows = array_slice($rows, 1);

    $parsed = [];
    foreach ($data_rows as $i => $row) {
        $line_no = $i + 2;
        $ym_raw = trim((string)($row[$header_idx['年月']] ?? ''));
        if ($ym_raw === '') continue;
        if (!validate_year_month($ym_raw)) {
            return ['error' => "行{$line_no}: 年月「{$ym_raw}」が不正。YYYY-MM 形式で入力してください"];
        }
        $rec = ['年月' => $ym_raw];
        foreach ($expected_columns as $col) {
            if ($col === '年月') continue;
            $val = trim((string)($row[$header_idx[$col]] ?? ''));
            $val = str_replace([',', '￥', '¥', '円', ' '], '', $val);
            if ($val === '') $val = '0';
            if (!is_numeric($val)) {
                return ['error' => "行{$line_no}: 「{$col}」が数値ではありません（{$val}）"];
            }
            $rec[$col] = (float)$val;
        }
        $parsed[] = $rec;
    }

    return ['rows' => $parsed];
}

function save_record(string $category, array $rec): string {
    $ym = $rec['年月'];
    $dir = DATA_ROOT . '/' . $category;
    if (!is_dir($dir)) mkdir($dir, 0755, true);
    $file = $dir . '/' . $ym . '.json';
    $data = [
        'year_month' => $ym,
        'category' => $category,
        'uploaded_at' => date('Y-m-d H:i:s'),
        'data' => array_diff_key($rec, ['年月' => true]),
    ];
    file_put_contents($file, json_encode($data, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
    return $file;
}

$messages = [];
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    foreach (CATEGORIES as $cat => $meta) {
        $field = "{$cat}_csv";
        if (!isset($_FILES[$field]) || $_FILES[$field]['error'] === UPLOAD_ERR_NO_FILE) continue;
        $f = $_FILES[$field];
        if ($f['error'] !== UPLOAD_ERR_OK) {
            $messages[] = ['type' => 'error', 'cat' => $cat, 'text' => "アップロードエラー (code: {$f['error']})"];
            continue;
        }
        if ($f['size'] > MAX_FILE_SIZE) {
            $messages[] = ['type' => 'error', 'cat' => $cat, 'text' => 'ファイルサイズが1MBを超えています'];
            continue;
        }
        $result = parse_csv_upload($f['tmp_name'], $meta['columns']);
        if (isset($result['error'])) {
            $messages[] = ['type' => 'error', 'cat' => $cat, 'text' => $result['error']];
            continue;
        }
        $saved = [];
        foreach ($result['rows'] as $rec) {
            save_record($cat, $rec);
            $saved[] = $rec['年月'];
        }
        $messages[] = [
            'type' => 'success',
            'cat' => $cat,
            'text' => count($saved) . '件保存しました：' . implode(', ', $saved),
        ];
    }
}

function h(string $s): string { return htmlspecialchars($s, ENT_QUOTES, 'UTF-8'); }
?><!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>月次データ アップロード — 株式会社はなさか</title>
<script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-50 text-gray-900">
<div class="max-w-4xl mx-auto p-6 md:p-10">

  <nav class="text-sm text-gray-500 mb-4">
    <a href="../index.html" class="text-blue-600 hover:underline">← 株式会社はなさか</a> &gt;
    <a href="index.html" class="text-blue-600 hover:underline">ビジネスダッシュボード</a>
  </nav>

  <h1 class="text-3xl font-bold mb-2">月次データ アップロード</h1>
  <p class="text-gray-600 mb-6">CSV形式で月次データをアップロードします。前年同月比較に使用。
    <a href="monthly-status.php" class="text-blue-600 hover:underline">→ アップロード状況を確認</a></p>

  <div class="bg-blue-50 border-l-4 border-blue-400 rounded p-4 mb-6 text-sm">
    <h3 class="font-bold text-blue-800 mb-2">📌 アップロード仕様</h3>
    <ul class="list-disc list-inside space-y-1 text-gray-700">
      <li><strong>1ファイル内に複数月を含めてOK</strong>（例：年度頭にまとめて投入も、毎月1行ずつも可）</li>
      <li>同じ年月を再アップロードすると<strong>上書き</strong>される</li>
      <li>年月は <code>YYYY-MM</code> 形式（例：<code>2026-04</code>）</li>
      <li>金額は数字のみ。<code>1,234,567</code> や <code>￥1234567</code> も OK（自動で正規化）</li>
      <li>文字コード：UTF-8（BOM付き可）または Shift_JIS</li>
    </ul>
  </div>

  <?php foreach ($messages as $m): ?>
    <?php
      $cat_label = CATEGORIES[$m['cat']]['label'];
      $is_err = $m['type'] === 'error';
      $bg = $is_err ? 'bg-red-50 border-red-400 text-red-800' : 'bg-emerald-50 border-emerald-400 text-emerald-800';
      $icon = $is_err ? '❌' : '✅';
    ?>
    <div class="border-l-4 rounded p-3 mb-3 text-sm <?= $bg ?>">
      <strong><?= $icon ?> [<?= h($cat_label) ?>]</strong> <?= h($m['text']) ?>
    </div>
  <?php endforeach; ?>

  <form method="POST" enctype="multipart/form-data" class="space-y-6">

    <?php foreach (CATEGORIES as $cat => $meta): ?>
      <?php
        $color = $meta['color'];
        $border = "border-{$color}-300";
        $bg = "bg-{$color}-50";
        $title_color = "text-{$color}-700";
      ?>
      <div class="border-2 <?= $border ?> <?= $bg ?> rounded-lg p-5">
        <h2 class="text-xl font-bold <?= $title_color ?> mb-2"><?= h($meta['icon']) ?> <?= h($meta['label']) ?></h2>
        <p class="text-xs text-gray-600 mb-3">
          列：<code class="bg-white px-1 rounded"><?= h(implode(' , ', $meta['columns'])) ?></code>
        </p>
        <div class="flex flex-col md:flex-row md:items-center gap-3">
          <input type="file" name="<?= h($cat) ?>_csv" accept=".csv,text/csv"
                 class="block w-full text-sm text-gray-700 file:mr-3 file:py-2 file:px-4 file:rounded file:border-0 file:bg-<?= $color ?>-600 file:text-white file:font-semibold hover:file:bg-<?= $color ?>-700">
          <a href="?template=<?= h($cat) ?>"
             class="whitespace-nowrap text-sm text-blue-600 hover:underline">📥 テンプレートDL</a>
        </div>
      </div>
    <?php endforeach; ?>

    <button type="submit"
            class="w-full bg-blue-600 hover:bg-blue-700 text-white font-bold py-3 px-6 rounded-lg shadow">
      アップロード
    </button>
  </form>

  <p class="text-xs text-gray-500 mt-6">
    保存先：<code>data/monthly/{revenue|cost}/YYYY-MM.json</code>（gitignored、VPS内のみ）
  </p>

</div>
</body>
</html>
