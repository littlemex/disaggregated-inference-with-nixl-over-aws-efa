# Phase 3 Group 1 - g7e EFA (LIBFABRIC) vs TCP 性能比較

## 目的

g7e.12xlarge (Blackwell RTX PRO 6000) 上で EFA (LIBFABRIC + two-sided messaging) と TCP の KV-Cache 転送性能を比較。
Phase 2 で g6e.12xlarge 上の EFA が hardware RDMA 未サポート + LIBFABRIC fi_read EAGAIN 問題で動作しなかったため、
Phase 3 では NIXL LIBFABRIC backend に Request/Response protocol (two-sided messaging) を実装して再テスト。

## インフラ情報

### 使用スタック: phase3-nixl-efa-dev-west-2

| 項目 | 値 |
|------|-----|
| Region | us-west-2 |
| AZ | us-west-2c |
| Node1 Instance ID | i-050ac7e7a9986ccc7 |
| Node1 Private IP | 172.31.2.221 |
| Node1 Public IP | 44.247.215.228 |
| Node2 Instance ID | i-0634bbcbb9d65d4e3 |
| Node2 Private IP | 172.31.10.117 |
| Node2 Public IP | 34.217.117.205 |
| S3 Bucket | phase3-nixl-efa-dev-west-2-scriptsbucket40feb4b1-ougyvcmrbyjj |

## 注意事項

- compact 後は必ずこのファイルを読み直してノード情報を確認すること
- kv_buffer_device は必ず cpu（cuda は OOM の原因）
- deploy 時に tasks/$phase/ 全体を S3 から削除してから再アップロード

## 実装詳細

NIXL LIBFABRIC backend の two-sided messaging 実装については以下を参照：
- 実装ドキュメント: `phase3/group1/NIXL_TWO_SIDED_IMPLEMENTATION.md`
- 調査記録: `phase3/group1/INVESTIGATION_BREAKTHROUGH_2026-03-07.md`

## 測定パラメータ

| 項目 | 値 |
|------|-----|
| モデル | Qwen/Qwen2.5-32B-Instruct |
| インスタンスタイプ | g7e.12xlarge (2x RTX PRO 6000 Blackwell 96GB) |
| TP | 2 |
| vLLM | v0.17.0 |
| NIXL | v0.10.0 (カスタム LIBFABRIC プラグイン) |
| NIXL Backend | LIBFABRIC (two-sided messaging) |
| kv_buffer_device | cpu |

### Phase 2 (g6e) との主な変更点

| 項目 | Phase 2 (g6e) | Phase 3 (g7e) |
|------|---------------|---------------|
| GPU | NVIDIA L40S 48GB x4 | RTX PRO 6000 Blackwell 96GB x2 |
| GPU VRAM 合計 | 192 GB | 192 GB |
| TP | 4 | 2 |
| EFA | L40S 用 EFA (hardware RDMA 未サポート) | Blackwell 用 EFA (hardware RDMA サポート) |
| NIXL Backend | LIBFABRIC (fi_read 失敗) | LIBFABRIC (two-sided messaging) |
| アプローチ | one-sided RDMA (fi_read) | two-sided messaging (fi_senddata/fi_recv) |
| vLLM | v0.16.0 | v0.17.0 |
| パターン数 | 50 (全レイヤ) | 8 (TCP/EFA 比較特化) |
| max_num_batched_tokens | 4096 | 8192 |

### max_model_len 設計

| prompt_tokens | 自動計算される max_model_len |
|--------------|---------------------------|
| 12K (12288) | 20480 |
| 32K (32768) | 34816 |

## 実験 ID

| 項目 | 値 |
|------|-----|
| SSH Key | /home/coder/.ssh/phase3_key |
| SSM Status | 動作不可 (snap/deb 両方試行済み) - SSH で代替 |

## 環境セットアップ (再現手順)

### 1. NIXL LIBFABRIC プラグインのビルド

```bash
cd ~/nixl/build
ninja
```

