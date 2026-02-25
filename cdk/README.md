# NIXL EFA CDK Stack

AWS CDK を使用した NIXL（Disaggregated Inference）の EFA 環境構築スタックです。

## 概要

このスタックは以下のリソースを作成します：

- **VPC**: デフォルト VPC または指定された VPC を使用
- **EC2 インスタンス × 2**: EFA 対応の GPU インスタンス（g5.12xlarge）
- **Placement Group**: クラスター配置戦略でノード間の低遅延通信を実現
- **Security Group**: EFA 通信用（allTraffic）+ vLLM HTTP（8100）
- **S3 Bucket**: デプロイメントスクリプト用（自動作成）
- **IAM Role**: SSM Session Manager + S3 読み取り + CloudWatch Logs

## 主要な機能

### 完全自動化

- **手動設定不要**: `cdk deploy` だけで完全な環境が構築される
- **S3 バケット自動作成**: スクリプト配布用バケットを自動作成
- **IAM 権限自動設定**: S3 アクセス権限を自動付与（最小権限の原則）
- **SSM Session Manager**: SSH 不要のセキュアなアクセス（ポート 22 は閉じている）

### セキュリティ

- **SSH ポート閉鎖**: SSM Session Manager 経由でのみアクセス可能
- **S3 暗号化**: S3_MANAGED 暗号化を有効化
- **パブリックアクセス禁止**: S3 バケットへのパブリックアクセスをブロック
- **最小権限の原則**: 必要最低限の IAM 権限のみ付与

### EFA サポート

- **allTraffic ルール**: EFA に必要なすべてのプロトコル（TCP/UDP/RDMA）を許可
- **Cluster Placement Group**: ノード間の低遅延通信を実現
- **EFA ネットワークインターフェース**: 専用 EFA NIC を自動作成

## デプロイ手順

### 1. 前提条件

- AWS CLI 設定済み（認証情報とリージョン）
- Node.js 18.x 以上
- AWS CDK CLI インストール済み

```bash
npm install -g aws-cdk
```

### 2. 依存関係のインストール

```bash
cd /work/data-science/disaggregated-inference-with-nixl-over-aws-efa/cdk
npm install
```

### 3. CDK ブートストラップ（初回のみ）

```bash
cdk bootstrap aws://ACCOUNT_ID/us-east-1
```

### 4. スタックのデプロイ

```bash
cdk deploy nixl-efa-dev-east-1
```

デプロイ完了後、以下の出力が表示されます：

```
Outputs:
nixl-efa-dev-east-1.Node1InstanceId = i-xxxxxxxxxxxxx
nixl-efa-dev-east-1.Node1PublicIp = 3.80.45.55
nixl-efa-dev-east-1.Node1PrivateIp = 172.31.27.16
nixl-efa-dev-east-1.Node2InstanceId = i-yyyyyyyyyyyyy
nixl-efa-dev-east-1.Node2PublicIp = 18.232.147.93
nixl-efa-dev-east-1.Node2PrivateIp = 172.31.20.197
nixl-efa-dev-east-1.ScriptsBucketName = nixl-efa-dev-east-1-scriptsbucket-xxxxx
nixl-efa-dev-east-1.SecurityGroupId = sg-xxxxxxxxxxxxx
nixl-efa-dev-east-1.PlacementGroupName = nixl-efa-dev-east-1-NixlClusterPlacementGroup-xxxxx
```

## スクリプトのアップロード

デプロイ後、task runner とタスク定義を S3 にアップロードします：

```bash
# CloudFormation から S3 バケット名を取得
BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name nixl-efa-dev-east-1 \
  --query 'Stacks[0].Outputs[?OutputKey==`ScriptsBucketName`].OutputValue' \
  --output text)

# スクリプトをアップロード
cd /work/data-science/claudecode/investigations/nixl-efa-tai/setup
aws s3 cp task_runner.sh s3://$BUCKET_NAME/
aws s3 cp tasks/ s3://$BUCKET_NAME/tasks/ --recursive
```

## 完全自動検証の実行

環境セットアップ、MLflow 検証、EFA 検証を一括実行：

```bash
cd /work/data-science/claudecode/investigations/nixl-efa-tai/setup
./step1-deploy-and-verify.sh nixl-efa-dev-east-1
```

このスクリプトは以下を実行します：

