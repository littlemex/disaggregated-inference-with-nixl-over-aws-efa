# Two-Sided NIXL 初期化フロー分析

**調査日**: 2026-03-05
**調査者**: initialization-analyst (Opus 4.6)
**対象**: NIXL LIBFABRIC バックエンド + vLLM nixl_connector.py

---

## 1. 初期化フロー全体像

### 1.1 NIXL LIBFABRIC バックエンドの初期化シーケンス

```
[Node 起動]
  |
  v
nixlLibfabricEngine::nixlLibfabricEngine()  -- バックエンドインスタンス化
  |
  +-- nixlLibfabricRail::nixlLibfabricRail()  -- 各 rail の初期化
  |     |
  |     +-- fi_allocinfo() / hints 設定
  |     |     hints->caps = FI_MSG | FI_HMEM  (two-sided パッチ版)
  |     |     hints->ep_attr->type = FI_EP_RDM
  |     |     hints->domain_attr->mr_mode = FI_MR_LOCAL | FI_MR_HMEM | FI_MR_VIRT_ADDR
  |     |                                   | FI_MR_ALLOCATED | FI_MR_PROV_KEY
  |     |
  |     +-- fi_getinfo()  -- EFA provider 検出
  |     +-- fi_fabric()   -- fabric 作成
  |     +-- fi_domain()   -- domain 作成
  |     +-- fi_cq_open()  -- CQ 作成 (FI_CQ_FORMAT_DATA, FI_WAIT_NONE)
  |     +-- fi_av_open()  -- AV 作成
  |     +-- fi_endpoint() -- endpoint 作成
  |     +-- fi_ep_bind(cq, FI_TRANSMIT | FI_RECV)
  |     +-- fi_ep_bind(av)
  |     +-- fi_setopt(EFA_RNR_RETRY=7)  -- RNR リトライ設定
  |     +-- fi_enable()   -- endpoint 有効化
  |     +-- fi_getname()  -- endpoint 名取得
  |     |
  |     +-- control_request_pool_.initialize(domain)
  |     +-- data_request_pool_.initialize()
  |     |
  |     +-- [重要] Pre-posting recv requests
  |           for i in NIXL_LIBFABRIC_RECV_POOL_SIZE:
  |             allocateControlRequest()
  |             postRecv(recv_req)  -- fi_recvmsg() で受信バッファを事前投入
  |
  +-- createAgentConnection(localAgent)  -- 自己接続の作成
  |
  +-- progress_thread_ 開始  -- CQ を継続的にポーリング
```

### 1.2 vLLM 側の初期化シーケンス

```
[vLLM 起動]
  |
  v
NixlConnectorWorker.__init__()
  |
  +-- NixlWrapper(uuid, config)  -- NIXL Agent 作成
  |     config.backends = ["LIBFABRIC"]
  |
  v
register_kv_caches()
  |
  +-- nixl_wrapper.get_reg_descs(caches_data, "DRAM")
  +-- nixl_wrapper.register_memory(descs, backends=["LIBFABRIC"])
  |     -> nixlLibfabricEngine::registerMem()
  |        -> rail.registerMemory(buffer, length, DRAM_SEG, ...)
  |           -> fi_mr_regattr()  -- メモリ登録
  |              access = FI_REMOTE_WRITE | FI_REMOTE_READ  [問題箇所 1]
  |
  +-- prep_xfer_dlist() でローカル転送ハンドル作成
  |
  +-- xfer_handshake_metadata を構築してスケジューラに送信
  |     (agent_metadata + engine_id + kv_caches_base_addr + ...)
  |
  v
NixlConnectorScheduler.set_xfer_handshake_metadata()
  |
  +-- _nixl_handshake_listener スレッド開始
        ZMQ ROUTER ソケットを side_channel_port で LISTEN
        -> これが port 50100 の LISTEN 状態の正体
```

### 1.3 ハンドシェイク（Consumer -> Producer 接続確立）

