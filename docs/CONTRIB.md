# Contributing to NIXL LIBFABRIC Backend Fix Project

**最終更新**: 2026-03-08

このドキュメントは、NIXL LIBFABRIC Backend Deletion 問題の修正プロジェクトへの貢献者向けのガイドです。

## 目次

- [プロジェクト概要](#プロジェクト概要)
- [環境セットアップ](#環境セットアップ)
- [開発ワークフロー](#開発ワークフロー)
- [利用可能なスクリプト](#利用可能なスクリプト)
- [テスト手順](#テスト手順)
- [デプロイ手順](#デプロイ手順)
- [トラブルシューティング](#トラブルシューティング)

---

## プロジェクト概要

### 問題の背景

vLLM v0.17.0 の Disaggregated Inference (Producer/Consumer) アーキテクチャで、NIXL LIBFABRIC backend が即座に削除される問題が発生していました。

**根本原因: **
- カスタム LIBFABRIC plugin の `getConnInfo()` が `NIXL_IN_PROG` または `NIXL_ERR_BACKEND` を返す
- `nixlAgent::createBackend()` が `getConnInfo()` の戻り値が `NIXL_SUCCESS` でない場合、Backend を即座に削除する

### 解決策

UCX backend のパターンを採用：
1. Constructor で `serializeConnectionInfo()` を呼び出し、接続情報を `conn_info_` メンバ変数にキャッシュ
2. `getConnInfo()` は単に `conn_info_` を返すだけにする（常に `NIXL_SUCCESS`）

**変更ファイル（3 つ）: **
- `/home/coder/nixl/src/plugins/libfabric/libfabric_backend.h` (line ~228)
- `/home/coder/nixl/src/plugins/libfabric/libfabric_backend.cpp` (Constructor, line ~382)
- `/home/coder/nixl/src/plugins/libfabric/libfabric_backend.cpp` (getConnInfo, line ~459)

---

## 環境セットアップ

### 前提条件

| ソフトウェア | バージョン | 用途 |
|------------|----------|-----|
| Python | 3.10+ | vLLM, NIXL Python bindings |
| Ninja | 1.10+ | NIXL ビルド |
| g++ | 11+ | C++ コンパイル |
| AWS CLI | 2.x | S3 デプロイ、SSM 操作 |
| Meson | 1.0+ | NIXL ビルドシステム |

### インストール手順

#### 1. リポジトリのクローン

```bash
# プロジェクトリポジトリ
git clone https://github.com/your-org/disaggregated-inference-with-nixl-over-aws-efa.git
cd disaggregated-inference-with-nixl-over-aws-efa

# NIXL fork（修正版）
git clone git@github.com: littlemex/nixl.git /home/coder/nixl
cd /home/coder/nixl
git checkout fix/libfabric-backend-deletion
```

#### 2. 環境変数の設定

```bash
cd /home/coder/phase2/disaggregated-inference-with-nixl-over-aws-efa/setup
cp .env.example .env
# .env を編集して実際の値を設定
vim .env
source .env
```

**必須の環境変数: **

```bash
# Node 情報
NODE1_PUBLIC_IP=44.247.215.228        # Node1 Public IP (Producer)
NODE2_PUBLIC_IP=34.217.117.205        # Node2 Public IP (Consumer)
NODE1_PRIVATE_IP=172.31.2.221         # Node1 Private IP
NODE2_PRIVATE_IP=172.31.10.117        # Node2 Private IP

# SSH 設定
SSH_KEY=/home/coder/.ssh/phase3_key   # SSH 秘密鍵パス

# S3 設定
S3_BUCKET=phase3-nixl-efa-dev-west-2-scriptsbucket40feb4b1-ougyvcmrbyjj

# vLLM 設定
MODEL_NAME=Qwen/Qwen2.5-32B-Instruct  # モデル名
ENGINE_ID=phase3-nixl-efa-di-20260307 # Engine ID
PRODUCER_PORT=8100                     # Producer ポート
CONSUMER_PORT=8200                     # Consumer ポート

# AWS 設定
AWS_REGION=us-west-2                   # AWS リージョン
```

#### 3. NIXL のビルド

```bash
cd /home/coder/nixl

# Meson セットアップ（初回のみ）
meson setup build --prefix=/usr/local

# ビルド
cd build
ninja src/plugins/libfabric/libplugin_LIBFABRIC.so
```

**期待される出力: **
```
[OK] libplugin_LIBFABRIC.so built successfully
[OK] Size: ~500KB
[OK] Format: ELF 64-bit shared object
```

---

## 開発ワークフロー

### Git ブランチ戦略

```
main
  └── fix/libfabric-backend-deletion  (修正ブランチ)
```

### コミットメッセージ規約

```
<type>: <description>

<optional body>

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
```

**Types: **
- `fix`: バグ修正
- `feat`: 新機能
- `refactor`: リファクタリング
- `test`: テスト追加
- `docs`: ドキュメント更新

### コードレビュー手順

1. ブランチを作成: `git checkout -b feat/your-feature`
2. 変更をコミット: `git commit -m "feat: Add feature"`
3. GitHub に push: `git push -u origin feat/your-feature`
4. Pull Request を作成
5. コードレビューを受ける
6. 修正をコミット
7. マージ

---

## 利用可能なスクリプト

### Task Runner による実行

プロジェクトでは JSON ベースの Task Runner を使用してすべてのタスクを実行します。

#### 基本コマンド

```bash
cd /home/coder/phase2/disaggregated-inference-with-nixl-over-aws-efa/setup

# Task Runner の基本形式
bash task_runner.sh <task-json-file>
```

#### 主要なタスク

| タスクファイル | 説明 |
|-------------|-----|
| `tasks/fix-backend-deletion.json` | 完全な再現ワークフロー（ビルド → デプロイ → インストール → 検証） |
| `tasks/verify-backend-fix.json` | 修正の検証（17 ステップ） |
| `tasks/deploy-nixl-libfabric-plugin.json` | プラグインの S3 デプロイ |
| `tasks/setup-v0.17.0-environment.json` | vLLM v0.17.0 環境セットアップ |

#### 再現システムのタスク（phase3/group1/tasks/）

| タスクファイル | 説明 |
|-------------|-----|
| `build-nixl-plugin.json` | NIXL プラグインのビルド（10 ステップ、冪等性保証） |
| `deploy-plugin-to-s3.json` | S3 へのプラグインアップロード（4 ステップ） |
| `install-plugin-on-nodes.json` | 両ノードへのプラグインインストール（9 ステップ） |

### スクリプト一覧

| スクリプト | 説明 | 使用例 |
|----------|-----|--------|
| `task_runner.sh` | 汎用 JSON タスク実行エンジン | `bash task_runner.sh tasks/fix-backend-deletion.json` |
| `runner.sh` | SSH 経由でリモートノードにデプロイ・実行 | `./runner.sh deploy --node1` |
| `setup_phase3_simple.sh` | Phase 3 環境の簡易セットアップ | `bash setup_phase3_simple.sh <NODE_IP> <NODE_NAME>` |
| `deploy_plugin.sh` | プラグインの S3 デプロイ | `bash deploy_plugin.sh` |

### 実行例

#### 完全な再現ワークフロー

```bash
cd /home/coder/phase2/disaggregated-inference-with-nixl-over-aws-efa/setup
source .env
bash task_runner.sh tasks/fix-backend-deletion.json
```

**実行される内容: **
1. NIXL ソースの修正確認
2. ninja によるビルド
3. S3 への SO ファイルアップロード
4. 両ノード（Node1, Node2）への SSH 経由インストール
5. Backend 作成の検証

#### 個別タスクの実行

```bash
# ビルドのみ
cd /home/coder/phase3/group1
bash task_runner.sh tasks/build-nixl-plugin.json

# S3 デプロイのみ
bash task_runner.sh tasks/deploy-plugin-to-s3.json

# ノードインストールのみ
bash task_runner.sh tasks/install-plugin-on-nodes.json
```

---

## テスト手順

### ビルドアーティファクトの検証

```bash
cd /home/coder/nixl/build
file src/plugins/libfabric/libplugin_LIBFABRIC.so
ls -lh src/plugins/libfabric/libplugin_LIBFABRIC.so
```

**期待される出力: **
```
src/plugins/libfabric/libplugin_LIBFABRIC.so: ELF 64-bit LSB shared object
-rw-r--r-- 1 coder coder 500K Mar  8 12:00 libplugin_LIBFABRIC.so
```

### Backend 作成の検証

#### Producer (Node1) での検証

```bash
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "journalctl -u vllm-producer -n 50 | grep 'Backend LIBFABRIC'"
```

**期待される出力: **
```
Backend LIBFABRIC was instantiated (rank: 0, device_list: cuda:0)
```

#### Consumer (Node2) での検証

```bash
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "journalctl -u vllm-consumer -n 50 | grep 'Backend LIBFABRIC'"
```

**期待される出力: **
```
Backend LIBFABRIC was instantiated (rank: 1, device_list: cuda:0)
```

### API テスト

```bash
# Consumer (Node2) にリクエストを送信
curl -X POST http://$NODE2_PUBLIC_IP:$CONSUMER_PORT/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-32B-Instruct",
    "prompt": "Hello, world!",
    "max_tokens": 10
  }'
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

### 包括的な検証

```bash
cd /home/coder/phase2/disaggregated-inference-with-nixl-over-aws-efa/setup
source .env
bash task_runner.sh tasks/verify-backend-fix.json
```

**検証項目（17 ステップ）: **
1. ビルドアーティファクトの存在確認
2. S3 デプロイの確認
3. ノードインストールの確認
4. Backend 作成ログの確認
5. エラーログの不在確認
6. API 疎通テスト

---

## デプロイ手順

### 手動デプロイ

#### 1. NIXL プラグインのビルド

```bash
cd /home/coder/nixl/build
ninja src/plugins/libfabric/libplugin_LIBFABRIC.so
```

#### 2. S3 へのアップロード

```bash
aws s3 cp \
  /home/coder/nixl/build/src/plugins/libfabric/libplugin_LIBFABRIC.so \
  s3://$S3_BUCKET/tasks/phase3/$(date +%Y%m%d_%H%M%S)/libplugin_LIBFABRIC.so
```

#### 3. ノードへのインストール

```bash
# Node1 (Producer)
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "\
  aws s3 cp s3://$S3_BUCKET/tasks/phase3/latest/libplugin_LIBFABRIC.so /tmp/ && \
  sudo mkdir -p /usr/local/lib/nixl/plugins/libfabric && \
  sudo cp /tmp/libplugin_LIBFABRIC.so /usr/local/lib/nixl/plugins/libfabric/ && \
  sudo chmod 755 /usr/local/lib/nixl/plugins/libfabric/libplugin_LIBFABRIC.so"

# Node2 (Consumer)
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "\
  aws s3 cp s3://$S3_BUCKET/tasks/phase3/latest/libplugin_LIBFABRIC.so /tmp/ && \
  sudo mkdir -p /usr/local/lib/nixl/plugins/libfabric && \
  sudo cp /tmp/libplugin_LIBFABRIC.so /usr/local/lib/nixl/plugins/libfabric/ && \
  sudo chmod 755 /usr/local/lib/nixl/plugins/libfabric/libplugin_LIBFABRIC.so"
```

#### 4. サービスの再起動

```bash
# Node1 (Producer)
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "sudo systemctl restart vllm-producer"

# Node2 (Consumer)
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP "sudo systemctl restart vllm-consumer"
```

### Task Runner による自動デプロイ

```bash
cd /home/coder/phase2/disaggregated-inference-with-nixl-over-aws-efa/setup
source .env
bash task_runner.sh tasks/fix-backend-deletion.json
```

---

## トラブルシューティング

### ビルドエラー

#### 問題: ninja が見つからない

```bash
bash: ninja: command not found
```

**解決策: **
```bash
sudo apt-get update
sudo apt-get install ninja-build
```

#### 問題: build.ninja が見つからない

```bash
[ERROR] build.ninja not found. Run meson setup first.
```

**解決策: **
```bash
cd /home/coder/nixl
meson setup build --prefix=/usr/local
```

### デプロイエラー

#### 問題: SSH 接続タイムアウト

```bash
ssh: connect to host 44.247.215.228 port 22: Connection timed out
```

**解決策: **
1. セキュリティグループで SSH (port 22) が開放されているか確認
2. ノードが起動しているか確認: `aws ec2 describe-instances --instance-ids $NODE1_INSTANCE_ID`

#### 問題: S3 アップロード権限エラー

```bash
An error occurred (AccessDenied) when calling the PutObject operation
```

**解決策: **
1. AWS credentials が設定されているか確認: `aws sts get-caller-identity`
2. S3 バケットへの書き込み権限があるか確認

### Backend 作成エラー

#### 問題: Backend が即座に削除される

```bash
[ERROR] NIXL_ERR_INVALID_PARAM when calling GetConnInfo()
```

**原因: **
- 修正が適用されていない
- 古いプラグインが使用されている

**解決策: **
1. 最新のプラグインがインストールされているか確認:
   ```bash
   ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP "\
     ls -lh /usr/local/lib/nixl/plugins/libfabric/libplugin_LIBFABRIC.so && \
     md5sum /usr/local/lib/nixl/plugins/libfabric/libplugin_LIBFABRIC.so"
   ```

2. ソースコードに修正が含まれているか確認:
   ```bash
   cd /home/coder/nixl
   grep -n "std::string conn_info_" src/plugins/libfabric/libfabric_backend.h
   grep -n "serializeConnectionInfo.*dest.*conn_info_" src/plugins/libfabric/libfabric_backend.cpp
   grep -A5 "getConnInfo.*const" src/plugins/libfabric/libfabric_backend.cpp | grep "str = conn_info_"
   ```

3. 再ビルドとデプロイ:
   ```bash
   cd /home/coder/phase2/disaggregated-inference-with-nixl-over-aws-efa/setup
   bash task_runner.sh tasks/fix-backend-deletion.json
   ```

---

## 参考資料

### ドキュメント

- [REPRODUCTION_DESIGN.md](/home/coder/phase3/group1/setup/REPRODUCTION_DESIGN.md) - 再現システムの設計
- [ROOT_CAUSE_BACKEND_DELETION_2026-03-08.md](/home/coder/phase3/group1/ROOT_CAUSE_BACKEND_DELETION_2026-03-08.md) - 根本原因分析
- [SOLUTION_BACKEND_DELETION_2026-03-08.md](/home/coder/phase3/group1/SOLUTION_BACKEND_DELETION_2026-03-08.md) - 解決策提案

### 関連リンク

- [NIXL フォーク (littlemex/nixl)](https://github.com/littlemex/nixl)
- [vLLM Disaggregated Inference ドキュメント](https://docs.vllm.ai/en/latest/features/disaggregated_inference.html)
- [AWS EFA ドキュメント](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)

---

**質問がある場合は、Issue を作成してください: **
https://github.com/your-org/disaggregated-inference-with-nixl-over-aws-efa/issues
