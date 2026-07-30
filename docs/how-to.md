# How to: wraptainer を使ってアプリをコンテナ化する

ここでは [simple-shopping-site](https://github.com/ysakashita/simple-shopping-site)（Java 21 + Spring Boot + PostgreSQL Primary/Replica + Apache LB）を例に、`make all` の各ステップと実際の出力を示します。

## 前提条件

- `claude` コマンドがインストール済み・認証済み（`claude --version` で確認）
- Docker Desktop が起動済み
- ソースコードを `apps/<app>/` に配置済み

## 実行手順

### Step 0: クリーンアップ（初回は不要）

```bash
make distclean APP_DIR=apps/simple-shopping-site
```

以前のコンテナ・ボリューム・イメージと生成ファイルをすべて削除します。

---

### Step 1: パイプライン全体を実行

```bash
make all APP_DIR=apps/simple-shopping-site
```

`analyze → dockerfile → compose → deploy → test` の順に自動実行されます。

---

## 各ステップの出力

### analyze — ソース解析・設計ドキュメント生成

ソースコードを読み込み、コンテナ化設計ドキュメントを `_out/<app>/design.md` に出力します。

```
[analyze] Analyzing apps/simple-shopping-site ...
[analyze] → _out/simple-shopping-site/design.md
```

**出力サンプル**: [design.md](simple-shopping-site/design.md)

設計ドキュメントには以下が含まれます:

- アプリケーション概要（言語・ランタイム・ポート・パッケージマネージャー）
- 外部依存サービス（DB・LB 等）
- 環境変数一覧
- Before/After のアーキテクチャ図（Mermaid）
- コンテナイメージ一覧

---

### dockerfile — Dockerfile 生成

設計ドキュメントをもとに `apps/<app>/Dockerfile` を生成します。

```
[generate] Generating Dockerfile ...
[generate] → apps/simple-shopping-site/Dockerfile
```

**出力サンプル**: [Dockerfile](simple-shopping-site/Dockerfile)

---

### compose — docker-compose.yml 生成

設計ドキュメントと Dockerfile をもとに `apps/<app>/docker-compose.yml` を生成します。
DB の初期化スクリプトが必要な場合は `_out/<app>/init-scripts/` にも出力されます。

```
[generate] Generating docker-compose.yml ...
[generate] → apps/simple-shopping-site/docker-compose.yml
```

**出力サンプル**:
- [docker-compose.yml](simple-shopping-site/docker-compose.yml)
- [init-scripts/01-replication.sql](simple-shopping-site/init-scripts/01-replication.sql)
- [init-scripts/pg_hba.conf](simple-shopping-site/init-scripts/pg_hba.conf)

---

### deploy — コンテナ起動

`docker compose up --build` でイメージをビルドし、全サービスを起動します。
失敗した場合は Dockerfile・docker-compose.yml を自動修正して最大 4 回リトライします。

```
[deploy] デプロイ開始 (試行 1/4) ...
NAME                              IMAGE                                  COMMAND                  ...  STATUS
simple-shopping-site-db-primary-1  postgres:16-alpine                    "docker-entrypoint.s…"  ...  healthy
simple-shopping-site-db-replica-1  postgres:16-alpine                    "/bin/sh -c '\n  set…"  ...  healthy
simple-shopping-site-app1-1        simple-shopping-site-app1             "/usr/local/tomcat/b…"  ...  healthy
simple-shopping-site-app2-1        simple-shopping-site-app2             "/usr/local/tomcat/b…"  ...  healthy
simple-shopping-site-lb-1          simple-shopping-site-lb               "httpd-foreground"       ...  healthy
[deploy] 完了.
```

---

### test — テストスクリプト生成・実行

設計ドキュメントと docker-compose.yml をもとにテストスクリプトを生成し、実行します。
失敗した場合はスクリプトや docker-compose.yml を自動修正して最大 4 回リトライします。

```
[test] Generating test script ...
[test] → _out/simple-shopping-site/test-run.sh
[test] テスト実行 (試行 1/4) ...
```

**テストスクリプトサンプル**: [test-run.sh](simple-shopping-site/test-run.sh)

テストでは以下を検証します:

- 全コンテナの healthcheck が `healthy` になること
- LB 経由で HTTP 200 が返ること（複数回リクエストして安定確認）
- Apache 設定ファイルのシンタックスが正常であること
- アプリコンテナがログを出力していること
- PostgreSQL Primary が `pg_isready` で接続を受け付けること
- PostgreSQL Primary が `pg_is_in_recovery() = false`（書き込み可能）であること
- PostgreSQL Replica が `pg_isready` で接続を受け付けること
- PostgreSQL Replica が `pg_is_in_recovery() = true`（読み取り専用）であること
- `pg_stat_replication` でレプリケーション接続が確立していること
- `pg_stat_wal_receiver` で Replica から Primary への接続が確立していること

**実行結果サンプル**: [test-results.md](simple-shopping-site/test-results.md)

```
==============================================
 simple-shopping-site 動作検証テスト開始
==============================================
[INFO] --- コンテナヘルスチェック待機 ---
[PASS] simple-shopping-site-db-primary-1 は healthy です（0s 経過）
[PASS] simple-shopping-site-db-replica-1 は healthy です（0s 経過）
[PASS] simple-shopping-site-app1-1 は healthy です（0s 経過）
[PASS] simple-shopping-site-app2-1 は healthy です（0s 経過）
[PASS] simple-shopping-site-lb-1 は healthy です（0s 経過）
[INFO] --- ロードバランサー疎通確認 ---
[PASS] LB 経由でアプリのヘルスエンドポイントに到達できる（http://localhost:8080/shop/actuator/health -> HTTP 200）
[PASS] アプリのヘルスステータスが UP を返している
[INFO] --- LB への複数回リクエストで安定して 200 が返ることを確認 ---
[PASS] LB への 5 回のリクエストすべてが HTTP 200 を返した（バックエンド分散は healthcheck 通過で保証）
[INFO] --- LB (Apache) 設定検証 ---
[PASS] Apache 設定ファイルのシンタックスは正常です
[INFO] --- アプリコンテナのログ出力確認 ---
[PASS] simple-shopping-site-app1-1 はログを出力している（直近 50 行）
[PASS] simple-shopping-site-app2-1 はログを出力している（直近 50 行）
[INFO] --- PostgreSQL Primary 起動確認 ---
[PASS] db-primary は接続を受け付けています（pg_isready）
[PASS] db-primary は recovery モードではありません（書き込み可能な primary である）
[INFO] --- PostgreSQL Replica 起動確認 ---
[PASS] db-replica は接続を受け付けています（pg_isready）
[PASS] db-replica は recovery モードで稼働しています（読み取り専用レプリカとして正常）
[INFO] --- ストリーミングレプリケーション確認 ---
[PASS] db-primary の pg_stat_replication に 1 件の接続を確認しました
[PASS] db-replica の pg_stat_wal_receiver で primary への接続を確認しました
==============================================
 テスト結果サマリー: PASS=17 FAIL=0
==============================================
```

---

## 個別ステップの再実行

生成ファイルが既に存在する場合、Make の依存関係により該当ステップはスキップされます。
強制的に再生成したい場合は対象ファイルを削除してから実行してください。

```bash
# Dockerfile だけ再生成
rm apps/simple-shopping-site/Dockerfile
make dockerfile APP_DIR=apps/simple-shopping-site

# docker-compose.yml だけ再生成
rm apps/simple-shopping-site/docker-compose.yml
make compose APP_DIR=apps/simple-shopping-site

# テストスクリプトだけ再生成・再実行
rm _out/simple-shopping-site/test-run.sh
make test APP_DIR=apps/simple-shopping-site
```