```
[Consumer がリクエスト受信]
  |
  v
start_load_kv() -> _background_nixl_handshake()
  |
  +-- _nixl_handshake(host, port, remote_tp_size, engine_id)
  |     |
  |     +-- ZMQ REQ ソケットで Producer の port 50100 に接続
  |     |     -> GET_META_MSG 送信
  |     |     -> NixlHandshakePayload 受信
  |     |
  |     +-- add_remote_agent(metadata)
  |           |
  |           +-- nixl_wrapper.add_remote_agent(agent_metadata)
  |           |     -> nixlAgent::loadRemoteMD()
  |           |        -> loadConnInfo(remote_agent, "LIBFABRIC", conn_info)
  |           |           -> nixlLibfabricEngine::loadRemoteConnInfo()
  |           |              -> rail_manager.deserializeConnectionInfo()
  |           |                 -> AV にリモートエンドポイントアドレスを挿入
  |           |              -> createAgentConnection(remote_agent)
  |           |                 -> rail_manager.insertAllAddresses()
  |           |                    -> fi_av_insert() でリモートアドレスを AV に登録
  |           |
  |           +-- nixl_wrapper.get_xfer_descs() / prep_xfer_dlist()
  |                 -> リモートブロックの転送記述子を準備
  |
  v
_read_blocks()
  |
  +-- nixl_wrapper.make_prepped_xfer("READ", ...)
  |     -> nixlAgent::makeXferReq()
  |        -> backend->prepXfer() -- 転送準備
  |
  +-- nixl_wrapper.transfer(handle)
        -> nixlAgent::postXferReq()
           -> nixlLibfabricEngine::postXfer()
              -> establishConnection(remote_agent)  -- 遅延接続
              |    接続状態を CONNECTED に設定
              |
              -> rail_manager.prepareAndSubmitTransfer(READ, ...)
                 -> rail.postRead(local_buffer, length, desc, dest_addr, ...)
                    -> fi_recv(endpoint, local_buffer, length, desc, dest_addr, &ctx)
                       [two-sided パッチ版]
```

---

## 2. メモリ登録フラグの確認

### 2.1 現在のコード（パッチ適用版 libfabric_rail.cpp）

**hints->caps（行 414）**:
```cpp
hints->caps = FI_MSG | FI_HMEM;  // [OK] パッチ適用済み、FI_RMA なし
```

**メモリ登録フラグ（行 1239-1247）**:
```cpp
// registerMemory() 内
if (provider_name == "tcp" || provider_name == "sockets") {
    provider_access_flags = FI_READ | FI_WRITE | FI_REMOTE_READ | FI_REMOTE_WRITE;
} else {
    // EFA and other providers use standard remote access flags
    provider_access_flags = FI_REMOTE_WRITE | FI_REMOTE_READ;  // [問題箇所 1]
}
```

**[問題箇所 1] の分析**:

README2.md のパッチ説明では、行 1253 と 1256 で以下の変更が必要とされている:
- `FI_READ | FI_WRITE | FI_REMOTE_READ | FI_REMOTE_WRITE` -> `FI_SEND | FI_RECV`
- `FI_REMOTE_WRITE | FI_REMOTE_READ` -> `FI_SEND | FI_RECV`

しかし、現在のソースコードでは EFA の場合 `FI_REMOTE_WRITE | FI_REMOTE_READ` のままになっている。
これは registerMemory() 内のメモリ登録フラグが**パッチ未適用**である可能性を示す。

ただし、Node1 のソースは `/tmp/nixl` であり、実際にビルド・インストールされたバイナリとは異なる可能性がある。ビルド前に sed でパッチを適用しているが、ソースツリーには反映されていない場合がある。

**確認方法**: ビルド済みバイナリの MD5 が `5841de7b7bc8254cb86922ac8a0f121c` であれば two-sided パッチ適用済み。

### 2.2 Control Request Pool のメモリ登録

```cpp
// ControlRequestPool::initialize(domain)
// control request のバッファは domain に対して fi_mr_regattr() で登録される
// access flags はコントロールプール用に別途設定されている
```

Control request（通知メッセージ用）のメモリ登録は、データ転送とは別のフラグで管理されている。

---

## 3. Side Channel 接続の正体

### 3.1 port 50100 の LISTEN 状態の説明

port 50100 は **NIXL の libfabric 接続ではなく、vLLM の ZMQ ハンドシェイク用** である。

```
Producer (Node1):
  NixlConnectorScheduler._nixl_handshake_listener()
    -> zmq.ROUTER ソケットを tcp://172.31.2.221:50100 で LISTEN
    -> Consumer からの GET_META_MSG を待機

Consumer (Node2):
  NixlConnectorScheduler._nixl_handshake_listener()
    -> zmq.ROUTER ソケットを tcp://172.31.10.117:50100 で LISTEN
    -> 自身も他からのハンドシェイク要求を待機
```

