APP_DIR  ?=
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

# '#' は Make のコメント文字のため octal エスケープで定義する
HASH := $(shell printf '\043')

# Claude 出力から先頭の説明文と末尾の Markdown フェンス・説明文を除去するフィルター
TRIM_DOCKERFILE = awk '/^FROM /{f=1} f{if(/^```|^---/)exit; print}'
TRIM_COMPOSE    = awk '/^(version:|services:|name:|networks:|volumes:)/{f=1} f{if(/^```/)exit; print}'
TRIM_SH         = awk '/^$(HASH)!/{f=1} f{if(/^```/)exit; print}'

.PHONY: all analyze dockerfile compose generate deploy test clean down distclean help

all: analyze dockerfile compose deploy test

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
	 for ATTEMPT in 1 2 3 4; do \
	   echo "[deploy] デプロイ開始 (試行 $$ATTEMPT/4) ..."; \
	   if docker compose -f "$$ABS_APP/docker-compose.yml" up -d --build > /tmp/wraptainer-deploy.txt 2>&1; then \
	     docker compose -f "$$ABS_APP/docker-compose.yml" ps; \
	     echo "[deploy] 完了."; \
	     exit 0; \
	   fi; \
	   cat /tmp/wraptainer-deploy.txt; \
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
	   if [ "$$ATTEMPT" = "1" ]; then \
	     echo "[deploy] Dockerfile を自動修正中 ..."; \
	     DOCKERFILE=$$(cat "$$ABS_APP/Dockerfile"); \
	     PROMPT=$$(printf '%s\n\n## ビルドエラー\n```\n%s\n```\n\n## 現在の Dockerfile\n```dockerfile\n%s\n```\n\n## ソースコードパス\n`%s`' \
	         "$$(cat "$$ABS_PROMPTS/fix-dockerfile.md")" "$$ERROR" "$$DOCKERFILE" "$$ABS_APP") && \
	     FIXED=$$(claude --allowed-tools "Read,Glob,Grep,LS" --add-dir "$$ABS_APP" -p "$$PROMPT" | $(TRIM_DOCKERFILE)) && \
	     [ -n "$$FIXED" ] && printf '%s\n' "$$FIXED" > "$$ABS_APP/Dockerfile" || echo "[deploy] 警告: 修正出力が空のため Dockerfile を維持します."; \
	     echo "[deploy] Dockerfile を修正しました."; \
	   elif [ "$$ATTEMPT" = "2" ]; then \
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
	 for ATTEMPT in 1 2 3 4; do \
	   echo "[test] テスト実行 (試行 $$ATTEMPT/4) ..."; \
	   bash "$$ABS_OUT/test-run.sh" > "$$ABS_OUT/test-results.md" 2>&1; TEST_RC=$$?; \
	   cat "$$ABS_OUT/test-results.md"; \
	   if [ $$TEST_RC -eq 0 ]; then \
	     echo "[test] 完了."; \
	     exit 0; \
	   fi; \
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