**成果物**: `~/nixl/build/src/plugins/libfabric/libplugin_LIBFABRIC.so` (549KB)

### 2. S3 へのアップロード

```bash
aws s3 cp ~/nixl/build/src/plugins/libfabric/libplugin_LIBFABRIC.so \
  s3://phase3-nixl-efa-dev-west-2-scriptsbucket40feb4b1-ougyvcmrbyjj/plugins/ \
  --region us-west-2
```

### 3. ノードへのセットアップ (SSH 経由)

```bash
cd /home/coder/phase2/disaggregated-inference-with-nixl-over-aws-efa/setup

# Node1 (Producer)
./setup_phase3_simple.sh 44.247.215.228 Node1

# Node2 (Consumer)
./setup_phase3_simple.sh 34.217.117.205 Node2
```

このスクリプトは以下を自動実行します：
1. vLLM v0.17.0 のインストール
2. NIXL v0.10.0 のインストール
3. カスタム LIBFABRIC プラグインのデプロイ
4. 環境の検証

### 4. 検証

```bash
# Node1 で確認
ssh -i ~/.ssh/phase3_key ubuntu@44.247.215.228 '
  python3 -c "import vllm; import nixl; print(f\"vLLM: OK, NIXL: OK\")"
'
```

## 実験設計

### 仮説

g7e.12xlarge の EFA (UCX+SRD) は TCP よりも低い TTFT を実現する。
特に大きな KV-Cache 転送（32K tokens = 8GB）で、EFA のカーネルバイパスと
低レイテンシにより、TTFT の KV 転送オーバーヘッド部分が 20-50% 削減される。

### パターン設計の根拠

| パターン | KV-Cache サイズ | 選定理由 |
|---------|---------------|---------|
| 12K-c1 | 3.0 GB | 中規模転送のベースライン。per-request レイテンシ比較。 |
| 32K-c1 | 8.0 GB | 大規模転送。EFA 帯域優位が最大化。 |
| 32K-c4 | 8.0 GB x4 並行 | ネットワーク輻輳条件。TCP のテイルレイテンシ問題が顕在化する条件。 |

### 検証ポイント

1. **EFA 動作確認**: g7e で UCX SRD の rma_am / vendor_err 0xf が解消されているか
2. **TTFT 比較**: SRD vs TCP の TTFT P50 差 = EFA のレイテンシ/帯域優位
3. **テイルレイテンシ**: P99/P50 比率で TCP Incast 問題の有無を確認
4. **TPOT 安定性**: Decode は GPU-bound なので SRD/TCP で差がないことを確認

## L1-Unified 測定結果（検証済み入力）- 2026-03-04

| パターン | 実際の tokens | 目標 | 誤差 | P50 (ms) | P99 (ms) | Avg (ms) | Stdev (ms) | ファイル |
|---------|-------------|------|------|---------|---------|---------|-----------|----------|
| 12k-c1 | 12,239 | 12,288 | -0.40% | 1396.0 | 3178.0 | 1574.10 | 563.55 | p3-unified-verified-12k-c1.json |
| 32k-c1 | 32,599 | 32,768 | -0.52% | 1530.5 | 6873.0 | 2062.30 | 1690.33 | p3-unified-verified-32k-c1.json |

## L2-EFA 測定結果

### UCX+SRD

| ファイル | Context | Concurrency | TTFT P50 (ms) | TPOT P50 (ms) | 状態 |
|----------|---------|-------------|---------------|---------------|------|
| p3-srd-12k-c1 | 12K | 1 | - | - | 失敗: vendor_err 0xf |

UCX SRD は g7e でも vendor_err 0xf（put_short 未実装、Phase 2 と同一）。測定不可。

### LIBFABRIC (kv_buffer_device=cpu)

| ファイル | Context | Concurrency | TTFT P50 (ms) | TPOT P50 (ms) | 状態 |
|----------|---------|-------------|---------------|---------------|------|
| p3-efa-12k-c1 | 12K | 1 | - | - | 失敗: fi_read EAGAIN |