### 3.2 ESTABLISHED 接続が存在しない理由

ZMQ のハンドシェイクは **Consumer が最初のリクエストを受信するまで発生しない**。

1. Producer と Consumer が起動する
2. 両方が port 50100 で LISTEN 開始
3. Proxy 経由でリクエストが来ると:
   - Producer が prefill を実行
   - kv_transfer_params に Producer の情報を含めて Consumer に転送
   - Consumer が `start_load_kv()` で Producer のハンドシェイクを開始
   - Consumer の Worker スレッドが ZMQ REQ で Producer の 50100 に接続 -> ESTABLISHED

**つまり、ESTABLISHED 接続がないのは正常**。単にまだハンドシェイクが開始されていないか、ZMQ 接続が短時間で完了して閉じられたことを意味する。

### 3.3 libfabric レベルの接続

libfabric の「接続」は RDM (Reliable Datagram) エンドポイントを使用しており、TCP のような持続的な接続は存在しない。代わりに:

1. `fi_av_insert()` でリモートのエンドポイントアドレスを AV に登録
2. 以降、`fi_senddata()` / `fi_recv()` で AV のアドレスを使って通信

つまり、libfabric レベルでは ESTABLISHED 接続は不要。

---

## 4. Warmup の必要性

### 4.1 現在の実装のウォームアップ

**事前に確立される接続はない**。vLLM の nixl_connector.py は遅延接続パターンを使用:

1. Consumer が最初のリクエストを受信したときにハンドシェイクを開始
2. `_background_nixl_handshake` でバックグラウンドスレッドを使用
3. ハンドシェイク完了後に `_read_blocks_for_req()` を呼び出し

### 4.2 EFA の場合のウォームアップ要件

EFA では以下の初期化が起動時に完了している:
- fi_fabric / fi_domain / fi_endpoint の作成
- CQ / AV のセットアップ
- Control request pool の recv buffer の pre-posting

ただし、**最初の通信時に追加のセットアップオーバーヘッドがある可能性**:
- EFA provider 内部での接続確立（SRD レベル）
- RNR (Receiver Not Ready) リトライの初回発生

### 4.3 aws-ofi-nccl の参考パターン

aws-ofi-nccl は EFA 上で fi_senddata/fi_recv を使用し、以下のウォームアップを行う:
- 通信前に recv buffer を pre-post する（NIXL でも実装済み）
- 最初の send/recv で SRD 接続が確立される
- RNR リトライメカニズムで初回の失敗を許容

NIXL の現在の実装では:
- Control recv buffer は pre-post 済み（rail 初期化時）
- Data recv buffer は **pre-post されていない**（これが問題）

---

## 5. 現在の実装で不足している初期化ステップ

### 5.1 [致命的] Two-Sided Messaging の根本的設計問題

**One-sided RDMA のフロー（正常動作）**:
```
Consumer: fi_read(producer_memory) -> Producer メモリから直接読み取り
                                      Producer 側のアクションは不要
```

**Two-sided Messaging のフロー（パッチ版）**:
```
Consumer: fi_recv(buffer) -> ローカルバッファで受信を待機
          ??? -> Producer に「データを送ってくれ」という通知が必要
Producer: fi_senddata(buffer) -> Consumer にデータを送信
```

**根本的問題**:
two-sided messaging では Consumer の `fi_recv()` は「受信準備完了」を意味するだけで、Producer に自動的に通知は送られない。Producer が能動的に `fi_senddata()` を呼ぶ必要があるが、**現在のパッチは API を置換しただけで、フローの制御を変更していない**。

具体的には:

1. Consumer が `postXfer(READ, ...)` を呼ぶ
2. NIXL バックエンドが `postRead()` を呼ぶ -> `fi_recv()` に変換
3. `fi_recv()` はローカルバッファに受信バッファを posting するだけ
4. **Producer に通知が送られない**
5. Producer は Consumer が何を要求しているか知らない
6. Producer の `postWrite()` / `fi_senddata()` は呼ばれない
7. Consumer はデータを永遠に待ち続ける -> タイムアウト

### 5.2 [致命的] データ転送の recv buffer pre-posting がない

Two-sided messaging では、送信側が `fi_senddata()` を発行する前に、受信側が `fi_recv()` で受信バッファを pre-post している必要がある。

