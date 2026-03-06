# Phase 3 L2-EFA 環境セットアップ手順

**日時**: 2026-03-05
**対象**: Producer (Node1) と Consumer (Node2) の両方

## 前提条件

- AWS g7e.12xlarge インスタンス（RTX PRO 6000 Blackwell 96GB x2）
- EFA 有効化済み
- Ubuntu 22.04
- Python 3.10
- CUDA 12.x

## 重要な注意事項

### バージョンの固定が必須

以下のバージョン不一致は **vLLM 起動失敗** の原因になります：

1. **PyTorch 2.10.0 は NG** → vLLM 0.16.0 は torch==2.9.1 を要求
2. **NIXL バージョン不一致は NG** → Producer と Consumer で同じバージョン必須
3. **torch 再インストール時の注意** → 依存関係で 2.10.0 に戻る場合がある

### 検証済み動作環境

| パッケージ | バージョン | 備考 |
|----------|----------|------|
| PyTorch | 2.9.1 | vLLM 0.16.0 の要求バージョン |
| torchvision | 0.24.1 | PyTorch 2.9.1 に対応 |
| torchaudio | 2.9.1 | PyTorch 2.9.1 に対応 |
| vLLM | 0.16.0 | V1 Engine with disaggregation |
| NIXL | 0.10.0 (nixl-cu12) | LIBFABRIC backend |
| Transformers | 4.57.6 | Qwen2.5 サポート |

## セットアップ手順

### 1. スクリプトのダウンロード

```bash
cd /home/ubuntu

# S3 からスクリプトをダウンロード
aws s3 cp s3://phase3-nixl-efa-dev-west-2-scriptsbucket40feb4b1-ougyvcmrbyjj/setup/setup_vllm_nixl_environment.sh .
aws s3 cp s3://phase3-nixl-efa-dev-west-2-scriptsbucket40feb4b1-ougyvcmrbyjj/setup/start_producer_efa.sh .
aws s3 cp s3://phase3-nixl-efa-dev-west-2-scriptsbucket40feb4b1-ougyvcmrbyjj/setup/start_consumer_efa.sh .

chmod +x *.sh
```

### 2. 環境のクリーンアップ（重要）

```bash
# 既存の vLLM プロセスを停止
sudo pkill -9 python3
sleep 3

# GPU メモリをリセット
sudo nvidia-smi --gpu-reset -i 0
sudo nvidia-smi --gpu-reset -i 1
sleep 2

# GPU メモリが 0 MiB になっていることを確認
nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv
```

### 3. パッケージのインストール

**方法 A: セットアップスクリプト使用（推奨）**

```bash
sudo -u ubuntu -i bash /home/ubuntu/setup_vllm_nixl_environment.sh
```

**方法 B: 手動インストール**

```bash
# PyTorch を完全にアンインストール
pip uninstall torch torchvision torchaudio -y

# PyTorch 2.9.1 をインストール
pip install torch==2.9.1 torchvision==0.24.1 torchaudio==2.9.1

# vLLM をインストール（依存関係なし）
pip install vllm==0.16.0 --no-deps

# NIXL をインストール
pip install nixl-cu12==0.10.0 --force-reinstall

# Transformers をインストール
pip install transformers==4.57.6
```

### 4. インストール確認

```bash
pip list | grep -E "(torch|vllm|nixl|transformers)"

# 期待される出力:
# torch                              2.9.1
# torchaudio                         2.9.1
# torchvision                        0.24.1
# vllm                               0.16.0
# nixl                               0.10.0
# nixl-cu12                          0.10.0
# transformers                       4.57.6
```

**重要**: torch が 2.10.0 の場合は再インストールが必要です。

### 5. Producer 起動（Node1 のみ）

```bash
cd /home/ubuntu
bash start_producer_efa.sh

# ログ確認
tail -f ~/producer_efa.log
```

**起動成功の確認ポイント**:
- `NIXL compatibility check passed`
- `Successfully inserted address GID[...]`
- `Application server listening at: http://0.0.0.0:8100`

### 6. Consumer 起動（Node2 のみ）

```bash
cd /home/ubuntu
bash start_consumer_efa.sh

# ログ確認
tail -f ~/consumer_efa.log
```

**起動成功の確認ポイント**:
- `NIXL compatibility check passed`
- `Successfully inserted address GID[...]`
- `Application server listening at: http://0.0.0.0:8200`

## トラブルシューティング

### エラー 1: "NIXL is not available"

**原因**:
- NIXL がインストールされていない
- NIXL バージョンが Producer と Consumer で異なる
- torch のバージョンが 2.10.0 になっている

**解決策**:
```bash
# NIXL 確認
pip list | grep nixl

# torch 確認（2.9.1 であること）
pip list | grep torch

# 必要に応じて再インストール
pip install nixl-cu12==0.10.0 --force-reinstall
pip uninstall torch -y && pip install torch==2.9.1
```

### エラー 2: GPU メモリ不足

**原因**: 古いプロセスが GPU メモリを占有

**解決策**:
```bash
sudo pkill -9 python3
sudo nvidia-smi --gpu-reset -i 0
sudo nvidia-smi --gpu-reset -i 1
```

### エラー 3: torch==2.9.1 が要求される

**原因**: torch 2.10.0 がインストールされている

**解決策**:
```bash
pip uninstall torch torchvision torchaudio -y
pip install torch==2.9.1 torchvision==0.24.1 torchaudio==2.9.1
```

## 検証

### Producer と Consumer の疎通確認

```bash
# Producer ヘルスチェック
curl http://172.31.2.221:8100/health

# Consumer ヘルスチェック
curl http://172.31.10.117:8200/health
```

### NIXL 接続確認

Producer と Consumer のログに以下が出力されていること：

```
NIXL compatibility check passed
Successfully inserted address GID[fe80::...]
```

## 参考情報

- スクリプト: `/work/data-science/disaggregated-inference-with-nixl-over-aws-efa/experiments/scripts/`
- README: `README_benchmark.md`
- トラブルシューティング: `TROUBLESHOOTING_2026-03-05.md`

## よくある質問

### Q: なぜ torch 2.9.1 が必要？

A: vLLM 0.16.0 は torch==2.9.1 を明示的に要求しています。torch 2.10.0 では起動時にエラーになります。

### Q: NIXL のバージョンを統一する理由は？

A: Producer 0.10.0 と Consumer 0.10.1 のような不一致は、NIXL プロトコルの互換性問題を引き起こす可能性があります。

### Q: --no-deps を使う理由は？

A: vLLM のインストール時に torch 2.10.0 が依存関係で引き込まれるのを防ぐためです。

---

**作成日**: 2026-03-05
**最終更新**: 2026-03-05
