# NIXL Request/Response Example - Quick Start

**compact 後にすぐ再現するためのクイックガイド**

## 1. 環境設定

```bash
cd /home/coder/phase3/group1
source get_config.sh
```

## 2. コンパイル

```bash
./compile_request_response.sh
```

これにより、両ノード（Node1, Node2）で自動的にコンパイルされます。

## 3. 実行

```bash
./run_request_response.sh
```

Producer（Node1）と Consumer（Node2）が起動し、60秒間実行されます。

## 4. ログ確認

```bash
# Producer ログ
ssh -i ~/.ssh/phase3_key ubuntu@172.31.2.221 'tail -50 /home/ubuntu/producer.log'

# Consumer ログ
ssh -i ~/.ssh/phase3_key ubuntu@172.31.10.117 'tail -50 /home/ubuntu/consumer.log'
```

## ファイル構成

| ファイル | 説明 |
|---------|------|
| `NIXL_REQUEST_RESPONSE_SETUP.md` | 詳細な実装手順とトラブルシューティング |
| `compile_request_response.sh` | コンパイルスクリプト |
| `run_request_response.sh` | 実行スクリプト |
| `setup.md` Section 17 | setup.md での参照 |

## ソースコードの場所

- **Example**: `/home/coder/nixl-fork/nixl/examples/cpp/request_response_example.cpp`
- **Unit Test**: `/home/coder/nixl-fork/nixl/test/unit/plugins/libfabric/libfabric_request_response_test.cpp`
- **meson.build**: `/home/coder/nixl-fork/nixl/examples/cpp/meson.build` (updated)

## 現在の状態

- [OK] metadata exchange 成功
- [NG] notification 送受信の問題（調査中）

詳細は `NIXL_REQUEST_RESPONSE_SETUP.md` を参照。
