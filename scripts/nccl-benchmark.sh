#!/bin/bash
set -e

echo "=========================================="
echo "NCCL ベンチマーク実行スクリプト"
echo "=========================================="
echo ""

# デフォルト設定
NCCL_TESTS_DIR="/opt/nccl-tests"
NUM_GPUS=${NUM_GPUS:-4}
MIN_SIZE=${MIN_SIZE:-8}
MAX_SIZE=${MAX_SIZE:-128M}
STEP_FACTOR=${STEP_FACTOR:-2}

# ヘルプ表示
if [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    echo "使用方法: $0 [OPTIONS]"
    echo ""
    echo "オプション:"
    echo "  NUM_GPUS=<num>     GPU 数（デフォルト: 4）"
    echo "  MIN_SIZE=<size>    最小データサイズ（デフォルト: 8）"
    echo "  MAX_SIZE=<size>    最大データサイズ（デフォルト: 128M）"
    echo "  STEP_FACTOR=<num>  ステップ倍率（デフォルト: 2）"
    echo ""
    echo "例:"
    echo "  NUM_GPUS=2 MAX_SIZE=64M $0"
    echo ""
    exit 0
fi

# NCCL tests の確認
if [ ! -f "$NCCL_TESTS_DIR/build/all_reduce_perf" ]; then
    echo "[ERROR] NCCL tests が見つかりません: $NCCL_TESTS_DIR"
    echo "[INFO] 先に setup-nccl-tests.sh を実行してください"
    exit 1
fi

# GPU 確認
GPU_COUNT=$(nvidia-smi --list-gpus 2>/dev/null | wc -l)
if [ "$GPU_COUNT" -eq 0 ]; then
    echo "[ERROR] GPU が検出されませんでした"
    exit 1
fi

echo "[INFO] 検出された GPU 数: $GPU_COUNT"
echo "[INFO] ベンチマーク GPU 数: $NUM_GPUS"
echo "[INFO] データサイズ範囲: $MIN_SIZE ~ $MAX_SIZE (ステップ x$STEP_FACTOR)"
echo ""

# 結果保存ディレクトリ
RESULT_DIR="/tmp/nccl-benchmark-results"
mkdir -p $RESULT_DIR
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# EFA デバイス確認
EFA_DEVICE=$(fi_info -p efa 2>/dev/null | grep -i "provider" | head -n 1 || echo "")
if [ -n "$EFA_DEVICE" ]; then
    echo "[INFO] EFA デバイスが検出されました"
    BACKEND="EFA"
else
    echo "[INFO] EFA デバイスが検出されませんでした（TCP を使用）"
    BACKEND="TCP"
fi
echo ""

# ========================================
# 1. all_reduce_perf（TP で最も使われる）
# ========================================
echo "=========================================="
echo "[1/2] all_reduce ベンチマーク実行中..."
echo "=========================================="

REDUCE_OUTPUT="$RESULT_DIR/all_reduce_${BACKEND}_${TIMESTAMP}.txt"

$NCCL_TESTS_DIR/build/all_reduce_perf \
    -b $MIN_SIZE \
    -e $MAX_SIZE \
    -f $STEP_FACTOR \
    -g $NUM_GPUS \
    | tee $REDUCE_OUTPUT

echo ""
echo "[OK] 結果を保存しました: $REDUCE_OUTPUT"
echo ""

# ========================================
# 2. all_gather_perf（KV-Cache 転送）
# ========================================
echo "=========================================="
echo "[2/2] all_gather ベンチマーク実行中..."
echo "=========================================="

GATHER_OUTPUT="$RESULT_DIR/all_gather_${BACKEND}_${TIMESTAMP}.txt"

$NCCL_TESTS_DIR/build/all_gather_perf \
    -b $MIN_SIZE \
    -e $MAX_SIZE \
    -f $STEP_FACTOR \
    -g $NUM_GPUS \
    | tee $GATHER_OUTPUT

echo ""
echo "[OK] 結果を保存しました: $GATHER_OUTPUT"
echo ""

# ========================================
# サマリー表示
# ========================================
echo "=========================================="
echo "ベンチマーク完了"
echo "=========================================="
echo ""
echo "結果ファイル:"
echo "  - all_reduce: $REDUCE_OUTPUT"
echo "  - all_gather: $GATHER_OUTPUT"
echo ""

# 最良性能の抽出
echo "最良性能（Bus Bandwidth）:"
echo ""

echo "[all_reduce]"
grep -E "^\s+[0-9]+" $REDUCE_OUTPUT | \
    awk '{print $1, $6}' | \
    sort -k2 -nr | \
    head -n 3 | \
    awk '{printf "  %10s bytes: %8s GB/s\n", $1, $2}'

echo ""
echo "[all_gather]"
grep -E "^\s+[0-9]+" $GATHER_OUTPUT | \
    awk '{print $1, $6}' | \
    sort -k2 -nr | \
    head -n 3 | \
    awk '{printf "  %10s bytes: %8s GB/s\n", $1, $2}'

echo ""
echo "=========================================="
