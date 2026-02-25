# G7e インスタンスと ML Capacity Block サポート - 実装レポート

## 概要

CDK スタックに以下の機能を追加しました：

1. **G7e インスタンスタイプのサポート**（NVIDIA RTX PRO 6000 Blackwell Server Edition GPU）
2. **ML Capacity Block のサポート**（キャパシティ予約購入）

## 実施日

2026-02-25

## 1. G7e インスタンスタイプのサポート

### G7e とは

G7e は AWS の最新 GPU インスタンスで、以下の特徴を持ちます：

- **GPU**: NVIDIA RTX PRO 6000 Blackwell Server Edition
- **GPU メモリ**: 各 GPU に 96 GB GDDR7（最大 768 GB）
- **性能**: G6e の 2.3 倍の推論性能
- **帯域幅**: EFA 1600 Gbps（4 倍高速）
- **用途**: AI 推論、空間コンピューティング、グラフィックス + AI

### サポートされている G7e インスタンスタイプ

| インスタンスタイプ | vCPUs | メモリ | GPU | GPU メモリ | EFA サポート | 推奨ボリュームサイズ |
|-------------------|-------|--------|-----|-----------|------------|---------------------|
| g7e.2xlarge | 8 | 64 GiB | 1 | 96 GiB | ✗ No | 200 GB |
| g7e.4xlarge | 16 | 128 GiB | 1 | 96 GiB | ✗ No | 200 GB |
| g7e.8xlarge | 32 | 256 GiB | 1 | 96 GiB | ✓ **Yes** | 300 GB |
| g7e.12xlarge | 48 | 512 GiB | 2 | 192 GiB | ✓ **Yes** | 300 GB |
| g7e.24xlarge | 96 | 1024 GiB | 4 | 384 GiB | ✓ **Yes** | 500 GB |
| g7e.48xlarge | 192 | 2048 GiB | 8 | 768 GiB | ✓ **Yes** | 1000 GB |

**重要**: EFA は g7e.8xlarge 以上でのみサポートされます。

### 実装内容

#### lib/nixl-efa-stack.ts

**EFA サポートインスタンスリストに追加**:
```typescript
const EFA_SUPPORTED_INSTANCE_TYPES = [
  // ... 既存のインスタンスタイプ
  // G7e series (NVIDIA RTX PRO 6000 Blackwell Server Edition)
  // Note: EFA supported on g7e.8xlarge and larger only
  "g7e.8xlarge",
  "g7e.12xlarge",
  "g7e.24xlarge",
  "g7e.48xlarge",
  // ...
];
```

**推奨ボリュームサイズに追加**:
```typescript
const RECOMMENDED_VOLUME_SIZES: Record<string, number> = {
  // ... 既存の設定
  "g7e.2xlarge": 200,
  "g7e.4xlarge": 200,
  "g7e.8xlarge": 300,
  "g7e.12xlarge": 300,
  "g7e.24xlarge": 500,
  "g7e.48xlarge": 1000,
  // ...
};
```

### 使用例

#### g7e.12xlarge でデプロイ

```bash
cdk deploy -c instanceType=g7e.12xlarge
```

#### g7e.48xlarge でカスタムボリュームサイズ

```bash
cdk deploy -c instanceType=g7e.48xlarge -c volumeSize=1500
```

## 2. ML Capacity Block のサポート

### ML Capacity Block とは

ML Capacity Block は、特定期間のキャパシティを予約購入できる AWS のサービスです。

**メリット**:
- 需要が高いインスタンス（P5、P4d など）のキャパシティを確実に確保
- 前払いで支払うため、コスト管理が容易
- 1 時間〜数日間の柔軟な期間設定

**適用インスタンス**:
- P5 (p5.48xlarge) - NVIDIA H100
- P4d (p4d.24xlarge) - NVIDIA A100
- P4de (p4de.24xlarge) - NVIDIA A100

