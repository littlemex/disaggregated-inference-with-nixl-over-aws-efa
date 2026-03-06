#!/bin/bash
##
## Proxy Server Startup Script for Disaggregated Inference
##
## Usage:
##   ./start-proxy.sh <prefill-ip> <decode-ip> [port]
##
## Example:
##   ./start-proxy.sh 172.31.2.221 172.31.10.117 8000
##

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <prefill-ip> <decode-ip> [port]"
    echo ""
    echo "Example:"
    echo "  $0 172.31.2.221 172.31.10.117 8000"
    exit 1
fi

PREFILL_IP="$1"
DECODE_IP="$2"
PORT="${3:-8000}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROXY_SCRIPT="$SCRIPT_DIR/../scripts/disagg_proxy_server.py"

# Check if proxy script exists locally
if [ ! -f "$PROXY_SCRIPT" ]; then
    # Try repo location
    PROXY_SCRIPT="/work/data-science/disaggregated-inference-with-nixl-over-aws-efa/experiments/scripts/disagg_proxy_server.py"
    if [ ! -f "$PROXY_SCRIPT" ]; then
        echo "[ERROR] Proxy script not found"
        exit 1
    fi
fi

echo "[INFO] Starting Proxy Server"
echo "  Prefill URL: http://$PREFILL_IP:8100"
echo "  Decode URL:  http://$DECODE_IP:8200"
echo "  Proxy Port:  $PORT"

# Stop existing proxy
pkill -f disagg_proxy_server.py || true
sleep 2

# Start proxy in background
nohup python3 "$PROXY_SCRIPT" \
    --prefill-url "http://$PREFILL_IP:8100" \
    --decode-url "http://$DECODE_IP:8200" \
    --port "$PORT" \
    > /home/ubuntu/proxy.log 2>&1 &

PROXY_PID=$!
echo "[OK] Proxy started with PID: $PROXY_PID"

# Wait and verify
sleep 5

if pgrep -f disagg_proxy_server.py > /dev/null; then
    echo "[OK] Proxy is running"
    netstat -tlnp 2>/dev/null | grep ":$PORT" || ss -tlnp 2>/dev/null | grep ":$PORT"
else
    echo "[ERROR] Proxy failed to start"
    tail -20 /home/ubuntu/proxy.log
    exit 1
fi

echo "[OK] Proxy startup complete"
echo "Log: /home/ubuntu/proxy.log"
