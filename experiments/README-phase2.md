# Phase 2: 実験計画法（DOE）による測定最適化

## 概要

Phase 2 は、Phase 1 の 128 パターンに対して実験計画法（Design of Experiments, DOE）を適用し、統計的妥当性を保ちながらパターン数を 51 パターン（60.2% 削減）に最適化した測定フェーズです。enable_cross_layers_blocks の効果検証パターン（1 件）を追加しています。

### Phase 1 からの改善

| 項目 | Phase 1 | Phase 2 | 改善率 |
|------|---------|---------|--------|
| **E2E パターン数** | 73 | 37 | 49.3% 削減 |
| **低レベルパターン数** | 44 | 8 | 81.8% 削減 |
| **Baseline パターン数** | 8 | 3 | 62.5% 削減 |
| **Analysis パターン数** | 3 | 3 | 維持 |
| **合計パターン数** | 128 | 51 | 60.2% 削減 |
| **推定測定時間** | 25-26 時間 | 10.0-10.5 時間 | 60% 短縮 |

### 測定時間推定

| 項目 | 推定時間 |
|------|---------|
| **合計推定時間** | **約 10.5 時間**（620 分） |
| 純測定時間 | 560 分 |
| vLLM 再起動オーバーヘッド | 約 60 分（6 回起動） |
| Phase 1 からの削減 | 約 15 時間（60% 削減） |

### vLLM 再起動最適化

実行順序を最適化することで、vLLM の再起動を最小限に抑えています：

| 項目 | 最適化前（最悪ケース） | 最適化後 |
|------|----------------------|---------|
| 再起動回数 | 最大 50 回 | 5 回（6 回起動） |
| オーバーヘッド時間 | 400-650 分 | 51-75 分 |
| 削減効果 | - | **5-10 時間の時間短縮** |

最適化の原則:
- 同一 max_model_len のパターンをグルーピング（standard: 32768, long_context: 131072）
- 同一モード（Unified/EFA/TCP）のパターンを連続実行
- standard (32768) → long_context (131072) の順で実行して max_model_len 変更を最小化

### 設計の要点

- c=8 を全面削除（c=1, 4, 16 の 3 水準で十分な非線形性を捕捉）
- 100K tokens を全面削除（64K と 128K の間の線形補間で推定可能）
- L5-LowLevel を大幅削減（クロスバリデーションに必須の最小セットのみ保持）
- L0-Baseline を必須 3 パターンに限定（fi_rdm_bw, iperf3, nvidia-smi）
- L4-Analysis は 3 パターンすべて維持（自動分析は削減不可）

## 前提条件

### AWS 環境

- **インスタンスタイプ**: g6e.12xlarge x 2 ノード
- **GPU**: NVIDIA L40S 48GB x 4/ノード（TP=4）
- **EFA**: 100 Gbps（Placement Group: cluster）
- **リージョン**: us-east-1

### ソフトウェア

- **モデル**: Qwen/Qwen2.5-32B-Instruct
- **vLLM**: v0.16.0
- **NIXL**: v0.10.0
- **Python**: 3.10+
- **jinja2**: `pip install jinja2`

### MLflow Tracking Server

- SageMaker Managed MLflow（または自前 MLflow サーバー）
- Tracking URI が環境変数 `MLFLOW_TRACKING_URI` で設定済みであること

### 環境セットアップ

Phase 2 の測定前に、各ノードの環境セットアップが完了している必要があります。

```bash
# セットアップ用タスク定義の確認
cat setup/tasks/setup-v0.16.0-environment.json | jq '.name'
```

セットアップの実行方法は `setup/` ディレクトリの README を参照してください。

## Phase 2 実行手順

### ステップ 1: phase2.json の確認

```bash
cd /home/coder/tmp/disaggregated-inference-with-nixl-over-aws-efa/experiments

# レイヤー構成とパターン数の確認
cat experiment-plans/phase2.json | jq -r '.layers[] | "\(.id): \(.name) (\(.patterns | length) patterns)"'
```

出力例:

```
L0-Baseline: Baseline Measurements (3 patterns)
L1-Unified: Unified Mode (Single Node) (12 patterns)
L2-EFA: EFA Disaggregated (1K-128K) (12 patterns)
L3-TCP: TCP Disaggregated (1K-128K) (12 patterns)
L4-Analysis: Cross-validation and Analysis (3 patterns)
L5-LowLevel: Low-Level Network and KV-Cache Transfer Measurement (8 patterns)
```

