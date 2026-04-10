hana-tools経由でChatworkにメッセージを送信します。

ユーザーの指示からメッセージ内容を整理し、送信前に必ず確認してください。

利用可能なChatwork装飾タグ:
- `[info]...[/info]` — 情報ボックス
- `[info][title]タイトル[/title]本文[/info]` — タイトル付き情報ボックス
- `[hr]` — 水平線
- `[To:アカウントID]` — メンション

確認後、以下の形式で実行してください:
```
bash bin/hana-api.sh chatwork '{"room_id":"ルームID","message":"メッセージ"}'
```

room_idが未指定の場合はサーバーのデフォルト値が使われます。

送信結果を表示してください。
