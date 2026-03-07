#!/bin/bash
set -e

echo "=== NIXL Plugin Replacement Script ==="
echo "Purpose: Replace pip-installed NIXL plugin with custom-built Request/Response plugin"
echo ""

PLUGIN_DIR="/home/ubuntu/.local/lib/python3.10/site-packages/nixl/../.nixl_cu12.mesonpy.libs/plugins"
CUSTOM_PLUGIN="/home/ubuntu/nixl/build/src/plugins/libfabric/libplugin_LIBFABRIC.so"
TARGET_PLUGIN="$PLUGIN_DIR/libplugin_LIBFABRIC.so"
BACKUP_PLUGIN="$TARGET_PLUGIN.original"

# Check if custom plugin exists
if [ ! -f "$CUSTOM_PLUGIN" ]; then
    echo "[ERROR] Custom plugin not found: $CUSTOM_PLUGIN"
    echo "Please build NIXL first: cd /home/ubuntu/nixl/build && ninja"
    exit 1
fi

# Check if target directory exists
if [ ! -d "$PLUGIN_DIR" ]; then
    echo "[ERROR] Plugin directory not found: $PLUGIN_DIR"
    echo "Please install nixl-cu12 first: pip install nixl-cu12==0.10.0"
    exit 1
fi

# Backup original plugin (if not already backed up)
if [ ! -f "$BACKUP_PLUGIN" ]; then
    echo "[INFO] Backing up original plugin to $BACKUP_PLUGIN"
    cp "$TARGET_PLUGIN" "$BACKUP_PLUGIN"
else
    echo "[INFO] Backup already exists: $BACKUP_PLUGIN"
fi

# Replace plugin
echo "[INFO] Replacing plugin with custom build"
cp "$CUSTOM_PLUGIN" "$TARGET_PLUGIN"

# Verify
CUSTOM_SIZE=$(stat -c%s "$CUSTOM_PLUGIN")
TARGET_SIZE=$(stat -c%s "$TARGET_PLUGIN")

if [ "$CUSTOM_SIZE" -eq "$TARGET_SIZE" ]; then
    echo "[OK] Plugin replaced successfully"
    echo "  Custom: $CUSTOM_SIZE bytes"
    echo "  Target: $TARGET_SIZE bytes"
    ls -lh "$TARGET_PLUGIN"
else
    echo "[ERROR] Size mismatch!"
    echo "  Custom: $CUSTOM_SIZE bytes"
    echo "  Target: $TARGET_SIZE bytes"
    exit 1
fi

# Check if plugin contains Request/Response code
echo ""
echo "[INFO] Verifying Request/Response code in plugin..."
if strings "$TARGET_PLUGIN" | grep -q "READ_REQUEST"; then
    echo "[OK] Plugin contains Request/Response code"
else
    echo "[WARNING] Plugin may not contain Request/Response code"
fi

echo ""
echo "=== Plugin Replacement Completed ==="
echo "Please restart vLLM to use the new plugin"
