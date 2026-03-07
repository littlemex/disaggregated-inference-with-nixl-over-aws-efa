#!/bin/bash
set -e
cd /home/ubuntu

# [P2] NIXL_PLUGIN_DIR を追加してカスタムビルドのプラグインを使用
NIXL_PLUGIN_DIR=/home/ubuntu/nixl/build/src/plugins \
FI_LOG_LEVEL=debug \
VLLM_NIXL_SIDE_CHANNEL_HOST=172.31.2.221 \
VLLM_NIXL_SIDE_CHANNEL_PORT=50100 \
NIXL_LOG_LEVEL=TRACE \
VLLM_LOGGING_LEVEL=DEBUG \
nohup python3 -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen2.5-32B-Instruct \
  --port 8100 \
  --tensor-parallel-size 2 \
  --distributed-executor-backend mp \
  --gpu-memory-utilization 0.9 \
  --max-model-len 32000 \
  --max-num-batched-tokens 8192 \
  --kv-transfer-config "$(cat /home/ubuntu/kv_config.json)" \
  > /home/ubuntu/producer_p2_fixed.log 2>&1 &

echo $! > /home/ubuntu/producer.pid
echo "Producer started with PID: $(cat /home/ubuntu/producer.pid)"
