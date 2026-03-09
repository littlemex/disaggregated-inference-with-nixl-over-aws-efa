# NIXL Disaggregated Inference - Deployment Setup (v9)

SSM + S3 ベースの完全自動デプロイメントシステム

## 概要

このディレクトリには、NIXL LIBFABRIC backend を使用した vLLM disaggregated inference の自動デプロイツールが含まれています。

### v9 の主な機能

- **SSM ベースのリモート実行**: SSH 不要、すべて AWS SSM 経由で実行
- **S3 経由のファイル配布**: プラグイン、設定ファイル、スクリプトを S3 経由で配布
- **GPU 数の動的検出**: インスタンスタイプに応じて自動的に TP サイズを調整
- **冪等性サポート**: タスクの再実行が安全
- **JSON ベースのタスク定義**: すべてのタスクを JSON で定義


## アーキテクチャ

```
setup/
├── deploy-v9.sh                      # メインデプロイスクリプト
├── task_runner.sh                    # 汎用 JSON タスク実行エンジン
├── ssm_helper.sh                     # SSM コマンド実行ヘルパー関数
├── tasks/
│   └── complete-deployment-v9.json   # v9 デプロイメントタスク定義
└── configs/
    └── v9test-ap-northeast-1.env     # デプロイ設定ファイル例
```

## 前提条件

### ローカルマシン

```bash
# libfabric-dev のインストール（必須）
sudo apt-get update
sudo apt-get install -y libfabric-dev

# ビルドツール
pip install ninja meson

# AWS CLI 設定
aws configure
```

### EC2 インスタンス

- Deep Learning AMI (Ubuntu 24.04 推奨)
- EFA サポート（g7e.8xlarge, g7e.12xlarge など）
- IAM ロール: S3 読み取り権限 + SSM 管理権限
- SSM Agent 実行中（Deep Learning AMI はデフォルトで有効）
- セキュリティグループ: EFA トラフィック許可

**注意**: SSH ポート (22) の開放は不要です（SSM 使用のため）

## クイックスタート

### 1. 設定ファイルの準備

```bash
cd setup
cp configs/example.env configs/my-deployment.env
vim configs/my-deployment.env
```

**必須項目: **

```bash
S3_BUCKET="your-bucket-name"
AWS_REGION="ap-northeast-1"
NODE1_INSTANCE_ID="$INSTANCE_ID"           # Producer インスタンス ID
NODE2_INSTANCE_ID="$INSTANCE_ID"           # Consumer インスタンス ID
NODE1_PRIVATE_IP="172.31.x.x"         # Producer プライベート IP
NODE2_PRIVATE_IP="172.31.x.x"         # Consumer プライベート IP
DEPLOYMENT_ID="my-deployment"
ENGINE_ID="nixl-efa-20260308"
```

### 2. デプロイ実行

```bash
./deploy-v9.sh configs/my-deployment.env
```

デプロイは約 10-15 分かかります。

## デプロイフロー

### Phase 1: ローカルビルド

1. NIXL fork のクローン（main ブランチ）
2. LIBFABRIC プラグインのビルド
3. S3 へのアップロード

### Phase 2: GPU 検出

両ノードの GPU 数を自動検出し、TP サイズを設定：

```bash
nvidia-smi --list-gpus | wc -l
```

| インスタンス | GPU 数 | TP サイズ |
|------------|--------|----------|
| g7e.8xlarge | 1 | 1 |
| g7e.12xlarge | 2 | 2 |
| g7e.24xlarge | 4 | 4 |

### Phase 3: リモートセットアップ（SSM 経由）

1. GPU プロセスクリーンアップ
2. vLLM v0.17.0 インストール
3. NIXL v0.10.0 インストール
4. LIBFABRIC プラグインデプロイ（549KB）
5. kv-transfer-config 配布
6. 起動スクリプト配布

### Phase 4: 完了

起動準備が整います。

## NIXL Fork 情報

### リポジトリ

- **URL**: https://github.com/littlemex/nixl.git
- **ブランチ**: `main`
- **タグ**: `v0.10.0-vllm-disagg-fix`

### Backend Deletion Fix

vLLM v0.17.0 の Disaggregated Inference で発生していた Backend 即座削除問題を修正：