### 実装内容

#### lib/nixl-efa-stack.ts

**プロパティの追加**:
```typescript
export interface NixlEfaStackProps extends StackProps {
  // ... 既存のプロパティ
  /** Use ML Capacity Block for purchasing capacity (optional). */
  useCapacityBlock?: boolean;

  /** Capacity Reservation ID for targeting a specific reservation (optional). */
  capacityReservationId?: string;
}
```

**CfnInstance への適用**:
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

#### bin/app.ts

**コンテキストからの取得**:
```typescript
const useCapacityBlock = app.node.tryGetContext("useCapacityBlock") === "true";
const capacityReservationId = app.node.tryGetContext("capacityReservationId");
```

**スタックへの渡し**:
```typescript
const nixlEfaStack = new NixlEfaStack(app, nixlEfaStackName, {
  // ... 既存のプロパティ
  useCapacityBlock,
  capacityReservationId: capacityReservationId || undefined,
  // ...
});
```

### 使用方法

#### ステップ 1: キャパシティブロックの検索

```bash
aws ec2 describe-capacity-block-offerings \
  --instance-type p5.48xlarge \
  --instance-count 2 \
  --capacity-duration-hours 24 \
  --start-date-range "$(date -u +%Y-%m-%dT%H: %M: %S.000Z)" \
  --end-date-range "$(date -u -d '+7 days' +%Y-%m-%dT%H: %M: %S.000Z)"
```

出力例:
```json
{
  "CapacityBlockOfferings": [
    {
      "CapacityBlockOfferingId": "cbo-xxxxxxxxxxxxx",
      "InstanceType": "p5.48xlarge",
      "AvailabilityZone": "us-east-1a",
      "InstanceCount": 2,
      "StartDate": "2026-02-26T10:00:00.000Z",
      "EndDate": "2026-02-27T10:00:00.000Z",
      "CapacityBlockDurationHours": 24,
      "UpfrontFee": "12345.67",
      "CurrencyCode": "USD"
    }
  ]
}
```

#### ステップ 2: キャパシティブロックの購入

```bash
aws ec2 purchase-capacity-block \
  --capacity-block-offering-id cbo-xxxxxxxxxxxxx \
  --instance-platform Linux/UNIX
```

出力例:
```json
{
  "CapacityReservation": {
    "CapacityReservationId": "cr-xxxxxxxxxxxxx",
    "InstanceType": "p5.48xlarge",
    "InstancePlatform": "Linux/UNIX",
    "AvailabilityZone": "us-east-1a",
    "State": "scheduled",
    "StartDate": "2026-02-26T10:00:00.000Z",
    "EndDate": "2026-02-27T10:00:00.000Z"
  }
}
```

#### ステップ 3: CDK でデプロイ

```bash
# Capacity Reservation ID を使用してデプロイ
cdk deploy \
  -c instanceType=p5.48xlarge \
  -c capacityReservationId=cr-xxxxxxxxxxxxx
```

または、useCapacityBlock フラグを使用：

```bash
# Capacity Block マーケットタイプを指定
cdk deploy \
  -c instanceType=p5.48xlarge \
  -c useCapacityBlock=true
```

### Parameter Store との統合

Capacity Reservation ID を Parameter Store に保存し、デプロイ時に自動取得できます：

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

### 参考実装

GitHub リポジトリに参考実装があります：

