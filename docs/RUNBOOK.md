# NIXL LIBFABRIC Backend Fix - Runbook

**最終更新**: 2026-03-08

この Runbook は、NIXL LIBFABRIC Backend Deletion 問題の修正を含む vLLM Disaggregated Inference システムの運用手順を提供します。

## 目次

- [概要](#概要)
- [デプロイ手順](#デプロイ手順)
- [監視とアラート](#監視とアラート)
- [一般的な問題と修正](#一般的な問題と修正)
- [ロールバック手順](#ロールバック手順)
- [緊急対応手順](#緊急対応手順)

---

## 概要

### システム構成

```
┌─────────────────┐         ┌─────────────────┐
│   Node1         │         │   Node2         │
│   (Producer)    │◄───────►│   (Consumer)    │
│                 │   EFA   │                 │
│  vLLM Producer  │  TCP    │  vLLM Consumer  │
│  NIXL LIBFABRIC │         │  NIXL LIBFABRIC │
│  RTX PRO 6000   │         │  RTX PRO 6000   │
└─────────────────┘         └─────────────────┘
```

### 主要コンポーネント

| コンポーネント | 説明 | ポート |
|-------------|-----|-------|
| vLLM Producer | Prefill 処理を担当 | 8100 |
| vLLM Consumer | Decode 処理を担当 | 8200 |
| Proxy Server | リクエストルーティング（オプション） | 8000 |
| NIXL Backend | 通信バックエンド（LIBFABRIC/UCX/TCP） | - |

### インフラストラクチャ

- **Cloud**: AWS us-west-2 (us-west-2c)
- **Instance Type**: g7e.12xlarge (RTX PRO 6000 Blackwell 96GB x2)
- **Network**: EFA (Elastic Fabric Adapter) + TCP fallback
- **S3 Bucket**: `phase3-nixl-efa-dev-west-2-scriptsbucket40feb4b1-ougyvcmrbyjj`
- **SSH Key**: `/home/coder/.ssh/phase3_key`

---

## デプロイ手順

### 事前準備

#### 1. 環境変数の設定

```bash
cd /home/coder/phase2/disaggregated-inference-with-nixl-over-aws-efa/setup
cp .env.example .env
vim .env  # 実際の値に編集
source .env
```

**必須の環境変数チェックリスト: **
- [ ] `NODE1_PUBLIC_IP` - Node1 Public IP
- [ ] `NODE2_PUBLIC_IP` - Node2 Public IP
- [ ] `NODE1_PRIVATE_IP` - Node1 Private IP
- [ ] `NODE2_PRIVATE_IP` - Node2 Private IP
- [ ] `SSH_KEY` - SSH 秘密鍵パス
- [ ] `S3_BUCKET` - S3 バケット名
- [ ] `MODEL_NAME` - vLLM モデル名
- [ ] `ENGINE_ID` - Engine ID（ユニークな識別子）
- [ ] `AWS_REGION` - AWS リージョン（us-west-2）

#### 2. インスタンスの起動確認

```bash
# Node1 の状態確認
aws ec2 describe-instances \
  --region $AWS_REGION \
  --filters "Name=tag: Phase,Values=phase3" "Name=tag: Node,Values=Node1" \
  --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress,PrivateIpAddress]' \
  --output table

# Node2 の状態確認
aws ec2 describe-instances \
  --region $AWS_REGION \
  --filters "Name=tag: Phase,Values=phase3" "Name=tag: Node,Values=Node2" \
  --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress,PrivateIpAddress]' \
  --output table
```

**期待される出力: **
```
----------------
|  State  | PublicIP       | PrivateIP      |
|---------|----------------|----------------|
| running | 44.247.215.228 | 172.31.2.221   |
----------------
```

### 標準デプロイ（完全な再現ワークフロー）

#### オプション A: 統合タスクによる自動デプロイ

```bash
cd /home/coder/phase2/disaggregated-inference-with-nixl-over-aws-efa/setup
source .env

# 完全な再現ワークフロー（ビルド → S3 デプロイ → ノードインストール → 検証）
bash task_runner.sh tasks/fix-backend-deletion.json
```

**実行時間: ** 約 5-10 分

**実行内容: **
1. NIXL ソースの修正確認（3 パッチ）
2. ninja によるビルド
3. S3 への SO ファイルアップロード
4. 両ノード（Node1, Node2）への SSH 経由インストール
5. vLLM サービスの再起動
6. Backend 作成の検証
7. API 疎通テスト

#### オプション B: 段階的デプロイ

```bash
cd /home/coder/phase3/group1
source /home/coder/phase2/disaggregated-inference-with-nixl-over-aws-efa/setup/.env

# Step 1: NIXL プラグインのビルド（冪等性保証、10 ステップ）
bash task_runner.sh tasks/build-nixl-plugin.json

# Step 2: S3 へのプラグインアップロード（4 ステップ）
bash task_runner.sh tasks/deploy-plugin-to-s3.json

# Step 3: 両ノードへのプラグインインストール（9 ステップ）
bash task_runner.sh tasks/install-plugin-on-nodes.json
```

**各ステップの所要時間: **
- Step 1 (ビルド): 約 2-3 分
- Step 2 (S3 デプロイ): 約 30 秒
- Step 3 (ノードインストール): 約 1-2 分

### デプロイ後の検証

#### 1. ビルドアーティファクトの検証

```bash
# ローカルでの確認
ls -lh /home/coder/nixl/build/src/plugins/libfabric/libplugin_LIBFABRIC.so
md5sum /home/coder/nixl/build/src/plugins/libfabric/libplugin_LIBFABRIC.so
```

**期待される出力: **
```
-rw-r--r-- 1 coder coder 500K Mar 8 12:00 libplugin_LIBFABRIC.so
a1b2c3d4e5f6... libplugin_LIBFABRIC.so
```

#### 2. S3 デプロイの検証

```bash
# S3 にアップロードされたファイルを確認
aws s3 ls s3://$S3_BUCKET/tasks/phase3/ --recursive | grep libplugin_LIBFABRIC.so | tail -5
```

**期待される出力: **
```
2026-03-08 12:00:00  512000 tasks/phase3/20260308_120000/libplugin_LIBFABRIC.so
```

#### 3. ノードインストールの検証

```bash
# Node1 での確認
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "\
  ls -lh /usr/local/lib/nixl/plugins/libfabric/libplugin_LIBFABRIC.so && \
  md5sum /usr/local/lib/nixl/plugins/libfabric/libplugin_LIBFABRIC.so"

# Node2 での確認
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "\
  ls -lh /usr/local/lib/nixl/plugins/libfabric/libplugin_LIBFABRIC.so && \
  md5sum /usr/local/lib/nixl/plugins/libfabric/libplugin_LIBFABRIC.so"
```

**期待される出力（両ノード同じ MD5）: **
```
-rwxr-xr-x 1 root root 500K Mar 8 12:00 libplugin_LIBFABRIC.so
a1b2c3d4e5f6... libplugin_LIBFABRIC.so
```

#### 4. Backend 作成の検証

```bash
# Producer (Node1) での Backend 作成確認
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "\
  journalctl -u vllm-producer -n 100 --no-pager | grep 'Backend LIBFABRIC'"

# Consumer (Node2) での Backend 作成確認
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "\
  journalctl -u vllm-consumer -n 100 --no-pager | grep 'Backend LIBFABRIC'"
```

**期待される出力: **
```
Backend LIBFABRIC was instantiated (rank: 0, device_list: cuda:0)
```

**NG パターン（即座に削除）: **
```
[ERROR] NIXL_ERR_INVALID_PARAM when calling GetConnInfo()
Backend deletion detected
```

#### 5. API テスト

```bash
# Consumer (Node2) にリクエストを送信
curl -X POST http://$NODE2_PUBLIC_IP:$CONSUMER_PORT/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'$MODEL_NAME'",
    "prompt": "Hello, world!",
    "max_tokens": 10
  }' | jq .
```

**期待される出力: **
```json
{
  "id": "cmpl-...",
  "object": "text_completion",
  "created": 1678886400,
  "model": "Qwen/Qwen2.5-32B-Instruct",
  "choices": [
    {
      "text": " I am a language model",
      "index": 0,
      "finish_reason": "length"
    }
  ]
}
```

---

## 監視とアラート

### ログの場所

| ログ種別 | Node1 (Producer) | Node2 (Consumer) |
|---------|------------------|------------------|
| vLLM ログ | `journalctl -u vllm-producer` | `journalctl -u vllm-consumer` |
| NIXL ログ | 上記に含まれる | 上記に含まれる |
| System ログ | `/var/log/syslog` | `/var/log/syslog` |

### 重要なログパターン

#### 正常な Backend 作成

```bash
# 両ノードで以下のログが出力されることを確認
grep "Backend LIBFABRIC was instantiated" <ログファイル>
```

#### Backend 削除エラー（修正前）

```bash
# このパターンが出現した場合、修正が適用されていない
grep "NIXL_ERR_INVALID_PARAM" <ログファイル>
grep "Backend deletion detected" <ログファイル>
```

#### メモリエラー

```bash
# CUDA OOM エラー
grep "CUDA out of memory" <ログファイル>

# kv_buffer_device 設定の確認（cpu であるべき）
grep "kv_buffer_device" <ログファイル>
```

### 定期監視コマンド

```bash
# スクリプトとして保存: /home/coder/scripts/monitor.sh

#!/bin/bash
source /home/coder/phase2/disaggregated-inference-with-nixl-over-aws-efa/setup/.env

echo "[INFO] Checking Node1 (Producer)..."
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "\
  systemctl is-active vllm-producer && \
  journalctl -u vllm-producer -n 10 --no-pager"

echo ""
echo "[INFO] Checking Node2 (Consumer)..."
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "\
  systemctl is-active vllm-consumer && \
  journalctl -u vllm-consumer -n 10 --no-pager"

echo ""
echo "[INFO] API Health Check..."
curl -s http://$NODE2_PUBLIC_IP:$CONSUMER_PORT/health | jq .
```

**実行: **
```bash
chmod +x /home/coder/scripts/monitor.sh
watch -n 60 /home/coder/scripts/monitor.sh  # 60 秒ごとに監視
```

---

## 一般的な問題と修正

### 問題 1: Backend が即座に削除される

**症状: **
```
[ERROR] NIXL_ERR_INVALID_PARAM when calling GetConnInfo()
Backend deletion detected
```

**原因: **
- NIXL LIBFABRIC plugin の修正が適用されていない
- 古いプラグインが使用されている

**修正手順: **

```bash
# 1. ソースコードの修正を確認
cd /home/coder/nixl
grep -n "std::string conn_info_" src/plugins/libfabric/libfabric_backend.h
grep -n "serializeConnectionInfo.*dest.*conn_info_" src/plugins/libfabric/libfabric_backend.cpp
grep -A5 "getConnInfo.*const" src/plugins/libfabric/libfabric_backend.cpp | grep "str = conn_info_"

# すべて一致すれば修正済み

# 2. 再ビルドとデプロイ
cd /home/coder/phase2/disaggregated-inference-with-nixl-over-aws-efa/setup
source .env
bash task_runner.sh tasks/fix-backend-deletion.json

# 3. サービスの再起動
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "sudo systemctl restart vllm-producer"
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "sudo systemctl restart vllm-consumer"

# 4. 検証
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "journalctl -u vllm-producer -n 50 | grep 'Backend LIBFABRIC'"
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "journalctl -u vllm-consumer -n 50 | grep 'Backend LIBFABRIC'"
```

---

### 問題 2: CUDA Out of Memory (OOM)

**症状: **
```
CUDA out of memory. Tried to allocate XX GB
```

**原因: **
- `kv_buffer_device` が `cuda` に設定されている（`cpu` であるべき）

**修正手順: **

```bash
# 1. 現在の設定を確認
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "cat /etc/systemd/system/vllm-producer.service | grep kv_buffer_device"
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "cat /etc/systemd/system/vllm-consumer.service | grep kv_buffer_device"

# 2. cpu に修正（Node1 Producer）
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "sudo sed -i 's/--kv-buffer-device=cuda/--kv-buffer-device=cpu/g' /etc/systemd/system/vllm-producer.service"

# 3. cpu に修正（Node2 Consumer）
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "sudo sed -i 's/--kv-buffer-device=cuda/--kv-buffer-device=cpu/g' /etc/systemd/system/vllm-consumer.service"

# 4. systemd リロードと再起動
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "sudo systemctl daemon-reload && sudo systemctl restart vllm-producer"
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "sudo systemctl daemon-reload && sudo systemctl restart vllm-consumer"

# 5. 検証
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "journalctl -u vllm-producer -n 100 | grep kv_buffer_device"
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "journalctl -u vllm-consumer -n 100 | grep kv_buffer_device"
```

---

### 問題 3: SSH 接続タイムアウト

**症状: **
```
ssh: connect to host 44.247.215.228 port 22: Connection timed out
```

**原因: **
- セキュリティグループで SSH (port 22) が開放されていない
- インスタンスが停止している

**修正手順: **

```bash
# 1. インスタンスの状態を確認
aws ec2 describe-instances \
  --region $AWS_REGION \
  --filters "Name=tag: Phase,Values=phase3" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name,PublicIpAddress]' \
  --output table

# 2. 停止している場合は起動
aws ec2 start-instances --instance-ids <INSTANCE_ID> --region $AWS_REGION

# 3. セキュリティグループを確認
aws ec2 describe-security-groups \
  --region $AWS_REGION \
  --filters "Name=tag: Phase,Values=phase3" \
  --query 'SecurityGroups[*].[GroupId,GroupName]' \
  --output table

# 4. セキュリティグループのインバウンドルールを確認
aws ec2 describe-security-groups \
  --region $AWS_REGION \
  --group-ids <SECURITY_GROUP_ID> \
  --query 'SecurityGroups[0].IpPermissions' \
  --output table

# SSH (port 22) が開放されているか確認
```

---

### 問題 4: S3 アップロード権限エラー

**症状: **
```
An error occurred (AccessDenied) when calling the PutObject operation
```

**原因: **
- AWS credentials が設定されていない
- S3 バケットへの書き込み権限がない

**修正手順: **

```bash
# 1. AWS credentials を確認
aws sts get-caller-identity

# 出力例:
# {
#     "UserId": "AIDAJ...",
#     "Account": "123456789012",
#     "Arn": "arn: aws: iam::123456789012: user/your-user"
# }

# 2. S3 バケットへのアクセス権限を確認
aws s3 ls s3://$S3_BUCKET/

# 3. 権限がない場合、IAM ポリシーを確認
aws iam get-user-policy --user-name <your-user> --policy-name <policy-name>

# 4. 必要に応じて権限を付与（管理者に依頼）
# 必要な権限:
# - s3: PutObject
# - s3: GetObject
# - s3: ListBucket
```

---

### 問題 5: API リクエストが 503 エラー

**症状: **
```
curl: (7) Failed to connect to 34.217.117.205 port 8200: Connection refused
```

**原因: **
- vLLM Consumer が起動していない
- Backend 作成に失敗している

**修正手順: **

```bash
# 1. Consumer (Node2) のサービス状態を確認
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "systemctl status vllm-consumer"

# 2. 起動していない場合は起動
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "sudo systemctl start vllm-consumer"

# 3. ログを確認
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "journalctl -u vllm-consumer -n 100 --no-pager"

# 4. Backend 作成エラーがある場合は「問題 1」を参照
```

---

## ロールバック手順

### シナリオ: 新しいプラグインで Backend 作成に失敗

**ロールバック対象: **
- NIXL LIBFABRIC plugin (`libplugin_LIBFABRIC.so`)

**手順: **

#### 1. バックアップからの復元

```bash
# Node1 (Producer) でバックアップから復元
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "\
  sudo cp /usr/local/lib/nixl/plugins/libfabric/libplugin_LIBFABRIC.so.backup \
         /usr/local/lib/nixl/plugins/libfabric/libplugin_LIBFABRIC.so && \
  sudo systemctl restart vllm-producer"

# Node2 (Consumer) でバックアップから復元
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "\
  sudo cp /usr/local/lib/nixl/plugins/libfabric/libplugin_LIBFABRIC.so.backup \
         /usr/local/lib/nixl/plugins/libfabric/libplugin_LIBFABRIC.so && \
  sudo systemctl restart vllm-consumer"
```

#### 2. 検証

```bash
# Backend 作成を確認
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "journalctl -u vllm-producer -n 50 | grep Backend"
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "journalctl -u vllm-consumer -n 50 | grep Backend"

# API 疎通テスト
curl -X POST http://$NODE2_PUBLIC_IP:$CONSUMER_PORT/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "'$MODEL_NAME'", "prompt": "Test", "max_tokens": 5}'
```

#### 3. ロールバック後の対応

```bash
# 原因調査のため、失敗したプラグインを保存
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "\
  sudo cp /usr/local/lib/nixl/plugins/libfabric/libplugin_LIBFABRIC.so \
         /tmp/libplugin_LIBFABRIC_failed_$(date +%Y%m%d_%H%M%S).so"

# ログを保存
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "\
  journalctl -u vllm-producer -n 1000 > /tmp/producer_logs_$(date +%Y%m%d_%H%M%S).log"
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "\
  journalctl -u vllm-consumer -n 1000 > /tmp/consumer_logs_$(date +%Y%m%d_%H%M%S).log"
```

---

## 緊急対応手順

### 緊急度: HIGH - Backend 作成に完全に失敗

**症状: **
- 両ノードで Backend が作成されない
- API リクエストがすべて失敗

**即座に実行すべき手順: **

#### 1. サービスの停止

```bash
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "sudo systemctl stop vllm-producer"
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "sudo systemctl stop vllm-consumer"
```

#### 2. バックアップからの復元（ロールバック）

上記「ロールバック手順」を参照

#### 3. サービスの再起動

```bash
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "sudo systemctl start vllm-producer"
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "sudo systemctl start vllm-consumer"
```

#### 4. 健全性確認

```bash
# Backend 作成確認
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "journalctl -u vllm-producer -n 50 | grep Backend"
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "journalctl -u vllm-consumer -n 50 | grep Backend"

# API 疎通テスト
curl -X POST http://$NODE2_PUBLIC_IP:$CONSUMER_PORT/health
```

#### 5. インシデントレポート作成

```bash
# ログ収集
mkdir -p /tmp/incident_$(date +%Y%m%d_%H%M%S)
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "journalctl -u vllm-producer -n 1000" > /tmp/incident_*/producer.log
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "journalctl -u vllm-consumer -n 1000" > /tmp/incident_*/consumer.log

# 環境情報
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "uname -a; nvidia-smi; ls -lh /usr/local/lib/nixl/plugins/libfabric/" > /tmp/incident_*/node1_env.txt
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "uname -a; nvidia-smi; ls -lh /usr/local/lib/nixl/plugins/libfabric/" > /tmp/incident_*/node2_env.txt
```

---

## 参考資料

### 関連ドキュメント

- [CONTRIB.md](./CONTRIB.md) - 開発ワークフロー、環境セットアップ
- [REPRODUCTION_DESIGN.md](/home/coder/phase3/group1/setup/REPRODUCTION_DESIGN.md) - 再現システムの設計
- [ROOT_CAUSE_BACKEND_DELETION_2026-03-08.md](/home/coder/phase3/group1/ROOT_CAUSE_BACKEND_DELETION_2026-03-08.md) - 根本原因分析

### 連絡先

**緊急時の連絡先: **
- インフラチーム: [連絡先情報]
- オンコールエンジニア: [連絡先情報]

**Issue トラッキング: **
- GitHub Issues: https://github.com/your-org/disaggregated-inference-with-nixl-over-aws-efa/issues

---

**この Runbook は定期的に更新してください。最終更新: 2026-03-08**