**修正内容: **
- `nixlLibfabricEngine` コンストラクタで接続情報を事前キャッシュ
- `getConnInfo()` メソッドを UCX backend と同じパターンに変更
- キャッシュされた `conn_info_` を返すことで常に `NIXL_SUCCESS` を返却

**効果: **
- Producer/Consumer の両ノードで Backend が正常に作成される
- EFA 経由の KV cache 転送が動作する

## 起動手順

デプロイ完了後、以下の順序でサービスを起動してください。

### 1. Producer 起動

```bash
aws ssm send-command \
  --instance-ids $NODE1_INSTANCE_ID \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["cd /home/ubuntu && ./start_producer.sh"]' \
  --region ap-northeast-1
```

### 2. Producer ログ確認（2-3 分待機）

```bash
aws ssm send-command \
  --instance-ids $NODE1_INSTANCE_ID \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["tail -50 /home/ubuntu/producer.log"]' \
  --region ap-northeast-1
```

"Uvicorn running" または "Application startup complete" が表示されれば成功。

### 3. Consumer 起動

```bash
aws ssm send-command \
  --instance-ids $NODE2_INSTANCE_ID \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["cd /home/ubuntu && ./start_consumer.sh"]' \
  --region ap-northeast-1
```

### 4. Consumer ログ確認（2-3 分待機）

```bash
aws ssm send-command \
  --instance-ids $NODE2_INSTANCE_ID \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["tail -50 /home/ubuntu/consumer.log"]' \
  --region ap-northeast-1
```

### 5. Proxy Server 起動

```bash
aws ssm send-command \
  --instance-ids $NODE2_INSTANCE_ID \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["cd /home/ubuntu && ./start_proxy.sh"]' \
  --region ap-northeast-1
```

### 6. 動作確認

```bash
# Proxy 経由でリクエスト
curl http://<CONSUMER_PUBLIC_IP>:8000/v1/models
```

## 設定ファイル

### kv-transfer-config

**Producer (`/home/ubuntu/kv_config.json`): **

```json
{
  "engine_id": "v9test-nixl-efa-20260308",
  "kv_connector": "NixlConnector",
  "kv_role": "kv_producer",
  "kv_rank": 0,
  "kv_parallel_size": 1,
  "kv_buffer_size": 5000000000,
  "kv_buffer_device": "cpu",
  "kv_ip": "172.31.37.101",
  "kv_port": 14579,
  "kv_connector_extra_config": {
    "backends": ["LIBFABRIC"]
  }
}
```

**Consumer (`/home/ubuntu/kv_config.json`): **

```json
{
  "engine_id": "v9test-nixl-efa-20260308",
  "kv_connector": "NixlConnector",
  "kv_role": "kv_consumer",
  "kv_rank": 0,
  "kv_parallel_size": 1,
  "kv_buffer_size": 5000000000,
  "kv_buffer_device": "cpu",
  "kv_ip": "172.31.43.3",
  "kv_port": 14579,
  "kv_producer_ips": ["172.31.37.101"],
  "kv_connector_extra_config": {
    "backends": ["LIBFABRIC"]
  }
}
```

**重要**: `kv_buffer_device` は必ず `"cpu"` を指定してください（`"cuda"` は OOM の原因）。

### 環境変数

| 変数 | デフォルト | 説明 |
|-----|----------|------|
| NIXL_REPO | https://github.com/littlemex/nixl.git | NIXL リポジトリ URL |
| NIXL_BRANCH | main | NIXL ブランチ |
| MODEL_NAME | Qwen/Qwen2.5-32B-Instruct | vLLM モデル |
| KV_BUFFER_SIZE | 5000000000 | KV キャッシュバッファサイズ（5GB） |
| KV_BUFFER_DEVICE | cpu | KV キャッシュデバイス（必ず cpu） |
| NIXL_PORT | 14579 | NIXL 通信ポート |
| ZMQ_PORT | 50100 | ZMQ サイドチャネルポート |
| PRODUCER_PORT | 8100 | Producer vLLM API ポート |
| CONSUMER_PORT | 8200 | Consumer vLLM API ポート |
| PROXY_PORT | 8000 | Proxy Server ポート |
| PRODUCER_GPU_COUNT | (自動検出) | Producer の GPU 数 |
| CONSUMER_GPU_COUNT | (自動検出) | Consumer の GPU 数 |

