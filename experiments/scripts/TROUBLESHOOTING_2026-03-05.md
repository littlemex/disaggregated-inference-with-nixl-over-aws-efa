# トラブルシューティングログ: KV-Cache 転送問題

**日時**: 2026-03-05
**フェーズ**: Phase 3 L2-EFA ベンチマーク

## 問題の概要

Producer と Consumer を再起動後、Consumer が Producer の KV-Cache を全く取得できない問題が発生。

## 環境情報

### ノード構成

- **Producer (Node1)**: i-050ac7e7a9986ccc7, IP: 172.31.2.221, Port: 8100
- **Consumer (Node2)**: i-0634bbcbb9d65d4e3, IP: 172.31.10.117, Port: 8200
- **Proxy**: Node1 上で動作, Port: 8000

### ソフトウェアバージョン

- **vLLM**: v0.16.0
- **NIXL**: Producer 0.10.0, Consumer 0.10.1 (バージョン不一致に注意)
- **Model**: Qwen/Qwen2.5-32B-Instruct
- **TP**: 2
- **GPU**: g7e.12xlarge (RTX PRO 6000 Blackwell 96GB x2)

## 症状

### 1. 正常動作する部分

- [OK] Producer、Consumer、Proxy が正常に起動
- [OK] NIXL 接続が確立（EFA アドレス解決成功）
  ```
  NIXL compatibility check passed
  Successfully inserted address GID[fe80::892:7bff: fee8:26c9]
  ```
- [OK] Prefill フェーズは正常動作（38ms）
- [OK] kv_transfer_params が正しく生成される
  ```json
  {
    "do_remote_prefill": true,
    "do_remote_decode": false,
    "remote_block_ids": [5876],
    "remote_engine_id": "0d09553d-878c-42d7-bceb-003ea634bdb4",
    "remote_host": "172.31.2.221",
    "remote_port": 50100,
    "tp_size": 2
  }
  ```

### 2. 問題のある部分

- [NG] Consumer が KV-Cache を全く取得しない
- [NG] Producer ログ: `Releasing expired KV blocks ... retrieved by 0 decode worker(s)`
- [NG] Producer メトリクス: `Num successful transfers=0`
- [NG] Consumer ログ: KV-Cache 取得の試行ログが全くない
- [NG] Consumer GPU 使用率: 0%（Decode 処理をしていない）
- [NG] Proxy で SocketTimeoutError 発生（600 秒タイムアウト）

## 調査結果

### ネットワーク層

**NIXL サイドチャンネル設定** (正常):
- Producer: 172.31.2.221:50100 (LISTEN)
- Consumer: 172.31.10.117:50100 (LISTEN)
- EFA アドレス解決: 成功

**セキュリティグループ** (正常):
- Port 8100, 8200, 50100 が 172.31.0.0/16 で許可済み

### vLLM 設定

**Producer 設定** (start_producer_efa.sh):
```bash
export NIXL_BACKEND=LIBFABRIC
export FI_PROVIDER=efa
export VLLM_NIXL_SIDE_CHANNEL_HOST=172.31.2.221
export VLLM_NIXL_SIDE_CHANNEL_PORT=50100
export VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
export FI_LOG_LEVEL=info
export NIXL_LOG_LEVEL=INFO

--kv-transfer-config '{
  "kv_connector": "NixlConnector",
  "kv_role": "kv_producer",
  "kv_rank": 0,
  "kv_parallel_size": 2,
  "kv_ip": "172.31.2.221",
  "kv_buffer_device": "cpu",
  "kv_buffer_size": 5000000000,
  "kv_connector_extra_config": {"backends": ["LIBFABRIC"]}
}'
```

**Consumer 設定** (restart_consumer.sh):
```bash
export NIXL_BACKEND=LIBFABRIC
export FI_PROVIDER=efa
export VLLM_NIXL_SIDE_CHANNEL_HOST=172.31.10.117
export VLLM_NIXL_SIDE_CHANNEL_PORT=50100
export VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
export FI_LOG_LEVEL=info
export NIXL_LOG_LEVEL=INFO

--kv-transfer-config '{
  "kv_connector": "NixlConnector",
  "kv_role": "kv_consumer",
  "kv_rank": 1,
  "kv_parallel_size": 2,
  "kv_ip": "172.31.10.117",
  "kv_buffer_device": "cpu",
  "kv_buffer_size": 5000000000,
  "kv_connector_extra_config": {"backends": ["LIBFABRIC"]}
}'
```

### Proxy ログからの観察

**タイムアウトエラー**:
```
2026-03-05 04:51:48,744 - __main__ - ERROR - [Proxy] Error: Timeout on reading data from socket
aiohttp.client_exceptions.SocketTimeoutError: Timeout on reading data from socket
```