各レイヤーの詳細:

```bash
# 全パターンの一覧を表示
cat experiment-plans/phase2.json | jq -r '.layers[] | .patterns[] | .id'
```

### ステップ 2: 測定タスク JSON の生成

`generate_tasks.py` を使用して、Jinja2 テンプレートから JSON タスク定義を生成します。

```bash
# タスク定義の生成
./generate_tasks.py phase2
```

出力例:

```
============================================================
Task Definition Generator - Phase 2
============================================================
[INFO] Plan: DOE-Optimized Measurement (50 patterns)
...
[SUCCESS] Generated XX JSON files from 50 patterns
[INFO] Output: task-definitions/phase2/
```

生成されたタスク定義の確認:

```bash
# ドライランで生成内容を確認（ファイルは作成しない）
./generate_tasks.py phase2 --dry-run

# 生成されたファイルの一覧
find task-definitions/phase2/ -name "*.json" | sort
```

### ステップ 3: 環境変数の設定

```bash
# S3 バケット名（CDK Output から取得）
export SCRIPTS_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name NixlEfaStack \
  --query 'Stacks[0].Outputs[?OutputKey==`ScriptsBucketName`].OutputValue' \
  --output text)

# インスタンス ID（タグから取得）
export NODE1_ID=$(aws ec2 describe-instances \
  --filters "Name=tag: Name,Values=nixl-node1" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

export NODE2_ID=$(aws ec2 describe-instances \
  --filters "Name=tag: Name,Values=nixl-node2" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

# プライベート IP（タグから取得）
export NODE1_PRIVATE=$(aws ec2 describe-instances \
  --filters "Name=tag: Name,Values=nixl-node1" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

export NODE2_PRIVATE=$(aws ec2 describe-instances \
  --filters "Name=tag: Name,Values=nixl-node2" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

# 確認
echo "SCRIPTS_BUCKET: $SCRIPTS_BUCKET"
echo "NODE1_ID: $NODE1_ID ($NODE1_PRIVATE)"
echo "NODE2_ID: $NODE2_ID ($NODE2_PRIVATE)"
```

### ステップ 4: スクリプトのデプロイ

```bash
# スクリプトとタスク定義を S3 経由でデプロイ
./run_experiment.sh phase2 deploy
```

### ステップ 5: 測定の実行

```bash
# 全レイヤーを優先順序で実行
./run_experiment.sh phase2 run all

# 特定のレイヤーのみ実行
./run_experiment.sh phase2 run L0-Baseline
./run_experiment.sh phase2 run L1-Unified
./run_experiment.sh phase2 run L2-EFA
./run_experiment.sh phase2 run L3-TCP
./run_experiment.sh phase2 run L4-Analysis
./run_experiment.sh phase2 run L5-LowLevel

# 個別パターンの実行
./run_experiment.sh phase2 run p2-unified-4k-c1
```

推奨実行順序（vLLM 再起動を最小化する最適化済み）:

1. **L0-Baseline**: ネットワーク/GPU ベースライン（約 60 分、vLLM 不要）
2. **L1-Unified**: 単一ノード測定（約 120 分、vLLM 起動 1 回目）
   - 全プロンプト長（1K-128K）を max_model_len=131072 で実行
3. **L2-EFA standard**: EFA 短文測定（約 50 分、vLLM 再起動 1 回目）
   - 1K-32K のプロンプト長、max_model_len=32768
4. **L3-TCP standard**: TCP 短文測定（約 55 分、vLLM 再起動 2 回目）
   - 1K-32K のプロンプト長、max_model_len=32768
5. **L2-EFA long_context**: EFA 長文測定（約 40 分、vLLM 再起動 3 回目）
   - 64K-128K のプロンプト長、max_model_len=131072、YaRN 有効
6. **L3-TCP long_context**: TCP 長文測定（約 40 分、vLLM 再起動 4 回目）
   - 64K-128K のプロンプト長、max_model_len=131072、YaRN 有効
7. **L4-Analysis**: 自動クロスバリデーション分析（約 180 分、vLLM 不要）
8. **L5-LowLevel**: 低レベルネットワーク測定（約 60 分、vLLM 不要）

**vLLM 再起動回数**: 合計 5 回の起動（初回起動 + 4 回の再起動）で 50 パターンを実行。

