#!/bin/bash
##
## Common functions for deployment scripts
##

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() { echo -e "${YELLOW}[$(date '+%H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Wait for process to finish
wait_for_process() {
    local process_name="$1"
    local timeout="${2:-60}"
    local elapsed=0

    while pgrep -f "$process_name" >/dev/null; do
        if [ $elapsed -ge $timeout ]; then
            error "Timeout waiting for $process_name to finish"
        fi
        echo -n "."
        sleep 2
        elapsed=$((elapsed + 2))
    done
    echo ""
}