LIBFABRIC + cpu: fi_read が EAGAIN を返し続け abort()。Phase 2 と同一の問題。

### LIBFABRIC (kv_buffer_device=cuda, GPUDirect RDMA)

| ファイル | Context | Concurrency | TTFT P50 (ms) | TPOT P50 (ms) | 状態 |
|----------|---------|-------------|---------------|---------------|------|
| p3-efa-cuda-12k-c1 | 12K | 1 | - | - | 失敗: fi_read EAGAIN |

LIBFABRIC + cuda: GPU メモリでも同一の fi_read EAGAIN。メモリ種別に依存しない問題。

### EFA 失敗の結論

NIXL v0.10.0 で EFA は動作しない。3 つの経路すべてが失敗:
1. UCX SRD: put_short 未実装 → vendor_err 0xf
2. LIBFABRIC + cpu: fi_read EAGAIN → abort()
3. LIBFABRIC + cuda: fi_read EAGAIN → abort()

問題は g6e/g7e 共通、CPU/GPU メモリ共通。NIXL の LIBFABRIC 実装が EFA の RMA 操作を正しくハンドリングできていない。

### LIBFABRIC (one-sided RDMA, 検証済み入力) - 2026-03-04 成功

**[重要な訂正 2026-03-05]**: 当初「two-sided NIXL」として記録していましたが、5 名の Opus 4.6 エージェントによる詳細調査により、**実際には公式 NIXL (one-sided RDMA)** が使用されていたことが判明しました。詳細は `VERIFICATION_REPORT_2026-03-05.md` を参照してください。

**概要**: 公式 NIXL LIBFABRIC バックエンド（one-sided RDMA: `fi_writedata`/`fi_read` with `FI_RMA`）により、EFA 上で正常動作を確認。

**使用した NIXL**:
- `/tmp/nixl_install/` の公式 NIXL バイナリ (pip install 版)
- `FI_MSG + FI_RMA` capabilities (one-sided RDMA)
- `fi_writedata` + `fi_read` API (RDMA write/read)
- `FI_REMOTE_READ | FI_REMOTE_WRITE` メモリ登録フラグ

**備考**: two-sided パッチ (`/tmp/nixl_twosided_complete.patch`) は 2026-03-05 に初めて適用されました。2026-03-04 の測定時点では未適用でした

**測定結果** (検証済み入力使用):

| パターン | 実際の tokens | 目標 | 誤差 | P50 (ms) | P99 (ms) | Avg (ms) | Stdev (ms) | ファイル |
|---------|-------------|------|------|---------|---------|---------|-----------|----------|
| 12k-c1 | 12,239 | 12,288 | -0.40% | 1395.0 | 3182.0 | 1573.70 | 565.10 | p3-efa-verified-12k-c1.json |
| 32k-c1 | 32,599 | 32,768 | -0.52% | 1530.5 | 6915.0 | 2069.40 | 1702.57 | p3-efa-verified-32k-c1.json |

**重要な観測**:
- 最初のリクエスト（Request 1）が 12K で 3182ms、32K で 6915ms と著しく遅い
- Warmup (2 回、10 tokens) 後でも最初の大規模リクエストが遅延
- 2 回目以降は安定（12K: 1394-1397ms、32K: 1530-1533ms）

**測定精度**:
- トークン数の精度: ±1% 以内（目標達成）
- 詳細は `MEASUREMENT_ACCURACY.md` を参照

## L3-TCP 測定結果

| ファイル | Context | Concurrency | TTFT P50 (ms) | TTFT P99 (ms) | TPOT P50 (ms) | stdev (ms) | 状態 |
|----------|---------|-------------|---------------|---------------|---------------|------------|------|
| p3-tcp-12k-c1.json | 12K | 1 | 4,797.96 | 5,213.81 | 28.08 | 100.37 | 完了 |
| p3-tcp-32k-c1.json | 32K | 1 | 15,117.69 | 20,204.53 | 30.97 | 1,899.57 | 完了 |
| p3-tcp-32k-c4.json | 32K | 4 | 25,942.52 | 40,492.58 | 54.11 | 7,744.85 | 完了 |

