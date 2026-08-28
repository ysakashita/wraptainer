# wraptainer

既存のアプリケーションを Claude Code が自動でコンテナ化するパイプラインです。
ソースコードを解析して Dockerfile・docker-compose.yml を生成し、デプロイ・テストまで一気通貫で実行します。

## 概要

`apps/<app>/` にソースコードを置いて `make all` を実行するだけで、次のステップが自動で走ります。

```text
analyze → dockerfile → compose → deploy → test → learn
```

各ステップは Claude Code (claude CLI) を呼び出し、[12factor.net](https://12factor.net/) に準拠した設計ドキュメント・Dockerfile・docker-compose.yml を生成します。デプロイやテストが失敗した場合は最大 4 回まで自動で修正を試みます。

テストが全て通ると最後に `learn` ステップが走り、その実行で発生した失敗と自動修正の内容を**汎用的な再発防止策**として [CLAUDE.md](CLAUDE.md) と `prompts/` に反映します。様々なアプリで実行を重ねるほどポリシーの精度が上がり、次のアプリでは同じ失敗を最初から避けられるようになります（[学習ループ](#学習ループself-improving) 参照）。

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
│   ├── fix-test.md       # テストスクリプト自動修正プロンプト
│   └── learn.md          # Step 7: ポリシー学習プロンプト
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
make learn      APP_DIR=apps/your-app   # テスト全 PASS 後、今回の修正をポリシーへ反映
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
| `fix-journal.md` | `_out/<app>/` | その実行で発生した失敗と自動修正の記録（`learn` の入力。失敗がなければ生成されない） |

> `apps/<app>/` 配下の既存ファイルは変更しません。Dockerfile と docker-compose.yml の**追加**のみ行います。

## 自動修正の仕組み

デプロイ・テストが失敗すると、最大 4 回まで自動で修正を試みます。

| 試行 | デプロイ失敗時 | テスト失敗時 |
| --- | --- | --- |
| 1 | Dockerfile を修正 | テストスクリプトを修正 |
| 2 | docker-compose.yml を修正 | docker-compose.yml を修正 → 再デプロイ → テストスクリプトを再生成 |
| 3 | Dockerfile + docker-compose.yml を同時修正 | テストスクリプトを再生成 |
| 4 | 失敗終了 | 失敗終了 |

> `docker compose up --build` 再実行時のコンテナ再作成レース（`container ... is not connected to the network`）は docker-compose.yml の不具合ではないため、Makefile がクリーンな `down` → `up` の再試行と BuildKit アテステーション無効化（`BUILDX_NO_DEFAULT_ATTESTATIONS=1`）で対処します。

## 学習ループ（self-improving）

`make all` の最後（テストが全て PASS したときのみ）に `learn` ステップが実行されます。

1. `deploy` / `test` は失敗のたびに内容を `_out/<app>/fix-journal.md` に記録します（`deploy` 開始時にリセット。一度も失敗しなければ作られません）。
2. `learn` はジャーナルがある場合のみ Claude Code を呼び出し、失敗を「クラス」に分類して、**別のアプリでも再発しうる汎用的なもの**だけを [CLAUDE.md](CLAUDE.md) と `prompts/` の適切なセクションに追記します。
3. ガードレール:
   - アプリ名・バージョン・ポート等の固有値は書かない（言語 / ミドルウェア共通の粒度に一般化）
   - 追記前に Grep して同等の記述があれば何もしない（冪等）
   - 既存記述の削除・書き換えはしない（`Edit` ツールのみ許可）
   - 失敗しても生成物・テスト結果には影響しない

これを様々なアプリで積み重ねることで、ポリシー文書が回を追うごとに賢くなり、次のアプリでは前回の失敗を最初から回避した生成物が出ます。

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
| `prompts/learn.md` | テスト全 PASS 後のポリシー学習 |
