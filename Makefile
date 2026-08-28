APP_DIR  ?= apps/simple-shopping-site
APP_NAME ?= $(shell basename "$(strip $(APP_DIR))")

ifeq ($(strip $(APP_DIR)),)
  ifeq ($(filter help clean,$(MAKECMDGOALS)),)
    $(error APP_DIR is not set. Set it in the Makefile (APP_DIR = apps/my-app) or on the command line (make all APP_DIR=apps/my-app))
  endif
endif

# trailing slash を除去した正規パス
APP_DIR_NORM   := $(patsubst %/,%,$(strip $(APP_DIR)))
OUT_DIR        := _out/$(APP_NAME)
PROMPTS        := prompts
APP_DOCKERFILE := $(APP_DIR_NORM)/Dockerfile
APP_COMPOSE    := $(APP_DIR_NORM)/docker-compose.yml

# BuildKit のデフォルトアテステーション（provenance / SBOM）を無効化する。
# 有効なままだとビルドのたびにタイムスタンプ入りのアテステーションマニフェストが
# 生成され、ソース不変でもイメージのマニフェストリストのダイジェストが毎回変わる。
# その結果 `docker compose up --build` の再実行のたびに全アプリコンテナが不要に
# 再作成され、共有ネットワーク上での並行 attach/detach レースにより
# "container ... is not connected to the network" を誘発する。
# アプリ非依存の対策なのでここで一括して無効化する。
export BUILDX_NO_DEFAULT_ATTESTATIONS := 1

# '#' は Make のコメント文字のため octal エスケープで定義する
HASH := $(shell printf '\043')

# Claude 出力から先頭の説明文と末尾の Markdown フェンス・説明文を除去するフィルター。
# 開始トリガーは「行全体がその形になっている」ことを要求する（説明文に version:/name: 等の
# 語が混じっても拾わないよう、トップレベルキー行は「キー: 単純スカラーのみ」に限定）。
TRIM_DOCKERFILE = awk '/^FROM [^ ]/{f=1} f{if(/^```|^---[ ]*$$/)exit; print}'
TRIM_COMPOSE    = awk '/^(version|services|name|networks|volumes|configs|secrets|include|x-[A-Za-z0-9_-]+):[ ]*("?[A-Za-z0-9._\/-]*"?)?[ ]*$$/{f=1} f{if(/^```/)exit; print}'
TRIM_SH         = awk '/^$(HASH)!/{f=1} f{if(/^```/)exit; print}'

.PHONY: all analyze dockerfile compose generate deploy test learn clean down distclean help

all: analyze dockerfile compose deploy test learn

analyze:    $(OUT_DIR)/design.md
dockerfile: $(APP_DOCKERFILE)
compose:    $(APP_COMPOSE)

# generate = dockerfile + compose (将来: k8s など他の出力形式もここに並べる)
generate: dockerfile compose

