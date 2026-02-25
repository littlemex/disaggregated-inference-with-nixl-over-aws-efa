# CDK Stack 完全自動化のための改善案（Opus4.6 レビュー反映版）

## レビュー結果サマリー

Opus4.6 による包括的レビューの結果、以下の問題が特定されました：

### CRITICAL（即座に修正必要）
1. **S3 権限が CDK に含まれていない** - 手動追加は CDK 再デプロイ時にドリフトする

### HIGH（優先度高）
1. EFA セキュリティグループルールの不一致（`allTcp` vs `allTraffic`）
2. runner.sh が SSH 前提だが、本番 CDK は SSH を閉じている
3. S3 バケットの手動作成

### MEDIUM（推奨）
1. MLflow ポート（5000）のセキュリティグループルール未定義
2. CloudWatch Logs 権限の追加

---

## 修正内容

### 1. S3 バケットの追加とアクセス権限の設定（CRITICAL）

**問題**: 手動で作成した S3 バケットと `AmazonS3ReadOnlyAccess` ポリシーは CDK 管理外のため、`cdk deploy` 時にドリフトします。

**解決策**: CDK スタックで S3 バケットを作成し、最小権限の原則に従って特定のバケットのみへのアクセスを許可します。

```typescript
// lib/nixl-efa-stack.ts に追加

import * as s3 from "aws-cdk-lib/aws-s3";

export class NixlEfaStack extends Stack {
  // ... 既存のプロパティ
  public readonly scriptsBucket: s3.Bucket;

  constructor(scope: Construct, id: string, props: NixlEfaStackProps) {
    super(scope, id, props);

    // ... 既存の VPC、AMI、SecurityGroup 設定

    // --- S3 Bucket for Scripts (CRITICAL FIX) ---
    this.scriptsBucket = new s3.Bucket(this, "ScriptsBucket", {
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
      versioned: false,
      encryption: s3.BucketEncryption.S3_MANAGED, // セキュリティ強化
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL, // セキュリティ強化
    });

    // ... IAM ロール作成

    // --- Grant S3 Read Access with Least Privilege (CRITICAL FIX) ---
    this.scriptsBucket.grantRead(ec2Role);

    // または、より明示的に：
    // ec2Role.addToPolicy(
    //   new iam.PolicyStatement({
    //     actions: ["s3: GetObject", "s3: ListBucket"],
    //     resources: [
    //       this.scriptsBucket.bucketArn,
    //       `${this.scriptsBucket.bucketArn}/*`,
    //     ],
    //   })
    // );

    // ... 既存のインスタンス作成

    // --- Output S3 Bucket Name ---
    new CfnOutput(this, "ScriptsBucketName", {
      value: this.scriptsBucket.bucketName,
      description: "S3 bucket for deployment scripts",
      exportName: `${this.stackName}-ScriptsBucketName`,
    });
  }
}
```

### 2. EFA セキュリティグループルールの修正（HIGH）

**問題**: 開発版 CDK スタック（`infrastructure/cdk/`）では `allTcp()` を使用していますが、EFA は TCP だけでなく RDMA over UDP や独自プロトコルを使用します。

**解決策**: 本番版と同様に `allTraffic()` を使用します。

```typescript
// 開発版の lib/nixl-efa-stack.ts を修正（行 106-110）

// BEFORE (不十分):
this.securityGroup.addIngressRule(
  this.securityGroup,
  ec2.Port.allTcp(),
  "All TCP traffic within security group for EFA"
);

// AFTER (正しい):
this.securityGroup.addIngressRule(
  this.securityGroup,
  ec2.Port.allTraffic(),
  "All traffic within security group for EFA"
);
```

### 3. Instance ID の出力追加（HIGH）

**問題**: SSM Send Command で必要な Instance ID が CloudFormation Outputs に含まれていません。

**解決策**: Instance ID を出力に追加します。

```typescript
// lib/nixl-efa-stack.ts の Outputs セクションに追加

new CfnOutput(this, "Node1InstanceId", {
  value: this.node1.ref,
  description: "Node 1 instance ID",
  exportName: `${this.stackName}-Node1InstanceId`,
});

new CfnOutput(this, "Node2InstanceId", {
  value: this.node2.ref,
  description: "Node 2 instance ID",
  exportName: `${this.stackName}-Node2InstanceId`,
});
```

### 4. MLflow ポートのセキュリティグループルール追加（MEDIUM）

**問題**: ノード間で MLflow にアクセスする場合、MLflow ポート（5000）への通信が必要ですが、現在は vLLM ポート（8100）のみ許可されています。

**解決策 1（推奨）**: 同一セキュリティグループ内の `allTraffic()` ルールが既に存在する場合、追加不要です（本番版はこれに該当）。

**解決策 2**: 明示的に MLflow ポートを追加する場合：

```typescript
// lib/nixl-efa-stack.ts のセキュリティグループ設定に追加

// MLflow HTTP access (VPC only)
this.securityGroup.addIngressRule(
  ec2.Peer.ipv4(this.vpc.vpcCidrBlock),
  ec2.Port.tcp(5000),
  "Allow MLflow HTTP from VPC"
);
```

### 5. CloudWatch Logs アクセス権限の追加（MEDIUM）

**問題**: SSM Session Manager のセッションログを保存する場合、CloudWatch Logs への書き込み権限が必要です。

**解決策**:

```typescript
// lib/nixl-efa-stack.ts の IAM ロール定義に追加

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

---

## 完全な修正版 lib/nixl-efa-stack.ts

以下、重要な修正部分のみ抜粋：

```typescript
import * as cdk from "aws-cdk-lib";
import { Stack, StackProps, CfnOutput, Tags, Fn } from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as iam from "aws-cdk-lib/aws-iam";
import * as s3 from "aws-cdk-lib/aws-s3"; // 追加
import { Construct } from "constructs";

export class NixlEfaStack extends Stack {
  public readonly node1: ec2.CfnInstance;
  public readonly node2: ec2.CfnInstance;
  public readonly securityGroup: ec2.ISecurityGroup;
  public readonly placementGroup: ec2.CfnPlacementGroup;
  public readonly vpc: ec2.IVpc;
  public readonly scriptsBucket: s3.Bucket; // 追加

  constructor(scope: Construct, id: string, props: NixlEfaStackProps) {
    super(scope, id, props);

    // ... VPC, AMI, SecurityGroup, PlacementGroup の設定（既存のまま）

    // --- Security Group Rules (FIX: allTraffic for EFA) ---
    this.securityGroup.addIngressRule(
      this.securityGroup,
      ec2.Port.allTraffic(), // allTcp() から変更
      "All traffic within security group for EFA"
    );

    // --- S3 Bucket for Scripts (NEW) ---
    this.scriptsBucket = new s3.Bucket(this, "ScriptsBucket", {
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
      versioned: false,
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
    });

    // --- IAM Role for EC2 with SSM and S3 (FIX: S3 access added) ---
    const ec2Role = new iam.Role(this, "NixlEfaInstanceRole", {
      assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
      description: "IAM role for NIXL EFA EC2 instances with SSM and S3 access",
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonSSMManagedInstanceCore"),
      ],
    });

    // Grant S3 read access (CRITICAL FIX)
    this.scriptsBucket.grantRead(ec2Role);

    // CloudWatch Logs access (MEDIUM FIX)
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

    // ... MLflow 権限設定、インスタンス作成（既存のまま）

    // --- Outputs (FIX: Instance IDs and S3 Bucket added) ---
    new CfnOutput(this, "Node1InstanceId", {
      value: this.node1.ref,
      description: "Node 1 instance ID",
      exportName: `${this.stackName}-Node1InstanceId`,
    });

    new CfnOutput(this, "Node2InstanceId", {
      value: this.node2.ref,
      description: "Node 2 instance ID",
      exportName: `${this.stackName}-Node2InstanceId`,
    });

    new CfnOutput(this, "ScriptsBucketName", {
      value: this.scriptsBucket.bucketName,
      description: "S3 bucket for deployment scripts",
      exportName: `${this.stackName}-ScriptsBucketName`,
    });

    // ... その他の既存 Outputs
  }
}
```

---

## デプロイ手順

### 1. CDK スタックのデプロイ

```bash
cd /work/data-science/disaggregated-inference-with-nixl-over-aws-efa/cdk
npm install  # 初回のみ
cdk deploy nixl-efa-dev-east-1
```

### 2. スクリプトのアップロード

```bash
cd /work/data-science/claudecode/investigations/nixl-efa-tai/setup

# CloudFormation から S3 バケット名を取得
BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name nixl-efa-dev-east-1 \
  --query 'Stacks[0].Outputs[?OutputKey==`ScriptsBucketName`].OutputValue' \
  --output text)

# スクリプトをアップロード
aws s3 cp task_runner.sh s3://$BUCKET_NAME/
aws s3 cp tasks/ s3://$BUCKET_NAME/tasks/ --recursive
```

### 3. 完全自動検証の実行

```bash
./deploy-and-verify.sh nixl-efa-dev-east-1
```

---

## Opus4.6 レビュー指摘事項の対応状況

| 優先度 | 問題 | 対応状況 | 備考 |
|--------|------|----------|------|
| CRITICAL | S3 権限が CDK に含まれていない | [OK] 修正済み | `scriptsBucket.grantRead()` で解決 |
| CRITICAL | vLLM 0.15.1 が存在しない可能性 | [確認済み] 問題なし | 実際のノードで動作確認済み |
| HIGH | EFA セキュリティグループルール | [OK] 修正済み | `allTraffic()` に統一 |
| HIGH | runner.sh と SSH の不整合 | [OK] 対応済み | `deploy-and-verify.sh` で SSM Send Command 化 |
| HIGH | S3 バケットの手動作成 | [OK] 修正済み | CDK で自動作成 |
| MEDIUM | MLflow ヘルスチェックの sleep 5 | [OK] 修正済み | リトライロジック実装 |
| MEDIUM | pip install の--no-cache-dir 不統一 | [OK] 修正済み | 全タスクに追加 |
| MEDIUM | MLflow ポートの SG ルール | [不要] | `allTraffic()` で対応済み |
| MEDIUM | CloudWatch Logs 権限 | [OK] 追加 | SSM ログ保存用 |

---

## 利点

1. **完全自動化**: `cdk deploy` だけで全環境が構築される
2. **ドリフト回避**: 手動設定が CDK に統合され、再デプロイ可能
3. **最小権限の原則**: S3 アクセスを特定バケットのみに制限
4. **セキュリティ強化**: S3 暗号化、パブリックアクセスブロック
5. **再現性**: インフラがコードで完全に定義される
6. **クリーンアップ**: `cdk destroy` でバケットも含めて削除される

---

## 注意事項

1. **既存のスタックへの適用**: 既存のスタック（nixl-efa-dev-east-1）にこの変更を適用する場合、CloudFormation が差分を検出して更新します。手動追加した IAM ポリシーは削除されますが、CDK で追加されたポリシーで置き換えられるため問題ありません。

2. **S3 バケット名の変更**: 新しくデプロイする場合、S3 バケット名はスタック名に基づいて自動生成されます。既存のスクリプトがハードコードされたバケット名に依存している場合は更新が必要です。

3. **autoDeleteObjects**: `autoDeleteObjects: true` を設定しているため、`cdk destroy` 実行時に S3 バケット内のすべてのファイルが削除されます。重要なログやスクリプトは別途バックアップしてください。

4. **EFA ドライバー**: Deep Learning AMI には EFA ドライバーがプリインストールされていますが、カスタム AMI を使用する場合は EFA インストーラーの実行が必要です。
