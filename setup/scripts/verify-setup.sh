#!/bin/bash
##
## Setup Verification Script
##
## Verifies that vLLM, NIXL, and LIBFABRIC plugin are properly installed
##

set -eo pipefail

# Source common functions
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/common.sh"

log "Verifying setup..."

# Use pre-installed PyTorch environment if available
if [ -f /opt/pytorch/bin/activate ]; then
    source /opt/pytorch/bin/activate
fi

# Check vLLM
log "Checking vLLM..."
if python3 -c "import vllm" 2>/dev/null; then
    VLLM_VERSION=$(python3 -c "import vllm; print(vllm.__version__)")
    success "vLLM ${VLLM_VERSION} is installed"
else
    error "vLLM is not installed"
fi

# Check NIXL
log "Checking NIXL..."
if python3 -c "import nixl" 2>/dev/null; then
    NIXL_VERSION=$(python3 -c "import nixl; print(getattr(nixl, '__version__', 'installed'))" 2>/dev/null || echo "installed")
    success "NIXL ${NIXL_VERSION} is installed"
else
    error "NIXL is not installed"
fi

# Check LIBFABRIC plugin
log "Checking LIBFABRIC plugin..."
NIXL_DIR=$(python3 -c "import nixl, os; print(os.path.dirname(nixl.__file__))")
PLUGIN_PATH="${NIXL_DIR}/_lib/libplugin_LIBFABRIC.so"

if [ -f "${PLUGIN_PATH}" ]; then
    PLUGIN_SIZE=$(ls -lh "${PLUGIN_PATH}" | awk '{print $5}')
    success "LIBFABRIC plugin found (${PLUGIN_SIZE})"
else
    error "LIBFABRIC plugin not found at ${PLUGIN_PATH}"
fi

# Check GPU
log "Checking GPU..."
if command_exists nvidia-smi; then
    GPU_COUNT=$(nvidia-smi --list-gpus | wc -l)
    success "Found ${GPU_COUNT} GPU(s)"
    nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader
else
    error "nvidia-smi not found"
fi

success "All checks passed"