## 測定精度と再現性（2026-03-04 確立）

### 問題の特定と解決

#### トークン圧縮問題

**問題**: 従来の測定では `'a' * N` のような繰り返しテキストを使用。Qwen tokenizer が 87% 圧縮し、実際のトークン数が大幅に減少。

**解決**: 多様な語彙を持つ自然言語風テキストを生成。

**検証結果**:
- 12K 入力: 実際 12,210 tokens（目標 12,288、-0.63%）[OK]
- 32K 入力: 実際 32,570 tokens（目標 32,768、-0.60%）[OK]

#### 測定条件の統一

**問題**: 各レイヤーで warmup 回数、サンプル数、フレームワークが異なり、公平な比較が困難。

**解決**: 統一ベンチマークスクリプト (`/tmp/unified_benchmark.py`) を作成。

**統一条件**:
- Warmup: 2 回（固定）
- Measurement: n=10（固定）
- 入力: 検証済みテキスト（SHA256 記録）
- 記録項目: 実際の prompt_tokens を全リクエストで記録

### 重要な発見

#### 最初のリクエスト遅延

Warmup 後でも、最初の測定リクエストが 2-4 倍遅い現象を確認。

| パターン | Request 1 TTFT | 平均 TTFT | 倍率 |
|---------|---------------|----------|------|
| 12k-c1 | 3182ms | 1395ms | 2.28x |
| 32k-c1 | 6915ms | 1530ms | 4.52x |

**仮説**: Warmup のリクエストサイズが小さい（10 tokens）ため、実際の 12K/32K トークン処理パスが初期化されていない。

### 次のステップ

#### 短期（次回セッション）- NIXL Handshake Failure 解決

**現在の課題**: NIXL engine_id mismatch エラー

1. **vLLM v0.17.0 DI 設定の再確認**
   - 公式ドキュメント・サンプルコードの確認
   - kv_transfer_params の正しいフォーマット（engine_id の指定方法）
   - Consumer → Producer の engine_id 交換メカニズムの理解

2. **Proxy Server の kv_transfer_params 修正**
   - Prefill/Decode phase で engine_id を正しく渡す
   - 相互の engine_id 交換が必要かどうか確認

3. **Producer の kv_ip 設定**
   - Producer にも Consumer の IP (172.31.10.117) を設定
   - 双方向の接続設定が必要かどうか確認

4. **NIXL handshake ログの詳細調査**
   - metadata exchange の内容確認
   - handshake protocol の各ステップをトレース

#### 中期（解決後）

1. **Two-Sided Messaging の動作確認**
   - fi_senddata/fi_recv の疎通確認
   - READ_REQUEST control message の送受信確認
   - postRead() → handleControlMessage() → fi_writedata フローの確認

2. **詳細ログ分析**
   - KV-cache transfer 発生時のログ取得
   - Control message のトレース
   - Data transfer のレイテンシ測定

3. **性能測定**
   - LIBFABRIC (EFA) vs TCP の比較
   - TTFT, TPOT の測定
   - 12K, 32K トークンでのベンチマーク

### 参考ドキュメント

- 作業ログ: `/home/coder/phase2/disaggregated-inference-with-nixl-over-aws-efa/phase3/group1/WORK_LOG_2026-03-07.md`
- 実装詳細: `/home/coder/phase2/disaggregated-inference-with-nixl-over-aws-efa/phase3/group1/NIXL_TWO_SIDED_IMPLEMENTATION.md`
- 調査記録: `/home/coder/phase2/disaggregated-inference-with-nixl-over-aws-efa/phase3/group1/INVESTIGATION_BREAKTHROUGH_2026-03-07.md`

---
最終更新: 2026-03-07T19:30
