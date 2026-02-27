#!/usr/bin/env python3
"""
Low-Level Network Measurement Runner with MLflow Integration

Executes Phase 3 tools (fi_pingpong, NIXLBench, KVBench, ucx_perftest) and
records results to MLflow for correlation analysis with E2E measurements.

This script:
1. Reads generated JSON task definitions from task-definitions/phase-low-level/
2. Orchestrates execution via run_experiment.sh (SSM-based)
3. Collects results from /tmp/low-level-results/ on remote nodes
4. Records all metrics and parameters to MLflow experiment "low-level-network"

Usage:
    # Run all low-level measurements
    python3 run_low_level_tools.py --phase-dir task-definitions/phase-low-level

    # Run specific layer only
    python3 run_low_level_tools.py --layer L0  # fi_pingpong only
    python3 run_low_level_tools.py --layer L1  # NIXLBench only
    python3 run_low_level_tools.py --layer L2  # KVBench only
    python3 run_low_level_tools.py --layer L3  # ucx_perftest only

    # Dry run (show what would be executed)
    python3 run_low_level_tools.py --dry-run

    # Record existing results to MLflow (skip execution)
    python3 run_low_level_tools.py --record-only --results-dir ./results/low-level

Environment variables:
    SCRIPTS_BUCKET: S3 bucket name (from CDK Output)
    NODE1_ID: Node1 instance ID
    NODE2_ID: Node2 instance ID
    NODE1_PRIVATE: Node1 private IP
    NODE2_PRIVATE: Node2 private IP
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

# MLflow is optional
try:
    import mlflow
    MLFLOW_AVAILABLE = True
except ImportError:
    MLFLOW_AVAILABLE = False

SCRIPT_DIR = Path(__file__).parent
EXPERIMENTS_DIR = SCRIPT_DIR.parent
MLFLOW_EXPERIMENT_NAME = "low-level-network"

# Tool-to-Layer mapping from phase-low-level.json
TOOL_LAYER_MAP = {
    "fi_pingpong": "L0",
    "fi_rma_pingpong": "L0",
    "nixlbench": "L1",
    "kvbench": "L2",
    "ucx_perftest": "L3",
}


def load_experiment_plan() -> dict:
    """Load the low-level experiment plan."""
    plan_path = EXPERIMENTS_DIR / "experiment-plans" / "phase-low-level.json"
    if not plan_path.exists():
        print(f"[ERROR] Experiment plan not found: {plan_path}")
        sys.exit(1)
    with open(plan_path, "r", encoding="utf-8") as f:
        return json.load(f)


def find_task_definitions(phase_dir: Path, layer_filter: Optional[str] = None) -> List[Path]:
    """Find all JSON task definitions, optionally filtered by layer."""
    if not phase_dir.exists():
        print(f"[ERROR] Task definitions directory not found: {phase_dir}")
        print("[INFO] Run: ./generate_tasks.py phase-low-level")
        sys.exit(1)

    json_files = sorted(phase_dir.glob("pll-*.json"))

    if layer_filter:
        plan = load_experiment_plan()
        layer_patterns = set()
        for layer in plan["layers"]:
            if layer["id"] == layer_filter:
                for p in layer["patterns"]:
                    layer_patterns.add(p["id"])
                break

        if not layer_patterns:
            print(f"[ERROR] Layer {layer_filter} not found in experiment plan")
            sys.exit(1)

        json_files = [f for f in json_files if f.stem in layer_patterns]

    return json_files


def execute_task(task_path: Path, node_target: str = "node1") -> Dict[str, Any]:
    """Execute a single task definition via run_experiment.sh.

    Returns parsed results dict or empty dict on failure.
    """
    runner_script = EXPERIMENTS_DIR / "run_experiment.sh"

    # Verify environment
    required_env = ["SCRIPTS_BUCKET", "NODE1_ID", "NODE2_ID", "NODE1_PRIVATE", "NODE2_PRIVATE"]
    missing = [v for v in required_env if not os.environ.get(v)]
    if missing:
        print(f"[ERROR] Missing environment variables: {', '.join(missing)}")
        return {}

    print(f"[INFO] Executing: {task_path.name} on {node_target}")
    start_time = time.time()

    try:
        result = subprocess.run(
            [str(runner_script), "phase-low-level", "run", task_path.stem],
            capture_output=True,
            text=True,
            timeout=600,  # 10 min timeout
            cwd=str(EXPERIMENTS_DIR),
        )

        elapsed = time.time() - start_time
        print(f"[INFO] Completed in {elapsed:.1f}s (exit code: {result.returncode})")

        if result.returncode != 0:
            print(f"[WARNING] Task failed: {result.stderr[:500]}")
            return {"_error": result.stderr[:500], "_elapsed_seconds": elapsed}

        return {"_elapsed_seconds": elapsed, "_stdout": result.stdout}

    except subprocess.TimeoutExpired:
        print(f"[WARNING] Task timed out after 600s")
        return {"_error": "timeout", "_elapsed_seconds": 600}
    except Exception as e:
        print(f"[ERROR] Task execution failed: {e}")
        return {"_error": str(e)}


def collect_results(results_dir: Path) -> Dict[str, Dict]:
    """Collect result JSON files from results directory."""
    results = {}
    if not results_dir.exists():
        print(f"[WARNING] Results directory not found: {results_dir}")
        return results

    for json_file in sorted(results_dir.glob("pll-*.json")):
        try:
            with open(json_file, "r", encoding="utf-8") as f:
                data = json.load(f)
            results[json_file.stem] = data
            print(f"  [OK] Loaded: {json_file.name}")
        except (json.JSONDecodeError, IOError) as e:
            print(f"  [WARNING] Failed to load {json_file.name}: {e}")

    return results


def record_to_mlflow(
    results: Dict[str, Dict],
    plan: dict,
    tracking_uri: str = "http://localhost:5000",
) -> None:
    """Record all low-level measurement results to MLflow."""
    if not MLFLOW_AVAILABLE:
        print("[WARNING] MLflow not installed. Skipping MLflow recording.")
        print("[INFO] Install with: pip install mlflow")
        return

    mlflow.set_tracking_uri(tracking_uri)
    mlflow.set_experiment(MLFLOW_EXPERIMENT_NAME)

    kv_ref = plan.get("kv_cache_reference", {})
    infra = plan.get("infrastructure", {})

    for pattern_id, data in results.items():
        if "_error" in data and not data.get("tool"):
            print(f"  [SKIP] {pattern_id}: error result, no tool data")
            continue

        tool = data.get("tool", "unknown")
        run_name = f"{pattern_id}-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}"

        with mlflow.start_run(run_name=run_name):
            # Common tags
            mlflow.set_tag("phase", "low-level")
            mlflow.set_tag("tool", tool)
            mlflow.set_tag("pattern_id", pattern_id)
            mlflow.set_tag("instance_type", infra.get("instance_type", "unknown"))

            # Layer tag
            layer_id = TOOL_LAYER_MAP.get(tool, "unknown")
            mlflow.set_tag("layer", layer_id)

            # Tool-specific params and metrics
            if tool == "fi_pingpong" or tool == "fi_rma_pingpong":
                _record_fi_pingpong(data)
            elif tool == "nixlbench":
                _record_nixlbench(data, kv_ref)
            elif tool == "kvbench":
                _record_kvbench(data, kv_ref)
            elif tool == "ucx_perftest":
                _record_ucx_perftest(data)

            print(f"  [OK] MLflow run created: {run_name}")

    print(f"[OK] Recorded {len(results)} results to MLflow experiment '{MLFLOW_EXPERIMENT_NAME}'")


def _record_fi_pingpong(data: Dict) -> None:
    """Record fi_pingpong results to MLflow."""
    mlflow.log_param("provider", data.get("provider", "efa"))

    results = data.get("results", [])
    for r in results:
        size = r.get("message_size", "unknown")
        if r.get("latency_us"):
            mlflow.log_metric(f"latency_us_{size}", r["latency_us"])
        if r.get("bandwidth_mbps"):
            mlflow.log_metric(f"bandwidth_mbps_{size}", r["bandwidth_mbps"])


def _record_nixlbench(data: Dict, kv_ref: dict) -> None:
    """Record NIXLBench results to MLflow."""
    mlflow.log_param("backend", data.get("backend", "unknown"))
    mlflow.log_param("initiator_seg_type", data.get("initiator_seg_type", "unknown"))
    mlflow.log_param("target_seg_type", data.get("target_seg_type", "unknown"))
    mlflow.log_param("message_size", data.get("message_size", 0))
    mlflow.log_param("message_size_human", data.get("message_size_human", "unknown"))
    mlflow.log_param("num_threads", data.get("num_threads", 1))
    mlflow.log_param("scheme", data.get("scheme", "pairwise"))
    mlflow.log_param("iterations", data.get("iterations", 0))

    # Metrics
    if data.get("latency_p50_us"):
        mlflow.log_metric("latency_p50_us", data["latency_p50_us"])
    if data.get("latency_p95_us"):
        mlflow.log_metric("latency_p95_us", data["latency_p95_us"])
    if data.get("latency_p99_us"):
        mlflow.log_metric("latency_p99_us", data["latency_p99_us"])
    if data.get("bandwidth_gbps"):
        mlflow.log_metric("bandwidth_gbps", data["bandwidth_gbps"])
    if data.get("transfer_time_ms"):
        mlflow.log_metric("transfer_time_ms", data["transfer_time_ms"])

    # KV-Cache equivalent tag
    msg_size = data.get("message_size", 0)
    bytes_per_token = kv_ref.get("bytes_per_token", 57344)
    if msg_size and bytes_per_token:
        equiv_tokens = msg_size / bytes_per_token
        mlflow.set_tag("kv_cache_equivalent_tokens", f"{equiv_tokens:.0f}")


def _record_kvbench(data: Dict, kv_ref: dict) -> None:
    """Record KVBench results to MLflow."""
    mlflow.log_param("backend", data.get("backend", "unknown"))
    mlflow.log_param("model_config", data.get("model_config", "unknown"))
    mlflow.log_param("prompt_tokens", data.get("prompt_tokens", 0))
    mlflow.log_param("action", data.get("action", "profile"))
    mlflow.log_param("kv_cache_size_bytes", data.get("kv_cache_size_bytes", 0))

    model_params = data.get("model_params", {})
    for k, v in model_params.items():
        mlflow.log_param(f"model_{k}", v)

    if data.get("kv_transfer_time_ms"):
        mlflow.log_metric("kv_transfer_time_ms", data["kv_transfer_time_ms"])
    if data.get("bandwidth_gbps"):
        mlflow.log_metric("bandwidth_gbps", data["bandwidth_gbps"])

    mlflow.set_tag("kv_cache_equivalent_tokens", str(data.get("prompt_tokens", 0)))


def _record_ucx_perftest(data: Dict) -> None:
    """Record ucx_perftest results to MLflow."""
    mlflow.log_param("test_type", data.get("test_type", "unknown"))
    mlflow.log_param("message_size", data.get("message_size", 0))
    mlflow.log_param("message_size_human", data.get("message_size_human", "unknown"))
    mlflow.log_param("memory_type", data.get("memory_type", "unknown"))
    mlflow.log_param("transport", data.get("transport", "unknown"))
    mlflow.log_param("iterations", data.get("iterations", 0))

    if data.get("latency_us"):
        mlflow.log_metric("latency_us", data["latency_us"])
    if data.get("bandwidth_mbps"):
        mlflow.log_metric("bandwidth_mbps", data["bandwidth_mbps"])
    if data.get("bandwidth_gbps"):
        mlflow.log_metric("bandwidth_gbps", data["bandwidth_gbps"])


def print_summary(results: Dict[str, Dict]) -> None:
    """Print a summary table of all results."""
    print()
    print("=" * 80)
    print("Low-Level Network Measurement Summary")
    print("=" * 80)
    print(f"{'Pattern ID':<40} {'Tool':<15} {'Key Metric':<25}")
    print("-" * 80)

    for pattern_id, data in sorted(results.items()):
        tool = data.get("tool", "unknown")

        if tool in ("fi_pingpong", "fi_rma_pingpong"):
            r = data.get("results", [{}])
            if r:
                metric = f"lat={r[-1].get('latency_us', '?')} us"
            else:
                metric = "no data"
        elif tool == "nixlbench":
            lat = data.get("latency_p50_us")
            bw = data.get("bandwidth_gbps")
            metric = f"p50={lat} us" if lat else f"bw={bw} GB/s" if bw else "no data"
        elif tool == "kvbench":
            t = data.get("kv_transfer_time_ms")
            metric = f"transfer={t} ms" if t else "no data"
        elif tool == "ucx_perftest":
            bw = data.get("bandwidth_gbps")
            lat = data.get("latency_us")
            metric = f"bw={bw} GB/s" if bw else f"lat={lat} us" if lat else "no data"
        else:
            metric = "unknown tool"

        print(f"{pattern_id:<40} {tool:<15} {metric:<25}")

    print("=" * 80)


def main():
    parser = argparse.ArgumentParser(
        description="Run low-level network measurements and record to MLflow"
    )
    parser.add_argument(
        "--layer",
        choices=["L0", "L1", "L2", "L3"],
        help="Run specific layer only (L0=fi_pingpong, L1=NIXLBench, L2=KVBench, L3=ucx_perftest)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be executed without running",
    )
    parser.add_argument(
        "--record-only",
        action="store_true",
        help="Skip execution, only record existing results to MLflow",
    )
    parser.add_argument(
        "--results-dir",
        type=Path,
        default=None,
        help="Directory containing result JSON files (default: auto-detect)",
    )
    parser.add_argument(
        "--mlflow-tracking-uri",
        default="http://localhost:5000",
        help="MLflow tracking URI (default: http://localhost:5000)",
    )
    parser.add_argument(
        "--skip-mlflow",
        action="store_true",
        help="Skip MLflow recording",
    )

    args = parser.parse_args()

    # Load experiment plan
    plan = load_experiment_plan()
    print(f"[INFO] Experiment: {plan['name']}")
    print(f"[INFO] Infrastructure: {plan['infrastructure']['instance_type']}")

    if args.layer:
        for layer in plan["layers"]:
            if layer["id"] == args.layer:
                print(f"[INFO] Layer: {layer['name']} ({layer['priority']})")
                print(f"[INFO] Estimated time: {layer.get('estimated_time_minutes', '?')} minutes")
                break

    # Determine task definitions directory
    phase_dir = EXPERIMENTS_DIR / "task-definitions" / "phase-low-level"
    task_files = find_task_definitions(phase_dir, args.layer)

    print(f"[INFO] Found {len(task_files)} task definitions")

    if args.dry_run:
        print()
        print("[DRY-RUN] Would execute the following tasks:")
        for tf in task_files:
            print(f"  - {tf.name}")
        return

    if not args.record_only:
        # Execute all tasks
        print()
        print("=" * 60)
        print("Executing Measurements")
        print("=" * 60)

        for i, tf in enumerate(task_files, 1):
            print(f"\n[{i}/{len(task_files)}] {tf.name}")
            result = execute_task(tf)
            if result.get("_error"):
                print(f"  [WARNING] Error: {result['_error']}")

    # Collect results
    results_dir = args.results_dir or EXPERIMENTS_DIR / "results" / "low-level"
    results = collect_results(results_dir)

    if not results:
        print("[WARNING] No results found. Check that measurements completed successfully.")
        return

    # Print summary
    print_summary(results)

    # Record to MLflow
    if not args.skip_mlflow:
        print()
        print("Recording to MLflow...")
        record_to_mlflow(results, plan, args.mlflow_tracking_uri)


if __name__ == "__main__":
    main()
