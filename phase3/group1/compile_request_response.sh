#!/bin/bash
# Request/Response Example コンパイルスクリプト
# 使い方: ./compile_request_response.sh

set -e

# 設定読み込み
source "$(dirname "$0")/get_config.sh"

NODES=("${PRODUCER_PRIVATE_IP}" "${CONSUMER_PRIVATE_IP}")

echo "[INFO] Compiling request_response_example on both nodes..."

for NODE_IP in "${NODES[@]}"; do
    echo ""
    echo "=== Node: $NODE_IP ==="

    ssh -i ~/.ssh/phase3_key ubuntu@$NODE_IP << 'EOF'
cd /home/ubuntu

# ソースコードをnixl-forkからコピー
if [ -f /home/ubuntu/nixl/examples/cpp/request_response_example.cpp ]; then
    cp /home/ubuntu/nixl/examples/cpp/request_response_example.cpp ./request_response_example.cpp
    echo "[OK] Source copied from nixl examples"
else
    echo "[ERROR] Source not found in /home/ubuntu/nixl/examples/cpp/"
    exit 1
fi

# コンパイル
echo "[INFO] Compiling..."
g++ -std=c++17 -O2 -o request_response_example \
  request_response_example.cpp \
  -I/home/ubuntu/nixl/src/api/cpp \
  -I/home/ubuntu/nixl/src/infra \
  -I/home/ubuntu/nixl/src/utils \
  -L/home/ubuntu/nixl/build/src/core \
  -L/home/ubuntu/nixl/build/src/infra \
  -L/home/ubuntu/nixl/build/src/utils/serdes \
  -L/home/ubuntu/nixl/build/src/utils/stream \
  -L/home/ubuntu/nixl/build/src/utils/common \
  -L/home/ubuntu/nixl/build/src \
  -lnixl -lnixl_build -lserdes -lstream -lnixl_common -pthread

if [ $? -eq 0 ]; then
    echo "[OK] Compilation successful"
    ls -lh request_response_example
else
    echo "[ERROR] Compilation failed"
    exit 1
fi
EOF

    if [ $? -eq 0 ]; then
        echo "[OK] Node $NODE_IP: Compilation complete"
    else
        echo "[ERROR] Node $NODE_IP: Compilation failed"
        exit 1
    fi
done

echo ""
echo "[OK] All nodes compiled successfully"
