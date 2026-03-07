#!/bin/bash
set -e

NODE1_PRIVATE="172.31.2.221"
NODE2_PRIVATE="172.31.10.117"

# Enable NIXL debug logging
export NIXL_LOG_LEVEL=DEBUG
export FI_LOG_LEVEL=info

# LD_LIBRARY_PATH
export LD_LIBRARY_PATH=/home/ubuntu/nixl/build/src/core:/home/ubuntu/nixl/build/src/infra:/home/ubuntu/nixl/build/src/utils/serdes:/home/ubuntu/nixl/build/src/utils/stream:/home/ubuntu/nixl/build/src/utils/common:/home/ubuntu/nixl/build/src:/opt/amazon/efa/lib64:$LD_LIBRARY_PATH

echo "[Consumer] Starting with debug logging enabled..."
echo "[Consumer] Listening on ${NODE2_PRIVATE}:8888"
echo "[Consumer] Will fetch metadata from Producer at ${NODE1_PRIVATE}:5555"

/home/ubuntu/request_response_example_fixed \
  --mode consumer \
  --producer-ip "${NODE1_PRIVATE}" \
  --producer-port 5555 \
  --port 8888 2>&1 | tee consumer_debug.log