現在の実装:
- **Control message 用**: pre-post 済み（rail 初期化時に `NIXL_LIBFABRIC_RECV_POOL_SIZE` 個）
- **Data 転送用**: pre-post なし。`postRead()` (fi_recv) は Consumer が READ を要求したときにのみ呼ばれる

one-sided RDMA では `fi_read()` が即座にリモートメモリにアクセスするため pre-posting は不要だったが、two-sided では必須。

### 5.3 [致命的] postWrite と postRead のセマンティクス不整合

パッチ後のコード:

```cpp
// postWrite (Producer 側で呼ばれる)
ret = fi_senddata(endpoint, local_buffer, length, local_desc,
                  immediate_data, dest_addr, &req->ctx);
// -> fi_senddata は正しいが、remote_addr/remote_key 引数が残っている
//    (関数シグネチャは変更されていない)

// postRead (Consumer 側で呼ばれる)
ret = fi_recv(endpoint, local_buffer, length, local_desc,
              dest_addr, &req->ctx);
// -> fi_recv は正しいが、dest_addr を指定している
//    fi_recv の dest_addr は「特定の送信元からのみ受信」を意味する
```

**問題**: `postRead()` に `dest_addr` と `remote_key` パラメータがまだ渡されているが、`fi_recv()` の場合:
- `dest_addr`: 受信フィルタとして機能（特定の送信元からのみ受信を許可）
- `remote_addr` / `remote_key`: 不要（削除済みのはず）

パッチでは `remote_addr` と `remote_key` 引数を削除したとされているが、関数のシグネチャ自体は変更されていないため、呼び出し元（`prepareAndSubmitTransfer`）がまだこれらの値を渡している。

### 5.4 [重要] メモリ登録フラグの不一致の可能性

パッチ適用の行番号（1253, 1256）が指す箇所と実際のコードが異なる可能性がある。
ソースコードの `registerMemory()` では EFA の場合 `FI_REMOTE_WRITE | FI_REMOTE_READ` が使われているが、two-sided では `FI_SEND | FI_RECV` が必要。

ただし、EFA provider (RDM) では `fi_mr_regattr` のアクセスフラグは無視される場合があるため、これが直接の原因ではない可能性もある。

### 5.5 Completion Queue のフラグ処理

`processCompletionQueueEntry()` では:
- `FI_SEND` -> `processLocalSendCompletion()` -- fi_senddata の完了
- `FI_RECV` -> `processRecvCompletion()` -- fi_recv の完了（制御メッセージのみ）
- `FI_WRITE` -> `processLocalTransferCompletion()` -- fi_writedata の完了
- `FI_READ` -> `processLocalTransferCompletion()` -- fi_read の完了

Two-sided パッチ後:
- `postWrite()` が `fi_senddata()` に変更されたため、完了フラグは `FI_SEND` になる
- `postRead()` が `fi_recv()` に変更されたため、完了フラグは `FI_RECV` になる

**問題**: `FI_RECV` の完了は `processRecvCompletion()` にルーティングされるが、この関数は制御メッセージ（通知）専用に設計されている。データ転送の `fi_recv` 完了を正しく処理できない:
- 制御メッセージフォーマットのデコードを試みる（msg_type, agent_idx, xfer_id）
- データバッファの内容は制御メッセージではないため、パース失敗または誤動作

---

## 6. 根本原因の結論

### 6.1 直接的原因: Producer が fi_senddata を呼ばない

Consumer のログ:
```
Processing complete: submitted 128 requests from 128 descriptors for xfer_id1025
```
-> Consumer は `fi_recv()` を 128 回 posting した

Producer のログ:
```
(postWrite / fi_senddata の呼び出しなし)
```
-> Producer は何も送信していない

### 6.2 根本的原因: one-sided -> two-sided の変換が不完全

単に API を置換（fi_writedata -> fi_senddata, fi_read -> fi_recv）しただけでは two-sided messaging は動作しない。
one-sided RDMA と two-sided messaging は根本的にフローが異なる:

| 観点 | One-Sided RDMA | Two-Sided Messaging |
|------|---------------|-------------------|
| データ移動の主体 | Consumer (fi_read で直接読み取り) | Producer (fi_senddata で能動的に送信) |
| Producer のアクション | なし（メモリ公開のみ） | 必須（fi_senddata 呼び出し） |
| Consumer の要求通知 | 不要（fi_read が直接アクセス） | 必要（通知メカニズムが別途必要） |
| recv buffer pre-posting | 不要 | 必須 |
| CQ 完了フラグ | FI_WRITE / FI_READ | FI_SEND / FI_RECV |

