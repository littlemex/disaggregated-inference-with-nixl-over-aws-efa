#!/bin/bash
##
## Complete NIXL Deployment Script
##
## Usage:
##   ./deploy.sh <config-file>
##
## Example:
##   ./deploy.sh configs/phase3-us-west-2.env
##
## This script automates the complete NIXL deployment:
##   1. Check prerequisites (libfabric-dev)
##   2. Clone and build NIXL from GitHub
##   3. Upload plugin to S3
##   4. Setup both EC2 nodes with vLLM + NIXL
##   5. Deploy custom LIBFABRIC plugin
##

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() { echo -e "${YELLOW}[$(date '+%H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Check arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <config-file>"
    echo ""
    echo "Example:"
    echo "  $0 configs/phase3-us-west-2.env"
    echo ""
    exit 1
fi

CONFIG_FILE="$1"

# Check config file
if [ ! -f "$CONFIG_FILE" ]; then
    error "Config file not found: $CONFIG_FILE"
fi

# Load configuration
log "Loading configuration from $CONFIG_FILE..."
source "$CONFIG_FILE"

# Validate required variables
REQUIRED_VARS=(
    "S3_BUCKET"
    "AWS_REGION"
    "SSH_KEY"
    "NODE1_PUBLIC_IP"
    "NODE2_PUBLIC_IP"
    "NODE1_PRIVATE_IP"
    "NODE2_PRIVATE_IP"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        error "Required variable $var is not set in $CONFIG_FILE"
    fi
done

success "Configuration loaded"

# Display configuration
echo ""
echo "========================================="
echo "Deployment Configuration"
echo "========================================="
echo "S3 Bucket:      $S3_BUCKET"
echo "AWS Region:     $AWS_REGION"
echo "Node1 (Producer): $NODE1_PUBLIC_IP ($NODE1_PRIVATE_IP)"
echo "Node2 (Consumer): $NODE2_PUBLIC_IP ($NODE2_PRIVATE_IP)"
echo "SSH Key:        $SSH_KEY"
echo ""

# Confirm
read -p "Proceed with deployment? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Deployment cancelled."
    exit 0
fi

# Export environment variables for task runner
export NIXL_REPO="${NIXL_REPO:-https://github.com/littlemex/nixl.git}"
export NIXL_BRANCH="${NIXL_BRANCH:-main}"
export NIXL_CLONE_DIR="${NIXL_CLONE_DIR:-/tmp/nixl-build}"
export BUILD_SUBDIR="${BUILD_SUBDIR:-build}"
export PLUGIN_RELATIVE_PATH="${PLUGIN_RELATIVE_PATH:-src/plugins/libfabric/libplugin_LIBFABRIC.so}"
export S3_PLUGIN_KEY="${S3_PLUGIN_KEY:-plugins/libplugin_LIBFABRIC.so}"
export REMOTE_USER="${REMOTE_USER:-ubuntu}"

# Run deployment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_FILE="$SCRIPT_DIR/tasks/complete-deployment-v2.json"

if [ ! -f "$TASK_FILE" ]; then
    error "Task file not found: $TASK_FILE"
fi

log "Starting deployment..."
bash "$SCRIPT_DIR/task_runner.sh" "$TASK_FILE"

success "Deployment complete!"
