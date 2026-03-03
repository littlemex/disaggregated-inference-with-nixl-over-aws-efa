#!/bin/bash
export NODE1_PRIVATE=172.31.2.221
export NODE2_PRIVATE=172.31.10.117
export NCCL_DEBUG=INFO
export NCCL_SOCKET_IFNAME=enp39s0
export NCCL_NET=Socket
export VLLM_ALLOW_LONG_MAX_MODEL_LEN=1

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
  --max-model-len 20480 \
  --no-enable-prefix-caching \
  --kv-transfer-config '{"kv_connector":"P2pNcclConnector","kv_role":"kv_consumer","kv_rank":1,"kv_parallel_size":2,"kv_ip":"172.31.2.221","kv_port":14579}' \
  > /tmp/vllm_consumer_nccl_p3-nccl-12k-c1.log 2>&1 &

echo "Consumer PID: $!"