deploy: $(APP_COMPOSE)
	@docker info > /dev/null 2>&1 || { echo "[deploy] エラー: Docker デーモンが起動していません。Docker Desktop を起動してから再実行してください。"; exit 1; }
	@ABS_APP=$$(cd "$(APP_DIR_NORM)" && pwd) && \
	 ABS_OUT=$$(cd "$(OUT_DIR)" && pwd) && \
	 ABS_PROMPTS=$$(cd "$(PROMPTS)" && pwd) && \
	 rm -f "$$ABS_OUT/fix-journal.md"; \
	 for ATTEMPT in 1 2 3 4; do \
	   echo "[deploy] デプロイ開始 (試行 $$ATTEMPT/4) ..."; \
	   if [ "$$ATTEMPT" != "1" ]; then \
	     docker compose -f "$$ABS_APP/docker-compose.yml" down --remove-orphans > /dev/null 2>&1 || true; \
	   fi; \
	   if docker compose -f "$$ABS_APP/docker-compose.yml" up -d --build > /tmp/wraptainer-deploy.txt 2>&1; then \
	     docker compose -f "$$ABS_APP/docker-compose.yml" ps; \
	     echo "[deploy] 完了."; \
	     exit 0; \
	   fi; \
	   cat /tmp/wraptainer-deploy.txt; \
	   { printf '\n### deploy 試行 %s / %s\n\n```\n%s\n```\n' "$$ATTEMPT" "$$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" "$$(tail -c 4000 /tmp/wraptainer-deploy.txt)"; } >> "$$ABS_OUT/fix-journal.md" 2>/dev/null || true; \
	   if [ "$$ATTEMPT" != "4" ] && grep -q 'is not connected to the network' /tmp/wraptainer-deploy.txt; then \
	     echo "[deploy] Compose のネットワーク再作成レースを検出。YAML は変更せず、クリーンな再デプロイで再試行します ..."; \
	     printf '  → ネットワーク再作成レース: YAML 変更なしでクリーン再デプロイ（Makefile が処理）\n' >> "$$ABS_OUT/fix-journal.md" 2>/dev/null || true; \
	     continue; \
	   fi; \
	   printf '' > /tmp/wraptainer-logs.txt; \
	   docker compose -f "$$ABS_APP/docker-compose.yml" ps 2>/dev/null \
	     | awk 'NR>1 && /unhealthy|Exit/{print $$1}' \
	     | xargs -I CNAME sh -c 'printf "\n=== CNAME logs (last 30) ===\n" && docker logs --tail 30 CNAME 2>&1' \
	     >> /tmp/wraptainer-logs.txt 2>&1 || true; \
	   ERROR=$$(cat /tmp/wraptainer-deploy.txt; cat /tmp/wraptainer-logs.txt); \
	   if [ "$$ATTEMPT" = "4" ]; then \
	     echo "[deploy] 自動修正を試みましたが解決できませんでした。"; \
	     exit 1; \
	   fi; \
	   COMPOSE_ERR=$$(grep -qE '^yaml: |mapping values are not allowed|did not find expected|could not find expected|found character that cannot start' /tmp/wraptainer-deploy.txt && echo 1 || true); \
	   if [ "$$ATTEMPT" = "1" ] && [ -n "$$COMPOSE_ERR" ]; then \
	     echo "[deploy] docker-compose.yml のパースエラーを検出。Dockerfile ではなく compose を修正します ..."; \
	   fi; \
	   if [ "$$ATTEMPT" = "1" ] && [ -z "$$COMPOSE_ERR" ]; then \
	     echo "[deploy] Dockerfile を自動修正中 ..."; \
	     DOCKERFILE=$$(cat "$$ABS_APP/Dockerfile"); \
	     PROMPT=$$(printf '%s\n\n## ビルドエラー\n```\n%s\n```\n\n## 現在の Dockerfile\n```dockerfile\n%s\n```\n\n## ソースコードパス\n`%s`' \
	         "$$(cat "$$ABS_PROMPTS/fix-dockerfile.md")" "$$ERROR" "$$DOCKERFILE" "$$ABS_APP") && \
	     FIXED=$$(claude --allowed-tools "Read,Glob,Grep,LS" --add-dir "$$ABS_APP" -p "$$PROMPT" | $(TRIM_DOCKERFILE)) && \
	     [ -n "$$FIXED" ] && printf '%s\n' "$$FIXED" > "$$ABS_APP/Dockerfile" || echo "[deploy] 警告: 修正出力が空のため Dockerfile を維持します."; \
	     echo "[deploy] Dockerfile を修正しました."; \
	   elif [ "$$ATTEMPT" = "2" ] || { [ "$$ATTEMPT" = "1" ] && [ -n "$$COMPOSE_ERR" ]; }; then \
	     echo "[deploy] docker-compose.yml を自動修正中 ..."; \
	     DOCKERFILE=$$(cat "$$ABS_APP/Dockerfile"); \
	     COMPOSE=$$(cat "$$ABS_APP/docker-compose.yml"); \
	     PROMPT=$$(printf '%s\n\n## デプロイエラー\n```\n%s\n```\n\n## 現在の docker-compose.yml\n```yaml\n%s\n```\n\n## 現在の Dockerfile\n```dockerfile\n%s\n```\n\n## ソースコードパス\n`%s`\n\n## Dockerfileパス\n`%s`\n\n## init-scripts パス\n`%s`' \
	         "$$(cat "$$ABS_PROMPTS/fix-compose.md")" "$$ERROR" "$$COMPOSE" "$$DOCKERFILE" "$$ABS_APP" "$$ABS_APP/Dockerfile" "$$ABS_OUT/init-scripts") && \
	     FIXED=$$(claude --allowed-tools "Write" -p "$$PROMPT" | $(TRIM_COMPOSE)) && \
	     [ -n "$$FIXED" ] && printf '%s\n' "$$FIXED" > "$$ABS_APP/docker-compose.yml" || echo "[deploy] 警告: 修正出力が空のため docker-compose.yml を維持します."; \
	     echo "[deploy] docker-compose.yml を修正しました."; \
	   elif [ "$$ATTEMPT" = "3" ]; then \
	     echo "[deploy] Dockerfile と docker-compose.yml を同時修正中 ..."; \
	     DOCKERFILE=$$(cat "$$ABS_APP/Dockerfile"); \
	     COMPOSE=$$(cat "$$ABS_APP/docker-compose.yml"); \
	     PROMPT=$$(printf '%s\n\n## ビルドエラー\n```\n%s\n```\n\n## 現在の Dockerfile\n```dockerfile\n%s\n```\n\n## ソースコードパス\n`%s`' \
	         "$$(cat "$$ABS_PROMPTS/fix-dockerfile.md")" "$$ERROR" "$$DOCKERFILE" "$$ABS_APP") && \
	     FIXED=$$(claude --allowed-tools "Read,Glob,Grep,LS" --add-dir "$$ABS_APP" -p "$$PROMPT" | $(TRIM_DOCKERFILE)) && \
	     [ -n "$$FIXED" ] && printf '%s\n' "$$FIXED" > "$$ABS_APP/Dockerfile" || echo "[deploy] 警告: Dockerfile 修正出力が空のため維持します."; \
	     DOCKERFILE=$$(cat "$$ABS_APP/Dockerfile"); \
	     PROMPT=$$(printf '%s\n\n## デプロイエラー\n```\n%s\n```\n\n## 現在の docker-compose.yml\n```yaml\n%s\n```\n\n## 現在の Dockerfile\n```dockerfile\n%s\n```\n\n## ソースコードパス\n`%s`\n\n## Dockerfileパス\n`%s`\n\n## init-scripts パス\n`%s`' \
	         "$$(cat "$$ABS_PROMPTS/fix-compose.md")" "$$ERROR" "$$COMPOSE" "$$DOCKERFILE" "$$ABS_APP" "$$ABS_APP/Dockerfile" "$$ABS_OUT/init-scripts") && \
	     FIXED=$$(claude --allowed-tools "Write" -p "$$PROMPT" | $(TRIM_COMPOSE)) && \
	     [ -n "$$FIXED" ] && printf '%s\n' "$$FIXED" > "$$ABS_APP/docker-compose.yml" || echo "[deploy] 警告: docker-compose.yml 修正出力が空のため維持します."; \
	     echo "[deploy] Dockerfile と docker-compose.yml を修正しました."; \
	   fi; \
	 done

