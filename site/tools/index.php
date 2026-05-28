<?php
declare(strict_types=1);

$tools = [];
foreach (new DirectoryIterator(__DIR__) as $entry) {
    if ($entry->isDot() || !$entry->isDir()) {
        continue;
    }
    $name = $entry->getFilename();
    if (str_starts_with($name, '_') || str_starts_with($name, '.')) {
        continue;
    }
    $meta_path = $entry->getPathname() . '/meta.json';
    $meta = ['title' => $name, 'desc' => '', 'tag' => ''];
    if (is_file($meta_path)) {
        $loaded = json_decode((string)file_get_contents($meta_path), true);
        if (is_array($loaded)) {
            $meta = array_merge($meta, $loaded);
        }
    }
    $tools[] = [
        'slug' => $name,
        'title' => $meta['title'],
        'desc' => $meta['desc'],
        'tag' => $meta['tag'],
    ];
}
usort($tools, fn($a, $b) => strcmp($a['slug'], $b['slug']));
?>
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ツールハブ — 株式会社はなさか</title>
<script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-50 text-gray-900">
<div class="max-w-4xl mx-auto p-6 md:p-10">

  <nav class="text-sm text-gray-500 mb-4">
    <a href="../index.html" class="text-blue-600 hover:underline">← 株式会社はなさか</a>
  </nav>

  <h1 class="text-3xl font-bold mb-2">🛠 ツールハブ</h1>
  <p class="text-gray-600 mb-8">PHPで動く社内ツール群。<code class="bg-gray-200 px-1 rounded">site/tools/&lt;slug&gt;/index.php</code> を追加すれば自動でここに並びます。</p>

  <?php if (empty($tools)): ?>
    <div class="border border-dashed border-gray-400 rounded p-6 text-gray-500 text-center">
      まだツールがありません。<br>
      <code class="bg-gray-200 px-1 rounded">site/tools/&lt;slug&gt;/index.php</code> を作って配置してください。
    </div>
  <?php else: ?>
    <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
      <?php foreach ($tools as $tool): ?>
        <a href="./<?= htmlspecialchars($tool['slug']) ?>/" class="block border border-gray-300 rounded p-4 hover:bg-gray-100 transition">
          <div class="flex items-center justify-between mb-1">
            <h3 class="font-semibold text-blue-600"><?= htmlspecialchars($tool['title']) ?></h3>
            <?php if ($tool['tag']): ?>
              <span class="text-xs bg-amber-100 text-amber-800 px-2 py-0.5 rounded"><?= htmlspecialchars($tool['tag']) ?></span>
            <?php endif; ?>
          </div>
          <?php if ($tool['desc']): ?>
            <p class="text-sm text-gray-600"><?= htmlspecialchars($tool['desc']) ?></p>
          <?php endif; ?>
          <p class="text-xs text-gray-400 mt-2 font-mono"><?= htmlspecialchars($tool['slug']) ?>/</p>
        </a>
      <?php endforeach; ?>
    </div>
  <?php endif; ?>

  <h2 class="text-xl font-semibold border-b border-gray-300 pb-2 mb-4 mt-10">ツールの追加方法</h2>
  <ol class="list-decimal list-inside space-y-1 text-sm text-gray-700">
    <li><code class="bg-gray-200 px-1 rounded">site/tools/&lt;slug&gt;/index.php</code> を作る</li>
    <li>必要なら <code class="bg-gray-200 px-1 rounded">site/tools/&lt;slug&gt;/meta.json</code> を作る（title / desc / tag）</li>
    <li>このページをリロードすると自動で並ぶ</li>
  </ol>

</div>
</body>
</html>