- [manage-capacity-block.sh](https://github.com/littlemex/samples/blob/main/aws-neuron/torch-neuronx/multi-framework-dlami-ubuntu24-cdk/scripts/manage-capacity-block.sh)
- [torch-neuron-stack.ts](https://github.com/littlemex/samples/blob/main/aws-neuron/torch-neuronx/multi-framework-dlami-ubuntu24-cdk/lib/torch-neuron-stack.ts)

## 検証

### ケース 1: G7e インスタンスでデプロイ

```bash
cdk deploy -c instanceType=g7e.12xlarge
```

**期待される結果**:
- 警告なし（EFA サポート、推奨ボリュームサイズが適用される）
- ボリュームサイズは 300 GB に自動設定

### ケース 2: EFA 非サポートの G7e インスタンス

```bash
cdk deploy -c instanceType=g7e.2xlarge
```

**期待される結果**:
- 警告: "Instance type g7e.2xlarge may not support EFA..."
- デプロイは続行される（警告のみ）

### ケース 3: Capacity Block を使用したデプロイ

```bash
cdk deploy \
  -c instanceType=p5.48xlarge \
  -c capacityReservationId=cr-xxxxxxxxxxxxx
```

**期待される結果**:
- CfnInstance に `capacityReservationSpecification` が設定される
- 指定した Capacity Reservation を使用してインスタンスが起動

### ケース 4: Capacity Block マーケットタイプでデプロイ

```bash
cdk deploy \
  -c instanceType=p5.48xlarge \
  -c useCapacityBlock=true
```

**期待される結果**:
- CfnInstance に `instanceMarketOptions: { marketType: "capacity-block" }` が設定される
- Capacity Block マーケットでインスタンスが起動

## 注意事項

### G7e インスタンス

1. **EFA サポート**: g7e.8xlarge 以上でのみ EFA がサポートされます
2. **リージョン**: すべてのリージョンで利用可能とは限りません
3. **Deep Learning AMI**: 現在使用している Deep Learning OSS Nvidia Driver AMI で動作します

### ML Capacity Block

1. **コスト**: 前払いで課金されます
2. **期間**: 1 時間〜数日間の予約が可能
3. **キャンセル**: キャンセル料が発生する可能性があります
4. **可用性**: すべてのリージョンで利用可能とは限りません
5. **予約時間**: 予約した時間内でのみインスタンスを起動できます

## 今後の改善提案

### 1. Capacity Block の自動管理スクリプト

参考実装の `manage-capacity-block.sh` を本リポジトリに追加：

```bash
# Capacity Block を検索
./scripts/manage-capacity-block.sh search p5.48xlarge 2 24

# Capacity Block を購入
./scripts/manage-capacity-block.sh purchase cbo-xxxxxxxxxxxxx

# Capacity Reservation をリスト
./scripts/manage-capacity-block.sh list
```

### 2. Parameter Store の統合

CDK スタックで Parameter Store から Capacity Reservation ID を自動取得：

```typescript
// Parameter Store から Reservation ID を取得
const reservationId = ssm.StringParameter.valueFromLookup(
  this,
  "/nixl-efa/capacity-reservation-id"
);

// CfnInstance で使用
capacityReservationId: reservationId || capacityReservationId
```

### 3. Capacity Block の状態チェック

デプロイ前に Capacity Reservation の状態を確認：

```typescript
// Capacity Reservation が active か確認
const reservationState = await checkReservationState(capacityReservationId);
if (reservationState !== "active") {
  throw new Error(`Capacity Reservation ${capacityReservationId} is not active`);
}
```

## まとめ

CDK スタックに以下の機能を追加しました：

- [OK] G7e インスタンスタイプのサポート（g7e.8xlarge, g7e.12xlarge, g7e.24xlarge, g7e.48xlarge）
- [OK] G7e の推奨ボリュームサイズの定義
- [OK] ML Capacity Block のサポート（useCapacityBlock, capacityReservationId）
- [OK] CfnInstance への instanceMarketOptions と capacityReservationSpecification の適用
- [OK] bin/app.ts でのコンテキスト取得
- [OK] README.md への詳細な説明とサンプルコード追加

これにより、最新の G7e インスタンスと ML Capacity Block を使用した柔軟なデプロイが可能になりました。

---

**作成者**: Claude Code (Sonnet 4.5)
**作成日**: 2026-02-25
**バージョン**: 1.0
