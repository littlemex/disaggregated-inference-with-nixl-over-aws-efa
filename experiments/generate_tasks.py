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
import os
import re
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


def generate_task_json(
    pattern: dict,
    layer: dict,
    plan: dict,
    env: Environment,
    output_dir: Path,
    consumer_dir: Path,
) -> int:
    """Generate JSON task definition(s) for a single pattern.

    Returns number of files generated.
    """
    backend = pattern.get("backend", "unified")
    pattern_id = pattern["id"]
    phase = plan["phase"]
    infrastructure = plan["infrastructure"]
    common = plan.get("common_settings", {})

    # Merge common settings with pattern overrides
    merged = merge_settings(common, pattern)
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

    if backend == "unified":
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
        producer_path = output_dir / f"{pattern_id}.json"
        content = producer_template.render(**template_vars)
        with open(producer_path, "w", encoding="utf-8") as f:
            f.write(content)

        consumer_template = env.get_template("disaggregated-consumer.json.jinja2")
        consumer_path = consumer_dir / f"{pattern_id}-consumer.json"
        content = consumer_template.render(**template_vars)
        with open(consumer_path, "w", encoding="utf-8") as f:
            f.write(content)

        print(f"  [OK] {producer_path.name} + {consumer_path.name}")
        return 2


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
    consumer_dir = output_dir / "consumer"

    if args.dry_run:
        print("[DRY-RUN] Would create directories:")
        print(f"  {output_dir}")
        print(f"  {consumer_dir}")
    else:
        output_dir.mkdir(parents=True, exist_ok=True)
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
                backend = pattern.get("backend", "unified")
                files = 1 if backend == "unified" else 2
                print(f"  [DRY-RUN] {pattern['id']}: {files} file(s)")
                total_files += files
                total_patterns += 1
        else:
            for pattern in layer["patterns"]:
                files = generate_task_json(
                    pattern, layer, plan, env, output_dir, consumer_dir
                )
                total_files += files
                total_patterns += 1

    print()
    print(f"[{'DRY-RUN ' if args.dry_run else ''}SUCCESS] Generated {total_files} JSON files from {total_patterns} patterns")
    if not args.dry_run:
        print(f"[INFO] Output: {output_dir}")
        print(f"[INFO] Consumer: {consumer_dir}")
    print()
    print("[NEXT STEPS]")
    print(f"  1. Review generated JSON files in task-definitions/{phase_name}/")
    print(f"  2. Deploy scripts: ./run_experiment.sh {phase_name} deploy")
    print(f"  3. Run experiment: ./run_experiment.sh {phase_name} run L0")


if __name__ == "__main__":
    main()
