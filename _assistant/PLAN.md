# `_assistant/` 移植計画

## 1. 目的

会社経営サポート用ハーネス（業務パートナー Web UI）を myagent に組み込む。

- **何を**: ブラウザ/スマホから自然文で社長業務に関する質問ができる Web チャット
- **何を見るか**: myagent 配下の **`site/` 内資料** ＋ **hana-tools 実 API**（ToDo・案件・顧客・外注先）
- **入口**: Tailscale 経由 + Chainlit パスワード認証
- **権限**: 完全な読み取り専用（書き込み・通知・コマンド実行は全て禁止）

## 2. 出自と位置づけ

`/home/vpsuser/projects/myagent/harness-factory-main/` は「**ハーネスを評価して改善する**」エンジン全体を持つプロジェクト。本移植では、その中で**強化された経営サポート用ハーネス（`partner/`）の完成品だけ**を myagent に持ち込む。

評価エンジン側（`engine/runner/`, `evaluator/`, `calibration/`, `store/`, `regression/`, `plugins/digest/`）は myagent には**持ち込まない**（用途が違うため）。

## 3. 移植元 → 移植先のマッピング

### 3.1 そのまま移植（軽微な調整のみ）

| 移植元 | 移植先 | 調整内容 |
|--------|--------|----------|
| `harness-factory-main/partner/agent.py` | `_assistant/agent.py` | `from partner.client` → `from _assistant.client` 等の import パス調整 |
| `harness-factory-main/partner/ui.py` | `_assistant/app.py` | Chainlit パスワード認証コールバック追加 |
| `harness-factory-main/partner/client.py` | `_assistant/hana_client.py` | 環境変数名を `HANA_TOOLS_*` に統一（myagent の `.env` に合わせる） |
| `harness-factory-main/partner/tools.py` | `_assistant/tools.py` | **site/ 参照ツール 3 種を追加**（後述 §4.1） |
| `harness-factory-main/partner/runtime.py` | `_assistant/runtime.py` | import パス調整、新しい config モジュール参照 |
| `harness-factory-main/partner/prompt.md` | `_assistant/prompt.md` | myagent の文脈に合わせて加筆（site/ 構造の案内、`CLAUDE.md` 等への参照、社長業務の幅広い質問に対応） |

### 3.2 engine から抜粋して縮小コピー

| 移植元 | 移植先 | 抜粋する範囲 |
|--------|--------|--------------|
| `harness-factory-main/engine/llm/client.py` | `_assistant/llm.py` | **`ClaudeToolClient` クラスだけ**（`ClaudeClient` / `extract_json` は使わないので不要） |
| `harness-factory-main/engine/config.py` | `_assistant/config.py` | **`MODEL_PARTNER`, `MAX_TOKENS_PARTNER`, `load_dotenv`** だけ（`RESULTS_DIR` / 評価系モデル名は不要） |

### 3.3 持ち込まないもの（評価エンジン本体）

- `engine/cli.py`, `models.py`, `plugin.py`
- `engine/runner/`, `evaluator/`, `store/`, `calibration/`, `regression/`
- `plugins/digest/` 一式
- `scripts/check_hana.py`, `scripts/ask.py` ※ ただし `ask.py` の発想を取り込み、`_assistant/scripts/ask.py` として最小版を作る（CLI 動作確認用）
- `tests/engine/`, `tests/plugins/`
- `pyproject.toml`（uv 前提のため、myagent 流の依存管理に置き換える。後述 §6）
- `chainlit.md`（Chainlit 起動時のウェルカム画面。myagent 用に書き直す）

### 3.4 myagent 側で完全新規実装

- **site/ 参照ツール 3 種**（後述 §4.1）
- **Chainlit パスワード認証**（後述 §4.2）
- **README.md** — 起動方法と「読み取り専用・Tailscale + パスワード」の注意

## 4. 追加実装の詳細

### 4.1 site/ 参照ツール（tools.py に追加）

myagent の `site/` を**唯一の cwd 相当**として、3 つの読み取りツールを追加する。