## トラブルシューティング

### GPU プロセスのクリーンアップ

```bash
aws ssm send-command \
  --instance-ids $INSTANCE_ID \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["sudo pkill -9 -f vllm.entrypoints.openai.api_server","nvidia-smi"]' \
  --region ap-northeast-1
```

### ログ確認

```bash
# Producer ログ
aws ssm send-command \
  --instance-ids $NODE1_INSTANCE_ID \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["tail -100 /home/ubuntu/producer.log"]' \
  --region ap-northeast-1

# Consumer ログ
aws ssm send-command \
  --instance-ids $NODE2_INSTANCE_ID \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["tail -100 /home/ubuntu/consumer.log"]' \
  --region ap-northeast-1

# Proxy ログ
aws ssm send-command \
  --instance-ids $NODE2_INSTANCE_ID \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["tail -50 /home/ubuntu/proxy.log"]' \
  --region ap-northeast-1
```

### プラグイン確認

```bash
aws ssm send-command \
  --instance-ids $INSTANCE_ID \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["python3 -c \"import nixl, os; print(os.path.join(os.path.dirname(nixl.__file__), '\''_lib/libplugin_LIBFABRIC.so'\''))\" | xargs ls -lh"]' \
  --region ap-northeast-1
```

期待される出力: `-rwxr-xr-x 1 root root 549K ... libplugin_LIBFABRIC.so`

### SSM Agent が応答しない

```bash
# SSM Agent のステータス確認
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --region ap-northeast-1

# SSM Agent の再起動（インスタンス内で）
sudo systemctl restart snap.amazon-ssm-agent.amazon-ssm-agent.service
```

### モデルのロードが遅い

32B モデルのロードには 2-3 分かかります。`nvidia-smi` で GPU 使用率を確認：

```bash
aws ssm send-command \
  --instance-ids $INSTANCE_ID \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["watch -n 1 nvidia-smi"]' \
  --region ap-northeast-1
```

## タスクランナー設計

### 汎用 JSON タスク実行エンジン

すべてのリモート実行タスクは JSON で定義し、同じ `task_runner.sh` で実行します。

**禁止事項: **

- 測定専用の bash スクリプト作成
- タスク定義なしで直接 SSH/SSM 実行
- タスク実行エンジンの複数作成

**正しい方法: **

```bash
# 1. JSON でタスクを定義
tasks/new-task.json

# 2. 既存の task_runner.sh で実行
./task_runner.sh tasks/new-task.json
```

### タスク定義例

```json
{
  "name": "Sample Task",
  "environment": {
    "VAR_NAME": "${VAR_NAME}"
  },
  "tasks": [
    {
      "id": "01-task",
      "name": "Task Name",
      "skip_if": "test -f /path/to/file",
      "commands": [
        "echo '[INFO] Doing something...'",
        "command1",
        "command2"
      ]
    }
  ]
}
```

### 冪等性

各タスクは `skip_if` 条件を持ち、既に完了している場合はスキップされます：

```bash
"skip_if": "test -f /home/ubuntu/kv_config.json"
```

### 再実行

特定のタスクから再実行：

```bash
./task_runner.sh tasks/complete-deployment-v9.json --from 09-producer-install-vllm
```

## デプロイ後のテスト

### 1. Prefill のみ（Producer のみ使用）

```bash
curl -X POST http://<CONSUMER_PUBLIC_IP>:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-32B-Instruct",
    "prompt": "Once upon a time",
    "max_tokens": 1
  }'
```

### 2. Disaggregated Inference（Producer + Consumer）

```bash
curl -X POST http://<CONSUMER_PUBLIC_IP>:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-32B-Instruct",
    "prompt": "Once upon a time",
    "max_tokens": 100
  }'
```

Consumer ログで "KV cache transferred" を確認。

## 参考リンク

- [NIXL GitHub](https://github.com/littlemex/nixl)
- [vLLM Documentation](https://docs.vllm.ai/)
- [AWS EFA Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
- [AWS Systems Manager](https://docs.aws.amazon.com/systems-manager/)

## 最終更新

- 日付: 2026-03-09
- バージョン: v9
- 主な変更: SSM ベース化、GPU 動的検出機能追加、完全再現可能なデプロイメント達成
