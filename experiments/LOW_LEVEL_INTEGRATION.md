# Low-Level Network Measurement Integration

Phase 3 ツール（fi_pingpong, NIXLBench, KVBench, ucx_perftest）を
既存の実験システムに統合し、E2E 測定の裏付けとなる低レベルネットワーク測定を提供する。

---

## 1. 目的

Phase 14/15 の E2E 測定で得られた以下の観察に対して、
低レベルツールによる **実測ベースの証拠** を提供する。

| 観察 | 現在の根拠 | 確度 | 低レベル測定後の確度 |
|------|-----------|------|-------------------|
| TPOT のバックエンド独立性 | E2E 推論 | 中 | 高（NIXLBench で転送時間を直接測定） |
| TCP c=16 の 2.72x 劣化 | IEEE Micro 2020 類似 | 中 | 高（fi_pingpong, NIXLBench で直接観測） |
| 12K token の 7.31x 乖離 | 複数要因の推測 | 低 | 高（KVBench で各要因を分離測定） |
| EFA 4-tier staircase | E2E 観察 | 中 | 高（NIXLBench many_to_one で再現） |

## 2. アーキテクチャ

```
experiments/
  experiment-plans/
    phase-low-level.json          # 低レベル測定の実験計画（新規）
  templates/
    low-level-fi-pingpong.json.jinja2    # fi_pingpong テンプレート（新規）
    low-level-nixlbench.json.jinja2      # NIXLBench テンプレート（新規）
    low-level-kvbench.json.jinja2        # KVBench テンプレート（新規）
    low-level-ucx-perftest.json.jinja2   # ucx_perftest テンプレート（新規）
  scripts/
    run_low_level_tools.py        # 測定実行 + MLflow 記録（新規）
    analyze_correlation.py        # E2E vs 低レベル相関分析（新規）
  task-definitions/
    phase-low-level/              # 自動生成（generate_tasks.py で生成）
      pll-fi-pingpong-efa-default.json
      pll-nixlbench-efa-55m.json
      pll-kvbench-efa-12k.json
      ...
  results/
    low-level/                    # 測定結果 JSON
    correlation-analysis.json     # 相関分析レポート
    plots/                        # matplotlib グラフ
```

**設計原則**: Phase 14 の設計思想（must-read.md）を厳守。

- task_runner.sh は不変（変更禁止）
- 全測定パターンは JSON task 定義で記述
- JSON ファイルでリモートにスクリプトを流し込み実行
- 再現性最重視: 全条件を JSON と MLflow に記録

## 3. ツール一覧

### 3.1 fi_pingpong / fi_rma_pingpong (Layer L0)

**目的**: 純粋な EFA ネットワークレイテンシの測定

**得られる情報**:
- ネットワーク層の基本レイテンシ（数 us）
- vLLM オーバーヘッドの分離: TTFT - KV-Cache 転送時間 - Prefill 時間

**メッセージサイズ**: 64B, 1KB, 64KB, 1MB, 10MB, 100MB

**推定時間**: 15 分

### 3.2 NIXLBench (Layer L1)

**目的**: KV-Cache 転送時間の直接測定（VRAM to VRAM）

**得られる情報**:
- EFA (Libfabric) vs TCP (UCX) の VRAM 間転送時間
- 並行度テスト（c=1, c=4, c=16）での incast 観測
- 4-tier staircase の再現

**メッセージサイズ**: 55 MB (1K tok), 224 MB (4K tok), 672 MB (12K tok)

**前提条件**: ETCD サーバー（Docker コンテナ）

**推定時間**: 60 分

### 3.3 KVBench (Layer L2)

**目的**: LLM 固有の KV-Cache 転送プロファイリング

**得られる情報**:
- Qwen2.5-7B の実際の KV-Cache 構造に基づく転送時間
- TCP slow start の影響の定量化
- MR キャッシュウォームアップ効果の分離

**プロンプト長**: 1K, 4K, 12K トークン

**前提条件**: ETCD サーバー、KVBench インストール済み

**推定時間**: 90 分

### 3.4 ucx_perftest (Layer L3)

**目的**: UCX トランスポートの実効帯域幅測定

**得られる情報**:
- UCX (SRD) の実効帯域幅
- EFA (libfabric) との性能差の直接比較

**テストタイプ**: tag_bw (帯域幅), tag_lat (レイテンシ)

**推定時間**: 30 分

## 4. Quick Start

### 4.1 タスク定義の生成

```bash
cd experiments
./generate_tasks.py phase-low-level
```

