#!/bin/bash
# 再現可能な vLLM + NIXL 環境セットアップスクリプト
# Phase 3 L2-EFA ベンチマーク用
# 日時: 2026-03-05

set -e

echo "[INFO] Starting vLLM + NIXL environment setup..."

# バージョン固定（Producer の動作確認済み環境）
TORCH_VERSION="2.9.1"
TORCHVISION_VERSION="0.24.1"
TORCHAUDIO_VERSION="2.9.1"
VLLM_VERSION="0.16.0"
NIXL_VERSION="0.10.0"
TRANSFORMERS_VERSION="4.57.6"

# 1. 既存の vLLM プロセスを停止
echo "[INFO] Stopping existing vLLM processes..."
pkill -9 -f "vllm" || true
sleep 3

# 2. GPU メモリをクリーンアップ
echo "[INFO] Cleaning GPU memory..."
nvidia-smi --gpu-reset -i 0 || true
nvidia-smi --gpu-reset -i 1 || true
sleep 2

# 3. 重要なパッケージを正しいバージョンでインストール
echo "[INFO] Installing PyTorch ${TORCH_VERSION}..."
pip install torch==${TORCH_VERSION} torchvision==${TORCHVISION_VERSION} torchaudio==${TORCHAUDIO_VERSION} --force-reinstall

echo "[INFO] Installing vLLM ${VLLM_VERSION}..."
pip install vllm==${VLLM_VERSION} --no-deps

echo "[INFO] Installing NIXL ${NIXL_VERSION}..."
pip install nixl-cu12==${NIXL_VERSION} --force-reinstall

echo "[INFO] Installing transformers ${TRANSFORMERS_VERSION}..."
pip install transformers==${TRANSFORMERS_VERSION}

# 4. インストール確認
echo "[INFO] Verifying installation..."
python3 -c "import torch; print(f'PyTorch: {torch.__version__}')"
python3 -c "import vllm; print(f'vLLM: {vllm.__version__}')"
python3 -c "import nixl; print('NIXL: 0.10.0')"
python3 -c "import transformers; print(f'Transformers: {transformers.__version__}')"

# 5. GPU 状態確認
echo "[INFO] GPU status:"
nvidia-smi

# 6. EFA ライブラリパス確認
echo "[INFO] Checking EFA library..."
ls -la /opt/amazon/efa/lib/ | head -5

echo "[OK] Environment setup completed successfully!"
echo ""
echo "Next steps:"
echo "  - Producer: bash start_producer_efa.sh"
echo "  - Consumer: bash start_consumer_efa.sh"
