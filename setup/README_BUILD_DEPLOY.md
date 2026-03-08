# NIXL LIBFABRIC Plugin - 完全自動ビルド＆デプロイ

**最終更新**: 2026-03-08

このガイドは、GitHub から NIXL をクローンしてビルド、S3 経由で EC2 ノードにデプロイする完全自動化されたワークフローを説明します。

---

## クイックスタート（3 ステップ）

### 1. 環境変数の設定

```bash
cd /home/coder/phase2/disaggregated-inference-with-nixl-over-aws-efa/setup
cp .env.example .env
vim .env  # NODE1_PUBLIC_IP, NODE2_PUBLIC_IP, SSH_KEY, S3_BUCKET を設定
source .env
```

### 2. 完全自動デプロイの実行

```bash
bash task_runner.sh tasks/build-deploy-from-github.json
```

### 3. vLLM サービスの再起動

```bash
# Node1 (Producer)
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "sudo systemctl restart vllm-producer"

# Node2 (Consumer)
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "sudo systemctl restart vllm-consumer"
```

**所要時間**: 約 5-10 分

---

## 何が行われるか？

### フロー図

```
┌─────────────────────────────────────────────────────────────┐
│  Step 1: ローカルビルド (管理マシン)                           │
│                                                              │
│  1. git clone git@github.com: littlemex/nixl.git            │
│     → /tmp/nixl-build/                                     │
│                                                              │
│  2. meson setup build                                       │
│                                                              │
│  3. ninja src/plugins/libfabric/libplugin_LIBFABRIC.so    │
│                                                              │
│  4. 検証: MD5, シンボル, ELF フォーマット                     │
│                                                              │
└──────────────────┬──────────────────────────────────────────┘
                   │
                   ↓
┌─────────────────────────────────────────────────────────────┐
│  Step 2: S3 アップロード                                      │
│                                                              │
│  aws s3 cp libplugin_LIBFABRIC.so                          │
│    s3://bucket/plugins/                                    │
│                                                              │
└──────────────────┬──────────────────────────────────────────┘
                   │
                   ↓
┌─────────────────────────────────────────────────────────────┐
│  Step 3: EC2 ノードへデプロイ (SSH 経由)                      │
│                                                              │
│  両ノード (Node1, Node2) で:                                 │
│                                                              │
│  1. aws s3 cp s3://bucket/plugins/libplugin_LIBFABRIC.so  │
│       /tmp/                                                │
│                                                              │
│  2. バックアップ作成                                          │
│     cp libplugin_LIBFABRIC.so                              │
│        libplugin_LIBFABRIC.so.original                     │
│                                                              │
│  3. pip 版プラグインを上書き                                  │
│     cp /tmp/libplugin_LIBFABRIC.so                         │
│        ~/.local/.../nixl/_lib/                             │
│                                                              │
│  4. 検証: NIXL が LIBFABRIC plugin をロードできるか           │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 実行されるタスク（13 ステップ）

| ID | タスク | 説明 | 所要時間 |
|----|--------|-----|----------|
| 01 | check-prerequisites | git, ninja, g++, meson, aws CLI の確認 | 5 秒 |
| 02 | clone-or-update-nixl | GitHub から clone または git pull | 30 秒 |
| 03 | verify-backend-fix | ソースコードに修正が含まれているか確認 | 5 秒 |
| 04 | setup-meson-build | meson setup build（初回のみ） | 30 秒 |
| 05 | build-plugin | ninja でビルド | 2-3 分 |
| 06 | verify-build-artifact | サイズ、MD5、ELF フォーマット検証 | 5 秒 |
| 07 | verify-symbols | シンボル検証 | 5 秒 |
| 08 | upload-to-s3 | S3 へアップロード | 30 秒 |
| 09 | check-node-connectivity | SSH 疎通確認 | 10 秒 |
| 10 | deploy-to-node1 | Node1 へデプロイ | 30 秒 |
| 11 | deploy-to-node2 | Node2 へデプロイ | 30 秒 |
| 12 | verify-deployment | 両ノードの MD5 一致確認 | 10 秒 |
| 13 | summary | デプロイサマリー表示 | 5 秒 |

---

## 前提条件

### ローカルマシン（管理マシン）

```bash
# 必須ソフトウェア
- git
- ninja (apt-get install ninja-build)
- g++ (apt-get install build-essential)
- meson (pip install meson)
- aws CLI

