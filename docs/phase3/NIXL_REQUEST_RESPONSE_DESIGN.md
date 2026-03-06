# NIXL Request/Response プロトコル設計

## 目的

Two-sided messaging 環境で Consumer の READ 要求を実現するため、制御メッセージによる Request/Response プロトコルを実装する。

## 問題の本質

- Consumer が `postXfer(NIXL_READ)` を呼ぶと、内部で `fi_recv()` が実行される
- `fi_recv()` は受動的な操作: 受信バッファを準備するだけ
- Producer は Consumer が READ を要求していることを知らない
- Producer は何も送信しない
- Consumer は永遠にデータを待ち続ける

## 解決策: Request/Response プロトコル

### プロトコルフロー

```
[Consumer]                                [Producer]
    |                                          |
    | (1) postXfer(NIXL_READ)                 |
    |     - Rail 0: 制御メッセージ送信        |
    |       {op: READ_REQ, rail: 1,           |
    |        request_id: 12345, ...}          |
    |-------------------------------------------->|
    |                                          | (2) 制御メッセージ受信
    |                                          |     - Progress thread で検出
    |                                          |     - READ_REQ を解析
    |                                          |
    |     - Rail 1: 受信バッファポスト        | (3) データ送信
    |       fi_recv(rail_1, buffer, ...)      |     - 指定された Rail でデータ送信
    |                                          |       fi_senddata(rail_1, data,
    |<-----------------------------------------|                   imm=12345)
    | (4) データ受信完了                       |
    |     - immediate data で request_id 照合 |
    |     - completion callback 実行          |
    |                                          |
```

### 制御メッセージ構造体

```cpp
/**
 * 制御メッセージ構造体
 * Rail 0 で送受信される
 */
struct NixlControlMessage {
    enum Operation {
        READ_REQUEST = 1,  // Consumer -> Producer: READ 要求
        WRITE_NOTIFY = 2   // 将来の拡張用（現在は不要）
    };

    uint32_t operation;     // Operation type
    uint32_t request_id;    // 要求 ID（Consumer が生成、response で照合）
    uint32_t rail_id;       // データ転送に使用する Rail ID (1, 2, ...)
    uint32_t reserved;      // アライメント用
    uint64_t length;        // 転送サイズ（bytes）
    uint64_t offset;        // オフセット（将来の拡張用）
};
```

サイズ: 32 bytes（キャッシュライン効率的）

### Rail 0: 制御プレーン

**役割**: 制御メッセージの送受信専用

**特性**:
- 常に利用可能（接続確立後すぐに使用可能）
- 小さなメッセージ（32 bytes）専用
- レイテンシ重視（データ転送は他の Rail）

**実装**:
- 制御メッセージ用の専用バッファプール（pre-allocated）
- 専用の受信バッファ（常に fi_recv がポストされている）
- Progress thread で常時監視

### Rail 1+: データプレーン

**役割**: 実際の KV-Cache データ転送

**特性**:
- 大きなデータ（MB 単位）
- スループット重視

## 実装箇所

### 1. 制御メッセージ構造体の定義

**ファイル**: `/home/coder/nixl/src/utils/libfabric/libfabric_common.h`

```cpp
// 制御メッセージ構造体
struct NixlControlMessage {
    enum Operation {
        READ_REQUEST = 1,
        WRITE_NOTIFY = 2
    };

    uint32_t operation;
    uint32_t request_id;
    uint32_t rail_id;
    uint32_t reserved;
    uint64_t length;
    uint64_t offset;
};

static_assert(sizeof(NixlControlMessage) == 32, "Control message must be 32 bytes");
```

### 2. nixlLibfabricRail の拡張

**ファイル**: `/home/coder/nixl/src/utils/libfabric/libfabric_rail.h`

```cpp
class nixlLibfabricRail {
    // ... 既存のメンバー ...

private:
    // 制御メッセージ用（Rail 0 のみ）
    bool is_control_rail_;                      // Rail 0 かどうか
    NixlControlMessage *ctrl_recv_buffer_;      // 受信用バッファ
    struct fid_mr *ctrl_recv_mr_;               // 受信バッファの MR
    NixlControlMessage *ctrl_send_buffer_;      // 送信用バッファ
    struct fid_mr *ctrl_send_mr_;               // 送信バッファの MR
    std::mutex ctrl_send_mutex_;                // 送信バッファの排他制御

    // 制御メッセージハンドラ
    std::function<void(const NixlControlMessage&)> ctrl_msg_handler_;

public:
    // 制御メッセージハンドラの設定（Producer 側）
    void setControlMessageHandler(std::function<void(const NixlControlMessage&)> handler);

    // 制御メッセージの送信（Consumer 側）
    nixl_status_t sendControlMessage(const NixlControlMessage &msg);

    // 制御メッセージの受信処理（Progress thread から呼ばれる）
    void handleControlMessageCompletion();
};
```

### 3. Consumer: postRead() の修正

**ファイル**: `/home/coder/nixl/src/utils/libfabric/libfabric_rail.cpp`

