# インスタンスタイプサポート - 実装レポート

## 概要

CDK スタックに、複数の EFA 対応インスタンスタイプをサポートするための機能を追加しました。

## 実施日

2026-02-25

## 実装内容

### 1. EFA サポートインスタンスタイプの定義

**ファイル**: `lib/nixl-efa-stack.ts`

EFA をサポートするインスタンスタイプのリストを定数として定義しました：

```typescript
const EFA_SUPPORTED_INSTANCE_TYPES = [
  // G5 series (NVIDIA A10G)
  "g5.12xlarge", "g5.24xlarge", "g5.48xlarge",
  // G6 series (NVIDIA L4)
  "g6.12xlarge", "g6.24xlarge", "g6.48xlarge",
  // G6e series (NVIDIA L40S)
  "g6e.12xlarge", "g6e.24xlarge", "g6e.48xlarge",
  // P4d series (NVIDIA A100)
  "p4d.24xlarge",
  // P4de series (NVIDIA A100)
  "p4de.24xlarge",
  // P5 series (NVIDIA H100)
  "p5.48xlarge",
  // Trn1 series (AWS Trainium)
  "trn1.32xlarge", "trn1n.32xlarge",
  // Inf2 series (AWS Inferentia2)
  "inf2.24xlarge", "inf2.48xlarge",
];
```

### 2. 推奨ボリュームサイズの定義

インスタンスタイプごとの推奨ボリュームサイズを定義しました：

```typescript
const RECOMMENDED_VOLUME_SIZES: Record<string, number> = {
  "g5.12xlarge": 200,
  "g5.24xlarge": 300,
  "g5.48xlarge": 500,
  "g6.12xlarge": 200,
  "g6.24xlarge": 300,
  "g6.48xlarge": 500,
  "g6e.12xlarge": 200,
  "g6e.24xlarge": 300,
  "g6e.48xlarge": 500,
  "p4d.24xlarge": 500,
  "p4de.24xlarge": 500,
  "p5.48xlarge": 1000,
  "trn1.32xlarge": 500,
  "trn1n.32xlarge": 500,
  "inf2.24xlarge": 300,
  "inf2.48xlarge": 500,
};
```

### 3. インスタンスタイプの検証

コンストラクタ内でインスタンスタイプを検証し、EFA 非対応の場合は警告を表示します：

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

ボリュームサイズが指定されていない場合、インスタンスタイプに応じた推奨サイズを自動設定します：

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

### 5. ドキュメントの更新

**ファイル**: `README.md`

以下のセクションを追加しました：

- **サポートされているインスタンスタイプ**: EFA 対応インスタンスの一覧表
- **インスタンスタイプの指定方法**: 3 つの指定方法（コンテキスト、コード、cdk.json）
- **スタックの詳細設定**: オプションパラメータの表と設定例

## 使用方法

### 方法 1: コンテキストで指定（推奨）

```bash
# g5.24xlarge でデプロイ
cdk deploy -c instanceType=g5.24xlarge

# p5.48xlarge でデプロイ（ボリュームサイズも指定）
cdk deploy -c instanceType=p5.48xlarge -c volumeSize=1000

# g6e.12xlarge でデプロイ（ボリュームサイズは自動推奨）
cdk deploy -c instanceType=g6e.12xlarge
```

### 方法 2: bin/app.ts で指定

```typescript
const nixlEfaStack = new NixlEfaStack(app, nixlEfaStackName, {
  instanceType: "g6e.12xlarge",  // NVIDIA L40S
  volumeSize: 300,               // 推奨サイズ（省略可能）
  // ...
});
```

### 方法 3: cdk.json でデフォルト値を設定

```json
{
  "context": {
    "instanceType": "g5.12xlarge",
    "volumeSize": 200
  }
}
```

## 検証動作

### ケース 1: EFA 対応インスタンス + ボリュームサイズ未指定

```bash
cdk deploy -c instanceType=g5.24xlarge
```

**結果**:
- 警告なし
- ボリュームサイズは自動的に 300GB に設定される

### ケース 2: EFA 対応インスタンス + 小さいボリュームサイズ

```bash
cdk deploy -c instanceType=g5.24xlarge -c volumeSize=100
```

**結果**:
- 警告: "Volume size 100GB is smaller than recommended 300GB for g5.24xlarge"
- デプロイは続行される（警告のみ）

### ケース 3: EFA 非対応インスタンス

```bash
cdk deploy -c instanceType=g5.xlarge
```

**結果**:
- 警告: "Instance type g5.xlarge may not support EFA. Supported types: ..."
- デプロイは続行される（警告のみ）

### ケース 4: 未知のインスタンスタイプ + ボリュームサイズ未指定

```bash
cdk deploy -c instanceType=m5.large
```

**結果**:
- 警告: "Instance type m5.large may not support EFA. Supported types: ..."
- ボリュームサイズは 200GB（デフォルト）に設定される

## サポートされているインスタンスタイプ

### GPU インスタンス