# 確認コマンド
git --version
ninja --version
g++ --version
meson --version
aws --version
```

### EC2 ノード

```bash
# 必須
- Python 3.10+
- vLLM v0.17.0
- NIXL (pip install nixl[cu12])
- AWS CLI (S3 アクセス権限)
- SSH アクセス可能
```

---

## 環境変数

`.env.example` から `.env` を作成して以下を設定：

| 変数名 | 説明 | 例 |
|--------|-----|-----|
| `NODE1_PUBLIC_IP` | Node1 (Producer) の Public IP | `44.247.215.228` |
| `NODE2_PUBLIC_IP` | Node2 (Consumer) の Public IP | `34.217.117.205` |
| `SSH_KEY` | SSH 秘密鍵のパス | `/home/coder/.ssh/phase3_key` |
| `S3_BUCKET` | S3 バケット名 | `phase3-nixl-efa-dev-west-2-...` |
| `AWS_REGION` | AWS リージョン | `us-west-2` |

---

## 冪等性（何度実行しても安全）

このタスクは冪等性を持つように設計されています：

### Git Clone
- 初回: `git clone`
- 2 回目以降: `git pull` で更新

### Meson Setup
- 初回: `meson setup build`
- 2 回目以降: スキップ（`build.ninja` 存在確認）

### プラグインバックアップ
- 初回: `.original` ファイル作成
- 2 回目以降: 既存の `.original` を保持

### S3 アップロード
- 常に最新版で上書き

### EC2 デプロイ
- 常に最新版で上書き（バックアップ保持）

---

## 個別タスクの実行

### ビルドのみ

```bash
bash task_runner.sh tasks/build-deploy-from-github.json --to 07-verify-symbols
```

### S3 アップロードから

```bash
bash task_runner.sh tasks/build-deploy-from-github.json --from 08-upload-to-s3
```

### デプロイのみ（ビルド済み＆S3 アップロード済みの場合）

```bash
bash task_runner.sh tasks/build-deploy-from-github.json --from 09-check-node-connectivity
```

---

## デプロイ後の検証

### Backend 作成確認

```bash
# Producer (Node1)
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "journalctl -u vllm-producer -n 100 | grep 'Backend LIBFABRIC'"
# 期待: Backend LIBFABRIC was instantiated (rank: 0, device_list: cuda:0)

# Consumer (Node2)
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "journalctl -u vllm-consumer -n 100 | grep 'Backend LIBFABRIC'"
# 期待: Backend LIBFABRIC was instantiated (rank: 1, device_list: cuda:0)
```

### API テスト

```bash
curl -X POST http://$NODE2_PUBLIC_IP:8200/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-32B-Instruct",
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

## ロールバック

### 問題発生時の復元手順

```bash
# Node1 で元のプラグインに戻す
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP << 'EOF'
  PLUGIN_DIR="/home/ubuntu/.local/lib/python3.10/site-packages/nixl/../.nixl_cu12.mesonpy.libs/plugins"
  cp "${PLUGIN_DIR}/libplugin_LIBFABRIC.so.original" "${PLUGIN_DIR}/libplugin_LIBFABRIC.so"
  sudo systemctl restart vllm-producer
EOF

# Node2 で元のプラグインに戻す
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP << 'EOF'
  PLUGIN_DIR="/home/ubuntu/.local/lib/python3.10/site-packages/nixl/../.nixl_cu12.mesonpy.libs/plugins"
  cp "${PLUGIN_DIR}/libplugin_LIBFABRIC.so.original" "${PLUGIN_DIR}/libplugin_LIBFABRIC.so"
  sudo systemctl restart vllm-consumer
EOF
```

---

## トラブルシューティング

### 問題 1: git clone が失敗

**症状: **
```
Permission denied (publickey)
```

**解決策: **
```bash
# SSH 鍵が GitHub に登録されているか確認
ssh -T git@github.com

# 登録されていない場合
cat ~/.ssh/id_rsa.pub
# → GitHub Settings → SSH and GPG keys で追加
```

### 問題 2: ninja ビルドが失敗

**症状: **
```
[ERROR] Build failed
```

**解決策: **
```bash
# 依存関係を確認
cd /tmp/nixl-build
meson setup build --wipe
ninja -v  # 詳細ログで確認
```

### 問題 3: S3 アップロードが失敗

**症状: **
```
An error occurred (AccessDenied) when calling the PutObject operation
```

**解決策: **
```bash
# AWS credentials を確認
aws sts get-caller-identity

# S3 バケットへのアクセス権限を確認
aws s3 ls s3://$S3_BUCKET/
```

### 問題 4: SSH 接続が失敗

**症状: **
```
ssh: connect to host 44.247.215.228 port 22: Connection timed out
```

**解決策: **
```bash
# セキュリティグループで SSH (port 22) が開放されているか確認
aws ec2 describe-security-groups --region $AWS_REGION

# インスタンスが起動しているか確認
aws ec2 describe-instances --instance-ids <INSTANCE_ID> --region $AWS_REGION
```

---

## クリーンアップ

### ビルドディレクトリの削除

```bash
rm -rf /tmp/nixl-build
```

### S3 の古いバージョン削除

```bash
# 最新版のみ残して古いバージョンを削除
aws s3api list-object-versions \
  --bucket $S3_BUCKET \
  --prefix plugins/libplugin_LIBFABRIC.so \
  --region $AWS_REGION
```

---

## まとめ

### メリット

1. **完全自動化**: 1 コマンドで GitHub → ビルド → S3 → EC2 デプロイ
2. **再現性**: 誰でも同じ手順で再現可能
3. **冪等性**: 何度実行しても安全
4. **バックアップ**: 元のプラグインを自動保存
5. **検証**: 各ステップで MD5、シンボル、ロード確認

### 推奨ワークフロー

```bash
# 1. 開発: littlemex/nixl の main ブランチに修正を push
git push origin main

# 2. デプロイ: 完全自動ビルド＆デプロイ
cd /home/coder/phase2/disaggregated-inference-with-nixl-over-aws-efa/setup
bash task_runner.sh tasks/build-deploy-from-github.json

# 3. 検証: vLLM サービスを再起動して Backend 作成を確認
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "sudo systemctl restart vllm-producer"
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "sudo systemctl restart vllm-consumer"

# 4. テスト: API エンドポイントをテスト
curl -X POST http://$NODE2_PUBLIC_IP:8200/v1/completions ...
```

---

**質問やサポートが必要な場合は、GitHub Issues を作成してください: **
https://github.com/littlemex/nixl/issues
