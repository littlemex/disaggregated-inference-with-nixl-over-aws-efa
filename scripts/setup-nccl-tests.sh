#!/bin/bash
set -e

echo "=========================================="
echo "NCCL Tests セットアップスクリプト"
echo "=========================================="
echo ""

# NCCL tests のインストール先
NCCL_TESTS_DIR="/opt/nccl-tests"

# インストール済みチェック
if [ -d "$NCCL_TESTS_DIR" ] && [ -f "$NCCL_TESTS_DIR/build/all_reduce_perf" ]; then
    echo "[INFO] NCCL tests は既にインストールされています: $NCCL_TESTS_DIR"
    echo "[INFO] バージョン確認:"
    $NCCL_TESTS_DIR/build/all_reduce_perf --help 2>&1 | head -n 5 || true
    exit 0
fi

echo "[STEP 1/4] 依存パッケージのインストール"
sudo apt-get update -qq
sudo apt-get install -y -qq \
    build-essential \
    git \
    libopenmpi-dev \
    openmpi-bin \
    > /dev/null 2>&1

echo "[STEP 2/4] NCCL tests のクローン"
sudo mkdir -p /opt
sudo git clone https://github.com/NVIDIA/nccl-tests.git $NCCL_TESTS_DIR

echo "[STEP 3/4] NCCL tests のビルド"
cd $NCCL_TESTS_DIR
sudo make MPI=1 MPI_HOME=/usr/lib/x86_64-linux-gnu/openmpi -j$(nproc) > /dev/null 2>&1

echo "[STEP 4/4] インストール確認"
if [ -f "$NCCL_TESTS_DIR/build/all_reduce_perf" ]; then
    echo "[SUCCESS] NCCL tests のインストールが完了しました"
    echo ""
    echo "利用可能なベンチマーク:"
    ls -1 $NCCL_TESTS_DIR/build/*_perf | head -n 10
else
    echo "[ERROR] NCCL tests のビルドに失敗しました"
    exit 1
fi

echo ""
echo "=========================================="
echo "セットアップ完了"
echo "=========================================="
