# Disaggregated KV Cache Inference with NIXL over AWS EFA

AWS EFA (Elastic Fabric Adapter) と NIXL を使用した分散 KV cache 推論の完全再現可能な実装です。

## バージョン情報

- **最新バージョン**: v0.3.0
- **検証済み環境**: Ubuntu 24.04 DLAMI on g7e.12xlarge (RTX PRO 6000 Blackwell 96GB x2)
- **リージョン**: ap-northeast-1 (Tokyo)

## プロジェクト概要

このプロジェクトは、大規模言語モデル (LLM) の推論を Prefill (KV cache 生成) と Decode (トークン生成) に分離し、それぞれ異なる GPU ノードで実行することで、リソース利用効率を最適化する「Disaggregated Inference」を実装します。

### アーキテクチャ

```
┌─────────────┐         ┌─────────────┐
│  Producer   │         │  Consumer   │
│   (Node1)   │         │   (Node2)   │
│             │         │             │
│ vLLM:8100   │◄────────┤ vLLM:8200   │
│  (Prefill)  │  NIXL   │  (Decode)   │
│             │  over   │             │
│             │   EFA   │             │
└─────────────┘         └──────┬──────┘
                               │
                               │ HTTP
                               │
                        ┌──────▼──────┐
                        │    Proxy    │
                        │  Server     │
                        │   :8000     │
                        └─────────────┘
                               │
                               ▼
                          Client Request
```

### 主な特徴

- **完全自動デプロイ**: CDK → deploy-v9.sh → run_inference_test.sh の 3 ステップ
- **Ubuntu 24.04 DLAMI 対応**: /opt/pytorch 環境を活用、PEP 668 完全対応
- **SSM 経由の自動化**: SSH キー不要、全操作を AWS Systems Manager 経由で実行
- **冪等性保証**: タスクステート管理により、途中から再実行可能
- **EFA による KV cache 転送**: Producer で生成した KV cache を Consumer が NIXL/EFA 経由で直接取得

## クイックスタート

### 前提条件

- AWS CLI v2
- Node.js 18+
- AWS CDK v2
- 適切な AWS 認証情報（EC2、S3、SSM、CloudFormation の権限）

### ステップ 1: CDK デプロイ

```bash
cd cdk

# 初回のみ: 依存関係インストールとビルド
npm install
npm run build

# スタックデプロイ
cdk deploy v9test-nixl-efa-dev-northeas-1 \
  -c availabilityZone=ap-northeast-1a \
  -c skipMlflow=true
```

デプロイ完了後、以下の情報を確認：

```bash
# 出力例
Outputs:
v9test-nixl-efa-dev-northeas-1.Node1InstanceId = i-03395a0827c156541
v9test-nixl-efa-dev-northeas-1.Node1PrivateIp = 172.31.33.7
v9test-nixl-efa-dev-northeas-1.Node2InstanceId = i-0e0d718b26626b48d
v9test-nixl-efa-dev-northeas-1.Node2PrivateIp = 172.31.34.243
v9test-nixl-efa-dev-northeas-1.ScriptsBucketName = v9test-nixl-efa-dev-northeas-scriptsbucket40feb4b1-cdi1udaxfajg
```

### ステップ 2: 設定ファイル作成

