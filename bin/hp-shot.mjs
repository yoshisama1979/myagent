// hp-shot.mjs — HP分析ループ用・読み取り専用スクリーンショットツール（T-008）
//
// 目的：指定URLを system Chrome（/usr/bin/google-chrome）でヘッドレス描画し、
//       PC幅・スマホ幅の「フルページPNG」を保存する。ループ（マルチモーダル）が
//       PNGを実際に見て、ファーストビュー・レイアウト・配色・CTAの目立ち・SP表示崩れ等
//       hp-audit（タグ解析）では拾えないビジュアル面を評価するための一次素材。
//
// 安全（automation.md 準拠／無人運用前提で多層防御）：実行時は読み取り専用。
//   - 描画してPNG保存のみ。外部送信・本番改変・破壊的操作・フォーム送信・クリックはしない。
//   - 非GETリクエスト（POST/PUT/…）は abort し、ダウンロードも拒否（読み取りを物理的に担保）。
//   - URLは http(s) のみ。認証情報付きURL・localhost/ループバック・リンクローカル(メタデータ)は拒否（SSRF抑止）。
//   - 出力はプロジェクト配下のみ（パストラバーサル無害化）。Chromeプロファイルは使い捨て tmp に隔離し撤去。
//   - Chromeサンドボックスは有効のまま起動（このVPSは user namespace 可。--no-sandbox は使わない）。
//   - 標準出力のURLはクエリ・認証情報を除去（ログに秘密を残さない）。
//
// 使い方：
//   node bin/hp-shot.mjs <URL> <出力ディレクトリ> [名前]
//   例：node bin/hp-shot.mjs https://fujisakagas.com/ data/hp-loop/cycles/fujisaka/shots/ top
//   出力（4枚）：
//     <名前>-pc-fold.png … 1280幅・ファーストビューのみ（鮮明＝コピー精読用）
//     <名前>-pc-full.png … 1280幅・フルページ（構造・配色・section の流れ）
//     <名前>-sp-fold.png … 390幅・DPR2・モバイル・ファーストビューのみ（鮮明）
//     <名前>-sp-full.png … 390幅・DPR2・モバイル・フルページ
//   標準出力：結果JSON（paths/title/finalUrl(クエリ除去済)/サイズ）。
//
// 限界：JS描画後の見た目を撮る。動画/外部埋め込みの読み込み次第で差異あり。
//   イントロ演出のあるサイト用に networkidle 後 +待機 を入れている。