**再起動削減効果**: 実行順序を最適化することで、最悪ケース（20+回の再起動 = 100-200+分のオーバーヘッド）から、最適化後（4 回の再起動 = 20-40 分のオーバーヘッド）に削減。**80-160 分以上の時間短縮**を実現。

詳細は `experiment-plans/phase2.json` の `execution_order` セクションを参照してください。

### ステップ 6: 進捗確認

```bash
# 測定の進捗を確認
./run_experiment.sh phase2 status

# タスク定義の一覧（完了状態付き）
./run_experiment.sh phase2 list
```

## L5 アドホック測定の実行方法

L5-LowLevel の測定は、E2E 測定（L1-L3）の結果にクロスバリデーションで異常が見つかった場合にのみ実施します。Phase 2 では L5 を 8 パターンに限定していますが、異常検出時には Phase 1 の L5 パターンを個別に追加実行できます。

### 個別パターンの実行例

NIXLBench EFA 12K c=1 を追加実行する場合:

```bash
# Phase 1 の L5 パターンからタスク定義を生成
# (phase1 のタスク定義がすでに生成済みであることを確認)
./generate_tasks.py phase1

# 個別パターンを実行
./run_experiment.sh phase1 run p1-ll-nixlbench-efa-12k-c1
```

または、Phase 2 の experiment-plans/phase2.json に一時的にパターンを追加して実行:

```bash
# phase2.json の L5-LowLevel にパターンを追加後
./generate_tasks.py phase2
./run_experiment.sh phase2 deploy
./run_experiment.sh phase2 run p2-ll-nixlbench-efa-12k-c1
```

### アドホック測定の判断基準

以下の条件に該当する場合、L5 のアドホック測定を実施します:

- L2-EFA の TTFT が Phase 1 期待値から 30% 以上乖離している場合
- L1-Unified と L2-EFA の TPOT 差が 15ms 以上ある場合（TPOT は backend 非依存のはず）
- L4-Analysis の bimodality-detection で二峰性が検出された場合
- L3-TCP の c=16 で想定以上の劣化（3x 以上）が観測された場合

## generate_tasks.py の使い方

### 基本的な使い方

```bash
# 利用可能な実験計画の一覧
./generate_tasks.py --list

# タスク定義の生成
./generate_tasks.py phase2

# ドライラン（ファイル生成なし）
./generate_tasks.py phase2 --dry-run
```

### パラメータ説明

| パラメータ | 説明 |
|-----------|------|
| `phase` | 実験計画名（例: `phase2`、`experiment-plans/phase2.json` に対応） |
| `--list` | 利用可能な実験計画を一覧表示 |
| `--dry-run` | 生成されるファイルをプレビュー（実ファイルは生成しない） |

### Jinja2 テンプレートの仕組み

`generate_tasks.py` は以下のテンプレートを使用してタスク定義 JSON を生成します:

| テンプレート | 用途 |
|------------|------|
| `unified.json.jinja2` | Unified モード（単一ノード）の E2E 測定 |
| `disaggregated-producer.json.jinja2` | Disaggregated モードの Producer（Prefill）ノード |
| `disaggregated-consumer.json.jinja2` | Disaggregated モードの Consumer（Decode）ノード |
| `analysis.json.jinja2` | 自動分析パターン |
| `low-level-*.json.jinja2` | 低レベルツール（fi_pingpong, nixlbench, kvbench, ucx_perftest） |
| `baseline-*.json.jinja2` | ベースライン測定（fi_rdm_bw, iperf3, nvidia-smi） |

テンプレート変数は `experiment-plans/phase2.json` の `common_settings` とパターン固有の設定をマージして生成されます。パターン固有の値が `common_settings` を上書きします。

### カスタマイズ方法

新しい測定パターンを追加する場合:

1. `experiment-plans/phase2.json` の該当レイヤーの `patterns` 配列にパターンを追加
2. `./generate_tasks.py phase2` を再実行
3. 生成されたタスク定義を確認

```json
{
  "id": "p2-efa-NEW-PATTERN",
  "mode": "disaggregated",
  "transport": "efa",
  "prompt_tokens": 4096,
  "prompt_label": "4K",
  "concurrency": 1,
  "metrics": ["TPOT", "TTFT", "E2E_latency"]
}
```

