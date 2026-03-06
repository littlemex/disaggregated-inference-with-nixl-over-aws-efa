# Two-Sided NIXL 解決策提案

**作成日**: 2026-03-05
**作成者**: Opus 4.6 (Task #4 - 統合分析)
**入力**: 4 件の個別調査レポート + README2.md

---

## 1. エグゼクティブサマリー

### 結論

Two-sided NIXL パッチは **API レベルの機械的置換** に留まっており、**データフローモデルの変換（pull -> push）が実装されていない** ことが根本原因である。4 件の調査結果はすべてこの結論を独立して支持しており、信頼性は高い。

### 問題の構造

```
One-sided RDMA (正常動作):
  Consumer が fi_read() で Producer メモリを直接読む -> Producer はパッシブ

Two-sided パッチ (動作不可):
  Consumer が fi_recv() で受信バッファをポスト -> 待機
  Producer は何もしない -> データ転送が発生しない -> タイムアウト
```

### 推奨アプローチ

**短期**: One-sided RDMA の再現（方法 C）を最優先で実施。2026-03-04 に実績があり、リスクが最も低い。

**中期**: Two-sided を正しく動作させるには方法 A（NIXL 内部に pull->push 変換レイヤーを追加）が最も実現可能だが、NIXL ソースの大幅な改修が必要。

---

## 2. 根本原因の確定（4 つの調査結果の統合）

### 2.1 全調査の合意点

| 調査 | 担当 | 主要な発見 | 結論 |
|------|------|-----------|------|
| vLLM 実装分析 | Task #1 | NixlConnector は `make_prepped_xfer("READ")` のみ使用。WRITE は Producer 側で自発的に呼ばれない | Pull model のみ実装 |
| NIXL 内部分析 | Task #5 | progress thread は CQ ポーリングのみ。fi_recv の posting を検知して fi_senddata をトリガーする機構がない | Push トリガーが不在 |
| kv_parallel_size 分析 | config-analyst | kv_parallel_size/kv_rank は NixlConnector で未使用。設定差異は問題の原因ではない | 設定は無関係 |
| 初期化フロー分析 | initialization-analyst | データ転送用 recv buffer の pre-post なし。CQ 完了フラグのルーティングが制御メッセージ専用 | 初期化も不完全 |

### 2.2 根本原因の確定

**直接的原因**: Consumer が `postXfer(NIXL_READ)` -> `fi_recv()` を 128 回呼んでバッファをポストするが、Producer 側では `postXfer(NIXL_WRITE)` -> `fi_senddata()` が一度も呼ばれない。

**構造的原因**: NIXL のアーキテクチャは one-sided RDMA を前提に設計されている。

| 設計要素 | One-sided (前提) | Two-sided (パッチ) | ギャップ |
|---------|-----------------|-------------------|---------|
| データ移動の主体 | Consumer (fi_read) | Producer (fi_senddata) | 主体が逆転 |
| Producer の役割 | パッシブ（メモリ公開のみ） | アクティブ（送信必須） | 根本的な変更が必要 |
| READ 要求の伝達 | 不要（直接アクセス） | 必要（通知メカニズム必須） | 未実装 |
| recv buffer | 不要 | pre-post 必須 | データ用は未実装 |
| CQ 完了処理 | FI_READ -> processLocalTransfer | FI_RECV -> processRecvCompletion | 制御メッセージ専用ハンドラに誤ルーティング |

### 2.3 Side Channel (port 50100) が ESTABLISHED にならない件

**これは正常動作であり、問題ではない。**

4 つの調査から明らかになった事実:
1. Side channel は **ZMQ ベースの vLLM 独自メカニズム**（NIXL バックエンドではない）
2. 接続は **リクエスト駆動（lazy）** -- Consumer が最初のリクエストを Proxy 経由で受信して初めてハンドシェイクを開始
3. ZMQ ハンドシェイクは **一時的**（完了後に REQ ソケットはクローズ）
4. `ss -tan | grep 50100` で ESTABLISHED が見えないのは、ハンドシェイクがまだ開始されていないか、一瞬で完了しているため

**ただし**: Proxy 経由テストでタイムアウトしている状態でもハンドシェイクが発生していない場合、以下の可能性がある:
- Proxy が `kv_transfer_params` を Consumer に正しく伝播していない
- Producer の `request_finished()` が `FINISHED_LENGTH_CAPPED` で完了していない（= `kv_transfer_params` が null）
- Consumer の Worker スレッドがハンドシェイクに到達する前にタイムアウトしている

---

## 3. 解決策の比較

### 方法 A: NIXL 内部に pull -> push 変換レイヤーを追加

**概要**: Consumer の NIXL_READ を受けて、NIXL バックエンド内部で Producer に「送信要求」制御メッセージを送り、Producer が対応するデータを fi_senddata で送信する仕組みを追加。

**実装内容**:
1. Consumer の `postXfer(NIXL_READ)` 内で、通常の `fi_recv` ポスト後に、NIXL 制御チャネル（rail 0）を使って Producer に「転送要求メッセージ」を送信
2. 転送要求メッセージには `(xfer_id, descriptor_list, remote_buffer_addrs)` を含める
3. Producer の progress thread が制御チャネル経由で転送要求を受信
4. Producer が受信した転送要求に基づいて `postWrite` -> `fi_senddata` でデータを送信
5. Consumer の `fi_recv` が完了し、CQ に FI_RECV が到着
6. `processRecvCompletion` を拡張してデータ転送完了を正しく処理
7. 転送完了後、通知メカニズム (notifSendPriv) で vLLM に完了を通知

**改修対象ファイル**:
- `libfabric_backend.cpp`: postXfer に制御メッセージ送信ロジック追加、progress thread に転送要求処理ロジック追加
- `libfabric_rail.cpp`: processRecvCompletion をデータ転送対応に拡張
- `libfabric_common.h`: 新しい制御メッセージタイプ (`NIXL_LIBFABRIC_MSG_XFER_REQUEST`) の定義

**メリット**:
- NIXL バックエンド内部で完結（vLLM 側の変更不要）
- 既存の制御チャネル（rail 0 の fi_senddata/fi_recvmsg）を再利用可能
- aws-ofi-nccl の設計パターン（sender-initiated + recv pre-post）と整合

**デメリット**:
- NIXL 内部の大幅な改修が必要（推定 500-800 行の追加/変更）
- progress thread のロック設計を理解する必要がある
- テストが困難（ユニットテスト環境に EFA が必要）
- recv buffer の動的管理（flow control）が必要

**難易度**: 高（2-3 週間）

### 方法 B: vLLM 側でフロー変更（Consumer READ -> Producer WRITE）

**概要**: vLLM の NixlConnector を変更し、KV-Cache 転送の主体を Consumer の READ から Producer の WRITE に変更する。

**実装内容**:
1. Producer の `request_finished()` 後、Consumer の情報（バッファアドレス、engine_id）を取得
2. Producer の NixlConnector が `postXfer(NIXL_WRITE)` を自発的に呼び出し
3. Consumer 側は `fi_recv` を事前にポストして待機
4. Producer の `fi_senddata` -> Consumer の `fi_recv` でデータ転送
5. Consumer 側で転送完了を検知してデコード開始

**改修対象ファイル**:
- `nixl_connector.py`: NixlConnectorScheduler と NixlConnectorWorker の大幅な改修
- Proxy のフロー変更（Consumer のバッファ情報を Producer に渡す追加フロー）

**メリット**:
- NIXL バックエンド内部の変更が不要
- Python レベルでの変更のため、テストが容易

**デメリット**:
- NIXL の設計思想（READ ベース）に反する
- vLLM のアーキテクチャを大幅に変更（Scheduler/Worker 間のデータフロー）
- Consumer のバッファアドレスを事前に Producer に渡す必要がある（追加のメタデータ交換フロー）
- fi_recv の事前ポストタイミングの制御が複雑
- vLLM のバージョンアップ時に毎回マージコンフリクトが発生

**難易度**: 高（2-4 週間）

### 方法 C: One-sided RDMA の再現

**概要**: 2026-03-04 に成功した one-sided RDMA (公式 NIXL 0.10.0) の環境を正確に再現し、ベースラインの性能を確立する。

**実装内容**:
1. 両ノードで公式 NIXL 0.10.0 を再インストール
2. 2026-03-04 の成功時設定を正確に再現（以下参照）
3. Proxy 経由の disaggregated inference を再テスト
4. ベンチマーク測定を実行

**2026-03-04 成功時の正確な設定**（analysis_kv_parallel_size.md の実ログから抽出）:

```bash
# Producer (Node1)
export VLLM_NIXL_SIDE_CHANNEL_HOST=172.31.2.221
export VLLM_NIXL_SIDE_CHANNEL_PORT=50100

python -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen2.5-32B-Instruct \
  --port 8100 \
  --tensor-parallel-size 2 \
  --gpu-memory-utilization 0.9 \
  --kv-transfer-config '{
    "kv_connector": "NixlConnector",
    "kv_role": "kv_producer",
    "kv_rank": 0,
    "kv_parallel_size": 1,
    "kv_buffer_device": "cpu",
    "kv_buffer_size": 5e9,
    "kv_ip": "172.31.10.117",
    "kv_port": 14579,
    "kv_connector_extra_config": {"backends": ["LIBFABRIC"]}
  }'

# Consumer (Node2)
export VLLM_NIXL_SIDE_CHANNEL_HOST=172.31.10.117
export VLLM_NIXL_SIDE_CHANNEL_PORT=50100

python -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen2.5-32B-Instruct \
  --port 8200 \
  --tensor-parallel-size 2 \
  --gpu-memory-utilization 0.9 \
  --kv-transfer-config '{
    "kv_connector": "NixlConnector",
    "kv_role": "kv_consumer",
    "kv_rank": 0,
    "kv_parallel_size": 1,
    "kv_buffer_device": "cpu",
    "kv_buffer_size": 5e9,
    "kv_ip": "127.0.0.1",
    "kv_port": 14579,
    "kv_connector_extra_config": {"backends": ["LIBFABRIC"]}
  }'
```

**注意事項**:
- `kv_parallel_size` は NixlConnector で未使用だが、成功時の設定に合わせて `1` に設定
- `max_model_len` は成功時にデフォルト（32768）だったが、32000 でも影響は軽微
- `enforce_eager` と `enable_prefix_caching` は成功時にデフォルト（false/true）だった
- `FI_EFA_USE_DEVICE_RDMA` の設定確認が必要

**メリット**:
- 2026-03-04 に成功した実績がある
- 変更量がゼロ（既存の公式バイナリを使用）
- リスクが最も低い
- 即座に実施可能

**デメリット**:
- EFA 上の one-sided RDMA は EFA provider 内部で send/recv にエミュレーションされるため、性能が最適ではない可能性
- Phase 2 では L2-EFA で fi_read EAGAIN 問題が発生していた（ただし Phase 3 g7e では成功実績あり）
- Two-sided の技術的な課題は解決されない

**難易度**: 低（数時間）

---

## 4. 推奨アプローチとその理由

### 第一優先: 方法 C（One-sided RDMA の再現）

**理由**:
1. **実績がある**: 2026-03-04 に同じインフラ (g7e.12xlarge, EFA3) で成功
2. **リスクが最低**: 公式バイナリの再インストールのみ、コード変更なし
3. **即座に実行可能**: 数時間で完了
4. **Phase 3 の実験目的を達成できる**: EFA vs TCP の比較実験に one-sided RDMA のベースラインが必須
5. **fi_read EAGAIN 問題は g7e では発生していない**: Phase 2 (g6e.12xlarge) では失敗したが、Phase 3 (g7e.12xlarge, EFA3) では成功。EFA3 デバイスは RDMA エミュレーションが改善されている可能性がある

### 第二優先: 方法 A（NIXL 内部改修）

Two-sided が必要な理由（EFA 上の one-sided RDMA の制限）がある場合のみ。

**理由**:
1. NIXL バックエンド内で完結するため、vLLM との結合度が低い
2. 既存の制御チャネル機構を再利用可能
3. aws-ofi-nccl の実績ある設計パターン（sender-initiated）に倣える

### 非推奨: 方法 B（vLLM 側フロー変更）

**理由**:
1. NIXL の設計思想（READ ベース）に反する
2. vLLM バージョンアップのたびにマージコンフリクトが発生
3. Consumer のバッファアドレスを事前に渡す追加フローが複雑

---

## 5. 具体的な実装手順

### 5.1 方法 C: One-sided RDMA の再現手順

```
[Step 1] 両ノードで公式 NIXL を再インストール
  Node1 & Node2:
    pip install nixl-cu12==0.10.0 --force-reinstall

[Step 2] バイナリの確認
  両ノード:
    pip show nixl-cu12  # Version: 0.10.0
    find / -name "libplugin_LIBFABRIC.so" 2>/dev/null | xargs ls -la
    # サイズが ~459KB (459,032 bytes) であること

[Step 3] 既存プロセスの停止
  両ノード:
    pkill -f "vllm.entrypoints.openai.api_server"
    nvidia-smi | grep 'VLLM' | awk '{print $5}' | xargs -r kill -9

[Step 4] Producer の起動 (Node1)
  上記「2026-03-04 成功時の正確な設定」に従って起動
  確認: ログに "Backend LIBFABRIC was instantiated" が表示されること
  確認: ログに "FI_MSG, FI_RMA" が含まれること（one-sided の証拠）

[Step 5] Consumer の起動 (Node2)
  上記設定に従って起動
  確認: 同様のログ確認

[Step 6] Producer 単体テスト
  Node1: curl -X POST http://localhost:8100/v1/completions ...
  確認: 200 OK、レスポンス受信

[Step 7] Proxy 起動と統合テスト
  Node1 で Proxy を起動
  curl -X POST http://localhost:8000/v1/completions ...
  確認: Prefill -> KV-Cache 転送 -> Decode -> レスポンス

[Step 8] Side channel 確認
  テスト中に: ss -tan | grep 50100
  確認: ESTABLISHED 接続が一時的に表示されること（ZMQ ハンドシェイク）

[Step 9] ベンチマーク測定
  12K tokens と 32K tokens でベンチマーク実行
```

### 5.2 方法 A: NIXL 内部改修の実装手順（参考）

以下は Two-sided を正しく動作させる場合の概略設計。

```
[Phase 1: 制御メッセージタイプの追加]
  libfabric_common.h:
    NIXL_LIBFABRIC_MSG_XFER_REQUEST = 5  // 転送要求
    struct XferRequestMessage {
      uint64_t xfer_id;
      uint32_t num_descriptors;
      // 各 descriptor の (remote_offset, length) ペア
    }

[Phase 2: Consumer 側 - 転送要求の送信]
  libfabric_backend.cpp の postXfer(NIXL_READ):
    1. 通常通り fi_recv でバッファをポスト
    2. 追加: rail 0 の制御チャネルで XFER_REQUEST を Producer に送信
       postControlMessage(remote_agent, MSG_XFER_REQUEST, xfer_request_data)

[Phase 3: Producer 側 - 転送要求の受信と応答]
  libfabric_rail.cpp の processRecvCompletion:
    1. msg_type == MSG_XFER_REQUEST の場合:
       a. xfer_id と descriptor リストをデコード
       b. 対応するローカルバッファのアドレスを解決
       c. 各 descriptor に対して postWrite -> fi_senddata を実行

[Phase 4: Consumer 側 - データ受信完了の処理]
  libfabric_rail.cpp の processCompletionQueueEntry:
    1. FI_RECV フラグのデータ転送完了を検出
       (制御メッセージとデータ転送の区別が必要 - バッファサイズ or タグで判別)
    2. processLocalTransferCompletion("read") に相当する処理を実行
    3. 全 descriptor 完了時に通知 (notifSendPriv) を送信

[Phase 5: recv buffer の管理]
  - Consumer 側でデータ用 recv buffer をプールで管理
  - fi_recv の pre-post 数を適切に設定
  - flow control: Producer が Consumer の recv buffer を枯渇させないよう制御
```

---

## 6. 検証方法

### 6.1 方法 C の検証チェックリスト

| # | 確認項目 | 期待値 | コマンド |
|---|---------|-------|---------|
| 1 | NIXL バージョン | 0.10.0 | `pip show nixl-cu12` |
| 2 | バイナリサイズ | ~459KB | `ls -la libplugin_LIBFABRIC.so` |
| 3 | バックエンド初期化 | "Backend LIBFABRIC was instantiated" | ログ確認 |
| 4 | Capabilities | "FI_MSG, FI_RMA, ..." | ログ確認 |
| 5 | Producer 単体テスト | 200 OK | `curl localhost:8100/v1/completions` |
| 6 | Consumer 単体テスト | 200 OK | `curl localhost:8200/v1/completions` |
| 7 | Proxy 統合テスト | レスポンス受信（タイムアウトなし） | `curl localhost:8000/v1/completions` |
| 8 | Side channel | ESTABLISHED が一時的に出現 | `ss -tan \| grep 50100` |
| 9 | ベンチマーク 12K | P50 < 2000ms | 実験スクリプト |
| 10 | ベンチマーク 32K | P50 < 2000ms | 実験スクリプト |

### 6.2 方法 A の検証チェックリスト（参考）

| # | 確認項目 | 期待値 |
|---|---------|-------|
| 1 | 制御メッセージ送信 | Consumer ログに "Sent XFER_REQUEST" |
| 2 | 制御メッセージ受信 | Producer ログに "Received XFER_REQUEST" |
| 3 | データ送信 | Producer ログに "postWrite/fi_senddata" |
| 4 | データ受信完了 | Consumer ログに "fi_recv completion for data" |
| 5 | 通知送信 | Consumer ログに "notifSendPriv" |
| 6 | vLLM 転送完了 | Consumer ログに "KV transfer complete" |
| 7 | Proxy 統合テスト | レスポンス受信 |

---

## 7. 代替案: One-Sided RDMA の安定性に関する考察

### 7.1 Phase 2 vs Phase 3 の違い

| 項目 | Phase 2 (g6e) | Phase 3 (g7e) |
|------|--------------|--------------|
| GPU | L40S 48GB x4 | RTX PRO 6000 96GB x2 |
| EFA | EFA (standard) | EFA3 (0xEFA3) |
| TP | 4 | 2 |
| fi_read 結果 | EAGAIN 無限ループ | 成功 |
| RDMA Read | max_qp_rd_atom=0 | max_qp_rd_atom=0 |
| efadv | 未確認 | RDMA_READ: YES, RDMA_WRITE: YES |

Phase 2 で失敗し Phase 3 で成功した理由の仮説:
1. **EFA3 デバイスの改良**: 新世代 EFA3 (0xEFA3) は fi_read のエミュレーションが改善されている可能性
2. **TP サイズの違い**: TP=4 では descriptor 数が多くなり、同時進行の fi_read が多すぎてエミュレーション層がオーバーフロー
3. **kv_buffer_device**: Phase 2 の一部テストで `cuda` を使用していた可能性
4. **ネットワーク帯域**: g7e の EFA3 は帯域が広く、エミュレーションのオーバーヘッドが軽減

### 7.2 One-Sided RDMA が g7e で安定動作する根拠

1. **2026-03-04 の成功実績**: Proxy 経由の完全な disaggregated inference が動作
2. **P50 レイテンシ**: 1395ms (12K) / 1530.5ms (32K) -- ベースラインと比較してほぼオーバーヘッドなし
3. **efadv_query_device**: RDMA_READ: YES -- EFA3 はハードウェアレベルで RDMA Read をサポートしている可能性

### 7.3 リスク

- EFA provider 内部のエミュレーションに依存しているため、長時間運用や高負荷時に不安定になる可能性
- NIXL / EFA provider のバージョンアップで動作が変わる可能性
- ibv_devinfo の `max_qp_rd_atom=0` が示す通り、ハードウェアレベルでの RDMA Read は制限されている

---

## 8. 追加調査事項

### 8.1 即座に確認すべき事項

1. **Proxy ログの確認**: Producer レスポンスの `kv_transfer_params` の内容（null か、正しい値が含まれているか）
2. **Producer の `request_finished()` ステータス**: `FINISHED_LENGTH_CAPPED` で終了しているか（でなければ kv_transfer_params は null）
3. **`FI_EFA_USE_DEVICE_RDMA` の現在値**: 成功時にシステムデフォルト (=1) が適用されていたか確認
4. **メモリ登録フラグ**: パッチの Change 5/6 (registerMemory の FI_SEND/FI_RECV) が実際にビルド済みバイナリに反映されているか（ソースでは FI_REMOTE_WRITE/FI_REMOTE_READ のまま）

### 8.2 方法 C 実施後に確認すべき事項

1. One-sided RDMA の安定性（10 回連続実行でエラーがないか）
2. 長時間ベンチマーク（100 リクエスト連続）での安定性
3. EFA3 上の fi_read パフォーマンス特性（レイテンシ分布）

---

## まとめ

| 優先度 | 方法 | 難易度 | 期間 | リスク | 効果 |
|--------|------|-------|------|-------|------|
| 1 (推奨) | C: One-sided RDMA 再現 | 低 | 数時間 | 低 | Phase 3 実験のベースライン確立 |
| 2 | A: NIXL 内部改修 | 高 | 2-3 週間 | 中 | EFA ネイティブ two-sided messaging の実現 |
| 3 (非推奨) | B: vLLM フロー変更 | 高 | 2-4 週間 | 高 | vLLM 依存の回避不可 |

**即座の次のアクション**: 方法 C を実施し、2026-03-04 の成功環境を再現する。

---

**最終更新**: 2026-03-05
