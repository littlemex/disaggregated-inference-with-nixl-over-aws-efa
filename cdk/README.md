# NIXL EFA CDK Stack

AWS CDK で EFA 対応 GPU インスタンスと SageMaker Managed MLflow を構築します。

## 概要

このスタックは以下を作成します：

- **EC2 インスタンス × 2**: EFA 対応 GPU（デフォルト: g5.12xlarge）
- **SageMaker Managed MLflow**: 実験トラッキングサーバー
- **Placement Group**: クラスター配置によるノード間低遅延通信
- **Security Group**: EFA 通信（allTraffic）+ vLLM HTTP（8100）
- **IAM Role**: SSM Session Manager + MLflow + CloudWatch Logs

## クイックスタート

```bash
# 依存関係のインストール
cd cdk
npm install

# デプロイ（2 スタック: MLflow + EC2）
npx cdk deploy --all \
  --context availabilityZone=us-east-1c \
  --context trackingServerName=nixl-efa-mlflow

# 完了後、Outputs で IP アドレスと MLflow ARN を確認
```

## インスタンスへのアクセス

```bash
# Node1 のインスタンス ID を取得
NODE1_ID=$(aws ec2 describe-instances \
  --region us-east-1 \
  --filters "Name=tag: Name,Values=nixl-node1" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

# SSM Session Manager で接続
aws ssm start-session --target $NODE1_ID --region us-east-1
```

## サポートされているインスタンスタイプ

### GPU インスタンス（EFA 対応）

| タイプ | GPU | 用途 |
|--------|-----|------|
| g5.12xlarge | NVIDIA A10G × 4 | 開発・テスト |
| g5.24xlarge | NVIDIA A10G × 4 | 中規模推論 |
| g5.48xlarge | NVIDIA A10G × 8 | 大規模推論 |
| g6.12xlarge | NVIDIA L4 × 4 | 開発・テスト |
| g6e.12xlarge | NVIDIA L40S × 4 | AI ワークステーション |
| g7e.8xlarge | NVIDIA RTX PRO 6000 × 1 | グラフィックス + AI |
| p4d.24xlarge | NVIDIA A100 × 8 | トレーニング |
| p5.48xlarge | NVIDIA H100 × 8 | 最高性能 |

### インスタンスタイプの変更

```bash
# コンテキストで指定
npx cdk deploy --all -c instanceType=g5.24xlarge

# bin/app.ts で指定
const nixlEfaStack = new NixlEfaStack(app, nixlEfaStackName, {
  instanceType: "g5.24xlarge",
  // ...
});
```

## クリーンアップ

```bash
npx cdk destroy --all
```

## トラブルシューティング

### InsufficientInstanceCapacity エラー

別の Availability Zone を試してください：

```bash
npx cdk deploy --all -c availabilityZone=us-east-1d
```

### SSM Session Manager に接続できない

Session Manager Plugin をインストールしてください：

```bash
# Ubuntu/Debian
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o "/tmp/session-manager-plugin.deb"
sudo dpkg -i /tmp/session-manager-plugin.deb
```

## 参考

- [AWS CDK](https://docs.aws.amazon.com/cdk/)
- [EFA Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
- [SSM Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