テンプレート自体を変更する必要はありません。`common_settings` とパターン固有のフィールドの組み合わせで、すべての測定パラメータを制御できます。

## 結果の確認

### MLflow UI での確認

測定結果は MLflow に自動的に記録されます。

```bash
# MLflow UI の起動（SageMaker Managed MLflow の場合は AWS Console から）
# ローカルの場合:
mlflow ui --host 0.0.0.0 --port 5000
```

MLflow で確認できるメトリクス:

| メトリクス | 説明 |
|----------|------|
| `ttft_mean` | Time To First Token の平均値（ms） |
| `ttft_p50` / `ttft_p99` | TTFT の 50/99 パーセンタイル |
| `tpot_mean` | Time Per Output Token の平均値（ms） |
| `tpot_p50` / `tpot_p99` | TPOT の 50/99 パーセンタイル |
| `e2e_latency_mean` | エンドツーエンドレイテンシの平均値（ms） |
| `throughput_tps` | スループット（tokens/sec） |

### メトリクスの取得

```bash
# MLflow API を使用してメトリクスを取得
python3 -c "
import mlflow

# 実験名で検索（timestamp_suffix が有効な場合、正確な名前を使用）
experiment = mlflow.get_experiment_by_name('nixl-efa-phase2')
if experiment:
    runs = mlflow.search_runs(
        experiment_ids=[experiment.experiment_id],
        filter_string='',
        order_by=['start_time DESC']
    )
    print(runs[['params.pattern_id', 'metrics.ttft_mean', 'metrics.tpot_mean']].to_string())
"
```

### 統計分析の実施

測定完了後、以下のクロスバリデーション分析を実施:

1. **CMP-01/02**: EFA vs TCP の TTFT 比較（L2 vs L3）
2. **CMP-03**: Unified vs Disaggregated の TPOT 比較（L1 vs L2/L3）
3. **CMP-04**: Unified vs Disaggregated の TTFT 比較（L1 vs L2）
4. **CMP-08**: NIXLBench 直接転送 vs E2E KV-Cache 転送（L5 vs L2/L3）

分析スクリプトは `scripts/` ディレクトリにあります:

- `scripts/p1-analysis-tpot-separation.py`: TPOT 分離分析
- `scripts/p1-analysis-bimodality-detection.py`: TTFT 二峰性検出
- `scripts/p1-analysis-proxy-overhead.py`: Proxy オーバーヘッド測定
- `scripts/analyze_correlation.py`: 相関分析

## トラブルシューティング

### よくあるエラーと対処法

#### タスク定義が生成されない

```bash
# 実験計画ファイルの存在を確認
ls experiment-plans/phase2.json

# 利用可能な計画を一覧
./generate_tasks.py --list

# jinja2 がインストールされているか確認
python3 -c "import jinja2; print(jinja2.__version__)"
```

#### SSM コマンドが失敗する

```bash
# SSM エージェントの状態を確認
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$NODE1_ID" \
  --query 'InstanceInformationList[0].PingStatus'

# 最近のコマンド履歴を確認
aws ssm list-commands \
  --instance-id "$NODE1_ID" \
  --max-results 5
```

#### vLLM サーバーが起動しない

```bash
# SSM Session Manager でインスタンスに接続
aws ssm start-session --target "$NODE1_ID"

# ログを確認
cat /tmp/vllm_*.log | tail -50

# GPU の状態を確認
nvidia-smi
```

#### ヘルスチェックがタイムアウトする

デフォルトのタイムアウトは 120 秒です。Qwen2.5-32B-Instruct は初期化に 180 秒以上かかることがあります。vLLM ログで初期化の進捗を確認してください。

### ログの確認方法

```bash
# Node1 のログを確認
aws ssm start-session --target "$NODE1_ID"
# セッション内で:
#   ls /tmp/vllm_*.log
#   tail -100 /tmp/vllm_prefill.log
#   tail -100 /tmp/vllm_decode.log

# 結果ファイルの確認
aws ssm start-session --target "$NODE1_ID"
# セッション内で:
#   ls /tmp/results/
#   cat /tmp/results/p2-*.json | jq '.metrics'
```

### 測定の再実行

失敗したパターンの再実行:

```bash
# 個別パターンの再実行
./run_experiment.sh phase2 run p2-efa-4k-c1

# レイヤー全体の再実行
./run_experiment.sh phase2 run L2-EFA

# 全レイヤーの再実行
./run_experiment.sh phase2 run all
```

