#!/bin/bash
# Phase 2 Experiment Monitor - Real-time progress tracking with error detection
# Usage: ./monitor_experiment.sh --log /path/to/log [--follow] [--summary-only] [--layer L2-EFA]

set -euo pipefail

# Default values
LOG_FILE=""
FOLLOW=0
SUMMARY_ONLY=1
FILTER_LAYER=""
INTERVAL=10
NO_COLOR=0
PLAN_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --log)
            LOG_FILE="$2"
            shift 2
            ;;
        --follow)
            FOLLOW=1
            SUMMARY_ONLY=0
            shift
            ;;
        --summary-only)
            SUMMARY_ONLY=1
            FOLLOW=0
            shift
            ;;
        --layer)
            FILTER_LAYER="$2"
            shift 2
            ;;
        --interval)
            INTERVAL="$2"
            shift 2
            ;;
        --no-color)
            NO_COLOR=1
            shift
            ;;
        --plan)
            PLAN_FILE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 --log <log_file> [--follow] [--summary-only] [--layer <layer>] [--interval <seconds>] [--no-color] [--plan <plan_file>]"
            exit 1
            ;;
    esac
done

if [ -z "$LOG_FILE" ]; then
    echo "Error: --log parameter is required"
    echo "Usage: $0 --log <log_file> [--follow] [--summary-only] [--layer <layer>]"
    exit 1
fi

if [ ! -f "$LOG_FILE" ]; then
    echo "Error: Log file not found: $LOG_FILE"
    exit 1
fi

# Auto-detect plan file if not specified
if [ -z "$PLAN_FILE" ]; then
    if [[ "$LOG_FILE" =~ phase2 ]]; then
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        PLAN_FILE="$SCRIPT_DIR/experiment-plans/phase2.json"
    fi
fi

# Color codes
if [ "$NO_COLOR" -eq 1 ]; then
    C_RESET=""
    C_BOLD=""
    C_GREEN=""
    C_YELLOW=""
    C_RED=""
    C_CYAN=""
    C_GRAY=""
else
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_RED="\033[31m"
    C_CYAN="\033[36m"
    C_GRAY="\033[90m"
fi

