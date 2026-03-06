# vLLM + NIXL KV-Cache 転送問題 調査計画

**日時**: 2026-03-05
**チーム**: Opus 4.6 x 5 名
**ステータス**: [完了] 根本原因を特定

## 問題概要（更新）

**[根本原因が判明]**: Consumer が kv_transfer_params を正しく受け取り処理を開始するが、**LIBFABRIC fi_read（one-sided RMA）が EAGAIN を繰り返し返し、最終的に EFA エラー（err: 113）で失敗する**。

### 症状（初期観察）
- Prefill: 成功（kv_transfer_params 生成）
- Proxy: kv_transfer_params を Consumer に送信
- Consumer: HTTP 200 OK を返すが、実際の処理をしない
- Producer: `Num successful transfers=0`

### 根本原因（調査結果）
- kv_transfer_params は正しく処理されている
- Consumer は KV-Cache 取得を試行している
- **失敗箇所**: LIBFABRIC の `fi_read` (one-sided RMA) が EAGAIN を 3100+ 回返す
- **最終エラー**: EFA "Unreachable remote" (err: 113, No route to host)
- **既知の問題**: Phase 2 の analy.md で報告済み（LIBFABRIC fi_read とエミュレーション RMA の不整合）

## 調査対象ファイル

### 1. nixl_connector.py
**パス**: `/home/ubuntu/.local/lib/python3.10/site-packages/vllm/distributed/kv_transfer/kv_connector/v1/nixl_connector.py`
**サイズ**: 115KB

**調査ポイント**:
- kv_transfer_params の処理ロジック
- Consumer 側での KV-Cache 取得メソッド
- `do_remote_prefill` と `do_remote_decode` の分岐処理
- NIXL エージェントとの通信実装

**関連ログメッセージ**:
```
INFO: Initializing NIXL Scheduler
INFO: Setting UCX_RCACHE_MAX_UNRELEASED
WARNING: Releasing expired KV blocks ... retrieved by 0 decode worker(s)
```

### 2. core.py
**パス**: `/home/ubuntu/.local/lib/python3.10/site-packages/vllm/v1/engine/core.py`
**サイズ**: 67KB

**調査ポイント**:
- リクエスト処理の全体フロー
- kv_transfer_params が Worker に伝わる経路
- EngineCoreProc の初期化と実行
- Worker プロセスへのパラメータ渡し

**関連ログメッセージ**:
```
INFO: Initializing a V1 LLM engine
WARNING: Initializing KVConnectorBase_V1
```

### 3. api_server.py
**パス**: `/home/ubuntu/.local/lib/python3.10/site-packages/vllm/entrypoints/openai/api_server.py`
**サイズ**: 18KB

**調査ポイント**:
- `/v1/completions` エンドポイントの実装
- リクエストボディのパース処理
- kv_transfer_params の取り出しと Engine への渡し方

**関連ログメッセージ**:
```
INFO: Route: /v1/completions, Methods: POST
INFO: 172.31.2.221:40644 - "POST /v1/completions HTTP/1.1" 200 OK
```

## チーム構成と担当

### 1. vllm-source-reader (Opus 4.6)
**担当**: nixl_connector.py の読解
**タスク**:
- kv_transfer_params の処理フローを追跡
- Consumer 側の KV-Cache 取得メソッドを特定
- do_remote_decode=false の場合の動作を確認

### 2. engine-core-analyzer (Opus 4.6)
**担当**: core.py の読解
**タスク**:
- リクエストから Worker への伝播経路を追跡
- kv_transfer_params が失われる可能性のある箇所を特定
- EngineCoreProc の処理フローを図示

### 3. api-endpoint-analyzer (Opus 4.6)
**担当**: api_server.py の読解
**タスク**:
- /v1/completions エンドポイントの実装を確認
- リクエストボディから kv_transfer_params の抽出方法を確認
- Engine への渡し方を特定

### 4. log-correlator (Opus 4.6)
**担当**: Producer と Consumer のログ相関分析
**タスク**:
- Producer と Consumer のログをタイムスタンプで突き合わせ
- kv_transfer_params が消失するタイミングを特定
- 欠落している処理ステップを洗い出し

### 5. team-coordinator (Opus 4.6)
**担当**: 全体調整とまとめ
**タスク**:
- 各メンバーの発見を統合
- Root cause を特定
- 修正案を提示