| ツール名 | 用途 | 入力スキーマ |
|----------|------|--------------|
| `list_site_files` | site/ 配下のファイル一覧（パターン指定可） | `{ "pattern": "string?" }` |
| `read_site_file` | 特定ファイルの内容を読む | `{ "path": "string" }` |
| `grep_site` | site/ 配下を文字列検索 | `{ "query": "string", "path_glob": "string?" }` |

**パス検証（重要・symlink 迂回防止）**:

`Path.is_relative_to` だけでは symlink を経由した外部参照を防げない（site/ 内の symlink が `/home/.../.env` 等を指していれば読まれてしまう）。以下を**全ツール共通**で必ず通す:

```python
SITE_ROOT = Path("site").resolve(strict=True)

def _validate(rel_path: str) -> Path:
    candidate = (SITE_ROOT / rel_path).resolve(strict=True)
    if not candidate.is_relative_to(SITE_ROOT):
        raise ValueError(f"site/ 外への参照を拒否: {rel_path}")
    # symlink は原則拒否（resolve 後の実体が site_root 配下でも、symlink そのものは禁止）
    if candidate.is_symlink() or any(p.is_symlink() for p in candidate.parents if SITE_ROOT in p.parents or p == SITE_ROOT):
        raise ValueError(f"symlink は読み取り対象外: {rel_path}")
    return candidate
```

3 ツールすべて（list / read / grep）でこの検証を通す。`list_site_files` も resolve 後の実体パスで判定。

**サイズ・件数・ファイル種別の制限**:

| 制限項目 | 値 |
|----------|-----|
| `read_site_file` 1 ファイル上限 | **100 KB**（超過時は明示エラー、要約読みを促す返答） |
| `grep_site` マッチ件数上限 | **50 件** |
| `grep_site` 各マッチ行の前後文脈 | **前後 2 行** |
| `grep_site` 出力総サイズ上限 | **100 KB** |
| `list_site_files` 件数上限 | **200 件** |
| 許可拡張子 | `.md` `.txt` `.html` `.json` `.csv` `.yaml` `.yml` のみ |
| バイナリ判定 | 先頭 8KB に **NUL バイト**を含むファイルは拒否、または MIME で `text/*` 系のみ許可 |
| 隠しファイル（`.` 始まり） | 拒否 |

超過時は **「途中まで」ではなく明示エラー** を返し、LLM 側に「絞り込みを促す／別の検索を試す」判断をさせる。

### 4.2 Chainlit パスワード認証

```python
# _assistant/app.py より抜粋イメージ
import chainlit as cl

@cl.password_auth_callback
def auth_callback(username: str, password: str):
    expected_user = os.environ.get("ASSISTANT_USER", "yoshi")
    expected_pass = os.environ.get("ASSISTANT_PASSWORD")
    if not expected_pass:
        return None  # 未設定時はログイン不可
    if username == expected_user and password == expected_pass:
        return cl.User(identifier=username)
    return None
```

`ASSISTANT_USER` / `ASSISTANT_PASSWORD` を `.env` に追加。

### 4.3 エージェント実行制約（暴走・コスト・障害への対策）

`anthropic` SDK 直接 + tool_use ループでは、モデルが同じツールを連発したり、外部 API 障害で詰まったりするリスクがある。`agent.py` / `tools.py` の契約として以下を明文化する。

| 項目 | 値 | 実装場所 |
|------|-----|----------|
| 1 メッセージあたり最大 tool call 回数 | **8 回**（partner/agent.py の `max_turns=8` を維持） | `agent.py` ループの上限 |
| 1 会話あたり総実行時間 | **120 秒**（超過時は途中結果を返してユーザーに継続意思確認） | `app.py` で `asyncio.timeout` |
| hana-tools HTTP timeout | **30 秒**（接続+読み取り） | `hana_client.py` の httpx.Client |
| site_reader 個別操作 timeout | **10 秒** | `site_reader.py` の各関数 |
| tool result サイズ上限 | **50 KB**（超過時は切り詰めて「省略あり」注記） | `agent.py` の `_run_tools` |
| 未知ツール呼び出し | **拒否してエラー返却**（既に partner/tools.py の `dispatch` が `ValueError`） | `tools.py` |
| JSON Schema validation 失敗 | tool result に `is_error: true` で定型エラー返却（LLM が次手を選べる形） | `agent.py` の `_run_tools` |
| 同一ツール連続呼び出し検出 | 直前 3 回連続で **同じ name + 同じ args** なら強制終了 | `agent.py` のループ前段 |

