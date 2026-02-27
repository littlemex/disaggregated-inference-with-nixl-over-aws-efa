#!/bin/bash
# GPUDirect RDMA Verification Script
#
# 目的: Phase 15 測定前に GPUDirect RDMA が有効かどうかを確認する
#
# 所要時間: ~15分
# 実行タイミング: baseline_bandwidth 測定の直後
#
# Usage:
#   ./check_gpudirect_rdma.sh <output_json>
#
# Example:
#   ./check_gpudirect_rdma.sh gpudirect_rdma_status.json

set -e

if [ $# -ne 1 ]; then
    echo "Usage: $0 <output_json>"
    exit 1
fi

OUTPUT_JSON="$1"

echo "========================================"
echo "GPUDirect RDMA Verification"
echo "========================================"
echo ""

# ========================================
# 1. nvidia-smi topo -m
# ========================================

echo "[1/5] Checking GPU-NIC topology with nvidia-smi topo -m..."
TOPO_OUTPUT="/tmp/nvidia_smi_topo.txt"
nvidia-smi topo -m > "$TOPO_OUTPUT" 2>&1 || true

echo "Topology:"
cat "$TOPO_OUTPUT"
echo ""

# EFA デバイスとの接続を確認
# "PIX" = 同一 PCIe スイッチ、GPUDirect RDMA 可能
# "SYS" = システムバス経由、GPUDirect RDMA 不可
GPU_NIC_CONNECTION=$(grep -i "mlx\|efa" "$TOPO_OUTPUT" | head -1 || echo "unknown")

if echo "$GPU_NIC_CONNECTION" | grep -q "PIX"; then
    GPU_DIRECT_STATUS="likely_enabled"
    GPU_DIRECT_REASON="GPU and EFA NIC are on the same PCIe switch (PIX)"
elif echo "$GPU_NIC_CONNECTION" | grep -q "SYS"; then
    GPU_DIRECT_STATUS="likely_disabled"
    GPU_DIRECT_REASON="GPU and EFA NIC are on system bus (SYS), requires CPU bounce"
else
    GPU_DIRECT_STATUS="unknown"
    GPU_DIRECT_REASON="Could not determine GPU-NIC connection from topology"
fi

echo "GPUDirect RDMA Status: $GPU_DIRECT_STATUS"
echo "Reason: $GPU_DIRECT_REASON"
echo ""

# ========================================
# 2. ibv_devinfo (EFA デバイス情報)
# ========================================

echo "[2/5] Checking EFA device info with ibv_devinfo..."
IBV_OUTPUT="/tmp/ibv_devinfo.txt"
ibv_devinfo > "$IBV_OUTPUT" 2>&1 || true

echo "EFA Device:"
head -20 "$IBV_OUTPUT"
echo ""

# EFA デバイスの存在確認
EFA_DEVICE_COUNT=$(grep -c "hca_id" "$IBV_OUTPUT" || echo "0")
echo "EFA Device Count: $EFA_DEVICE_COUNT"
echo ""

# ========================================
# 3. lspci (PCIe デバイス一覧)
# ========================================

echo "[3/5] Checking PCIe devices with lspci..."
LSPCI_OUTPUT="/tmp/lspci.txt"
lspci | grep -iE "nvidia|mellanox|amazon" > "$LSPCI_OUTPUT" 2>&1 || true

echo "Relevant PCIe Devices:"
cat "$LSPCI_OUTPUT"
echo ""

# ========================================
# 4. vLLM ログから NIXL/GDR 情報を検索
# ========================================

echo "[4/5] Searching for NIXL/GDR references in vLLM logs..."
VLLM_LOG_PATTERN="/tmp/vllm_*.log"

if ls $VLLM_LOG_PATTERN 1> /dev/null 2>&1; then
    echo "Checking vLLM logs for GDR/GPUDirect references..."
    NIXL_GDR_REFS=$(grep -ihE "gdr|gpudirect|gdrcopy|cuda.*direct" $VLLM_LOG_PATTERN | head -10 || echo "No GDR references found")
    echo "$NIXL_GDR_REFS"
else
    NIXL_GDR_REFS="No vLLM logs found"
    echo "$NIXL_GDR_REFS"
fi
echo ""

# ========================================
# 5. libfabric 環境変数の確認
# ========================================

echo "[5/5] Checking libfabric environment variables..."
echo "FI_PROVIDER: ${FI_PROVIDER:-not set}"
echo "FI_EFA_USE_DEVICE_RDMA: ${FI_EFA_USE_DEVICE_RDMA:-not set}"
echo ""

if [ "${FI_EFA_USE_DEVICE_RDMA}" = "1" ]; then
    LIBFABRIC_GDR="requested"
else
    LIBFABRIC_GDR="not_requested"
fi

# ========================================
# 6. 結果を JSON に保存
# ========================================

echo "Saving results to $OUTPUT_JSON..."

# [FIXED MEDIUM-3] JSON エスケープを Python で実行
python3 -c "
import json
import sys

data = {
    'measurement_type': 'gpudirect_rdma_check',
    'timestamp': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'gpudirect_status': '$GPU_DIRECT_STATUS',
    'gpudirect_reason': '''$GPU_DIRECT_REASON''',
    'efa_device_count': $EFA_DEVICE_COUNT,
    'libfabric_gdr_requested': '$LIBFABRIC_GDR',
    'env_fi_provider': '${FI_PROVIDER:-not set}',
    'env_fi_efa_use_device_rdma': '${FI_EFA_USE_DEVICE_RDMA:-not set}',
    'raw_files': {
        'topology': '$TOPO_OUTPUT',
        'ibv_devinfo': '$IBV_OUTPUT',
        'lspci': '$LSPCI_OUTPUT'
    },
    'nixl_gdr_references': '''$NIXL_GDR_REFS'''
}

with open('$OUTPUT_JSON', 'w') as f:
    json.dump(data, f, indent=2)
"

echo ""
echo "========================================"
echo "GPUDirect RDMA Verification Complete"
echo "========================================"
echo "Status: $GPU_DIRECT_STATUS"
echo "Reason: $GPU_DIRECT_REASON"
echo "Result saved to: $OUTPUT_JSON"
echo ""

if [ "$GPU_DIRECT_STATUS" = "likely_enabled" ]; then
    echo "[OK] GPUDirect RDMA appears to be available"
    echo "  Expected KV-Cache transfer improvement: ~14ms per 2.7GB (20K tokens)"
elif [ "$GPU_DIRECT_STATUS" = "likely_disabled" ]; then
    echo "[WARNING] GPUDirect RDMA appears to be DISABLED"
    echo "  Expected overhead: ~168ms per 2.7GB (CPU bounce buffer)"
    echo "  This will significantly impact TTFT measurements"
else
    echo "[UNKNOWN] Could not determine GPUDirect RDMA status"
    echo "  Manual verification recommended: check nvidia-smi topo -m output"
fi

echo ""
echo "Next step: Run smoke test (20K/100K tokens)"
