# EFA 実装検証レポート

## 概要

ユーザー提供のサンプルスクリプトと現在の CDK 実装を比較し、EFA の要件がすべて満たされているか検証しました。

## 検証日

2026-02-25

## サンプルスクリプトの分析

ユーザーが提供したサンプルスクリプトから、EFA の実装に必要な重要なポイントを抽出しました：

### 1. セキュリティグループの自己参照ルール（必須）

**サンプルスクリプト（setup-efa-sg.sh）**:
```bash
# EFA 用: セキュリティグループ自身からの全トラフィックを許可
# これは EFA ノード間通信に必須です
aws ec2 authorize-security-group-ingress \
    --group-id "${SG_ID}" \
    --protocol -1 \
    --port -1 \
    --source-group "${SG_ID}" \
    --region "${AWS_REGION}"
```

**現在の CDK 実装（lib/nixl-efa-stack.ts:181-187）**:
```typescript
// All traffic within security group (for EFA)
// EFA requires all protocols, not just TCP
this.securityGroup.addIngressRule(
  this.securityGroup,
  ec2.Port.allTraffic(),
  "All traffic within security group for EFA"
);
```

**検証結果**: ✓ 正しく実装されている

### 2. EFA ネットワークインターフェースの指定

**サンプルスクリプト（launch-efa-instance.sh）**:
```bash
--network-interfaces \
    "DeleteOnTermination=true,DeviceIndex=0,SubnetId=${SUBNET_ID},Groups=${SECURITY_GROUP_ID},InterfaceType=efa"
```

**現在の CDK 実装（lib/nixl-efa-stack.ts:280-286, 289-295）**:
```typescript
// --- EFA Network Interface: Node 1 ---
const node1Efa = new ec2.CfnNetworkInterface(this, "Node1EfaInterface", {
  subnetId: subnet.subnetId,
  groupSet: [this.securityGroup.securityGroupId],
  interfaceType: "efa",
  tags: [{ key: "Name", value: "node1-efa" }],
});

// --- EFA Network Interface: Node 2 ---
const node2Efa = new ec2.CfnNetworkInterface(this, "Node2EfaInterface", {
  subnetId: subnet.subnetId,
  groupSet: [this.securityGroup.securityGroupId],
  interfaceType: "efa",
  tags: [{ key: "Name", value: "node2-efa" }],
});
```

**検証結果**: ✓ 正しく実装されている

### 3. IAM ロール（SSM 接続用）

**サンプルスクリプトのコメント**:
```bash
# IAM ロール（SSM 接続に必要）
# AmazonSSMManagedInstanceCore ポリシーがアタッチされた
# インスタンスプロファイルを事前に作成してください
IAM_INSTANCE_PROFILE="${IAM_INSTANCE_PROFILE: -EfaInstanceProfile}"
```

**現在の CDK 実装（lib/nixl-efa-stack.ts:204-210）**:
```typescript
// --- IAM Role for EC2 with SSM ---
const ec2Role = new iam.Role(this, "NixlEfaInstanceRole", {
  assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
  description: "IAM role for NIXL EFA EC2 instances with SSM and S3 access",
  managedPolicies: [
    iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonSSMManagedInstanceCore"),
  ],
});
```

**検証結果**: ✓ 正しく実装されている

### 4. EFA ドライバのインストール

**サンプルスクリプトの UserData**:
```bash
# EFA インストーラのダウンロードとインストール
cd /tmp
curl -O https://efa-installer.amazonaws.com/aws-efa-installer-latest.tar.gz
tar xzf aws-efa-installer-latest.tar.gz
cd aws-efa-installer
./efa_installer.sh -y
```

**現在の CDK 実装**:
Deep Learning OSS Nvidia Driver AMI を使用しているため、EFA ドライバーは既にプリインストールされています。

```typescript
// --- AMI: Deep Learning OSS Nvidia Driver AMI ---
const ami = ec2.MachineImage.lookup({
  name: "Deep Learning OSS Nvidia Driver AMI GPU PyTorch * (Ubuntu 22.04) *",
  owners: ["amazon"],
});
```

