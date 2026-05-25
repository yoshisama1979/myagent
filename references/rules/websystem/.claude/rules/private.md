# 環境固有の設定メモ

## Pythonの実行方法

このプロジェクトはWSL上で動作しており、シェル環境はGit Bash on Windows（platform: win32）です。

- `python3` / `conda` はGit BashおよびWSL bashから直接呼び出せません
- Pythonが必要な場合は **PowerShell経由** で実行してください

### 使用可能なconda環境

```
powershell -Command "conda env list"
```

| 環境名 | パス |
|---|---|
| base | C:\ProgramData\anaconda3 |
| my_env | C:\ProgramData\anaconda3\envs\my_env |
| marukoma | C:\Users\yoshi\.conda\envs\marukoma |
| myenv_py39 | C:\Users\yoshi\.conda\envs\myenv_py39 |
| task-orchestrator | C:\Users\yoshi\.conda\envs\task-orchestrator |

### 実行例

```bash
# スクリプト実行
powershell -Command "conda run -n base python -c 'print(\"hello\")'"

# ファイル実行
powershell -Command "conda run -n base python C:/path/to/script.py"
```

### 注意事項

- `cmd /c "..."` はUNCパス（`\\wsl.localhost\...`）から起動するとエラーになります
- `wsl -e bash -c "conda ..."` もcondaが見つからずエラーになります
- PowerShell経由が唯一の安定した方法です

### うまく動かない場合

上記の手順でも実行に失敗する場合は、推測で進めず原因を調査してから対処すること。
具体的には以下を確認する：

- エラーメッセージ（特にエンコード関連・パス関連）
- 利用しているシェル（Git Bash / WSL / PowerShell）と conda の相性
- conda 環境のアクティベート状態（`conda info --envs` で確認）
- 必要に応じて conda の python 実行ファイルを直接呼び出す代替手段を検討する
  - 例：`& "C:\ProgramData\anaconda3\python.exe" ...`

恒久的に実行方法を変更した場合は、この `private.md` の例を更新してナレッジを残すこと。
