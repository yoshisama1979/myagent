# `_assistant/` — 経営サポート用業務パートナー

myagent プロジェクトに組み込まれた、社長専用の業務サポート AI。
ブラウザ／スマホから自然文で質問でき、`site/` 配下の業務記録と hana-tools の実データを
横断して答える **読み取り専用** のエージェントです。

- **対応モデル**: Claude（`claude-sonnet-4-6`、`_assistant/config.py` で変更可）
- **入口**: Tailscale 経由 + パスワード認証（PC・スマホブラウザ）
- **権限**: 読み取り専用（site/ 配下と hana-tools の GET 系のみ。書き込み・通知・実行は不可）
- **永続化**: なし（会話履歴はプロセス内メモリ、再起動でリセット）

## ディレクトリ構成

```
_assistant/
├── PLAN.md              移植計画（Codex レビュー反映済み）
├── README.md            このファイル
├── app.py               Web UI（FastAPI + Jinja2 + cookie session + CSRF）
├── agent.py             tool_use ループ（max_calls/timeout/同一連続/サイズ切詰）
├── runtime.py           build_agent() で実 LLM + 実 client + dispatcher を組み立て
├── tools.py             TOOL_SCHEMAS (7 種) + make_dispatcher
├── hana_client.py       hana-tools 読み取り専用クライアント (4 メソッド)
├── site_reader.py       site/ 参照（list/read/grep、symlink・size・拡張子で守る）
├── llm.py               ClaudeToolClient（薄ラッパ）
├── config.py            定数・load_dotenv・require_env
├── prompt.md            業務パートナー人格 + ツール使い分け
├── requirements.txt     Python 依存（pip 用）
├── .env.example         必要な環境変数の雛形
├── templates/           Jinja2 テンプレ（base/login/chat）
├── static/style.css     UI スタイル
├── scripts/
│   ├── ask.py           CLI 1 問 1 答（動作確認）
│   └── regression.py    軽量品質ガード（固定 5 質問）
└── tests/               pytest（実 LLM/HTTP は叩かない）
```

## 初回セットアップ

VPS（Linux + Python 3.14）上で:

```bash
cd /home/vpsuser/projects/myagent

# venv を作る（python3.14-venv が必要。未導入なら sudo apt install python3.14-venv）
python3 -m venv _assistant/.venv

# 依存をインストール
_assistant/.venv/bin/pip install -r _assistant/requirements.txt

# .env を整備（プロジェクトルートの .env を使うか、_assistant/.env を別途置く）
# load_dotenv は _assistant/.env → ../.env の順で探す
cp _assistant/.env.example _assistant/.env
# エディタで実値を埋める：
#   ANTHROPIC_API_KEY=sk-ant-...
#   HANA_TOOLS_BASE_URL=https://stg.hana-tools.com
#   HANA_TOOLS_API_TOKEN=...
#   HANA_MY_USER_ID=（hana-tools 上のあなたの user_id）
#   ASSISTANT_USER=yoshi
#   ASSISTANT_PASSWORD=（強いランダム文字列）
#   ASSISTANT_SESSION_SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
```

## 動作確認（CLI）

実 API キーが揃ったら、まず CLI で 1 問 1 答が動くか確認:

```bash
cd /home/vpsuser/projects/myagent
_assistant/.venv/bin/python -m _assistant.scripts.ask "今日のタスクは？"
```

タスクが返ってくれば LLM + tool_use + hana-tools + site_reader まで通っています。

## 起動（Web UI）

**uvicorn を単一ワーカで起動**（`_chat_state` はプロセス内メモリ・複数ワーカでは履歴が分散するため必須）:

```bash
cd /home/vpsuser/projects/myagent
_assistant/.venv/bin/uvicorn _assistant.app:app \
    --host 100.123.104.87 \
    --port 8010 \
    --log-level warning \
    --workers 1
```

ブラウザから `http://100.123.104.87:8010/` にアクセス（Tailscale 経由のみ）。
ログイン後にチャットできます。

### bind 先について

| 値 | 用途 |
|---|---|
| `100.123.104.87` (Tailscale IP) | **推奨**。Tailscale 経由でのみアクセス可能 |
| `127.0.0.1` | VPS 内のみ。スマホから繋がらない |
| `0.0.0.0` | **禁止**。意図せずインターネット公開のリスク |

### systemd で常駐させる（任意）

`/etc/systemd/system/myagent-assistant.service`:

```ini
[Unit]
Description=myagent business partner assistant
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
User=vpsuser
WorkingDirectory=/home/vpsuser/projects/myagent
Environment="PATH=/home/vpsuser/projects/myagent/_assistant/.venv/bin"
ExecStart=/home/vpsuser/projects/myagent/_assistant/.venv/bin/uvicorn _assistant.app:app --host 100.123.104.87 --port 8010 --log-level warning --workers 1
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=read-only

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now myagent-assistant
sudo systemctl status myagent-assistant
```

## セキュリティ要点

| 項目 | 対策 |
|---|---|
| 認証 | `ASSISTANT_USER` / `ASSISTANT_PASSWORD`、`secrets.compare_digest` で定数時間比較 |
| セッション | cookie session（itsdangerous 署名）、`max_age=8h`、`same_site=lax`、ログイン成功時に再発行（session fixation 対策） |
| CSRF | 全 POST に hidden `csrf_token`（セッションごとに発行・照合） |
| ブルートフォース | クライアント IP ごとに 5 失敗で 60 秒 lockout |
| 永続化 | しない（プロセス内メモリのみ）。再起動で消える |
| アップロード | 不可（`<input type="file">` を置かない） |
| ツール | 読み取り専用 7 種のみ登録（site/ 3 + hana 4）。書き込み・実行系は無し |
| パス検証 | `resolve(strict=True)` + `is_relative_to(SITE_ROOT)` + symlink 拒否 + 拡張子ホワイトリスト |
| サイズ制限 | 1 ファイル 100KB、grep 総出力 100KB、grep ヒット 50 件、tool_result 50KB |
| エージェント | max 8 tool calls/会話、120 秒 timeout、同一ツール+引数 3 回連続で停止 |
| API キー | `.env` のみ、コードにハードコードなし |

## テスト

```bash
cd /home/vpsuser/projects/myagent
_assistant/.venv/bin/pytest _assistant/tests/ -v
```

実 LLM / 実 hana-tools は叩きません（`httpx.MockTransport` と `FakeLLM` / `FakeAgent` で代替）。

軽量品質ガード（実 LLM + 実 hana 叩き＝API キー必須）:

```bash
_assistant/.venv/bin/python -m _assistant.scripts.regression
```

## トラブルシュート

| 症状 | 確認 |
|---|---|
| `ModuleNotFoundError: _assistant` | プロジェクトルート（`/home/vpsuser/projects/myagent`）から実行しているか |
| `必須環境変数 ... が未設定です` | `.env` のキー名・実値を確認。`_assistant/.env` を作るか、ルート `.env` に書く |
| 起動時に `chainlit` 関連エラー | Chainlit は不採用。FastAPI 構成（このファイル参照） |
| 起動はするがブラウザで繋がらない | `--host 100.123.104.87`（Tailscale IP）か、Tailscale が VPS で動いているか |
| ログインできない | パスワード正しいか、`/var/log/syslog` で uvicorn の出力を確認 |
| LLM 応答が遅い | hana-tools API が遅い可能性。`HANA_HTTP_TIMEOUT_SECONDS=30` 内で応答するか |

## 関連ドキュメント

- 全体設計と判断履歴: [PLAN.md](PLAN.md)
- myagent プロジェクト規約: [../CLAUDE.md](../CLAUDE.md)
