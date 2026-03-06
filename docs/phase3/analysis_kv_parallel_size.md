# kv_parallel_size の影響分析レポート

**作成日**: 2026-03-05
**分析者**: config-analyst (Opus 4.6)

---

## 1. エグゼクティブサマリー

**結論: kv_parallel_size は NixlConnector では使用されておらず、現在の問題の根本原因ではない。**

vLLM v0.16.0 のソースコード分析により、`kv_parallel_size` は `KVTransferConfig` に設定フィールドとして存在するが、NixlConnector のコード内では一切参照されていないことを確認した。このパラメータは主に P2pNcclConnector 向けのレガシー設定であり、NIXL ベースの disaggregated inference には影響しない。

一方、**`kv_ip` の設定差異**と **side channel ポート（50100 vs デフォルト 5600）の接続フロー**に、成功/失敗を分ける可能性のある重要な差異が見つかった。

---

## 2. ログから確認した設定パラメータ比較

### 2.1 全ログの正確な設定値（ログから直接抽出）

| パラメータ | 成功時 Producer (03-04 14:57) | 成功時 Consumer (03-04 14:55) | 現在 Producer (03-05 07:42) | 現在 Consumer (03-05 07:38) |
|-----------|------------------------------|------------------------------|----------------------------|----------------------------|
| kv_parallel_size | **1** | **1** | **2** | **2** |
| kv_rank | 0 | 0 | 0 | 1 |
| kv_role | kv_producer | kv_consumer | kv_producer | kv_consumer |
| kv_ip | 172.31.10.117 (Consumer IP) | 127.0.0.1 | **172.31.2.221 (Producer IP)** | 172.31.10.117 (自身の IP) |
| kv_port | 14579 | 14579 | 14579 | 14579 |
| kv_buffer_device | cpu | cpu | cpu | cpu |
| kv_buffer_size | 5e9 | 5e9 | 5e9 | 5e9 |
| trust_remote_code | (なし) | (なし) | True | True |
| max_model_len | 32768 (デフォルト) | 32768 (デフォルト) | 32000 | 32000 |
| enforce_eager | (なし/False) | (なし/False) | True | True |
| enable_prefix_caching | True (デフォルト) | True (デフォルト) | False | False |
| NIXL バイナリ | 公式 0.10.0 (459KB) | 公式 0.10.0 (459KB) | パッチ版 1.0.0 (537KB) | パッチ版 1.0.0 (537KB) |

### 2.2 README2.md 付録の記載との相違

README2.md の付録では「成功時 Producer kv_parallel_size=1, Consumer kv_parallel_size=2」と記載されていたが、**実際のログでは両方とも kv_parallel_size=1 だった**。

- `success_producer_0304.log` (L7): `kv_parallel_size=1`
- `success_consumer_bench_0304.log` (L7): `kv_parallel_size=1`

付録の「Consumer kv_parallel_size=2」という記載は、おそらく別のスクリプト（`start_consumer_efa.sh`）の設定値を参照したもので、実際にベンチマークに使用されたスクリプトの設定とは異なる。

---

## 3. kv_parallel_size の vLLM コード内での使用箇所

### 3.1 定義場所

`/home/coder/vllm/vllm/config/kv_transfer.py` L44-46:

```python
kv_parallel_size: int = 1
"""The number of parallel instances for KV cache transfer. For
P2pNcclConnector, this should be 2."""
```

デフォルト値は 1。ドキュメントに明記されている通り、P2pNcclConnector 向けの設定。

### 3.2 NixlConnector での参照

**NixlConnector 内では kv_parallel_size を一切参照していない。**

`/home/coder/vllm/vllm/distributed/kv_transfer/kv_connector/v1/nixl_connector.py` 全体を検索した結果:

- `kv_parallel_size` への直接参照: **0 箇所**
- `parallel_size` への参照: L190 のコメント内（`tensor_parallel_size` について）と L850 の `tensor_parallel_size` のみ
- NixlConnector は `kv_rank` も直接参照していない

### 3.3 kv_parallel_size を参照するコネクタ

vLLM v0.16.0 全体で `kv_parallel_size` を参照しているのは:

1. **`KVTransferConfig`** (`config/kv_transfer.py` L44): 定義のみ
2. **LMCache コネクタ** (`lmcache_mp_connector.py`): `kv_rank` を worker_id として使用