test: $(OUT_DIR)/test-run.sh
	@ABS_APP=$$(cd "$(APP_DIR_NORM)" && pwd) && \
	 ABS_OUT=$$(cd "$(OUT_DIR)" && pwd) && \
	 ABS_PROMPTS=$$(cd "$(PROMPTS)" && pwd) && \
	 rm -f "$$ABS_OUT/tests-passed"; \
	 for ATTEMPT in 1 2 3 4; do \
	   echo "[test] テスト実行 (試行 $$ATTEMPT/4) ..."; \
	   bash "$$ABS_OUT/test-run.sh" > "$$ABS_OUT/test-results.md" 2>&1; TEST_RC=$$?; \
	   cat "$$ABS_OUT/test-results.md"; \
	   if [ $$TEST_RC -eq 0 ]; then \
	     touch "$$ABS_OUT/tests-passed"; \
	     echo "[test] 完了."; \
	     exit 0; \
	   fi; \
	   { printf '\n### test 試行 %s / %s\n\n```\n%s\n```\n' "$$ATTEMPT" "$$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" "$$(grep -E '^FAIL:|Results:' "$$ABS_OUT/test-results.md" | tail -c 4000)"; } >> "$$ABS_OUT/fix-journal.md" 2>/dev/null || true; \
	   if [ "$$ATTEMPT" = "4" ]; then \
	     echo "[test] テストが解決できませんでした。"; \
	     exit 1; \
	   fi; \
	   ERROR=$$(cat "$$ABS_OUT/test-results.md" 2>/dev/null || echo ""); \
	   DESIGN=$$(cat "$$ABS_OUT/design.md" 2>/dev/null || echo ""); \
	   DOCKERFILE=$$(cat "$$ABS_APP/Dockerfile" 2>/dev/null || echo ""); \
	   COMPOSE=$$(cat "$$ABS_APP/docker-compose.yml" 2>/dev/null || echo ""); \
	   RUNNING=$$(docker compose -f "$$ABS_APP/docker-compose.yml" ps 2>/dev/null || echo ""); \
	   if [ "$$ATTEMPT" = "1" ]; then \
	     echo "[test] テストスクリプトを自動修正中 ..."; \
	     TESTSCRIPT=$$(cat "$$ABS_OUT/test-run.sh" 2>/dev/null || echo ""); \
	     PROMPT=$$(printf '%s\n\n## テスト失敗内容\n```\n%s\n```\n\n## 現在のテストスクリプト\n```bash\n%s\n```\n\n## コンテナ状態\n```\n%s\n```\n\n## docker-compose.yml\n```yaml\n%s\n```\n\n## 設計\n%s' \
	         "$$(cat "$$ABS_PROMPTS/fix-test.md")" "$$ERROR" "$$TESTSCRIPT" "$$RUNNING" "$$COMPOSE" "$$DESIGN") && \
	     FIXED=$$(claude --allowed-tools "" -p "$$PROMPT" | $(TRIM_SH)) && \
	     [ -n "$$FIXED" ] && printf '%s\n' "$$FIXED" > "$$ABS_OUT/test-run.sh" && chmod +x "$$ABS_OUT/test-run.sh" || \
	       echo "[test] 警告: 修正出力が空のため test-run.sh を維持します."; \
	     echo "[test] テストスクリプトを修正しました."; \
	   elif [ "$$ATTEMPT" = "2" ]; then \
	     echo "[test] docker-compose.yml を自動修正中 ..."; \
	     printf '' > /tmp/wraptainer-logs.txt; \
	     docker compose -f "$$ABS_APP/docker-compose.yml" ps 2>/dev/null \
	       | awk 'NR>1 && /unhealthy|Exit/{print $$1}' \
	       | xargs -I CNAME sh -c 'printf "\n=== CNAME logs (last 30) ===\n" && docker logs --tail 30 CNAME 2>&1' \
	       >> /tmp/wraptainer-logs.txt 2>&1 || true; \
	     ERR_WITH_LOGS=$$(printf '%s\n%s' "$$ERROR" "$$(cat /tmp/wraptainer-logs.txt)"); \
	     PROMPT=$$(printf '%s\n\n## テスト失敗内容とコンテナログ\n```\n%s\n```\n\n## 現在の docker-compose.yml\n```yaml\n%s\n```\n\n## 現在の Dockerfile\n```dockerfile\n%s\n```\n\n## ソースコードパス\n`%s`\n\n## Dockerfileパス\n`%s`\n\n## init-scripts パス\n`%s`' \
	         "$$(cat "$$ABS_PROMPTS/fix-compose.md")" "$$ERR_WITH_LOGS" "$$COMPOSE" "$$DOCKERFILE" "$$ABS_APP" "$$ABS_APP/Dockerfile" "$$ABS_OUT/init-scripts") && \
	     FIXED=$$(claude --allowed-tools "Write" -p "$$PROMPT" | $(TRIM_COMPOSE)) && \
	     [ -n "$$FIXED" ] && printf '%s\n' "$$FIXED" > "$$ABS_APP/docker-compose.yml" || \
	       echo "[test] 警告: 修正出力が空のため docker-compose.yml を維持します."; \
	     echo "[test] docker-compose.yml を修正しました。再デプロイ中 ..."; \
	     docker compose -f "$$ABS_APP/docker-compose.yml" down --volumes --remove-orphans 2>/dev/null || true; \
	     docker compose -f "$$ABS_APP/docker-compose.yml" up -d --build > /tmp/wraptainer-deploy.txt 2>&1 || \
	       cat /tmp/wraptainer-deploy.txt; \
	     docker compose -f "$$ABS_APP/docker-compose.yml" ps; \
	     RUNNING=$$(docker compose -f "$$ABS_APP/docker-compose.yml" ps 2>/dev/null || echo ""); \
	     COMPOSE=$$(cat "$$ABS_APP/docker-compose.yml"); \
	     PROMPT=$$(printf '%s\n\n---\n## App: %s\n\n## コンテナ状態\n```\n%s\n```\n\n## docker-compose.yml\n```yaml\n%s\n```\n\n## 設計\n%s' \
	         "$$(cat "$$ABS_PROMPTS/test.md")" "$(APP_NAME)" "$$RUNNING" "$$COMPOSE" "$$DESIGN") && \
	     FIXED=$$(claude --allowed-tools "" -p "$$PROMPT" | $(TRIM_SH)) && \
	     [ -n "$$FIXED" ] && printf '%s\n' "$$FIXED" > "$$ABS_OUT/test-run.sh" && chmod +x "$$ABS_OUT/test-run.sh" || \
	       echo "[test] 警告: テストスクリプト再生成が空のため維持します."; \
	     echo "[test] テストスクリプトを再生成しました."; \
	   elif [ "$$ATTEMPT" = "3" ]; then \
	     echo "[test] テストスクリプトを再生成中 ..."; \
	     PROMPT=$$(printf '%s\n\n---\n## App: %s\n\n## テスト失敗内容\n```\n%s\n```\n\n## コンテナ状態\n```\n%s\n```\n\n## docker-compose.yml\n```yaml\n%s\n```\n\n## 設計\n%s' \
	         "$$(cat "$$ABS_PROMPTS/test.md")" "$(APP_NAME)" "$$ERROR" "$$RUNNING" "$$COMPOSE" "$$DESIGN") && \
	     FIXED=$$(claude --allowed-tools "" -p "$$PROMPT" | $(TRIM_SH)) && \
	     [ -n "$$FIXED" ] && printf '%s\n' "$$FIXED" > "$$ABS_OUT/test-run.sh" && chmod +x "$$ABS_OUT/test-run.sh" || \
	       echo "[test] 警告: テストスクリプト再生成が空のため維持します."; \
	     echo "[test] テストスクリプトを再生成しました."; \
	   fi; \
	 done

