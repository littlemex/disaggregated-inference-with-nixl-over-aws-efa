#!/bin/bash
##
## NIXL Installation Script
##
## Installs NIXL v0.10.0 with CUDA 12 support
##

set -eo pipefail

# Source common functions
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/common.sh"

NIXL_VERSION="${NIXL_VERSION:-0.10.0}"

log "Installing NIXL ${NIXL_VERSION}..."

# Use pre-installed PyTorch environment if available (DLAMI)
if [ -f /opt/pytorch/bin/activate ]; then
    log "Using pre-installed PyTorch environment from /opt/pytorch"
    source /opt/pytorch/bin/activate
    pip install --no-cache-dir "nixl[cu12]==${NIXL_VERSION}"
else
    log "Using system Python with --break-system-packages (Ubuntu 24.04)"
    python3 -m pip install --break-system-packages --no-cache-dir "nixl[cu12]==${NIXL_VERSION}"
fi

# Verify installation
log "Verifying NIXL installation..."
python3 -c "import nixl"

# Get installed version (if available)
INSTALLED_VERSION=$(python3 -c "import nixl; print(getattr(nixl, '__version__', 'installed'))" 2>/dev/null || echo "installed")

success "NIXL ${INSTALLED_VERSION} installed successfully"
