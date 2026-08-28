CLAUDE.md に定義されたコンテナ化ポリシーに従ってください。

以下のテスト失敗を分析し、テストスクリプトを修正してください。
エラーの根本原因を特定し、最小限の変更で問題を解決してください。

修正対象は**テストスクリプトのみ**です。Dockerfile や docker-compose.yml の変更が必要と判断した場合でも、テストスクリプトの修正のみ行うこと。

よくある問題と対処法:
- 待機タイムアウトが短すぎる → コンテナ起動待ちループのタイムアウトを延ばす
- エンドポイント URL やポート番号の誤り → docker-compose.yml の ports: を確認して正しいポートを使う
- HTTP ステータスコードの誤認識 → `curl -s -o /dev/null -w '%{http_code}'` パターンで正確に取得する
- コンテナ名の誤り → `docker compose ps` 出力を参考に正確なコンテナ名を使う
- DB ログの起動メッセージ検索が失敗 → `docker logs | grep "ready to accept"` は禁止。`pg_isready` や SQL（`pg_is_in_recovery()` 等）で代替すること
- `psql` が `role "postgres" does not exist` で失敗 / SQL チェックの結果が軒並み空文字 → 接続ユーザ未指定で OS ユーザ名が使われている。`psql -U "$DB_USER"` のように docker-compose.yml と同じ `POSTGRES_USER` 由来の値を `-U` で明示する
- 「失敗するはず」のアサーションが常に FAIL する → エラーを飲み込むヘルパー（末尾 `|| true` / `2>/dev/null` で常に exit 0）を否定的アサーションの `if` 条件に流用している。出力へのエラー文字列マッチ（`2>&1` + `grep -qi 'read-only'` 等）、副作用が起きなかったことの確認（`to_regclass(...) IS NULL` 等）、または飲み込まない専用呼び出しでの終了コード判定に置き換える
- `set -euo pipefail` 下でコマンドが途中終了する → 失敗しうるコマンドの結果を使うときは `if cmd; then` か `cmd && rc=0 || rc=$?` にする（`cmd; rc=$?` は不可）
- `container ... is not connected to the network` 等のデプロイ時 Compose レースが原因 → これはテストスクリプトでも docker-compose.yml でも直せない。テストスクリプトは変更せずそのまま出力する（デプロイ実行側が再試行で対処する）

## 出力フォーマット

修正後の bash スクリプトの内容のみを stdout に直接出力してください。ファイル書き込みツールは使用しないでください。**必ず `#!/usr/bin/env bash` で始めてください（最初の行）**。Markdown のコードフェンスで囲まないでください。スクリプトの前後に説明文を含めないでください。
