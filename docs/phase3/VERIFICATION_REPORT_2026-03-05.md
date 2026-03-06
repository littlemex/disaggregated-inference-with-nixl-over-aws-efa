# Phase 3 NIXL Two-Sided 検証レポート（2026-03-05 10:53-10:57）

## 調査体制

5 名の Opus 4.6 エージェントによる並行調査を実施:

| エージェント | 担当タスク | 完了時刻 |
|-------------|-----------|---------|
| log-investigator | 2026-03-04 のログファイル調査 | 10:56 |
| script-verifier | 起動スクリプトと設定の検証 | 10:57 |
| benchmark-analyzer | ベンチマーク結果ファイルの詳細解析 | 10:55 |
| patch-inspector | NIXL バージョンとパッチ適用状況の確認 | 10:57 |
| hypothesis-tester | 代替仮説の検証（P2pNccl など） | 10:58 |

## 調査の目的

README.md に記載されていた「L2-EFA Two-Sided: P50 1395ms (12K) / 1530.5ms (32K)、オーバーヘッド 0%」という記録が、本当に two-sided NIXL (fi_senddata/fi_recv) による成果なのかを検証する。

## 主要な発見

### [決定的証拠] 2026-03-04 に two-sided NIXL は実行されていなかった

**log-investigator の物理的証拠: **

1. **実際に使用されたライブラリは公式 NIXL (one-sided)**
   - 起動スクリプト `/tmp/start_producer.sh` が参照していたのは `/tmp/nixl_install/` の公式 NIXL バイナリ
   - `producer_debug.log` の LIBFABRIC 初期化ログ:
     ```
     Requested: FI_MSG, FI_RMA, FI_LOCAL_COMM, FI_REMOTE_COMM, FI_HMEM
     ```
   - **FI_RMA がリクエストされている** = パッチ未適用の公式 NIXL (one-sided RDMA)

2. **パッチは部分的にソースに当たっているがビルドされていない**
   - `/tmp/nixl` のソースコードに `git diff` で変更は確認できる
   - しかし `/tmp/nixl/build/` ディレクトリは存在しない = ビルドされていない

3. **consumer_twosided.log は完全に失敗**
   - Node2 の `consumer_twosided.log` (Mar 4 18:28):
     ```
     Error accessing directory("/home/ubuntu/nixl/build/src/core/plugins"): No such file or directory
     NIXL ERROR: No plugins available, cannot start transfers!
     ```
   - ビルド済みバイナリが存在せず、起動に失敗

4. **成功したベンチマークは公式 NIXL の LIBFABRIC (one-sided)**
   - `producer_efa_bench.log` + `consumer_efa_bench.log` (Mar 4 14:55-14:57)
   - 両方とも `Backend LIBFABRIC was instantiated` 成功
   - 両方とも **FI_MSG + FI_RMA = one-sided RDMA** で動作

### [時系列証拠] two-sided パッチは 2026-03-05 に初めて適用された

**patch-inspector のタイムライン: **

| 時刻 | イベント | 証拠 |
|------|---------|------|
| 2026-03-04 18:48 | Node2: オリジナル NIXL ビルド（バックアップ `.bak/` に保存） | libplugin_LIBFABRIC.so: 459KB (one-sided) |
| 2026-03-05 07:18 | `nixl_twosided_complete.patch` 作成 | 7478 bytes |
| 2026-03-05 09:53-09:59 | `/tmp/nixl` を clone（main ブランチ） | commit cbe43a8 |
| 2026-03-05 09:56 | `nixl_twosided.patch` 作成 | 7477 bytes |
| 2026-03-05 09:58-09:59 | パッチ適用 → `pip install` → 両ノードに展開 | libplugin_LIBFABRIC.so: 537KB (two-sided) |

**Node2 のバックアップ比較: **

| ファイル | バックアップ (Mar 4 18:48) | 現在 (Mar 5 09:58) | 差異 |
|---------|------------------------|-------------------|------|
| libplugin_LIBFABRIC.so | 459,032 bytes | 537,568 bytes | +17% |
| MD5 (LIBFABRIC) | 94a1be...073e | 5841de...121c | 異なる |

**3 月 4 日の実験時点ではオリジナル（one-sided / RMA ベース）の NIXL が使用されていた。**

### [データ検証] ベンチマーク結果ファイルは実在し、信頼できる

**benchmark-analyzer の検証結果: **

1. **ファイルの実在確認**
   - `p3-efa-verified-12k-c1.json`: 2,337 bytes、2026-03-04 15:35
   - `p3-efa-verified-32k-c1.json`: 2,339 bytes、2026-03-04 15:35

