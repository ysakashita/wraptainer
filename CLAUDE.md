# wraptainer — コンテナ化ポリシー

このファイルは wraptainer が Claude Code を呼び出す際のすべての共通ポリシーを定義する。
各ステップのプロンプトはここに記載されたポリシーに従うこと。

---

## 大原則

- **ソースコード不変**: `apps/<app>/` 配下の既存ファイルは一切変更・削除しない。ただし、`Dockerfile` およびデプロイに必要な YAML ファイルの**追加**のみ許可する。解析結果などの生成物はすべて `_out/<app>/` 直下に置く。
- **冪等性**: 何度実行しても同じ結果になるよう生成すること。

---

## 解析ポリシー（analyze）

- 日本語で出力します
- https://12factor.net/ に従いマイクロサービス化しやすい単位でコンテナ化する
- 利用しているソフトウェアはコンテナ化する場合でも原則同じソフトウェアで同じバージョンのコンテナイメージを利用する
- クラスタ構成やLBなどの構成は崩さないようにコンテナ化する
- ランタイム・言語バージョン・パッケージマネージャーを明示する
- 公開ポート、環境変数、外部依存（DB/キャッシュ/キュー）を漏れなく列挙する
- Before/After の構成図は **mermaid** 形式で出力する
- Before: コンテナなしの現状構成
- After: Docker コンテナ化後の構成（依存サービスを含む）
- Mermaid 図のシンタックスルール（必須）:
  - `graph TD` のみ使用する（`flowchart` は使わない）
  - ノード ID に空白・ハイフン・括弧・特殊文字を含めない（英数字とアンダースコアのみ）
  - ラベルに括弧や特殊文字を含む場合は `["ラベル"]` 形式で囲む
  - エッジは `-->` のみ使用する（`==>`, `-.->`, `---` は使わない）
  - `subgraph` のラベルに特殊文字を含めない

---

## Dockerfile ポリシー

- **ベースポリシー**: https://docs.docker.jp/develop/develop-images/dockerfile_best-practices.html のベストプラクティスに従いDockerfileを作成する
- **マルチステージビルド**: コンパイル・バンドル等のビルド工程が必要な場合のみ使用する。スクリプト言語（Python/Node.js/Ruby等）や既にビルド済みの成果物を使う場合は使用しない
- **既存ビルドスクリプトの優先利用**: ソースコードに `Makefile` や `build.sh` 等のビルドスクリプトがある場合は、ビルドツール（mvn/gradle/npm 等）を直接呼び出さず、そのスクリプトを `COPY` して実行する（例: `RUN make build`、`RUN ./build.sh`）
- **ベースイメージ**: ランタイムに最小限のイメージを選択する（alpine / distroless / slim）。`latest` タグは使用禁止、バージョンを必ずピンする
- **Tomcat ベースイメージ**: JDK 17 以降は `tomcat:X.Y-jdk<version>-alpine` タグが Docker Hub に存在しない。JDK 17+（Tomcat 9.0/10.1 等）では `tomcat:10.1-jdk21-temurin`（Ubuntu ベース）を使用すること。alpine を優先したい場合は `eclipse-temurin:<version>-jre-alpine` + `java -jar` に切り替えるか、WAR の場合は Ubuntu ベースを受け入れること
- **COPY パス**: ビルドコンテキストはソースコードのディレクトリ自体（プロンプトで絶対パスが渡される）。`COPY` 命令に `src/` プレフィックスは不要（例: `COPY pom.xml .`、`COPY src/ ./src/`）
- **HEALTHCHECK**: HTTP エンドポイントがある場合は必ず追加する
- **レイヤー効率**: `RUN` を連結して不要なレイヤーを減らす。依存インストールとアプリコードは別レイヤーにしてキャッシュを活かす
- **ストレージ**: 永続的データを保存する際は、コンテナの外に保存する

---

## docker-compose.yml ポリシー

