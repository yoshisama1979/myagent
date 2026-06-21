// hp-serp.mjs — HP分析ループ用・検索結果（SERP）から競合サイトURLを取得（T-011・読み取り専用）
//
// 目的：狙うクエリの検索結果の上位サイト（＝競合・参考サイト）を自動取得し、hp-compete / hp-shot へ渡す。
//       社長のSEOワークフロー「①SCで戦場特定 → ②検索結果から競合を見つける → ③超える施策」の
//       ②を自動化する。SEOは相対評価なので「狙うクエリで上位の競合を超える」のがゴール。
//
// なぜ Yahoo! JAPAN か（2026-06-21 実測で決定）：
//   このVPS（データセンターIP）からは
//     - Google      … HTTP 429「通常と異なるトラフィック」でボット判定ブロック（取得不能）
//     - Bing        … 取れるが結果が無関係（「ホーム」を住宅/不動産と誤解釈し制作会社が出ない）
//     - Yahoo!JAPAN … HTTP 200・Googleのインデックス使用＝関連性が正しい・ブロックされない ← これを使う
//   Yahoo!JAPAN は Google 検索インデックスを採用しているため、結果は Google 順位に近く関連性も妥当。
//   IP地域に依存しない（クエリに「大阪」等を入れればその地域の結果が出る）＝社長方針
//   「コンテンツ改善は地域非依存で十分・大阪固有が要るときは社長が渡す」に合致。
//
// 安全（automation.md 準拠／hp-shot と同じ多層防御）：実行時は読み取り専用。
//   - 検索結果ページを描画して結果リンクを読むだけ。外部送信・本番改変・フォーム送信・クリックはしない。
//   - 非GETリクエスト（POST/beacon等）は abort、ダウンロードは拒否（read-only を物理担保）。
//   - 取得先は search.yahoo.co.jp 固定（任意URLは踏まない）。Chromeサンドボックス有効・使い捨てプロファイル。
//   - 競合サイト本体は取得しない（それは hp-compete/hp-shot の役目＝役割分離）。
//   - ブロック・0件は握りつぶさず明示（捏造しない）。低頻度・少量で使う（週次・数クエリ想定）。
//
// 使い方：
//   node bin/hp-serp.mjs "<検索クエリ>" [--top N] [--exclude ドメイン,ドメイン] [--json|--urls]
//   例：node bin/hp-serp.mjs "ホームページ制作 大阪 料金" --top 8 --exclude y-com.info
//   既定：上位10件・自社(y-com.info 等)除外なし(--exclude 指定推奨)・人が読む表
//   --urls：URLを1行1件で出力（hp-compete へ渡しやすい）。--json：機械可読。

import puppeteer from 'puppeteer-core';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const CHROME_ALLOWLIST = ['/usr/bin/google-chrome', '/usr/bin/google-chrome-stable',
  '/usr/bin/chromium', '/usr/bin/chromium-browser'];
const NAV_TIMEOUT = 30000;
const SETTLE_MS = 2000;
const SEARCH_HOST = 'search.yahoo.co.jp';
// リクエストを通す宛先は Yahoo!/Yimg 系のみ（検索結果ページの描画に必要な範囲）。
// これ以外（広告・計測・競合サイト本体へのprefetch等）は GET でも abort＝「取得先は Yahoo 固定」を物理担保。
const ALLOW_REQ_HOSTS = ['yahoo.co.jp', 'yahoo.com', 'yimg.jp', 'yahoo.jp'];

function fail(msg) { console.error(msg); process.exit(2); }

const CHROME = (() => {
  const c = process.env.HP_SHOT_CHROME;
  if (!c) return CHROME_ALLOWLIST[0];
  if (!CHROME_ALLOWLIST.includes(c)) fail(`error: HP_SHOT_CHROME は許可パスのみ（${CHROME_ALLOWLIST.join(' / ')}）`);
  return c;
})();

// --- 引数 ---
const argv = process.argv.slice(2);
let query = '';
let top = 10;
let exclude = [];
let mode = 'human'; // human | json | urls
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--json') mode = 'json';
  else if (a === '--urls') mode = 'urls';
  else if (a === '--top') top = Math.max(1, Math.min(30, parseInt(argv[++i] || '10', 10) || 10));
  else if (a === '--exclude') exclude = (argv[++i] || '').split(',').map(s => s.trim().toLowerCase()).filter(Boolean);
  else if (a.startsWith('-')) fail(`error: 不明なオプション: ${a}`);
  else if (!query) query = a;
  else fail('error: クエリは1つだけ指定してください（複数語はクォートで囲む）');
}
if (!query) fail('usage: node bin/hp-serp.mjs "<検索クエリ>" [--top N] [--exclude ドメイン,…] [--json|--urls]');

// 結果URLのクリーニング：ハッシュ(#:~:text= 等)除去・既知トラッキングパラメータ除去
function cleanUrl(raw) {
  try {
    const u = new URL(raw);
    u.hash = '';
    for (const k of ['msockid', 'utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content', 'gclid', 'fbclid']) {
      u.searchParams.delete(k);
    }
    // 末尾の空クエリを整理
    let s = u.toString();
    s = s.replace(/\?$/, '');
    return s;
  } catch { return raw; }
}

function hostOf(u) { try { return new URL(u).hostname.replace(/^www\./, '').toLowerCase(); } catch { return ''; } }

