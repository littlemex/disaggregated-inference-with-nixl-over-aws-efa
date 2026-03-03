#!/bin/bash
# Kill existing proxy
pgrep -f 'disagg_proxy\|p2pnccl' | xargs -r kill 2>/dev/null
sleep 1

nohup python3 /tmp/disagg_proxy_p2pnccl.py \
  --prefill-url http://172.31.2.221:8100 \
  --decode-url http://172.31.10.117:8200 \
  --port 8000 \
  --prefill-zmq-port 14579 \
  --decode-zmq-port 14579 \
  > /tmp/proxy_p2pnccl.log 2>&1 &

echo "Proxy PID: $!"