learn:
	@ABS_APP=$$(cd "$(APP_DIR_NORM)" && pwd) && \
	 ABS_OUT=$$(cd "$(OUT_DIR)" 2>/dev/null && pwd || echo "$(CURDIR)/$(OUT_DIR)") && \
	 ABS_PROMPTS=$$(cd "$(PROMPTS)" && pwd) && \
	 ABS_ROOT="$(CURDIR)" && \
	 if [ ! -s "$$ABS_OUT/fix-journal.md" ]; then \
	   echo "[learn] 今回の実行で自動修正は発生しませんでした。ポリシー学習をスキップします."; \
	   exit 0; \
	 fi; \
	 if [ ! -f "$$ABS_OUT/tests-passed" ]; then \
	   echo "[learn] 直近の test が全 PASS で完了していないため、ポリシー学習をスキップします."; \
	   exit 0; \
	 fi; \
	 echo "[learn] 今回の自動修正を汎用ポリシー（CLAUDE.md / prompts）へ反映中 ..."; \
	 PROMPT=$$(printf '%s\n\n---\n## 修正ジャーナル（今回の実行で発生した失敗と、解消までの試行）\n\n%s\n\n---\n## 最終 Dockerfile（テストを通した版）\n\n```dockerfile\n%s\n```\n\n---\n## 最終 docker-compose.yml（テストを通した版）\n\n```yaml\n%s\n```\n\n---\n## 最終 テストスクリプト（PASS した版）\n\n```bash\n%s\n```\n\n---\n## 編集対象のポリシーファイル\n\n- `%s`（CLAUDE.md）\n- `%s` 配下のプロンプト（analyze.md / dockerize.md / deploy-yaml.md / test.md / fix-dockerfile.md / fix-compose.md / fix-test.md）\n' \
	     "$$(cat "$$ABS_PROMPTS/learn.md")" \
	     "$$(cat "$$ABS_OUT/fix-journal.md")" \
	     "$$(cat "$$ABS_APP/Dockerfile" 2>/dev/null || echo '(なし)')" \
	     "$$(cat "$$ABS_APP/docker-compose.yml" 2>/dev/null || echo '(なし)')" \
	     "$$(cat "$$ABS_OUT/test-run.sh" 2>/dev/null || echo '(なし)')" \
	     "$$ABS_ROOT/CLAUDE.md" \
	     "$$ABS_PROMPTS") && \
	 claude --allowed-tools "Read,Edit,Glob,Grep,LS" -p "$$PROMPT" < /dev/null || \
	   echo "[learn] 警告: ポリシー学習ステップが失敗しました（生成物・テスト結果には影響しません）."; \
	 echo "[learn] 完了."