```bash
cd ../setup

# configs/v9test-ap-northeast-1.env を編集
# CDK の出力値を反映
cat > configs/v9test-ap-northeast-1.env << 'EOF'
# AWS Configuration
S3_BUCKET="v9test-nixl-efa-dev-northeas-scriptsbucket40feb4b1-cdi1udaxfajg"
AWS_REGION="ap-northeast-1"
DEPLOYMENT_ID="v9test-tokyo-ubuntu24"

# Node1 (Producer)
NODE1_INSTANCE_ID="i-03395a0827c156541"
NODE1_PRIVATE_IP="172.31.33.7"

# Node2 (Consumer)
NODE2_INSTANCE_ID="i-0e0d718b26626b48d"
NODE2_PRIVATE_IP="172.31.34.243"

# Remote user
REMOTE_USER="ubuntu"

# Service Configuration
ENGINE_ID="v9test-nixl-efa-$(date +%Y%m%d)"
PRODUCER_PORT="8100"
CONSUMER_PORT="8200"
PROXY_PORT="8000"

# NIXL Configuration
NIXL_PORT="14579"
ZMQ_PORT="50100"
NIXL_REPO="https://github.com/littlemex/nixl.git"
NIXL_BRANCH="main"
NIXL_CLONE_DIR="/tmp/nixl-build"
BUILD_SUBDIR="build"
PLUGIN_RELATIVE_PATH="src/plugins/libfabric/libplugin_LIBFABRIC.so"
S3_PLUGIN_KEY="plugins/libplugin_LIBFABRIC.so"
S3_PROXY_KEY="scripts/disagg_proxy_server.py"

# vLLM Configuration
MODEL_NAME="Qwen/Qwen2.5-32B-Instruct"
TENSOR_PARALLEL_SIZE="2"
PRODUCER_GPU_COUNT="1"
CONSUMER_GPU_COUNT="1"
GPU_MEMORY_UTILIZATION="0.9"
MAX_MODEL_LEN="32000"
MAX_NUM_BATCHED_TOKENS="8192"
KV_BUFFER_SIZE="5000000000"
KV_BUFFER_DEVICE="cpu"
EOF
```

### ステップ 3: 完全自動デプロイ

```bash
# 環境セットアップ + vLLM/NIXL インストール + プラグインデプロイ
./deploy-v9.sh configs/v9test-ap-northeast-1.env
```

**実行内容**:
1. NIXL LIBFABRIC プラグインのビルドと S3 アップロード
2. Producer/Consumer に vLLM v0.17.0 インストール
3. Producer/Consumer に NIXL v0.10.0 インストール
4. LIBFABRIC プラグインのデプロイ
5. kv-transfer-config と起動スクリプトの生成・配置
6. Proxy Server のデプロイ

所要時間: 約 5-7 分

### ステップ 4: 推論テスト実行

```bash
# Producer → Consumer → Proxy を順次起動し、推論リクエスト送信
./run_inference_test.sh configs/v9test-ap-northeast-1.env
```

**実行内容**:
1. 起動スクリプト再生成（最新テンプレート適用）
2. Producer 起動（ポート 8100）
3. Consumer 起動（ポート 8200）
4. Proxy Server 起動（ポート 8000）
5. ヘルスチェック
6. 推論リクエスト送信

所要時間: 約 3-5 分（モデルロード含む）

### 成功時の出力

```json
{
  "id": "cmpl-bc4c297360922d91",
  "object": "text_completion",
  "created": 1773040876,
  "model": "Qwen/Qwen2.5-32B-Instruct",
  "choices": [{
    "index": 0,
    "text": " If",
    "logprobs": null,
    "finish_reason": "length"
  }]
}
```

## ディレクトリ構成

```
disaggregated-inference-with-nixl-over-aws-efa/
├── README.md                      # このファイル
├── ARCHITECTURE.md                # アーキテクチャ詳細
├── cdk/                           # AWS CDK (IaC)
│   ├── bin/app.ts                 # CDK アプリ
│   ├── lib/
│   │   ├── nixl-efa-stack.ts      # NIXL + EFA スタック
│   │   └── mlflow-stack.ts        # MLflow スタック（オプション）
│   └── package.json
└── setup/                         # デプロイメント自動化
    ├── deploy-v9.sh               # 完全自動デプロイスクリプト
    ├── run_inference_test.sh      # 推論テストスクリプト
    ├── task_runner.sh             # 汎用タスクランナー
    ├── ssm_helper.sh              # SSM ヘルパー関数
    ├── configs/                   # 環境設定ファイル
    │   └── v9test-ap-northeast-1.env
    ├── scripts/                   # インストールスクリプト
    │   ├── install-vllm.sh        # vLLM インストール
    │   ├── install-nixl.sh        # NIXL インストール
    │   ├── deploy-plugin.sh       # プラグインデプロイ
    │   ├── verify-setup.sh        # セットアップ検証
    │   └── common.sh              # 共通関数
    ├── templates/                 # 起動スクリプトテンプレート
    │   ├── start_producer.sh.template
    │   ├── start_consumer.sh.template
    │   ├── start_proxy.sh.template
    │   ├── kv_config_producer.json.template
    │   └── kv_config_consumer.json.template
    ├── tasks/                     # タスク定義（JSON）
    │   ├── complete-deployment-v9.json
    │   └── regenerate-startup-scripts.json
    └── archive/                   # 古いスクリプト（参考用）
```