1. CloudFormation スタックから情報を取得（Instance ID、IP アドレス、S3 バケット名）
2. S3 バケットにスクリプトをアップロード
3. 両ノードで環境セットアップを実行（vLLM、NIXL、MLflow）
4. MLflow の書き込み・読み出しテスト
5. EFA の設定確認
6. 結果をサマリーで表示

## インスタンスへのアクセス

### SSM Session Manager でログイン

```bash
# Node1 にアクセス
aws ssm start-session --target i-xxxxxxxxxxxxx

# Node2 にアクセス
aws ssm start-session --target i-yyyyyyyyyyyyy
```

### MLflow UI へのアクセス（ポートフォワーディング）

```bash
# Node1 の MLflow UI にアクセス
aws ssm start-session \
  --target i-xxxxxxxxxxxxx \
  --document-name AWS-StartPortForwardingSession \
  --parameters "portNumber=5000,localPortNumber=5000"

# ブラウザで http://localhost:5000 を開く
```

## サポートされているインスタンスタイプ

### EFA 対応インスタンス

このスタックは EFA（Elastic Fabric Adapter）をサポートするインスタンスタイプのみで動作します。

| シリーズ | インスタンスタイプ | GPU | 推奨ボリュームサイズ | 用途 |
|----------|-------------------|-----|---------------------|------|
| **G5** | g5.12xlarge | NVIDIA A10G × 4 | 200 GB | 開発・テスト |
| | g5.24xlarge | NVIDIA A10G × 4 | 300 GB | 中規模推論 |
| | g5.48xlarge | NVIDIA A10G × 8 | 500 GB | 大規模推論 |
| **G6** | g6.12xlarge | NVIDIA L4 × 4 | 200 GB | 開発・テスト |
| | g6.24xlarge | NVIDIA L4 × 4 | 300 GB | 中規模推論 |
| | g6.48xlarge | NVIDIA L4 × 8 | 500 GB | 大規模推論 |
| **G6e** | g6e.12xlarge | NVIDIA L40S × 4 | 200 GB | AI ワークステーション |
| | g6e.24xlarge | NVIDIA L40S × 4 | 300 GB | AI トレーニング |
| | g6e.48xlarge | NVIDIA L40S × 8 | 500 GB | 大規模 AI |
| **G7e** | g7e.8xlarge | NVIDIA RTX PRO 6000 Blackwell × 1 | 300 GB | グラフィックス + AI |
| | g7e.12xlarge | NVIDIA RTX PRO 6000 Blackwell × 2 | 300 GB | レンダリング + 推論 |
| | g7e.24xlarge | NVIDIA RTX PRO 6000 Blackwell × 4 | 500 GB | 空間コンピューティング |
| | g7e.48xlarge | NVIDIA RTX PRO 6000 Blackwell × 8 | 1000 GB | 最高性能グラフィックス |
| **P4d** | p4d.24xlarge | NVIDIA A100 × 8 | 500 GB | トレーニング |
| **P4de** | p4de.24xlarge | NVIDIA A100 × 8 | 500 GB | トレーニング |
| **P5** | p5.48xlarge | NVIDIA H100 × 8 | 1000 GB | 最高性能 |
| **Trn1** | trn1.32xlarge | AWS Trainium × 16 | 500 GB | トレーニング |
| | trn1n.32xlarge | AWS Trainium × 16 | 500 GB | トレーニング（高速 NW） |
| **Inf2** | inf2.24xlarge | AWS Inferentia2 × 6 | 300 GB | 推論 |
| | inf2.48xlarge | AWS Inferentia2 × 12 | 500 GB | 推論 |

**注意**:
- ボリュームサイズを指定しない場合、インスタンスタイプに応じた推奨サイズが自動設定されます
- 推奨サイズより 20% 以上小さいボリュームを指定すると警告が表示されます
- EFA 非対応のインスタンスタイプを指定すると警告が表示されます

### インスタンスタイプの指定方法

#### 方法 1: コンテキストで指定（推奨）

```bash
# g5.24xlarge でデプロイ
cdk deploy -c instanceType=g5.24xlarge

# p5.48xlarge でデプロイ（ボリュームサイズも指定）
cdk deploy -c instanceType=p5.48xlarge -c volumeSize=1000
```

#### 方法 2: bin/app.ts で指定

```typescript
const nixlEfaStack = new NixlEfaStack(app, nixlEfaStackName, {
  instanceType: "g6e.12xlarge",  // 変更
  volumeSize: 300,               // 推奨サイズ（省略可能）
  // ...
});
```