# Parse log and extract statistics
parse_log() {
    python3 -c "
import sys
import re
import json
from collections import defaultdict
from datetime import datetime

log_file = '$LOG_FILE'
plan_file = '$PLAN_FILE' if '$PLAN_FILE' else None
filter_layer = '$FILTER_LAYER'

# Load experiment plan to get total pattern counts
layer_totals = {}
if plan_file:
    try:
        with open(plan_file, 'r') as f:
            plan = json.load(f)
            for layer in plan.get('layers', []):
                layer_id = layer.get('id', '')
                patterns = layer.get('patterns', [])
                layer_totals[layer_id] = len(patterns)
    except Exception as e:
        pass

# Parse log file
layer_stats = defaultdict(lambda: {'success': 0, 'failed': 0, 'running': 0, 'patterns': set()})
errors = []
current_pattern = None
current_layer = None
last_activity = None

# Remove ANSI escape codes
ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')

with open(log_file, 'r', encoding='utf-8', errors='ignore') as f:
    for line in f:
        line = ansi_escape.sub('', line)

        # Extract timestamp
        ts_match = re.search(r'\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]', line)
        if ts_match:
            last_activity = ts_match.group(1)

        # Detect layer start
        layer_match = re.search(r'Starting Layer: (L\d+-[A-Za-z]+)', line)
        if layer_match:
            current_layer = layer_match.group(1)

        # Detect pattern start
        pattern_match = re.search(r'=== Pattern \d+/\d+: ([a-z0-9-]+) ===', line)
        if pattern_match:
            current_pattern = pattern_match.group(1)
            if current_layer:
                layer_stats[current_layer]['running'] = 1
                layer_stats[current_layer]['patterns'].add(current_pattern)

        # Detect success
        if 'Benchmark complete:' in line or '[OK] Benchmark complete' in line:
            if current_pattern:
                # Infer layer from pattern name if current_layer is None
                if not current_layer:
                    if 'unified' in current_pattern:
                        current_layer = 'L1-Unified'
                    elif 'efa' in current_pattern:
                        current_layer = 'L2-EFA'
                    elif 'tcp' in current_pattern:
                        current_layer = 'L3-TCP'
                    elif 'analysis' in current_pattern:
                        current_layer = 'L4-Analysis'

                if current_layer:
                    layer_stats[current_layer]['success'] += 1
                    layer_stats[current_layer]['running'] = 0

        # Detect failure
        if 'Pattern' in line and 'failed' in line:
            pattern_fail = re.search(r'Pattern ([a-z0-9-]+) failed', line)
            if pattern_fail:
                failed_pattern = pattern_fail.group(1)
                # Infer layer from pattern name
                inferred_layer = None
                if 'unified' in failed_pattern:
                    inferred_layer = 'L1-Unified'
                elif 'efa' in failed_pattern:
                    inferred_layer = 'L2-EFA'
                elif 'tcp' in failed_pattern:
                    inferred_layer = 'L3-TCP'
                elif 'analysis' in failed_pattern:
                    inferred_layer = 'L4-Analysis'

                if inferred_layer:
                    layer_stats[inferred_layer]['failed'] += 1
                    layer_stats[inferred_layer]['running'] = 0
                elif current_layer:
                    layer_stats[current_layer]['failed'] += 1
                    layer_stats[current_layer]['running'] = 0

        # Detect errors
        if '[ERROR]' in line or '[FATAL]' in line:
            error_type = None
            if 'OOM' in line or 'out of memory' in line or 'OutOfMemoryError' in line:
                error_type = 'OOM'
            elif 'timeout' in line.lower():
                error_type = 'TIMEOUT'
            elif '[FATAL]' in line:
                error_type = 'FATAL'
            elif 'Command failed' in line:
                error_type = 'CMD_FAIL'

            if error_type and current_pattern:
                error_key = f\"{current_pattern}:{error_type}\"
                if not any(e['key'] == error_key for e in errors):
                    errors.append({
                        'key': error_key,
                        'pattern': current_pattern,
                        'type': error_type,
                        'line': line.strip()[:100]
                    })

# Apply layer filter
if filter_layer:
    layer_stats = {k: v for k, v in layer_stats.items() if k == filter_layer}

# Calculate totals and remaining
for layer_id, stats in layer_stats.items():
    total = layer_totals.get(layer_id, 0)
    completed = stats['success'] + stats['failed']
    stats['remaining'] = max(0, total - completed) if total > 0 else 0
    stats['total'] = total

# Output JSON
output = {
    'layer_stats': {k: {
        'success': v['success'],
        'failed': v['failed'],
        'running': v['running'],
        'remaining': v['remaining'],
        'total': v['total']
    } for k, v in layer_stats.items()},
    'errors': errors[-8:],  # Last 8 errors
    'current_pattern': current_pattern,
    'current_layer': current_layer,
    'last_activity': last_activity
}
print(json.dumps(output))
"
}