**正常なリクエストフロー**:
1. Proxy が Prefill リクエストを送信 → 成功（38ms）
2. Proxy が kv_transfer_params を取得 → 成功
3. Proxy が Decode リクエストを送信 → 送信成功
4. Consumer が 200 OK を返す → HTTP レスポンスは返る
5. ストリーミングボディが返ってこない → タイムアウト

## 前回の成功環境との違い

### 成功時 (前回セッション)

- Consumer は古いプロセス（PID 76278）のまま
- Producer のみを再起動
- KV-Cache 転送が正常動作
- External prefix cache hit rate: 100%

### 失敗時 (今回)

- Producer と Consumer の両方を新規起動
- NIXL 接続は確立するが、KV-Cache 転送が動作しない
- Consumer が KV-Cache 取得を試行しない

## 仮説

### 仮説 1: Consumer が kv_transfer_params を処理していない

- **証拠**: Consumer ログに取得の試行が全くない
- **可能性**: vLLM の内部処理で kv_transfer_params が無視されている

### 仮説 2: NIXL バージョン不一致

- **証拠**: Producer は 0.10.0、Consumer は 0.10.1
- **可能性**: プロトコルの互換性問題

### 仮説 3: 両ノード再起動後の初期化問題

- **証拠**: 前回は Consumer を再起動せずに成功
- **可能性**: NIXL の状態管理や接続初期化に問題

## 試行した解決策

### 1. GPU メモリクリーンアップ ✓

- Producer と Consumer の GPU メモリをリセット
- 結果: 起動は成功したが、KV-Cache 転送は動作せず

### 2. Consumer 再起動 ✓

- 複数回 Consumer を再起動
- 結果: NIXL 接続は確立するが、転送は動作せず

### 3. Proxy タイムアウト延長 ✓

- Prefill: 120s → 300s
- Decode: sock_read=600s
- 結果: タイムアウトは延長されたが、根本原因は未解決

### 4. デバッグログ有効化 (進行中)

- NIXL_LOG_LEVEL=DEBUG
- VLLM_LOGGING_LEVEL=DEBUG
- 結果: 未確認

## 次のアクション

### 優先度: 高

1. **デバッグログの確認**
   - Consumer の consumer_debug.log を確認
   - kv_transfer_params の処理を追跡

2. **NIXL バージョン統一**
   - Producer と Consumer を同じバージョンにする
   - 推奨: 0.10.1 に統一

3. **シンプルなテストケース**
   - 最小限のリクエストで KV-Cache 転送を検証
   - "Hello" (数トークン) → Producer → Consumer

### 優先度: 中

4. **vLLM の設定見直し**
   - --no-enable-prefix-caching の影響確認
   - --enable-chunked-prefill の影響確認

5. **以前成功した環境の再現**
   - Consumer を再起動せずに Producer だけ再起動
   - 古い Consumer プロセスとの違いを特定

### 優先度: 低

6. **代替実装の検討**
   - UCX SRD（vendor_err 0xf 問題）
   - TCP disaggregation（ベースライン比較用）

## 参考ファイル

- `/work/data-science/disaggregated-inference-with-nixl-over-aws-efa/experiments/scripts/disagg_proxy_server.py`
- `/work/data-science/disaggregated-inference-with-nixl-over-aws-efa/experiments/scripts/unified_benchmark.py`
- `/work/data-science/disaggregated-inference-with-nixl-over-aws-efa/experiments/scripts/README_benchmark.md`
- `/home/coder/phase3/group1/README.md`
- `/home/coder/phase3/group1/MEASUREMENT_ACCURACY.md`

## ログファイルの場所

### Node1 (Producer)

- `/home/ubuntu/producer_efa.log`
- `/home/ubuntu/proxy.log`

### Node2 (Consumer)

- `/home/ubuntu/consumer_restart.log`
- `/home/ubuntu/consumer_debug.log` (デバッグ版)

## 解決した問題（2026-03-05 午後）

### 問題 5: NIXL 未インストール

**原因**: Consumer ノードに nixl-cu12 がインストールされていなかった

**解決策**:
```bash
pip install nixl-cu12==0.10.0 --force-reinstall
```

### 問題 6: PyTorch バージョン不一致

**原因**: Consumer の torch が 2.10.0、vLLM 0.16.0 は torch==2.9.1 を要求

**解決策**:
```bash
pip uninstall torch torchvision torchaudio -y
pip install torch==2.9.1 torchvision==0.24.1 torchaudio==2.9.1
```

### 問題 7: GPU メモリ未解放

**原因**: 古い Worker プロセスが GPU メモリを占有（89GB）

**解決策**:
```bash
pkill -9 python3
sudo nvidia-smi --gpu-reset -i 0
sudo nvidia-smi --gpu-reset -i 1
```

