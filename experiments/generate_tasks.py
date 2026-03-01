#!/usr/bin/env python3
"""
Unified JSON Task Definition Generator

Reads experiment-plans/phase{N}.json and generates task-definitions/phase{N}/*.json
using Jinja2 templates. All phases share the same generator and templates.

Usage:
    ./generate_tasks.py phase14         # Generate Phase 14 task definitions
    ./generate_tasks.py phase15         # Generate Phase 15 task definitions
    ./generate_tasks.py phase16         # Generate Phase 16 task definitions (future)
    ./generate_tasks.py --list          # List available experiment plans

Environment variables:
    FORCE_OVERWRITE=1   Overwrite existing task definitions without confirmation
"""

import argparse
import json
import sys
from pathlib import Path

try:
    from jinja2 import Environment, FileSystemLoader
except ImportError:
    print("[ERROR] jinja2 is required. Install with: pip install jinja2")
    sys.exit(1)


SCRIPT_DIR = Path(__file__).parent
PLANS_DIR = SCRIPT_DIR / "experiment-plans"
TEMPLATES_DIR = SCRIPT_DIR / "templates"


def load_experiment_plan(phase_name: str) -> dict:
    """Load experiment plan JSON for the given phase name."""
    plan_path = PLANS_DIR / f"{phase_name}.json"
    if not plan_path.exists():
        print(f"[ERROR] Experiment plan not found: {plan_path}")
        print(f"[INFO] Available plans: {list_plans()}")
        sys.exit(1)

    with open(plan_path, "r", encoding="utf-8") as f:
        return json.load(f)


def list_plans() -> list:
    """List available experiment plan names."""
    plans = []
    if PLANS_DIR.exists():
        for p in sorted(PLANS_DIR.glob("*.json")):
            plans.append(p.stem)
    return plans


def setup_jinja_env() -> Environment:
    """Set up Jinja2 environment with templates directory."""
    env = Environment(
        loader=FileSystemLoader(TEMPLATES_DIR),
        trim_blocks=True,
        lstrip_blocks=True,
    )
    return env


def merge_settings(common: dict, pattern: dict) -> dict:
    """Merge common_settings with pattern-level overrides.

    Pattern values take precedence over common_settings.
    """
    merged = {**common}
    for key, value in pattern.items():
        if key != "id":
            merged[key] = value
    return merged