# Display statistics
display_stats() {
    local data="$1"

    clear

    echo -e "${C_BOLD}=== Phase 2 Experiment Monitor ===${C_RESET}"
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') | Log: $LOG_FILE"
    echo ""

    # Parse JSON
    local layer_stats=$(echo "$data" | python3 -c "import sys, json; d=json.load(sys.stdin); print(json.dumps(d['layer_stats']))")
    local errors=$(echo "$data" | python3 -c "import sys, json; d=json.load(sys.stdin); print(json.dumps(d['errors']))")
    local current_pattern=$(echo "$data" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('current_pattern', '') or '')")
    local current_layer=$(echo "$data" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('current_layer', '') or '')")
    local last_activity=$(echo "$data" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('last_activity', '') or '')")

    # Layer progress table
    echo -e "${C_BOLD}┌─────────────────────────────────────────────────────────┐${C_RESET}"
    echo -e "${C_BOLD}│ Layer Progress                                          │${C_RESET}"
    echo -e "${C_BOLD}├─────────────┬─────────┬─────────┬─────────┬────────────┤${C_RESET}"
    echo -e "${C_BOLD}│ Layer       │ Success │ Failed  │ Running │ Remaining  │${C_RESET}"
    echo -e "${C_BOLD}├─────────────┼─────────┼─────────┼─────────┼────────────┤${C_RESET}"

    # Default layers
    for layer in "L0-Baseline" "L1-Unified" "L2-EFA" "L3-TCP" "L4-Analysis"; do
        if [ -n "$FILTER_LAYER" ] && [ "$layer" != "$FILTER_LAYER" ]; then
            continue
        fi

        local success=$(echo "$layer_stats" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('$layer', {}).get('success', 0))" 2>/dev/null || echo "0")
        local failed=$(echo "$layer_stats" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('$layer', {}).get('failed', 0))" 2>/dev/null || echo "0")
        local running=$(echo "$layer_stats" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('$layer', {}).get('running', 0))" 2>/dev/null || echo "0")
        local remaining=$(echo "$layer_stats" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('$layer', {}).get('remaining', 0))" 2>/dev/null || echo "0")
        local total=$(echo "$layer_stats" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('$layer', {}).get('total', 0))" 2>/dev/null || echo "0")

        local status=""
        if [ "$total" -gt 0 ]; then
            if [ "$success" -eq "$total" ]; then
                status="${C_GREEN}[COMPLETE]${C_RESET}"
            elif [ $((success + failed)) -eq "$total" ]; then
                status="${C_YELLOW}[DONE+ERR]${C_RESET}"
            elif [ "$running" -gt 0 ]; then
                status="${C_CYAN}[RUNNING]${C_RESET}"
            elif [ $((success + failed)) -gt 0 ]; then
                status="${C_YELLOW}[PARTIAL]${C_RESET}"
            else
                status="${C_GRAY}[PENDING]${C_RESET}"
            fi
        else
            status="${C_GRAY}[PENDING]${C_RESET}"
        fi

        printf "│ %-11s │ %3s/%-3s │ %7s │ %7s │ %10s │ %s\n" \
            "$layer" "$success" "$total" "$failed" "$running" "$remaining" "$status"
    done

    echo -e "${C_BOLD}└─────────────┴─────────┴─────────┴─────────┴────────────┘${C_RESET}"
    echo ""

    # Current pattern
    if [ -n "$current_pattern" ]; then
        echo -e "${C_BOLD}[CURRENT]${C_RESET} ${current_layer:-Unknown}: ${C_CYAN}$current_pattern${C_RESET}"
        if [ -n "$last_activity" ]; then
            echo -e "  Last activity: $last_activity"
        fi
        echo ""
    fi

    # Recent errors
    local error_count=$(echo "$errors" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    if [ "$error_count" -gt 0 ]; then
        echo -e "${C_BOLD}[RECENT ERRORS]${C_RESET}"
        echo "$errors" | python3 -c "
import sys, json
errors = json.load(sys.stdin)
for e in errors:
    error_type = e['type']
    pattern = e['pattern']
    color = '\033[31m' if '$NO_COLOR' == '0' else ''
    reset = '\033[0m' if '$NO_COLOR' == '0' else ''
    print(f'  {color}[{error_type}]{reset} {pattern}')
" 2>/dev/null
        echo ""
    fi

    # Alerts
    local total_success=0
    local total_failed=0
    for layer in "L0-Baseline" "L1-Unified" "L2-EFA" "L3-TCP" "L4-Analysis"; do
        local success=$(echo "$layer_stats" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('$layer', {}).get('success', 0))" 2>/dev/null || echo "0")
        local failed=$(echo "$layer_stats" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('$layer', {}).get('failed', 0))" 2>/dev/null || echo "0")
        total_success=$((total_success + success))
        total_failed=$((total_failed + failed))

        # Layer-specific alert
        if [ "$failed" -ge 3 ]; then
            echo -e "${C_RED}[ALERT]${C_RESET} Layer $layer has $failed failures"
        fi
    done

    # Overall failure rate alert
    local total_completed=$((total_success + total_failed))
    if [ "$total_completed" -gt 0 ]; then
        local failure_rate=$((total_failed * 100 / total_completed))
        if [ "$failure_rate" -ge 50 ]; then
            echo -e "${C_RED}[ALERT]${C_RESET} Overall failure rate: ${failure_rate}% ($total_failed/$total_completed)"
        fi
    fi

    # Stale log warning
    if [ -n "$last_activity" ]; then
        local now_ts=$(date +%s)
        local activity_ts=$(date -d "$last_activity" +%s 2>/dev/null || echo "$now_ts")
        local age=$((now_ts - activity_ts))
        if [ "$age" -gt 600 ]; then
            echo -e "${C_YELLOW}[WARNING]${C_RESET} Log hasn't been updated for $((age / 60)) minutes"
        fi
    fi
}

# Main loop
if [ "$SUMMARY_ONLY" -eq 1 ]; then
    data=$(parse_log)
    display_stats "$data"
else
    while true; do
        data=$(parse_log)
        display_stats "$data"
        echo ""
        echo -e "${C_GRAY}Press Ctrl+C to exit. Refreshing every ${INTERVAL}s...${C_RESET}"
        sleep "$INTERVAL"
    done
fi
