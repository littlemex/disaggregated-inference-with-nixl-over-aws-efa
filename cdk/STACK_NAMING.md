# スタック名とリソース名の管理

## 概要

CDK デプロイ時にスタック名やリソース名が既存のものと衝突するのを避けるため、`projectPrefix` コンテキストパラメータを使用してプレフィックスを指定できます。

## 基本的な使い方

### プレフィックスなし（デフォルト）

```bash
npx cdk deploy --all \
  --context instanceType=g7e.12xlarge \
  --context availabilityZone=us-east-1a
```

**生成されるスタック名: **
- MLflow: `mlflow-prod-east-1`
- NIXL EFA: `nixl-efa-dev-east-1`

**リソース名: **
- Tracking Server: `mlflow-tracking-server`
- Instance Profile: `mlflow-tracking-server-ec2-profile`

### プレフィックス付き

```bash
npx cdk deploy --all \
  --context projectPrefix=phase15 \
  --context instanceType=g7e.12xlarge \
  --context availabilityZone=us-east-1a
```

**生成されるスタック名: **
- MLflow: `phase15-mlflow-prod-east-1`
- NIXL EFA: `phase15-nixl-efa-dev-east-1`

**リソース名: **
- Tracking Server: `phase15-mlflow-tracking-server`
- Instance Profile: `phase15-mlflow-tracking-server-ec2-profile`

## スタック名のカスタマイズ方法

### 1. projectPrefix（推奨）

最もシンプルな方法。すべてのスタックとリソースに一貫してプレフィックスが付きます。

```bash
--context projectPrefix=my-experiment
```

### 2. environment

環境名を変更してスタック名をカスタマイズ。

```bash
--context environment=staging
```

**結果: **
- MLflow: `mlflow-staging-east-1`
- NIXL EFA: `nixl-efa-staging-east-1`

### 3. 個別のスタック名指定

特定のスタックだけ名前を変更したい場合。

```bash
--context mlflowStackName=my-custom-mlflow \
--context nixl-efaStackName=my-custom-nixl
```

## 複数環境の管理例

### 開発環境

```bash
npx cdk deploy --all \
  --context projectPrefix=dev \
  --context instanceType=g5.12xlarge \
  --context availabilityZone=us-east-1a
```

### Phase 15 測定環境

```bash
npx cdk deploy --all \
  --context projectPrefix=phase15 \
  --context instanceType=g7e.12xlarge \
  --context availabilityZone=us-east-1a
```

### Phase 16 測定環境（並行実行）

```bash
npx cdk deploy --all \
  --context projectPrefix=phase16 \
  --context instanceType=g7e.12xlarge \
  --context availabilityZone=us-east-1b
```

## 注意事項

### リソース名の一貫性

`projectPrefix` を使用すると、以下のすべてに一貫してプレフィックスが付きます：

- CloudFormation スタック名
- SageMaker MLflow Tracking Server 名
- IAM ロール名（自動生成）
- IAM Instance Profile 名
- S3 バケット名（bucketName を指定しない場合）

### 既存のスタックとの衝突

既存のスタックやリソースと名前が衝突する場合、以下のエラーが発生します：

```
mlflow-tracking-server already exists in stack arn: ...
Resource handler returned message: "Resource of type 'AWS::IAM::InstanceProfile'
with identifier 'mlflow-tracking-server-ec2-profile' already exists."
```

この場合、`projectPrefix` を使用して別の名前を指定してください。

### スタックの削除

プレフィックスを使用してデプロイした場合、削除時も同じプレフィックスを指定する必要があります：

```bash
npx cdk destroy --all \
  --context projectPrefix=phase15
```

## トラブルシューティング

### スタック名が予期したものと異なる

`cdk synth` でスタック名を確認できます：

```bash
npx cdk synth \
  --context projectPrefix=phase15 \
  --context instanceType=g7e.12xlarge
```

出力の最初にスタック名が表示されます。

### 既存のスタックを見つける

現在デプロイされているスタックを確認：

```bash
aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query 'StackSummaries[?contains(StackName, `mlflow`) || contains(StackName, `nixl`)].StackName' \
  --output table
```

### リソース名の確認

デプロイ後、実際のリソース名を確認：

```bash
aws sagemaker list-mlflow-tracking-servers \
  --query 'TrackingServerSummaries[].TrackingServerName' \
  --output table
```

## まとめ

- スタック名の衝突を避けるには `--context projectPrefix=<名前>` を使用
- プレフィックスはスタック名とすべてのリソース名に一貫して適用される
- 複数の環境を並行して管理する際に便利