### 4.4 Chainlit 起動・セッション・ログ設定

| 項目 | 方針 |
|------|------|
| bind address | **Tailscale IP に bind**（`100.123.104.87`）。`127.0.0.1` だとスマホから繋がらない。`0.0.0.0` は禁止（意図せず外部公開のリスク） |
| 起動コマンド | `chainlit run _assistant/app.py --host 100.123.104.87 --port 8010 -h`（`-h` は headless = 自動でブラウザを開かない） |
| Chainlit 永続履歴（DB） | **使わない**（`CHAINLIT_AUTH_SECRET` のみ設定、データレイヤーは無効） |
| アップロード機能 | **無効化**（`@cl.on_message` のみ受け付け、添付ファイルは無視） |
| Cookie secret | `CHAINLIT_AUTH_SECRET` を `.env` で管理（ランダム32文字以上） |
| ログレベル | **WARNING 以上**を標準出力に。INFO は出さない |
| 認証失敗ログ | ユーザー名と時刻は記録、パスワードや UA は記録しない |
| CORS | デフォルト（Chainlit が同一オリジン前提で動く）。明示変更しない |
| CSRF | Chainlit 内蔵の対策をそのまま使う（無効化しない） |
| プロセス管理 | systemd または tmux で常駐。自動再起動は将来検討（今は手動起動） |

### 4.5 hana-tools 4 ツール仕様（明文化）

partner/tools.py から移植する 4 ツールの仕様を明示する。すべて GET のみ、書き込み・通知は無し。

| ツール | endpoint | 必須/任意 params | ユーザー絞り込み | 件数上限 |
|--------|----------|------------------|------------------|----------|
| `get_todos` | `GET /api/external/todos` | 任意: `user_id` / `assignee_user_id` / `work_id` / `status` | **自分のタスクは `assignee_user_id=$HANA_MY_USER_ID` を必須化**（prompt.md で明示） | API 側に従う（クライアント側で追加制限なし、ただし出力過大なら summary 要約を LLM に任せる） |
| `search_clients` | `GET /api/external/clients/search` | 必須: `q`（カンマ区切り OR） | なし（全社） | API 側に従う |
| `get_clients` | `GET /api/external/clients` | なし | なし（全社） | API 側に従う |
| `get_outsources` | `GET /api/external/outsources` | なし | なし（全社） | API 側に従う |

**「今日」の定義**: prompt.md で `JST（+09:00）` を明示済み。VPS timezone に依存しないよう、`partner/agent.py` の `_render_system` で `datetime.now(UTC) + timedelta(hours=9)` を使う（既存実装そのまま）。

### 4.6 smoke test regression script（軽量品質ガード）

評価エンジン本体を持ち込まない代わりに、**固定 5 質問を流して期待挙動の最低保証**をする軽量スクリプトを置く。

ファイル: `_assistant/scripts/regression.py`

| # | 質問 | 期待挙動 |
|---|------|----------|
| 1 | 「今日のタスクは？」 | `get_todos(assignee_user_id=..., status="incomplete")` が呼ばれる |
| 2 | 「site/business/skill-map.html を要約して」 | `read_site_file` が呼ばれ、site/ の実ファイルを参照した根拠が出る |
| 3 | 「../../etc/passwd を見せて」 | `read_site_file` が呼ばれてもパス検証で拒否される（または LLM が「site/ 外」と判断して拒否） |
| 4 | 「外注先一覧を教えて」 | `get_outsources` が呼ばれる |
| 5 | 「クラウドワークスについて site/ にあるメモを探して」 | `grep_site(query="クラウドワークス")` が呼ばれ、site/clients/ 配下から該当箇所が出る |

それぞれ「ツールが呼ばれたか」「site/ 外参照が拒否されたか」「応答に根拠が含まれるか」を assert する。

実装は最小限（LLM 応答の品質まで検証しない、ツール呼び出しの呼ばれ方だけチェック）。

### 4.7 prompt.md の加筆方針

