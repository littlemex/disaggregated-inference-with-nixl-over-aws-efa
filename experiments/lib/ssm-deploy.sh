#!/bin/bash
# SSM を使った S3 経由ファイル転送ヘルパー

set -e

SCRIPTS_BUCKET="${SCRIPTS_BUCKET:-}"
if [ -z "$SCRIPTS_BUCKET" ]; then
    echo "Error: SCRIPTS_BUCKET environment variable not set"
    exit 1
fi

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() { echo -e "${YELLOW}[$(date -u '+%H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

# S3 にファイルをアップロード
upload_to_s3() {
    local local_file="$1"
    local s3_key="$2"

    if [ ! -f "$local_file" ]; then
        echo "Error: File not found: $local_file"
        exit 1
    fi

    log "Uploading: $local_file -> s3://$SCRIPTS_BUCKET/$s3_key"
    aws s3 cp "$local_file" "s3://$SCRIPTS_BUCKET/$s3_key" --quiet
    success "Uploaded: $s3_key"
}

# ディレクトリを S3 に同期
sync_to_s3() {
    local local_dir="$1"
    local s3_prefix="$2"

    if [ ! -d "$local_dir" ]; then
        echo "Error: Directory not found: $local_dir"
        exit 1
    fi

    log "Syncing: $local_dir -> s3://$SCRIPTS_BUCKET/$s3_prefix"
    aws s3 sync "$local_dir" "s3://$SCRIPTS_BUCKET/$s3_prefix" --delete --quiet
    success "Synced: $s3_prefix"
}

# S3 からダウンロード（ローカル用）
download_from_s3() {
    local s3_key="$1"
    local local_file="$2"

    log "Downloading: s3://$SCRIPTS_BUCKET/$s3_key -> $local_file"
    aws s3 cp "s3://$SCRIPTS_BUCKET/$s3_key" "$local_file" --quiet
    success "Downloaded: $local_file"
}

# 関数をエクスポート（source された場合）
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    export -f upload_to_s3
    export -f sync_to_s3
    export -f download_from_s3
fi
