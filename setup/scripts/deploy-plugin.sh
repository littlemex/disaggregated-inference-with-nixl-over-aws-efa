#!/bin/bash
##
## NIXL LIBFABRIC Plugin Deployment Script
##
## Downloads and deploys the LIBFABRIC plugin from S3
##

set -eo pipefail

# Source common functions
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/common.sh"

# Required environment variables
: "${S3_BUCKET:?S3_BUCKET is required}"
: "${AWS_REGION:?AWS_REGION is required}"
: "${S3_PLUGIN_KEY:?S3_PLUGIN_KEY is required}"

log "Deploying NIXL LIBFABRIC plugin..."

# Use pre-installed PyTorch environment if available
if [ -f /opt/pytorch/bin/activate ]; then
    source /opt/pytorch/bin/activate
fi

# Get NIXL installation directory
NIXL_DIR=$(python3 -c "import nixl, os; print(os.path.dirname(nixl.__file__))")
log "NIXL directory: ${NIXL_DIR}"

# Download plugin from S3
PLUGIN_PATH="${NIXL_DIR}/_lib/libplugin_LIBFABRIC.so"
log "Downloading plugin to ${PLUGIN_PATH}..."

sudo aws s3 cp "s3://${S3_BUCKET}/${S3_PLUGIN_KEY}" "${PLUGIN_PATH}" --region "${AWS_REGION}"

# Set permissions
sudo chmod +x "${PLUGIN_PATH}"

# Verify plugin
if [ ! -f "${PLUGIN_PATH}" ]; then
    error "Plugin file not found: ${PLUGIN_PATH}"
fi

PLUGIN_SIZE=$(ls -lh "${PLUGIN_PATH}" | awk '{print $5}')
success "LIBFABRIC plugin deployed successfully (${PLUGIN_SIZE})"