import puppeteer from 'puppeteer-core';
import { mkdir, mkdtemp, rm } from 'node:fs/promises';
import { statSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import dns from 'node:dns/promises';
import net from 'node:net';
import { fileURLToPath } from 'node:url';

// Chrome 実行バイナリは既知パスのみ許可（任意バイナリ実行の抜け道を封じる）
const CHROME_ALLOWLIST = ['/usr/bin/google-chrome', '/usr/bin/google-chrome-stable',
  '/usr/bin/chromium', '/usr/bin/chromium-browser'];
const NAV_TIMEOUT = 45000;
const SETTLE_MS = 2500;            // networkidle 後にイントロ演出等を落ち着かせる猶予
const SCROLL_MAX_STEPS = 60;       // 無限スクロール対策（最大ステップ）
const SCROLL_MAX_MS = 15000;       // スクロール処理全体の上限（無限ページで止まらない保険）
const PROJ = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SHOTS_ROOT = path.join(PROJ, 'data', 'hp-loop', 'cycles'); // 出力はここ配下(スクショ域・gitignore)のみ

function fail(msg) { console.error(msg); process.exit(2); }

// 標準出力・エラーに載せる用にURLのクエリと認証情報を落とす（トークン等の秘密漏洩抑止）
function redactUrl(u) {
  try { const x = new URL(u); return `${x.protocol}//${x.host}${x.pathname}`; } catch { return '(url)'; }
}

// プライベート/ループバック/リンクローカル/ULA/メタデータ宛てIPか（SSRF抑止）
function isBlockedIp(ip) {
  if (net.isIPv4(ip)) {
    const o = ip.split('.').map(Number);
    return o[0] === 0 || o[0] === 127 ||                       // this-host / loopback
      o[0] === 10 ||                                           // 10/8
      (o[0] === 172 && o[1] >= 16 && o[1] <= 31) ||            // 172.16/12
      (o[0] === 192 && o[1] === 168) ||                        // 192.168/16
      (o[0] === 169 && o[1] === 254) ||                        // 169.254/16 (メタデータ含む)
      (o[0] === 100 && o[1] >= 64 && o[1] <= 127);             // 100.64/10 (CGNAT/Tailscale)
  }
  if (net.isIPv6(ip)) {
    const a = ip.toLowerCase();
    if (a === '::1' || a === '::') return true;                // loopback / unspecified
    if (/^(fe80|fc|fd)/.test(a)) return true;                  // link-local / ULA
    const m = a.match(/::ffff:(\d+\.\d+\.\d+\.\d+)$/);          // IPv4-mapped
    if (m) return isBlockedIp(m[1]);
  }
  return false;
}

const CHROME = (() => {
  const c = process.env.HP_SHOT_CHROME;
  if (!c) return CHROME_ALLOWLIST[0];
  if (!CHROME_ALLOWLIST.includes(c)) fail(`error: HP_SHOT_CHROME は許可パスのみ（${CHROME_ALLOWLIST.join(' / ')}）`);
  return c;
})();

const [rawUrl, outdirArg, nameArg] = process.argv.slice(2);
if (!rawUrl || !outdirArg) fail('usage: node bin/hp-shot.mjs <URL> <outdir> [name]');

// --- URL 検証（http(s)のみ・認証情報なし・内部/メタデータ宛て拒否） ---
let parsed;
try { parsed = new URL(rawUrl); } catch { fail('error: URL の形式が不正です'); }
if (!/^https?:$/.test(parsed.protocol)) fail('error: URL は http(s):// で始めてください（読み取り専用GETのみ）');
if (parsed.username || parsed.password) fail('error: 認証情報付きURLは受け付けません');
const host = parsed.hostname.replace(/^\[|\]$/g, '').toLowerCase();
if (host === 'localhost' || host === 'metadata.google.internal') fail(`error: 内部宛てのURLは撮影しません（${host}）`);
// IPリテラルはその場で、ホスト名はDNS解決して全アドレスを内部IP判定（SSRF抑止）
if (net.isIP(host)) {
  if (isBlockedIp(host)) fail(`error: 内部/プライベート宛てのURLは撮影しません（${host}）`);
} else {
  let addrs = [];
  try { addrs = await dns.lookup(host, { all: true }); } catch { fail(`error: 名前解決に失敗しました（${host}）`); }
  if (!addrs.length || addrs.some(a => isBlockedIp(a.address))) {
    fail(`error: 内部/プライベートIPへ解決するホストは撮影しません（${host}）`);
  }
}
const url = parsed.href;

// --- name サニタイズ（パストラバーサル・区切り文字を排除） ---
const rawName = nameArg || parsed.pathname.replace(/[^a-zA-Z0-9]+/g, '-').replace(/^-|-$/g, '') || 'top';
const name = rawName.replace(/[^a-zA-Z0-9._-]/g, '-').replace(/^[-.]+/, '').slice(0, 64) || 'top';

// --- 出力先をスクショ域（data/hp-loop/cycles/）配下に限定（committed資産の上書き防止） ---
const outdir = path.resolve(outdirArg);
if (!outdir.startsWith(SHOTS_ROOT + path.sep)) {
  fail(`error: 出力先は ${SHOTS_ROOT}/ 配下のみ許可します（例: data/hp-loop/cycles/<site>/shots/）`);
}
const outPath = (suffix) => {
  const p = path.resolve(outdir, `${name}-${suffix}.png`);
  if (p !== outdir && !p.startsWith(outdir + path.sep)) fail('error: 出力パスがディレクトリ外を指しています');
  return p;
};

async function shot(browser, { width, height, dpr, mobile }, foldPath, fullPath) {
  const page = await browser.newPage();
  try {
    // 非GETを物理的に遮断（フォーム送信/ビーコン/POST等を abort＝read-only 担保）
    await page.setRequestInterception(true);
    page.on('request', (req) => {
      if (req.method() === 'GET') req.continue();
      else req.abort();
    });
    // ダウンロードを拒否
    const cdp = await page.target().createCDPSession();
    await cdp.send('Page.setDownloadBehavior', { behavior: 'deny' }).catch(() => {});

    await page.setViewport({ width, height, deviceScaleFactor: dpr, isMobile: mobile, hasTouch: mobile });
    if (mobile) await page.setUserAgent('Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1');
    const resp = await page.goto(url, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT });
    await new Promise(r => setTimeout(r, SETTLE_MS));
    // 遅延読み込み画像の発火＋イントロ演出の完了を促す：最下部まで送って先頭へ戻す（回数・時間・高さ上限つき）
    await page.evaluate(async (maxSteps, maxMs) => {
      await new Promise(res => {
        const t0 = Date.now(); let y = 0; let steps = 0; const cap = 200000; // 高さ上限(px)
        const step = () => {
          window.scrollTo(0, y); y += window.innerHeight; steps++;
          if (y < document.body.scrollHeight && steps < maxSteps && y < cap && (Date.now() - t0) < maxMs) setTimeout(step, 120);
          else res();
        }; step();
      });
    }, SCROLL_MAX_STEPS, SCROLL_MAX_MS);
    await page.evaluate(() => window.scrollTo(0, 0));
    await new Promise(r => setTimeout(r, 800));
    await page.screenshot({ path: foldPath, fullPage: false }); // ファーストビュー（鮮明）
    await page.screenshot({ path: fullPath, fullPage: true });   // 全体（構造）
    const title = (await page.title() || '').slice(0, 200);
    return { status: resp ? resp.status() : null, finalUrl: redactUrl(page.url()), title };
  } finally {
    await page.close();
  }
}