P2pNcclConnector でさえ v0.16.0 では直接 `kv_parallel_size` を参照していない（v1 API に移行済み）。

### 3.4 kv_rank の役割

`kv_rank` も NixlConnector では直接使用されていない。NixlConnector は代わりに:

- `get_tensor_model_parallel_rank()` で TP rank を取得（L903）
- `engine_id`（UUID）でインスタンスを一意に識別
- side channel (ZMQ) でメタデータを交換

---

## 4. NixlConnector の接続確立メカニズム

### 4.1 接続フロー

NixlConnector の接続確立は `kv_parallel_size` / `kv_rank` に依存せず、以下のメカニズムで行われる:

1. **Producer 起動時**:
   - `NixlConnectorScheduler` が `VLLM_NIXL_SIDE_CHANNEL_HOST: VLLM_NIXL_SIDE_CHANNEL_PORT` で ZMQ ROUTER ソケットを LISTEN
   - Handshake メタデータ（engine_id, agent_metadata, KV cache アドレス等）を準備

2. **Consumer がリクエストを受信した時**（オンデマンド接続）:
   - Proxy が `kv_transfer_params` を Consumer に渡す
   - `kv_transfer_params` には `remote_host`, `remote_port`, `remote_engine_id` が含まれる
   - Consumer の Worker が `_background_nixl_handshake()` を呼び出し
   - ZMQ REQ ソケットで Producer の side channel に接続
   - `GET_META_MSG` を送信してメタデータを取得
   - NIXL agent 間の handshake を完了

3. **重要**: 接続は **リクエスト駆動**（lazy）であり、起動時に自動接続されない

### 4.2 side channel の接続確立に必要な情報

side channel 接続に使用されるのは:

- `remote_host`: Producer の `VLLM_NIXL_SIDE_CHANNEL_HOST` の値
- `remote_port`: Producer の `VLLM_NIXL_SIDE_CHANNEL_PORT` の値
- `remote_engine_id`: Producer の `engine_id`（UUID）
- `tp_size`: `tensor_parallel_size`（handshake 時に remote TP rank の特定に使用）

これらは Proxy が `request_finished()` 時に生成する `kv_transfer_params` 経由で Consumer に渡される（L842-851）。

### 4.3 side channel ポートの実装

```python
# NixlConnectorScheduler.__init__ (L522-526)
self.side_channel_host = envs.VLLM_NIXL_SIDE_CHANNEL_HOST
self.side_channel_port = (
    envs.VLLM_NIXL_SIDE_CHANNEL_PORT
    + vllm_config.parallel_config.data_parallel_index
)
```

デフォルトポートは **5600**（`vllm/envs.py` L172）。現在の設定では環境変数で 50100 に変更済み。

---

## 5. 成功時と現在の設定差異の影響分析

### 5.1 kv_parallel_size: 影響なし

| 設定 | 成功時 | 現在 | 影響 |
|------|--------|------|------|
| Producer: kv_parallel_size=1 | [適用] | kv_parallel_size=2 | **NixlConnector では未使用のため影響なし** |
| Consumer: kv_parallel_size=1 | [適用] | kv_parallel_size=2 | **NixlConnector では未使用のため影響なし** |

### 5.2 kv_rank: 影響なし

| 設定 | 成功時 | 現在 | 影響 |
|------|--------|------|------|
| Producer: kv_rank=0 | [適用] | kv_rank=0 | 同じ、かつ NixlConnector では未使用 |
| Consumer: kv_rank=0 | [適用] | kv_rank=1 | **NixlConnector では未使用のため影響なし** |

### 5.3 kv_ip: 注目すべき差異

| 設定 | 成功時 | 現在 | 影響 |
|------|--------|------|------|
| Producer kv_ip | 172.31.10.117 (Consumer IP) | **172.31.2.221 (Producer 自身の IP)** | **要調査** |
| Consumer kv_ip | 127.0.0.1 | 172.31.10.117 (自身の IP) | kv_ip は NixlConnector では直接使用されない |

ただし `kv_ip` は NixlConnector 内で直接使用されていない（P2pNcclConnector の NCCL 通信確立向け）。NixlConnector は `VLLM_NIXL_SIDE_CHANNEL_HOST` 環境変数と Proxy 経由の `kv_transfer_params` を使用する。

### 5.4 その他の差異

