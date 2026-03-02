#!/bin/bash
# S3 Deployment Verification Script
#
# S3にデプロイされたファイルがローカルファイルと一致しているかを検証する。
# 重要設定項目（VLLM_NIXL_SIDE_CHANNEL_HOST, kv_buffer_size 等）の整合性も検証する。
#
# Usage:
#   ./verify-s3-deployment.sh <phase> [--verbose]
#
# Required environment variables:
#   SCRIPTS_BUCKET: S3 bucket name
#
# Exit codes:
#   0 - All verifications passed
#   1 - Verification failed (mismatch detected)
#   2 - Usage error or missing prerequisites

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo -e "${YELLOW}[$(date -u '+%H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }

# Counters
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
VERBOSE=false

pass() { PASS_COUNT=$((PASS_COUNT + 1)); success "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); error "$*"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); echo -e "${YELLOW}[WARNING]${NC} $*"; }

# ---- Usage ----

usage() {
    echo "Usage: $0 <phase> [--verbose]"
    echo ""
    echo "Verify that S3 deployment matches local files."
    echo ""
    echo "Arguments:"
    echo "  phase     Phase name (e.g., phase1, phase2)"
    echo "  --verbose Show detailed diff output"
    echo ""
    echo "Required environment variables:"
    echo "  SCRIPTS_BUCKET  S3 bucket name"
    echo ""
    echo "Examples:"
    echo "  SCRIPTS_BUCKET=my-bucket $0 phase2"
    echo "  SCRIPTS_BUCKET=my-bucket $0 phase2 --verbose"
    exit 2
}

# ---- File Checksum Comparison ----

# Compare local file with S3 file using md5 checksum
verify_s3_file() {
    local local_file="$1"
    local s3_key="$2"
    local label="${3:-$s3_key}"

    if [ ! -f "$local_file" ]; then
        fail "$label: local file not found: $local_file"
        return 1
    fi

    # Get local file md5
    local local_md5
    local_md5=$(md5sum "$local_file" | awk '{print $1}')

    # Download S3 file to temp and compute md5
    local tmp_file
    tmp_file=$(mktemp)

    if ! aws s3 cp "s3://$SCRIPTS_BUCKET/$s3_key" "$tmp_file" --quiet 2>/dev/null; then
        fail "$label: S3 file not found: s3://$SCRIPTS_BUCKET/$s3_key"
        rm -f "$tmp_file"
        return 1
    fi

    local s3_md5
    s3_md5=$(md5sum "$tmp_file" | awk '{print $1}')

    if [ "$local_md5" = "$s3_md5" ]; then
        pass "$label: checksums match"
        rm -f "$tmp_file"
        return 0
    else
        fail "$label: MISMATCH (local=$local_md5, s3=$s3_md5)"
        if [ "$VERBOSE" = true ]; then
            echo "  --- diff (local vs s3) ---"
            diff --unified=3 "$local_file" "$tmp_file" | head -50 || true
            echo "  --- end diff ---"
        fi
        rm -f "$tmp_file"
        return 1
    fi
}

# ---- Critical Config Extraction ----

# Extract and verify critical configuration items from task definition JSON
verify_critical_configs() {
    local phase="$1"
    local task_dir="$EXPERIMENTS_DIR/task-definitions/$phase"

    if [ ! -d "$task_dir" ]; then
        warn "Task definitions directory not found: $task_dir"
        return 0
    fi

    log "Verifying critical configuration items..."

    # Check producer task definitions for VLLM_NIXL_SIDE_CHANNEL_HOST
    local producer_dir="$task_dir/producer"
    if [ -d "$producer_dir" ]; then
        local producer_files
        producer_files=$(find "$producer_dir" -name "*.json" -type f 2>/dev/null)

        for json_file in $producer_files; do
            local filename
            filename=$(basename "$json_file")

            # Verify VLLM_NIXL_SIDE_CHANNEL_HOST uses $NODE1_PRIVATE (not $NODE2_PRIVATE)
            if grep -q 'VLLM_NIXL_SIDE_CHANNEL_HOST' "$json_file"; then
                local side_channel_value
                side_channel_value=$(grep -o 'VLLM_NIXL_SIDE_CHANNEL_HOST=\$[A-Z0-9_]*' "$json_file" | head -1 || true)
                if [ -n "$side_channel_value" ]; then
                    if echo "$side_channel_value" | grep -q 'NODE1_PRIVATE'; then
                        pass "Producer $filename: VLLM_NIXL_SIDE_CHANNEL_HOST=\$NODE1_PRIVATE"
                    else
                        fail "Producer $filename: VLLM_NIXL_SIDE_CHANNEL_HOST should use \$NODE1_PRIVATE but found: $side_channel_value"
                    fi
                fi
            fi

            # Verify kv_role is kv_producer
            if grep -q 'kv_role' "$json_file"; then
                local kv_role
                kv_role=$(python3 -c "
import json, re, sys
with open('$json_file') as f:
    content = f.read()
# Find kv_transfer_config JSON string
m = re.search(r'kv-transfer-config.*?(\{.*?kv_role.*?\})', content)
if m:
    try:
        cfg = json.loads(m.group(1).replace(\"'\", '\"'))
        print(cfg.get('kv_role', 'UNKNOWN'))
    except:
        # Try a simpler extraction
        m2 = re.search(r'kv_role.*?kv_producer|kv_consumer', content)
        if m2:
            print('kv_producer' if 'kv_producer' in m2.group() else 'kv_consumer')
        else:
            print('PARSE_ERROR')
" 2>/dev/null || echo "PARSE_ERROR")

                if [ "$kv_role" = "kv_producer" ]; then
                    pass "Producer $filename: kv_role=kv_producer"
                elif [ "$kv_role" = "PARSE_ERROR" ]; then
                    # Fallback: grep-based check
                    if grep -q '"kv_role":"kv_producer"\|kv_role.*kv_producer\|"kv_role":\\"kv_producer\\"' "$json_file"; then
                        pass "Producer $filename: kv_role=kv_producer (grep)"
                    else
                        warn "Producer $filename: could not parse kv_role"
                    fi
                else
                    fail "Producer $filename: kv_role should be 'kv_producer' but found '$kv_role'"
                fi
            fi

            # Verify kv_buffer_size is present and reasonable
            local buffer_size
            buffer_size=$(grep -o 'kv_buffer_size["\\ ]*:["\\ ]*[0-9]*' "$json_file" | grep -o '[0-9]*$' | head -1 || true)
            if [ -n "$buffer_size" ]; then
                if [ "$buffer_size" -gt 0 ] 2>/dev/null; then
                    pass "Producer $filename: kv_buffer_size=$buffer_size"
                else
                    fail "Producer $filename: kv_buffer_size invalid: $buffer_size"
                fi
            fi
        done
    fi

    # Check consumer task definitions for VLLM_NIXL_SIDE_CHANNEL_HOST
    local consumer_dir="$task_dir/consumer"
    if [ -d "$consumer_dir" ]; then
        local consumer_files
        consumer_files=$(find "$consumer_dir" -name "*.json" -type f 2>/dev/null)

        for json_file in $consumer_files; do
            local filename
            filename=$(basename "$json_file")

            # Verify VLLM_NIXL_SIDE_CHANNEL_HOST uses $NODE2_PRIVATE (not $NODE1_PRIVATE)
            if grep -q 'VLLM_NIXL_SIDE_CHANNEL_HOST' "$json_file"; then
                local side_channel_value
                side_channel_value=$(grep -o 'VLLM_NIXL_SIDE_CHANNEL_HOST=\$[A-Z0-9_]*' "$json_file" | head -1 || true)
                if [ -n "$side_channel_value" ]; then
                    if echo "$side_channel_value" | grep -q 'NODE2_PRIVATE'; then
                        pass "Consumer $filename: VLLM_NIXL_SIDE_CHANNEL_HOST=\$NODE2_PRIVATE"
                    else
                        fail "Consumer $filename: VLLM_NIXL_SIDE_CHANNEL_HOST should use \$NODE2_PRIVATE but found: $side_channel_value"
                    fi
                fi
            fi

            # Verify kv_role is kv_consumer
            if grep -q 'kv_consumer' "$json_file"; then
                pass "Consumer $filename: kv_role=kv_consumer"
            elif grep -q 'kv_role' "$json_file"; then
                fail "Consumer $filename: kv_role should contain 'kv_consumer'"
            fi
        done
    fi
}

# ---- S3 File Listing Comparison ----

# Compare the set of files in a local directory with those on S3
verify_s3_file_listing() {
    local local_dir="$1"
    local s3_prefix="$2"
    local label="$3"

    if [ ! -d "$local_dir" ]; then
        warn "$label: local directory not found: $local_dir"
        return 0
    fi

    # Get local file list (relative paths)
    local local_files
    local_files=$(cd "$local_dir" && find . -type f -name "*.json" -o -name "*.py" -o -name "*.sh" | sort | sed 's|^\./||')

    # Get S3 file list (relative to prefix)
    local s3_files
    s3_files=$(aws s3 ls "s3://$SCRIPTS_BUCKET/$s3_prefix" --recursive 2>/dev/null \
        | awk '{print $NF}' \
        | sed "s|^$s3_prefix||" \
        | sort)

    if [ -z "$s3_files" ]; then
        fail "$label: no files found on S3 at s3://$SCRIPTS_BUCKET/$s3_prefix"
        return 1
    fi

    # Compare file counts
    local local_count s3_count
    local_count=$(echo "$local_files" | grep -c . || echo 0)
    s3_count=$(echo "$s3_files" | grep -c . || echo 0)

    if [ "$local_count" -eq "$s3_count" ]; then
        pass "$label: file count matches ($local_count files)"
    else
        fail "$label: file count mismatch (local=$local_count, s3=$s3_count)"
        if [ "$VERBOSE" = true ]; then
            echo "  Local-only files:"
            comm -23 <(echo "$local_files") <(echo "$s3_files") | head -10 | sed 's/^/    /'
            echo "  S3-only files:"
            comm -13 <(echo "$local_files") <(echo "$s3_files") | head -10 | sed 's/^/    /'
        fi
    fi
}

# ---- Template Consistency Check ----

# Verify that generated JSON task definitions are consistent with templates
verify_template_consistency() {
    local phase="$1"
    local task_dir="$EXPERIMENTS_DIR/task-definitions/$phase"
    local plan_file="$EXPERIMENTS_DIR/experiment-plans/$phase.json"

    if [ ! -f "$plan_file" ]; then
        warn "Experiment plan not found: $plan_file"
        return 0
    fi

    log "Verifying template consistency for $phase..."

    # Extract infrastructure settings from plan
    local model venv_path
    model=$(python3 -c "import json; print(json.load(open('$plan_file'))['infrastructure']['model'])" 2>/dev/null || echo "UNKNOWN")
    venv_path=$(python3 -c "import json; p=json.load(open('$plan_file'))['infrastructure']; print(p.get('venv_path', ''))" 2>/dev/null || echo "")

    # Check all producer/consumer JSONs for consistent model reference
    local all_jsons
    all_jsons=$(find "$task_dir" -name "*.json" -type f 2>/dev/null | grep -v '__pycache__' || true)

    for json_file in $all_jsons; do
        local filename
        filename=$(basename "$json_file")

        # Skip analysis/baseline/low-level task definitions
        if echo "$json_file" | grep -qE 'analysis|baseline|low-level'; then
            continue
        fi

        # Verify model name
        local file_model
        file_model=$(python3 -c "
import json
with open('$json_file') as f:
    data = json.load(f)
print(data.get('variables', {}).get('MODEL', 'NONE'))
" 2>/dev/null || echo "PARSE_ERROR")

        if [ "$file_model" = "$model" ]; then
            if [ "$VERBOSE" = true ]; then
                pass "$filename: MODEL=$model"
            fi
        elif [ "$file_model" = "PARSE_ERROR" ] || [ "$file_model" = "NONE" ]; then
            # Skip non-standard task definitions
            :
        else
            fail "$filename: MODEL mismatch (expected=$model, found=$file_model)"
        fi
    done

    pass "Template consistency check complete for $phase (model=$model)"
}

# ---- Main ----

if [ $# -lt 1 ]; then
    usage
fi

PHASE="$1"
shift

# Parse optional arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

: "${SCRIPTS_BUCKET:?SCRIPTS_BUCKET not set}"

echo "============================================================"
echo "S3 Deployment Verification - $PHASE"
echo "============================================================"
echo "  Bucket: $SCRIPTS_BUCKET"
echo "  Phase:  $PHASE"
echo ""

# ---- Step 1: Verify shared scripts on S3 ----

log "Step 1/4: Verifying shared scripts..."

SCRIPTS_DIR="$EXPERIMENTS_DIR/scripts"

# Critical scripts that must be present
for script_file in benchmark_common.py disagg_proxy_server.py; do
    if [ -f "$SCRIPTS_DIR/$script_file" ]; then
        verify_s3_file "$SCRIPTS_DIR/$script_file" "scripts/$script_file" "scripts/$script_file"
    fi
done

# Verify task_runner.sh
TASK_RUNNER_SEARCH_PATHS=(
    "/work/data-science/claudecode/investigations/nixl-efa-tai/setup/task_runner.sh"
    "$EXPERIMENTS_DIR/../setup/task_runner.sh"
)

for path in "${TASK_RUNNER_SEARCH_PATHS[@]}"; do
    if [ -f "$path" ]; then
        verify_s3_file "$path" "scripts/task_runner.sh" "scripts/task_runner.sh"
        break
    fi
done

echo ""

# ---- Step 2: Verify task definitions on S3 ----

log "Step 2/4: Verifying task definitions..."

TASK_DIR="$EXPERIMENTS_DIR/task-definitions/$PHASE"
if [ -d "$TASK_DIR" ]; then
    # Verify a sample of task definitions (up to 5 files from each subdirectory)
    for subdir in "" "producer" "consumer" "baseline" "low-level"; do
        local_subdir="$TASK_DIR"
        s3_prefix="tasks/$PHASE/"
        if [ -n "$subdir" ]; then
            local_subdir="$TASK_DIR/$subdir"
            s3_prefix="tasks/$PHASE/$subdir/"
        fi

        if [ ! -d "$local_subdir" ]; then
            continue
        fi

        sample_files=$(find "$local_subdir" -maxdepth 1 -name "*.json" -type f 2>/dev/null | sort | head -5 || true)

        for local_file in $sample_files; do
            fname=$(basename "$local_file")
            s3_key="${s3_prefix}${fname}"
            verify_s3_file "$local_file" "$s3_key" "tasks/$PHASE/${subdir:+$subdir/}$fname"
        done
    done
else
    warn "Task definitions directory not found: $TASK_DIR"
fi

echo ""

# ---- Step 3: Verify critical configuration items ----

log "Step 3/4: Verifying critical configuration items..."
verify_critical_configs "$PHASE"

echo ""

# ---- Step 4: Verify template consistency ----

log "Step 4/4: Verifying template consistency..."
verify_template_consistency "$PHASE"

echo ""

# ---- Summary ----

echo "============================================================"
echo "Verification Summary"
echo "============================================================"
echo -e "  ${GREEN}PASS:${NC}    $PASS_COUNT"
echo -e "  ${RED}FAIL:${NC}    $FAIL_COUNT"
echo -e "  ${YELLOW}WARNING:${NC} $WARN_COUNT"
echo ""

if [ $FAIL_COUNT -gt 0 ]; then
    error "Deployment verification FAILED ($FAIL_COUNT failures)"
    echo ""
    echo "Suggested actions:"
    echo "  1. Re-run deployment: ./run_experiment.sh $PHASE deploy"
    echo "  2. Re-generate task definitions: ./generate_tasks.py $PHASE"
    echo "  3. Re-run verification: ./scripts/verify-s3-deployment.sh $PHASE --verbose"
    exit 1
else
    success "Deployment verification PASSED"
    exit 0
fi
