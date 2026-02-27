# Phase 15 測定実行ガイド

## 概要

Phase 15 は Qwen2.5-32B-Instruct モデルを使用した長コンテキスト（4K-100K tokens）の測定です。
100K トークンのプロンプトを処理するには vLLM サーバーの `max_model_len` を段階的に変更する必要があるため、測定を 3 つのステージに分けて実行します。

## 前提条件

- インスタンスタイプ: g7e.12xlarge x 2 (primary) または g5.12xlarge x 2 (4x GPU per node)
- TP size: 4 (全 4 GPUs を使用)
- モデル: Qwen/Qwen2.5-32B-Instruct
- vLLM version: v0.15.1+
- 複数のインスタンスタイプで測定することで、インスタンス依存性を把握します

## 測定前のバリデーション（必須）

Phase 15 測定を開始する前に、以下の 3 つのバリデーションを実行してください。

### 1. ベースライン帯域幅測定（所要時間: 約 1 時間）

```bash
cd /work/data-science/disaggregated-inference-with-nixl-over-aws-efa/experiments/scripts

# NODE1_IP, NODE2_IP を実際の Private IP に置き換えてください
./measure_baseline_bandwidth.sh <node1_private_ip> <node2_private_ip> ../results/baseline_bandwidth.json
```

**測定内容: **
- TCP 帯域幅（iperf3, 8 並列ストリーム）
- EFA 帯域幅（fi_rdm_bw, 16MB メッセージサイズ）
- EFA/TCP 比率の算出

**期待される結果: **
- TCP: 20-30 Gbps（単一ストリーム制限あり）
- EFA: 80-100 Gbps（RDMA の理論最大帯域幅）
- EFA/TCP 比率: 3-5x

### 2. GPUDirect RDMA 検証（所要時間: 約 15 分）

```bash
cd /work/data-science/disaggregated-inference-with-nixl-over-aws-efa/experiments/scripts

./check_gpudirect_rdma.sh ../results/gpudirect_rdma_status.json
```

**検証内容: **
- GPU-NIC トポロジー（nvidia-smi topo -m）
- EFA デバイス情報（ibv_devinfo）
- PCIe 接続確認（PIX vs SYS）
- GPUDirect RDMA の有効/無効判定

**期待される結果: **
- `gpudirect_status`: `"likely_enabled"`
- GPU-NIC 接続: `"PIX"`（同一 PCIe スイッチ）
- EFA デバイス数: 1 以上

GPUDirect RDMA が無効の場合、20K トークン（2.7GB）の KV-Cache 転送に ~168ms の CPU bounce buffer オーバーヘッドが追加されます。

### 3. スモークテスト（所要時間: 約 1 時間）

20K tokens と 100K tokens で各 1 リクエストを実行し、基本動作を確認します。

```bash
cd /work/data-science/disaggregated-inference-with-nixl-over-aws-efa/experiments

# 20K tokens スモークテスト（max_model_len=32768 で起動済みの vLLM を想定）
./run_experiment.sh phase15 run p15-L1-unified-20k-c1 --warmup 1 --iterations 1

# 100K tokens スモークテスト（vLLM を max_model_len=131072 で再起動後）
./run_experiment.sh phase15 run p15-L1-unified-100k-c1 --warmup 1 --iterations 1
```

**確認項目: **
- エラーなく完了すること
- TTFT が妥当な範囲であること（20K: ~2-3 秒、100K: ~10-15 秒）
- Proxy タイミングヘッダーが記録されていること（`proxy_prefill_time`, `proxy_kv_extract_time`）

## Phase 15 本測定の実行

### Stage 1: 4K-20K トークン（max_model_len=32768）

**vLLM サーバー起動コマンド: **

```bash
# Unified モード（Node1 のみ）
python -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen2.5-32B-Instruct \
  --tensor-parallel-size 4 \
  --max-model-len 32768 \
  --max-num-batched-tokens 32768 \
  --gpu-memory-utilization 0.9 \
  --enable-prefix-caching \
  --port 8100

# Disaggregated モード（Prefill: Node1, Decode: Node2）
# Prefill ノード（Node1）
python -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen2.5-32B-Instruct \
  --tensor-parallel-size 4 \
  --max-model-len 32768 \
  --max-num-batched-tokens 32768 \
  --gpu-memory-utilization 0.9 \
  --kv-transfer-config '{"kv_connector": "NixlConnector", "kv_role": "producer", "kv_rank": 0, "kv_parallel_size": 2, "kv_ip": "172.31.x.x", "kv_port": 15000}' \
  --port 8100

# Decode ノード（Node2）
python -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen2.5-32B-Instruct \
  --tensor-parallel-size 4 \
  --max-model-len 32768 \
  --max-num-batched-tokens 32768 \
  --gpu-memory-utilization 0.9 \
  --kv-transfer-config '{"kv_connector": "NixlConnector", "kv_role": "consumer", "kv_rank": 1, "kv_parallel_size": 2, "kv_ip": "172.31.y.y", "kv_port": 15000}' \
  --port 8200
```

**測定実行: **

