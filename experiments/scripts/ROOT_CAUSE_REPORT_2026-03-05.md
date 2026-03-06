# 根本原因レポート: vLLM + NIXL KV-Cache 転送失敗

**日時**: 2026-03-05
**調査チーム**: Opus 4.6 x 5 名
**ステータス**: [完了] 根本原因を特定

---

## エグゼクティブサマリ

Phase 3 L2-EFA ベンチマークにおいて、Producer（Prefill ノード）から Consumer（Decode ノード）への KV-Cache 転送が全く動作しない問題が発生しました。5 名の Opus 4.6 チームによる深掘り調査の結果、**LIBFABRIC fi_read (one-sided RMA) が EAGAIN を繰り返し返し、最終的に EFA エラー（err: 113）で失敗する**ことが根本原因であると特定しました。

**重要**: この問題は Phase 2（g6e.12xlarge）でも報告されており、vLLM や kv_transfer_params の処理ロジックの問題ではなく、**NIXL LIBFABRIC EFA backend の実装制約**によるものです。

---

## 1. 問題の発生状況

### 1.1 初期症状

- **Prefill**: 成功（2428ms for 12K tokens）
- **kv_transfer_params**: 正しく生成（remote_block_ids count=764）
- **Proxy**: kv_transfer_params を Consumer に送信
- **Consumer**: HTTP 200 OK を返すが、レスポンスボディが途中で切れる
- **Producer**: "Num successful transfers=0"

### 1.2 環境情報

| 項目 | 値 |
|------|-----|
| インスタンス | g7e.12xlarge (RTX PRO 6000 Blackwell 96GB x2) |
| vLLM | v0.16.0 |
| NIXL | v0.10.0 (nixl-cu12) |
| PyTorch | 2.9.1 |
| Model | Qwen/Qwen2.5-32B-Instruct |
| TP | 2 |
| EFA | LIBFABRIC backend |
| kv_buffer_device | cpu |

---

## 2. 調査プロセス

### 2.1 チーム構成

| 役割 | 担当 | 主な成果 |
|------|------|----------|
| vllm-source-reader | nixl_connector.py 読解 | kv_transfer_params 処理フローを完全解明 |
| engine-core-analyzer | core.py 読解 | Engine Core での処理経路を確認 |
| api-endpoint-analyzer | api_server.py 読解 | API エンドポイントから Engine への伝播を確認 |
| log-correlator | ログ相関分析 | **fi_read EAGAIN を発見**（根本原因の特定） |
| implementation-diver | 全体統合 | Phase 2 の知見と照合 |
| team-lead | 調整・まとめ | 解決策の提案 |

### 2.2 調査の流れ

1. **Phase 1**: vLLM 実装の読解（並行実行）
   - nixl_connector.py (2775 lines): kv_transfer_params 処理フローを追跡
   - api_server.py: リクエストボディからの抽出方法を確認
   - core.py: Engine Core での処理経路を確認

2. **Phase 2**: kv_transfer_params 処理フローの統合
   ```
   CompletionRequest.kv_transfer_params
     → SamplingParams.extra_args["kv_transfer_params"]
     → engine_client.generate()
     → EngineCoreProc
     → Worker (NixlConnector.retrieve_kv_cache())
   ```

3. **Phase 3**: ログ相関分析
   - Producer/Consumer/Proxy のログをタイムスタンプで突き合わせ
   - **重要な発見**: Consumer ログで `fi_read` が EAGAIN を 3100+ 回返していることを確認

4. **Phase 4**: Phase 2 の知見との照合
   - `/home/coder/phase2/group1/analy.md` 7.4 節で同様の問題が報告されていることを確認

---

## 3. 根本原因

### 3.1 技術的詳細

**LIBFABRIC fi_read (one-sided RMA) とエミュレーション RMA の不整合**