#### 方法 3: cdk.json でデフォルト値を設定

```json
{
  "context": {
    "instanceType": "g5.12xlarge",
    "volumeSize": 200
  }
}
```

### ML Capacity Block のサポート

ML Capacity Block を使用すると、特定期間のキャパシティを予約購入できます。P5 などの需要が高いインスタンスタイプで確実にキャパシティを確保できます。

#### Capacity Block の使用

```bash
# Capacity Block を使用してデプロイ
cdk deploy -c useCapacityBlock=true

# 特定の Capacity Reservation を指定
cdk deploy -c capacityReservationId=cr-xxxxxxxxxxxxx
```

#### Capacity Block の管理

参考実装: [manage-capacity-block.sh](https://github.com/littlemex/samples/blob/main/aws-neuron/torch-neuronx/multi-framework-dlami-ubuntu24-cdk/scripts/manage-capacity-block.sh)

**キャパシティブロックの検索**:
```bash
aws ec2 describe-capacity-block-offerings \
  --instance-type p5.48xlarge \
  --instance-count 2 \
  --capacity-duration-hours 24 \
  --start-date-range "$(date -u +%Y-%m-%dT%H: %M: %S.000Z)" \
  --end-date-range "$(date -u -d '+7 days' +%Y-%m-%dT%H: %M: %S.000Z)"
```

**キャパシティブロックの購入**:
```bash
aws ec2 purchase-capacity-block \
  --capacity-block-offering-id cbo-xxxxxxxxxxxxx \
  --instance-platform Linux/UNIX
```

**購入した Reservation ID の取得**:
```bash
aws ec2 describe-capacity-reservations \
  --filters Name=instance-type,Values=p5.48xlarge
```

**CDK でデプロイ**:
```bash
# Reservation ID を使用してデプロイ
cdk deploy \
  -c instanceType=p5.48xlarge \
  -c capacityReservationId=cr-xxxxxxxxxxxxx
```

#### Parameter Store との統合

Capacity Reservation ID を Parameter Store に保存することで、デプロイ時に自動取得できます：

```bash
# Reservation ID を Parameter Store に保存
aws ssm put-parameter \
  --name "/nixl-efa/capacity-reservation-id" \
  --value "cr-xxxxxxxxxxxxx" \
  --type String

# デプロイ時に Parameter Store から取得
RESERVATION_ID=$(aws ssm get-parameter \
  --name "/nixl-efa/capacity-reservation-id" \
  --query 'Parameter.Value' \
  --output text)

cdk deploy -c capacityReservationId=$RESERVATION_ID
```

#### 注意事項

- **コスト**: Capacity Block は前払いで課金されます
- **期間**: 1 時間〜数日間の予約が可能
- **キャンセル**: キャンセル料が発生する可能性があります
- **可用性**: すべてのリージョンで利用可能とは限りません

## スタックの詳細設定

### オプションパラメータ

| パラメータ | 説明 | デフォルト | 指定方法 |
|-----------|------|-----------|---------|
| instanceType | EC2 インスタンスタイプ（EFA 対応必須） | g5.12xlarge | -c instanceType=VALUE |
| volumeSize | ルートボリュームサイズ（GB） | 自動（推奨値） | -c volumeSize=VALUE |
| vllmPort | vLLM HTTP ポート | 8100 | -c vllmPort=VALUE |
| availabilityZone | アベイラビリティゾーン | 自動（最初の AZ） | -c availabilityZone=VALUE |
| vpcId | 既存 VPC の ID | デフォルト VPC | -c vpcId=VALUE |
| keyName | SSH キーペア名（非推奨） | なし | -c keyName=VALUE |
| useCapacityBlock | ML Capacity Block を使用 | false | -c useCapacityBlock=true |
| capacityReservationId | Capacity Reservation ID | なし | -c capacityReservationId=VALUE |

### 設定例

#### 例 1: g5.24xlarge でデプロイ

```bash
cdk deploy -c instanceType=g5.24xlarge
```

#### 例 2: p5.48xlarge でカスタムボリュームサイズ

```bash
cdk deploy -c instanceType=p5.48xlarge -c volumeSize=1000
```

#### 例 3: 特定の VPC とアベイラビリティゾーンを指定

```bash
cdk deploy \
  -c instanceType=g6e.12xlarge \
  -c vpcId=vpc-xxxxxxxxxxxxx \
  -c availabilityZone=us-east-1a
```

#### 例 4: bin/app.ts で直接指定

```typescript
new NixlEfaStack(app, "nixl-efa-dev-east-1", {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: "us-east-1",
  },
  // カスタム設定
  instanceType: "g6e.12xlarge",       // NVIDIA L40S
  volumeSize: 300,                    // 推奨サイズ
  vllmPort: 8100,                     // vLLM HTTP ポート
  availabilityZone: "us-east-1a",     // 特定の AZ
  // vpcId: "vpc-xxxxx",              // 既存 VPC を使用する場合
});
```

## スタックの削除

```bash
cdk destroy nixl-efa-dev-east-1
```

**注意**: `autoDeleteObjects: true` が設定されているため、S3 バケット内のファイルもすべて削除されます。

## EFA（Elastic Fabric Adapter）について

### EFA の仕組みと要件

EFA は AWS が提供する高性能ネットワークインターフェースで、以下の要件があります：

#### 1. セキュリティグループの自己参照ルール（必須）

**EFA ノード間の通信には、セキュリティグループ自身からの全トラフィック許可が必須です。**

本スタックでは以下のように設定されています：
```typescript
this.securityGroup.addIngressRule(
  this.securityGroup,         // 自分自身のセキュリティグループから
  ec2.Port.allTraffic(),      // すべてのプロトコル・ポートを許可
  "All traffic within security group for EFA"
);
```

これにより、同じセキュリティグループに属するインスタンス間で RDMA 通信が可能になります。

#### 2. EFA ネットワークインターフェース

インスタンス起動時に `interfaceType: "efa"` を指定する必要があります：
```typescript
const node1Efa = new ec2.CfnNetworkInterface(this, "Node1EfaInterface", {
  subnetId: subnet.subnetId,
  groupSet: [this.securityGroup.securityGroupId],
  interfaceType: "efa",  // EFA を有効化
});
```

#### 3. Placement Group（推奨）

低遅延通信のため、cluster 戦略の Placement Group を使用：
```typescript
this.placementGroup = new ec2.CfnPlacementGroup(this, "NixlClusterPlacementGroup", {
  strategy: "cluster",  // ノードを物理的に近接配置
});
```

#### 4. EFA 対応インスタンスタイプ

すべてのインスタンスタイプが EFA をサポートしているわけではありません。サポート状況は「サポートされているインスタンスタイプ」セクションを参照してください。

### EFA デバイスの確認手順

デプロイ後、SSM Session Manager でインスタンスに接続し、以下の手順で EFA デバイスを確認します。

#### ステップ 1: インスタンスに接続

```bash
# Node1 に接続
aws ssm start-session --target i-xxxxxxxxxxxxx
```

#### ステップ 2: PCIe デバイスとして EFA を確認

```bash
# EFA デバイスが PCIe で認識されているか確認
lspci | grep -i "Amazon.*Elastic Fabric Adapter"

# 出力例:
# 00:06.0 Ethernet controller: Amazon.com, Inc. Elastic Fabric Adapter (EFA)
```

#### ステップ 3: EFA カーネルドライバの確認

```bash
# EFA ドライバがロードされているか確認
lsmod | grep efa

# ドライバ情報の詳細表示
modinfo efa | head -5
```

#### ステップ 4: libfabric の EFA Provider 確認

```bash
# fi_info コマンドで EFA Provider を確認
fi_info -p efa

# 出力例:
# provider: efa
# fabric: efa-direct
# domain: rdmap0s26-rdm
# type: FI_EP_RDM
# protocol: FI_PROTO_EFA
```

#### ステップ 5: RDMA デバイスファイルの確認

```bash
# /dev/infiniband/ にデバイスファイルが存在するか確認
ls -la /dev/infiniband/

# 出力例:
# total 0
# drwxr-xr-x  2 root root       80 Feb 25 10:00 .
# drwxr-xr-x 20 root root     3260 Feb 25 10:00 ..
# crw-------  1 root root 231,  64 Feb 25 10:00 rdma_cm
# crw-------  1 root root  10, 125 Feb 25 10:00 uverbs0
```

#### ステップ 6: ネットワークインターフェースの確認

```bash
# EFA のネットワークインターフェースを確認
ip link show | grep -A1 "efa\|eth"

# EFA のアドレスを確認
ip addr show dev eth0
```

### EFA 通信テスト（2 台のインスタンスが必要）

#### Node1 でサーバーを起動

```bash
# SSM で Node1 に接続
aws ssm start-session --target i-xxxxxxxxxxxxx

# 環境変数の設定
export PATH=/opt/amazon/efa/bin:/opt/amazon/openmpi/bin: $PATH
export LD_LIBRARY_PATH=/opt/amazon/efa/lib64:/opt/amazon/openmpi/lib64: $LD_LIBRARY_PATH

# Private IP を確認（Node2 から接続する際に使用）
hostname -I | awk '{print $1}'

# fi_pingpong サーバーを起動
fi_pingpong -p efa
```

#### Node2 でクライアントを起動

```bash
# SSM で Node2 に接続
aws ssm start-session --target i-yyyyyyyyyyyyy

# 環境変数の設定
export PATH=/opt/amazon/efa/bin:/opt/amazon/openmpi/bin: $PATH
export LD_LIBRARY_PATH=/opt/amazon/efa/lib64:/opt/amazon/openmpi/lib64: $LD_LIBRARY_PATH

# Node1 の Private IP を指定して接続（例: 172.31.27.16）
fi_pingpong -p efa 172.31.27.16
```

**期待される出力**:
```
bytes   #sent   #ack     total       time     MB/sec    usec/xfer   Mxfers/sec
64      10      =10      1.2k        0.00s    267.38    0.24        4.18
256     10      =10      5k          0.00s    1069.51   0.24        4.18
1k      10      =10      20k         0.00s    4278.05   0.24        4.18
```

この出力が表示されれば、EFA が正しく動作しています。

## トラブルシューティング

### S3 バケットへのアクセスが拒否される

- CDK スタックが正しくデプロイされているか確認
- IAM ロールに S3 読み取り権限が付与されているか確認

```bash
aws cloudformation describe-stacks \
  --stack-name nixl-efa-dev-east-1 \
  --query 'Stacks[0].Outputs'
```

### EFA が動作しない

#### 原因 1: セキュリティグループの設定不足

**確認方法**:
```bash
# セキュリティグループのルールを確認
SG_ID=$(aws cloudformation describe-stacks \
  --stack-name nixl-efa-dev-east-1 \
  --query 'Stacks[0].Outputs[?OutputKey==`SecurityGroupId`].OutputValue' \
  --output text)

aws ec2 describe-security-groups \
  --group-ids $SG_ID \
  --query 'SecurityGroups[0].IpPermissions'
```

**期待される出力**:
- `IpProtocol: "-1"`（全プロトコル）
- `UserIdGroupPairs` に自分自身のセキュリティグループ ID が含まれる

#### 原因 2: EFA デバイスが認識されていない

**確認方法**:
```bash
# PCIe デバイス確認
lspci | grep -i "Amazon.*Elastic Fabric Adapter"

# EFA ドライバ確認
lsmod | grep efa
```

**対処法**:
- インスタンスタイプが EFA に対応しているか確認
- Deep Learning AMI に EFA ドライバーがプリインストールされているか確認

#### 原因 3: Placement Group の設定不足

**確認方法**:
```bash
# インスタンスの Placement Group を確認
aws ec2 describe-instances \
  --instance-ids i-xxxxxxxxxxxxx \
  --query 'Reservations[0].Instances[0].Placement'
```

**期待される出力**:
```json
{
  "AvailabilityZone": "us-east-1a",
  "GroupName": "nixl-efa-dev-east-1-NixlClusterPlacementGroup-xxxxx",
  "Tenancy": "default"
}
```

### MLflow に接続できない

- MLflow サーバーが起動しているか確認

```bash
# SSM Session Manager でログイン
aws ssm start-session --target i-xxxxxxxxxxxxx

# MLflow プロセス確認
pgrep -f mlflow

# MLflow ログ確認
tail -f /tmp/mlflow-server.log
```

## 参考資料

- [AWS CDK Documentation](https://docs.aws.amazon.com/cdk/)
- [EFA on AWS Deep Learning AMI](https://docs.aws.amazon.com/dlami/latest/devguide/tutorial-efa-launching.html)
- [SSM Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- [NIXL Documentation](https://github.com/aws-samples/awsome-distributed-training/tree/main/3.test_cases/12.SM-modelparallelv2/scripts/llama2)

## ライセンス

このプロジェクトは MIT ライセンスの下で公開されています。