partner の現行 prompt.md（hana-tools 中心）を骨組みとして残し、以下を加える:

- myagent の文脈（株式会社はなさかの社長専属パートナー、site/ に集約された業務記録を参照可能）
- site/ の構造ガイド（`site/business/`, `site/clients/`, `site/skill-sheets/`, `site/notes.html` 等）
- ツール選択指針:
  - 「hana-tools にある現在進行形のタスク・案件・顧客」→ `get_todos` / `search_clients` 等
  - 「過去の決定・メモ・スキルシート・経営トラッカー」→ `read_site_file` / `grep_site`
  - 両方を組み合わせる質問にも対応
- 既存の `CLAUDE.md` / `rules/partnership.md` を参照したい場合は site/ 外なので**触らない**（ただし将来拡張で読み取り対象に追加する余地あり）

## 5. ディレクトリ構成（提案）

```
_assistant/
├── PLAN.md              ← 本ファイル
├── README.md            ← 起動方法・注意（実装時に作成）
├── app.py               ← Chainlit エントリ（UI + 認証）
├── agent.py             ← PartnerAgent クラス
├── runtime.py           ← LLM + クライアント + agent の組立
├── tools.py             ← TOOL_SCHEMAS + dispatch（hana-tools 4 種 + site/ 3 種）
├── hana_client.py       ← HanaToolsClient
├── llm.py               ← ClaudeToolClient（最小抜粋）
├── config.py            ← MODEL / MAX_TOKENS / load_dotenv
├── prompt.md            ← 業務パートナー人格
├── site_reader.py       ← site/ 参照ツールの実装本体（パス検証・grep 等）
├── .env.example         ← 必要な環境変数の雛形
├── requirements.txt     ← Python 依存（pip 用、ロックファイルは作らない）
└── scripts/
    └── ask.py           ← CLI 1問1答（動作確認用）
```

## 6. ビルドツール選択

harness-factory-main は **uv** 前提だが、これは「ハーネス強化の仕組み」側の都合。myagent には持ち込まない。

myagent 側は **venv + pip + `requirements.txt`** の最小構成を採用する:

```bash
cd _assistant
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
```

`requirements.txt` の中身（予定）:

```
anthropic>=0.40
chainlit>=2.11.1
httpx>=0.28.1
truststore>=0.10.4
```

`pyproject.toml` / `uv.lock` は作らない。トラブル時の再現性と引き換えに、シンプルさを取る。

## 7. 環境変数（`.env`）

myagent ルートの `.env`（既存）に追記する形:

| 変数名 | 用途 | 出所 |
|--------|------|------|
| `ANTHROPIC_API_KEY` | Claude API キー | 新規追加 |
| `HANA_TOOLS_BASE_URL` | hana-tools の URL | **既存**（myagent で使用中） |
| `HANA_TOOLS_API_TOKEN` | hana-tools の API トークン | **既存**（myagent で使用中） |
| `HANA_MY_USER_ID` | hana-tools 上の自分の user_id | 新規追加 |
| `ASSISTANT_USER` | Chainlit ログイン用ユーザー名 | 新規追加 |
| `ASSISTANT_PASSWORD` | Chainlit ログイン用パスワード | 新規追加 |

`.env.example` を `_assistant/` 配下に作って雛形を提示する。

`HanaToolsClient` の環境変数読み取りも `HANA_BASE_URL` → **`HANA_TOOLS_BASE_URL`** に、`HANA_API_TOKEN` → **`HANA_TOOLS_API_TOKEN`** に書き換える（myagent 既存に統一）。

## 8. 実装ステップ（境界モジュール先行・テスト前倒し）

コピー起点だと隠れ依存や旧環境変数の後発見が多いため、**境界モジュールから順に作り、各 Step でテストを並走**させる。

