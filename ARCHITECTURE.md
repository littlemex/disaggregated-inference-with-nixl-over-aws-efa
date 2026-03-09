# アーキテクチャ設計書

Disaggregated KV Cache Inference with NIXL over AWS EFA

## 目次

1. [システム概要](#システム概要)
2. [アーキテクチャ図](#アーキテクチャ図)
3. [コンポーネント詳細](#コンポーネント詳細)
4. [通信フロー](#通信フロー)
5. [デプロイメントアーキテクチャ](#デプロイメントアーキテクチャ)
6. [技術的意思決定](#技術的意思決定)

## システム概要

### 目的

大規模言語モデル (LLM) の推論を Prefill フェーズと Decode フェーズに分離し、それぞれ異なる GPU ノードで実行することで、リソース利用効率を最適化する。

### 主要課題と解決策

| 課題 | 解決策 |
|------|--------|
| GPU リソースの効率的利用 | Prefill と Decode を分離し、各フェーズに最適なハードウェア割り当て |
| KV cache の高速転送 | AWS EFA + NIXL による低レイテンシ RDMA 通信 |
| 複雑なデプロイ手順 | SSM + S3 ベースの完全自動化、冪等性保証 |
| 環境依存性 | Ubuntu 24.04 DLAMI の /opt/pytorch 環境を統一使用 |

## アーキテクチャ図

### レイヤー構成

```
┌─────────────────────────────────────────────────────────────────┐
│                        Application Layer                         │
│  ┌──────────────┐                           ┌──────────────┐    │
│  │   Client     │──────HTTP Request─────────│Proxy Server  │    │
│  │              │◄─────HTTP Response────────│    (Node2)   │    │
│  └──────────────┘                           │   Port: 8000 │    │
│                                              └──────┬───────┘    │
└────────────────────────────────────────────────────┼────────────┘
                                                      │
┌─────────────────────────────────────────────────────┼────────────┐
│                      Service Layer                  │            │
│  ┌──────────────────────┐          ┌───────────────┼──────────┐ │
│  │   vLLM Producer      │          │  vLLM Consumer│          │ │
│  │      (Node1)         │          │     (Node2)   │          │ │
│  │   Port: 8100         │          │  Port: 8200   │          │ │
│  │                      │          │               │          │ │
│  │  [Prefill Phase]     │          │ [Decode Phase]│          │ │
│  │  - Prompt 処理        │          │ - Token 生成   │          │ │
│  │  - KV cache 生成      │          │ - KV cache 参照│          │ │
│  │  - remote_block_ids  │          │               │          │ │
│  │    送信              │          │               │          │ │
│  └──────────┬───────────┘          └───────┬───────┘          │ │
└─────────────┼──────────────────────────────┼──────────────────┘ │
              │                              │                      │
┌─────────────┼──────────────────────────────┼──────────────────┐ │
│        Communication Layer                 │                  │ │
│  ┌──────────▼───────────┐          ┌──────▼────────────┐     │ │
│  │  NIXL Connector      │          │ NIXL Connector    │     │ │
│  │    (Producer)        │          │   (Consumer)      │     │ │
│  │                      │          │                   │     │ │
│  │  Side Channel (ZMQ)  │◄────────►│ Side Channel (ZMQ)│     │ │
│  │    Port: 50100       │          │   Port: 50100     │     │ │
│  │                      │          │                   │     │ │
│  │  KV Transfer         │──────────│ KV Retrieval      │     │ │
│  │  (fi_write)          │   EFA    │   (fi_read)       │     │ │
│  └──────────────────────┘   RDMA   └───────────────────┘     │ │
└──────────────────────────────┼──────────────────────────────┘ │
                               │                                  │
┌──────────────────────────────┼──────────────────────────────┐ │
│         Network Layer        │                              │ │
│  ┌───────────────────────────▼──────────────────────────┐   │ │
│  │         AWS EFA (Elastic Fabric Adapter)             │   │ │
│  │         - 100 Gbps bandwidth                         │   │ │
│  │         - Sub-microsecond latency                    │   │ │
│  │         - RDMA (Remote Direct Memory Access)         │   │ │
│  │         - libfabric API                              │   │ │
│  └──────────────────────────────────────────────────────┘   │ │
└──────────────────────────────────────────────────────────────┘ │
```

## コンポーネント詳細

### 1. Producer Node (Node1)

**役割**: Prefill フェーズの実行と KV cache の生成

**プロセス構成**:
```
vLLM API Server (Port 8100)
  ├─ Worker Process (GPU 0)
  │   ├─ Model: Qwen/Qwen2.5-32B-Instruct
  │   ├─ NIXL Connector (Producer mode)
  │   │   ├─ Side Channel: ZMQ (Port 50100)
  │   │   └─ Data Plane: LIBFABRIC (EFA)
  │   └─ KV Cache Manager
  └─ API Router (FastAPI/uvicorn)
```

**環境変数**:
```bash
NIXL_PLUGIN_DIR=/opt/pytorch/lib/python3.12/site-packages/nixl/_lib
FI_PROVIDER=efa
FI_LOG_LEVEL=debug
VLLM_NIXL_SIDE_CHANNEL_HOST=172.31.33.7
VLLM_NIXL_SIDE_CHANNEL_PORT=50100
NIXL_LOG_LEVEL=TRACE
```

**kv-transfer-config**:
```json
{
  "kv_connector": "NixlConnector",
  "kv_role": "kv_producer",
  "kv_rank": 0,
  "kv_parallel_size": 1,
  "kv_ip": "172.31.33.7",
  "kv_port": 14579,
  "kv_buffer_device": "cpu",
  "kv_buffer_size": 5000000000
}
```

### 2. Consumer Node (Node2)

**役割**: Decode フェーズの実行と KV cache の取得

**プロセス構成**:
```
vLLM API Server (Port 8200)
  ├─ Worker Process (GPU 0)
  │   ├─ Model: Qwen/Qwen2.5-32B-Instruct
  │   ├─ NIXL Connector (Consumer mode)
  │   │   ├─ Side Channel: ZMQ (Port 50100)
  │   │   └─ Data Plane: LIBFABRIC (EFA)
  │   └─ KV Cache Manager
  └─ API Router (FastAPI/uvicorn)

Proxy Server (Port 8000)
  ├─ aiohttp Web Server
  ├─ Connection Pooling (HTTP/1.1 keep-alive)
  └─ Request Router
```

**環境変数**:
```bash
NIXL_PLUGIN_DIR=/opt/pytorch/lib/python3.12/site-packages/nixl/_lib
FI_PROVIDER=efa
FI_LOG_LEVEL=debug
VLLM_NIXL_SIDE_CHANNEL_HOST=172.31.34.243
VLLM_NIXL_SIDE_CHANNEL_PORT=50100
NIXL_LOG_LEVEL=TRACE
```

**kv-transfer-config**:
```json
{
  "kv_connector": "NixlConnector",
  "kv_role": "kv_consumer",
  "kv_rank": 0,
  "kv_parallel_size": 1,
  "kv_ip": "172.31.34.243",
  "kv_port": 14579,
  "kv_buffer_device": "cpu",
  "kv_buffer_size": 5000000000
}
```

### 3. Proxy Server

**役割**: Prefill と Decode リクエストのルーティング

**実装**: `disagg_proxy_server.py` (aiohttp ベース)

**処理フロー**:
```python
async def handle_completion(request):
    # 1. Prefill リクエスト送信
    prefill_data = {
        "max_tokens": 1,
        "kv_transfer_params": {"do_remote_decode": True}
    }
    prefill_response = await session.post(
        f"{prefill_url}/v1/completions",
        json=prefill_data
    )

    # 2. kv_transfer_params 取得
    kv_params = prefill_response["kv_transfer_params"]
    # {
    #   "remote_block_ids": [[0, 1, 2, ...]],
    #   "kv_ip": "172.31.33.7",
    #   "kv_port": 14579
    # }

    # 3. Decode リクエスト送信（kv_transfer_params 付き）
    decode_data = {
        "stream": True,
        "kv_transfer_params": kv_params
    }
    async for chunk in session.post(
        f"{decode_url}/v1/completions",
        json=decode_data
    ):
        yield chunk
```

## 通信フロー

### 推論リクエストの完全フロー

```
Client                 Proxy              Producer           NIXL/EFA           Consumer
  │                     │                    │                   │                  │
  │──HTTP POST────────► │                    │                   │                  │
  │ /v1/completions     │                    │                   │                  │
  │                     │                    │                   │                  │
  │                     │──HTTP POST────────►│                   │                  │
  │                     │ max_tokens=1       │                   │                  │
  │                     │ do_remote_decode=T │                   │                  │
  │                     │                    │                   │                  │
  │                     │                    │ [Prefill Phase]   │                  │
  │                     │                    │ - Prompt 処理      │                  │
  │                     │                    │ - KV cache 生成    │                  │
  │                     │                    │ - Block 割り当て   │                  │
  │                     │                    │                   │                  │
  │                     │                    │──register_blocks──►                  │
  │                     │                    │   (ZMQ)           │                  │
  │                     │                    │                   │                  │
  │                     │◄──HTTP Response────│                   │                  │
  │                     │ kv_transfer_params │                   │                  │
  │                     │ {                  │                   │                  │
  │                     │   remote_block_ids │                   │                  │
  │                     │   kv_ip, kv_port   │                   │                  │
  │                     │ }                  │                   │                  │
  │                     │                    │                   │                  │
  │                     │──HTTP POST (stream)────────────────────────────────────► │
  │                     │ kv_transfer_params │                   │                  │
  │                     │                    │                   │                  │
  │                     │                    │                   │◄──fi_read(RDMA)──│
  │                     │                    │                   │   KV cache 取得   │
  │                     │                    │                   │                  │
  │                     │                    │                   │                  │ [Decode Phase]
  │                     │                    │                   │                  │ - KV cache 参照
  │                     │                    │                   │                  │ - Token 生成
  │                     │                    │                   │                  │
  │◄──HTTP Stream───────│◄────────────────────────────────────────────────────────│
  │ (Server-Sent Events)│                    │                   │                  │
  │                     │                    │                   │                  │
```

### NIXL プロトコル詳細

**Phase 1: 接続確立とハンドシェイク (ZMQ)**

```
Producer (Worker init)                    Consumer (Worker init)
    │                                          │
    │──bind(tcp://*:50100)                    │
    │                                          │
    │                     connect(tcp://producer:50100)──│
    │                                          │
    │◄─────────HANDSHAKE_REQUEST──────────────│
    │   {engine_id: "v9test-xxx"}             │
    │                                          │
    │──────────HANDSHAKE_RESPONSE─────────────►
    │   {engine_id: "v9test-xxx", status: OK} │
    │                                          │
```

**Phase 2: Block 登録 (ZMQ)**

```
Producer (after Prefill)                  Consumer
    │                                          │
    │──────────REGISTER_BLOCKS────────────────►
    │   {                                      │
    │     remote_block_ids: [[0,1,2,...]],    │
    │     kv_ip: "172.31.33.7",               │
    │     kv_port: 14579                      │
    │   }                                      │
    │                                          │
    │◄─────────ACK─────────────────────────────│
    │                                          │
```

**Phase 3: KV Cache 転送 (EFA/RDMA)**

```
Producer Memory                           Consumer Memory
┌─────────────┐                          ┌─────────────┐
│ KV Block 0  │                          │             │
│ KV Block 1  │◄──────fi_read(RDMA)──────┤ GPU Memory  │
│ KV Block 2  │         (EFA)            │             │
│    ...      │                          │             │
└─────────────┘                          └─────────────┘
   (CPU)                                    (CPU/GPU)
```

## デプロイメントアーキテクチャ

### インフラストラクチャ (AWS CDK)

```
┌────────────────────────────────────────────────────────────┐
│                        VPC                                 │
│  ┌──────────────────────────────────────────────────────┐  │
│  │           Subnet (ap-northeast-1a)                   │  │
│  │  ┌──────────────────┐    ┌──────────────────┐       │  │
│  │  │  EC2 Instance    │    │  EC2 Instance    │       │  │
│  │  │    (Node1)       │    │    (Node2)       │       │  │
│  │  │  g7e.12xlarge    │    │  g7e.12xlarge    │       │  │
│  │  │  - RTX PRO 6000  │    │  - RTX PRO 6000  │       │  │
│  │  │    96GB x 2      │    │    96GB x 2      │       │  │
│  │  │  - EFA enabled   │    │  - EFA enabled   │       │  │
│  │  │  - SSM managed   │    │  - SSM managed   │       │  │
│  │  └──────────────────┘    └──────────────────┘       │  │
│  │         │                        │                   │  │
│  │  ┌──────▼────────────────────────▼─────────┐        │  │
│  │  │     Placement Group (cluster)           │        │  │
│  │  │     - EFA 最適化                        │        │  │
│  │  │     - 低レイテンシ保証                  │        │  │
│  │  └─────────────────────────────────────────┘        │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
               │                          │
               │                          │
        ┌──────▼──────┐            ┌─────▼──────┐
        │ S3 Bucket   │            │  SSM       │
        │ - Plugins   │            │  - Session │
        │ - Scripts   │            │  - Commands│
        │ - Configs   │            │            │
        └─────────────┘            └────────────┘
```

### デプロイメント自動化 (SSM + S3)

```
Local Machine                 AWS S3                    Remote Nodes
     │                          │                           │
     │──1. Build Plugin─────────►                           │
     │   (meson, ninja)         │                           │
     │                          │                           │
     │──2. Upload───────────────►                           │
     │   - Plugin .so           │                           │
     │   - Scripts              │                           │
     │   - Templates            │                           │
     │                          │                           │
     │──3. SSM Command──────────┼──────────────────────────►
     │   send-command           │                           │
     │                          │                           │
     │                          │◄───4. Download──────────  │
     │                          │    aws s3 cp              │
     │                          │                           │
     │                          │                           │──5. Execute
     │                          │                           │   - Install vLLM
     │                          │                           │   - Install NIXL
     │                          │                           │   - Deploy Plugin
     │                          │                           │   - Start Services
     │                          │                           │
     │◄───6. Get Status────────────────────────────────────│
     │   get-command-invocation │                           │
     │                          │                           │
```

### タスク実行フロー

```
deploy-v9.sh
    │
    ├─ Task 00: Check libfabric-dev
    ├─ Task 01: Check local prerequisites
    ├─ Task 02: Clone NIXL from GitHub
    ├─ Task 03: Verify Request/Response protocol
    ├─ Task 04: Setup meson build
    ├─ Task 05: Build NIXL plugin
    ├─ Task 06: Verify plugin artifact
    ├─ Task 07: Upload plugin to S3
    ├─ Task 07b: Upload Proxy Server to S3
    ├─ Task 07c: Upload scripts to S3
    ├─ Task 08: Check SSM connectivity
    ├─ Task 08a: Producer GPU cleanup
    ├─ Task 08b: Consumer GPU cleanup
    │
    ├─ [Producer Setup]
    ├─ Task 09: Producer install vLLM
    ├─ Task 10: Producer install NIXL
    ├─ Task 11: Producer deploy plugin
    ├─ Task 12: Producer create kv-transfer-config
    ├─ Task 13: Producer create startup script
    ├─ Task 14: Producer verify setup
    │
    ├─ [Consumer Setup]
    ├─ Task 15: Consumer install vLLM
    ├─ Task 16: Consumer install NIXL
    ├─ Task 17: Consumer deploy plugin
    ├─ Task 18: Consumer create kv-transfer-config
    ├─ Task 19: Consumer create startup script
    ├─ Task 20: Consumer verify setup
    │
    ├─ [Proxy Setup]
    ├─ Task 21: Consumer deploy Proxy Server
    ├─ Task 22: Consumer install aiohttp
    ├─ Task 23: Consumer create Proxy startup script
    │
    └─ Task 24-29: Summary and instructions
```

## 技術的意思決定

### 1. Ubuntu 24.04 DLAMI 採用

**理由**:
- CUDA/PyTorch が事前インストール済み（/opt/pytorch）
- GPU ドライバーの互換性問題を回避
- デプロイ時間の大幅短縮（CUDA インストール不要）

**対応事項**:
- PEP 668 (externally-managed-environment) 対応
- bash flags を `set -eo pipefail` に統一（LD_LIBRARY_PATH 問題回避）

### 2. SSM (Systems Manager) 採用

**理由**:
- SSH キーペア管理不要
- セキュリティグループで SSH ポート開放不要
- IAM ロールベースの権限管理
- CloudWatch Logs への自動ログ記録

**トレードオフ**:
- コマンド実行結果の取得に非同期処理が必要
- リアルタイムのインタラクティブ操作が不可

### 3. S3 + Task Runner パターン

**理由**:
- スクリプトのバージョン管理が容易
- 複数ノードへの並列デプロイが可能
- 冪等性保証（タスクステート管理）
- 途中からの再実行が可能

**実装**:
```bash
# タスク定義 (JSON)
{
  "id": "09-producer-install-vllm",
  "name": "Producer: Install vLLM",
  "skip_if": "python3 -c 'import vllm'",
  "commands": [
    "echo '[INFO] Installing vLLM...'",
    "source ./ssm_helper.sh",
    "DOWNLOAD_CMD=\"aws s3 cp s3://${S3_BUCKET}/scripts/install-vllm.sh ...\"",
    "ssm_run_and_wait \"${NODE1_INSTANCE_ID}\" \"${AWS_REGION}\" \"${DOWNLOAD_CMD}\" 60"
  ]
}
```

### 4. NIXL Request/Response プロトコル採用

**理由**:
- Producer が明示的に Block 登録（`register_blocks`）
- Consumer が必要時に KV cache 取得（`fi_read` one-sided RDMA）
- Two-sided 通信（`fi_send/fi_recv`）よりシンプル

**実装箇所**:
- `littlemex/nixl: main` ブランチ
- `src/core/libfabric_backend.cpp` の `getConnInfo()` で conn_info_ を事前キャッシュ

### 5. Proxy Server v3 (Connection Pooling)

**理由**:
- TCP ハンドシェイク（SYN/SYN-ACK/ACK）を削減
- HTTP/1.1 keep-alive による接続再利用
- Proxy オーバーヘッドを 50-100ms 削減

**実装**:
```python
class DisaggregatedProxyServerV2:
    async def start(self):
        if self.session is None:
            self.session = aiohttp.ClientSession()  # 再利用
```

## パフォーマンス特性

### レイテンシ内訳（推定値）

| フェーズ | レイテンシ | 主要処理 |
|---------|-----------|---------|
| Proxy → Producer (Prefill) | 1-2 ms | HTTP + Prompt 処理 |
| Prefill 実行 | 50-100 ms | GPU 演算（モデルサイズ依存） |
| NIXL Block 登録 | 1-5 ms | ZMQ 通信 |
| Proxy → Consumer (Decode) | 1-2 ms | HTTP |
| KV Cache 転送 (EFA) | 1-10 ms | RDMA（データサイズ依存） |
| Decode 実行 (per token) | 10-20 ms | GPU 演算 |

**Total First Token Latency**: 約 64-139 ms

### スループット

- **EFA 帯域幅**: 100 Gbps = 12.5 GB/s
- **実効帯域幅**: 約 10 GB/s（80% 効率）
- **KV cache サイズ**: 約 1-5 GB（シーケンス長依存）
- **転送時間**: 100-500 ms

## 制約と今後の改善

### 現在の制約

1. **Single GPU per Node**: TP=1 のみ対応
2. **CPU KV Buffer**: GPU メモリ不足時の対応（`kv_buffer_device=cpu`）
3. **固定モデル**: Qwen2.5-32B-Instruct でのみ検証

### 今後の改善案

1. **Multi-GPU 対応**: TP=2, 4 での検証
2. **GPU KV Buffer**: メモリ許容時のパフォーマンス向上
3. **複数モデル対応**: Llama 3, Mistral などでの検証
4. **バッチ処理最適化**: 複数リクエストの並列処理
5. **メトリクス収集**: Prometheus/Grafana での可視化

## 参考資料

- [vLLM Disaggregated Inference Documentation](https://docs.vllm.ai/)
- [NIXL Architecture](https://github.com/littlemex/nixl/blob/main/docs/ARCHITECTURE.md)
- [AWS EFA Developer Guide](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa.html)
- [libfabric Programming Guide](https://ofiwg.github.io/libfabric/)

## 変更履歴

- **2026-03-09**: 初版作成（v0.3.0 ベース）