| シリーズ | インスタンスタイプ | GPU | 推奨ボリュームサイズ | 用途 |
|----------|-------------------|-----|---------------------|------|
| G5 | g5.12xlarge | NVIDIA A10G × 4 | 200 GB | 開発・テスト |
| G5 | g5.24xlarge | NVIDIA A10G × 4 | 300 GB | 中規模推論 |
| G5 | g5.48xlarge | NVIDIA A10G × 8 | 500 GB | 大規模推論 |
| G6 | g6.12xlarge | NVIDIA L4 × 4 | 200 GB | 開発・テスト |
| G6 | g6.24xlarge | NVIDIA L4 × 4 | 300 GB | 中規模推論 |
| G6 | g6.48xlarge | NVIDIA L4 × 8 | 500 GB | 大規模推論 |
| G6e | g6e.12xlarge | NVIDIA L40S × 4 | 200 GB | AI ワークステーション |
| G6e | g6e.24xlarge | NVIDIA L40S × 4 | 300 GB | AI トレーニング |
| G6e | g6e.48xlarge | NVIDIA L40S × 8 | 500 GB | 大規模 AI |
| P4d | p4d.24xlarge | NVIDIA A100 × 8 | 500 GB | トレーニング |
| P4de | p4de.24xlarge | NVIDIA A100 × 8 | 500 GB | トレーニング |
| P5 | p5.48xlarge | NVIDIA H100 × 8 | 1000 GB | 最高性能 |

### AWS カスタムチップインスタンス

| シリーズ | インスタンスタイプ | チップ | 推奨ボリュームサイズ | 用途 |
|----------|-------------------|--------|---------------------|------|
| Trn1 | trn1.32xlarge | AWS Trainium × 16 | 500 GB | トレーニング |
| Trn1n | trn1n.32xlarge | AWS Trainium × 16 | 500 GB | トレーニング（高速 NW） |
| Inf2 | inf2.24xlarge | AWS Inferentia2 × 6 | 300 GB | 推論 |
| Inf2 | inf2.48xlarge | AWS Inferentia2 × 12 | 500 GB | 推論 |

## 注意事項

### 1. G7e は存在しない

G7e というインスタンスタイプは AWS には存在しません。以下のいずれかの間違いの可能性があります：

- **G6e**: NVIDIA L40S を搭載した AI ワークステーション向けインスタンス
- **G5**: NVIDIA A10G を搭載した汎用 GPU インスタンス
- **G6**: NVIDIA L4 を搭載した次世代 GPU インスタンス

### 2. EFA サポート状況の確認

EFA をサポートするインスタンスタイプは限られています。以下のドキュメントで最新情報を確認してください：

- [Elastic Fabric Adapter - Supported instance types](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html#efa-instance-types)

### 3. リージョンによるインスタンスタイプの可用性

すべてのインスタンスタイプがすべてのリージョンで利用可能とは限りません。特に以下のインスタンスはリージョンが制限されています：

- **P5** (p5.48xlarge): us-east-1, us-west-2 など限定的
- **P4de** (p4de.24xlarge): 一部リージョンのみ
- **Trn1n** (trn1n.32xlarge): 一部リージョンのみ

デプロイ前に、対象リージョンでインスタンスタイプが利用可能か確認してください：

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters Name=instance-type,Values=p5.48xlarge \
  --region us-east-1
```

### 4. Deep Learning AMI の互換性

現在の実装では、Deep Learning OSS Nvidia Driver AMI を使用しています。この AMI は以下のインスタンスタイプに対応しています：

- GPU インスタンス: G5, G6, G6e, P4d, P4de, P5
- AWS カスタムチップ: Trn1, Trn1n, Inf2（別の AMI が必要な場合があります）

Trn1 や Inf2 を使用する場合は、専用の Deep Learning AMI（Neuron SDK 付き）を使用することを推奨します。

## 今後の改善提案

### 1. AMI の自動選択

インスタンスタイプに応じて適切な AMI を自動選択する機能を追加：

```typescript
const ami = getAppropriateAmi(instanceType);

function getAppropriateAmi(instanceType: string): ec2.IMachineImage {
  if (instanceType.startsWith("trn1") || instanceType.startsWith("inf2")) {
    // Deep Learning AMI Neuron
    return ec2.MachineImage.lookup({
      name: "Deep Learning AMI Neuron PyTorch * (Ubuntu 22.04) *",
      owners: ["amazon"],
    });
  } else {
    // Deep Learning OSS Nvidia Driver AMI
    return ec2.MachineImage.lookup({
      name: "Deep Learning OSS Nvidia Driver AMI GPU PyTorch * (Ubuntu 22.04) *",
      owners: ["amazon"],
    });
  }
}
```

### 2. リージョンでの可用性チェック

デプロイ前にインスタンスタイプがリージョンで利用可能かチェック：

```typescript
async function validateInstanceTypeAvailability(
  instanceType: string,
  region: string
): Promise<boolean> {
  // AWS SDK を使用してインスタンスタイプの可用性をチェック
}
```

### 3. コスト見積もり

インスタンスタイプとボリュームサイズに基づくコスト見積もりを表示：

```typescript
function estimateMonthlyCost(instanceType: string, volumeSize: number): number {
  // AWS Pricing API を使用してコストを見積もり
}
```

## まとめ

CDK スタックに以下の機能を追加しました：

- [OK] EFA サポートインスタンスタイプのリスト定義
- [OK] インスタンスタイプの検証（警告表示）
- [OK] ボリュームサイズの自動推奨
- [OK] ボリュームサイズの検証（警告表示）
- [OK] 複数の指定方法のサポート（コンテキスト、コード、cdk.json）
- [OK] ドキュメントの充実（README に詳細な表と例を追加）

これにより、g5, g6, g6e, p4d, p4de, p5, trn1, trn1n, inf2 など、さまざまなインスタンスタイプで柔軟にデプロイできるようになりました。

---

**作成者**: Claude Code (Sonnet 4.5)
**作成日**: 2026-02-25
**バージョン**: 1.0
