# vLLM nixl_connector.py 実装分析レポート

**対象**: vLLM v0.16.0 `vllm/distributed/kv_transfer/kv_connector/v1/nixl_connector.py`
**分析日**: 2026-03-05
**分析者**: Opus 4.6 (Task #1)

---

## 1. NIXL Side Channel (Port 50100) の接続確立フロー

### 1.1 Side Channel の実体

side channel は **ZMQ (ZeroMQ)** ベースの通信チャネルであり、NIXL ライブラリ自体のポートではない。vLLM が独自に実装したメタデータ交換メカニズム。

**重要**: side channel のデフォルトポートは `5600` であり、`50100` ではない。

```python
# vllm/envs.py (v0.16.0)
VLLM_NIXL_SIDE_CHANNEL_HOST: str = "localhost"
VLLM_NIXL_SIDE_CHANNEL_PORT: int = 5600
```

### 1.2 接続確立フロー（正常系）

```
[Phase 1: Producer 起動時]
  1. NixlConnectorWorker.__init__() で NIXL agent を生成
  2. register_kv_caches() で KV Cache メモリを NIXL に登録
  3. NixlAgentMetadata を構築 (engine_id, agent_metadata, base_addr 等)
  4. NixlHandshakePayload にラップして Worker -> Scheduler に渡す
  5. NixlConnectorScheduler.set_xfer_handshake_metadata() が呼ばれる
  6. _nixl_handshake_listener スレッドが起動
     -> ZMQ ROUTER ソケットを side_channel_host: side_channel_port で BIND (LISTEN)
     -> メタデータリクエストを待機

[Phase 2: Consumer が Prefill リクエスト受信時 (オンデマンド)]
  1. Proxy が Consumer にリクエスト送信 (kv_transfer_params 付き)
  2. Scheduler が update_state_after_alloc() で do_remote_prefill を検出
  3. Worker の start_load_kv() が呼ばれる
  4. remote_engine_id が未知の場合、_background_nixl_handshake() を開始
  5. ThreadPoolExecutor で _nixl_handshake() を実行:
     a. ZMQ REQ ソケットで Producer の side_channel_host: side_channel_port に接続
     b. GET_META_MSG + target_tp_rank を送信
     c. NixlHandshakePayload を受信
     d. compatibility_hash を検証
     e. NixlAgentMetadata をデコード
     f. nixl_wrapper.add_remote_agent() でリモートエージェント登録
     g. リモートブロックの descriptor を prep_xfer_dlist で準備
  6. ハンドシェイク完了後、_read_blocks_for_req() で実際の KV 転送を開始
```

### 1.3 重要なポイント

- **side channel 接続は Consumer -> Producer 方向のみ**（Consumer が REQ、Producer が ROUTER）
- **接続はリクエスト処理時にオンデマンドで確立**される（起動時ではない）
- Producer は LISTEN のみ。Consumer がリクエストを受け取るまで ESTABLISHED にはならない
- **TCP 50100 は NIXL ライブラリ自体が使用するポートの可能性がある**（side channel ではない）
- ZMQ ソケットは一時的（ハンドシェイク中のみ接続、完了後はクローズ）

### 1.4 現状の問題との関連

README2.md に記載の「port 50100 で ESTABLISHED がない」問題は、以下のシナリオが考えられる:

1. **VLLM_NIXL_SIDE_CHANNEL_PORT が 50100 に設定されている場合**: Producer 側は LISTEN しているが、Consumer がまだハンドシェイクを開始していない（= Proxy 経由のリクエストがまだ Worker まで到達していない）
2. **50100 が NIXL ライブラリ内部のポートの場合**: vLLM の side channel とは別のメカニズム

---

## 2. Consumer -> Producer への READ 通知メカニズム

### 2.1 転送の全体フロー

```
Consumer Worker                              Producer Worker
     |                                            |
     |  [1] _read_blocks() で make_prepped_xfer   |
     |       "READ" 操作として準備                  |
     |                                            |
     |  [2] nixl_wrapper.transfer(handle)          |
     |       -> NIXL が非同期 READ 開始             |
     |       -> notif_id = "req_id: tp_size"        |
     |                                            |
     |  [NIXL 内部: データ転送実行]                  |
     |  =====================================>     |
     |                                            |
     |  [3] 転送完了時、NIXL が自動で通知送信        |
     |       -> notif_msg = notif_id              |
     |                                   -------> |
     |                                            |  [4] nixl_wrapper.get_new_notifs()
     |                                            |       で通知を取得
     |                                            |  [5] _get_new_notifs() で req_id を
     |                                            |       パース、ブロック解放判定
```

### 2.2 notif_id の構造

```python
notif_id = f"{remote_request_id}: {self.world_size}".encode()
```

- `remote_request_id`: Producer 側のリクエスト ID
- `self.world_size`: Consumer 側の TP サイズ（heterogeneous TP 対応用）

### 2.3 Producer 側の通知受信処理

```python
def _get_new_notifs(self) -> set[str]:
    for notifs in self.nixl_wrapper.get_new_notifs().values():
        for notif in notifs:
            req_id, tp_size = notif.decode("utf-8").rsplit(": ", 1)
            # ...
            n_consumers = int(tp_size)
            tp_ratio = self.kv_topo.tp_ratio(n_consumers)
            consumers_per_producer = -tp_ratio if n_consumers > self.world_size else 1

            self.consumer_notification_counts_by_req[req_id] += 1
            if self.consumer_notification_counts_by_req[req_id] == consumers_per_producer:
                notified_req_ids.add(req_id)  # ブロック解放可能
```

### 2.4 Full Prefix Cache Hit の場合

転送が不要な場合（全ブロックがキャッシュにある場合）は、`send_notif` のみ送信:

```python
if num_local_blocks == 0:
    agent_name = self._remote_agents[dst_engine_id][remote_rank]
    self.nixl_wrapper.send_notif(agent_name, notif_msg=notif_id)
    return
```

### 2.5 Two-sided との関連

**重要な発見**: vLLM の nixl_connector.py は NIXL の `make_prepped_xfer("READ", ...)` と `transfer()` を使用する。これは NIXL ライブラリ内部で:

- **One-sided (公式版)**: `fi_read()` に変換される（Consumer がリモートメモリを直接読み取り）
- **Two-sided (パッチ版)**: `fi_recv()` に変換される（Consumer が recv を posting）

Two-sided の場合、**Consumer が `fi_recv()` を posting した後、Producer 側の NIXL progress thread がこれを検知して `fi_senddata()` で応答する必要がある**。この検知メカニズムが正しく動作しない場合、Producer は応答しない。

---

## 3. kv_parallel_size と kv_rank が接続確立に与える影響

### 3.1 v0.16.0 での kv_parallel_size / kv_rank の役割

**極めて重要な発見: NixlConnector では kv_parallel_size と kv_rank は使用されていない。**

`kv_transfer.py` (v0.16.0) で定義されているが:

```python
kv_parallel_size: int = 1
"""The number of parallel instances for KV cache transfer. For
P2pNcclConnector, this should be 2."""

kv_rank: int | None = None
"""The rank of this vLLM instance in the KV cache transfer. Typical value:
0 for prefill instance, 1 for decode instance.
Currently only 1P1D is supported."""
```

コメントにも「P2pNcclConnector 用」と明記されている。

### 3.2 NixlConnector で重要なパラメータ

NixlConnector が使用するのは以下:

| パラメータ | 用途 |
|-----------|------|
| `kv_connector` | `"NixlConnector"` |
| `kv_role` | `"kv_both"`, `"kv_producer"`, `"kv_consumer"` (実質的に区別なし) |
| `kv_buffer_device` | `"cpu"` or `"cuda"` |
| `kv_connector_extra_config.backends` | `["LIBFABRIC"]` etc. |
| `VLLM_NIXL_SIDE_CHANNEL_HOST` (env) | 自身の IP アドレス |
| `VLLM_NIXL_SIDE_CHANNEL_PORT` (env) | side channel ポート (default: 5600) |

### 3.3 engine_id の重要性

NixlConnector はインスタンスの識別に `engine_id` を使用する（UUID で自動生成）:

```python
def __post_init__(self) -> None:
    if self.engine_id is None:
        self.engine_id = str(uuid.uuid4())
```

Producer と Consumer は engine_id で互いを識別し、ハンドシェイクで交換する。

### 3.4 TP (Tensor Parallel) サイズの伝播

TP サイズは `kv_parallel_size` ではなく、以下の経路で伝播:

1. Producer の `request_finished()` が `kv_transfer_params` に `tp_size` を含める:
   ```python
   return delay_free_blocks, dict(
       tp_size=self.vllm_config.parallel_config.tensor_parallel_size,
       ...
   )
   ```
2. Proxy 経由で Consumer に転送
3. Consumer の Worker が `meta.tp_size` として受け取り、ハンドシェイク時にリモート TP サイズとして使用

### 3.5 現在の設定の問題

現在の設定:
```json
{
    "kv_parallel_size": 2,
    "kv_rank": 0
}
```

これらは NixlConnector では無視されるため、**直接的な悪影響はない**。ただし、v0.16.0 のドキュメントでは `kv_role: "kv_both"` を推奨している。

---

## 4. do_remote_prefill / do_remote_decode の制御フロー

### 4.1 フロー概要

```
[Step 1: Client -> Proxy]
  Client が /v1/completions にリクエスト送信

[Step 2: Proxy -> Producer]
  Proxy が Producer にリクエスト転送
  kv_transfer_params = {
      "do_remote_decode": True,
      "do_remote_prefill": False,
  }

[Step 3: Producer が Prefill 実行]
  - update_state_after_alloc() で do_remote_decode=True を検出
  - KV Cache を GPU/CPU メモリに保存
  - リクエスト完了時 (FINISHED_LENGTH_CAPPED):
    request_finished() が kv_transfer_params を生成

[Step 4: Producer -> Proxy (レスポンス)]
  kv_transfer_params = {
      "do_remote_prefill": True,
      "do_remote_decode": False,
      "remote_block_ids": [0, 1, 2, ...],
      "remote_engine_id": "uuid-of-producer",
      "remote_request_id": "req-id",
      "remote_host": "172.31.2.221",   <- VLLM_NIXL_SIDE_CHANNEL_HOST
      "remote_port": 5600,             <- VLLM_NIXL_SIDE_CHANNEL_PORT
      "tp_size": 2,                    <- tensor_parallel_size
  }

[Step 5: Proxy -> Consumer]
  Proxy が Consumer にリクエスト転送 (Producer の kv_transfer_params 付き)

[Step 6: Consumer が Decode 実行]
  - get_num_new_matched_tokens() で do_remote_prefill=True を検出
    -> num_external_tokens = len(prompt_tokens) - num_computed_tokens
  - update_state_after_alloc() で remote_block_ids を取得
  - Worker の start_load_kv() が NIXL ハンドシェイク + READ を実行
  - 転送完了後、Decode を実行
```

### 4.2 do_remote_decode の詳細

Producer 側で使用される。Proxy から送信されるリクエストに含まれる:

```python
if params.get("do_remote_decode"):
    self._reqs_in_batch.add(request.request_id)
if self.use_host_buffer and params.get("do_remote_decode"):
    self._reqs_need_save[request.request_id] = request
```

- `do_remote_decode=True`: このリクエストは後で Consumer に読み取られる
- Producer は Prefill 完了後、ブロックを保持し、Consumer からの READ を待つ
- `VLLM_NIXL_ABORT_REQUEST_TIMEOUT`（デフォルト 480 秒）後にタイムアウト

### 4.3 do_remote_prefill の詳細

Consumer 側で使用される。Producer の kv_transfer_params から引き継がれる:

```python
if params is not None and params.get("do_remote_prefill"):
    token_ids = request.prompt_token_ids or []
    count = len(token_ids) - num_computed_tokens
    if count > 0:
        return count, True  # 非同期 KV ロード
```

- `do_remote_prefill=True`: リモートから KV Cache を取得する
- Consumer は remote_block_ids, remote_engine_id, remote_host, remote_port を使用
- 一度処理したら `params["do_remote_prefill"] = False` に設定（重複防止）

---

## 5. kv_transfer_params の生成と使用方法

### 5.1 生成元: Producer の request_finished()

```python
def request_finished(self, request, block_ids):
    # ...
    if request.status != RequestStatus.FINISHED_LENGTH_CAPPED:
        return False, None  # Prefill が完了しなかった

    return delay_free_blocks, dict(
        do_remote_prefill=True,
        do_remote_decode=False,
        remote_block_ids=block_ids,
        remote_engine_id=self.engine_id,
        remote_request_id=request.request_id,
        remote_host=self.side_channel_host,
        remote_port=self.side_channel_port,
        tp_size=self.vllm_config.parallel_config.tensor_parallel_size,
    )
```

### 5.2 レスポンスへの格納

Producer は `/v1/completions` レスポンスの JSON に `kv_transfer_params` を含める。

### 5.3 Proxy による中継

toy_proxy_server.py がレスポンスから `kv_transfer_params` を抽出し、Consumer へのリクエストに付与:

```python
# Proxy: Producer レスポンスから取得
kv_transfer_params = response_json.get("kv_transfer_params", {})
if kv_transfer_params:
    req_data["kv_transfer_params"] = kv_transfer_params
```

### 5.4 Consumer での使用

Consumer は `kv_transfer_params` から以下を抽出:

```python
req.remote = RemoteMeta(
    block_ids=kv_transfer_params["remote_block_ids"],
    engine_id=kv_transfer_params["remote_engine_id"],
    request_id=kv_transfer_params["remote_request_id"],
    host=kv_transfer_params["remote_host"],
    port=kv_transfer_params["remote_port"],
)
```

これらの情報を使用して:
1. `host: port` で Producer の side channel に接続してハンドシェイク
2. `engine_id` で Producer のエージェントを識別
3. `block_ids` でどのブロックを READ するか決定

---

## 6. 根本原因分析

### 6.1 Side Channel 接続が確立されない理由の仮説

1. **VLLM_NIXL_SIDE_CHANNEL_PORT の設定問題**:
   - 現在 50100 を使用しているが、v0.16.0 のデフォルトは 5600
   - Producer/Consumer 両方で同じポートを使用しているのは正しい（Producer が LISTEN、Consumer が接続）

2. **VLLM_NIXL_SIDE_CHANNEL_HOST の設定問題**:
   - Producer は自身の Private IP (172.31.2.221) を設定する必要がある
   - Consumer は自身の Private IP (172.31.10.117) を設定する
   - **しかし、Consumer が Producer に接続する際は、kv_transfer_params の remote_host (= Producer の side_channel_host) を使用する**
   - つまり Producer の VLLM_NIXL_SIDE_CHANNEL_HOST が正しく設定されていれば、Consumer は自動的に正しいホストに接続する

3. **ZMQ ソケットの一時性**:
   - ZMQ のハンドシェイク接続は一時的であり、ハンドシェイク完了後はクローズされる
   - `ss -tan | grep 50100` で ESTABLISHED が見えない可能性がある（瞬間的な接続）

4. **Proxy の問題**:
   - Proxy が Producer のレスポンスから `kv_transfer_params` を正しく抽出・転送できていない可能性
   - Producer が `kv_transfer_params: null` を返している場合（do_remote_decode が設定されていない）

### 6.2 Producer が応答しない理由の仮説

Two-sided NIXL でのデータ転送フロー:

1. Consumer が `make_prepped_xfer("READ", ...)` で転送を準備
2. NIXL 内部: Consumer 側で `fi_recv()` を posting
3. **NIXL progress thread が Consumer の recv を Producer に通知する必要がある**
4. Producer が `fi_senddata()` でデータを送信

**問題点**: Two-sided パッチは `fi_read` -> `fi_recv` と `fi_writedata` -> `fi_senddata` を置換しただけ。しかし:

- One-sided では Consumer の `fi_read` が直接リモートメモリを読む（Producer は passive）
- Two-sided では Consumer の `fi_recv` は受信準備のみ（Producer が能動的に送信する必要がある）
- **NIXL の progress thread がこの two-sided のフローを正しくハンドリングするかは未確認**
- NIXL の `make_prepped_xfer("READ")` が内部的に one-sided READ を前提として設計されている場合、two-sided に置換しただけでは動作しない

### 6.3 v0.16.0 で kv_role の変更

v0.16.0 のドキュメントには以下の記載がある:

> NixlConnector currently does not distinguish kv_role; the actual prefiller/decoder roles are determined by the upper-level proxy.
> Therefore, kv_role in --kv-transfer-config is effectively a placeholder and does not affect NixlConnector's behavior.

つまり `kv_role: "kv_both"` を使用すべき。

---

## 7. 推奨事項

### 7.1 即座に確認すべき事項

1. **Proxy のログを確認**: Producer のレスポンスに `kv_transfer_params` が含まれているか
2. **Producer のリクエストステータスを確認**: `FINISHED_LENGTH_CAPPED` で終了しているか（そうでなければ kv_transfer_params は null）
3. **VLLM_NIXL_SIDE_CHANNEL_PORT の値を確認**: 50100 が意図的な設定か、デフォルトの 5600 を使用すべきか

### 7.2 設定の修正提案

```bash
# Producer (Node1) - v0.16.0 推奨設定
export VLLM_NIXL_SIDE_CHANNEL_HOST=172.31.2.221
export VLLM_NIXL_SIDE_CHANNEL_PORT=5600  # デフォルト値に変更

python -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen2.5-32B-Instruct \
  --port 8100 \
  --tensor-parallel-size 2 \
  --max-model-len 32000 \
  --gpu-memory-utilization 0.9 \
  --kv-transfer-config '{
    "kv_connector": "NixlConnector",
    "kv_role": "kv_both",
    "kv_buffer_device": "cpu",
    "kv_buffer_size": 5e9,
    "kv_connector_extra_config": {"backends": ["LIBFABRIC"]}
  }'

# Consumer (Node2) - v0.16.0 推奨設定
export VLLM_NIXL_SIDE_CHANNEL_HOST=172.31.10.117
export VLLM_NIXL_SIDE_CHANNEL_PORT=5600

python -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen2.5-32B-Instruct \
  --port 8200 \
  --tensor-parallel-size 2 \
  --max-model-len 32000 \
  --gpu-memory-utilization 0.9 \
  --kv-transfer-config '{
    "kv_connector": "NixlConnector",
    "kv_role": "kv_both",
    "kv_buffer_device": "cpu",
    "kv_buffer_size": 5e9,
    "kv_connector_extra_config": {"backends": ["LIBFABRIC"]}
  }'
```

注: `kv_parallel_size`, `kv_rank`, `kv_ip`, `kv_port` は NixlConnector では不要。

### 7.3 Two-sided NIXL の根本的な問題

NIXL の `make_prepped_xfer("READ")` は内部的に one-sided READ (fi_read) を前提として設計されている可能性が高い。Two-sided (fi_recv/fi_senddata) に置換するだけでは、以下の問題が発生する:

1. **READ 操作の意味論の違い**: One-sided では Consumer が能動的に読む。Two-sided では Producer が能動的に送る
2. **NIXL progress thread のトリガー**: Consumer が fi_recv を posting しても、Producer 側の NIXL がそれを検知して fi_senddata を呼ぶメカニズムが必要
3. **通知メカニズム**: vLLM の notif_id は転送完了後の通知であり、転送開始のトリガーではない

Two-sided を正しく動作させるには、NIXL ライブラリ内部の LIBFABRIC バックエンドで、fi_recv posting を検知して対向側の fi_senddata をトリガーする progress thread メカニズムの実装が必要。単純なパッチ適用では不十分な可能性がある。

---

## 付録: nixl_connector.py のクラス構造

```
NixlConnector (KVConnectorBase_V1)
  |
  +-- NixlConnectorScheduler  (Scheduler プロセスで動作)
  |     - side channel listener (ZMQ ROUTER)
  |     - リクエスト管理 (recv/save/send 追跡)
  |     - kv_transfer_params 生成
  |
  +-- NixlConnectorWorker  (Worker プロセスで動作)
        - NIXL agent (nixl_wrapper)
        - KV Cache メモリ登録
        - ハンドシェイク (ZMQ REQ -> Producer の ROUTER)
        - READ 転送 (make_prepped_xfer + transfer)
        - 通知受信 (get_new_notifs)
```