down:
	@PROJECT="$(APP_NAME)" && \
	 echo "[down] $$PROJECT のリソースを削除中 ..." && \
	 IMAGES=$$(docker ps -a \
	   --filter "label=com.docker.compose.project=$$PROJECT" \
	   --format "{{.Image}}" 2>/dev/null | sort -u) && \
	 if [ -f "$(APP_COMPOSE)" ]; then \
	   ABS_APP=$$(cd "$(APP_DIR_NORM)" && pwd) && \
	   docker compose -f "$$ABS_APP/docker-compose.yml" down --volumes --remove-orphans 2>/dev/null || true; \
	 else \
	   docker ps -a --filter "label=com.docker.compose.project=$$PROJECT" -q \
	     2>/dev/null | xargs -r docker rm -f 2>/dev/null || true; \
	   docker volume ls --filter "label=com.docker.compose.project=$$PROJECT" -q \
	     2>/dev/null | xargs -r docker volume rm 2>/dev/null || true; \
	 fi; \
	 [ -n "$$IMAGES" ] && printf '%s\n' $$IMAGES | xargs docker rmi -f 2>/dev/null || true; \
	 echo "[down] 完了."

clean:
	rm -rf _out
	rm -f "$(APP_DOCKERFILE)" "$(APP_COMPOSE)"
	@echo "Cleaned."

