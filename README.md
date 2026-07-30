# wraptainer

既存のアプリケーションを Claude Code が自動でコンテナ化するパイプラインです。
ソースコードを解析して Dockerfile・docker-compose.yml を生成し、デプロイ・テストまで一気通貫で実行します。

## 概要

`apps/<app>/` にソースコードを置いて `make all` を実行するだけで、次のステップが自動で走ります。

```text
analyze → dockerfile → compose → deploy → test
```

各ステップは Claude Code (claude CLI) を呼び出し、[12factor.net](https://12factor.net/) に準拠した設計ドキュメント・Dockerfile・docker-compose.yml を生成します。デプロイやテストが失敗した場合は最大 4 回まで自動で修正を試みます。

## 前提条件

- [Claude Code](https://github.com/anthropics/claude-code) (`claude` コマンド) がインストール済み・認証済み
- Docker Desktop が起動済み
- GNU Make

## ディレクトリ構成

```text
wraptainer/
├── Makefile              # パイプライン定義
├── CLAUDE.md             # コンテナ化ポリシー（Claude Code への共通指示）
├── prompts/
│   ├── analyze.md        # Step 1: ソース解析プロンプト
│   ├── dockerize.md      # Step 2: Dockerfile 生成プロンプト
│   ├── deploy-yaml.md    # Step 3: docker-compose.yml 生成プロンプト
│   ├── test.md           # Step 4: テストスクリプト生成プロンプト
│   ├── fix-dockerfile.md # Dockerfile 自動修正プロンプト
│   ├── fix-compose.md    # docker-compose.yml 自動修正プロンプト
│   └── fix-test.md       # テストスクリプト自動修正プロンプト
├── apps/
│   └── <app>/            # コンテナ化対象のソースコード（.gitignore 対象）
└── _out/
    └── <app>/            # 生成物（design.md, test-run.sh, test-results.md 等）
```

> `apps/` と `_out/` は `.gitignore` で除外されています。

## ドキュメント

- [How to: 実行手順と出力サンプル](docs/how-to.md) — 各ステップのコマンドと実際の出力結果を示します

## 使い方

### 1. ソースコードを配置する

```bash
cp -r /path/to/your-app apps/your-app
```

### 2. パイプラインを実行する

```bash
make all APP_DIR=apps/your-app
```

### 3. 個別ステップを実行する

```bash
make analyze    APP_DIR=apps/your-app   # ソース解析 → _out/<app>/design.md
make dockerfile APP_DIR=apps/your-app   # Dockerfile 生成
make compose    APP_DIR=apps/your-app   # docker-compose.yml 生成
make deploy     APP_DIR=apps/your-app   # docker compose up --build
make test       APP_DIR=apps/your-app   # テストスクリプト生成 & 実行
```

### 4. クリーンアップ

```bash
make down       APP_DIR=apps/your-app   # コンテナ・ボリューム・イメージを削除
make clean      APP_DIR=apps/your-app   # _out/ と生成ファイルを削除
make distclean  APP_DIR=apps/your-app   # down + clean
```

## 生成されるファイル

| ファイル | 生成先 | 説明 |
| --- | --- | --- |
| `design.md` | `_out/<app>/` | コンテナ化設計ドキュメント（Before/After 構成図を含む） |
| `Dockerfile` | `apps/<app>/` | アプリのコンテナイメージ定義 |
| `docker-compose.yml` | `apps/<app>/` | 全サービス（LB・アプリ・DB 等）の構成定義 |
| `test-run.sh` | `_out/<app>/` | コンテナ動作確認テストスクリプト |
| `test-results.md` | `_out/<app>/` | テスト実行結果 |

> `apps/<app>/` 配下の既存ファイルは変更しません。Dockerfile と docker-compose.yml の**追加**のみ行います。

## 自動修正の仕組み

デプロイ・テストが失敗すると、最大 4 回まで自動で修正を試みます。

| 試行 | デプロイ失敗時 | テスト失敗時 |
| --- | --- | --- |
| 1 | Dockerfile を修正 | テストスクリプトを修正 |
| 2 | docker-compose.yml を修正 | docker-compose.yml を修正 → 再デプロイ → テストスクリプトを再生成 |
| 3 | Dockerfile + docker-compose.yml を同時修正 | テストスクリプトを再生成 |
| 4 | 失敗終了 | 失敗終了 |

## ポリシー・プロンプト

コンテナ化の設計方針・Dockerfile・docker-compose.yml・テストの各ポリシーは [CLAUDE.md](CLAUDE.md) に定義されています。

各ステップで Claude Code に渡すプロンプトは `prompts/` 配下のファイルで管理しています。

| ファイル | 用途 |
| --- | --- |
| `prompts/analyze.md` | ソース解析・設計ドキュメント生成 |
| `prompts/dockerize.md` | Dockerfile 生成 |
| `prompts/deploy-yaml.md` | docker-compose.yml 生成 |
| `prompts/test.md` | テストスクリプト生成 |
| `prompts/fix-dockerfile.md` | Dockerfile 自動修正 |
| `prompts/fix-compose.md` | docker-compose.yml 自動修正 |
| `prompts/fix-test.md` | テストスクリプト自動修正 |
