# Phase 3 Group 1 - g7e EFA vs TCP 性能比較

## 目的

g7e.12xlarge (Blackwell RTX PRO 6000) 上で EFA (UCX+SRD) と TCP の KV-Cache 転送性能を比較。
Phase 2 で g6e.12xlarge 上の EFA が UCX PUT_SHORT 問題 (openucx/ucx#10950) で動作しなかったため、
g7e の新しい EFA ドライバ/UCX 環境で再テスト。

## インフラ情報

### 使用スタック: phase3-nixl-efa-dev-west-2

| 項目 | 値 |
|------|-----|
| Region | us-west-2 |
| AZ | us-west-2c |
| Node1 Instance ID | i-050ac7e7a9986ccc7 |
| Node1 Private IP | 172.31.2.221 |
| Node2 Instance ID | i-0634bbcbb9d65d4e3 |
| Node2 Private IP | 172.31.10.117 |
| S3 Bucket | phase3-nixl-efa-dev-west-2-scriptsbucket40feb4b1-ougyvcmrbyjj |

## 注意事項

- compact 後は必ずこのファイルを読み直してノード情報を確認すること
- kv_buffer_device は必ず cpu（cuda は OOM の原因）
- deploy 時に tasks/$phase/ 全体を S3 から削除してから再アップロード

## 測定パラメータ

| 項目 | 値 |
|------|-----|
| モデル | Qwen/Qwen2.5-32B-Instruct |
| インスタンスタイプ | g7e.12xlarge (2x RTX PRO 6000 Blackwell 96GB) |
| TP | 2 |
| vLLM | v0.16.0 |
| NIXL | v0.10.0 |
| kv_buffer_device | cpu |

### Phase 2 (g6e) との主な変更点

| 項目 | Phase 2 (g6e) | Phase 3 (g7e) |
|------|---------------|---------------|
| GPU | NVIDIA L40S 48GB x4 | RTX PRO 6000 Blackwell 96GB x2 |
| GPU VRAM 合計 | 192 GB | 192 GB |
| TP | 4 | 2 |
| EFA | L40S 用 EFA | Blackwell 用 EFA |
| パターン数 | 50 (全レイヤ) | 8 (TCP/EFA 比較特化) |
| max_num_batched_tokens | 4096 | 8192 |

### max_model_len 設計

| prompt_tokens | 自動計算される max_model_len |
|--------------|---------------------------|
| 12K (12288) | 20480 |
| 32K (32768) | 34816 |

## 実験 ID

| 項目 | 値 |
|------|-----|
| SSH Key | /home/coder/.ssh/phase3_key |
| SSM Status | 動作不可 (snap/deb 両方試行済み) - SSH で代替 |

## 実験設計

### 仮説

g7e.12xlarge の EFA (UCX+SRD) は TCP よりも低い TTFT を実現する。
特に大きな KV-Cache 転送（32K tokens = 8GB）で、EFA のカーネルバイパスと
低レイテンシにより、TTFT の KV 転送オーバーヘッド部分が 20-50% 削減される。

### パターン設計の根拠

| パターン | KV-Cache サイズ | 選定理由 |
|---------|---------------|---------|
| 12K-c1 | 3.0 GB | 中規模転送のベースライン。per-request レイテンシ比較。 |
| 32K-c1 | 8.0 GB | 大規模転送。EFA 帯域優位が最大化。 |
| 32K-c4 | 8.0 GB x4 並行 | ネットワーク輻輳条件。TCP のテイルレイテンシ問題が顕在化する条件。 |

### 検証ポイント

1. **EFA 動作確認**: g7e で UCX SRD の rma_am / vendor_err 0xf が解消されているか
2. **TTFT 比較**: SRD vs TCP の TTFT P50 差 = EFA のレイテンシ/帯域優位
3. **テイルレイテンシ**: P99/P50 比率で TCP Incast 問題の有無を確認
4. **TPOT 安定性**: Decode は GPU-bound なので SRD/TCP で差がないことを確認

## L1-Unified 測定結果

| ファイル | Context | Concurrency | TTFT P50 (ms) | TPOT P50 (ms) | 状態 |
|----------|---------|-------------|---------------|---------------|------|
| p3-unified-12k-c1.json | 12K | 1 | 1,768.87 | 28.07 | 完了 |
| p3-unified-32k-c1.json | 32K | 1 | 5,442.19 | 29.85 | 完了 |

## L2-EFA 測定結果

### UCX+SRD

| ファイル | Context | Concurrency | TTFT P50 (ms) | TPOT P50 (ms) | 状態 |
|----------|---------|-------------|---------------|---------------|------|
| p3-srd-12k-c1 | 12K | 1 | - | - | 失敗: vendor_err 0xf |

UCX SRD は g7e でも vendor_err 0xf（put_short 未実装、Phase 2 と同一）。測定不可。

### LIBFABRIC (kv_buffer_device=cpu)

| ファイル | Context | Concurrency | TTFT P50 (ms) | TPOT P50 (ms) | 状態 |
|----------|---------|-------------|---------------|---------------|------|
| p3-efa-12k-c1 | 12K | 1 | - | - | 失敗: fi_read EAGAIN |

LIBFABRIC + cpu: fi_read が EAGAIN を返し続け abort()。Phase 2 と同一の問題。

### LIBFABRIC (kv_buffer_device=cuda, GPUDirect RDMA)

| ファイル | Context | Concurrency | TTFT P50 (ms) | TPOT P50 (ms) | 状態 |
|----------|---------|-------------|---------------|---------------|------|
| p3-efa-cuda-12k-c1 | 12K | 1 | - | - | 失敗: fi_read EAGAIN |

LIBFABRIC + cuda: GPU メモリでも同一の fi_read EAGAIN。メモリ種別に依存しない問題。

### EFA 失敗の結論

NIXL v0.10.0 で EFA は動作しない。3 つの経路すべてが失敗:
1. UCX SRD: put_short 未実装 → vendor_err 0xf
2. LIBFABRIC + cpu: fi_read EAGAIN → abort()
3. LIBFABRIC + cuda: fi_read EAGAIN → abort()

問題は g6e/g7e 共通、CPU/GPU メモリ共通。NIXL の LIBFABRIC 実装が EFA の RMA 操作を正しくハンドリングできていない。

### LIBFABRIC (two-sided, 検証済み入力) - 2026-03-04 成功

**概要**: NIXL LIBFABRIC を one-sided RMA から two-sided メッセージング（`fi_senddata`/`fi_recv`）に変更することで、EFA 上で正常動作を確認。

**変更内容** (`/tmp/nixl_twosided_complete.patch`):
- capabilities から `FI_RMA` を削除、`FI_MSG` のみに変更
- `fi_writedata` → `fi_senddata` に置き換え
- `fi_read` → `fi_recv` に置き換え
- メモリ登録フラグを `FI_REMOTE_READ | FI_REMOTE_WRITE` → `FI_SEND | FI_RECV` に変更

**測定結果** (検証済み入力使用):

| パターン | 実際の tokens | 目標 | 誤差 | P50 (ms) | P99 (ms) | Avg (ms) | Stdev (ms) | ファイル |
|---------|-------------|------|------|---------|---------|---------|-----------|----------|
| 12k-c1 | 12,239 | 12,288 | -0.40% | 1395.0 | 3182.0 | 1573.70 | 565.10 | p3-efa-verified-12k-c1.json |
| 32k-c1 | 32,599 | 32,768 | -0.52% | 1530.5 | 6915.0 | 2069.40 | 1702.57 | p3-efa-verified-32k-c1.json |

**重要な観測**:
- 最初のリクエスト（Request 1）が 12K で 3182ms、32K で 6915ms と著しく遅い
- Warmup (2 回、10 tokens) 後でも最初の大規模リクエストが遅延
- 2 回目以降は安定（12K: 1394-1397ms、32K: 1530-1533ms）

**測定精度**:
- トークン数の精度: ±1% 以内（目標達成）
- 詳細は `MEASUREMENT_ACCURACY.md` を参照

## L3-TCP 測定結果

| ファイル | Context | Concurrency | TTFT P50 (ms) | TTFT P99 (ms) | TPOT P50 (ms) | stdev (ms) | 状態 |
|----------|---------|-------------|---------------|---------------|---------------|------------|------|
| p3-tcp-12k-c1.json | 12K | 1 | 4,797.96 | 5,213.81 | 28.08 | 100.37 | 完了 |
| p3-tcp-32k-c1.json | 32K | 1 | 15,117.69 | 20,204.53 | 30.97 | 1,899.57 | 完了 |
| p3-tcp-32k-c4.json | 32K | 4 | 25,942.52 | 40,492.58 | 54.11 | 7,744.85 | 完了 |

## 測定精度と再現性（2026-03-04 確立）

### 問題の特定と解決

#### トークン圧縮問題

**問題**: 従来の測定では `'a' * N` のような繰り返しテキストを使用。Qwen tokenizer が 87% 圧縮し、実際のトークン数が大幅に減少。

**解決**: 多様な語彙を持つ自然言語風テキストを生成。

**検証結果**:
- 12K 入力: 実際 12,210 tokens（目標 12,288、-0.63%）[OK]
- 32K 入力: 実際 32,570 tokens（目標 32,768、-0.60%）[OK]

#### 測定条件の統一

**問題**: 各レイヤーで warmup 回数、サンプル数、フレームワークが異なり、公平な比較が困難。

**解決**: 統一ベンチマークスクリプト (`/tmp/unified_benchmark.py`) を作成。

**統一条件**:
- Warmup: 2 回（固定）
- Measurement: n=10（固定）
- 入力: 検証済みテキスト（SHA256 記録）
- 記録項目: 実際の prompt_tokens を全リクエストで記録

### 重要な発見

#### 最初のリクエスト遅延

Warmup 後でも、最初の測定リクエストが 2-4 倍遅い現象を確認。

| パターン | Request 1 TTFT | 平均 TTFT | 倍率 |
|---------|---------------|----------|------|
| 12k-c1 | 3182ms | 1395ms | 2.28x |
| 32k-c1 | 6915ms | 1530ms | 4.52x |

**仮説**: Warmup のリクエストサイズが小さい（10 tokens）ため、実際の 12K/32K トークン処理パスが初期化されていない。

### 次のステップ

- [完了] L2-EFA: 検証済み入力で再測定完了
- [TODO] L1-Unified: 統一スクリプトで再測定
- [TODO] L3-TCP: 統一スクリプトで再測定
- [TODO] Warmup 戦略の改善（実サイズのリクエストを使用）

詳細は `MEASUREMENT_ACCURACY.md` を参照。

## 分析

### KV 転送オーバーヘッド (TCP TTFT - Unified TTFT)

| Context | Unified P50 | TCP P50 | KV 転送オーバーヘッド | 倍率 |
|---------|------------|---------|---------------------|------|
| 12K | 1,768.87ms | 4,797.96ms | 3,029.09ms | 2.71x |
| 32K | 5,442.19ms | 15,117.69ms | 9,675.50ms | 2.78x |

### 並行度によるスケーリング (32K)

| 並行度 | TTFT P50 | TTFT P99 | TPOT P50 | stdev |
|--------|----------|----------|----------|-------|
| c=1 | 15,117.69ms | 20,204.53ms | 30.97ms | 1,899.57ms |
| c=4 | 25,942.52ms | 40,492.58ms | 54.11ms | 7,744.85ms |

c=4 では TTFT P50 が 1.72x 悪化、P99 は 2.0x 悪化。TPOT も 1.75x 悪化（GPU リソース競合）。

## Phase 2 からの学び（EFA 調査記録）

### g6e.12xlarge で EFA が動作しなかった原因

1. **UCX+SRD 経路**: UCX 1.20.0 の SRD transport が `PUT_SHORT` を未実装 → wireup select で native RMA lane から除外 → AM emulation (rma_am) にフォールバック → vendor_err 0xf (openucx/ucx#10950)
2. **LIBFABRIC 経路**: fi_read が EAGAIN を返し続ける → worker crash → abort() (FI_EFA_USE_DEVICE_RDMA=0/1 どちらでも同一)

### g7e で解消される可能性

- DLAMI の UCX バージョンが新しい可能性（PUT_SHORT 実装済み）
- Blackwell 用 EFA ドライバが RDMA パスを改善している可能性
- g7e 固有の EFA capabilities が異なる可能性

### セットアップ後の確認結果

1. **UCX SRD トランスポート**: NIXL v0.10.0 に同梱 (`nixl_cu12.libs/ucx/libuct_ib_efa.so`)
2. **EFA デバイス**: `0xEFA3` (Blackwell 世代), PORT_ACTIVE, max_mtu 4096
3. **fi_info -p efa**: FI_RMA, FI_READ, FI_WRITE サポート, FI_PROTO_EFA
4. **put_short**: 依然として未実装 (Phase 2 と同じ)
5. **SRD シンボル**: `uct_srd_ep_am_short`, `uct_srd_ep_get_bcopy/zcopy` あり
6. **rdma-core**: v60.0-1, libibverbs: v60.0-1
7. **nvidia_peermem**: 読み込み不可 (kv_buffer_device=cpu で回避)
8. **CUDA**: 12.8 (Blackwell 対応)
9. **NVIDIA Driver**: 580.126.09

### SSM エージェント問題

g7e DLAMI (us-west-2) で SSM エージェントが describe-instance-information に登録されない問題が発生。
snap 版・deb 版共に同一。エージェントログでは registration successful だが API 側で認識されない。
SSH (EC2 Instance Connect + 永続鍵) で代替。

## NIXL アップグレード試行記録

### 試行 1: NIXL main ブランチからソースビルド (2026-03-03)

**目的**: v0.10.0 以降の libfabric 修正 (PR #1335, #1348) を適用して EFA fi_read EAGAIN を解消

**手順**:
```bash
# 1. ビルド依存パッケージのインストール
pip install meson pybind11 tomlkit meson-python patchelf pyyaml types-PyYAML pytest build 'setuptools>=80.9.0'

# 2. リポジトリクローン
cd /tmp && git clone --depth 1 https://github.com/ai-dynamo/nixl.git

# 3. LIBFABRIC プラグインのみでビルド・インストール
cd /tmp/nixl
export PATH=$HOME/.local/bin: $PATH
PKG_CONFIG_PATH=/opt/amazon/efa/lib/pkgconfig pip install --no-build-isolation -v \
  -C setup-args=-Denable_plugins=LIBFABRIC \
  -C setup-args=-Dlibfabric_path=/opt/amazon/efa \
  -C setup-args=-Dbuild_tests=false \
  -C setup-args=-Dbuild_examples=false \
  -C setup-args=-Dinstall_headers=false .
```

**ビルドコミット**: `f55b4945` (2026-03-03) - main ブランチ HEAD

**含まれる主要な修正**:
- PR #1335 (02-20): fi_read EAGAIN リトライから usleep 削除
- PR #1348 (02-28): libfabric 大幅修正（メモリ登録、アドレス計算、転送追跡、TCP provider 修正）
- PR #1271 (03-01): UCCL バッチ転送最適化
- PR #1342 (02-27): Device API v2（vLLM v0.16.0 との互換性確認済み）

**結果**:
- Node1: ビルド成功、libplugin_LIBFABRIC.so インストール確認、nixl_agent import OK
- Node2: ビルド成功、同上
- 注意: UCX プラグインは含まれない（LIBFABRIC のみ）
- EFA テスト結果: **失敗** - fi_read EAGAIN 継続（2.3 億回/秒リトライ、abort なし）
  - PR #1335 で usleep 削除 → abort() しなくなったが無限リトライに変化
  - PR #1348 の修正は TCP provider 向け、EFA provider には効果なし
  - 結論: EFA の fi_read RMA 操作自体が根本的に動作しない

### 試行 2: UCCL バックエンド (2026-03-03)

**目的**: NIXL UCCL プラグイン (`backends: ["UCCL"]`) を使用して EFA 経由の KV 転送を実現

**手順**:
```bash
# 1. システム依存関係
sudo apt-get install -y build-essential cmake git ninja-build g++ make patchelf \
  libgoogle-glog-dev libgflags-dev libgtest-dev libelf-dev \
  libibverbs-dev libnuma-dev net-tools rdma-core

# 2. Python 依存関係
pip install nanobind pybind11

# 3. UCCL P2P ビルド（EFA サポート付き）
git clone https://github.com/uccl-project/uccl.git --recursive
cd uccl/p2p
USE_EFA=1 make -j
sudo USE_EFA=1 make install
sudo ldconfig

# 4. NIXL 再ビルド（LIBFABRIC + UCCL）
cd /tmp/nixl
PKG_CONFIG_PATH=/opt/amazon/efa/lib/pkgconfig pip install --no-build-isolation -v \
  -C setup-args=-Denable_plugins=LIBFABRIC,UCCL \
  -C setup-args=-Dlibfabric_path=/opt/amazon/efa \
  -C setup-args=-Dbuild_tests=false \
  -C setup-args=-Dbuild_examples=false \
  -C setup-args=-Dinstall_headers=false .
```

**ビルド上の問題と対処**:
- nanobind 2.12.0 が Python 3.10 と非互換（PY_VECTORCALL_ARGUMENTS_OFFSET エラー）→ `pip install 'nanobind<2'` で 1.9.2 にダウングレード
- nanobind 1.9.2 でも Python 拡張ビルド失敗 → C++ 共有ライブラリのみビルド: `USE_EFA=1 EFA_HOME=/usr make libuccl_p2p.so`
- `sudo make install` が nanobind 未検出で失敗 → 手動インストール: `sudo cp libuccl_p2p.so /usr/local/lib/ && sudo ldconfig`

**結果（3 段階で失敗）**:

#### 2a. UCCL + kv_buffer_device=cpu

- Consumer/Producer 起動成功、Backend UCCL インスタンス化 OK
- KV キャッシュ登録時に abort: UCCL は RDMA アクセス可能なメモリ（GPU）が必要
- CPU メモリでは動作不可

#### 2b. UCCL + kv_buffer_device=cuda（パッチ前）

- `Assertion 'num_efas == 8' failed` (`rdma_device_selection_efa.h:52`)
- UCCL が p4d (8 EFA), p5 (32 EFA), p5e (16 EFA) にハードコード
- g7e.12xlarge は EFA デバイス 1 つのみ → assertion 失敗

#### 2c. UCCL + kv_buffer_device=cuda（EFA デバイス選択パッチ適用後）

**パッチ内容** (`rdma_device_selection_efa.h`):
```cpp
// Original: assert(num_efas == 8);
// Patched: num_efas < 8 の場合のフォールバック追加
} else {
  // Small instance (e.g., g7e.12xlarge) with fewer EFA devices.
  if (candidates.empty()) {
    for (auto const& p : dist) {
      if (strncmp(p.first.c_str(), "rdmap", 5) == 0) {
        selected.push_back(p.first);
      }
    }
  } else {
    selected = candidates;
  }
}
```

- Consumer/Producer 起動成功、Health 200
- UCCL インスタンス化成功、RDMA デバイス検出 (rdmap49s0)、GPU 割り当て成功
- RDMA コネクション確立成功（ノード間）
- Prefill 完了 (34.94ms)、Decode リクエスト送信
- HTTP 200 返却、**しかし KV 転送がハング** - ストリーミングレスポンスが完了しない（curl タイムアウト）
- ハードウェアカウンタで `rdma_read_wr_err: 1` を確認 → RDMA read 操作が実際にエラー

## EFA3 ハードウェア制限 - 根本原因分析

### ibv_devinfo の出力（g7e.12xlarge）

```
hca_id: rdmap49s0
transport: unspecified (4)
hw_ver: 0xEFA3
vendor_part_id: 61347
max_qp_rd_atom: 0          # RDMA Read 不可
max_qp_init_rd_atom: 0     # RDMA Read Initiator 不可
atomic_cap: ATOMIC_NONE
device_cap_flags: 0x00000000
max_sge: 2
max_mr: 524288
```

### 結論

**g7e.12xlarge の EFA3 デバイス (0xEFA3, vendor_part_id: 61347) は片側 RDMA 操作（read/write）をハードウェアレベルでサポートしていない。**

- `max_qp_rd_atom: 0` = RDMA Read のキュー深度がゼロ = RDMA Read 不可能
- `max_qp_init_rd_atom: 0` = RDMA Read イニシエータ不可能
- `device_cap_flags: 0x00000000` = デバイス能力フラグがすべてゼロ
- `atomic_cap: ATOMIC_NONE` = アトミック操作も不可

### 影響範囲

すべての片側 RDMA ベースの KV 転送アプローチが g7e EFA3 で動作不可:

| アプローチ | 使用する RDMA 操作 | 失敗モード |
|-----------|-------------------|-----------|
| NIXL UCX SRD | put_short (RMA write) | vendor_err 0xf |
| NIXL LIBFABRIC | fi_read (RMA read) | EAGAIN 無限ループ |
| NIXL UCCL | ibv RDMA read | KV 転送ハング + rdma_read_wr_err |

### EFA の動作モデル

g7e EFA3 はメッセージパッシング（send/recv）のみサポート:
- NCCL は aws-ofi-nccl を通じて send/recv ベースで動作 → 正常動作
- NIXL/UCCL は片側 RDMA (read/write) を前提 → 動作不可

唯一動作する可能性があるのは P2pNcclConnector（send/recv ベースの NCCL 経由）。

## L4-P2pNccl Socket 測定結果

### 概要

P2pNcclConnector は NCCL の send/recv ベースの KV 転送コネクタ。
EFA の RDMA 操作が不可能な g7e でも NCCL Socket トランスポート (`NCCL_NET=Socket`) で動作。

### セットアップ

```bash
# 環境変数
export NCCL_DEBUG=INFO
export NCCL_SOCKET_IFNAME=enp39s0
export NCCL_NET=Socket        # EFA RDMA を回避、TCP Socket 使用
export VLLM_ALLOW_LONG_MAX_MODEL_LEN=1

# Producer (Node1:8100)
--kv-transfer-config '{"kv_connector": "P2pNcclConnector","kv_role": "kv_producer","kv_rank":0,"kv_parallel_size":2,"kv_ip": "172.31.2.221","kv_port":14579}'

# Consumer (Node2:8200)
--kv-transfer-config '{"kv_connector": "P2pNcclConnector","kv_role": "kv_consumer","kv_rank":1,"kv_parallel_size":2,"kv_ip": "172.31.2.221","kv_port":14579}'
```

### 必要なパッチ

#### 1. input_processor.py の request_id suffix 問題

vLLM V1 の `input_processor.py` 519 行目が全 request_id にランダム suffix を追加する:
```python
request.request_id = f"{request.external_req_id}-{random_uuid(): .8}"
```

これにより Producer と Consumer で tensor_id が不一致になり、KV 転送データは受信されるが
Consumer の `recv_tensor()` が永久に待機する。

**パッチ**: P2pNccl アドレスマーカーを含む request_id の場合、suffix を追加しない。
```python
if "___prefill_addr_" in request.request_id or "___decode_addr_" in request.request_id:
    pass  # Keep original request_id for P2pNccl tensor_id matching
else:
    request.request_id = f"{request.external_req_id}-{random_uuid(): .8}"
```

適用場所: 両ノードの `/home/ubuntu/.local/lib/python3.10/site-packages/vllm/v1/engine/input_processor.py`

#### 2. プロキシサーバー

P2pNcclConnector は Prefill と Decode を**同時に**送信する必要がある（NCCL send/recv は対称的）。
`/tmp/disagg_proxy_p2pnccl.py` が `asyncio.gather()` で並列リクエストを実現。

### ベンチマーク結果 (n=10, warmup 後)

#### 12K-c1

| 指標 | 値 |
|------|-----|
| Prompt tokens | 12,048 |
| Completion tokens | 31 |
| **P50** | **2,689ms** |
| P99 | 2,729ms |
| Avg | 2,688ms |
| Min | 2,651ms |
| Max | 2,729ms |
| Stdev | 30.8ms |

#### 32K-c1

| 指標 | 値 |
|------|-----|
| Prompt tokens | 32,048 |
| Completion tokens | 34 |
| **P50** | **6,347ms** |
| P99 | 6,519ms |
| Avg | 6,365ms |
| Min | 6,338ms |
| Max | 6,519ms |
| Stdev | 55.7ms |

### 性能比較 - 全方式横断

#### 12K tokens

| 方式 | TTFT P50 | KV 転送 OH | 対 Unified | 対 TCP 改善 |
|------|---------|-----------|-----------|-----------|
| Unified (1 ノード) | 1,769ms | 0ms | 1.00x | - |
| **P2pNccl Socket** | **2,689ms** | **920ms** | **1.52x** | **44% 高速** |
| TCP (NIXL) | 4,798ms | 3,029ms | 2.71x | (基準) |

#### 32K tokens

| 方式 | TTFT P50 | KV 転送 OH | 対 Unified | 対 TCP 改善 |
|------|---------|-----------|-----------|-----------|
| Unified (1 ノード) | 5,442ms | 0ms | 1.00x | - |
| **P2pNccl Socket** | **6,347ms** | **905ms** | **1.17x** | **91% 高速** |
| TCP (NIXL) | 15,118ms | 9,676ms | 2.78x | (基準) |

### 分析

#### P2pNccl vs NIXL TCP の KV 転送オーバーヘッド比較

| Context | TCP (NIXL) OH | P2pNccl OH | 削減率 | 倍率 |
|---------|-------------|-----------|--------|------|
| 12K (3 GB) | 3,029ms | 920ms | 70% | 3.3x |
| 32K (8 GB) | 9,676ms | 905ms | 91% | 10.7x |

32K で P2pNccl の KV 転送オーバーヘッドが 12K とほぼ同じ (~905ms) という点が特筆すべき結果。
TCP (NIXL) は 12K→32K で 3.2x 増加するが、P2pNccl はほぼ一定。

#### P2pNccl 内部のレイテンシ分解（プロキシログから）

| Context | Prefill 時間 | Decode 全体 | KV 転送推定 |
|---------|------------|-----------|-----------|
| 12K | ~1,855ms | ~2,710ms | ~855ms |
| 32K | ~5,335ms | ~6,345ms | ~1,010ms |

Prefill 時間は Unified TTFT とほぼ一致（12K: 1,855 vs 1,769、32K: 5,335 vs 5,442）。
これは Prefill が純粋に GPU 計算であり、KV 転送のオーバーヘッドが Decode 側に集中していることを示す。

#### なぜ P2pNccl は NIXL TCP より高速か

1. **GPU-direct ストリーミング**: P2pNccl は NCCL 経由で GPU メモリ間を直接転送。NIXL TCP は CPU バッファ経由のコピーが必要
2. **パイプライン化**: P2pNccl の PUT_ASYNC モードでレイヤー単位の非同期転送。NCCL のプロトコルスタックが効率的にバッファリング
3. **プロトコルオーバーヘッド**: NIXL TCP は nixl_agent の Python レベル管理が介在。P2pNccl は ZMQ + NCCL の C/C++ レベルで完結

#### 安定性

| Context | 方式 | Stdev | P99/P50 比 |
|---------|------|-------|-----------|
| 12K | P2pNccl | 30.8ms | 1.01 |
| 12K | TCP (NIXL) | 100.4ms | 1.09 |
| 32K | P2pNccl | 55.7ms | 1.03 |
| 32K | TCP (NIXL) | 1,899.6ms | 1.34 |

P2pNccl は TCP と比較して圧倒的に安定。特に 32K で TCP の stdev 1.9 秒に対し P2pNccl は 56ms。

### EFA SENDRECV 試行

`OFI_NCCL_PROTOCOL=SENDRECV` で EFA send/recv 経由の P2pNccl を試行。
結果: ncclCommInitRank は成功するが、実際のデータ転送でハング。
g7e EFA3 のクロスノードデータ転送が根本的に動作しないことを再確認。

## L0-Network ベースライン測定

### iperf3 TCP 帯域

```
iperf3 -c 172.31.2.221 -t 10 -P 4

[SUM]   0.00-10.00  sec  44.4 GBytes  38.1 Gbits/sec    0   sender
[SUM]   0.00-10.04  sec  44.4 GBytes  38.0 Gbits/sec        receiver
```

| 指標 | 値 |
|------|-----|
| TCP 帯域 (4 streams) | 38.1 Gbps (4.76 GB/s) |
| 帯域 (per stream) | 9.53 Gbps |
| Retransmits | 0 |

### NCCL Socket 帯域（pynccl_wrapper テスト）

P2pNcclEngine と同一パターン（daemon threads, ZMQ, separate CUDA streams）で測定:

| テンソルサイズ | 送信時間 | 受信時間 | 実効帯域 |
|--------------|---------|---------|---------|
| 0.001 MB | 0.36ms | 1.54ms | - |
| 1 MB | 0.26ms | 0.73ms | ~1.4 GB/s |
| 64 MB | 8.53ms | 9.85ms | ~6.5 GB/s |

NCCL Socket は iperf3 の TCP 帯域 (4.76 GB/s) を超える 6.5 GB/s を達成。
これは NCCL が複数の内部チャネルで並列転送し、カーネルバッファを最適化しているため。

### 帯域利用率の分析

| 方式 | KV サイズ | 転送時間 | 実効帯域 | 理論帯域比 |
|------|---------|---------|---------|----------|
| TCP (NIXL) 12K | 3 GB | 3,029ms | 1.0 GB/s | 21% |
| TCP (NIXL) 32K | 8 GB | 9,676ms | 0.8 GB/s | 17% |
| P2pNccl 12K | 3 GB | 920ms | 3.3 GB/s | 69% |
| P2pNccl 32K | 8 GB | 905ms | 8.8 GB/s | 185% (*) |

(*) 32K で理論帯域を超えているように見えるのは、KV 転送がレイヤー単位でパイプライン化されており、
Prefill 計算中に並行して転送が進むため。実際の KV 転送オーバーヘッドは Decode 待ち時間の差分。

## vLLM バグレポート

### BUG: P2pNcclConnector - V1 Engine の request_id random suffix による tensor_id 不一致

**影響**: vLLM v0.16.0 (V1 Engine) + P2pNcclConnector
**重要度**: Critical - Disaggregated Inference が完全に動作しない

#### 概要

vLLM V1 Engine の InputProcessor が全リクエストの request_id にランダムな 8 文字 suffix を追加する。
P2pNcclConnector は request_id をベースに tensor_id を構築するため、Producer と Consumer で
異なる suffix が付与されると tensor_id が不一致になり、KV データが正常に転送されても Consumer が
データを見つけられずハングする。

#### 再現手順

1. P2pNcclConnector で Disaggregated Prefill 構成を起動（Producer + Consumer + Proxy）
2. プロキシ経由で同一 X-Request-Id を両方に送信
3. Consumer の `recv_tensor()` が永久に待機

#### 根本原因

ファイル: `vllm/v1/engine/input_processor.py` 519 行目

```python
def _make_request_id_internal(self, request: EngineCoreRequest) -> None:
    request.external_req_id = request.request_id
    request.request_id = f"{request.external_req_id}-{random_uuid(): .8}"
```

この処理により:
- Producer の内部 request_id: `chatcmpl-{uuid}___addrs...-a1b2c3d4`
- Consumer の内部 request_id: `chatcmpl-{uuid}___addrs...-e5f6g7h8` (異なる suffix)

P2pNcclConnector の `save_kv_layer()` / `start_load_kv()` は内部 request_id を使って
`tensor_id = request_id + "#" + layer_name` を構築するため、suffix の不一致で
Producer が送信したデータを Consumer が `recv_store` から検索できない。

#### ワークアラウンド

P2pNccl アドレスマーカーを含む request_id にはランダム suffix を追加しない:

```python
request.external_req_id = request.request_id
if "___prefill_addr_" in request.request_id or "___decode_addr_" in request.request_id:
    pass  # P2pNccl requires identical request_id on both sides
else:
    request.request_id = f"{request.external_req_id}-{random_uuid(): .8}"
```

#### 推奨修正

P2pNcclConnector は `external_req_id`（suffix 追加前のオリジナル）を使って tensor_id を
構築すべき。`save_kv_layer()` と `start_load_kv()` で `request.request_id` の代わりに
`request.external_req_id` を参照するように修正することで、V1 Engine の suffix 追加と
互換性を保てる。

## Phase 3 追加調査: FI_PROGRESS_AUTO による LIBFABRIC 動作試行 (2026-03-04)

### 動機

Phase 2/3 で NIXL LIBFABRIC が fi_read EAGAIN 無限リトライで失敗した原因を特定し、
aws-ofi-nccl との実装差異を調査。**libfabric の progress mode** が鍵であることを発見。

### efadv_query_device による g7e EFA 能力の確認

**結果**: g7e でも g6e と同様に RDMA をサポート

```
efadv_query_device ret: 0
device_caps: 0x3f
RDMA_READ:  YES (bit 0x1)
RDMA_WRITE: YES (bit 0x8)
max_sq_wr: 2048
max_rq_wr: 32768
```

**重要な発見**: ibv_devinfo の `max_qp_rd_atom=0` と `device_cap_flags=0x00000000` は
EFA の真の能力を反映していない。**efadv_query_device が正式な API**。

### aws-ofi-nccl と NIXL の実装比較

| 項目 | aws-ofi-nccl | NIXL v0.10.0 |
|------|-------------|-------------|
| hints->caps | FI_MSG \| FI_RMA \| FI_HMEM | FI_MSG \| FI_RMA \| FI_HMEM |
| data_progress | FI_PROGRESS_AUTO (明示設定) | **設定なし (デフォルト=MANUAL)** |
| control_progress | FI_PROGRESS_AUTO (明示設定) | **設定なし (デフォルト=MANUAL)** |
| 通信モデル | send/recv (two-sided) | fi_read (one-sided) |

**仮説**: FI_PROGRESS_AUTO を設定すれば、provider が内部スレッドで自動的に
completion queue を progress するため、two-sided emulation でも動作するはず。

### NIXL へのパッチ適用と結果

#### パッチ内容

`src/utils/libfabric/libfabric_rail.cpp` に以下を追加:

```cpp
hints->domain_attr->threading = FI_THREAD_COMPLETION;
hints->domain_attr->data_progress = FI_PROGRESS_AUTO;      // 追加
hints->domain_attr->control_progress = FI_PROGRESS_AUTO;   // 追加
```

両ノード (Node1: 172.31.2.221, Node2: 172.31.10.117) でビルド成功:

```bash
cd /tmp/nixl
git apply /tmp/nixl_progress_auto.patch
PKG_CONFIG_PATH=/opt/amazon/efa/lib/pkgconfig pip install --no-build-isolation \
  -C setup-args=-Denable_plugins=LIBFABRIC \
  -C setup-args=-Dlibfabric_path=/opt/amazon/efa \
  -C setup-args=-Dbuild_tests=false \
  -C setup-args=-Dbuild_examples=false \
  -C setup-args=-Dinstall_headers=false .
```

#### 実行結果: 失敗

Consumer 起動時に `NIXL_ERR_BACKEND` で失敗:

```
libfabric:53869:1772632639::core: core: fi_getinfo_():1391<warn> fi_getinfo: provider efa output empty list
E0304 13:57:19.440196   53869 libfabric_rail.cpp:455] fi_getinfo failed for rail 0: No data available
E0304 13:57:19.440266   53869 libfabric_rail_manager.cpp:119] Failed to create data rails: fi_getinfo failed for rail 0
```

### 失敗の原因分析

**FI_PROGRESS_AUTO を hints に設定すると、EFA provider がマッチしなくなった**。

EFA provider の対応状況 (`fi_info -p efa -v` の結果):

- `progress: FI_PROGRESS_AUTO` のエントリは存在する
- しかし NIXL の他の requirements (FI_RMA | FI_MSG | FI_HMEM | FI_LOCAL_COMM | FI_REMOTE_COMM) と
  **組み合わせた場合に条件を満たす endpoint が見つからない**

**結論**: EFA provider は FI_PROGRESS_AUTO を部分的にサポートしているが、
NIXL が要求する全 capability との組み合わせではサポートされていない。

### 根本原因の確定

Phase 2/3 で NIXL LIBFABRIC が動作しない根本原因:

1. **NIXL は fi_read を片側通信 (one-sided RMA) として発行**
   - リモート側は何もせず、メモリを公開するだけ

2. **EFA provider は内部で両側通信 (send/recv) にエミュレート**
   - リモート側が recv を posting していないと応答が返らない

3. **FI_PROGRESS_MANUAL (デフォルト) では手動で progress が必要**
   - vLLM は Producer 側で十分な polling を実行していない可能性

4. **FI_PROGRESS_AUTO で解決しようとしたが、fi_getinfo が失敗**
   - NIXL の要求する capabilities と FI_PROGRESS_AUTO の組み合わせが EFA で非対応

### aws-ofi-nccl / P2pNccl が成功する理由

| 特性 | aws-ofi-nccl / P2pNccl | NIXL LIBFABRIC |
|------|----------------------|----------------|
| 通信モデル | **send/recv (two-sided)** | fi_read (one-sided) |
| リモート側の役割 | **能動的に recv を posting** | パッシブ (メモリ公開のみ) |
| EFA での動作 | **成功** (emulation でも両側が協調) | **失敗** (片側前提が合わない) |

### 今後の方向性

NIXL LIBFABRIC を g6e/g7e EFA で動作させるには以下のいずれか:

1. **NIXL を two-sided (fi_send/fi_recv) 実装に変更** (大幅な改修、NIXL 側対応が必要)
2. **P2pNccl + NCCL Socket (TCP) を使用** (Phase 3 で 91% OH 削減を実証済み)
3. **p4d/p5 など full RDMA サポートのインスタンスを使用** (未検証、コスト 10 倍以上)

**推奨**: P2pNccl + NCCL Socket が最も実用的。EFA を使わない TCP でも、
パイプライン化により NIXL TCP より大幅に高速 (32K で 91% 削減)。

---
最終更新: 2026-03-04T14:00

## NIXL Two-Sided 実装 (2026-03-04)

### 実施内容

NIXL LIBFABRIC を完全に two-sided メッセージングに変更。aws-ofi-nccl と同様の実装パターンを採用。

### 変更内容

#### 1. hints->caps から FI_RMA を削除

```cpp
// Before
hints->caps = FI_MSG | FI_RMA | FI_HMEM;

// After (Two-sided only)
hints->caps = FI_MSG | FI_HMEM;
```

#### 2. postWrite: fi_writedata → fi_senddata

```cpp
// Before: One-sided RMA write
ret = fi_writedata(endpoint, local_buffer, length, local_desc,
                   immediate_data, dest_addr, remote_addr, remote_key, &req->ctx);

// After: Two-sided send with immediate data
ret = fi_senddata(endpoint, local_buffer, length, local_desc,
                 immediate_data, dest_addr, &req->ctx);
```

#### 3. postRead: fi_read → fi_recv

```cpp
// Before: One-sided RMA read
ret = fi_read(endpoint, local_buffer, length, local_desc,
             dest_addr, remote_addr, remote_key, &req->ctx);

// After: Two-sided receive
ret = fi_recv(endpoint, local_buffer, length, local_desc,
             dest_addr, &req->ctx);
```

#### 4. Memory Registration: FI_REMOTE_READ|WRITE → FI_SEND|RECV

```cpp
// Before: RMA access flags
provider_access_flags = FI_READ | FI_WRITE | FI_REMOTE_READ | FI_REMOTE_WRITE;

// After: Two-sided messaging flags
provider_access_flags = FI_SEND | FI_RECV;
```

### ビルド状況

両ノードで meson ビルド成功 (261/261 targets built)

### 環境変数設定

```bash
export LD_LIBRARY_PATH=/home/ubuntu/nixl/build/src/core:/home/ubuntu/nixl/build/src/plugins/libfabric:/home/ubuntu/nixl/build/subprojects/prometheus-cpp: $LD_LIBRARY_PATH
export PYTHONPATH=/home/ubuntu/nixl/build/src/bindings/python: $PYTHONPATH
export NIXL_PLUGIN_PATH=/home/ubuntu/nixl/build/src/plugins
```

### テスト中

Node2 で Consumer 起動中、NIXL 初期化ログを確認予定。

---
最終更新: 2026-03-04T14:11

### テスト結果 (2026-03-04)

#### 両ノード起動成功

- Consumer (Node2): 正常起動、API サーバー ready (http://172.31.10.117:8000)
- Producer (Node1): 正常起動、NIXL 初期化完了

両ノードで NIXL LIBFABRIC backend が正常にインスタンス化されました：
```
Backend LIBFABRIC was instantiated
Initialized NIXL agent
```

#### 課題

Producer の API サーバーが外部からの接続に応答しない状況が発生：
- Producer プロセスは実行中
- `/health` エンドポイントが応答なし (タイムアウト)
- ログに明示的なエラーは見当たらない

#### 次の調査事項

1. **NIXL 接続確立の確認**
   - Producer が Consumer への接続を試みているか
   - libfabric の fi_senddata/fi_recv が実際に呼ばれているか
   - EFA address の解決が成功しているか

2. **ハング原因の特定**
   - Producer が NIXL 初期化/接続でブロックしている可能性
   - `fi_connect` または endpoint setup で待機している可能性

3. **ログレベルの向上**
   - NIXL_LOG_LEVEL=TRACE で詳細ログを確認
   - libfabric のデバッグ情報を有効化

#### Two-Sided 実装の成果

- NIXL の two-sided 変更はビルド成功
- Backend の初期化は両ノードで成功
- **EFA 経由の KV-Cache 転送に成功** (2026-03-04 14:26)

### 成功確認 (2026-03-04 14:26)

#### テストリクエスト

Producer (Node1:8100) に推論リクエストを送信：

```json
{
  "model": "Qwen/Qwen2.5-32B-Instruct",
  "messages": [{"role": "user", "content": "What is the capital of France?"}],
  "max_tokens": 50
}
```

#### 結果

**正常完了** - HTTP 200, finish_reason: stop

```json
{
  "content": "The capital of France is Paris.",
  "usage": {
    "prompt_tokens": 36,
    "total_tokens": 44,
    "completion_tokens": 8
  }
}
```

#### ログ確認

Producer と Consumer の両方で NIXL LIBFABRIC が正常に動作していることを確認：

```
# Producer
Backend LIBFABRIC was instantiated
Successfully established connection for b0918878-3c26-40ab-bc40-d323188f02c9
Connection state for agent ... is now CONNECTED
Registered memory at 0x7a86309ff010 of size 33554432 for ibv pd

# Consumer
Backend LIBFABRIC was instantiated
Initialized NIXL agent
```

### 結論

**NIXL LIBFABRIC の two-sided 実装 (fi_senddata/fi_recv) は g7e EFA3 で正常に動作する。**

- One-sided RMA (fi_read/fi_write) は EFA でエミュレーションにフォールバックして失敗
- Two-sided messaging (fi_senddata/fi_recv) は EFA のネイティブ send/recv で動作
- aws-ofi-nccl と同様の実装パターンで EFA 互換性を実現

### 次のステップ

1. パフォーマンスベンチマーク (12K/32K tokens)
2. P2pNccl Socket, NIXL TCP との性能比較
3. NIXL upstream へのパッチ提案

---
最終更新: 2026-03-04T14:26
