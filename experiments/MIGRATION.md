# SSH から SSM への移行ガイド

このドキュメントでは、実験実行システムを SSH/SCP ベースから SSM (Systems Manager) ベースに移行する手順を説明します。

## 変更概要

| 項目 | 移行前 (SSH) | 移行後 (SSM) |
|------|-------------|-------------|
| ファイル転送 | SCP (SSH key 必要) | S3 経由 (SSH key 不要) |
| コマンド実行 | SSH (SSH key 必要) | SSM send-command (SSH key 不要) |
| インタラクティブ接続 | SSH | SSM Session Manager |
| 必要なポート | 22 (Security Group) | なし (SSM Agent) |
| 認証 | SSH key pair | IAM ロール |

## 移行手順

### Step 1: CDK のデプロイ

S3 バケットへの書き込み権限が追加されています。CDK を再デプロイしてください。

```bash
cd cdk
npx cdk deploy
```

変更点:
- `grantRead(ec2Role)` -> `grantReadWrite(ec2Role)`: 実験結果の S3 アップロードに対応

### Step 2: 環境変数の変更

#### 移行前

```bash
export SSH_KEY=~/.ssh/checkpointless-key.pem
export NODE1_IP=3.80.45.55        # パブリック IP
export NODE2_IP=18.232.147.93     # パブリック IP
export NODE1_PRIVATE=172.31.27.16
export NODE2_PRIVATE=172.31.20.197
```

#### 移行後

```bash
# S3 バケット名（CDK Output から自動取得）
export SCRIPTS_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name NixlEfaStack \
  --query 'Stacks[0].Outputs[?OutputKey==`ScriptsBucketName`].OutputValue' \
  --output text)

# インスタンス ID（タグから自動取得）
export NODE1_ID=$(aws ec2 describe-instances \
  --filters "Name=tag: Name,Values=nixl-node1" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

export NODE2_ID=$(aws ec2 describe-instances \
  --filters "Name=tag: Name,Values=nixl-node2" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

# プライベート IP（タグから自動取得）
export NODE1_PRIVATE=$(aws ec2 describe-instances \
  --filters "Name=tag: Name,Values=nixl-node1" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)

export NODE2_PRIVATE=$(aws ec2 describe-instances \
  --filters "Name=tag: Name,Values=nixl-node2" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)
```

#### 変更点まとめ

| 変数 | 移行前 | 移行後 |
|------|-------|-------|
| SSH_KEY | `~/.ssh/checkpointless-key.pem` | (削除) |
| NODE1_IP | パブリック IP | (削除) |
| NODE2_IP | パブリック IP | (削除) |
| SCRIPTS_BUCKET | (なし) | S3 バケット名 |
| NODE1_ID | (なし) | インスタンス ID |
| NODE2_ID | (なし) | インスタンス ID |
| NODE1_PRIVATE | プライベート IP | プライベート IP (変更なし) |
| NODE2_PRIVATE | プライベート IP | プライベート IP (変更なし) |

### Step 3: 実験の実行

コマンド体系は変更ありません。

```bash
# タスク定義の生成（変更なし）
./generate_tasks.py phase14

# デプロイ（S3 経由に変更）
./run_experiment.sh phase14 deploy

# 実行（SSM 経由に変更）
./run_experiment.sh phase14 run L0

# ステータス確認（変更なし）
./run_experiment.sh phase14 status
```

## 既存スクリプトとの違い

### ファイル転送

```bash
# 移行前: SCP
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    benchmark_common.py "ubuntu@$NODE1_IP:/tmp/"

# 移行後: S3 + SSM
# 1. S3 にアップロード（deploy 時）
aws s3 sync scripts/ "s3://$SCRIPTS_BUCKET/scripts/"

# 2. SSM でインスタンスに S3 からダウンロードさせる（run 時）
aws ssm send-command --instance-ids "$NODE1_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands": ["aws s3 cp s3://BUCKET/scripts/benchmark_common.py /tmp/"]}'
```

### コマンド実行

```bash
# 移行前: SSH
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "ubuntu@$NODE1_IP" \
    "bash /tmp/task_runner.sh /tmp/task.json --reset"

# 移行後: SSM send-command
aws ssm send-command --instance-ids "$NODE1_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands": ["bash /tmp/task_runner.sh /tmp/task.json --reset"]}'
```

### インタラクティブ接続

```bash
# 移行前: SSH
ssh -i "$SSH_KEY" "ubuntu@$NODE1_IP"

# 移行後: SSM Session Manager
aws ssm start-session --target "$NODE1_ID"
```

## 新しいファイル構成

```
experiments/
  lib/
    ssm-deploy.sh    # S3 ファイル転送ヘルパー（新規）
    ssm-run.sh       # SSM コマンド実行ヘルパー（新規）
  run_experiment.sh  # SSM ベースに書き換え（更新）
  README.md          # 環境変数セクション更新（更新）
  MIGRATION.md       # 本ファイル（新規）

cdk/lib/
  nixl-efa-stack.ts  # grantReadWrite に変更（更新）
```

## トラブルシューティング

### SSM Agent が応答しない

```bash
# インスタンスの SSM ステータスを確認
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$NODE1_ID" \
  --query 'InstanceInformationList[0].PingStatus'
```

期待値: `Online`

原因と対策:
- IAM ロールに `AmazonSSMManagedInstanceCore` が付与されていることを確認
- インスタンスがインターネットアクセス（NAT Gateway or VPC エンドポイント）を持つことを確認
- SSM Agent が起動していることを確認（UserData で自動起動済み）

### S3 アクセスが拒否される

```bash
# IAM ロールの S3 権限を確認
aws iam list-attached-role-policies --role-name <role-name>

# S3 バケットポリシーを確認
aws s3api get-bucket-policy --bucket "$SCRIPTS_BUCKET"
```

対策:
- CDK を再デプロイして `grantReadWrite` が反映されていることを確認
- `npx cdk deploy` を実行

### コマンドがタイムアウトする

SSM send-command のデフォルトタイムアウトは 3600 秒（1 時間）に設定しています。
大規模なモデルの初期化には時間がかかる場合があります。

```bash
# コマンドのステータスを確認
aws ssm list-commands \
  --instance-id "$NODE1_ID" \
  --max-results 5 \
  --query 'Commands[*].[CommandId,Status,StatusDetails]'

# 特定のコマンドの出力を確認
aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$NODE1_ID"
```

### SCRIPTS_BUCKET が取得できない

```bash
# CDK スタックの Output を直接確認
aws cloudformation describe-stacks \
  --stack-name NixlEfaStack \
  --query 'Stacks[0].Outputs'
```

スタック名が異なる場合は、正しいスタック名を指定してください。
