#!/bin/bash
##
## Phase 3 Simple Setup Script (SSH-based)
##
## Usage:
##   ./setup_phase3_simple.sh <node-ip> <node-name>
##
## Example:
##   ./setup_phase3_simple.sh 44.247.215.228 Node1
##

set -euo pipefail

NODE_IP="$1"
NODE_NAME="${2:-Node}"
SSH_KEY="/home/coder/.ssh/phase3_key"
S3_BUCKET="phase3-nixl-efa-dev-west-2-scriptsbucket40feb4b1-ougyvcmrbyjj"

echo "[INFO] Setting up ${NODE_NAME} (${NODE_IP})..."

ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no ubuntu@"${NODE_IP}" 'bash -s' << 'REMOTE_SCRIPT'
set -euo pipefail

echo "[STEP 1/4] Installing vLLM v0.17.0..."
python3 -m pip install --no-cache-dir "vllm==0.17.0" --user -q
python3 -c "import vllm; print(f'[OK] vLLM {vllm.__version__} installed')"

echo "[STEP 2/4] Installing NIXL v0.10.0..."
python3 -m pip install --no-cache-dir "nixl[cu12]" --user -q
python3 -c "import nixl; print('[OK] NIXL installed')"

echo "[STEP 3/4] Deploying LIBFABRIC plugin..."
NIXL_DIR=$(python3 -c "import nixl; import os; print(os.path.dirname(nixl.__file__))")
PLUGIN_DIR="${NIXL_DIR}/_lib"
aws s3 cp "s3://phase3-nixl-efa-dev-west-2-scriptsbucket40feb4b1-ougyvcmrbyjj/plugins/libplugin_LIBFABRIC.so" \
  "${PLUGIN_DIR}/libplugin_LIBFABRIC.so" --region us-west-2 --quiet
chmod 755 "${PLUGIN_DIR}/libplugin_LIBFABRIC.so"
ls -lh "${PLUGIN_DIR}/libplugin_LIBFABRIC.so"
echo "[OK] Plugin deployed"

echo "[STEP 4/4] Verifying setup..."
python3 << 'EOF'
import nixl
import os
plugin_dir = os.path.join(os.path.dirname(nixl.__file__), "_lib")
plugins = [f for f in os.listdir(plugin_dir) if f.startswith("libplugin_") and f.endswith(".so")]
print(f"[OK] Available plugins: {plugins}")
assert "libplugin_LIBFABRIC.so" in plugins, "LIBFABRIC plugin not found"
print("[SUCCESS] Setup complete!")
EOF

REMOTE_SCRIPT

echo "[SUCCESS] ${NODE_NAME} setup complete!"
