# CDK Stack Improvements

## 手動設定の自動化

現在、以下の設定が手動で実施されています：

1. **S3 バケットの作成** - スクリプト配布用
2. **IAM ロールへの S3 アクセス権限追加** - スクリプトダウンロード用
3. **Instance ID の取得** - SSM Send Command で必要

これらを CDK スタックに追加します。

## 修正内容

### 1. S3 バケットの追加

```typescript
// lib/nixl-efa-stack.ts に追加

import * as s3 from "aws-cdk-lib/aws-s3";
import * as s3deploy from "aws-cdk-lib/aws-s3-deployment";

// IAM ロールの定義後に追加
// --- S3 Bucket for Scripts ---
const scriptsBucket = new s3.Bucket(this, "ScriptsBucket", {
  removalPolicy: cdk.RemovalPolicy.DESTROY,
  autoDeleteObjects: true,
  versioned: false,
});

// Grant read access to EC2 instances
scriptsBucket.grantRead(ec2Role);

// Optionally, deploy initial scripts from local directory
// const scriptsDeployment = new s3deploy.BucketDeployment(this, "DeployScripts", {
//   sources: [s3deploy.Source.asset("../setup")],
//   destinationBucket: scriptsBucket,
//   destinationKeyPrefix: "setup/",
// });
```

### 2. IAM ロールへの S3 アクセス権限追加

```typescript
// lib/nixl-efa-stack.ts の IAM Role 定義部分を修正

const ec2Role = new iam.Role(this, "NixlEfaInstanceRole", {
  assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
  description: "IAM role for NIXL EFA EC2 instances with SSM access",
  managedPolicies: [
    iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonSSMManagedInstanceCore"),
    iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonS3ReadOnlyAccess"), // 追加
  ],
});
```

**注意**: `AmazonS3ReadOnlyAccess` は広範な権限を付与します。本番環境では、特定のバケットのみにアクセスを制限することを推奨します：

```typescript
// より厳密な権限設定（推奨）
ec2Role.addToPolicy(
  new iam.PolicyStatement({
    actions: ["s3: GetObject", "s3: ListBucket"],
    resources: [
      scriptsBucket.bucketArn,
      `${scriptsBucket.bucketArn}/*`,
    ],
  })
);
```

### 3. Instance ID の出力追加

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

new CfnOutput(this, "ScriptsBucketName", {
  value: scriptsBucket.bucketName,
  description: "S3 bucket for deployment scripts",
  exportName: `${this.stackName}-ScriptsBucketName`,
});
```

## 完全な修正ファイル

以下、完全な修正版の `lib/nixl-efa-stack.ts` の主要部分：

```typescript
import * as s3 from "aws-cdk-lib/aws-s3";

// ... (既存の import)

export class NixlEfaStack extends Stack {
  public readonly node1: ec2.CfnInstance;
  public readonly node2: ec2.CfnInstance;
  public readonly securityGroup: ec2.ISecurityGroup;
  public readonly placementGroup: ec2.CfnPlacementGroup;
  public readonly vpc: ec2.IVpc;
  public readonly scriptsBucket: s3.Bucket; // 追加

  constructor(scope: Construct, id: string, props: NixlEfaStackProps) {
    super(scope, id, props);

    // ... (既存の VPC、AMI、SecurityGroup、PlacementGroup 設定)

    // --- S3 Bucket for Scripts ---
    this.scriptsBucket = new s3.Bucket(this, "ScriptsBucket", {
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
      versioned: false,
    });

    // --- IAM Role for EC2 with SSM and S3 ---
    const ec2Role = new iam.Role(this, "NixlEfaInstanceRole", {
      assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
      description: "IAM role for NIXL EFA EC2 instances with SSM and S3 access",
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonSSMManagedInstanceCore"),
      ],
    });

    // Grant read access to scripts bucket
    this.scriptsBucket.grantRead(ec2Role);

    // ... (既存の MLflow 権限設定)

    // ... (既存のインスタンス作成)

    // --- Outputs ---
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

    // ... (既存の他の Outputs)
  }
}
```

## デプロイ後の使い方

### スクリプトのアップロード

```bash
# スタックの出力からバケット名を取得
BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name nixl-efa-dev-east-1 \
  --query 'Stacks[0].Outputs[?OutputKey==`ScriptsBucketName`].OutputValue' \
  --output text)

# スクリプトをアップロード
aws s3 cp setup/task_runner.sh s3://$BUCKET_NAME/
aws s3 cp setup/tasks/ s3://$BUCKET_NAME/tasks/ --recursive
```

### SSM Run Command での実行

```bash
# Instance ID を取得
NODE1_INSTANCE_ID=$(aws cloudformation describe-stacks \
  --stack-name nixl-efa-dev-east-1 \
  --query 'Stacks[0].Outputs[?OutputKey==`Node1InstanceId`].OutputValue' \
  --output text)

# スクリプトを実行
aws ssm send-command \
  --instance-ids "$NODE1_INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[
    'cd /tmp',
    'aws s3 cp s3://$BUCKET_NAME/task_runner.sh . && chmod +x task_runner.sh',
    'aws s3 cp s3://$BUCKET_NAME/tasks/full-verification.json .',
    'bash task_runner.sh full-verification.json'
  ]"
```

## 利点

1. **完全自動化**: 手動で S3 バケットを作成する必要がなくなる
2. **最小権限の原則**: 特定のバケットのみへのアクセスに制限可能
3. **再現性**: `cdk deploy` だけで完全な環境が構築される
4. **クリーンアップ**: `cdk destroy` でバケットも含めてすべて削除される

## 注意事項

1. `AmazonS3ReadOnlyAccess` は広範な権限です。本番環境では、特定のバケットのみにアクセスを制限してください。
2. `autoDeleteObjects: true` を設定しているため、スタック削除時にバケットも削除されます。
3. スクリプトのデプロイは手動または CI/CD パイプラインで実施する必要があります。
