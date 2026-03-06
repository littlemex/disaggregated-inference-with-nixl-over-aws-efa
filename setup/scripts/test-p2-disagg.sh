#!/bin/bash
##
## P2 Investigation Test Script - Disaggregated Inference with NIXL Request/Response
##
## Usage:
##   ./test-p2-disagg.sh <proxy-ip> [proxy-port]
##
## Example:
##   ./test-p2-disagg.sh 172.31.10.117 8000
##

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <proxy-ip> [proxy-port]"
    echo ""
    echo "Example:"
    echo "  $0 172.31.10.117 8000"
    exit 1
fi

PROXY_IP="$1"
PROXY_PORT="${2:-8000}"
PROXY_URL="http://$PROXY_IP:$PROXY_PORT"

echo "=========================================="
echo "P2 Disaggregated Inference Test"
echo "=========================================="
echo "Proxy URL: $PROXY_URL"
echo ""

# Test 1: Health check
echo "[Test 1] Health Check"
if curl -s "$PROXY_URL/health" | grep -q "healthy"; then
    echo "[OK] Proxy is healthy"
else
    echo "[ERROR] Proxy health check failed"
    exit 1
fi
echo ""

# Test 2: Simple completion request
echo "[Test 2] Completion Request (max_tokens=10)"
RESPONSE=$(curl -X POST "$PROXY_URL/v1/completions" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "Qwen/Qwen2.5-32B-Instruct",
        "prompt": "Hello, how are you?",
        "max_tokens": 10
    }' 2>&1)

if echo "$RESPONSE" | grep -q "choices"; then
    echo "[OK] Request succeeded"
    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
else
    echo "[ERROR] Request failed"
    echo "$RESPONSE"
    exit 1
fi
echo ""

# Test 3: Check logs for KV transfer
echo "[Test 3] Verify KV Transfer in Logs"
echo "Check Producer log for handshake:"
if grep "_nixl_handshake_listener: received request" /home/ubuntu/producer_p2.log | tail -1; then
    echo "[OK] Producer received handshake"
else
    echo "[WARNING] No handshake found in Producer log"
fi
echo ""

echo "Check Consumer log for READ_REQUEST:"
if grep "Consumer sent READ_REQUEST" /home/ubuntu/consumer_p2.log | tail -1; then
    echo "[OK] Consumer sent READ_REQUEST"
else
    echo "[WARNING] No READ_REQUEST found in Consumer log"
fi
echo ""

echo "=========================================="
echo "P2 Test Complete"
echo "=========================================="
echo "Summary:"
echo "  - Proxy health: OK"
echo "  - Completion request: OK"
echo "  - NIXL handshake: Check logs above"
echo "  - READ_REQUEST: Check logs above"
echo ""
echo "For detailed analysis, check:"
echo "  Producer log: /home/ubuntu/producer_p2.log"
echo "  Consumer log: /home/ubuntu/consumer_p2.log"
echo "  Proxy log:    /home/ubuntu/proxy.log"
