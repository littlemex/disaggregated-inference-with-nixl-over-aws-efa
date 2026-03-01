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

echo "[STEP 2/5] NCCL コアライブラリのインストール"
if ldconfig -p | grep -q "libnccl.so.2"; then
    echo "[INFO] NCCL ランタイムライブラリが見つかりました"
else
    echo "[INFO] NCCL ランタイムライブラリが見つかりません"
fi

# NCCL 開発ライブラリ（libnccl-dev）のインストール確認
if [ ! -f /usr/lib/x86_64-linux-gnu/libnccl.so ]; then
    echo "[INFO] NCCL 開発ライブラリをインストールします..."

    # NVIDIA CUDA リポジトリの追加（まだの場合）
    if [ ! -f /etc/apt/sources.list.d/cuda-ubuntu2204-x86_64.list ]; then
        wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
        sudo dpkg -i cuda-keyring_1.1-1_all.deb
        sudo apt-get update -qq
        rm -f cuda-keyring_1.1-1_all.deb
    fi

    # NCCL 開発ライブラリのインストール
    sudo apt-get install -y -qq libnccl2 libnccl-dev > /dev/null 2>&1
    echo "[INFO] NCCL 開発ライブラリのインストールが完了しました"
else
    echo "[INFO] NCCL 開発ライブラリは既にインストールされています"
fi

# インストール確認
if [ -f /usr/lib/x86_64-linux-gnu/libnccl.so ]; then
    NCCL_VERSION=$(dpkg -l | grep libnccl2 | awk '{print $3}')
    echo "[INFO] NCCL バージョン: $NCCL_VERSION"
else
    echo "[ERROR] NCCL 開発ライブラリのインストールに失敗しました"
    exit 1
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