1. **NIXL LIBFABRIC backend の動作**:
   - KV-Cache 取得に `fi_read` (one-sided RMA) を使用
   - Producer 側のメモリを Consumer から直接読み取る RDMA 操作

2. **libfabric EFA provider の制約**:
   - EFA デバイスは hardware RDMA をサポート（`device_caps: 0x3f`）
   - しかし、libfabric EFA provider の実装レベルで、エミュレーション RMA（two-sided 要求）と不整合を起こす

3. **失敗のタイムライン**:
   ```
   06:00:19  Consumer: NIXL compatibility check passed
   06:00:19  Consumer: Producer EFA address inserted to AV
   06:00:20  Consumer: fi_read returns EAGAIN (starts retry loop)
   06:00:20-06:04:40  Consumer: 3100+ EAGAIN retries over 4 minutes
   06:04:42  Consumer: EFA "Unreachable remote" error (err: 113, No route to host)
   06:04:43  Consumer: Worker process crashes
   ```

4. **エラーメッセージ**:
   - `fi_read`: "Resource temporarily unavailable" (EAGAIN)
   - EFA layer: "Unreachable remote" (err: 113, No route to host)

### 3.2 Phase 2 での既知の問題

`/home/coder/phase2/group1/analy.md` 7.4 節より引用:

> LIBFABRIC backend で `FI_EFA_USE_DEVICE_RDMA=1` を設定してテストしたが、NIXL の fi_read (one-sided RMA) が libfabric のエミュレーション RMA (two-sided 要求) と不整合を起こし、同様に失敗した。fi_pingpong テストでもデータプレーン転送がハングすることを確認している。

### 3.3 誤った仮説（調査前）

以下の仮説は**すべて誤り**であることが判明:

- [NG] Consumer が kv_transfer_params を受け取っているが、vLLM の内部で無視されている
- [NG] nixl_connector.py の実装で、kv_transfer_params の処理がスキップされている
- [NG] Worker プロセスに kv_transfer_params が伝わっていない

**実際には**: vLLM のすべての処理は正しく動作しており、RDMA レベルの通信失敗が問題でした。

---

## 4. 解決策の提案

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
python -c "import nixl; help(nixl)"

# NIXL の設定オプションを確認
export NIXL_USE_TWO_SIDED=1  # 仮の環境変数名
```

**実装例**（仮）:
```python
# nixl_connector.py 修正案（要調査）
# one-sided RMA
# data = self.nixl_agent.fi_read(remote_addr, size)

# two-sided communication に変更
self.nixl_agent.fi_recv_request(remote_addr, size)  # 受信要求を送信
data = self.nixl_agent.fi_recv_data()  # データを受信
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
# start_producer_efa.sh / start_consumer_efa.sh から以下を削除
# export NIXL_BACKEND=LIBFABRIC
# export FI_PROVIDER=efa

# kv_connector_extra_config から backends を削除
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

1. **短期 (Phase 3)**: TCP-DI でベースライン測定を完了
   - g7e.12xlarge (Blackwell RTX PRO 6000 96GB) の GPU 性能を評価
   - Unified vs TCP-DI の比較を完了
   - EFA 帯域は活用できないが、GPU 性能の評価は可能

2. **中期 (Phase 4)**: NIXL two-sided API サポートの確認
   - NIXL 開発チームに two-sided API の実装状況を問い合わせ
   - vLLM への統合方法を調査
   - two-sided API が利用可能になれば、Phase 3 環境で再測定

3. **長期 (Phase 5)**: GPUDirect RDMA 対応インスタンスでの測定
   - p5en (H100 NVL, EFA 3200Gbps, GPUDirect RDMA 対応)
   - GPU VRAM → NIC 直接転送で RDMA 性能を最大化
   - GPU-CPU 間コピーのオーバーヘッドを完全に排除

---

## 5. 学び

### 5.1 調査手法の改善点