distclean: down clean

help:
	@echo "Usage: make <target> APP_DIR=<path-to-app>"
	@echo ""
	@echo "  analyze     Step 2: Analyze source → _out/<app>/design.md"
	@echo "  dockerfile  Step 3: Generate Dockerfile → apps/<app>/Dockerfile"
	@echo "  compose     Step 4: Generate docker-compose.yml → apps/<app>/docker-compose.yml"
	@echo "  generate    Step 3+4: dockerfile + compose (shorthand)"
	@echo "  deploy      Step 5: docker compose up --build"
	@echo "  test        Step 6: Generate and run container tests"
	@echo "  learn       Step 7: テスト全 PASS 後、今回の自動修正を CLAUDE.md / prompts へ汎用化して反映"
	@echo "  all         Run all steps"
	@echo "  down        コンテナ・ボリューム・イメージを停止・削除"
	@echo "  distclean   down + clean（生成ファイルもすべて削除）"
	@echo "  clean       Remove _out/ and generated Dockerfile/docker-compose.yml"
	@echo ""
	@echo "Place the app source under this directory first, then:"
	@echo "  make all APP_DIR=./my-app"

# ── Directory ────────────────────────────────────────────────────────────────

$(OUT_DIR):
	mkdir -p $@

# ── Step 2: Analyze source → design.md ──────────────────────────────────────

$(OUT_DIR)/design.md: | $(OUT_DIR)
	@echo "[analyze] Analyzing $(APP_DIR_NORM) ..."
	@ABS=$$(cd "$(APP_DIR_NORM)" && pwd) && \
	 HINT=$$(cat "$(OUT_DIR)/fix-hint.md" 2>/dev/null || echo "") && \
	 HINT_SECTION=$$([ -n "$$HINT" ] && printf '\n\n---\n## 前回の失敗情報（修正の参考にすること）\n\n%s' "$$HINT" || echo "") && \
	 PROMPT=$$(printf '%s\n\n---\n## Target Source Code\n\nPath: `%s`\n\nRead and analyze all relevant files in that directory.%s' \
	     "$$(cat $(PROMPTS)/analyze.md)" "$$ABS" "$$HINT_SECTION") && \
	 claude --allowed-tools "Read,Glob,Grep,LS" --add-dir "$$ABS" -p "$$PROMPT" > $@
	@echo "[analyze] → $@"