| 項目 | 成功時 | 現在 | 潜在的影響 |
|------|--------|------|-----------|
| NIXL バイナリ | one-sided (459KB) | two-sided (537KB) | **根本的な差異（one-sided vs two-sided）** |
| max_model_len | 32768 | 32000 | 軽微（KV cache サイズに影響） |
| enforce_eager | False | True | CUDAGraph 無効化、起動は遅いが動作には影響しないはず |
| enable_prefix_caching | True | False | 影響小 |
| FI_EFA_USE_DEVICE_RDMA | 1 (確認済み) | 未確認 | **確認が必要** |

---

## 6. 推奨設定

### 6.1 kv_parallel_size と kv_rank の推奨値

NixlConnector では使用されないため、デフォルト値を推奨:

```json
{
  "kv_parallel_size": 1,
  "kv_rank": 0
}
```

Producer / Consumer 両方で同じ値（デフォルト）を使用すれば十分。ただし、間違った値を設定しても NixlConnector の動作には影響しない。

### 6.2 成功時の設定を再現する場合

2026-03-04 の one-sided RDMA 成功時の設定を正確に再現するには:

**Producer: **
```json
{
  "kv_connector": "NixlConnector",
  "kv_role": "kv_producer",
  "kv_rank": 0,
  "kv_parallel_size": 1,
  "kv_buffer_device": "cpu",
  "kv_buffer_size": 5e9,
  "kv_ip": "172.31.10.117",
  "kv_port": 14579,
  "kv_connector_extra_config": {"backends": ["LIBFABRIC"]}
}
```

**Consumer: **
```json
{
  "kv_connector": "NixlConnector",
  "kv_role": "kv_consumer",
  "kv_rank": 0,
  "kv_parallel_size": 1,
  "kv_buffer_device": "cpu",
  "kv_buffer_size": 5e9,
  "kv_ip": "127.0.0.1",
  "kv_port": 14579,
  "kv_connector_extra_config": {"backends": ["LIBFABRIC"]}
}
```

### 6.3 two-sided NIXL 向けの推奨設定

`kv_parallel_size` は関係ないため、問題解決の焦点は以下に移すべき:

1. **NIXL side channel の接続確立**
   - 環境変数 `VLLM_NIXL_SIDE_CHANNEL_HOST` が正しい IP を指しているか
   - ポート 50100（またはデフォルト 5600）がノード間で疎通可能か
   - handshake はリクエスト駆動なので、Proxy が正しく `kv_transfer_params` を伝播しているか

2. **Two-sided NIXL の progress thread 問題**
   - fi_recv() を posting する側と fi_senddata() をトリガーする側の連携
   - NIXL の内部 notification メカニズムが two-sided で正しく動作するか

3. **FI_EFA_USE_DEVICE_RDMA の確認**
   - 成功時はシステムデフォルト (`=1`) が適用されていた
   - 現在の設定でも同じ値が適用されているか確認が必要

---

## 7. まとめ

### 確認された事実

1. **kv_parallel_size は NixlConnector で未使用** -- vLLM v0.16.0 のソースコードで確認
2. **kv_rank も NixlConnector で未使用** -- TP rank は別途 `get_tensor_model_parallel_rank()` で取得
3. **2026-03-04 の成功時は Producer/Consumer 両方とも kv_parallel_size=1** -- README2.md 付録の「Producer=1, Consumer=2」は不正確
4. **side channel 接続はリクエスト駆動** -- 起動時に自動接続されず、Proxy 経由のリクエスト時に初めて handshake が開始される
5. **接続確立に使用されるのは VLLM_NIXL_SIDE_CHANNEL_HOST/PORT と Proxy 経由の kv_transfer_params**

### 問題の根本原因への示唆

kv_parallel_size の設定差異は問題の原因ではない。現在の問題（side channel が ESTABLISHED にならない、Producer が応答しない）は、以下のいずれかが原因:

1. **Two-sided NIXL 固有の問題**: one-sided RDMA（成功）と two-sided messaging（失敗）の動作の違い
2. **NIXL progress thread**: fi_recv で受信待機中のデータに対して fi_senddata をトリガーする内部メカニズムが two-sided パッチで正しく動作していない可能性
3. **NIXL バージョンの意図せぬ変更**: 17:30 に nixl-cu12 0.10.0 に戻っていた問題

---

**記録**: `/home/coder/phase3/group1/analysis_kv_parallel_size.md`