**良かった点**:
- 5 名の Opus 4.6 チームによる並行調査が効率的だった
- log-correlator によるタイムスタンプベースの詳細分析が根本原因の発見につながった
- Phase 2 の知見と照合することで、既知の問題であることを確認できた

**改善点**:
- **Phase 2 の知見を最初に確認すべきだった**
  - 同じ問題が Phase 2 で報告されていたため、初期段階で確認すれば調査時間を短縮できた
- **初期症状だけで判断しない**
  - "Consumer が処理しない" という症状から "kv_transfer_params が消失" という誤った仮説を立てた
  - NIXL/libfabric レイヤーのログを最初に確認すべきだった
- **vLLM 実装の深掘りは最後の手段**
  - vLLM の実装を深掘りする前に、より低レイヤー（RDMA/EFA）の問題を確認すべき

### 5.2 技術的な学び

1. **NIXL LIBFABRIC EFA の制約**:
   - one-sided RMA (`fi_read`/`fi_write`) はエミュレーション RMA と不整合を起こす
   - two-sided communication (`fi_senddata`/`fi_recv`) への切り替えが必要

2. **UCX SRD の制約**:
   - PUT_SHORT 未実装により、native RMA を使えない
   - AM emulation 経由で失敗する

3. **Phase 3 の戦略的判断**:
   - EFA 性能測定が目的であっても、技術的制約により実現不可能な場合がある
   - TCP-DI でベースライン測定を完了し、GPU 性能評価に焦点を当てることが現実的

---

## 6. 次のステップ

### 6.1 即座に実行すべきこと（優先度: 高）

1. **Option 1 の調査**: NIXL two-sided API サポートの確認
   ```bash
   # NIXL v0.10.0 のドキュメント確認
   python -c "import nixl; help(nixl)"

   # two-sided API の有無を確認
   python -c "import nixl; print(dir(nixl.Agent))"
   ```

2. **Option 2 の実装**: TCP-DI への切り替え（Option 1 が不可の場合）
   - `start_producer_efa.sh` / `start_consumer_efa.sh` を修正
   - LIBFABRIC backend を無効化
   - Phase 3 測定を TCP で実行

### 6.2 中期的なアクション（優先度: 中）

1. **NIXL 開発チームへの問い合わせ**
   - two-sided API の実装状況
   - LIBFABRIC EFA backend での推奨される使用方法
   - UCX backend の SRD サポート状況

2. **Phase 3 の目的再定義**
   - g7e.12xlarge の GPU 性能評価に焦点
   - Unified vs TCP-DI の比較測定を完了
   - EFA 性能測定は Phase 4 に延期

### 6.3 長期的なアクション（優先度: 低）

1. **GPUDirect RDMA 対応インスタンスでの測定計画**
   - p5en (H100 NVL) での Phase 5 測定を計画
   - GPU VRAM → NIC 直接転送による性能向上を評価

2. **vLLM/NIXL への Contribution 検討**
   - two-sided API サポートの Pull Request
   - LIBFABRIC EFA backend の改善提案

---

## 7. 参考資料

### 7.1 ドキュメント

- `/work/data-science/disaggregated-inference-with-nixl-over-aws-efa/experiments/scripts/TROUBLESHOOTING_2026-03-05.md`
- `/work/data-science/disaggregated-inference-with-nixl-over-aws-efa/experiments/scripts/investigation_plan_2026-03-05.md`
- `/home/coder/phase2/group1/analy.md` (7.4 節)

### 7.2 ログファイル

- Producer: `/home/ubuntu/producer_efa.log`
- Consumer: `/home/ubuntu/consumer_efa.log`
- Proxy: `/home/ubuntu/proxy.log`

### 7.3 関連 Issue

- `openucx/ucx#10950`: UCX SRD で native RMA があるのに AM emulation が使われる (OPEN)

---

**作成日**: 2026-03-05
**最終更新**: 2026-03-05
**作成者**: Opus 4.6 x 5 名チーム + team-lead