**既存の実装**:
```cpp
nixl_status_t nixlLibfabricRail::postRead(...) {
    // Two-sided receive (replaces fi_read with fi_recv)
    ret = fi_recv(endpoint, local_buffer, length, local_desc,
                 dest_addr, &req->ctx);
    // ...
}
```

**新しい実装**:
```cpp
nixl_status_t nixlLibfabricRail::postRead(
    void *local_buffer,
    size_t length,
    void *local_desc,
    fi_addr_t dest_addr,
    nixlLibfabricReq *req) {

    // (1) データ用 Rail で受信バッファをポスト
    req->operation_type = nixlLibfabricReq::READ;
    ret = fi_recv(endpoint, local_buffer, length, local_desc,
                 dest_addr, &req->ctx);
    if (ret) {
        NIXL_ERROR << "fi_recv failed: " << fi_strerror(-ret);
        return NIXL_ERR_BACKEND;
    }

    // (2) Rail 0 (制御プレーン) で READ 要求を送信
    nixlLibfabricRail *ctrl_rail = rail_manager->getRail(0);
    if (!ctrl_rail) {
        NIXL_ERROR << "Control rail not found";
        return NIXL_ERR_BACKEND;
    }

    NixlControlMessage ctrl_msg = {};
    ctrl_msg.operation = NixlControlMessage::READ_REQUEST;
    ctrl_msg.request_id = req->xfer_id;  // グローバルに一意な ID
    ctrl_msg.rail_id = this->rail_id;    // このデータ Rail の ID
    ctrl_msg.length = length;
    ctrl_msg.offset = 0;

    nixl_status_t status = ctrl_rail->sendControlMessage(ctrl_msg);
    if (status != NIXL_SUCCESS) {
        NIXL_ERROR << "Failed to send control message";
        // fi_recv をキャンセルする必要がある（TODO）
        return status;
    }

    NIXL_DEBUG << "Posted READ: rail=" << rail_id
               << " request_id=" << req->xfer_id
               << " length=" << length;

    return NIXL_SUCCESS;
}
```

### 4. Producer: Progress thread での制御メッセージ処理

**ファイル**: `/home/coder/nixl/src/utils/libfabric/libfabric_rail.cpp`

**Progress thread に追加**:

```cpp
nixl_status_t nixlLibfabricRail::progressCompletionQueue() {
    struct fi_cq_data_entry comps[LF_CQ_BATCH_SIZE];
    int ret = fi_cq_read(cq, comps, LF_CQ_BATCH_SIZE);

    if (ret > 0) {
        for (int i = 0; i < ret; i++) {
            struct fi_cq_data_entry &comp = comps[i];

            // 制御メッセージの completion かチェック
            if (is_control_rail_ && comp.op_context == ctrl_recv_buffer_) {
                // 制御メッセージ受信完了
                handleControlMessageCompletion();

                // 次の制御メッセージ受信をポスト
                fi_recv(endpoint, ctrl_recv_buffer_, sizeof(NixlControlMessage),
                       fi_mr_desc(ctrl_recv_mr_), FI_ADDR_UNSPEC, ctrl_recv_buffer_);
                continue;
            }

            // 通常のデータ completion 処理
            // ... 既存のコード ...
        }
    }

    return NIXL_SUCCESS;
}

void nixlLibfabricRail::handleControlMessageCompletion() {
    if (!ctrl_msg_handler_) {
        NIXL_WARN << "Control message received but no handler set";
        return;
    }

    // コピーしてハンドラに渡す（受信バッファは再利用される）
    NixlControlMessage msg = *ctrl_recv_buffer_;

    NIXL_DEBUG << "Control message received: op=" << msg.operation
               << " request_id=" << msg.request_id
               << " rail_id=" << msg.rail_id
               << " length=" << msg.length;

    // ハンドラ実行（別の Rail でデータ送信を実行）
    ctrl_msg_handler_(msg);
}
```

### 5. Producer: 制御メッセージハンドラの実装

**ファイル**: `/home/coder/nixl/src/utils/libfabric/libfabric_rail_manager.cpp`

```cpp
void nixlLibfabricRailManager::setupControlMessageHandler() {
    nixlLibfabricRail *ctrl_rail = getRail(0);
    if (!ctrl_rail) {
        NIXL_ERROR << "Control rail not found";
        return;
    }

    // ラムダでハンドラを設定
    ctrl_rail->setControlMessageHandler(
        [this](const NixlControlMessage &msg) {
            handleReadRequest(msg);
        }
    );
}

void nixlLibfabricRailManager::handleReadRequest(const NixlControlMessage &msg) {
    if (msg.operation != NixlControlMessage::READ_REQUEST) {
        NIXL_WARN << "Unknown control message operation: " << msg.operation;
        return;
    }

    NIXL_DEBUG << "Processing READ_REQUEST: request_id=" << msg.request_id
               << " rail_id=" << msg.rail_id
               << " length=" << msg.length;

    // (1) 指定された Rail を取得
    nixlLibfabricRail *data_rail = getRail(msg.rail_id);
    if (!data_rail) {
        NIXL_ERROR << "Data rail not found: " << msg.rail_id;
        return;
    }

    // (2) 送信するデータを特定
    // NOTE: request_id を使って、どのバッファを送信するか特定する必要がある
    // これは connection レベルで管理されているため、connection に委譲
    nixlLibfabricConnection *conn = getConnectionForRequest(msg.request_id);
    if (!conn) {
        NIXL_ERROR << "Connection not found for request_id=" << msg.request_id;
        return;
    }

    // (3) データ送信
    conn->sendDataForReadRequest(msg);
}
```

