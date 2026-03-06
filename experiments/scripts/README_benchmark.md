# 統一ベンチマークスクリプト

## 概要

Phase 3 実験において、すべてのレイヤー（L1 Unified, L2 EFA, L3 TCP）で統一条件でベンチマークを実行するためのスクリプト群です。

## 環境セットアップ（重要）

### 0. setup_vllm_nixl_environment.sh

**目的**: 再現可能な vLLM + NIXL 環境を構築

**重要**: Producer と Consumer の両方で**必ず同じバージョン**をインストールしてください。

**固定バージョン**:
- PyTorch: 2.9.1
- vLLM: 0.16.0
- NIXL: 0.10.0 (nixl-cu12)
- Transformers: 4.57.6

**使用方法**:
```bash
# Node1 (Producer) で実行
sudo -u ubuntu -i bash /path/to/setup_vllm_nixl_environment.sh

# Node2 (Consumer) で実行
sudo -u ubuntu -i bash /path/to/setup_vllm_nixl_environment.sh
```

**動作**:
1. 既存 vLLM プロセスを停止
2. GPU メモリをリセット
3. PyTorch 2.9.1 をインストール（vLLM 0.16.0 が要求）
4. vLLM 0.16.0 をインストール
5. NIXL 0.10.0 をインストール
6. インストール確認

**注意事項**:
- torch 2.10.0 がインストールされている場合、vLLM が起動しません
- NIXL のバージョン不一致は "NIXL is not available" エラーの原因になります

### 0-1. start_producer_efa.sh

**目的**: Producer (Prefill) を L2-EFA モードで起動

**環境変数**:
```bash
NIXL_BACKEND=LIBFABRIC
FI_PROVIDER=efa
VLLM_NIXL_SIDE_CHANNEL_HOST=172.31.2.221  # Producer の Private IP
VLLM_NIXL_SIDE_CHANNEL_PORT=50100
LD_LIBRARY_PATH=/opt/amazon/efa/lib: ${LD_LIBRARY_PATH: -}
```

**使用方法**:
```bash
# Node1 で実行
cd /home/ubuntu
bash start_producer_efa.sh
```

### 0-2. start_consumer_efa.sh

**目的**: Consumer (Decode) を L2-EFA モードで起動

**環境変数**:
```bash
NIXL_BACKEND=LIBFABRIC
FI_PROVIDER=efa
VLLM_NIXL_SIDE_CHANNEL_HOST=172.31.10.117  # Consumer の Private IP
VLLM_NIXL_SIDE_CHANNEL_PORT=50100
LD_LIBRARY_PATH=/opt/amazon/efa/lib: ${LD_LIBRARY_PATH: -}
```

**使用方法**:
```bash
# Node2 で実行
cd /home/ubuntu
bash start_consumer_efa.sh
```

## スクリプト一覧

### 1. create_benchmark_inputs.py

**目的**: トークン圧縮を回避した自然言語風テキストを生成

**問題**:
- 従来の `'a' * N` のような繰り返しテキストは、Qwen tokenizer により 87% 圧縮される
- 例: `'a' * 12288` → 実際 1,565 tokens（目標の 87% 減少）

**解決策**:
- 多様な語彙（COMMON_WORDS）からランダムに単語を選択
- 平均 1.0 tokens/word（実測）
- 句読点の影響で約 7% 増加するため、補正係数 0.93 を適用

**使用方法**:
```bash
python3 create_benchmark_inputs.py
```

**出力**:
- `/tmp/benchmark_input_12k.txt` - 12K tokens 入力
- `/tmp/benchmark_input_32k.txt` - 32K tokens 入力
- `/tmp/benchmark_inputs_metadata.json` - メタデータ

**検証結果**:
- 12K: 実際 12,210 tokens（目標 12,288、-0.63%）
- 32K: 実際 32,570 tokens（目標 32,768、-0.60%）

### 2. verify_token_count.py

**目的**: 生成されたテキストの実際のトークン数を vLLM tokenizer で検証

**依存関係**:
```bash
pip install transformers
```

**使用方法**:
```bash
python3 verify_token_count.py
```

**出力**:
- `/tmp/token_verification_results.json`

### 3. unified_benchmark.py

**目的**: すべてのレイヤーで同じ条件で TTFT を測定

**重要な変更（2026-03-05）**:
- **API フォーマット**: `/v1/completions` を使用（`prompt` 文字列）
- **従来の問題**: `/v1/chat/completions`（`messages` 配列）では Proxy と互換性がない

