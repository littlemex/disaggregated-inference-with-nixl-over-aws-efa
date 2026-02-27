#!/bin/bash
# Baseline Bandwidth Measurement (iperf3 + fi_rdm_pingpong)
#
# 目的: Phase 15 測定前に EFA/TCP の実効帯域幅を測定し、
#       TTFT の理論値計算の根拠を確立する
#
# 所要時間: ~1 時間
# 実行タイミング: Phase 15 測定の最初のステップ
#
# Usage:
#   ./measure_baseline_bandwidth.sh <node1_private_ip> <node2_private_ip> <output_json>
#
# Example:
#   ./measure_baseline_bandwidth.sh 172.31.27.16 172.31.20.197 baseline_bandwidth.json

set -e

if [ $# -ne 3 ]; then
    echo "Usage: $0 <node1_private_ip> <node2_private_ip> <output_json>"
    exit 1
fi

NODE1_IP="$1"
NODE2_IP="$2"
OUTPUT_JSON="$3"

echo "========================================"
echo "Baseline Bandwidth Measurement"
echo "========================================"
echo "Node1 (Server): $NODE1_IP"
echo "Node2 (Client): $NODE2_IP"
echo "Output: $OUTPUT_JSON"
echo ""

# Temporary result files
TCP_RESULT="/tmp/iperf3_tcp_result.txt"
EFA_RESULT="/tmp/fi_rdm_pingpong_result.txt"

# ========================================
# 1. iperf3 (TCP bandwidth)
# ========================================

echo "[1/4] Starting iperf3 server on Node1..."
echo "  SSH to Node1 and run: iperf3 -s -p 5201"
echo "  Press Enter when iperf3 server is ready on Node1"
read -p ""

echo "[2/4] Running iperf3 client on Node2 (TCP bandwidth test)..."
echo "  Measuring TCP bandwidth for 30 seconds with 8 parallel streams..."

# Node2 で iperf3 クライアントを実行
# -c: サーバーIP、-t: テスト時間、-P: 並列ストリーム数、-J: JSON 出力
# -P 8: 単一ストリームでは TCP 帯域幅が過小評価されるため、8 並列で最大帯域幅を測定
iperf3 -c "$NODE1_IP" -p 5201 -t 30 -P 8 -J > "$TCP_RESULT" 2>&1 || true

# 結果を解析
TCP_BANDWIDTH_GBPS=$(python3 -c "
import json, sys
try:
    with open('$TCP_RESULT') as f:
        data = json.load(f)
    bits_per_second = data['end']['sum_received']['bits_per_second']
    gbps = bits_per_second / 1e9
    print(f'{gbps:.2f}')
except Exception as e:
    print('0.0', file=sys.stderr)
    sys.exit(0)
")

echo "  TCP Bandwidth: $TCP_BANDWIDTH_GBPS Gbps"
echo ""

# iperf3 サーバーを停止
echo "  Please stop iperf3 server on Node1 (Ctrl+C)"
echo "  Press Enter when stopped"
read -p ""

# ========================================
# 2. fi_rdm_bw (EFA bandwidth)
# ========================================

echo "[3/4] Starting fi_rdm_bw server on Node1 (EFA)..."
echo "  SSH to Node1 and run:"
echo "    fi_rdm_bw -p efa"
echo "  Press Enter when fi_rdm_bw server is ready on Node1"
read -p ""

echo "[4/4] Running fi_rdm_bw client on Node2 (EFA bandwidth test)..."
echo "  Measuring EFA bandwidth with 16MB message size..."

# Node2 で fi_rdm_bw クライアントを実行
# -s: メッセージサイズ (16MB - 帯域幅測定に適切なサイズ)、-I: イテレーション回数
# fi_rdm_bw は帯域幅測定に最適化されており、fi_rdm_pingpong より正確
fi_rdm_bw -p efa "$NODE1_IP" -s 16777216 -I 100 > "$EFA_RESULT" 2>&1 || true

# 結果を解析
EFA_BANDWIDTH_GBPS=$(python3 -c "
import sys
try:
    with open('$EFA_RESULT') as f:
        lines = f.readlines()
    # fi_rdm_bw の出力形式: 'bytes    #sent  #recv  total  time   MB/sec ...'
    # 最後の行からデータを取得
    for line in reversed(lines):
        if line.strip() and not line.startswith('#'):
            parts = line.split()
            if len(parts) >= 6:
                mbps = float(parts[5])
                gbps = mbps * 8 / 1000  # MB/s -> Gbps
                print(f'{gbps:.2f}')
                sys.exit(0)
    print('0.0', file=sys.stderr)
except Exception as e:
    print('0.0', file=sys.stderr)
    sys.exit(0)
")

echo "  EFA Bandwidth: $EFA_BANDWIDTH_GBPS Gbps"
echo ""

# fi_rdm_bw サーバーを停止
echo "  Please stop fi_rdm_bw server on Node1 (Ctrl+C)"
echo "  Press Enter when stopped"
read -p ""

# ========================================
# 3. 結果を JSON に保存
# ========================================

echo "Saving results to $OUTPUT_JSON..."

cat > "$OUTPUT_JSON" <<EOF
{
  "measurement_type": "baseline_bandwidth",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "node1_ip": "$NODE1_IP",
  "node2_ip": "$NODE2_IP",
  "tcp_bandwidth_gbps": $TCP_BANDWIDTH_GBPS,
  "efa_bandwidth_gbps": $EFA_BANDWIDTH_GBPS,
  "bandwidth_ratio": $(python3 -c "print(${EFA_BANDWIDTH_GBPS} / ${TCP_BANDWIDTH_GBPS} if ${TCP_BANDWIDTH_GBPS} > 0 else 0)"),
  "notes": "iperf3 for TCP (8 parallel streams), fi_rdm_bw for EFA bandwidth (libfabric)",
  "raw_files": {
    "tcp_result": "$TCP_RESULT",
    "efa_result": "$EFA_RESULT"
  }
}
EOF

echo ""
echo "========================================"
echo "Baseline Bandwidth Measurement Complete"
echo "========================================"
echo "TCP Bandwidth: $TCP_BANDWIDTH_GBPS Gbps"
echo "EFA Bandwidth: $EFA_BANDWIDTH_GBPS Gbps"
echo "EFA/TCP Ratio: $(python3 -c "print(${EFA_BANDWIDTH_GBPS} / ${TCP_BANDWIDTH_GBPS} if ${TCP_BANDWIDTH_GBPS} > 0 else 0)")"
echo "Result saved to: $OUTPUT_JSON"
echo ""
echo "Next steps:"
echo "  1. Verify GPUDirect RDMA: nvidia-smi topo -m"
echo "  2. Run smoke test: 20K/100K tokens with 1 request each"
echo "  3. Start Phase 15 measurement"
