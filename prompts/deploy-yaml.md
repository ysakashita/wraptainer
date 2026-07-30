CLAUDE.md に定義されたコンテナ化ポリシーに従ってください。

提供された設計ドキュメントと Dockerfile をもとに、本番品質の docker-compose.yml を生成してください。

## イメージ選定ルール

外部依存サービスには Docker Hub 公式イメージのみ使用すること。使用するイメージとバージョンは設計ドキュメントの「コンテナイメージ一覧」に従い、`latest` タグは禁止。

## 全サービス必須ルール

設計ドキュメントの「コンテナイメージ一覧」と「After アーキテクチャ図」に記載されたすべてのサービスを compose に含めること。`app` と `db` だけの最小構成は誤り。LB・複数アプリインスタンス・DB レプリカ等がある場合は必ずすべて含める。

## 環境変数ルール

- すべての環境変数は `${VAR:-デフォルト値}` 形式を使用すること
- `${VAR:?エラーメッセージ}` や `${VAR}` のような必須指定は**使用禁止**
- シークレット系（パスワード・トークン等）は `changeme` などのプレースホルダーをデフォルトにする（例: `${DB_PASSWORD:-changeme}`）
- PostgreSQL の `POSTGRES_PASSWORD` は空にすると起動失敗するため必ず非空のデフォルト値を設定する
- **認証シークレット**: アプリが JWT 等の認証シークレットを environment で受け取る場合は必ず設定する。HMAC-SHA256 系アルゴリズムは 256 bit（32 バイト）以上のキーが必須のため、デフォルト値は 32 バイト以上にすること（例: `${JWT_SECRET:-changeme-replace-with-openssl-rand-base64-32}`）。デフォルト値なしの `${VAR}` 形式は起動時エラーの原因になる
- これにより、環境変数未設定でもコンテナが起動できるようにする

## command ブロック内のシェル変数エスケープ

Docker Compose YAML の `command:` ブロック内では `$VAR` が Compose の変数展開として処理される。シェル変数・コマンド置換として渡すには `$$` を使うこと（YAML の `$$` は実行時に `$` に変換される）。

- `$$VAR` → シェル実行時に `$VAR`（コンテナの環境変数として展開）
- `$$(cmd)` → シェル実行時に `$(cmd)`（コマンド置換）

**アンチパターン（誤り）**: `$PGDATA`（Compose が展開を試みて空になる）
**正しい例**: `$$PGDATA`

## PostgreSQL ストリーミングレプリケーションの例

primary/replica 構成が必要な場合は以下のパターンを使用すること。`<primary>`・`<replica>`・`<version>`・`<primary_vol>`・`<replica_vol>`・`<init_scripts_path>` は設計とプロンプトに記載された値に置き換える。

### primary サービス

primary は通常の postgres コマンドに WAL オプションを渡すだけでよい。レプリカユーザの作成は SQL ファイル、`pg_hba.conf` の設定はカスタムファイルのマウントで行う。バックグラウンドプロセス・シェルスクリプトは使用しない。

**シェルスクリプト（.sh）は `docker-entrypoint-initdb.d` に配置禁止**: macOS Docker Desktop の virtioFS ボリュームマウントでは `.sh` ファイルが executable として扱われ exec が試みられるが、ボリューム上のスクリプトは "bad interpreter: Permission denied" で失敗する。

**手順**:
1. Write ツールで `<init_scripts_path>/01-replication.sql` を書き込む（SQL ファイルは exec されず psql で実行されるため安全）
2. Write ツールで `<init_scripts_path>/pg_hba.conf` を書き込む
3. compose の volumes で両方をマウントし `-c hba_file=` を指定する

**01-replication.sql の内容**（Write ツールで書き込む）:

```sql
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'replicator') THEN
    CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'changeme';
  END IF;
END $$;
```

注意:
- `CREATE USER IF NOT EXISTS` は PostgreSQL では無効な構文。DO ブロックで代替する
- SQL ファイル内では `${REPLICATION_PASSWORD}` は展開されないため、デフォルト値を直接記入すること

**pg_hba.conf の内容**（Write ツールで書き込む）:

```
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     trust
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
local   replication     all                                     trust
host    replication     all             127.0.0.1/32            scram-sha-256
host    replication     all             ::1/128                 scram-sha-256
host    replication     replicator      all                     scram-sha-256
host    all             all             all                     scram-sha-256
```

**primary compose 定義**:

```yaml
<primary>:
  image: postgres:<version>-alpine
  environment:
    POSTGRES_USER: ${POSTGRES_USER:-appuser}
    POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-changeme}
    POSTGRES_DB: ${POSTGRES_DB:-appdb}
    REPLICATION_PASSWORD: ${REPLICATION_PASSWORD:-changeme}
  command:
    - postgres
    - -c
    - wal_level=replica
    - -c
    - max_wal_senders=3
    - -c
    - wal_keep_size=256
    - -c
    - hot_standby=on
    - -c
    - hba_file=/etc/postgresql/pg_hba.conf
  volumes:
    - <primary_vol>:/var/lib/postgresql/data
    - <init_scripts_path>:/docker-entrypoint-initdb.d:ro
    - <init_scripts_path>/pg_hba.conf:/etc/postgresql/pg_hba.conf:ro
  healthcheck:
    test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-appuser}"]
    interval: 10s
    timeout: 5s
    retries: 5
    start_period: 60s
  restart: unless-stopped
  networks:
    - app_net
```

