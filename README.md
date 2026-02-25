# Disaggregated Inference with NIXL over AWS EFA

AWS EFA（Elastic Fabric Adapter）と NIXL（Network Interface for XPU Layers）を活用した分散推論の実装・検証プロジェクトです。

## プロジェクト概要

このリポジトリは、大規模言語モデル（LLM）の推論を効率化するための「分散推論（Disaggregated Inference）」アーキテクチャを AWS 環境で実装・検証するためのコードとドキュメントを提供します。

### 主な特徴

- **AWS CDK による IaC**: MLflow tracking server と GPU インスタンス（EFA 対応）を CDK でデプロイ
- **MLflow による実験管理**: すべての実験パラメータとメトリクスを SageMaker Managed MLflow で一元管理
- **EFA による高速通信**: AWS EFA を活用した低レイテンシ・高スループットのノード間通信
- **再現可能な実験環境**: すべての設定を IaC とスクリプトで管理し、実験の再現性を確保

## ディレクトリ構成

```
disaggregated-inference-with-nixl-over-aws-efa/
├── README.md                         # このファイル
├── blog/                             # ブログ記事（実装の解説）
│   ├── 01-environment-setup.md       # 第 1 回: 環境構築編
│   └── ssm-session-manager-guide.md  # SSM Session Manager ガイド
├── cdk/                              # AWS CDK による IaC
│   ├── bin/app.ts                    # CDK アプリケーションエントリーポイント
│   ├── lib/
│   │   ├── mlflow-stack.ts           # SageMaker Managed MLflow スタック
│   │   └── nixl-efa-stack.ts         # GPU インスタンス + EFA スタック
│   ├── package.json
│   ├── tsconfig.json
│   └── cdk.json
└── scripts/                          # 検証スクリプト（インスタンス上で実行）
    ├── mlflow_helper.py              # MLflow presigned URL 取得ヘルパー
    ├── test-mlflow.py                # MLflow 接続テスト
    ├── check-environment.sh          # 環境確認スクリプト
    ├── setup-nccl-tests.sh           # NCCL tests セットアップ
    └── nccl-benchmark.sh             # NCCL ベンチマーク実行
```

## 前提条件

### ローカル環境

- Node.js 18+
- AWS CLI v2
- AWS CDK v2
- Python 3.9+
- 適切な AWS 認証情報

### AWS リソース

- AWS アカウント
- 十分な EC2 容量制限（p4d.24xlarge または類似の GPU インスタンス）
- EFA が利用可能なアベイラビリティゾーン

## クイックスタート

### 1. SSM Session Manager Plugin のインストール

インスタンスへの接続に SSM Session Manager を使用します（SSH keypair 不要）。

```bash
# macOS (Homebrew)
brew install --cask session-manager-plugin

# Ubuntu/Debian
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o "session-manager-plugin.deb"
sudo dpkg -i session-manager-plugin.deb

# インストール確認
session-manager-plugin --version
```

詳細は [blog/ssm-session-manager-guide.md](blog/ssm-session-manager-guide.md) を参照してください。

### 2. CDK のセットアップとデプロイ

```bash
# CDK ディレクトリに移動
cd cdk

# 依存関係のインストール
npm install

# CDK のブートストラップ（初回のみ）
npx cdk bootstrap

# スタックのデプロイ
npx cdk deploy --all \
  --context availabilityZone=us-east-1a
```

デプロイには 10-15 分程度かかります。完了後、CloudFormation の Outputs から以下の情報を取得できます：

- `MlflowTrackingServerArn`: MLflow tracking server の ARN

### 3. 環境確認

デプロイしたインスタンスに SSM Session Manager で接続し、環境を確認します。

```bash
# Node 1 のインスタンス ID を取得
NODE1_ID=$(aws cloudformation describe-stack-resources \
  --stack-name NixlEfaStack \
  --logical-resource-id Node1 \
  --query 'StackResources[0].PhysicalResourceId' \
  --output text)

# SSM Session Manager で接続
aws ssm start-session --target $NODE1_ID

# 環境確認スクリプトを実行（インスタンス上で）
# リポジトリをクローンしてスクリプトを取得
git clone https://github.com/<your-username>/disaggregated-inference-with-nixl-over-aws-efa.git
cd disaggregated-inference-with-nixl-over-aws-efa/scripts
./check-environment.sh
```

### 4. MLflow 接続テスト

```bash
# ローカルまたはリモートで実行
# 環境変数 MLFLOW_TRACKING_ARN が設定されていることを確認
echo $MLFLOW_TRACKING_ARN

# MLflow 接続テスト
python3 scripts/test-mlflow.py
```

## 実験の実行

### Step 1: NCCL 通信ベンチマーク（オプション）

EFA の実効性能を測定するため、NCCL 通信ベンチマークを実行できます。

```bash
# インスタンス上で実行

# NCCL tests のインストール
sudo bash scripts/setup-nccl-tests.sh

# ベンチマーク実行（all_reduce と all_gather）
bash scripts/nccl-benchmark.sh

# GPU 数やデータサイズをカスタマイズ
NUM_GPUS=2 MAX_SIZE=64M bash scripts/nccl-benchmark.sh
```

測定される指標：
- **Bus Bandwidth**: 実効帯域幅（GB/s）
- **Latency**: 通信レイテンシ（μs）
- **Algorithm Bandwidth**: NCCL アルゴリズムの効率

結果は `/tmp/nccl-benchmark-results/` に保存されます。

### Step 2: vLLM による分散推論

（今後のブログ記事で解説予定）

- vLLM を使用した推論サーバーの起動
- NIXL を使用した KV-cache 転送
- ベンチマーク測定と MLflow への記録

## クリーンアップ

不要になったリソースを削除します。

```bash
cd cdk

# すべてのスタックを削除
npx cdk destroy --all
```

**重要**: SageMaker Managed MLflow は S3 バケットを作成します。完全に削除するには、S3 バケットを手動で削除する必要があります。

```bash
# MLflow のアーティファクト用 S3 バケットを確認
aws s3 ls | grep mlflow

# バケットを削除（バケット名は環境により異なります）
aws s3 rb s3://<mlflow-bucket-name> --force
```

## ブログ記事

実装の詳細と背景は、以下のブログ記事で解説しています：

1. [環境構築編](blog/01-environment-setup.md) - CDK による MLflow + GPU インスタンスのデプロイ
2. （今後追加予定）推論実験編 - vLLM と NIXL を使用した分散推論の実装

## 技術スタック

- **Infrastructure**: AWS CDK, CloudFormation
- **Compute**: EC2 (p4d.24xlarge with EFA)
- **Experiment Tracking**: SageMaker Managed MLflow Serverless
- **Networking**: AWS EFA (Elastic Fabric Adapter)
- **ML Framework**: vLLM, PyTorch
- **Communication Library**: NIXL (Network Interface for XPU Layers)

## 参考資料

- [AWS EFA Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
- [SageMaker Managed MLflow](https://docs.aws.amazon.com/sagemaker/latest/dg/mlflow.html)
- [vLLM Documentation](https://docs.vllm.ai/)
- [NIXL Repository](https://github.com/3outeille/nixl) （仮想リンク）

## ライセンス

MIT License（または適切なライセンスを指定）

## 著者

（著者情報）

## 謝辞

このプロジェクトは、AWS の EFA 技術と MLflow による実験管理のベストプラクティスを組み合わせた研究プロジェクトです。