## 調査手順

### Phase 1: ファイル読み込みと理解（並行実行）
1. 各担当者が担当ファイルを読み込む
2. 重要なメソッドと処理フローを抽出
3. kv_transfer_params の処理箇所を特定

### Phase 2: フロー統合と分析
1. Team coordinator が各メンバーの発見を統合
2. リクエスト全体のフローを図示
3. kv_transfer_params が消失/無視される箇所を特定

### Phase 3: Root cause 特定と修正案
1. 問題箇所を特定
2. なぜ Consumer が KV-Cache を取得しないのかを解明
3. 修正方法を提案（ログ追加、設定変更、コード修正）

## 調査結果と成果物

### 1. 根本原因の特定 [完了]

**LIBFABRIC fi_read EAGAIN 失敗**

- **技術的詳細**:
  - NIXL LIBFABRIC backend は one-sided RMA (`fi_read`) を使用
  - libfabric EFA provider は device RDMA をサポートするが、エミュレーション RMA（two-sided 要求）と不整合を起こす
  - `fi_read` が "Resource temporarily unavailable" (EAGAIN) を繰り返し返す
  - 4 分間のリトライ後、EFA レイヤーで "Unreachable remote" エラー（err: 113）

- **Phase 2 での同様の問題**:
  - `/home/coder/phase2/group1/analy.md` 7.4 節で報告済み
  - `FI_EFA_USE_DEVICE_RDMA=1` でも失敗を確認
  - fi_pingpong テストでもデータプレーン転送がハング

### 2. kv_transfer_params 処理フロー [完了]

**API → Engine → Worker の処理経路を確認**:
```
CompletionRequest.kv_transfer_params
  → SamplingParams.extra_args["kv_transfer_params"]
  → engine_client.generate()
  → EngineCoreProc
  → Worker (NixlConnector.retrieve_kv_cache())
```

Consumer は kv_transfer_params を正しく受け取り、KV-Cache 取得を試行している。

### 3. 解決策の提案

#### Option 1: NIXL Two-Sided API への切り替え [推奨]

- **方法**: `fi_senddata`/`fi_recv` (two-sided) を使用
- **利点**: エミュレーション RMA との不整合を回避
- **課題**: NIXL v0.10.0 が two-sided API をサポートしているか確認が必要

#### Option 2: TCP Disaggregation への切り替え [短期的解決策]

- **方法**: NIXL LIBFABRIC を無効化し、TCP バックエンドに戻す
- **利点**: Phase 2 で動作確認済み（TCP-DI は安定動作）
- **欠点**: EFA 100Gbps の帯域を活用できない

#### Option 3: UCX バックエンドへの切り替え [検証必要]

- **方法**: NIXL_BACKEND=UCX に変更
- **Phase 2 での知見**: UCX SRD は PUT_SHORT 未実装で native RMA を使えず失敗
- **推奨度**: 低（同様の問題が発生する可能性）

#### Option 4: Phase 3 の目的再検討 [戦略的判断]

- **現状**: g7e.12xlarge (Nitro v6, EFA 200Gbps) で LIBFABRIC EFA の性能を測定する予定
- **問題**: NIXL LIBFABRIC EFA が根本的に動作しない
- **提案**:
  - TCP-DI でベースライン測定を完了
  - Phase 4 で NIXL two-sided API または GPUDirect RDMA 対応インスタンス（p5en）での再測定

## 参考情報

### 既知の事実
- ✓ NIXL 接続は確立している（EFA アドレス挿入成功）
- ✓ Prefill は成功し、kv_transfer_params が生成される
- ✓ Proxy は kv_transfer_params を正しく Consumer に送信する
- ✗ Consumer が kv_transfer_params を受け取った後の処理が不明
- ✗ Producer メトリクス: Num successful transfers=0

### kv_transfer_params の例
```json
{
  "do_remote_prefill": true,
  "do_remote_decode": false,
  "remote_block_ids": [5877, 5878, ...],
  "remote_engine_id": "0d09553d-878c-42d7-bceb-003ea634bdb4",
  "remote_host": "172.31.2.221",
  "remote_port": 50100,
  "tp_size": 2
}
```

### ログファイルの場所
- Producer: `/home/ubuntu/producer_efa.log`
- Consumer: `/home/ubuntu/consumer_efa.log`
- Proxy: `/home/ubuntu/proxy.log`
