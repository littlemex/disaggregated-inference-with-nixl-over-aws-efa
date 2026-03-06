#!/bin/bash
# Consumer (Decode) 起動スクリプト - L2-EFA
# Phase 3 L2-EFA ベンチマーク用
# 日時: 2026-03-05

set -e

# 環境変数（Producer と同じ構成）
export NIXL_BACKEND=LIBFABRIC
export FI_PROVIDER=efa
export VLLM_NIXL_SIDE_CHANNEL_HOST=172.31.10.117  # Consumer の IP
export VLLM_NIXL_SIDE_CHANNEL_PORT=50100
export VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
export FI_LOG_LEVEL=info
export NIXL_LOG_LEVEL=INFO
export LD_LIBRARY_PATH=/opt/amazon/efa/lib:${LD_LIBRARY_PATH:-}

# 既存プロセスを停止
echo "[INFO] Stopping existing Consumer..."
pkill -9 -f "vllm.*8200" || true
sleep 3

# Consumer 起動
echo "[INFO] Starting Consumer..."
nohup python3 -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen2.5-32B-Instruct \
  --disable-log-requests \
  --trust-remote-code \
  --port 8200 \
  --tensor-parallel-size 2 \
  --gpu-memory-utilization 0.9 \
  --max-num-batched-tokens 8192 \
  --enable-chunked-prefill \
  --enforce-eager \
  --max-model-len 32000 \
  --no-enable-prefix-caching \
  --kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_consumer","kv_rank":1,"kv_parallel_size":2,"kv_ip":"172.31.10.117","kv_buffer_device":"cpu","kv_buffer_size":5000000000,"kv_connector_extra_config":{"backends":["LIBFABRIC"]}}' \
  > ~/consumer_efa.log 2>&1 &

PID=$!
echo $PID > ~/consumer_efa.pid
echo "[OK] Consumer started with PID: $PID"

sleep 10
echo "[INFO] Checking Consumer health..."
curl -s http://localhost:8200/health || echo "[WARNING] Health check failed, Consumer may still be initializing"

echo ""
echo "Monitor logs: tail -f ~/consumer_efa.log"
