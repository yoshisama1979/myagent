"""共有ヘルパー：`.env` から必要なキーだけを読む。

なぜ共有にするか
  同じ 24 行の実装が `gmail-fetch.py` と `calendar-fetch.py` に**1文字違わず**重複しており、
  片方だけ直すと静かに食い違う形になっていた（[[rules/refactoring.md]] §6「不整合の芽」）。
  .env を読むスクリプトは 2026-08-11 時点で 11 本あり、書き方が3系統に分かれている。
  本モジュールはその収束先＝**新しく .env を読むときは必ずここを使う**。

規約（gmail-fetch.py / calendar-fetch.py の既存実装をそのまま持ち上げたもの＝挙動不変）
  - `.env` 全体を環境に流し込まない（`source` しない）。**要求されたキーだけ**を返す。
  - 空行・`#` で始まる行・`=` を含まない行は無視する。
  - キーの前後の空白は無視。値の前後の空白は落とす。
  - 値全体が `"` または `'` で囲まれていれば、その1組だけ外す。
  - 同じキーが複数あれば**最初の1つ**を採用する。
  - ファイルが無い／キーが無ければ**空文字**を返す（例外にしない＝呼び出し側が既定値を決める）。
  - 値は絶対にログ・例外メッセージへ出さない（呼び出し側も同様）。

⚠️ `.env` のパスは**このファイルの位置から絶対パスで解決**する。相対パスで開くと、
   cron のように作業ディレクトリが違う環境で黙って読めなくなる（実在の潜在バグ＝`gsc-fetch.py`）。

利用中（2026-08-11 時点・8本）
  gmail-fetch / calendar-fetch / gsc-fetch / ga4-fetch / ads-fetch / clarity-fetch /
  office-forest-fetch / chatwork-fetch

**あえて移していないもの（規約が違う＝移すと静かに挙動が変わる）**
  - `slack-poll.py`／`slack-listen.py`：同じキーが複数あるとき**最後の定義**を採る
    （`slack.sh` と揃えた意図的な仕様）。本モジュールは**最初の定義**を採るため、
    移すと重複キーのある .env で別の値を掴む。移すなら「最後を採る」選択肢を足すか、
    先に .env 側の重複を無くしてから。
  - `wp-draft.py`：環境変数を先に見る（`os.environ.get(key) or ...`）。移すこと自体は可能だが
    回帰テストが無いため、テストを用意してからにする。
  - shell 側（`slack.sh`・`hana-api.sh`・`hp-audit.sh`・`mailbox.sh`・`office-beacon.sh`）：
    言語が違うため本モジュールでは吸収できない。共通化するなら別途 shell 用ヘルパーが要る。

触ったら必ず流すこと：bash bin/test-env.sh
"""

from pathlib import Path

PROJ = Path(__file__).resolve().parent.parent
ENV_FILE = PROJ / ".env"


def env_value(key: str, env_file: Path = None) -> str:
    """`.env` から `key` の値を返す。無ければ空文字（秘密値はログに出さない）。"""
    path = Path(env_file) if env_file is not None else ENV_FILE
    if not path.is_file():
        return ""
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k.strip() != key:
            continue
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        return v
    return ""