def compute_derived_values(merged: dict, infrastructure: dict) -> dict:
    """Compute derived template variables from merged settings."""
    # Model size heuristic for initialization wait time
    model_name = infrastructure.get("model", "")
    if "32B" in model_name or "70B" in model_name:
        merged["init_wait_seconds"] = 180
    elif "14B" in model_name:
        merged["init_wait_seconds"] = 150
    else:
        merged["init_wait_seconds"] = 120

    # TP per node: total TP / node count
    tp_size = infrastructure.get("tp_size", 1)
    node_count = infrastructure.get("node_count", 2)
    merged["tp_per_node"] = max(tp_size // node_count, 1)

    # KV buffer size: scale based on model size
    if "32B" in model_name or "70B" in model_name:
        merged["kv_buffer_size"] = 5000000000  # 5GB
    else:
        merged["kv_buffer_size"] = 1000000000  # 1GB

    # max_model_len: use pattern override or compute from prompt_tokens
    if "max_model_len" not in merged:
        prompt_tokens = merged.get("prompt_tokens", 4096)
        if prompt_tokens >= 100000:
            merged["max_model_len"] = 131072
        elif prompt_tokens >= 50000:
            merged["max_model_len"] = 65536
        elif prompt_tokens >= 20000:
            merged["max_model_len"] = 32768
        elif prompt_tokens >= 10000:
            merged["max_model_len"] = 20480
        else:
            merged["max_model_len"] = 16384

    return merged


# Low-level tools that require dual-node execution (server + client)
DUAL_NODE_TOOLS = {"fi_pingpong", "fi_rma_pingpong", "fi_rdm_pingpong", "nixlbench", "ucx_perftest"}

# Low-level tool to template mapping (single-node tools)
LOW_LEVEL_TEMPLATE_MAP = {
    "fi_pingpong": "low-level-fi-pingpong.json.jinja2",
    "fi_rma_pingpong": "low-level-fi-pingpong.json.jinja2",
    "fi_rdm_pingpong": "low-level-fi-pingpong.json.jinja2",
    "nixlbench": "low-level-nixlbench.json.jinja2",
    "kvbench": "low-level-kvbench.json.jinja2",
    "ucx_perftest": "low-level-ucx-perftest.json.jinja2",
}

# Low-level tool to server/client template mapping (dual-node tools)
LOW_LEVEL_SERVER_TEMPLATE_MAP = {
    "fi_pingpong": "low-level-fi-pingpong-server.json.jinja2",
    "fi_rma_pingpong": "low-level-fi-pingpong-server.json.jinja2",
    "fi_rdm_pingpong": "low-level-fi-pingpong-server.json.jinja2",
    "nixlbench": "low-level-nixlbench-server.json.jinja2",
    "ucx_perftest": "low-level-ucx-perftest-server.json.jinja2",
}

LOW_LEVEL_CLIENT_TEMPLATE_MAP = {
    "fi_pingpong": "low-level-fi-pingpong-client.json.jinja2",
    "fi_rma_pingpong": "low-level-fi-pingpong-client.json.jinja2",
    "fi_rdm_pingpong": "low-level-fi-pingpong-client.json.jinja2",
    "nixlbench": "low-level-nixlbench-client.json.jinja2",
    "ucx_perftest": "low-level-ucx-perftest-client.json.jinja2",
}

# Baseline tool to template mapping (single-node tools)
BASELINE_TEMPLATE_MAP = {
    "fi_info": "baseline-fi-info.json.jinja2",
    "nccl-tests": "baseline-nccl-test.json.jinja2",
    "nvidia-smi": "baseline-nvidia-smi.json.jinja2",
    "nvidia-smi dmon": "baseline-nvidia-smi.json.jinja2",
    "nvidia-smi topo -m": "baseline-nvidia-smi.json.jinja2",
}

# Baseline tools that require dual-node execution (server + client)
BASELINE_DUAL_NODE_TOOLS = {"fi_rdm_bw", "fi_rdm_pingpong", "iperf3"}

# Baseline dual-node tool template (same template, rendered with different node_role)
BASELINE_DUAL_NODE_TEMPLATE_MAP = {
    "fi_rdm_bw": "baseline-fi-rdm-bw.json.jinja2",
    "fi_rdm_pingpong": "baseline-fi-rdm-pingpong.json.jinja2",
    "iperf3": "baseline-iperf3.json.jinja2",
}


def generate_task_json(
    pattern: dict,
    layer: dict,
    plan: dict,
    env: Environment,
    output_dir: Path,
    producer_dir: Path,
    consumer_dir: Path,
) -> int:
    """Generate JSON task definition(s) for a single pattern.

    Supports both E2E patterns (unified/disaggregated via mode field) and
    low-level tool patterns (fi_pingpong, nixlbench, kvbench, ucx_perftest
    via tool field).

    Returns number of files generated.
    """
    pattern_id = pattern["id"]
    phase = plan["phase"]
    infrastructure = plan["infrastructure"]
    common = plan.get("common_settings", {})

    # Check if this is an analysis pattern
    pattern_type = pattern.get("type")
    if pattern_type in ["analysis", "measurement"]:
        return _generate_analysis_task(
            pattern, layer, plan, env, output_dir
        )

    # Check if this is a baseline tool pattern (L0-Baseline layer only)
    tool = pattern.get("tool")
    layer_id = layer.get("id", "")
    is_baseline_layer = layer_id.startswith("L0-Baseline")
    if is_baseline_layer and tool and (tool in BASELINE_TEMPLATE_MAP or tool in BASELINE_DUAL_NODE_TOOLS):
        baseline_dir = output_dir / "baseline"
        baseline_dir.mkdir(parents=True, exist_ok=True)
        return _generate_baseline_task(
            pattern, layer, plan, env, baseline_dir
        )

    # Check if this is a low-level tool pattern
    if tool and tool in LOW_LEVEL_TEMPLATE_MAP:
        low_level_dir = output_dir / "low-level"
        low_level_dir.mkdir(parents=True, exist_ok=True)
        return _generate_low_level_task(
            pattern, layer, plan, env, low_level_dir
        )

    # E2E pattern (existing logic)
    # Determine mode: use 'mode' field if present, otherwise infer from 'backend'
    mode = pattern.get("mode", "unified")

    # For disaggregated mode, use 'transport' as backend if 'backend' not explicitly set
    if mode == "disaggregated":
        backend = pattern.get("backend") or pattern.get("transport", "efa")
    else:
        backend = pattern.get("backend", "unified")

    # Merge common settings, layer vllm_config, and pattern overrides
    # Priority: common < layer vllm_config < pattern
    merged = {**common}

    # Apply layer vllm_config (overrides common)
    layer_vllm_config = layer.get("vllm_config", {})
    for key, value in layer_vllm_config.items():
        merged[key] = value

    # Apply pattern overrides (highest priority)
    for key, value in pattern.items():
        if key != "id":
            merged[key] = value

    merged = compute_derived_values(merged, infrastructure)

    # Template variables
    template_vars = {
        "pattern_id": pattern_id,
        "phase": phase,
        "infrastructure": infrastructure,
        "layer_name": layer.get("name", ""),
        "layer_priority": layer.get("priority", "P0"),
        **merged,
    }

    if mode == "unified":
        template = env.get_template("unified.json.jinja2")
        output_path = output_dir / f"{pattern_id}.json"
        content = template.render(**template_vars)
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(content)
        print(f"  [OK] {output_path.name}")
        return 1
    else:
        # Disaggregated: Producer + Consumer
        template_vars["backend"] = backend

        producer_template = env.get_template("disaggregated-producer.json.jinja2")
        producer_path = producer_dir / f"{pattern_id}.json"
        content = producer_template.render(**template_vars)
        with open(producer_path, "w", encoding="utf-8") as f:
            f.write(content)

        consumer_template = env.get_template("disaggregated-consumer.json.jinja2")
        consumer_path = consumer_dir / f"{pattern_id}.json"
        content = consumer_template.render(**template_vars)
        with open(consumer_path, "w", encoding="utf-8") as f:
            f.write(content)

        print(f"  [OK] {producer_path.name} + {consumer_path.name}")
        return 2


def _generate_baseline_task(
    pattern: dict,
    layer: dict,
    plan: dict,
    env: Environment,
    output_dir: Path,
) -> int:
    """Generate JSON task definition for a baseline measurement pattern.

    Baseline tools (fi_info, fi_rdm_bw, fi_rdm_pingpong, iperf3, nccl-tests,
    nvidia-smi) use dedicated templates from baseline-*.json.jinja2.

    Dual-node tools (fi_rdm_bw, fi_rdm_pingpong, iperf3) generate server +
    client JSON pairs. Single-node tools (fi_info, nccl-tests, nvidia-smi)
    generate a single JSON file.

    When pattern has "node": "both" and the tool is dual-node, two files are
    generated: one with node_role=server and one with node_role=client.

    Returns number of files generated.
    """
    tool = pattern["tool"]
    pattern_id = pattern["id"]
    phase = plan["phase"]
    infrastructure = plan["infrastructure"]

    # Timestamp for output file naming
    from datetime import datetime, timezone
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # Base template variables shared across all baseline tools
    base_vars = {
        "pattern_id": pattern_id,
        "phase": phase,
        "infrastructure": infrastructure,
        "output_dir": "/tmp/results",
        "timestamp": timestamp,
        "layer_name": layer.get("name", ""),
        "layer_priority": layer.get("priority", "P0"),
    }

    # Add NCCL-specific parameters
    if tool == "nccl-tests":
        base_vars["nccl_min_size"] = pattern.get("nccl_min_size", "1M")
        base_vars["nccl_max_size"] = pattern.get("nccl_max_size", "1G")
        base_vars["nccl_factor"] = pattern.get("nccl_factor", "2")
        base_vars["nccl_ngpus"] = str(infrastructure.get("gpu_count_per_node", 4))

    if tool in BASELINE_DUAL_NODE_TOOLS:
        # Dual-node: generate server + client pair
        template_name = BASELINE_DUAL_NODE_TEMPLATE_MAP[tool]
        template = env.get_template(template_name)

        # Server JSON
        server_vars = {**base_vars, "node_role": "server", "peer_ip": ""}
        server_vars["pattern_id"] = f"{pattern_id}-server"
        server_vars["output_dir"] = "/tmp/results"
        server_path = output_dir / f"{pattern_id}-server.json"
        server_content = template.render(**server_vars)

        # Validate JSON
        try:
            json.loads(server_content)
        except json.JSONDecodeError as e:
            print(f"  [ERROR] Invalid JSON for {pattern_id}-server: {e}")
            return 0

        with open(server_path, "w", encoding="utf-8") as f:
            f.write(server_content)

        # Client JSON
        client_vars = {**base_vars, "node_role": "client", "peer_ip": ""}
        client_vars["pattern_id"] = f"{pattern_id}-client"
        client_vars["output_dir"] = "/tmp/results"
        client_path = output_dir / f"{pattern_id}-client.json"
        client_content = template.render(**client_vars)

        try:
            json.loads(client_content)
        except json.JSONDecodeError as e:
            print(f"  [ERROR] Invalid JSON for {pattern_id}-client: {e}")
            return 0

        with open(client_path, "w", encoding="utf-8") as f:
            f.write(client_content)

        print(f"  [OK] {server_path.name} + {client_path.name} (baseline: {tool})")
        return 2
    else:
        # Single-node tool (fi_info, nccl-tests, nvidia-smi variants)
        template_name = BASELINE_TEMPLATE_MAP.get(tool)
        if template_name is None:
            print(f"  [ERROR] No baseline template found for tool: {tool}")
            return 0

        template = env.get_template(template_name)
        output_path = output_dir / f"{pattern_id}.json"
        content = template.render(**base_vars)

        try:
            json.loads(content)
        except json.JSONDecodeError as e:
            print(f"  [ERROR] Invalid JSON for {pattern_id}: {e}")
            return 0

        with open(output_path, "w", encoding="utf-8") as f:
            f.write(content)

        print(f"  [OK] {output_path.name} (baseline: {tool})")
        return 1


def _generate_low_level_task(
    pattern: dict,
    layer: dict,
    plan: dict,
    env: Environment,
    output_dir: Path,
) -> int:
    """Generate JSON task definition for a low-level tool pattern.

    Low-level tools (fi_pingpong, nixlbench, kvbench, ucx_perftest) use
    dedicated templates and do not require common_settings merging or
    derived value computation (no vLLM server involved).

    Dual-node tools (fi_pingpong, fi_rma_pingpong, nixlbench, ucx_perftest)
    generate server + client JSON pairs, similar to disaggregated patterns.
    Single-node tools (kvbench) generate a single JSON file.

    Returns number of files generated.
    """
    tool = pattern["tool"]
    pattern_id = pattern["id"]
    infrastructure = plan["infrastructure"]
    common = plan.get("common_settings", {})

    # Merge common settings (warmup_iterations, measurement_iterations)
    # but skip E2E-specific derived value computation
    merged = {**common}
    for key, value in pattern.items():
        if key != "id":
            merged[key] = value

    # KV-Cache reference (needed for bytes_per_token in templates)
    kv_cache_ref = plan.get("kv_cache_reference", {})

    # Model params for KVBench (from pattern or plan defaults)
    if tool == "kvbench" and "model_params" not in merged:
        # Derive model_params from kv_cache_reference comment if available
        pass

    template_vars = {
        "pattern_id": pattern_id,
        "phase": plan.get("phase", "low-level"),
        "infrastructure": infrastructure,
        "kv_cache_reference": kv_cache_ref,
        "layer_name": layer.get("name", ""),
        "layer_priority": layer.get("priority", "P0"),
        **merged,
    }

    # Ensure bytes_per_token is available for KVBench
    # Default: 262144 bytes/token for Qwen2.5-32B (2 * 64 layers * 8 kv_heads * 128 head_dim * 2 bytes)
    if "bytes_per_token" not in template_vars:
        template_vars["bytes_per_token"] = kv_cache_ref.get("bytes_per_token", 262144)

    if tool in DUAL_NODE_TOOLS:
        # Generate server + client pair for dual-node execution
        server_template_name = LOW_LEVEL_SERVER_TEMPLATE_MAP[tool]
        client_template_name = LOW_LEVEL_CLIENT_TEMPLATE_MAP[tool]
        server_template = env.get_template(server_template_name)
        client_template = env.get_template(client_template_name)

        # Server JSON (runs on Node1)
        server_path = output_dir / f"{pattern_id}.json"
        server_content = server_template.render(**template_vars)
        with open(server_path, "w", encoding="utf-8") as f:
            f.write(server_content)

        # Client JSON (runs on Node2, stored in client/ subdir)
        client_dir = output_dir / "client"
        client_dir.mkdir(parents=True, exist_ok=True)
        client_path = client_dir / f"{pattern_id}-client.json"
        client_content = client_template.render(**template_vars)
        with open(client_path, "w", encoding="utf-8") as f:
            f.write(client_content)

        print(f"  [OK] {server_path.name} + {client_path.name} ({tool})")
        return 2
    else:
        # Single-node tool (e.g., kvbench)
        template_name = LOW_LEVEL_TEMPLATE_MAP[tool]
        template = env.get_template(template_name)

        output_path = output_dir / f"{pattern_id}.json"
        content = template.render(**template_vars)

        with open(output_path, "w", encoding="utf-8") as f:
            f.write(content)

        print(f"  [OK] {output_path.name} ({tool})")
        return 1


def _generate_analysis_task(
    pattern: dict,
    layer: dict,
    plan: dict,
    env: Environment,
    output_dir: Path,
) -> int:
    """Generate JSON task definition for an analysis pattern.

    Analysis patterns (type: "analysis" or "measurement") run data analysis
    scripts without starting vLLM servers. They process results from previous
    measurement layers (L1-Unified, L2-EFA, L3-TCP) and generate reports.

    Returns number of files generated (always 1).
    """
    pattern_id = pattern["id"]
    description = pattern.get("description", "")
    infrastructure = plan["infrastructure"]

    template_vars = {
        "pattern_id": pattern_id,
        "phase": plan.get("phase", "1"),
        "infrastructure": infrastructure,
        "description": description,
        "layer_name": layer.get("name", ""),
        "layer_priority": layer.get("priority", "P0"),
    }

    template = env.get_template("analysis.json.jinja2")
    output_path = output_dir / f"{pattern_id}.json"
    content = template.render(**template_vars)

    with open(output_path, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"  [OK] {output_path.name} (analysis)")
    return 1


def main():
    parser = argparse.ArgumentParser(
        description="Generate JSON task definitions from experiment plans"
    )
    parser.add_argument(
        "phase",
        nargs="?",
        help="Phase name (e.g., phase14, phase15)",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="List available experiment plans",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be generated without writing files",
    )

    args = parser.parse_args()

    if args.list:
        plans = list_plans()
        if plans:
            print("[INFO] Available experiment plans:")
            for p in plans:
                print(f"  - {p}")
        else:
            print("[INFO] No experiment plans found in {}".format(PLANS_DIR))
        return

    if not args.phase:
        parser.print_help()
        sys.exit(1)

    phase_name = args.phase

    # Load experiment plan
    plan = load_experiment_plan(phase_name)
    phase_num = plan["phase"]

    print("=" * 60)
    print(f"Task Definition Generator - Phase {phase_num}")
    print("=" * 60)
    print(f"[INFO] Plan: {plan['name']}")
    print(f"[INFO] Description: {plan['description']}")
    print(f"[INFO] Infrastructure: {plan['infrastructure']['instance_type']} x {plan['infrastructure']['node_count']}")
    print(f"[INFO] Model: {plan['infrastructure']['model']}")
    print()

    # Output directories
    output_dir = SCRIPT_DIR / "task-definitions" / phase_name
    producer_dir = output_dir / "producer"
    consumer_dir = output_dir / "consumer"

    low_level_dir = output_dir / "low-level"
    baseline_dir = output_dir / "baseline"

    if args.dry_run:
        print("[DRY-RUN] Would create directories:")
        print(f"  {output_dir}")
        print(f"  {producer_dir}")
        print(f"  {consumer_dir}")
        print(f"  {low_level_dir}")
        print(f"  {baseline_dir}")
    else:
        output_dir.mkdir(parents=True, exist_ok=True)
        producer_dir.mkdir(parents=True, exist_ok=True)
        consumer_dir.mkdir(parents=True, exist_ok=True)

    # Set up Jinja2
    env = setup_jinja_env()

    # Generate task definitions
    total_files = 0
    total_patterns = 0

    for layer in plan["layers"]:
        layer_id = layer.get("id", "")
        layer_name = layer.get("name", "")
        layer_priority = layer.get("priority", "P0")
        pattern_count = len(layer.get("patterns", []))

        print(f"[LAYER] {layer_id}: {layer_name} ({layer_priority}, {pattern_count} patterns)")

        if args.dry_run:
            for pattern in layer["patterns"]:
                # Skip comment-only entries (no "id" field)
                if "id" not in pattern:
                    continue
                tool = pattern.get("tool")
                is_baseline = layer_id.startswith("L0-Baseline")
                if is_baseline and tool and (tool in BASELINE_TEMPLATE_MAP or tool in BASELINE_DUAL_NODE_TOOLS):
                    files = 2 if tool in BASELINE_DUAL_NODE_TOOLS else 1
                    mode = "server+client" if tool in BASELINE_DUAL_NODE_TOOLS else "single"
                    print(f"  [DRY-RUN] {pattern['id']}: {files} file(s) (baseline: {tool}, {mode})")
                elif tool and tool in LOW_LEVEL_TEMPLATE_MAP:
                    files = 2 if tool in DUAL_NODE_TOOLS else 1
                    mode = "server+client" if tool in DUAL_NODE_TOOLS else "single"
                    print(f"  [DRY-RUN] {pattern['id']}: {files} file(s) ({tool}, {mode})")
                else:
                    backend = pattern.get("backend", "unified")
                    files = 1 if backend == "unified" else 2
                    print(f"  [DRY-RUN] {pattern['id']}: {files} file(s)")
                total_files += files
                total_patterns += 1
        else:
            for pattern in layer["patterns"]:
                # Skip comment-only entries (no "id" field)
                if "id" not in pattern:
                    continue
                files = generate_task_json(
                    pattern, layer, plan, env, output_dir, producer_dir, consumer_dir
                )
                total_files += files
                total_patterns += 1

    print()
    print(f"[{'DRY-RUN ' if args.dry_run else ''}SUCCESS] Generated {total_files} JSON files from {total_patterns} patterns")
    if not args.dry_run:
        print(f"[INFO] Output: {output_dir}")
        print(f"[INFO] Producer: {producer_dir}")
        print(f"[INFO] Consumer: {consumer_dir}")
        if baseline_dir.exists():
            print(f"[INFO] Baseline: {baseline_dir}")
        if low_level_dir.exists():
            print(f"[INFO] Low-level: {low_level_dir}")
    print()
    print("[NEXT STEPS]")
    print(f"  1. Review generated JSON files in task-definitions/{phase_name}/")
    print(f"  2. Deploy scripts: ./run_experiment.sh {phase_name} deploy")
    print(f"  3. Run experiment: ./run_experiment.sh {phase_name} run L0")


if __name__ == "__main__":
    main()
