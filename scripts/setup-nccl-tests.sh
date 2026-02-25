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

echo "[STEP 1/5] 依存パッケージのインストール"
sudo apt-get update -qq
sudo apt-get install -y -qq \
    build-essential \
    git \
    libopenmpi-dev \
    openmpi-bin \
    > /dev/null 2>&1

echo "[STEP 2/5] NCCL ライブラリの確認"
if ! ldconfig -p | grep -q libnccl; then
    echo "[WARNING] NCCL ライブラリが見つかりません"
    echo "[INFO] CUDA toolkit に含まれる NCCL を使用します"
    # CUDA のパスを環境変数に追加
    export CUDA_HOME=/usr/local/cuda
    export LD_LIBRARY_PATH=$CUDA_HOME/lib64:$LD_LIBRARY_PATH
else
    echo "[INFO] NCCL ライブラリが見つかりました"
    ldconfig -p | grep libnccl | head -3
fi

echo "[STEP 3/5] NCCL tests のクローン"
sudo mkdir -p /opt
if [ -d "$NCCL_TESTS_DIR/.git" ]; then
    echo "[INFO] リポジトリは既に存在します。最新版を取得します..."
    cd $NCCL_TESTS_DIR
    sudo git pull
else
    sudo git clone https://github.com/NVIDIA/nccl-tests.git $NCCL_TESTS_DIR
fi

echo "[STEP 4/5] NCCL tests のビルド"
cd $NCCL_TESTS_DIR
echo "[INFO] ビルドを開始します（数分かかります）..."
sudo make MPI=1 MPI_HOME=/usr/lib/x86_64-linux-gnu/openmpi -j$(nproc)

echo "[STEP 5/5] インストール確認"
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