let browser = null;
let userDataDir = null;
try {
  userDataDir = await mkdtemp(path.join(os.tmpdir(), 'hp-serp-'));
  browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: 'new',
    userDataDir,
    args: ['--disable-gpu', '--disable-dev-shm-usage', '--disable-background-networking', '--disable-sync', '--lang=ja-JP'],
  });

  const page = await browser.newPage();
  // 非GET遮断＋「取得先は Yahoo 系のみ」許可＋ダウンロード拒否（read-only・取得先固定を物理担保）
  await page.setRequestInterception(true);
  page.on('request', (req) => {
    if (req.method() !== 'GET') return req.abort();             // POST/beacon 等は遮断
    let h = '';
    try { h = new URL(req.url()).hostname.toLowerCase(); } catch { return req.abort(); }
    const ok = ALLOW_REQ_HOSTS.some(d => h === d || h.endsWith('.' + d));
    return ok ? req.continue() : req.abort();                   // Yahoo/Yimg 以外（広告/計測/競合本体prefetch）は踏まない
  });
  const cdp = await page.target().createCDPSession();
  await cdp.send('Page.setDownloadBehavior', { behavior: 'deny' }).catch(() => {});

  await page.setUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36');
  await page.setExtraHTTPHeaders({ 'Accept-Language': 'ja-JP,ja;q=0.9' });

  const searchUrl = `https://${SEARCH_HOST}/search?p=${encodeURIComponent(query)}`;
  const resp = await page.goto(searchUrl, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT });
  await new Promise(r => setTimeout(r, SETTLE_MS));

  const status = resp ? resp.status() : null;
  const httpOk = status !== null && status >= 200 && status < 300;
  // ボット判定・異常検出（捏造しない＝ブロック/HTTPエラーを成功と偽らない）。
  // 本文を広めに見る＋title＋CAPTCHA系selectorも併用して取りこぼしを減らす。
  const pageInfo = await page.evaluate(() => ({
    body: (document.body?.innerText || '').slice(0, 5000),
    title: document.title || '',
    captcha: !!document.querySelector('form[action*="captcha" i], iframe[src*="recaptcha" i], #recaptcha, .g-recaptcha'),
  }));
  const BOT_RE = /通常と異なるトラフィック|unusual traffic|reCAPTCHA|あなたがロボットでないこと|画像認証|認証にご協力|アクセスが制限/i;
  const botDetected = pageInfo.captcha || BOT_RE.test(pageInfo.body) || BOT_RE.test(pageInfo.title);

  // 結果リンク抽出：Yahoo!JAPAN の本文領域のアンカーから外部サイトを拾う
  const rawLinks = await page.evaluate(() => {
    const out = [];
    const scope = document.querySelector('#contents') || document.body;
    scope.querySelectorAll('a[href^="http"]').forEach((a) => {
      const href = a.href;
      const title = (a.innerText || '').trim().split('\n')[0];
      out.push({ href, title });
    });
    return out;
  });

  // 自社/検索エンジン/ノイズを除外しつつ、ドメイン単位で上位を残す
  const NOISE = ['yahoo.co.jp', 'yahoo.com', 'yimg.jp', 'yahoo.jp', 'google.com', 'bing.com', 'microsoft.com'];
  const seen = new Set();
  const results = [];
  for (const { href, title } of rawLinks) {
    const url = cleanUrl(href);
    const host = hostOf(url);
    if (!host) continue;
    if (!/^https?:\/\//.test(url)) continue;
    if (NOISE.some(n => host === n || host.endsWith('.' + n))) continue;
    if (exclude.some(e => host === e || host.endsWith('.' + e))) continue;
    if (seen.has(host)) continue;       // 同一ドメインは最上位1件（別企業を並べる）
    seen.add(host);
    results.push({ rank: results.length + 1, url, domain: host, title: (title || '').slice(0, 70) });
    if (results.length >= top) break;
  }

  // 取得不能の総合判定（捏造しない）：HTTP非2xx／ボット判定／結果0件はすべて失敗扱い
  const failed = !httpOk || botDetected || results.length === 0;
  let note = null;
  if (!httpOk) note = `⛔ HTTPステータスが非2xx（${status ?? '不明'}）＝取得不能扱い`;
  else if (botDetected) note = '⛔ ボット判定/CAPTCHA を検出。結果は信頼できない（取得不能扱い）。時間をおく/社長にSERPを依頼する';
  else if (results.length === 0) note = '⛔ 結果0件。クエリ・到達性・Yahoo側HTML構造変更を確認（取得不能扱い）';

  if (mode === 'json') {
    console.log(JSON.stringify({
      ok: !failed, engine: 'yahoo-japan', query, http: status,
      blocked: botDetected, count: results.length, results, note,
    }, null, 1));
  } else if (mode === 'urls') {
    if (failed) console.error(note);
    results.forEach(r => console.log(r.url));
  } else {
    console.log(`■ hp-serp（Yahoo!JAPAN＝Googleインデックス・読み取り専用） q="${query}" HTTP=${status}`);
    if (note) console.log(`  ${note}`);
    console.log(`  上位 ${results.length} サイト（自社/検索エンジン/重複ドメイン除外後）:`);
    results.forEach(r => console.log(`  ${String(r.rank).padStart(2)}. ${r.domain}\n      ${r.title || '(タイトル取得不可)'}\n      ${r.url}`));
    console.log('  ※ 競合の中身は hp-compete.py / hp-shot.sh で対比する（このツールはURL収集のみ）');
  }
  if (failed) process.exitCode = 3;
} catch (e) {
  console.error('hp-serp failed:', (e && e.message ? e.message : String(e)).split('\n')[0]);
  process.exitCode = 1;
} finally {
  if (browser) await browser.close().catch(() => {});
  if (userDataDir) await rm(userDataDir, { recursive: true, force: true }).catch(() => {});
}