**統一条件**:
- Warmup: 2 回（固定）
- Measurement: n=10（固定）
- 入力: 検証済みテキスト（SHA256 記録）
- 記録項目: 実際の prompt_tokens を全リクエストで記録

**使用方法**:
```bash
python3 unified_benchmark.py \
  --pattern 12k-c1 \
  --url http://localhost:8000/v1/completions \
  --model "Qwen/Qwen2.5-32B-Instruct" \
  --input /tmp/benchmark_input_12k.txt \
  --output /tmp/result.json \
  --layer L2-EFA \
  --description "NIXL LIBFABRIC two-sided over EFA" \
  --warmup 2 \
  --n 10
```

**出力形式**:
```json
{
  "benchmark": "Phase 3 Unified Benchmark",
  "layer": "L2-EFA",
  "pattern": "12k-c1",
  "description": "NIXL LIBFABRIC two-sided over EFA",
  "timestamp": "20260305_024300",
  "config": {
    "model": "Qwen/Qwen2.5-32B-Instruct",
    "url": "http://localhost:8000/v1/completions",
    "warmup": 2,
    "n": 10,
    "input_file": "/tmp/benchmark_input_12k.txt",
    "input_sha256": "0f55d0c382178cc5...",
    "input_length": 60000
  },
  "statistics": {
    "n": 10,
    "ttft_ms": {
      "avg": 1573.70,
      "min": 1394,
      "max": 3182,
      "p50": 1395.0,
      "p99": 3182.0,
      "stdev": 565.10
    }
  },
  "results": [...]
}
```

### 4. disagg_proxy_server.py

**目的**: Prefill（Producer）と Decode（Consumer）を仲介し、KV-Cache 転送を管理

**重要な変更（2026-03-05）**:
- **タイムアウト延長**: Prefill のタイムアウトを 120 秒 → 300 秒 に延長
  - 理由: 12K tokens の Prefill には 120 秒以上かかる場合がある
  - 変更箇所: `timeout=aiohttp.ClientTimeout(total=300)`

**使用方法**:
```bash
python3 disagg_proxy_server.py \
  --prefill-url http://172.31.2.221:8100 \
  --decode-url http://172.31.10.117:8200 \
  --port 8000
```

**動作フロー**:
1. `/v1/completions` エンドポイントでリクエスト受信
2. Prefill に `max_tokens=1`, `do_remote_decode=true` で送信
3. レスポンスから `kv_transfer_params` を抽出（remote_block_ids など）
4. Decode に `kv_transfer_params` 付きでリクエスト送信
5. Decode のストリーミングレスポンスをクライアントに転送

## トラブルシューティング

### 問題 1: `asyncio.TimeoutError` が発生する

**原因**: Prefill のタイムアウト（120 秒）が短すぎる

**解決策**: disagg_proxy_server.py の 106 行目を修正:
```python
# 変更前
timeout=aiohttp.ClientTimeout(total=120),

# 変更後
timeout=aiohttp.ClientTimeout(total=300),
```

### 問題 2: トークン数が目標と大きくずれる

**原因**:
- 繰り返しテキスト（`'a' * N`）を使用している
- tokenizer が圧縮している

**解決策**:
- `create_benchmark_inputs.py` で生成した自然言語風テキストを使用
- `verify_token_count.py` で実際のトークン数を検証（±5% 以内を確認）

### 問題 3: unified_benchmark.py が 404 エラーを返す

**原因**:
- URL が `/v1/chat/completions` になっている
- Proxy は `/v1/completions` を期待

**解決策**:
- `--url http://localhost:8000/v1/completions` を使用
- スクリプト内で `"prompt": text` を使用（`"messages"` ではない）

## 参考ドキュメント

- `/home/coder/phase3/group1/MEASUREMENT_ACCURACY.md` - 測定精度と再現性の確立
- `/home/coder/phase3/group1/README.md` - Phase 3 実験ログ
- `TROUBLESHOOTING_2026-03-05.md` - KV-Cache 転送問題のトラブルシューティングログ
- `ROOT_CAUSE_REPORT_2026-03-05.md` - [重要] LIBFABRIC fi_read EAGAIN 失敗の根本原因レポート
- `investigation_plan_2026-03-05.md` - vLLM + NIXL 実装調査計画（Opus 4.6 x 5 名チーム）

## 変更履歴

### 2026-03-05

- unified_benchmark.py: `/v1/completions` API に対応（`messages` → `prompt`）
- disagg_proxy_server.py: Prefill タイムアウトを 300 秒 に延長
- create_benchmark_inputs.py, verify_token_count.py: 新規作成

---

**作成日**: 2026-03-05