### 4.2 環境変数の設定

```bash
export SCRIPTS_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name NixlEfaStack \
  --query 'Stacks[0].Outputs[?OutputKey==`ScriptsBucketName`].OutputValue' \
  --output text)

export NODE1_ID=$(aws ec2 describe-instances \
  --filters "Name=tag: Name,Values=nixl-node1" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

export NODE2_ID=$(aws ec2 describe-instances \
  --filters "Name=tag: Name,Values=nixl-node2" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

export NODE1_PRIVATE=$(aws ec2 describe-instances \
  --filters "Name=tag: Name,Values=nixl-node1" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

export NODE2_PRIVATE=$(aws ec2 describe-instances \
  --filters "Name=tag: Name,Values=nixl-node2" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
```

### 4.3 スクリプトのデプロイ

```bash
./run_experiment.sh phase-low-level deploy
```

### 4.4 測定の実行

```bash
# 全レイヤーを順番に実行
python3 scripts/run_low_level_tools.py

# 特定のレイヤーのみ実行
python3 scripts/run_low_level_tools.py --layer L0  # fi_pingpong
python3 scripts/run_low_level_tools.py --layer L1  # NIXLBench
python3 scripts/run_low_level_tools.py --layer L2  # KVBench
python3 scripts/run_low_level_tools.py --layer L3  # ucx_perftest

# run_experiment.sh 経由で個別パターンを実行
./run_experiment.sh phase-low-level run pll-nixlbench-efa-672m
```

### 4.5 相関分析

```bash
# MLflow データから分析
python3 scripts/analyze_correlation.py --mlflow-uri http://localhost:5000

# ローカル JSON ファイルから分析
python3 scripts/analyze_correlation.py \
  --e2e-dir results/phase14 \
  --low-level-dir results/low-level

# 特定の分析のみ
python3 scripts/analyze_correlation.py --analysis tpot-independence
python3 scripts/analyze_correlation.py --analysis tcp-incast
python3 scripts/analyze_correlation.py --analysis token-gap
python3 scripts/analyze_correlation.py --analysis staircase
```

## 5. MLflow 統合

### 5.1 Experiment 構成

```
MLflow Experiments:
  nixl-efa-tai-phase-14       # E2E 測定（既存）
  nixl-efa-tai-phase-15       # E2E 測定（既存）
  low-level-network           # 低レベル測定（新規）
```

### 5.2 低レベル測定の記録形式

**fi_pingpong / fi_rma_pingpong**:
- tags: tool=fi_pingpong, layer=L0
- metrics: latency_us_{size}, bandwidth_mbps_{size}

**NIXLBench**:
- tags: tool=nixlbench, layer=L1, kv_cache_equivalent_tokens={N}
- params: backend, message_size, num_threads, scheme
- metrics: latency_p50_us, latency_p95_us, latency_p99_us, bandwidth_gbps, transfer_time_ms

**KVBench**:
- tags: tool=kvbench, layer=L2
- params: backend, model_config, prompt_tokens, kv_cache_size_bytes
- metrics: kv_transfer_time_ms, bandwidth_gbps

**ucx_perftest**:
- tags: tool=ucx_perftest, layer=L3
- params: test_type, message_size, memory_type, transport
- metrics: latency_us, bandwidth_gbps

### 5.3 相関クエリの例

```python
import mlflow

# TTFT から KV-Cache 転送時間を分離
e2e_run = mlflow.get_run("phase14-efa-c1-12k-XXXXXXXX")
nixl_run = mlflow.get_run("pll-nixlbench-efa-672m-XXXXXXXX")

ttft = e2e_run.data.metrics["ttft_mean"]           # 例: 2664 ms
kv_transfer = nixl_run.data.metrics["transfer_time_ms"]  # 例: 150 ms

# vLLM オーバーヘッドの推定
# prefill_time は別途測定（Unified モードの TTFT を参考）
prefill_time = 800  # ms (推定)
vllm_overhead = ttft - kv_transfer - prefill_time
print(f"vLLM Overhead: {vllm_overhead: .0f} ms")
```

## 6. 実行順序と依存関係

```
L0 (fi_pingpong)     ---- 依存関係なし、最初に実行
     |
L1 (NIXLBench)       ---- ETCD が必要（L1 内で自動起動）
     |
L2 (KVBench)         ---- ETCD が必要（L1 で起動済み）
     |
L3 (ucx_perftest)    ---- 依存関係なし（並列実行可能）
```