### 6.3 必要な追加実装

Two-sided messaging を正しく動作させるには、以下の追加実装が必要:

1. **通知メカニズムの実装**: Consumer が READ を要求したとき、Producer に「このデータを送ってくれ」という通知を送信するメカニズム
2. **Producer 側の受信・応答ロジック**: Producer が通知を受信し、対応するデータを `fi_senddata` で送信するロジック
3. **データ受信の CQ 処理**: `fi_recv` のデータ転送完了を正しく処理するハンドラ（制御メッセージとは分離）
4. **recv buffer の管理**: Consumer 側でデータ受信用の recv buffer を事前に posting するメカニズム

---

## 7. aws-ofi-nccl との比較

aws-ofi-nccl は EFA 上で fi_senddata/fi_recv を正常に使用している。その設計パターン:

1. **全て sender-initiated**: 送信側が fi_senddata を呼び、受信側が fi_recv を pre-post
2. **両方のエンドポイントが recv buffer を pre-post**: 送受信双方向で通信可能
3. **NCCL の通信パターンに合わせて設計**: send/recv のペアリングが保証されている
4. **flow control**: 送信側は受信側の recv buffer が枯渇しないよう制御

NIXL の two-sided パッチとの違い:
- NCCL は send/recv のペアリングが明示的（両側が協調して呼び出す）
- NIXL は one-sided の「Consumer が主体的に読む」パターンを前提に設計されており、two-sided への変換が構造的に困難

---

## 8. 推奨される解決策

### 8.1 短期的解決策: One-sided RDMA の正常動作を再確認

2026-03-04 に one-sided RDMA で成功している実績があるため:
1. 公式 NIXL (0.10.0) を両ノードに再インストール
2. 03-04 の成功時の設定を正確に再現
3. ベースライン性能を再測定

### 8.2 中期的解決策: 通知ベースの Two-Sided 実装

1. Consumer が READ を要求するとき、NIXL notification (`genNotif`) で Producer に通知
2. Producer が notification を受信し、対応するデータを `postWrite` (fi_senddata) で送信
3. Consumer 側で data recv buffer を pre-post
4. CQ の処理を FI_SEND/FI_RECV 対応に拡張

この方式は大規模な設計変更を伴うため、十分なテストが必要。

### 8.3 長期的解決策: NIXL のアップストリームに EFA two-sided サポートを提案

NVIDIA NIXL チームに EFA の制約と two-sided messaging の必要性を報告し、公式サポートを求める。

---

## 付録: 設定パラメータの確認

### VLLM_NIXL_SIDE_CHANNEL_HOST / PORT

- Producer: `VLLM_NIXL_SIDE_CHANNEL_HOST=172.31.2.221`, `PORT=50100`
- Consumer: `VLLM_NIXL_SIDE_CHANNEL_HOST=172.31.10.117`, `PORT=50100`

各ノードが自身の IP を指定するのは正しい（LISTEN 用のバインドアドレス）。

Consumer が Producer に接続するときは、kv_transfer_params 内の `remote_host` / `remote_port` を使用する。
これは vLLM Proxy が prefill 結果を Consumer に渡すときに含まれる。

### kv_transfer_config パラメータ

| パラメータ | Producer | Consumer | 備考 |
|-----------|----------|----------|------|
| kv_connector | NixlConnector | NixlConnector | 一致 |
| kv_role | kv_producer | kv_consumer | 正しい |
| kv_rank | 0 | 1 | 異なるランク |
| kv_parallel_size | 2 | 2 | 一致（03-04 成功時は 1/2 で不一致だった） |
| kv_buffer_device | cpu | cpu | 一致 |
| kv_buffer_size | 5e9 | 5e9 | 一致 |
| kv_ip | 172.31.10.117 | 172.31.10.117 | 同じ IP（Consumer IP） |
| kv_port | 14579 | 14579 | 一致 |
| backends | ["LIBFABRIC"] | ["LIBFABRIC"] | 一致 |

---

**結論**: Two-sided messaging への変換は API レベルの置換だけでは不十分であり、データフローの根本的な再設計が必要。One-sided RDMA の再現を優先し、two-sided は中長期的な課題として扱うことを推奨する。
