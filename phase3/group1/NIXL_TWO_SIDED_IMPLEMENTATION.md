# NIXL LIBFABRIC Backend - Two-Sided Messaging 実装

## 概要

Phase 3 では、NIXL LIBFABRIC backend に Request/Response protocol (two-sided messaging) を実装しました。

**実装日**: 2026-03-07
**対象**: NIXL v0.10.0 (カスタムフォーク)
**Backend**: LIBFABRIC
**プロトコル**: Two-sided messaging (fi_senddata + fi_recv)

## 背景

### Phase 2 での課題

Phase 2 (g6e.12xlarge) では、以下の問題により EFA 上の NIXL が動作しませんでした：

1. **Hardware RDMA 未サポート**: g6e の L40S は hardware RDMA をサポートしていない
2. **fi_read EAGAIN エラー**: LIBFABRIC の one-sided RDMA (fi_read) が EAGAIN エラーで失敗
3. **UCX PUT_SHORT 未実装**: UCX backend も PUT_SHORT 未実装で動作せず

### Phase 3 のアプローチ

Phase 3 (g7e.12xlarge) では、hardware RDMA をサポートする Blackwell RTX PRO 6000 を使用し、**two-sided messaging** を実装することで課題を解決します。

**Two-sided messaging の利点**:
- EFA provider が完全にサポート (fi_senddata, fi_recv)
- Hardware RDMA の有無に依存しない
- Producer/Consumer 間の明示的な Request/Response プロトコル

## 実装内容

### 1. メッセージタイプの追加

**ファイル**: `nixl/src/utils/libfabric/libfabric_common.h`

```cpp
// Line 77
#define NIXL_LIBFABRIC_MSG_CONTROL_REQUEST 3  // Control message (READ_REQUEST, etc.)

// Line 332-346: Control message structure
struct NixlControlMessage {
    enum Operation : uint32_t {
        READ_REQUEST = 1,  // Consumer -> Producer: request data send
        WRITE_NOTIFY = 2   // Reserved for future use
    };
    uint32_t operation;
    uint32_t request_id;
    uint32_t rail_id;
    uint32_t reserved;
    uint64_t length;
    uint64_t offset;
};
```

### 2. Control Message 受信処理

**ファイル**: `nixl/src/utils/libfabric/libfabric_rail.cpp`

Control message の受信とハンドラ呼び出しを実装：

```cpp
// Line ~940: processRecvCompletion()
} else if (msg_type == NIXL_LIBFABRIC_MSG_CONTROL_REQUEST) {
    // Control message (READ_REQUEST)
    NixlControlMessage ctrl_msg;
    memcpy(&ctrl_msg, req->buffer, sizeof(NixlControlMessage));

    if (ctrl_msg_handler_) {
        ctrl_msg_handler_(ctrl_msg, FI_ADDR_UNSPEC);
    }
}
```

### 3. Control Message 送信処理

**ファイル**: `nixl/src/utils/libfabric/libfabric_rail.cpp`

fi_senddata を使用した control message 送信：

```cpp
// Line ~1620: sendControlMessage()
uint64_t imm_data = NIXL_MAKE_IMM_DATA(
    NIXL_LIBFABRIC_MSG_CONTROL_REQUEST,
    0,
    msg.request_id,
    0
);

int ret = fi_senddata(
    endpoint,
    ctrl_send_buffer_,
    sizeof(NixlControlMessage),
    fi_mr_desc(ctrl_send_mr_),
    imm_data,
    dest_addr,
    ctrl_send_buffer_
);
```

### 4. Producer の Control Message ハンドラ

**ファイル**: `nixl/src/plugins/libfabric/libfabric_backend.cpp`

Producer 側で READ_REQUEST を受信し、データ送信を実行：

```cpp
// Line ~1450: handleControlMessage()
void nixlLibfabricEngine::handleControlMessage(
    const NixlControlMessage &msg,
    fi_addr_t src_addr
) {
    if (msg.operation != NixlControlMessage::READ_REQUEST) {
        return;
    }

    // ProducerTransferContext から dest_addr を取得
    auto &ctx = producer_transfers_[msg.request_id];
    auto conn_it = connections_.find(ctx.remote_agent);
    auto &rail_addrs = conn_it->second->rail_remote_addr_list_;
    const auto &remote_eps = rail_addrs.at(msg.rail_id);
    fi_addr_t dest_addr = remote_eps[0];

    // Immediate data を作成
    uint64_t imm_data = NIXL_MAKE_IMM_DATA(
        NIXL_LIBFABRIC_MSG_TRANSFER,
        ctx.agent_index,
        msg.request_id,
        0
    );

    // fi_writedata でデータ送信
    nixlLibfabricRail *rail = rails_[msg.rail_id].get();
    rail->postWrite(
        ctx.local_buffer,
        msg.length,
        ctx.local_desc,
        imm_data,
        dest_addr,
        ctx.remote_addr,
        ctx.remote_key,
        data_req
    );
}
```

### 5. Consumer の postRead 実装