## トラブルシューティング

### デプロイが途中で失敗した場合

タスクステート管理により、途中から再実行可能です：

```bash
# タスクステートをクリアして最初から再実行
rm -f /tmp/task-state-*.json
./deploy-v9.sh configs/v9test-ap-northeast-1.env
```

### Producer/Consumer が起動しない

ログを確認：

```bash
# Producer ログ
aws ssm send-command \
  --instance-ids i-03395a0827c156541 \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["tail -100 /home/ubuntu/producer.log"]' \
  --region ap-northeast-1

# Consumer ログ
aws ssm send-command \
  --instance-ids i-0e0d718b26626b48d \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["tail -100 /home/ubuntu/consumer.log"]' \
  --region ap-northeast-1
```

### ポートが Listen していない

サービスが起動中の可能性があります。モデルロードに時間がかかります（Qwen2.5-32B で 2-3 分）：

```bash
# ポート確認
aws ssm send-command \
  --instance-ids i-03395a0827c156541 \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["ss -tlnp | grep -E \": (8100|8200)\""]' \
  --region ap-northeast-1
```

## クリーンアップ

```bash
# インスタンス上のプロセス停止
aws ssm send-command \
  --instance-ids i-03395a0827c156541 i-0e0d718b26626b48d \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["pkill -f vllm || true","pkill -f disagg_proxy || true"]' \
  --region ap-northeast-1

# CDK スタック削除
cd cdk
cdk destroy v9test-nixl-efa-dev-northeas-1
```

## 技術仕様

### ソフトウェアバージョン

- **OS**: Ubuntu 24.04 LTS (Deep Learning AMI GPU PyTorch)
- **Python**: 3.12 (/opt/pytorch 環境)
- **vLLM**: v0.17.0
- **NIXL**: v0.10.0
- **PyTorch**: 事前インストール（DLAMI）
- **CUDA**: 事前インストール（DLAMI）

### ハードウェア

- **Instance Type**: g7e.12xlarge
- **GPU**: NVIDIA RTX PRO 6000 Blackwell (96GB VRAM) x2
- **Network**: EFA (Elastic Fabric Adapter) 100 Gbps

### ネットワーク構成

- **NIXL Protocol**: Request/Response (libfabric_backend.cpp)
- **Transport**: EFA (fi_read one-sided RDMA)
- **Side Channel**: ZMQ (ポート 50100)
- **vLLM Ports**: Producer 8100, Consumer 8200
- **Proxy Port**: 8000

## 関連ドキュメント

- [ARCHITECTURE.md](ARCHITECTURE.md) - アーキテクチャ詳細説明
- [setup/README.md](setup/README.md) - デプロイメント詳細
- [setup/README_COMPLETE_DEPLOYMENT.md](setup/README_COMPLETE_DEPLOYMENT.md) - 完全デプロイメント手順

## 参考リンク

- [NIXL Repository](https://github.com/littlemex/nixl)
- [vLLM Documentation](https://docs.vllm.ai/)
- [AWS EFA Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)

## ライセンス

MIT License

## 著者

littlemex

## 変更履歴

### v0.3.0 (2026-03-09)

最終更新: 2026-03-09 22:00 UTC

- Ubuntu 24.04 DLAMI 完全対応
- /opt/pytorch 環境統合
- PEP 668 対応
- 完全再現可能なデプロイメント達成
- EFA 経由 KV cache 転送動作確認

### v0.2.0 (2026-03-07)

- Phase 2 vs Phase 3 詳細比較分析完了
- 自動ビルド・デプロイワークフロー追加

### v0.1.0 (2026-03-04)

- 初期リリース
- Phase 3 環境構築完了