**検証結果**: ✓ Deep Learning AMI に含まれているため、手動インストール不要

### 5. Placement Group（推奨）

サンプルスクリプトには明示的な記載はありませんが、EFA の低遅延通信には Placement Group が推奨されます。

**現在の CDK 実装（lib/nixl-efa-stack.ts:189-192）**:
```typescript
// --- Placement Group ---
this.placementGroup = new ec2.CfnPlacementGroup(this, "NixlClusterPlacementGroup", {
  strategy: "cluster",
});
```

**検証結果**: ✓ 正しく実装されている（サンプルより優れている）

### 6. SSH ポートの扱い

**サンプルスクリプト**:
```bash
# SSH アクセスを許可（必要に応じて IP を制限してください）
aws ec2 authorize-security-group-ingress \
    --group-id "${SG_ID}" \
    --protocol tcp \
    --port 22 \
    --cidr "0.0.0.0/0" \
    --region "${AWS_REGION}"
```

**現在の CDK 実装**:
SSH ポート（22）を開かず、SSM Session Manager のみを使用するセキュアな設計を採用しています。

```typescript
// Note: SSH port (22) is NOT opened. Use SSM Session Manager for secure access.
```

**検証結果**: ✓ よりセキュアな実装（サンプルより優れている）

## 追加の実装項目

現在の CDK 実装には、サンプルスクリプトには含まれていない以下の機能も含まれています：

### 1. S3 バケットの自動作成とアクセス権限

```typescript
// --- S3 Bucket for Scripts ---
this.scriptsBucket = new s3.Bucket(this, "ScriptsBucket", {
  removalPolicy: RemovalPolicy.DESTROY,
  autoDeleteObjects: true,
  versioned: false,
  encryption: s3.BucketEncryption.S3_MANAGED,
  blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
});

// Grant S3 read access to scripts bucket
this.scriptsBucket.grantRead(ec2Role);
```

### 2. CloudWatch Logs アクセス権限

