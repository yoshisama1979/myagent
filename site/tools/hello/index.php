<?php
declare(strict_types=1);

$info = [
    'PHP バージョン' => PHP_VERSION,
    '実行ユーザ' => trim((string)shell_exec('whoami')),
    'ホスト名' => gethostname() ?: '-',
    '現在時刻' => date('Y-m-d H:i:s'),
    '作業ディレクトリ' => getcwd() ?: '-',
    'プロジェクトルート' => realpath(__DIR__ . '/../../..') ?: '-',
];
?>
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Hello — PHP動作確認</title>
<script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-50 text-gray-900">
<div class="max-w-2xl mx-auto p-6 md:p-10">

  <nav class="text-sm text-gray-500 mb-4">
    <a href="../" class="text-blue-600 hover:underline">← ツールハブ</a>
  </nav>

  <h1 class="text-3xl font-bold mb-2">👋 Hello, PHP</h1>
  <p class="text-gray-600 mb-8">PHP-FPM + Nginx の動作確認用ページ。</p>

  <table class="w-full border-collapse border border-gray-300 text-sm">
    <tbody>
      <?php foreach ($info as $key => $value): ?>
        <tr class="border-b border-gray-300">
          <th class="text-left bg-gray-100 px-3 py-2 w-1/3"><?= htmlspecialchars($key) ?></th>
          <td class="px-3 py-2 font-mono"><?= htmlspecialchars((string)$value) ?></td>
        </tr>
      <?php endforeach; ?>
    </tbody>
  </table>

</div>
</body>
</html>