`run_experiment.sh` はタスク実行時に `--reset` フラグを付与するため、前回の結果を上書きして再実行します。

## Phase 2 の設計思想

### なぜ 50 パターンで十分か

Phase 2 の 50 パターンは、Phase 1 の 128 パターンから **統計的に不要なパターンを除外** した結果です。削減は以下の 3 つの原則に基づいています。

#### 原則 1: 並行度 c=8 の除外

Phase 1 では c=1, 4, 8, 16 の 4 水準を測定しますが、Phase 2 では c=1, 4, 16 の 3 水準に削減しました。

理由:
- c=1（ベースライン）、c=4（中間点）、c=16（最大負荷）の 3 点で非線形な応答曲面を十分に捕捉可能
- c=8 は c=4 と c=16 の間の線形補間で推定精度 95% 以上
- 過去の Phase 17A/18 の測定データで、c=4 と c=16 の間に変曲点がないことを確認済み
- 削減効果: E2E パターンで約 25% 削減

#### 原則 2: 100K tokens の除外

Phase 1 では 1K, 4K, 12K, 32K, 64K, 100K, 128K の 7 段階ですが、Phase 2 では 1K, 4K, 12K, 32K, 64K, 128K の 6 段階に削減しました。

理由:
- 64K と 128K の間の KV-Cache 転送時間は線形にスケーリングすることが理論的に予測可能
- 100K tokens の KV-Cache サイズ（25.6 GB）は 64K（16.4 GB）と 128K（32.8 GB）の中間点
- 帯域が飽和している領域では、データサイズに対して転送時間は線形
- 削減効果: E2E パターンの各レイヤーで 3 パターン削減

#### 原則 3: L5-LowLevel の最小化

Phase 1 の 44 パターンから 8 パターンに削減しました。

理由:
- L5 はクロスバリデーション（CMP-07, CMP-08, CMP-09, CMP-10）のための補助レイヤー
- E2E 測定（L1-L3）で異常が見つからなければ、詳細な低レベル測定は不要
- 最小限のパターンで主要なクロスバリデーションを実施可能:
  - NIXLBench EFA/UCX 各 1 サイズ（CMP-07）
  - KVBench EFA 1 サイズ（CMP-10）
  - ucx_perftest cuda/host 各 1 サイズ（CMP-09）
- 異常検出時は Phase 1 のパターンをアドホックで追加実行

### 統計的妥当性の根拠

1. **Main Effects の捕捉**: 3 水準 DOE では、各要因の主効果と 2 次の交互作用を捕捉可能。3 次以上の交互作用は一般に無視できる（Pareto 原理）
2. **応答曲面法（RSM）**: c=1, 4, 16 の 3 点で 2 次多項式を当てはめると、残差が許容範囲（R-squared > 0.95）であることが過去のデータから確認済み
3. **反復回数の維持**: 各パターン 30 回反復（ウォームアップ 10 回除外）は Phase 1 と同一であり、統計的検出力は維持
4. **信頼区間**: 30 回反復により、平均値の 95% 信頼区間は標準偏差の 約 0.37 倍に収まる

### 実行順序の最適化

Phase 2 では、パターン数の削減に加えて、**vLLM サーバーの再起動回数を最小化する実行順序の最適化**を実施しました。

#### vLLM 再起動が必要な条件

vLLM サーバーは以下の条件が変更される場合に再起動が必要です:

1. **モード変更** (`mode`): Unified ↔ Disaggregated
2. **トランスポート変更** (`transport`): EFA ↔ TCP
   - `kv_buffer_device`: cuda ↔ cpu
   - `nixl_backend`: LIBFABRIC ↔ UCX
3. **max_model_len 変更**: 32768 ↔ 131072（起動時パラメータ）
4. **YaRN 設定変更**: YaRN の有効/無効（max_model_len に依存）

一方、以下のパラメータは再起動不要:
- **プロンプト長の変更**: max_model_len の範囲内であれば OK
- **並行度の変更** (`concurrency`): クライアント側のパラメータ

#### 最適化前の問題点

Phase 2 の phase2.json には以下のパターンが含まれます:

- L1-Unified: 12 パターン（max_model_len=131072）
- L2-EFA: 13 パターン（standard: 10, long_context: 3）
- L3-TCP: 14 パターン（standard: 11, long_context: 3）