推奨実行順序:
1. L0: fi_pingpong (15 分) -- EFA 接続性の確認を兼ねる
2. L1: NIXLBench (60 分) -- ETCD 起動 + VRAM 転送測定
3. L2: KVBench (90 分) -- L1 の ETCD を再利用
4. L3: ucx_perftest (30 分) -- 独立して実行可能

**合計推定時間**: 約 3.5 時間（順次実行の場合）

## 7. KV-Cache サイズの参照値

Qwen2.5-7B-Instruct (GQA, layers=28, kv_heads=4, head_dim=128, bf16):

```
KV-Cache per token = 2 x 28 x 4 x 128 x 2 = 57,344 bytes
```

| トークン数 | KV-Cache サイズ | 理論 EFA (4.4 GB/s) | 理論 TCP (2.9 GB/s) | 差分 |
|-----------|----------------|--------------------|--------------------|------|
| 1,000 | 55 MB | 12 ms | 18 ms | 6 ms |
| 4,096 | 224 MB | 50 ms | 75 ms | 25 ms |
| 12,288 | 672 MB | 149 ms | 226 ms | 77 ms |
| 20,000 | 1,094 MB | 243 ms | 368 ms | 125 ms |

## 8. 期待される成果

### 8.1 測定妥当性スコアの改善

- 現在: 59/100（推論ベース）
- 目標: 75-80/100（実測ベース）

### 8.2 登壇での説得力向上

以下の形式で説明が可能になる:

- "NIXLBench で 12K token 相当の KV-Cache (672 MB) を直接測定した結果、
   EFA (Libfabric) では XX ms、TCP (UCX) では YY ms でした"
- "KVBench で TCP slow start の影響を分離すると、最初の転送で ZZ ms の
   追加レイテンシが発生し、これが理論値との乖離の主因です"
- "fi_pingpong で測定した純粋なネットワークレイテンシは XX us であり、
   TTFT の大部分は vLLM の Prefill + Proxy オーバーヘッドです"

### 8.3 generate_tasks.py との統合

`phase-low-level.json` は既存の `generate_tasks.py` で処理可能。
ただし、低レベルツールのテンプレートは E2E テンプレートとは異なるため、
テンプレート選択ロジックの拡張が必要:

```python
# generate_tasks.py に追加が必要なロジック
if pattern.get("tool") in ("fi_pingpong", "fi_rma_pingpong"):
    template = env.get_template("low-level-fi-pingpong.json.jinja2")
elif pattern.get("tool") == "nixlbench":
    template = env.get_template("low-level-nixlbench.json.jinja2")
elif pattern.get("tool") == "kvbench":
    template = env.get_template("low-level-kvbench.json.jinja2")
elif pattern.get("tool") == "ucx_perftest":
    template = env.get_template("low-level-ucx-perftest.json.jinja2")
```

## 9. 冪等性の確保

各タスク定義は以下のパターンで冪等性を確保:

- **ETCD**: `skip_if` で既存コンテナを検出
- **結果ファイル**: 毎回上書き（再実行で最新の結果を取得）
- **ツールバイナリ**: `skip_if` で存在チェック
- **GPU クリーンアップ**: 不要（低レベルツールは vLLM を使用しない）

## 10. トラブルシューティング

### ETCD が起動しない

```bash
# Docker が動作しているか確認
docker ps

# ETCD コンテナのログ確認
docker logs etcd-nixlbench

# 手動で ETCD を起動
docker run -d --name etcd-nixlbench --network host \
  quay.io/coreos/etcd: v3.5.18 /usr/local/bin/etcd \
  --listen-client-urls=http://0.0.0.0:2379 \
  --advertise-client-urls=http://0.0.0.0:2379
```

### NIXLBench がセグフォルト

```bash
# EFA デバイスの確認
fi_info -p efa -t FI_EP_RDM

# GDR (GPUDirect RDMA) の確認
nvidia-smi topo -m

# VRAM ではなく DRAM で再試行
./nixlbench --etcd_endpoints http://localhost:2379 \
  --backend Libfabric \
  --initiator_seg_type DRAM \
  --target_seg_type DRAM
```

### ucx_perftest の SRD が利用できない

```bash
# UCX トランスポート情報の確認
ucx_info -d | grep srd

# SRD なしで実行（tcp フォールバック）
UCX_TLS=tcp ucx_perftest -m cuda $NODE1_PRIVATE -t tag_bw -s 10000000
```

---

**作成日**: 2026-02-27
**対象**: Phase 3 低レベルツールの Phase 14/15 実験システムへの統合