**ファイル**: `nixl/src/utils/libfabric/libfabric_rail.cpp`

Consumer が Rail 0 経由で READ_REQUEST を送信：

```cpp
// Line ~1200: postRead()
nixl_status_t nixlLibfabricRail::postRead(
    void *local_buffer,
    size_t length,
    void *local_desc,
    fi_addr_t dest_addr,
    uint64_t remote_addr,
    uint64_t remote_key,
    nixlLibfabricReq *req
) const {
    // Step 1: Register local buffer
    // ...

    // Step 2: Send control message to Producer via Rail 0
    nixlLibfabricRail *ctrl_rail = rail_manager_->getRailPtr(0);

    NixlControlMessage ctrl_msg;
    ctrl_msg.operation = NixlControlMessage::READ_REQUEST;
    ctrl_msg.request_id = req->xfer_id;
    ctrl_msg.rail_id = this->rail_id;
    ctrl_msg.length = length;
    ctrl_msg.offset = 0;

    return ctrl_rail->sendControlMessage(ctrl_msg, dest_addr);
}
```

## ビルド手順

```bash
cd ~/nixl/build
ninja
```

**ビルド成果物**: `/home/coder/nixl/build/src/plugins/libfabric/libplugin_LIBFABRIC.so` (549KB)

## デプロイ手順

### 1. S3 へのアップロード

```bash
aws s3 cp ~/nixl/build/src/plugins/libfabric/libplugin_LIBFABRIC.so \
  s3://phase3-nixl-efa-dev-west-2-scriptsbucket40feb4b1-ougyvcmrbyjj/plugins/libplugin_LIBFABRIC.so \
  --region us-west-2
```

### 2. ノードへのデプロイ (Node1 & Node2)

```bash
# SSH 経由でデプロイ
ssh -i ~/.ssh/phase3_key ubuntu@<node-ip> '
  NIXL_DIR=$(python3 -c "import nixl; import os; print(os.path.dirname(nixl.__file__))");
  PLUGIN_DIR="${NIXL_DIR}/_lib";
  aws s3 cp s3://phase3-nixl-efa-dev-west-2-scriptsbucket40feb4b1-ougyvcmrbyjj/plugins/libplugin_LIBFABRIC.so \
    "${PLUGIN_DIR}/libplugin_LIBFABRIC.so" --region us-west-2 && \
  chmod 755 "${PLUGIN_DIR}/libplugin_LIBFABRIC.so" && \
  ls -lh "${PLUGIN_DIR}/libplugin_LIBFABRIC.so"
'
```

## 検証

### プラグインの確認

```bash
ssh -i ~/.ssh/phase3_key ubuntu@<node-ip> '
  python3 << EOF
import nixl
import os
plugin_dir = os.path.join(os.path.dirname(nixl.__file__), "_lib")
plugins = [f for f in os.listdir(plugin_dir) if f.startswith("libplugin_") and f.endswith(".so")]
print("Available plugins: ", plugins)
EOF
'
```

**期待される出力**:
```
Available plugins: ['libplugin_LIBFABRIC.so']
```

### シンボルの確認

```bash
nm -D /path/to/libplugin_LIBFABRIC.so | grep nixl | head -20
```

## 設定

**config.json** で LIBFABRIC backend を指定：

```json
{
  "kv_transfer": {
    "kv_connector": "NixlConnector",
    "kv_parallel_size": 1,
    "kv_buffer_device": "cpu",
    "kv_buffer_size": 5000000000,
    "backends": ["LIBFABRIC"]
  }
}
```

## プロトコルフロー

### Request/Response Protocol

```
[Consumer]                     [Producer]
    |                              |
    | (1) postRead()               |
    |    - Register local buffer   |
    |                              |
    | (2) READ_REQUEST (Rail 0)    |
    |----------------------------->|
    |                              | (3) handleControlMessage()
    |                              |    - Lookup transfer context
    |                              |    - Get dest_addr from connection
    |                              |
    |                              | (4) fi_writedata (Data Rail)
    |<-----------------------------|
    |                              |
    | (5) processRemoteWriteCompletion()
    |    - Verify immediate data   |
    |    - Complete transfer       |
    |                              |
```

## 既知の制限事項

1. **Rail 0 専用**: Control message は Rail 0 のみを使用
2. **単一チャンク**: 現在の実装は単一チャンクのみサポート
3. **エラーハンドリング**: 再送メカニズムは未実装

## 次のステップ

1. **テスト実行**: vLLM で EFA vs TCP の性能比較
2. **ログ分析**: two-sided messaging の動作確認
3. **パフォーマンス測定**: レイテンシとスループットの評価
4. **エラーハンドリング改善**: 再送メカニズムの実装

## 参考資料

- Phase 2 調査結果: `/home/coder/phase2/group1/README.md`
- Phase 3 調査結果: `/home/coder/phase3/group1/INVESTIGATION_BREAKTHROUGH_2026-03-07.md`
- NIXL ソースコード: `/home/coder/nixl/`
- Libfabric ドキュメント: https://ofiwg.github.io/libfabric/