```typescript
// CloudWatch Logs access for SSM session logging
ec2Role.addToPolicy(
  new iam.PolicyStatement({
    actions: [
      "logs: CreateLogGroup",
      "logs: CreateLogStream",
      "logs: PutLogEvents",
    ],
    resources: [
      `arn: aws: logs: ${this.region}: ${this.account}: log-group:/aws/ssm/*`,
    ],
  })
);
```

### 3. インスタンスタイプの検証

```typescript
// --- Validate instance type ---
if (!EFA_SUPPORTED_INSTANCE_TYPES.includes(instanceType)) {
  Annotations.of(this).addWarning(
    `Instance type ${instanceType} may not support EFA. ` +
    `Supported types: ${EFA_SUPPORTED_INSTANCE_TYPES.join(", ")}`
  );
}
```

### 4. ボリュームサイズの自動推奨

```typescript
// --- Determine volume size ---
const recommendedVolumeSize = RECOMMENDED_VOLUME_SIZES[instanceType] || 200;
const finalVolumeSize = volumeSize || recommendedVolumeSize;

// Warn if volume size is significantly smaller than recommended
if (volumeSize && volumeSize < recommendedVolumeSize * 0.8) {
  Annotations.of(this).addWarning(
    `Volume size ${volumeSize}GB is smaller than recommended ${recommendedVolumeSize}GB for ${instanceType}`
  );
}
```

### 5. ML Capacity Block のサポート

```typescript
// Add capacity block configuration if enabled
if (useCapacityBlock) {
  (node1Props as any).instanceMarketOptions = {
    marketType: "capacity-block",
  };
}

// Add capacity reservation specification if provided
if (capacityReservationId) {
  (node1Props as any).capacityReservationSpecification = {
    capacityReservationTarget: {
      capacityReservationId: capacityReservationId,
    },
  };
}
```

## EFA 検証手順の追加

サンプルスクリプト（verify-efa.sh、run-efa-test.sh）を参考に、README.md に以下のセクションを追加しました：

### 1. EFA の仕組みと要件

- セキュリティグループの自己参照ルールの重要性
- EFA ネットワークインターフェースの必要性
- Placement Group の推奨理由
- EFA 対応インスタンスタイプの一覧

### 2. EFA デバイスの確認手順

- PCIe デバイスとして EFA を確認
- EFA カーネルドライバの確認
- libfabric の EFA Provider 確認
- RDMA デバイスファイルの確認
- ネットワークインターフェースの確認

### 3. EFA 通信テスト

- Node1 でサーバーを起動（fi_pingpong）
- Node2 でクライアントを起動
- 期待される出力の例

### 4. トラブルシューティング

- セキュリティグループの設定不足
- EFA デバイスが認識されていない
- Placement Group の設定不足

## 検証結果サマリー

| 項目 | サンプルスクリプト | CDK 実装 | 検証結果 |
|------|-------------------|---------|---------|
| セキュリティグループ自己参照ルール | ✓ あり | ✓ あり | ✓ 一致 |
| EFA ネットワークインターフェース | ✓ あり | ✓ あり | ✓ 一致 |
| IAM ロール（SSM） | ✓ あり | ✓ あり | ✓ 一致 |
| EFA ドライバインストール | ✓ あり | ✓ AMI に含む | ✓ 対応 |
| Placement Group | - なし | ✓ あり | ✓ 優れている |
| SSH ポート | ✓ 開放 | ✓ 閉鎖（SSM のみ） | ✓ よりセキュア |
| S3 バケット管理 | - なし | ✓ あり | ✓ 追加機能 |
| CloudWatch Logs | - なし | ✓ あり | ✓ 追加機能 |
| インスタンスタイプ検証 | - なし | ✓ あり | ✓ 追加機能 |
| ボリュームサイズ推奨 | - なし | ✓ あり | ✓ 追加機能 |
| ML Capacity Block | - なし | ✓ あり | ✓ 追加機能 |

## 結論

### 考慮漏れ: なし

現在の CDK 実装は、サンプルスクリプトで示された EFA の要件をすべて満たしており、考慮漏れはありません。

### 実装の優位性

現在の CDK 実装は、サンプルスクリプトと比較して以下の点で優れています：

1. **Placement Group の自動設定**: 低遅延通信を実現
2. **よりセキュアなアクセス制御**: SSH ポートを開かず SSM Session Manager のみを使用
3. **完全な IaC**: すべてのリソースが CDK で管理され、再現性が高い
4. **自動化**: S3 バケット、IAM 権限、ボリュームサイズなどを自動設定
5. **検証機能**: インスタンスタイプやボリュームサイズの妥当性を自動チェック
6. **拡張機能**: ML Capacity Block のサポートなど、高度な機能に対応

### 推奨事項

1. **デプロイ後の EFA 検証**: README.md に記載された手順に従って、EFA が正しく動作していることを確認してください

2. **EFA 通信テスト**: 本番利用前に `fi_pingpong` を使用して 2 ノード間の通信をテストすることを推奨します

3. **既存の JSON タスク定義の活用**: `/work/data-science/claudecode/investigations/nixl-efa-tai/setup/tasks/step1-verify-efa.json` を使用すれば、自動的に EFA 検証を実行できます

## 参考資料

- [サンプルスクリプト（ユーザー提供）](#)
- [AWS EFA Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
- [EFA on AWS Deep Learning AMI](https://docs.aws.amazon.com/dlami/latest/devguide/tutorial-efa-launching.html)
- [現在の CDK 実装](lib/nixl-efa-stack.ts)
- [README - EFA について](README.md#efa%E3%80%88elastic-fabric-adapter%E3%80%89%E3%81%AB%E3%81%A4%E3%81%84%E3%81%A6)

---

**検証者**: Claude Code (Sonnet 4.5)
**検証日**: 2026-02-25
**バージョン**: 1.0