```bash
cd /work/data-science/disaggregated-inference-with-nixl-over-aws-efa/experiments

# L0: 4K トークン（Unified, EFA, TCP のベースライン比較）
./run_experiment.sh phase15 run p15-L0-unified-4k-c1
./run_experiment.sh phase15 run p15-L0-unified-4k-c1-nocache
./run_experiment.sh phase15 run p15-L0-efa-4k-c1
./run_experiment.sh phase15 run p15-L0-tcp-4k-c1

# L1: 20K トークン（Unified のみ、Prefix Cache ON）
./run_experiment.sh phase15 run p15-L1-unified-20k-c1

# L2: 20K トークン（EFA vs TCP 比較、Prefix Cache OFF）
./run_experiment.sh phase15 run p15-L2-efa-20k-c1
./run_experiment.sh phase15 run p15-L2-tcp-20k-c1
```

**所要時間: ** 約 3-4 時間

### Stage 2: 50K トークン（max_model_len=65536）

**vLLM サーバー再起動: **

```bash
# Unified モード: --max-model-len 65536 --max-num-batched-tokens 65536 に変更
# Disaggregated モード: 両ノードで --max-model-len 65536 --max-num-batched-tokens 65536 に変更
```

**測定実行: **

```bash
# L1: 50K トークン（Unified のみ）
./run_experiment.sh phase15 run p15-L1-unified-50k-c1

# L2: 50K トークン（EFA vs TCP 比較）
./run_experiment.sh phase15 run p15-L2-efa-50k-c1
./run_experiment.sh phase15 run p15-L2-tcp-50k-c1
```

**所要時間: ** 約 4-5 時間

### Stage 3: 100K トークン（max_model_len=131072）

**vLLM サーバー再起動: **

```bash
# Unified モード: --max-model-len 131072 --max-num-batched-tokens 131072 に変更
# Disaggregated モード: 両ノードで --max-model-len 131072 --max-num-batched-tokens 131072 に変更
```

**測定実行: **

```bash
# L1: 100K トークン（Unified のみ）
./run_experiment.sh phase15 run p15-L1-unified-100k-c1

# L2: 100K トークン（EFA vs TCP 比較）
./run_experiment.sh phase15 run p15-L2-efa-100k-c1
./run_experiment.sh phase15 run p15-L2-tcp-100k-c1
```

**所要時間: ** 約 5-6 時間

## 全ステージの推定所要時間

- **Stage 1 (4K-20K)**: 3-4 時間
- **Stage 2 (50K)**: 4-5 時間
- **Stage 3 (100K)**: 5-6 時間
- **合計**: 12-15 時間

## 測定結果の確認

測定結果は `experiments/results/phase15/` に保存されます。各結果 JSON には以下のデータが含まれます：

```json
{
  "metadata": {
    "phase": 15,
    "backend": "efa",
    "prompt_tokens": 20000,
    "max_tokens": 100,
    "instance_type": "p5.48xlarge",
    ...
  },
  "results": {
    "ttft": {
      "mean": 2345.67,
      "p50": 2300.12,
      "p95": 2890.34,
      "p99": 3012.45
    },
    "ttft_bimodal": {
      "cv": 0.15,
      "is_bimodal": false
    },
    "tpot": {
      "mean": 12.34,
      "p50": 12.10,
      "p95": 14.56,
      "p99": 15.67
    },
    "tpot_bimodal": {
      "cv": 0.08,
      "is_bimodal": false
    },
    "proxy_prefill_time": {
      "mean": 1234.56,
      "p50": 1200.00,
      "p95": 1450.00
    },
    "proxy_kv_extract_time": {
      "mean": 234.56,
      "p50": 220.00,
      "p95": 280.00
    },
    "throughput_rps": 0.42
  }
}
```

## トラブルシューティング

### OOM エラーが発生する場合

- `--gpu-memory-utilization` を 0.8 に下げる
- `--max-num-batched-tokens` を小さくする（例: 16384）

### TTFT が異常に長い場合

- GPUDirect RDMA が無効になっている可能性 → `check_gpudirect_rdma.sh` を再実行
- Proxy オーバーヘッドの可能性 → `proxy_prefill_time`, `proxy_kv_extract_time` を確認

### 二峰性分布（`ttft_bimodal.is_bimodal: true`）が検出される場合

- NIXL の状態遷移によるもの（Phase A: 遅い、Phase B: 速い）
- warmup を増やして Phase B に到達させる（例: warmup=30）

## 注意事項

1. **Prefix Cache の扱い: **
   - Unified モード（L1）: Prefix Cache ON
   - Disaggregated モード（L2）: Prefix Cache OFF
   - 公平な比較のため、L0 に Unified + Prefix Cache OFF パターンを追加済み

2. **max_model_len の制限: **
   - Stage 1 (32768): 最大 32K トークンまで処理可能
   - Stage 2 (65536): 最大 65K トークンまで処理可能
   - Stage 3 (131072): 最大 131K トークンまで処理可能
   - **重要**: Stage を跨ぐ場合は必ず vLLM サーバーを再起動すること

3. **Proxy タイミングデータ: **
   - CRITICAL-1 修正により、Proxy 内部タイムスタンプが集約結果 JSON に含まれるようになりました
   - `proxy_prefill_time`: Prefill フェーズの時間（KV-Cache 生成）
   - `proxy_kv_extract_time`: KV-Cache パラメータ抽出の時間（通常 <1ms）

---

**最終更新**: 2026-02-27
**対応修正**: CRITICAL-1, HIGH-1, HIGH-2, HIGH-3, MEDIUM-1, MEDIUM-2, MEDIUM-3