- `version:` フィールドは記載しない（現行 Docker Compose では obsolete 警告が出るため）
- `build.context` にはソースコードの絶対パスを指定する（プロンプトで渡される）
- `build.dockerfile` には Dockerfile の絶対パスを指定する（プロンプトで渡される）
- 外部依存サービスは Docker Hub 公式イメージをバージョンピンして使用する（設計ドキュメントのコンテナイメージ一覧に従う）。公式イメージ以外のサードパーティイメージは使用しない
- 環境変数は `${VAR:-デフォルト値}` 形式を使用する（`${VAR:?...}` の必須指定は禁止）
- パスワード等のシークレットは `${DB_PASSWORD:-changeme}` のように非空のプレースホルダーをデフォルトにする（空文字デフォルトは DB が起動しない場合があるため禁止）
- 永続データはnamed volume を使用する
- `depends_on` は `condition: service_healthy` で健全性を保証する
- 全サービスに `healthcheck` を設定する
- `restart: unless-stopped` を全サービスに付与する
- サービス間通信用の named network を定義する
- **全サービス必須**: 設計ドキュメントのアーキテクチャ図・コンテナイメージ一覧に記載されたすべてのサービス（LB・アプリインスタンス・DB レプリカ等）を漏れなく compose に含める。`app` と `db` だけの最小構成は禁止
- **認証シークレットの設定**: アプリが JWT 等の認証シークレットを環境変数で受け取る場合は必ず compose に記載する。HMAC-SHA256 系アルゴリズムは **256 bit（32 バイト）以上** のキーを要求するため、デフォルト値は 32 バイト以上の文字列を指定する（例: `${JWT_SECRET:-changeme-replace-with-openssl-rand-base64-32}`）。デフォルト値なしの `${SECRET_VAR}` 形式は起動時エラーの原因になるため禁止
- **LB・リバースプロキシのコンテナ設定**: バックエンドの URL には **`127.0.0.1` や `localhost` を使わず Docker ネットワーク内のサービス名**（`http://<サービス名>:<ポート>`）を指定する。ソースコードに既存の LB 設定ファイルがある場合でも `127.0.0.1` が含まれるものはそのまま使わず Docker 向けに置き換えること。プロキシ機能がデフォルトで無効なイメージは `command` で起動前にインライン設定すること（`deploy-yaml.md` のパターン参照）
- **`command:` 内のシェル変数**: Docker Compose YAML の `command:` ブロック内でシェル変数やコマンド置換を使う場合は `$$VAR`・`$$(cmd)` のように `$$` でエスケープすること（単独の `$VAR` は Compose が変数展開を試みて空になる）
- **DB レプリケーション構成**: primary/replica 構成が必要な場合は `deploy-yaml.md` の PostgreSQL レプリケーションテンプレートに従う。primary はバックグラウンドプロセスを使わず通常の postgres コマンドに WAL オプションを渡すだけにし、レプリカユーザ作成と `pg_hba.conf` 設定は `docker-entrypoint-initdb.d` 経由の init スクリプトで行うこと（Write ツールでプロンプト末尾の init-scripts パスに書き込む）
- **replica の postgres 起動**: replica の command を `/bin/sh -c "..."` でカスタムシェルから起動する場合、最終的に `exec gosu postgres postgres` で実行すること。postgres は root 実行を拒否するため、`exec postgres` 直接呼び出しは失敗する。`gosu` は postgres 公式イメージに含まれている
- **replica データディレクトリのパーミッション**: `pg_basebackup` 完了後は必ず `chmod 0700 /var/lib/postgresql/data` を実行すること。Docker の named volume はデフォルトで 0755 等広めのパーミッションを持つ場合があり、PostgreSQL は 0700 または 0750 以外のデータディレクトリを起動拒否する
- **`docker-entrypoint-initdb.d` にシェルスクリプト配置禁止**: macOS Docker Desktop の virtioFS ボリュームマウントでは `.sh` ファイルが executable に見え、exec 時に "bad interpreter: Permission denied" で失敗する。init 処理は `.sql` ファイル（psql で実行）と `-c hba_file=` によるカスタム `pg_hba.conf` マウントで実装すること
- **healthcheck の start_period**: DB 等、起動・初期化に時間がかかるサービスは `start_period: 60s` 以上を設定すること（デフォルト 0s では起動前から失敗カウントが始まる）

---

## テストポリシー（test）

- `#!/usr/bin/env bash` + `set -euo pipefail` で始める
- コンテナ起動を待機する（ポーリング + タイムアウト。単純な `sleep` は禁止）
- HTTP サービスは `curl` でエンドポイントを叩き、ステータスコードを検証する
- 非 HTTP サービス（PostgreSQL 等）の起動確認は `pg_isready` や SQL（`pg_is_in_recovery()`、`pg_stat_replication` 等）で行う。`docker logs | grep "ready to accept"` のようなログ検索は禁止（`--tail` なしは重く、`--tail` ありは起動メッセージを見逃す）
- 各チェックは PASS / FAIL を明示して出力する
- 外部ツールへの依存は最小限（標準 Unix ツール + docker のみ）
- ログが出力されているかどうかを確認する
- **ロードバランサーの分散検証**: アプリコンテナのログは多くのフレームワークでデフォルトではリクエストを記録しないため、LB の分散テストではアプリログを根拠にしない。代わりに「LB エンドポイントが HTTP 200 を返す」「全バックエンドが healthcheck 通過」を確認することで正常動作を保証する。ログ行数の変化を比較する方法も不確実なため禁止。
- **シェル特殊文字の安全な扱い**: 生成するスクリプト内でシングルクォートを含む文字列（例: `docker exec ... bash -c '...'`）は、シングルクォートをネストせず `"..."` に置き換えるか `printf '%s' ...` 経由で渡す。`#` を含むコマンド（awk パターン等）は Makefile コンテキストでコメントと誤解釈されることがあるため、`#` 自体を文字列として明示的に扱う代替表現（例: `[[:space:]]*` など）を検討する

---

## セキュリティ共通ルール

- シークレットをファイルにハードコードしない（環境変数参照のみ）
- コンテナ内で root 権限を持つプロセスを動かさない
- 不要なパッケージ・ファイルをイメージに含めない
