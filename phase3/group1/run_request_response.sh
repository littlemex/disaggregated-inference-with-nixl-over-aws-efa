#!/bin/bash
# Request/Response Example 実行スクリプト
# 使い方: ./run_request_response.sh

set -e

# 設定読み込み
source "$(dirname "$0")/get_config.sh"

PRODUCER_PORT=5555
CONSUMER_PORT=8888

echo "[INFO] Starting Request/Response Example..."
echo ""
echo "Producer: ${NODE1_PRIVATE}:${PRODUCER_PORT}"
echo "Consumer: ${NODE2_PRIVATE}:${CONSUMER_PORT}"
echo ""

# Producer起動（バックグラウンド）
echo "=== Starting Producer on Node1 ==="
ssh -i ~/.ssh/phase3_key ubuntu@${NODE1_PRIVATE} << EOF &
cd /home/ubuntu
export NIXL_LOG_LEVEL=INFO
export FI_LOG_LEVEL=warn
export LD_LIBRARY_PATH=/home/ubuntu/nixl/build/src/core:/home/ubuntu/nixl/build/src/infra:/home/ubuntu/nixl/build/src/utils/serdes:/home/ubuntu/nixl/build/src/utils/stream:/home/ubuntu/nixl/build/src/utils/common:/home/ubuntu/nixl/build/src:/opt/amazon/efa/lib64:\$LD_LIBRARY_PATH

echo "[Producer] Starting..."
./request_response_example \
  --mode producer \
  --port ${PRODUCER_PORT} 2>&1 | tee producer.log
EOF

PRODUCER_PID=$!
echo "[OK] Producer started (PID: $PRODUCER_PID)"
echo ""

# Producerの起動を待つ
sleep 5

# Consumer起動（フォアグラウンド）
echo "=== Starting Consumer on Node2 ==="
ssh -i ~/.ssh/phase3_key ubuntu@${NODE2_PRIVATE} << EOF
cd /home/ubuntu
export NIXL_LOG_LEVEL=INFO
export FI_LOG_LEVEL=warn
export LD_LIBRARY_PATH=/home/ubuntu/nixl/build/src/core:/home/ubuntu/nixl/build/src/infra:/home/ubuntu/nixl/build/src/utils/serdes:/home/ubuntu/nixl/build/src/utils/stream:/home/ubuntu/nixl/build/src/utils/common:/home/ubuntu/nixl/build/src:/opt/amazon/efa/lib64:\$LD_LIBRARY_PATH

echo "[Consumer] Starting..."
timeout 60 ./request_response_example \
  --mode consumer \
  --producer-ip ${NODE1_PRIVATE} \
  --producer-port ${PRODUCER_PORT} \
  --port ${CONSUMER_PORT} 2>&1 | tee consumer.log

echo ""
echo "[Consumer] Finished"
EOF

# Producerを停止
echo ""
echo "=== Stopping Producer ==="
kill $PRODUCER_PID 2>/dev/null || true

echo ""
echo "[INFO] Execution complete"
echo ""
echo "ログ確認:"
echo "  Producer: ssh -i ~/.ssh/phase3_key ubuntu@${NODE1_PRIVATE} 'tail -50 /home/ubuntu/producer.log'"
echo "  Consumer: ssh -i ~/.ssh/phase3_key ubuntu@${NODE2_PRIVATE} 'tail -50 /home/ubuntu/consumer.log'"
