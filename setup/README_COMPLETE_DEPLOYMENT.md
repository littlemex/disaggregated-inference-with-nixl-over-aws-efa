# 完全自動デプロイメント - ゼロから vLLM 起動まで

**最終更新**: 2026-03-08

このガイドは、GitHub → ビルド → S3 → EC2 セットアップ → vLLM 起動まで、**完全に自動化**されたワークフローを提供します。

---

## 🚀 クイックスタート（2 ステップ）

### 1. 環境変数設定

```bash
cd /home/coder/phase2/disaggregated-inference-with-nixl-over-aws-efa/setup
cp .env.example .env
vim .env  # 実際の値に編集
source .env
```

### 2. 完全自動デプロイ実行

```bash
bash task_runner.sh tasks/complete-deployment.json
```

**所要時間: ** 約 10-15 分（モデルダウンロード除く）

---

## 📋 実行内容（13 ステップ）

| # | タスク | 説明 | 所要時間 |
|---|--------|-----|----------|
| 01 | check-local-prerequisites | git, ninja, meson, aws CLI 確認 | 5 秒 |
| 02 | clone-nixl-from-github | `git clone https://github.com/littlemex/nixl.git` | 30 秒 |
| 03 | verify-backend-fix | ソースコードの修正確認 | 5 秒 |
| 04 | setup-meson-build | `meson setup build`（初回のみ） | 30 秒 |
| 05 | build-nixl-plugin | `ninja` でビルド | 2-3 分 |
| 06 | create-deployment-scripts | EC2 用セットアップスクリプト生成 | 5 秒 |
| 07 | upload-to-s3 | S3 へアップロード | 30 秒 |
| 08 | verify-s3-upload | S3 検証 | 5 秒 |
| 09 | check-node-connectivity | SSH 疎通確認 | 10 秒 |
| 10 | setup-node1-producer | Node1 セットアップ（Producer） | 2-3 分 |
| 11 | setup-node2-consumer | Node2 セットアップ（Consumer） | 2-3 分 |
| 12 | verify-plugin-deployment | MD5 検証 | 10 秒 |
| 13 | display-summary | サマリー表示 | 5 秒 |

---

## 🎯 各ノードで実行される内容

### Node1 (Producer) & Node2 (Consumer)

```bash
# 1. vLLM v0.17.0 インストール
pip install vllm==0.17.0 --user

# 2. NIXL インストール
pip install nixl[cu12] --user

# 3. LIBFABRIC plugin デプロイ
aws s3 cp s3://$S3_BUCKET/plugins/libplugin_LIBFABRIC.so $PLUGIN_DIR/

# 4. vLLM 起動スクリプト生成
/tmp/start-vllm.sh
```

### 起動スクリプトの内容

**Producer (Node1): **
```bash
python3 -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen2.5-32B-Instruct \
  --port 8100 \
  --tensor-parallel-size 2 \
  --gpu-memory-utilization 0.9 \
  --max-model-len 32000 \
  --max-num-batched-tokens 8192 \
  --kv-transfer-config '{
    "kv_connector": "NixlConnector",
    "kv_role": "kv_producer",
    "kv_rank": 0,
    "kv_parallel_size": 1,
    "kv_buffer_device": "cpu",
    "kv_buffer_size": 5000000000,
    "kv_ip": "172.31.10.117",      # Consumer Private IP
    "kv_port": 14579,
    "kv_connector_extra_config": {"backends": ["LIBFABRIC"]}
  }'
```

**Consumer (Node2): **
```bash
python3 -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen2.5-32B-Instruct \
  --port 8200 \
  --tensor-parallel-size 2 \
  --gpu-memory-utilization 0.9 \
  --max-model-len 32000 \
  --max-num-batched-tokens 8192 \
  --kv-transfer-config '{
    "kv_connector": "NixlConnector",
    "kv_role": "kv_consumer",
    "kv_rank": 0,
    "kv_parallel_size": 1,
    "kv_buffer_device": "cpu",
    "kv_buffer_size": 5000000000,
    "kv_ip": "127.0.0.1",           # ローカル
    "kv_port": 14579,
    "kv_connector_extra_config": {"backends": ["LIBFABRIC"]}
  }'
```

---

## 🔧 デプロイ後の手順

### 1. vLLM 起動

```bash
# Consumer 起動（Node2）
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP '/tmp/start-vllm.sh > /tmp/vllm-consumer.log 2>&1 &'

# 少し待機
sleep 10

# Producer 起動（Node1）
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP '/tmp/start-vllm.sh > /tmp/vllm-producer.log 2>&1 &'
```

### 2. モデルロード待機（5-10 分）

```bash
# Consumer (Node2) のログ監視
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP 'tail -f /tmp/vllm-consumer.log'

# 以下のメッセージが出るまで待機:
# "Backend LIBFABRIC was instantiated"
# "Application startup complete"
```