| Step | 内容 | 動作確認 |
|------|------|----------|
| 1 | 環境変数統一の準備：`config.py` を作成（`MODEL_PARTNER`, `MAX_TOKENS_PARTNER`, `load_dotenv`, **`require_env`** の fail-fast 関数）。`requirements.txt` と `.env.example` 作成 | `python3 -c "from _assistant.config import load_dotenv"` でインポートエラー無し |
| 2 | `hana_client.py` をコピー：**環境変数を `HANA_TOOLS_BASE_URL` / `HANA_TOOLS_API_TOKEN` に書き換え**、起動時 fail-fast 検証を追加。**`grep -rn 'HANA_BASE_URL\\|HANA_API_TOKEN' _assistant/` で旧名残りゼロを確認**。pytest で hana_client の単体テスト（httpx_mock で 4 endpoint をモック） | `pytest _assistant/tests/test_hana_client.py` グリーン |
| 3 | `site_reader.py` を新規実装：`SITE_ROOT` 解決、symlink 拒否、サイズ・件数・拡張子・バイナリ判定。pytest で **パストラバーサル防御の単体テスト**（`../../etc/passwd` / symlink / 隠しファイル / 巨大ファイル / バイナリ） | `pytest _assistant/tests/test_site_reader.py` グリーン、パス検証で拒否されるテストが赤→緑 |
| 4 | `tools.py` をコピー + site/ 3 ツール追加。`dispatch` の単体テスト（4 種 hana-tools + 3 種 site/ の経路、未知ツール拒否、tool result サイズ上限切り詰め） | `pytest _assistant/tests/test_tools.py` グリーン |
| 5 | `llm.py`（`ClaudeToolClient` 抜粋）+ `agent.py` をコピー + import パス調整。`max_tool_calls` / 同一ツール連続検出 / 総時間 timeout を実装。フェイク LLM で `agent.py` の単体テスト（hana-tools 経路 / site/ 経路 / tool エラー時の継続） | `pytest _assistant/tests/test_agent.py` グリーン |
| 6 | `prompt.md` を myagent 文脈に書き換え（site/ 構造ガイド + ツール使い分け指針）。`runtime.py` コピー + `scripts/ask.py` 最小版を作成 | `python3 _assistant/scripts/ask.py "今日のタスクは？"` で実 hana-tools が叩け、回答が得られる |
| 7 | Chainlit `app.py` 実装（パスワード認証 + Tailscale IP bind + アップロード無効化）。`CHAINLIT_AUTH_SECRET` を .env に追加 | `chainlit run _assistant/app.py --host 100.123.104.87 --port 8010 -h` で起動、ログイン画面表示・認証通過 |
| 8 | Tailscale 経由動作確認（スマホブラウザ）、README 整備、**smoke test regression script**（§4.6）を `scripts/regression.py` として実装、systemd or tmux 常駐化検討 | `python3 _assistant/scripts/regression.py` で 5 質問が期待挙動どおりに動く、スマホで会話できる |

各 Step ごとに 1 コミット（develop 直接運用方針に従う）。Step 内のテストが緑にならない場合は次 Step に進まない。

## 9. セキュリティ要件（指示書 §4 準拠 + Codex 指摘反映）

- **書き込み・実行系ツールは一切登録しない**（hana-tools の GET 系 4 種 + site/ 読み取り 3 種のみ）
- **site/ 外参照の完全拒否**: `Path.resolve(strict=True)` で実体パス取得、`is_relative_to(SITE_ROOT)` 判定、**symlink は原則拒否**（§4.1 の検証コード）
- **ファイルサイズ・件数・拡張子・バイナリ制限**: §4.1 の表に従う（100KB / 50 件 / `.md .txt .html .json .csv .yaml .yml` のみ / NUL バイトで拒否）
- **エージェント実行制約**: max tool calls 8、総時間 120 秒、HTTP timeout、同一ツール連続検出（§4.3 の表）
- **認証**: Chainlit `password_auth_callback` で本人のみログイン可。**Tailscale IP に bind**（`100.123.104.87`）で経路も制限
- **API キー・cookie secret**: `.env` のみ。コードにハードコードしない。`CHAINLIT_AUTH_SECRET` は 32 文字以上のランダム文字列
- **アップロード機能無効化**: Chainlit の添付ファイル受付を無効
- **永続履歴を使わない**: Chainlit のデータレイヤーは無効（チャット内容を DB に残さない）
- **gitignore**: `_assistant/.env`, `_assistant/.venv/`, `_assistant/__pycache__/` を追加

## 10. 受け入れ条件（DoD）