## 再現可能な環境セットアップの確立

以下のスクリプトを作成し、再現可能性を確保：

1. **setup_vllm_nixl_environment.sh** - 環境セットアップ（バージョン固定）
2. **start_producer_efa.sh** - Producer 起動スクリプト
3. **start_consumer_efa.sh** - Consumer 起動スクリプト
4. **SETUP_INSTRUCTIONS.md** - 詳細なセットアップ手順書

### 確認済みの動作環境

| コンポーネント | バージョン | 状態 |
|--------------|----------|------|
| PyTorch | 2.9.1 | ✓ 正常 |
| vLLM | 0.16.0 | ✓ 正常 |
| NIXL | 0.10.0 | ✓ 正常 |
| Producer | Port 8100 | ✓ 起動成功 |
| Consumer | Port 8200 | ✓ 起動成功 |
| Proxy | Port 8000 | ✓ 起動成功 |
| EFA 接続 | LIBFABRIC | ✓ アドレス挿入成功 |

## 根本原因の特定（2026-03-05 午後）

### 問題 8: LIBFABRIC fi_read EAGAIN 失敗 [根本原因]

**日時**: 2026-03-05 午後
**調査チーム**: Opus 4.6 x 5 名
**ステータス**: [根本原因特定済み]

#### 症状（初期観察）
- Prefill フェーズは正常動作（2428ms for 12K tokens）
- kv_transfer_params が正しく生成される（remote_block_ids count=764）
- Proxy が Decode リクエストを Consumer に送信
- Consumer が HTTP 200 OK を返す
- **しかし Consumer のレスポンスが途中で切れる**

#### 調査結果

**kv_transfer_params は正しく処理されていた**:
1. API エンドポイント: `CompletionRequest.kv_transfer_params` を正しく受信
2. Engine Core: `SamplingParams.extra_args["kv_transfer_params"]` に格納
3. Worker: `NixlConnector.retrieve_kv_cache()` を呼び出し
4. Consumer は KV-Cache 取得を試行している

**実際の失敗箇所: LIBFABRIC fi_read**:
```
06:00:19  Consumer: NIXL compatibility check passed
06:00:19  Consumer: Producer EFA address inserted to AV
06:00:20  Consumer: fi_read returns EAGAIN (starts retry loop)
06:00:20-06:04:40  Consumer: 3100+ EAGAIN retries over 4 minutes
06:04:42  Consumer: EFA "Unreachable remote" error (err: 113, No route to host)
06:04:43  Consumer: Worker process crashes
```

#### 根本原因

**LIBFABRIC fi_read (one-sided RMA) とエミュレーション RMA の不整合**:

- NIXL LIBFABRIC backend は `fi_read` (one-sided RMA) を使用して KV-Cache を取得
- libfabric EFA provider は device RDMA をサポートするが、実装レベルでエミュレーション RMA（two-sided 要求）と不整合を起こす
- `fi_read` が "Resource temporarily unavailable" (EAGAIN) を繰り返し返す
- 4 分間のリトライ後、EFA レイヤーで "Unreachable remote" エラー（err: 113）

**Phase 2 での既知の問題**:

`/home/coder/phase2/group1/analy.md` 7.4 節より引用:

> LIBFABRIC backend で `FI_EFA_USE_DEVICE_RDMA=1` を設定してテストしたが、NIXL の fi_read (one-sided RMA) が libfabric のエミュレーション RMA (two-sided 要求) と不整合を起こし、同様に失敗した。fi_pingpong テストでもデータプレーン転送がハングすることを確認している。

#### 誤った仮説（調査前）

以下は**誤り**であることが判明:
- [NG] Consumer が kv_transfer_params を受け取っているが、vLLM の内部で無視されている
- [NG] nixl_connector.py の実装で、kv_transfer_params の処理がスキップされている
- [NG] Worker プロセスに kv_transfer_params が伝わっていない

**実際には**: すべての処理は正しく動作しており、RDMA レベルの通信失敗が問題でした。

## 解決策の提案

### Option 1: NIXL Two-Sided API への切り替え [推奨]

**方法**:
- `fi_senddata`/`fi_recv` (two-sided communication) を使用
- one-sided RMA (`fi_read`/`fi_write`) を使用しない

**利点**:
- エミュレーション RMA との不整合を回避
- EFA provider との互換性が向上

**課題**:
- NIXL v0.10.0 が two-sided API をサポートしているか確認が必要
- vLLM の NixlConnector で two-sided API を使用する設定方法を調査

**調査方法**:
```bash
# NIXL ドキュメントで two-sided API サポートを確認
python -c "import nixl; help(nixl.send_data)"

# NIXL の設定オプションを確認
export NIXL_USE_TWO_SIDED=1  # 仮の環境変数名
```

