#!/bin/bash
##
## GPU Process Cleanup Script
##
## Kills all vLLM-related GPU processes
##

set -euo pipefail

# Source common functions
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/common.sh"

log "Checking for running GPU processes..."

# Find vLLM processes
VLLM_PIDS=$(pgrep -f "vllm.entrypoints.openai.api_server" || true)

if [ -z "$VLLM_PIDS" ]; then
    success "No vLLM processes found"
else
    log "Found vLLM processes: $VLLM_PIDS"
    log "Killing vLLM processes..."
    sudo pkill -9 -f "vllm.entrypoints.openai.api_server" || true
    sleep 2
    success "vLLM processes terminated"
fi

# Show GPU status
log "Current GPU status:"
nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader

success "GPU cleanup completed"
