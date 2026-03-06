#!/bin/bash
# Phase 3 P2 Investigation - Consumer (Prefill) Startup Script
# Usage: bash start-consumer-p2.sh
set -e

cd /home/ubuntu

# Stop existing processes
pkill -9 -f 'vllm.entrypoints.openai.api_server' || true
pkill -9 -f 'vllm_worker' || true
sleep 3

# Start Consumer with DEBUG logging
FI_LOG_LEVEL=debug \
VLLM_NIXL_SIDE_CHANNEL_HOST=172.31.2.221 \
VLLM_NIXL_SIDE_CHANNEL_PORT=50100 \
NIXL_LOG_LEVEL=TRACE \
VLLM_LOGGING_LEVEL=DEBUG \
nohup python3 -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen2.5-32B-Instruct \
  --port 8200 \
  --tensor-parallel-size 2 \
  --distributed-executor-backend mp \
  --gpu-memory-utilization 0.9 \
  --max-model-len 32000 \
  --max-num-batched-tokens 8192 \
  --kv-connector NixlConnector \
  --kv-role kv_consumer \
  --kv-rank 0 \
  --kv-parallel-size 1 \
  --kv-buffer-device cpu \
  --kv-buffer-size 5G > /home/ubuntu/consumer_p2.log 2>&1 &

echo "Consumer started with PID: $!"
echo "Log file: /home/ubuntu/consumer_p2.log"
