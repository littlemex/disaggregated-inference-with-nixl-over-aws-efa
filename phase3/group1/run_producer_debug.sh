#!/bin/bash
set -e

NODE1_PRIVATE="172.31.2.221"
NODE2_PRIVATE="172.31.10.117"

# Enable NIXL debug logging
export NIXL_LOG_LEVEL=DEBUG
export FI_LOG_LEVEL=info

# LD_LIBRARY_PATH
export LD_LIBRARY_PATH=/home/ubuntu/nixl/build/src/core:/home/ubuntu/nixl/build/src/infra:/home/ubuntu/nixl/build/src/utils/serdes:/home/ubuntu/nixl/build/src/utils/stream:/home/ubuntu/nixl/build/src/utils/common:/home/ubuntu/nixl/build/src:/opt/amazon/efa/lib64:$LD_LIBRARY_PATH

echo "[Producer] Starting with debug logging enabled..."
echo "[Producer] Listening on ${NODE1_PRIVATE}:5555"

/home/ubuntu/request_response_example_fixed \
  --mode producer \
  --port 5555 2>&1 | tee producer_debug.log
