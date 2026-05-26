#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Google Sheets API ラッパースクリプト

請求管理スプレッドシート等のGoogle Sheetsを Service Account経由で読み取る。

認証:
  /home/vpsuser/projects/myagent/data/secrets/hana-sheets-key.json
  （Service AccountのJSON鍵ファイル、Gitignore対象）

使い方:
  python bin/sheets.py info <sheet_id>
      → スプレッドシートのタイトル、シート一覧、各シートのサイズを出力

  python bin/sheets.py read <sheet_id> <range>
      → 指定範囲のセル値を TSV 形式で標準出力
      → 例: python bin/sheets.py read 1AbC... "請求一覧!A1:H100"

  python bin/sheets.py read <sheet_id> <range> --json
      → JSON形式で出力（2次元配列）

事前準備:
  1. GCPでService Accountを作成、JSON鍵をダウンロード
  2. 鍵を data/secrets/hana-sheets-key.json に配置（chmod 600）
  3. 対象スプレッドシートをService Accountのメールアドレスに「閲覧者」共有
  4. python3 -c "from google.oauth2.service_account import Credentials" で動作確認
"""

import sys
import json
from pathlib import Path

from google.oauth2.service_account import Credentials
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError


KEY_FILE = Path(__file__).resolve().parent.parent / 'data' / 'secrets' / 'hana-sheets-key.json'
SCOPES = ['https://www.googleapis.com/auth/spreadsheets.readonly']


def get_service():
    """Sheets API のサービスオブジェクトを返す"""
    if not KEY_FILE.exists():
        print(f'エラー: 鍵ファイルが見つかりません: {KEY_FILE}', file=sys.stderr)
        sys.exit(1)
    creds = Credentials.from_service_account_file(str(KEY_FILE), scopes=SCOPES)
    return build('sheets', 'v4', credentials=creds, cache_discovery=False)


def cmd_info(sheet_id: str):
    """スプレッドシートのメタ情報を出力"""
    service = get_service()
    try:
        meta = service.spreadsheets().get(spreadsheetId=sheet_id).execute()
    except HttpError as e:
        print(f'API エラー: {e}', file=sys.stderr)
        sys.exit(1)

    print(f'タイトル: {meta.get("properties", {}).get("title", "(no title)")}')
    print(f'スプレッドシートID: {sheet_id}')
    print(f'ロケール: {meta.get("properties", {}).get("locale", "—")}')
    print(f'タイムゾーン: {meta.get("properties", {}).get("timeZone", "—")}')
    print()
    print('シート一覧:')
    print(f'  {"sheet_id":>12} | {"行":>6} | {"列":>4} | シート名')
    print(f'  {"-"*12:>12}-+-{"-"*6:>6}-+-{"-"*4:>4}-+--------')
    for sheet in meta.get('sheets', []):
        props = sheet.get('properties', {})
        grid = props.get('gridProperties', {})
        sid = props.get('sheetId', 0)
        title = props.get('title', '')
        rows = grid.get('rowCount', 0)
        cols = grid.get('columnCount', 0)
        print(f'  {sid:>12} | {rows:>6} | {cols:>4} | {title}')


def cmd_read(sheet_id: str, range_a1: str, as_json: bool = False):
    """指定範囲を読み取り、TSV または JSON で出力"""
    service = get_service()
    try:
        result = service.spreadsheets().values().get(
            spreadsheetId=sheet_id,
            range=range_a1,
            valueRenderOption='UNFORMATTED_VALUE',
            dateTimeRenderOption='FORMATTED_STRING',
        ).execute()
    except HttpError as e:
        print(f'API エラー: {e}', file=sys.stderr)
        sys.exit(1)

    values = result.get('values', [])
    if as_json:
        print(json.dumps(values, ensure_ascii=False, indent=2))
    else:
        for row in values:
            print('\t'.join(str(v) for v in row))


def main():
    if len(sys.argv) < 3:
        print('使い方:')
        print('  python bin/sheets.py info <sheet_id>')
        print('  python bin/sheets.py read <sheet_id> <range>')
        print('  python bin/sheets.py read <sheet_id> <range> --json')
        sys.exit(1)

    cmd = sys.argv[1]
    sheet_id = sys.argv[2]

    if cmd == 'info':
        cmd_info(sheet_id)
    elif cmd == 'read':
        if len(sys.argv) < 4:
            print('使い方: python bin/sheets.py read <sheet_id> <range>', file=sys.stderr)
            sys.exit(1)
        range_a1 = sys.argv[3]
        as_json = '--json' in sys.argv
        cmd_read(sheet_id, range_a1, as_json)
    else:
        print(f'未知のコマンド: {cmd}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
