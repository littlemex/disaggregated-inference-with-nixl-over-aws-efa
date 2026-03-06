# NIXL 内部実装分析 - Two-Sided Messaging の動作メカニズム

**調査日**: 2026-03-05
**調査者**: Opus 4.6 (Task #5)
**対象コード**: Node2 `/tmp/nixl/src/utils/libfabric/` + `/tmp/nixl/src/plugins/libfabric/`

---

## 1. Progress Thread の動作

### 1.1 起動

progress thread は `nixlLibfabricEngine` のコンストラクタ内で起動される（`libfabric_backend.cpp:390-400`）。

```cpp
if (progress_thread_enabled_) {
    progress_thread_stop_ = false;
    progress_thread_ = std::thread(&nixlLibfabricEngine::progressThread, this);
}
```

`enableProgTh` は `nixlBackendInitParams` から渡され、vLLM の NixlConnector が NIXL エンジンを初期化する際に設定される。

### 1.2 メインループ

progress thread のメインループ（`libfabric_backend.cpp:1397-1417`）:

```
while (!progress_thread_stop_) {
    status = rail_manager.progressActiveRails();
    if (completions なし) {
        sleep(progress_thread_delay_);
    }
}
```

`progressActiveRails()`（`libfabric_rail_manager.cpp:908-948`）は:
1. active_rails_ セット + rail 0 を常に含むリストを作成
2. 各 rail の `progressCompletionQueue()` を呼び出し
3. CQ（Completion Queue）を non-blocking で `fi_cq_read()` でポーリング

### 1.3 CQ エントリの処理

`progressCompletionQueue()`（`libfabric_rail.cpp:709-763`）:
1. `fi_cq_read(cq, completions, NIXL_LIBFABRIC_CQ_BATCH_SIZE)` で最大 16 エントリを読み取り
2. 各エントリを `processCompletionQueueEntry()` で処理

`processCompletionQueueEntry()`（`libfabric_rail.cpp:767-832`）は completion の flags によってルーティング:

| flags | ハンドラ | 用途 |
|-------|---------|------|
| FI_SEND | `processLocalSendCompletion` | fi_senddata の送信完了（control + data） |
| FI_RECV | `processRecvCompletion` | fi_recvmsg / fi_recv の受信完了 |
| FI_WRITE | `processLocalTransferCompletion("write")` | fi_writedata の書込完了 |
| FI_READ | `processLocalTransferCompletion("read")` | fi_read の読取完了 |
| FI_REMOTE_WRITE / FI_REMOTE_CQ_DATA | `processRemoteWriteCompletion` | リモート書込到着通知 |

---

## 2. Consumer の NIXL_READ が Producer の NIXL_WRITE をトリガーする仕組み

### 2.1 One-Sided RDMA の場合（公式 NIXL）

One-Sided RDMA では、Consumer が `fi_read()` を呼ぶと:
1. Consumer が Producer のメモリを直接読み取る
2. Producer 側では何もしない（メモリ領域が登録されているだけ）
3. Consumer の CQ に FI_READ completion が到着

**この方式は EFA 上では動作しない**（`max_qp_rd_atom=0` のため、EFA provider 内部でエミュレーションされるが、リモート側が recv を posting していないため EAGAIN ループに陥る）。

### 2.2 Two-Sided Messaging の場合（パッチ適用版）

[重要な発見] **Two-Sided パッチでは Consumer の READ は Producer の WRITE を自動トリガーしない。**

パッチは以下の変換のみを行っている:
- `postWrite()` 内: `fi_writedata()` -> `fi_senddata()`（Producer 側の送信）
- `postRead()` 内: `fi_read()` -> `fi_recv()`（Consumer 側の受信）

**しかし、NIXL のアーキテクチャでは READ と WRITE は独立した操作であり、Consumer の `fi_recv()` が Producer の `fi_senddata()` を「トリガー」するメカニズムは存在しない。**

### 2.3 NIXL の実際のデータフロー（設計意図）

vLLM NixlConnector から見た正常な KV-Cache 転送フロー:

```
1. Proxy が Producer に Prefill リクエストを送信
2. Producer が Prefill 完了後、KV-Cache をバッファに保持
3. Proxy が Consumer に Decode リクエストを送信（kv_transfer_params 付き）
4. Consumer の NixlConnector が NIXL_READ (postXfer with NIXL_READ) を実行
5. NIXL バックエンドが各 descriptor に対して postRead (fi_recv) を呼ぶ
6. [ここで問題] Consumer は fi_recv() でデータ受信を待つが、
   Producer は fi_senddata() を呼ばないため、データが来ない
```

### 2.4 One-Sided RDMA が機能する理由

One-sided RDMA では:
- Consumer が `fi_read()` を呼ぶと、ハードウェアが Producer のメモリに直接アクセス
- Producer 側のソフトウェアは関与不要（メモリ登録のみ）
- Consumer の CQ に FI_READ completion が到着

Two-sided では:
- Consumer が `fi_recv()` を呼ぶと、受信バッファがポストされるだけ
- Producer 側が明示的に `fi_senddata()` を呼ばない限り、データは転送されない
- **NIXL の設計には、「Consumer の READ 要求を受けて Producer が WRITE する」ための明示的なコーディネーションメカニズムがない**

---

## 3. Side Channel (port 50100) の通知メカニズム

### 3.1 Side Channel の役割

NIXL の side channel (port 50100) は **vLLM レベルの機構**であり、NIXL バックエンド自身とは別物である。

vLLM の `NixlConnector` が以下の目的で使用:
- Producer/Consumer 間のメタデータ交換（KV-Cache バッファアドレス、キー情報）
- 接続確立のためのエンドポイント名交換

**`VLLM_NIXL_SIDE_CHANNEL_HOST` / `VLLM_NIXL_SIDE_CHANNEL_PORT` で設定される。**

### 3.2 Side Channel が ESTABLISHED にならない問題

README2.md の記載通り、両ノードとも LISTEN のみで ESTABLISHED 接続がない。

これは以下のいずれかを意味する:
1. vLLM の NixlConnector がまだ `loadRemoteConnInfo()` を呼んでいない
2. Proxy から Consumer へのリクエスト中に初めて接続が試行される
3. セキュリティグループ or ネットワーク設定で port 50100 がブロックされている

### 3.3 NIXL バックエンド内の通知メカニズム

NIXL バックエンド内の「通知」は side channel とは異なり、**LIBFABRIC rail 0 を通じた fi_senddata/fi_recvmsg による制御メッセージ**である。

制御メッセージの種類（`libfabric_common.h`）:
- `NIXL_LIBFABRIC_MSG_NOTIFICTION` (=2): 転送完了通知
- `NIXL_LIBFABRIC_MSG_TRANSFER` (=4): データ転送の到着通知

通知は `postControlMessage()` -> `postSend()` で rail 0 経由で送信される。

---

## 4. postWrite / postRead の呼び出しタイミング

### 4.1 postWrite の呼び出しチェーン

```
vLLM NixlConnector -> NIXL API (nixl_xfer)
  -> nixlLibfabricEngine::postXfer(operation=NIXL_WRITE, ...)
    -> rail_manager.prepareAndSubmitTransfer(op_type=WRITE, ...)
      -> rails_[rail_id]->postWrite(...)
        -> fi_senddata(endpoint, local_buffer, length, ...)  [パッチ適用後]
```

**タイミング**: Producer が vLLM から NIXL_WRITE 操作を指示されたときに呼ばれる。

### 4.2 postRead の呼び出しチェーン

```
vLLM NixlConnector -> NIXL API (nixl_xfer)
  -> nixlLibfabricEngine::postXfer(operation=NIXL_READ, ...)
    -> rail_manager.prepareAndSubmitTransfer(op_type=READ, ...)
      -> rails_[rail_id]->postRead(...)
        -> fi_recv(endpoint, local_buffer, length, ...)  [パッチ適用後]
```

**タイミング**: Consumer が vLLM から NIXL_READ 操作を指示されたときに呼ばれる。

### 4.3 通知メッセージの送信タイミング

NIXL_WRITE の場合（`libfabric_backend.cpp:1087-1098`）:
```
postXfer 内で全 descriptor のサブミット完了後、
has_notif && operation == NIXL_WRITE の場合に notifSendPriv() を即座に呼び出し
```

NIXL_READ の場合（`libfabric_backend.cpp:1112-1122`）:
```
postXfer 内で転送完了を即座に確認し、
is_completed() && has_notif && operation == NIXL_READ の場合に notifSendPriv() を呼び出し
```

---

## 5. fi_senddata / fi_recv のペアリング方法

### 5.1 制御メッセージのペアリング（正常動作）

**送信側**（`postSend()` - `libfabric_rail.cpp:1010-1075`）:
```cpp
fi_senddata(endpoint, req->buffer, req->buffer_size, desc,
            immediate_data, dest_addr, &req->ctx);
```

**受信側**（`postRecv()` - `libfabric_rail.cpp:976-1008`）:
- 初期化時に `NIXL_LIBFABRIC_RECV_POOL_SIZE` (1024) 個の recv を pre-post
- 受信完了後に `processRecvCompletion()` が新しい recv を再 post

ペアリングは RDM (Reliable Datagram) エンドポイントの fi_av_insert で挿入されたアドレスで行われる。

### 5.2 データ転送のペアリング（問題箇所）

パッチ適用後:
- **postWrite (Producer 側)**: `fi_senddata()` でデータを送信
- **postRead (Consumer 側)**: `fi_recv()` でデータを受信

[重大な問題] `fi_recv()` は EFA RDM エンドポイントの受信キューにバッファをポストする。
しかし:

1. **fi_recv の引数に `dest_addr` が渡されている**が、`fi_recv()` は送信先アドレスを受け取らない。libfabric の `fi_recv()` API は `(endpoint, buf, len, desc, src_addr, context)` であり、第 5 引数は `src_addr`（受信フィルタ）。ここに `dest_addr` が渡されているため、意図しないフィルタリングが発生する可能性がある。

2. **fi_recv は pre-post（事前にバッファを用意）が必要**。現在の実装では、データ転送用の `postRead()` が呼ぶ `fi_recv()` は、制御メッセージ用のものとは別のタイミングで呼ばれる。Producer の `fi_senddata()` がまだ実行されていない場合、Consumer の `fi_recv()` は待機するが、Producer 側には受信トリガーがない。

---

## 6. 根本原因の分析

### 6.1 Two-Sided パッチの根本的な設計問題

**One-sided RDMA のアーキテクチャ**:
```
Consumer: fi_read(remote_addr, remote_key) -> ハードウェアが直接 Producer のメモリを読む
Producer: 何もしない (パッシブ)
```

**Two-sided messaging パッチの変換**:
```
Consumer: fi_recv(buffer) -> 受信バッファをポスト (パッシブ、待機)
Producer: fi_senddata(buffer) -> データを送信 (アクティブ)
```

**問題**: One-sided RDMA では Consumer が能動的に読み取るが、Two-sided では Producer が能動的に送信する必要がある。パッチは API 呼び出しを機械的に置換しただけで、**読み取り主導（pull model）から書き込み主導（push model）への設計変更**を行っていない。

### 6.2 Consumer の「128 descriptors submitted」の意味

Consumer ログの `submitted 128 requests from 128 descriptors for xfer_id1025` は:
1. `postXfer(operation=NIXL_READ, ...)` が呼ばれた
2. 128 個の descriptor それぞれに対して `postRead()` -> `fi_recv()` が成功（リターン 0）
3. fi_recv は受信バッファをエンドポイントにポストしただけ
4. **データは到着していない** -- Producer が fi_senddata を呼んでいないため

### 6.3 Producer が応答しない理由

Producer 側では:
1. Prefill は正常に完了（KV-Cache がバッファに保持される）
2. **vLLM の NixlConnector が Producer に対して `postXfer(operation=NIXL_WRITE)` を呼ばない**
3. NIXL の標準アーキテクチャでは、Consumer が READ を実行することで KV-Cache を取得する
4. Producer は WRITE 操作を自発的に行わない

### 6.4 メモリ登録フラグの不一致（追加発見）

Node2 上の `libfabric_rail.cpp:1238-1247` の `registerMemory()` 関数を確認すると:

```cpp
// Determine access flags based on provider capabilities
uint64_t provider_access_flags;
if (provider_name == "tcp" || provider_name == "sockets") {
    provider_access_flags = FI_READ | FI_WRITE | FI_REMOTE_READ | FI_REMOTE_WRITE;
} else {
    // EFA and other providers use standard remote access flags
    provider_access_flags = FI_REMOTE_WRITE | FI_REMOTE_READ;
}
```

**パッチの Change 5/6 が registerMemory 関数に適用されていない。** パッチは行番号ベースの `sed` で適用されたため、ソースコードの変更後に行番号がずれた可能性がある。

EFA provider でメモリを `FI_REMOTE_WRITE | FI_REMOTE_READ` で登録しているが、Two-sided messaging では `FI_SEND | FI_RECV` で登録すべきである。ただし、EFA provider は `fi_mr_regattr` の access flags に対して柔軟に対応するため、これは直接的なエラー原因ではない可能性もある。

---

## 7. 結論と推奨事項

### 7.1 根本原因

Two-sided messaging パッチは **API の機械的な置換** に留まっており、NIXL のデータフローモデルを変更していない:

1. **NIXL は「Consumer が READ する」pull model**: Consumer の NixlConnector が `NIXL_READ` を発行して KV-Cache を取得する設計
2. **Two-sided messaging は「Producer が SEND する」push model**: Producer が明示的にデータを送信する必要がある
3. **パッチはこのギャップを埋めていない**: Consumer が `fi_recv()` で待っていても、Producer に送信を指示するメカニズムがない

### 7.2 解決に必要なアプローチ

Two-sided messaging を正しく機能させるには、以下のいずれかが必要:

**方法 A: Pull -> Push 変換レイヤーの追加**
- Consumer が READ を要求する際に、NIXL の制御チャネル（rail 0 の fi_senddata/fi_recvmsg）を使って Producer に「送信要求」通知を送る
- Producer が通知を受信し、対応するバッファの内容を fi_senddata で Consumer に送信
- Consumer の fi_recv が完了し、データ転送が完了

**方法 B: vLLM 側でフロー変更**
- vLLM の Proxy/NixlConnector を変更し、Consumer の READ の代わりに Producer の WRITE を使用
- Producer が Prefill 完了後に自発的に KV-Cache を Consumer に書き込む
- これは NIXL の設計思想に合っていない可能性がある

**方法 C: One-sided RDMA を修正して動作させる**
- EFA の fi_read EAGAIN 問題の根本原因（受信バッファの pre-post 不足）を解決
- EFA provider の RDMA emulation を正しく機能させる

### 7.3 Side Channel の問題

Side channel (port 50100) が ESTABLISHED にならない問題は、NIXL バックエンドの問題とは独立している可能性がある。ただし、side channel が接続されていない場合、vLLM 側のメタデータ交換（バッファアドレス、キー情報）が完了しておらず、そもそも転送が開始できない可能性もある。これは別途調査が必要。

---

## 付録: ソースファイル一覧

| ファイル | 行数 | 役割 |
|---------|------|------|
| `libfabric_backend.cpp` | 1611 | NIXL バックエンドエンジン（progress thread、postXfer、通知処理） |
| `libfabric_backend.h` | 599 | エンジンのクラス定義（メタデータ、接続、リクエストハンドル） |
| `libfabric_rail.cpp` | 1483 | 個別 rail の操作（CQ 処理、postWrite/Read/Send/Recv、メモリ登録） |
| `libfabric_rail.h` | 399 | rail のクラス定義（リクエストプール） |
| `libfabric_rail_manager.cpp` | 1625 | マルチ rail 管理（トポロジ、ストライピング、転送サブミット） |
| `libfabric_rail_manager.h` | 382 | rail manager のクラス定義 |
| `libfabric_common.h` | 327 | 共通定義（マクロ、定数、BinaryNotification） |
| `libfabric_common.cpp` | 301 | ユーティリティ関数 |

---

**最終更新**: 2026-03-05