### Option 2: TCP Disaggregation への切り替え [短期的解決策]

**方法**:
- `kv_connector_extra_config` から `{"backends": ["LIBFABRIC"]}` を削除
- TCP ソケット通信にフォールバック

**利点**:
- Phase 2 で動作確認済み（TCP-DI は安定動作）
- 即座に測定を再開できる

**欠点**:
- EFA 100-200Gbps の帯域を活用できない
- Phase 3 の目的（EFA 性能測定）から外れる

**実装**:
```bash
# Producer 設定
--kv-transfer-config '{
  "kv_connector": "NixlConnector",
  "kv_role": "kv_producer",
  "kv_rank": 0,
  "kv_parallel_size": 2,
  "kv_ip": "172.31.2.221",
  "kv_buffer_device": "cpu",
  "kv_buffer_size": 5000000000
  // "kv_connector_extra_config": {"backends": ["LIBFABRIC"]} を削除
}'
```

### Option 3: UCX バックエンドへの切り替え [検証必要]

**方法**:
```bash
export NIXL_BACKEND=UCX
export UCX_TLS=self,tcp,efa
```

**Phase 2 での知見**:
- UCX SRD transport は PUT_SHORT 未実装
- native RMA を使えず、AM emulation 経由で失敗
- `openucx/ucx#10950` (OPEN) で報告済み、未解決

**推奨度**: 低（同様の RDMA 問題が発生する可能性が高い）

### Option 4: Phase 3 の目的再検討 [戦略的判断]

**現状認識**:
- Phase 3 の目的: g7e.12xlarge (Nitro v6, EFA 200Gbps) で LIBFABRIC EFA の性能を測定
- 問題: NIXL LIBFABRIC EFA が根本的に動作しない（one-sided RMA の実装制約）
- Phase 2 でも同じ問題が発生していた

**提案**:
1. **短期**: TCP-DI でベースライン測定を完了
   - g7e.12xlarge (Blackwell RTX PRO 6000 96GB) の GPU 性能を評価
   - Unified vs TCP-DI の比較を完了
2. **中期**: NIXL two-sided API サポートの確認
   - NIXL 開発チームに two-sided API の実装状況を問い合わせ
   - vLLM への統合方法を調査
3. **長期**: GPUDirect RDMA 対応インスタンスでの測定
   - p5en (H100 NVL, EFA 3200Gbps, GPUDirect RDMA 対応)
   - GPU VRAM → NIC 直接転送で RDMA 性能を最大化

## まとめ

### 根本原因の特定 [完了]

Producer と Consumer を両方とも再起動した後、環境セットアップは完了し、NIXL 接続も確立したが、実際の KV-Cache 転送が動作しない根本原因を特定しました。

**確認できたこと**:
- [OK] 環境は正しく構築されている（PyTorch 2.9.1, vLLM 0.16.0, NIXL 0.10.0）
- [OK] NIXL EFA 接続は確立している（EFA アドレス挿入成功）
- [OK] Prefill は正常動作し、kv_transfer_params が生成される
- [OK] Proxy は kv_transfer_params を正しく Consumer に送信する
- [OK] Consumer は kv_transfer_params を受け取り、処理を開始する
- [OK] vLLM の内部処理フローは正常に動作している

**根本原因**:
- [NG] **LIBFABRIC fi_read (one-sided RMA) が EAGAIN を繰り返す**
- [NG] libfabric EFA provider のエミュレーション RMA との不整合
- [NG] Phase 2 で既知の問題（7.4 節で報告済み）

### 次のステップ

**推奨アプローチ**: Option 1（NIXL Two-Sided API）を調査後、実現不可能であれば Option 2（TCP-DI）に切り替え

1. **NIXL two-sided API サポートの確認**（優先度: 高）
   - NIXL v0.10.0 のドキュメントで `fi_senddata`/`fi_recv` サポートを確認
   - vLLM NixlConnector での設定方法を調査

2. **TCP-DI への切り替え**（優先度: 高、Option 1 が不可の場合）
   - `kv_connector_extra_config` から LIBFABRIC を削除
   - Phase 3 測定を TCP で完了

3. **Phase 3 の目的再定義**（優先度: 中）
   - g7e.12xlarge の GPU 性能（Blackwell RTX PRO 6000 96GB）を評価
   - Unified vs TCP-DI の比較に焦点
   - EFA 測定は Phase 4 に延期（NIXL two-sided API 対応後）

### 学び

**誤った仮説に時間を費やさないための教訓**:
- 初期症状だけで判断せず、Phase 2 の知見を最初に確認すべきだった
- "kv_transfer_params が消失している" という仮説は誤りで、実際には RDMA レベルの問題
- vLLM の実装を深掘りする前に、NIXL/libfabric レイヤーのログを確認すべきだった