### 3. API テスト

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
  "model": "Qwen/Qwen2.5-32B-Instruct",
  "choices": [{
    "text": " I am a language model",
    "index": 0,
    "finish_reason": "length"
  }]
}
```

---

## 🔍 検証コマンド

### Backend 作成確認

```bash
# Producer (Node1)
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP 'grep "Backend LIBFABRIC" /tmp/vllm-producer.log'

# Consumer (Node2)
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP 'grep "Backend LIBFABRIC" /tmp/vllm-consumer.log'
```

**期待される出力: **
```
Backend LIBFABRIC was instantiated (rank: 0, device_list: cuda:0,cuda:1)
```

### プラグイン MD5 確認

```bash
# ローカル
md5sum /tmp/nixl-build/build/src/plugins/libfabric/libplugin_LIBFABRIC.so

# Node1
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP \
  "python3 -c 'import nixl, os, hashlib; plugin_dir = os.path.join(os.path.dirname(nixl.__file__), \"../.nixl_cu12.mesonpy.libs/plugins\"); print(hashlib.md5(open(os.path.join(plugin_dir, \"libplugin_LIBFABRIC.so\"), \"rb\").read()).hexdigest())'"

# Node2
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP \
  "python3 -c 'import nixl, os, hashlib; plugin_dir = os.path.join(os.path.dirname(nixl.__file__), \"../.nixl_cu12.mesonpy.libs/plugins\"); print(hashlib.md5(open(os.path.join(plugin_dir, \"libplugin_LIBFABRIC.so\"), \"rb\").read()).hexdigest())'"
```

全ての MD5 が一致すれば成功。

---

## 🛠️ トラブルシューティング

### 問題 1: vLLM 起動が失敗

**確認: **
```bash
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP 'cat /tmp/vllm-consumer.log | tail -50'
```

**よくあるエラー: **
- `CUDA out of memory` → GPU 不足、`--gpu-memory-utilization` を下げる
- `Backend LIBFABRIC` not found → プラグインデプロイ失敗、ステップ 12 を再確認

### 問題 2: Backend 削除エラー

**エラー: **
```
[ERROR] NIXL_ERR_INVALID_PARAM when calling GetConnInfo()
Backend deletion detected
```

**原因: ** 修正が適用されていない

**解決策: **
```bash
# ステップ 3 で修正確認
cd /tmp/nixl-build
grep -n "str = conn_info_" src/plugins/libfabric/libfabric_backend.cpp

# 再ビルド・再デプロイ
bash task_runner.sh tasks/complete-deployment.json --from 05-build-nixl-plugin
```

### 問題 3: S3 アップロード失敗

**確認: **
```bash
aws sts get-caller-identity
aws s3 ls s3://$S3_BUCKET/
```

**必要な権限: **
- `s3: PutObject`
- `s3: GetObject`
- `s3: ListBucket`

---

## 🔄 ロールバック

```bash
# Node1 で元のプラグインに戻す
ssh -i $SSH_KEY ubuntu@$NODE1_PUBLIC_IP << 'EOF'
  NIXL_DIR=$(python3 -c 'import nixl, os; print(os.path.dirname(nixl.__file__))')
  PLUGIN_DIR="${NIXL_DIR}/../.nixl_cu12.mesonpy.libs/plugins"
  cp "${PLUGIN_DIR}/libplugin_LIBFABRIC.so.original" "${PLUGIN_DIR}/libplugin_LIBFABRIC.so"
EOF

# Node2 も同様
ssh -i $SSH_KEY ubuntu@$NODE2_PUBLIC_IP << 'EOF'
  NIXL_DIR=$(python3 -c 'import nixl, os; print(os.path.dirname(nixl.__file__))')
  PLUGIN_DIR="${NIXL_DIR}/../.nixl_cu12.mesonpy.libs/plugins"
  cp "${PLUGIN_DIR}/libplugin_LIBFABRIC.so.original" "${PLUGIN_DIR}/libplugin_LIBFABRIC.so"
EOF
```

---

## 📝 重要な設定

### 必須設定

| 設定 | 値 | 理由 |
|------|---|------|
| `kv_buffer_device` | `"cpu"` | GPU OOM 回避（必須！） |
| `kv_ip` (Producer) | Consumer Private IP | 通信先 |
| `kv_ip` (Consumer) | `"127.0.0.1"` | ローカル |
| `backends` | `["LIBFABRIC"]` | EFA 使用 |

### 環境変数（使われていない）

- ❌ `VLLM_NIXL_SIDE_CHANNEL_PORT` → 代わりに `kv_port` を使用

---

## 🎉 完全再現性

このワークフローは以下を保証します：

1. ✅ **パス非依存**: `/tmp/nixl-build`使用
2. ✅ **冪等性**: 何度実行しても安全
3. ✅ **S3 ベース**: スクリプトも S3 経由で配布
4. ✅ **完全検証**: 各ステップで MD5, ロード確認
5. ✅ **バックアップ**: 元のプラグインを自動保存

---

**完璧な再現が完了しました！**

問題が発生した場合は、GitHub Issues で報告してください：
https://github.com/littlemex/nixl/issues