# ── Step 3: Dockerfile → apps/<app>/Dockerfile ───────────────────────────────

$(APP_DOCKERFILE): $(OUT_DIR)/design.md
	@echo "[generate] Generating Dockerfile ..."
	@ABS=$$(cd "$(APP_DIR_NORM)" && pwd) && \
	 PROMPT=$$(printf '%s\n\n---\n## Design Reference\n\n%s\n\n---\n## Build Context (ソースコードの絶対パス)\n\n`%s`\n\nCOPY 命令のパスはこのディレクトリを起点にする（`src/` プレフィックス不要）。' \
	     "$$(cat $(PROMPTS)/dockerize.md)" "$$(cat $(OUT_DIR)/design.md)" "$$ABS") && \
	 claude --allowed-tools "Read,Glob,Grep,LS" --add-dir "$$ABS" -p "$$PROMPT" | $(TRIM_DOCKERFILE) > $@
	@echo "[generate] → $@"

# ── Step 4: docker-compose.yml → apps/<app>/docker-compose.yml ───────────────

$(APP_COMPOSE): $(APP_DOCKERFILE) $(OUT_DIR)/design.md
	@echo "[generate] Generating docker-compose.yml ..."
	@ABS_APP=$$(cd "$(APP_DIR_NORM)" && pwd) && \
	 ABS_OUT=$$(cd "$(OUT_DIR)" && pwd) && \
	 mkdir -p "$$ABS_OUT/init-scripts" && \
	 PROMPT=$$(printf '%s\n\n---\n## Design Reference\n\n%s\n\n---\n## Dockerfile\n\n```dockerfile\n%s\n```\n\n---\n## Paths\n\n- build.context（ソースコード）: `%s`\n- dockerfile: `%s`\n- init-scripts（初期化スクリプト出力先）: `%s`' \
	    "$$(cat $(PROMPTS)/deploy-yaml.md)" \
	    "$$(cat $(OUT_DIR)/design.md)" \
	    "$$(cat $(APP_DOCKERFILE))" \
	    "$$ABS_APP" \
	    "$$ABS_APP/Dockerfile" \
	    "$$ABS_OUT/init-scripts") && \
	 claude --allowed-tools "Write" -p "$$PROMPT" | $(TRIM_COMPOSE) > $@
	@echo "[generate] → $@"

# ── Step 6: Test script ───────────────────────────────────────────────────────

$(OUT_DIR)/test-run.sh: $(APP_COMPOSE)
	@echo "[test] Generating test script ..."
	@ABS_APP=$$(cd "$(APP_DIR_NORM)" && pwd) && \
	 COMPOSE=$$(cat $(APP_COMPOSE)) && \
	 DESIGN=$$(cat $(OUT_DIR)/design.md 2>/dev/null || echo "") && \
	 RUNNING=$$(docker compose -f "$(APP_COMPOSE)" ps 2>/dev/null || echo "(not running)") && \
	 PROMPT=$$(printf '%s\n\n---\n## App: %s\n\n## Containers\n```\n%s\n```\n\n## docker-compose.yml\n```yaml\n%s\n```\n\n## Design\n%s' \
	     "$$(cat $(PROMPTS)/test.md)" "$(APP_NAME)" "$$RUNNING" "$$COMPOSE" "$$DESIGN") && \
	 FIXED=$$(claude --allowed-tools "" -p "$$PROMPT" | $(TRIM_SH)) && \
	 [ -n "$$FIXED" ] || { echo "[test] エラー: テストスクリプト生成が空でした（shebang #!/usr/bin/env bash で始まっていない可能性）"; exit 1; } && \
	 printf '%s\n' "$$FIXED" > $@ && chmod +x $@
	@echo "[test] → $@"
