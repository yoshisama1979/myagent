"""業務パートナーへの 1 問 1 答 CLI（動作確認用）。

使い方:
  cd /home/vpsuser/projects/myagent
  _assistant/.venv/bin/python -m _assistant.scripts.ask "今日のタスクは？"

実 LLM と実 hana-tools API を叩くので、`.env` に `ANTHROPIC_API_KEY` /
`HANA_TOOLS_API_TOKEN` 等が設定済みである必要がある（未設定なら fail-fast）。
"""

from __future__ import annotations

import sys

from _assistant.runtime import build_agent


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(
            'usage: python -m _assistant.scripts.ask "<question>"',
            file=sys.stderr,
        )
        return 2
    question = " ".join(argv[1:])
    agent = build_agent()
    print(agent.ask(question))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