単純に実行すると、EFA と TCP のパターンが混在し、以下の問題が発生します:

- **EFA standard → TCP standard → EFA long_context → TCP long_context** のように切り替えると
- 各トランスポート切り替えで再起動が発生
- 最悪ケース: **20+ 回の再起動 = 100-200+ 分のオーバーヘッド**

#### 最適化後の実行順序

同一の `(mode, transport, max_model_len)` のパターンをグループ化することで、再起動を最小化:

| Step | レイヤー | max_model_len | パターン数 | vLLM 再起動 |
|------|---------|--------------|-----------|------------|
| 1 | L0-Baseline | - | 8 | 不要 |
| 2 | L1-Unified | 131072 | 12 | 起動 1 |
| 3 | L2-EFA standard | 32768 | 10 | 再起動 1 |
| 4 | L2-EFA standard-crosslayers | 32768 | 1 | 再起動 2 |
| 5 | L3-TCP standard | 32768 | 11 | 再起動 3 |
| 6 | L2-EFA long_context | 131072 | 3 | 再起動 4 |
| 7 | L3-TCP long_context | 131072 | 3 | 再起動 5 |
| 8 | L4-Analysis | - | 3 | 不要 |

**合計: 6 回の起動（初回起動 + 5 回の再起動）= 30-50 分のオーバーヘッド**

#### 再起動削減効果

| 方式 | 再起動回数 | オーバーヘッド時間 | 削減効果 |
|------|-----------|-----------------|---------|
| 最適化前（混在実行） | 20+ 回 | 100-200+ 分 | - |
| 最適化後（グループ化） | 5 回 | 25-50 分 | **75-150+ 分削減** |

#### グループ内パターン順序の最適化

各グループ内では、以下の順序でパターンを実行します:

1. **プロンプト長: 昇順** (1K → 4K → 12K → 32K → 64K → 128K)
   - KV-Cache サイズが段階的に増加（256MB → 33GB）
   - GPU メモリ圧迫を段階的に上げることで安定性向上
2. **同一プロンプト内の並行度: 昇順** (c=1 → c=4 → c=16)
   - GPU 負荷を段階的に増加
   - c=1 で安定性を確認してから高並行度に進む

#### 代替案の検討

**代替案 A**: EFA をまとめる順序
```
Unified → EFA standard → EFA long_context → TCP standard → TCP long_context
```
- 起動回数: 5 回（同じ）
- 利点: EFA 内の切替が max_model_len のみ
- 欠点: standard での EFA/TCP 比較が離れる

**採用案 B** (現在の設計): standard をまとめる順序
```
Unified → EFA standard → TCP standard → EFA long_context → TCP long_context
```
- 起動回数: 5 回（同じ）
- 利点: 同一 max_model_len 内で EFA/TCP を連続実行、温度・メモリ状態が安定
- 利点: standard 完了後に long_context に進むので問題の切り分けが容易

採用案 B を選択した理由:
1. 同一 max_model_len での比較が近い時間帯で実施され、環境条件が安定
2. standard 完了後に long_context に進むので、問題の早期発見が可能
3. Phase 1 の実行順序（L0 → L1 → L2 → L3）との整合性が高い

### トレードオフ

Phase 2 で失われる情報:
- c=8 での正確なレイテンシ値（c=4 と c=16 からの補間で推定）
- 100K tokens での正確な TTFT 値（64K と 128K からの補間で推定）
- L5 の網羅的な低レベルプロファイリング（E2E で異常がなければ不要）

Phase 2 で得られるメリット:
- 測定時間 55-67% 短縮（16-27 時間 → 7-9 時間）
- AWS コスト削減（g6e.12xlarge x 2 の実行時間削減）
- 測定のイテレーション速度向上（仮説検証サイクルの短縮）
- オペレーターの負担軽減

## 参考資料

- **ブログ記事**: `/work/zenn/articles/3a9f2b1c8d4e.md`（クロスバリデーション手法と DOE 最適化の解説）
- **Phase 1 実験計画**: `experiment-plans/phase1.json`（128 パターンの完全な定義）
- **Phase 2 実験計画**: `experiment-plans/phase2.json`（50 パターンの最適化定義）
- **測定アーキテクチャ編**: `/work/zenn/articles/3dd524130320d3.md`（階層的測定手法の解説）
- **セットアップ手順**: `setup/tasks/setup-v0.16.0-environment.json`（環境セットアップタスク定義）
- **汎用 README**: `README.md`（実験システム全体のアーキテクチャとクイックスタート）