### replica サービス

```yaml
<replica>:
  image: postgres:<version>-alpine
  environment:
    POSTGRES_USER: ${POSTGRES_USER:-appuser}
    PGPASSWORD: ${REPLICATION_PASSWORD:-changeme}
  command:
    - /bin/sh
    - -c
    - |
      set -e
      if [ -z "$$(ls -A /var/lib/postgresql/data 2>/dev/null)" ]; then
        chown postgres:postgres /var/lib/postgresql/data || true
        gosu postgres pg_basebackup -h <primary> -U replicator \
          -D /var/lib/postgresql/data \
          -R -X stream -c fast -P
        chmod 0700 /var/lib/postgresql/data
      fi
      exec gosu postgres postgres -c hot_standby=on
  volumes:
    - <replica_vol>:/var/lib/postgresql/data
  depends_on:
    <primary>:
      condition: service_healthy
  healthcheck:
    test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-appuser}"]
    interval: 10s
    timeout: 5s
    retries: 5
    start_period: 60s
  restart: unless-stopped
  networks:
    - app_net
```

- primary は標準の postgres ENTRYPOINT がそのまま使われ、バックグラウンドプロセス不要
- init SQL ファイル（`01-replication.sql`）は PGDATA が空のとき（初回のみ）実行される（冪等）
- replica の `[ -z "$$(ls -A ...)" ]` により再起動時の二重初期化を防ぐ（冪等）
- `PGPASSWORD` を `environment:` に設定することで pg_basebackup が認証できる

### Write ツールの利用ルール

init スクリプト等を Write ツールで書き込む場合、書き込み先は必ずプロンプト末尾に記載された `init-scripts` パス配下に限定すること。`apps/<app>/` 配下への書き込みは禁止。

## ロードバランサー・リバースプロキシのルール

- バックエンドの URL には `127.0.0.1` / `localhost` を**使用禁止**。Docker ネットワーク内のサービス名（`http://<サービス名>:<ポート>`）を指定すること
- プロキシ機能がデフォルト無効なイメージは `command` で起動前にインライン設定し、追加ファイルなしで自己完結させること

**`httpd:2.4-alpine` を使う場合の具体例**（`<backend1>` `<backend2>` `<lb_port>` `<backend_port>` は設計に合わせて置き換える）:

```yaml
lb:
  image: httpd:2.4-alpine
  command:
    - /bin/sh
    - -c
    - |
      set -e
      sed -i \
        -e '/^#LoadModule proxy_module /s/^#//' \
        -e '/^#LoadModule proxy_http_module /s/^#//' \
        -e '/^#LoadModule proxy_balancer_module /s/^#//' \
        -e '/^#LoadModule lbmethod_byrequests_module /s/^#//' \
        -e '/^#LoadModule slotmem_shm_module /s/^#//' \
        -e '/^#LoadModule headers_module /s/^#//' \
        /usr/local/apache2/conf/httpd.conf
      grep -q 'balancer://appcluster' /usr/local/apache2/conf/httpd.conf || printf '%s\n' \
        'Listen <lb_port>' \
        '<Proxy "balancer://appcluster">' \
        '  BalancerMember "http://<backend1>:<backend_port>" route=node1' \
        '  BalancerMember "http://<backend2>:<backend_port>" route=node2' \
        '  ProxySet lbmethod=byrequests' \
        '</Proxy>' \
        '<VirtualHost *:<lb_port>>' \
        '  ProxyPreserveHost On' \
        '  RequestHeader set X-Forwarded-Proto http' \
        '  ProxyPass "/" "balancer://appcluster/"' \
        '  ProxyPassReverse "/" "balancer://appcluster/"' \
        '  ErrorLog /proc/self/fd/2' \
        '  CustomLog /proc/self/fd/1 combined' \
        '</VirtualHost>' >> /usr/local/apache2/conf/httpd.conf
      exec httpd-foreground
  ports:
    - "<lb_port>:<lb_port>"
  healthcheck:
    test: ["CMD", "httpd", "-t"]
    interval: 30s
    timeout: 5s
    start_period: 10s
    retries: 3
  depends_on:
    <backend1>:
      condition: service_healthy
    <backend2>:
      condition: service_healthy
  restart: unless-stopped
  networks:
    - app_net
```

- `grep -q 'balancer://appcluster' /usr/local/apache2/conf/httpd.conf ||` により再起動時の二重追記を防ぐ（冪等）
- `exec httpd-foreground` でシグナルが httpd に正しく届く
- バックエンドが 3 台以上ある場合は `BalancerMember` 行を追加する

## 出力フォーマット

docker-compose.yml の内容のみを stdout に直接出力してください。ファイル書き込みツールは使用しないでください。Markdown のコードフェンスで囲まないでください。ファイル内容の前後に説明文を含めないでください。