### 6. データ送信の実装

**ファイル**: `/home/coder/nixl/src/utils/libfabric/libfabric_connection.cpp`

```cpp
void nixlLibfabricConnection::sendDataForReadRequest(const NixlControlMessage &msg) {
    // (1) 送信するバッファを特定
    // NOTE: これは Producer 側で管理している送信バッファマップから取得
    void *send_buffer = getSendBufferForRequest(msg.request_id);
    if (!send_buffer) {
        NIXL_ERROR << "Send buffer not found for request_id=" << msg.request_id;
        return;
    }

    // (2) 指定された Rail でデータ送信
    nixlLibfabricRail *rail = rail_manager_->getRail(msg.rail_id);
    if (!rail) {
        NIXL_ERROR << "Rail not found: " << msg.rail_id;
        return;
    }

    // (3) fi_senddata で送信（immediate data に request_id を含める）
    nixlLibfabricReq *req = rail->allocateRequest();
    if (!req) {
        NIXL_ERROR << "Failed to allocate request";
        return;
    }

    req->operation_type = nixlLibfabricReq::WRITE;  // WRITE として扱う
    req->xfer_id = msg.request_id;

    int ret = fi_senddata(rail->endpoint,
                         send_buffer,
                         msg.length,
                         fi_mr_desc(send_buffer_mr),
                         msg.request_id,  // immediate data
                         remote_addr,
                         &req->ctx);

    if (ret) {
        NIXL_ERROR << "fi_senddata failed: " << fi_strerror(-ret);
        rail->releaseRequest(req);
        return;
    }

    NIXL_DEBUG << "Data sent for READ_REQUEST: request_id=" << msg.request_id
               << " rail=" << msg.rail_id
               << " length=" << msg.length;
}
```

## 初期化フロー

### Producer 側

```cpp
// nixlLibfabricEngine::initialize()
void nixlLibfabricEngine::initialize() {
    // ... 既存の初期化 ...

    // Rail Manager に制御メッセージハンドラを設定
    rail_manager_->setupControlMessageHandler();
}
```

### Consumer 側

```cpp
// 特別な初期化は不要
// postRead() が呼ばれたときに自動的に制御メッセージを送信
```

## エラーハンドリング

### タイムアウト

Consumer が制御メッセージを送信したが、Producer からデータが返ってこない場合：

- 既存の NIXL タイムアウトメカニズムを使用
- `check_xfer_state()` が TIMEOUT を返す

### 制御メッセージの送信失敗

- fi_recv をキャンセルする必要がある（要実装）
- または、タイムアウトで自然に処理される

## パフォーマンス考慮事項

### レイテンシ

- **追加コスト**: 制御メッセージ 1 RTT（Rail 0）
- **推定**: 1-5 μs（EFA の typical latency）
- **影響**: 小（KV-Cache 転送全体のレイテンシに比べて無視できる）

### スループット

- Rail 0 は小さなメッセージ専用
- データ転送は他の Rail で並列実行
- **影響**: なし（パイプライン化可能）

### メモリオーバーヘッド

- 制御メッセージバッファ: 32 bytes × 2（送信/受信） × Rails = 数百 bytes
- **影響**: 無視できる

## 代替設計

### オプション A: Inline 制御情報（不採用）

データ転送と制御情報を同じ Rail で送受信：

- メリット: シンプル
- デメリット: データ転送のプロトコルが複雑化、パフォーマンス低下

### オプション B: ZMQ で制御メッセージ（不採用）

ZMQ side channel を制御プレーンとして使用：

- メリット: 既存インフラを活用
- デメリット: レイテンシが高い（TCP）、RDMA のメリットが失われる

### オプション C: Rail 0 専用（採用）

**理由**:
- RDMA のレイテンシメリットを活用
- 制御プレーンとデータプレーンの分離
- 実装がクリーン

## テスト計画

### ユニットテスト

1. 制御メッセージの送受信
2. READ_REQUEST の処理
3. エラーハンドリング

### 統合テスト

1. Producer/Consumer 間の READ 操作
2. 複数の同時 READ 要求
3. タイムアウト処理

### E2E テスト

1. vLLM disaggregated inference
2. 実際の KV-Cache 転送
3. パフォーマンスベンチマーク

## まとめ

Request/Response プロトコルの実装により、Two-sided messaging 環境で Consumer の READ 要求を実現します。

- **制御プレーン**: Rail 0（小さな制御メッセージ）
- **データプレーン**: Rail 1+（大きなデータ転送）
- **レイテンシ**: 1 RTT 追加（1-5 μs）
- **実装箇所**: NIXL の libfabric backend