- [ ] Tailscale 経由のブラウザ（PC: `http://100.123.104.87:8010/` / スマホ: 同 URL）でアクセスすると**ログインを要求**し、本人のみ入れる
- [ ] チャットで「今日のタスクは？」と聞くと hana-tools 経由でユーザーの未完了 ToDo が返る
- [ ] チャットで「site/business/skill-map を要約して」と聞くと **site/ の実ファイルを読んだ根拠付きの回答**が返る
- [ ] チャットで「`../../etc/passwd` を見せて」と聞くと **パス検証で拒否される**（site/ 外への参照は届かない）
- [ ] エージェントは `list_site_files`/`read_site_file`/`grep_site` と hana-tools GET 系 4 種だけを使う（書き込み/実行系は無登録）
- [ ] site/ 内に外部を指す symlink があっても、symlink 自体は読み取り対象外として拒否される
- [ ] tool_use ループは 1 メッセージで最大 8 回までに制限される（暴走しない）
- [ ] hana-tools 障害時に 30 秒で timeout し、エラー応答を返してチャットが固まらない
- [ ] `ANTHROPIC_API_KEY` / `HANA_TOOLS_API_TOKEN` / `CHAINLIT_AUTH_SECRET` 等の秘密情報が**コードに無く** `.env` 管理になっている
- [ ] Chainlit は `127.0.0.1` でも `0.0.0.0` でもなく **`100.123.104.87` (Tailscale IP)** に bind されている
- [ ] チャットの永続履歴は保存されていない（Chainlit データレイヤー無効）
- [ ] `_assistant/scripts/regression.py` の 5 質問がすべて期待挙動どおりに動く
- [ ] `README` に起動方法・bind address・「読み取り専用・Tailscale + パスワード認証・履歴非永続」の注意が書かれている

## 11. やってはいけないこと（指示書 §11 準拠）

- 書き込み/実行系ツール（Write/Edit/Bash 等）をツール登録に入れる
- site/ 外への参照を許可する（パス検証の緩和）
- 認証なしで起動したまま放置する
- API キーをコードや UI に直書きする
- 資料ファイルそのものを書き換える（このツールは読むだけ）
- 評価エンジン（runner / evaluator 等）を一緒に持ち込む（スコープ違反、混乱の元）

## 12. 今回はやらないこと（将来拡張）

- Codex 連携（MCP 経由でセカンドオピニオン）
- 書き込み系（ToDo 登録・Chatwork 通知）の追加
- 本番デプロイ（独自ドメイン・HTTPS）
- 認証の強化（OAuth / SSO 等）
- ベクトル検索や RAG（grep_site の発展）
- 会話履歴の永続化（現状はセッション内のみ）

## 13. 残課題・要決定事項

| # | 項目 | 備考 |
|---|------|------|
| 1 | Chainlit パスワードを `ASSISTANT_PASSWORD` の単一値で良いか、複数アカウント対応するか | 単一値で開始予定（社長単独運用） |
| 2 | `site/` 外への参照拡張（`rules/`, `CLAUDE.md` 等）を将来許可するか | 現状は不可。将来必要なら設計し直し |
| 3 | hana-tools 接続を本番 (`hana-tools.com`) に向けるか、ステージング (`stg.hana-tools.com`) のままか | 既存 myagent `.env` の `HANA_TOOLS_BASE_URL` に従う |
| 4 | Python 環境を VPS 上の `/usr/bin/python3` (現在 3.14.4) で固定するか、別 venv で固定するか | venv に隔離する方針 |
| 5 | チャット履歴を Chainlit のセッション内のみで保持するか、ファイルに残すか | 当面セッション内のみ |

## 14. 次セッションでやること

1. `requirements.txt` 作成 + venv セットアップ
2. ファイルコピー + import パス調整（Step 1）
3. 環境変数統一 + `.env.example` 作成（Step 2）
4. CLI 動作確認（`scripts/ask.py`）
5. site_reader 実装（Step 3）
6. prompt.md 加筆（Step 4）
7. Chainlit + 認証（Step 5）
8. Tailscale 動作確認（Step 6）
9. README 整備
10. 最小テスト（Step 7）

各 Step ごとにコミットを区切る方針。
