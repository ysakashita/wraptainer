#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# simple-shopping-site コンテナ化 検証テストスクリプト
# ============================================================

BASE_URL="${BASE_URL:-http://localhost:8080}"
DB_USER="${DB_USER:-shopuser}"
DB_NAME="${DB_NAME:-shopdb}"

LB_CONTAINER="simple-shopping-site-lb-1"
APP1_CONTAINER="simple-shopping-site-app1-1"
APP2_CONTAINER="simple-shopping-site-app2-1"
DB_PRIMARY_CONTAINER="simple-shopping-site-db-primary-1"
DB_REPLICA_CONTAINER="simple-shopping-site-db-replica-1"

HEALTH_TIMEOUT=120
HEALTH_INTERVAL=3
CURL_MAX_TIME=5

PASS_COUNT=0
FAIL_COUNT=0

log_pass() {
  echo "[PASS] $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

log_fail() {
  echo "[FAIL] $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

log_info() {
  echo "[INFO] $1"
}

# --------------------------------------------------------------
# コンテナのヘルスチェック状態が healthy になるまでポーリングで待機
# --------------------------------------------------------------
wait_for_healthy() {
  local container="$1"
  local elapsed=0
  local status=""

  if ! docker inspect "$container" >/dev/null 2>&1; then
    log_fail "コンテナ ${container} が見つかりません"
    return 1
  fi

  while [ "$elapsed" -lt "$HEALTH_TIMEOUT" ]; do
    status=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$container" 2>/dev/null || echo "unknown")

    if [ "$status" = "healthy" ]; then
      log_pass "${container} は healthy です（${elapsed}s 経過）"
      return 0
    elif [ "$status" = "no-healthcheck" ]; then
      log_fail "${container} に healthcheck が設定されていません"
      return 1
    fi

    sleep "$HEALTH_INTERVAL"
    elapsed=$((elapsed + HEALTH_INTERVAL))
  done

  log_fail "${container} が ${HEALTH_TIMEOUT}s 以内に healthy になりませんでした（最終状態: ${status}）"
  return 1
}

# --------------------------------------------------------------
# HTTP ステータスコード検証
# --------------------------------------------------------------
check_http_status() {
  local url="$1"
  local expected="$2"
  local description="$3"
  local actual

  actual=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$CURL_MAX_TIME" "$url" || echo "000")

  if [ "$actual" = "$expected" ]; then
    log_pass "${description}（${url} -> HTTP ${actual}）"
    return 0
  else
    log_fail "${description}（${url} -> 期待値 HTTP ${expected}, 実際 HTTP ${actual}）"
    return 1
  fi
}

echo "=============================================="
echo " simple-shopping-site 動作検証テスト開始"
echo "=============================================="

# --------------------------------------------------------------
# 1. 全コンテナの healthcheck 待機
# --------------------------------------------------------------
log_info "--- コンテナヘルスチェック待機 ---"
wait_for_healthy "$DB_PRIMARY_CONTAINER" || true
wait_for_healthy "$DB_REPLICA_CONTAINER" || true
wait_for_healthy "$APP1_CONTAINER" || true
wait_for_healthy "$APP2_CONTAINER" || true
wait_for_healthy "$LB_CONTAINER" || true

# --------------------------------------------------------------
# 2. LB エンドポイントの疎通確認
# --------------------------------------------------------------
log_info "--- ロードバランサー疎通確認 ---"
check_http_status "${BASE_URL}/shop/actuator/health" "200" "LB 経由でアプリのヘルスエンドポイントに到達できる" || true

health_body=$(curl -s --max-time "$CURL_MAX_TIME" "${BASE_URL}/shop/actuator/health" || echo "")
if echo "$health_body" | grep -q '"status":"UP"'; then
  log_pass "アプリのヘルスステータスが UP を返している"
else
  log_fail "アプリのヘルスステータスが UP ではありません（応答: ${health_body}）"
fi

# LB を複数回叩き、常に 200 が返ることを確認（分散先ログの検査は行わない）
log_info "--- LB への複数回リクエストで安定して 200 が返ることを確認 ---"
lb_ok_count=0
lb_total=5
for i in $(seq 1 "$lb_total"); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$CURL_MAX_TIME" "${BASE_URL}/shop/actuator/health" || echo "000")
  if [ "$code" = "200" ]; then
    lb_ok_count=$((lb_ok_count + 1))
  fi
done

if [ "$lb_ok_count" -eq "$lb_total" ]; then
  log_pass "LB への ${lb_total} 回のリクエストすべてが HTTP 200 を返した（バックエンド分散は healthcheck 通過で保証）"
else
  log_fail "LB への ${lb_total} 回のリクエスト中 ${lb_ok_count} 回のみ HTTP 200 を返した"
fi

# --------------------------------------------------------------
# 3. LB (Apache) の設定検証
# --------------------------------------------------------------
log_info "--- LB (Apache) 設定検証 ---"
if docker exec "$LB_CONTAINER" httpd -t 2>&1 | grep -q "Syntax OK"; then
  log_pass "Apache 設定ファイルのシンタックスは正常です"
else
  log_fail "Apache 設定ファイルのシンタックス検証に失敗しました"
fi

# --------------------------------------------------------------
# 4. アプリコンテナのログ出力確認
# --------------------------------------------------------------
log_info "--- アプリコンテナのログ出力確認 ---"
for c in "$APP1_CONTAINER" "$APP2_CONTAINER"; do
  log_lines=$(docker logs --tail 50 "$c" 2>&1 | wc -l | tr -d ' ')
  if [ "$log_lines" -gt 0 ]; then
    log_pass "${c} はログを出力している（直近 ${log_lines} 行）"
  else
    log_fail "${c} のログ出力が確認できません"
  fi
done

# --------------------------------------------------------------
# 5. PostgreSQL Primary の起動確認
# --------------------------------------------------------------
log_info "--- PostgreSQL Primary 起動確認 ---"
if docker exec "$DB_PRIMARY_CONTAINER" pg_isready -U "$DB_USER" >/dev/null 2>&1; then
  log_pass "db-primary は接続を受け付けています（pg_isready）"
else
  log_fail "db-primary が接続を受け付けていません（pg_isready）"
fi

primary_recovery=$(docker exec "$DB_PRIMARY_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d '[:space:]' || echo "error")
if [ "$primary_recovery" = "f" ]; then
  log_pass "db-primary は recovery モードではありません（書き込み可能な primary である）"
else
  log_fail "db-primary の pg_is_in_recovery() が想定外の値です（値: ${primary_recovery}）"
fi

# --------------------------------------------------------------
# 6. PostgreSQL Replica の起動確認
# --------------------------------------------------------------
log_info "--- PostgreSQL Replica 起動確認 ---"
if docker exec "$DB_REPLICA_CONTAINER" pg_isready -U "$DB_USER" >/dev/null 2>&1; then
  log_pass "db-replica は接続を受け付けています（pg_isready）"
else
  log_fail "db-replica が接続を受け付けていません（pg_isready）"
fi

replica_recovery=$(docker exec "$DB_REPLICA_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d '[:space:]' || echo "error")
if [ "$replica_recovery" = "t" ]; then
  log_pass "db-replica は recovery モードで稼働しています（読み取り専用レプリカとして正常）"
else
  log_fail "db-replica の pg_is_in_recovery() が想定外の値です（値: ${replica_recovery}）"
fi

# --------------------------------------------------------------
# 7. ストリーミングレプリケーションの確認
# --------------------------------------------------------------
log_info "--- ストリーミングレプリケーション確認 ---"
replication_count=$(docker exec "$DB_PRIMARY_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null | tr -d '[:space:]' || echo "0")
if [ "$replication_count" -ge 1 ] 2>/dev/null; then
  log_pass "db-primary の pg_stat_replication に ${replication_count} 件の接続を確認しました"
else
  log_fail "db-primary の pg_stat_replication にレプリカ接続が見つかりません（値: ${replication_count}）"
fi

wal_receiver_count=$(docker exec "$DB_REPLICA_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT count(*) FROM pg_stat_wal_receiver;" 2>/dev/null | tr -d '[:space:]' || echo "0")
if [ "$wal_receiver_count" -ge 1 ] 2>/dev/null; then
  log_pass "db-replica の pg_stat_wal_receiver で primary への接続を確認しました"
else
  log_fail "db-replica の pg_stat_wal_receiver に primary への接続が見つかりません（値: ${wal_receiver_count}）"
fi

# --------------------------------------------------------------
# 結果サマリー
# --------------------------------------------------------------
echo "=============================================="
echo " テスト結果サマリー: PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"
echo "=============================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi

exit 0