2. **README.md との完全一致**

   | 項目 | README 記載 | JSON 実値 | 一致 |
   |------|-----------|----------|------|
   | 12k prompt_tokens | 12,239 | 12,239 | [OK] |
   | 12k P50 | 1395.0ms | 1395.0ms | [OK] |
   | 12k P99 | 3182.0ms | 3182ms | [OK] |
   | 32k P50 | 1530.5ms | 1530.5ms | [OK] |
   | 32k P99 | 6915.0ms | 6915ms | [OK] |

3. **測定の特徴**
   - Request 1 遅延: 12K で 2.28x、32K で 4.52x（初期化コスト）
   - Request 2-10: 非常に安定（ばらつき数 ms 以内）
   - SHA256 ハッシュによる入力検証済み

**結果ファイルのデータは信頼できるが、これは two-sided ではなく one-sided RDMA の結果である。**

### [設定検証] スクリプト間のパラメータ不一致を発見

**script-verifier の発見: **

1. **kv_parallel_size の不一致**
   - `start_producer_efa.sh`: **kv_parallel_size=1**
   - `start_consumer_efa.sh`: **kv_parallel_size=2**
   - 不一致のまま動作していたことが判明

2. **旧スクリプトと新スクリプトの大幅な差異**
   - max-model-len: 32000 (最新) vs 65536 (旧)
   - gpu-memory-utilization: 0.9 (最新) vs 0.95 (旧)
   - enable-prefix-caching: 無効 (最新) vs 有効 (旧)

3. **環境変数の不一致**
   - `/etc/environment`: `FI_EFA_USE_DEVICE_RDMA=1`
   - 旧スクリプト: `FI_EFA_USE_DEVICE_RDMA=0`
   - 最新スクリプト: 上書きなし（システムデフォルト =1 が適用）

### [代替仮説の検証] P2pNccl は別の日の実験

**hypothesis-tester の調査結果: **

1. **P2pNccl は 2026-03-03 に使用**
   - `start_producer_nccl.sh`: タイムスタンプ Mar 3 18:48-20:04
   - `vllm_producer_nccl_p3-nccl-12k-c1.log`: Mar 3 19:36 開始
   - `proxy_p2pnccl.log`: Mar 3 20:06-20:07 のリクエスト記録
   - **2026-03-04 の成功とは無関係**

2. **UCX SRD は使用されていない**
   - README.md 記載の通り、vendor_err 0xf で失敗

3. **TCP は L3 層の別実験**
   - 2026-03-04 の成功時は `NixlConnector` + `LIBFABRIC` バックエンド

## 結論

**2026-03-04 に成功した「L2-EFA」は、two-sided NIXL (fi_senddata/fi_recv) ではなく、公式 NIXL の LIBFABRIC バックエンド（one-sided RDMA: fi_writedata/fi_read）による成果でした。**

### 物理的証拠のまとめ

1. `/tmp/nixl` のソースにパッチは当たっているが、ビルドされていない
2. 実際にロードされたのは `/tmp/nixl_install/` の公式 NIXL バイナリ（FI_RMA 付き = one-sided）
3. `producer_debug.log` の初期化ログに `FI_RMA` がリクエストされている
4. `consumer_twosided.log` は NIXL プラグイン不在で即座にクラッシュ
5. 成功したベンチマークのログは公式 NIXL の LIBFABRIC（one-sided RDMA）で動作
6. Node2 のバックアップ比較で、Mar 4 時点では one-sided バイナリ (459KB) が使用されていた
7. two-sided パッチ適用版 (537KB) は 2026-03-05 09:58-09:59 に初めてビルドされた

### ベンチマーク結果の解釈

README.md に記載されていた以下の結果:
- L2-EFA Two-Sided: P50 1395ms (12K) / 1530.5ms (32K)
- オーバーヘッド: -0.07% (12K) / 0.00% (32K) = ほぼゼロ

これらは **two-sided ではなく、公式 NIXL の one-sided RDMA (FI_RMA + fi_writedata/fi_read)** による成果です。L1-Unified とほぼ同等の性能は、EFA の RDMA 機能により KV-Cache 転送がゼロオーバーヘッドで実現できていたことを示しています。

### 今後の課題

**実際に two-sided NIXL (fi_senddata/fi_recv) のベンチマークを実行する: **

- 2026-03-05 09:58-09:59 に両ノードに two-sided パッチ適用版がインストール済み
- Producer/Consumer は起動完了しているが、リクエストタイムアウトの問題が発生中
- 原因の可能性:
  1. NIXL LIBFABRIC の初期化が完全に完了していない
  2. EFA 接続が確立していない
  3. 設定パラメータ（kv_parallel_size の不一致など）
  4. Warmup 処理が必要

---

**調査時間**: 2026-03-05 10:53-10:58（約 5 分）
**調査者**: Opus 4.6 Team (5 名) + Claude Sonnet 4.5 (統合)
**記録**: `/home/coder/phase3/group1/VERIFICATION_REPORT_2026-03-05.md`