const userDataDir = await mkdtemp(path.join(os.tmpdir(), 'hp-shot-'));
const browser = await puppeteer.launch({
  executablePath: CHROME,
  headless: 'new',
  userDataDir,
  args: ['--disable-gpu', '--hide-scrollbars', '--disable-dev-shm-usage',
         '--disable-background-networking', '--disable-sync'],
});
try {
  await mkdir(outdir, { recursive: true });
  const pcFold = outPath('pc-fold');
  const pcFull = outPath('pc-full');
  const spFold = outPath('sp-fold');
  const spFull = outPath('sp-full');
  const pc = await shot(browser, { width: 1280, height: 900, dpr: 1, mobile: false }, pcFold, pcFull);
  const sp = await shot(browser, { width: 390, height: 844, dpr: 2, mobile: true }, spFold, spFull);
  const size = p => { try { return statSync(p).size; } catch { return 0; } };
  console.log(JSON.stringify({
    ok: true, url: redactUrl(url), finalUrl: pc.finalUrl, status: pc.status, title: pc.title,
    pc: { fold: pcFold, full: pcFull, foldBytes: size(pcFold), fullBytes: size(pcFull) },
    sp: { fold: spFold, full: spFull, foldBytes: size(spFold), fullBytes: size(spFull) },
  }));
} catch (e) {
  console.error('shot failed:', (e && e.message ? e.message : String(e)).split('\n')[0]);
  process.exitCode = 1;
} finally {
  await browser.close();
  await rm(userDataDir, { recursive: true, force: true }).catch(() => {});
}
