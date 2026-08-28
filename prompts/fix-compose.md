CLAUDE.md に定義されたコンテナ化ポリシーに従ってください。

以下のデプロイエラーを分析し、docker-compose.yml を修正してください。
エラーの根本原因を特定し、最小限の変更で問題を解決してください。

## YAML では直さないエラー（そのまま元の内容を出力すること）

次のエラーは Docker Compose の再作成レースであり docker-compose.yml の不具合ではない。デプロイ実行側が「クリーンな `down` → `up` の再試行」で対処するため、**docker-compose.yml は変更せず現在の内容をそのまま出力すること**:

- `Error response from daemon: container <id> is not connected to the network <project>_<network>`
- `network <name> has active endpoints` / `network <name> not found`
- `endpoint with name <name> already exists in network`

これらに対して以下の回避策を YAML へ入れてはならない（根本原因を隠すアプリ固有ハックになるため）:

- `build.provenance: false` / `build.sbom: false`
- 依存関係のない `depends_on`（アプリインスタンス同士を `service_started` で直列化する等）
- `container_name` 固定、network エイリアス調整、スケール抑制など

## 出力フォーマット

修正後の docker-compose.yml の内容のみを stdout に直接出力してください。ファイル書き込みツールは使用しないでください。Markdown のコードフェンスで囲まないでください。ファイル内容の前後に説明文を含めないでください。
