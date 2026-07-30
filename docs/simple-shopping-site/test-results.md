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