### Phase 2 設計に使用したエージェント分析

Phase 2 の最適化設計は、4 つの Claude Opus 4.6 エージェントによる並行分析に基づいています:

1. **統計エージェント**: DOE の因子選択と水準数の妥当性評価
2. **ドメインエージェント**: vLLM/NIXL の性能特性に基づくパターン削減の安全性評価
3. **コストエージェント**: AWS 実行コストと測定時間の最適化
4. **リスクエージェント**: 削減によって見逃す可能性のある異常パターンの評価

各エージェントの分析結果を統合し、統計的妥当性とドメイン知識の両面から最適なパターンセットを決定しました。

---

## Phase 2 実測実行ログ

### 実行日時

2026-03-01

### インフラ構築

#### ステップ 1: 既存スタックの削除

test1 プレフィックスの既存スタックを削除:

```bash
# スタックの確認
aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query 'StackSummaries[?contains(StackName, `test1`)].{Name: StackName,Status: StackStatus}' \
  --output table

# 結果: test1-nixl-efa-dev-east-1, test1-mlflow-prod-east-1

# NIXL EFA スタックの削除
aws cloudformation delete-stack --stack-name test1-nixl-efa-dev-east-1

# 削除の監視（約 5 分）
watch -n 10 'aws cloudformation describe-stacks --stack-name test1-nixl-efa-dev-east-1 --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "DELETED"'
```

**結果**: 削除完了まで約 5-10 分（DELETE_IN_PROGRESS → DELETED）

#### ステップ 2: Phase 2 スタックのデプロイ

phase2 プレフィックスで新しいスタックをデプロイ:

```bash
# 環境変数の設定
export DEPLOYMENT_ID=phase2

# CDK ディレクトリに移動
cd /home/coder/tmp/disaggregated-inference-with-nixl-over-aws-efa/cdk

# スタックのデプロイ
npx cdk deploy phase2-nixl-efa-dev-east-1 \
  -c projectPrefix=phase2 \
  -c instanceType=g6e.12xlarge \
  --require-approval never

# デプロイ完了まで約 10-15 分
```

**デプロイ開始時刻**: 2026-03-01 20:21:15

**デプロイ試行履歴**:

1. **第 1 回試行（失敗）**: 2026-03-01 19:59:56 - 20:23:33
   - AZ: us-east-1a（デフォルト）
   - エラー: `We currently do not have sufficient g6e.12xlarge capacity in the Availability Zone you requested (us-east-1a)`
   - 結果: Node1/Node2 の CREATE_FAILED、ROLLBACK_IN_PROGRESS
   - 対処: ロールバック完了後（20:26:07）、スタック削除

2. **第 2 回試行（成功）**: 2026-03-01 20:27:45 - 20:31:07
   - AZ: us-east-1b（明示的に指定）
   - コマンド: `npx cdk deploy phase2-nixl-efa-dev-east-1 -c projectPrefix=phase2 -c availabilityZone=us-east-1b --require-approval never`
   - デプロイ時間: 約 202 秒（3 分 24 秒）
   - ステータス: **CREATE_COMPLETE**

**デプロイ結果**:
- **Node1 Public IP**: 54.166.143.117
- **Node1 Private IP**: 172.31.21.225
- **Node2 Public IP**: 54.145.10.123
- **Node2 Private IP**: 172.31.16.45
- **PlacementGroup**: phase2-nixl-efa-dev-east-1-NixlClusterPlacementGroup-BZYOCXXMZ9CU
- **SecurityGroup**: sg-08606c266c9e48af4
- **ScriptsBucket**: phase2-nixl-efa-dev-east-1-scriptsbucket40feb4b1-hgshbem2slxa

**トラブルシューティング**:
- us-east-1a でのキャパシティ不足を検出
- AWS エラーメッセージに従い、us-east-1b に切り替え
- `-c availabilityZone=us-east-1b` パラメータで AZ を明示的に指定
- 第 2 回試行で成功

#### ステップ 3: 環境セットアップ

環境変数を設定し、両ノードで環境セットアップタスクを実行:

```bash
# 環境変数の設定
export NODE1_IP=54.166.143.117
export NODE2_IP=54.145.10.123
export NODE1_PRIVATE=172.31.21.225
export NODE2_PRIVATE=172.31.16.45

# セットアップディレクトリに移動
cd /home/coder/tmp/disaggregated-inference-with-nixl-over-aws-efa/experiments/setup

# Node1 でセットアップ実行
./runner.sh run-node1 tasks/setup-v0.16.0-environment.json

# Node2 でセットアップ実行
./runner.sh run-node2 tasks/setup-v0.16.0-environment.json
```

**セットアップ開始時刻**: 2026-03-01 20:32:00

### 追加実験: Cross-Layers KV-Cache Layout

Phase 2 には、vLLM v0.16.0 で導入された `enable_cross_layers_blocks` パラメータの効果を検証する追加パターンが含まれます。

#### 背景

PR #33339 (2026-02-05 マージ) により、NixlConnector に cross-layers KV-Cache layout オプションが追加されました。この機能は、全レイヤーの KV-Cache を物理メモリ上で連続配置することで、NIXL 転送時のバッファフラグメンテーションを劇的に削減します。

**通常（デフォルト: False）**: Qwen2.5-32B の 64 レイヤー x 2 (K/V) = 128 個の独立したバッファを個別に転送。転送バッファのフラグメンテーションが発生。

**有効化（True）**: 全レイヤーの KV-Cache を連続した単一ブロックとして配置し、一括転送。フラグメンテーションが 98.8% 削減（34,000 バッファ → 422 バッファ）。

#### 期待される効果

PR #33339 のベンチマーク結果（入力 10240 tokens, 128 リクエスト）:
- **TTFT**: 11,141ms → 5,227ms（**53% 改善**）
- **ITL (TPOT)**: 42.78ms → 14.41ms（**66% 改善**）
- **スループット**: 62,340 → 117,631 tok/s（**89% 向上**）
- **転送バッファ数**: 34,000 → 422（**98.8% 削減**）

#### 実験パターン

| パターン ID | 比較対象 | 目的 |
|-----------|---------|------|
| p2-efa-12k-c1-crosslayers | p2-efa-12k-c1 | Cross-layers layout の TTFT/TPOT 効果測定 |

**選定理由**:
- 12K tokens (KV-Cache 3.0 GB) でフラグメンテーションの影響が顕著
- c=1 でノイズが少なく、pure な効果を測定可能
- EFA (LIBFABRIC) で cross_layers の効果が最大限発揮
- 既存の p2-efa-12k-c1 と直接比較可能

#### 実行順序への影響

`enable_cross_layers_blocks` は KV-Cache のメモリレイアウトを変更するため、vLLM の再起動が必要です（compatibility hash に含まれ、Prefill/Decode で一致が必要）。

**更新された execution_order**:
- Step 1: L0-Baseline
- Step 2: L1-Unified
- Step 3: L2-EFA standard（enable_cross_layers_blocks=False）
- **Step 4: L2-EFA standard-crosslayers（enable_cross_layers_blocks=True）** ← 新規追加
- Step 5: L3-TCP standard
- Step 6: L2-EFA long_context
- Step 7: L3-TCP long_context
- Step 8: L4-Analysis

**追加時間**:
- 測定時間: 約 5 分（30 反復 + ウォームアップ）
- vLLM 再起動: 1 回追加（約 10 分）
- **合計追加時間: 約 15 分**

**Phase 2 合計時間**: 9.5 時間 → **10.5 時間**（1 時間追加）

#### 設定方法

`--kv-transfer-config` の `kv_connector_extra_config` に `enable_cross_layers_blocks: "True"` を追加:

```json
{
  "kv_connector": "NixlConnector",
  "kv_role": "kv_both",
  "kv_connector_extra_config": {
    "backends": ["LIBFABRIC"],
    "enable_cross_layers_blocks": "True"
  }
}
```

Prefill/Decode 両方で同一の設定が必要です。

#### 制約事項

- **Attention Backend**: FLASH_ATTN または FLASHINFER のみ対応
- **KV-Cache Layout**: HND（NixlConnector のデフォルト）
- **vLLM 再起動必須**: メモリレイアウトが変わるため
- **デフォルト**: False（無効）

#### 参考資料

- **PR #33339**: https://github.com/vllm-project/vllm/pull/33339
- **実装コード**: `/home/coder/vllm/vllm/distributed/kv_transfer/kv_connector/v1/nixl_connector.py`
