# テンプレート設定ルール

## VLLM_NIXL_SIDE_CHANNEL_HOST の設定規則

### 概要

`VLLM_NIXL_SIDE_CHANNEL_HOST` は vLLM の NIXL KV Transfer で使用される ZMQ サイドチャネルの bind アドレスを指定する環境変数です。各ノードは **自分自身のプライベート IP アドレス** で ZMQ ソケットを bind する必要があります。

### ルール

| ロール | テンプレート | 設定値 | 理由 |
|--------|-------------|--------|------|
| Consumer (Node2) | `disaggregated-consumer.json.jinja2` | `$NODE2_PRIVATE` | Consumer は Node2 で動作し、自ノードの IP で ZMQ をbind する |
| Producer (Node1) | `disaggregated-producer.json.jinja2` | `$NODE1_PRIVATE` | Producer は Node1 で動作し、自ノードの IP で ZMQ を bind する |

### 重要な注意事項

- **絶対に相手ノードの IP を指定しないこと**: Consumer に `$NODE1_PRIVATE` を指定したり、Producer に `$NODE2_PRIVATE` を指定すると、ZMQ ソケットの bind に失敗し、NIXL 接続が確立できません
- この設定は「サーバー/クライアント」の関係ではなく、各ノードが自分自身で ZMQ ソケットを bind するための設定です

### ノード配置の前提

```
Node1 (NODE1_PRIVATE): Producer (Prefill) - kv_rank=0
Node2 (NODE2_PRIVATE): Consumer (Decode)  - kv_rank=1
```

### テンプレート内のコメント

各テンプレートには Jinja2 コメントでルールが明記されています:

```jinja2
{# [RULE] Consumer: VLLM_NIXL_SIDE_CHANNEL_HOST=$NODE2_PRIVATE (自ノードIP) #}
{# [RULE] Producer: VLLM_NIXL_SIDE_CHANNEL_HOST=$NODE1_PRIVATE (自ノードIP) #}
```

### 変更時のチェックリスト

テンプレートを変更する際は、以下を確認してください:

- [ ] `VLLM_NIXL_SIDE_CHANNEL_HOST` が自ノードの IP 変数を参照している
- [ ] Consumer テンプレート: `$NODE2_PRIVATE` であること
- [ ] Producer テンプレート: `$NODE1_PRIVATE` であること
- [ ] 新しいテンプレートを追加する場合、同じルールに従っている

## 関連する環境変数

| 変数名 | 説明 |
|--------|------|
| `NODE1_PRIVATE` | Producer ノード（Node1）のプライベート IP |
| `NODE2_PRIVATE` | Consumer ノード（Node2）のプライベート IP |
| `NIXL_BACKEND` | NIXL バックエンド（`LIBFABRIC` or `UCX`） |
| `NIXL_LOG_LEVEL` | NIXL ログレベル |

## テンプレート一覧

### Disaggregated Inference テンプレート

| ファイル | ロール | VLLM_NIXL_SIDE_CHANNEL_HOST |
|---------|--------|---------------------------|
| `disaggregated-consumer.json.jinja2` | Consumer (Decode) | `$NODE2_PRIVATE` |
| `disaggregated-producer.json.jinja2` | Producer (Prefill) | `$NODE1_PRIVATE` |

### その他のテンプレート（VLLM_NIXL_SIDE_CHANNEL_HOST 不使用）

以下のテンプレートは `VLLM_NIXL_SIDE_CHANNEL_HOST` を使用しません:

- `analysis.json.jinja2`
- `baseline-*.json.jinja2` (fi-info, fi-rdm-bw, fi-rdm-pingpong, iperf3, nccl-test, nvidia-smi)
- `low-level-*.json.jinja2` (fi-pingpong, kvbench, nixlbench, ucx-perftest)
- `unified.json.jinja2`

---

最終更新: 2026-03-02
