#!/bin/bash
##
## vLLM Installation Script
##
## Installs vLLM v0.17.0 with verification
##

set -eo pipefail

# Source common functions
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/common.sh"

VLLM_VERSION="${VLLM_VERSION:-0.17.0}"

log "Installing vLLM ${VLLM_VERSION}..."

# Use pre-installed PyTorch environment if available (DLAMI)
if [ -f /opt/pytorch/bin/activate ]; then
    log "Using pre-installed PyTorch environment from /opt/pytorch"
    source /opt/pytorch/bin/activate
    pip install --no-cache-dir "vllm==${VLLM_VERSION}"
else
    log "Using system Python with --break-system-packages (Ubuntu 24.04)"
    python3 -m pip install --break-system-packages --no-cache-dir "vllm==${VLLM_VERSION}"
fi

# Verify installation
log "Verifying vLLM installation..."
python3 -c "import vllm"

# Get installed version
INSTALLED_VERSION=$(python3 -c "import vllm; print(vllm.__version__)")

success "vLLM ${INSTALLED_VERSION} installed successfully"
