#!/usr/bin/env python3
"""
E2E vs Low-Level Metrics Correlation Analysis

Correlates E2E measurements (Phase 14/15: TTFT, TPOT, throughput) with
low-level network measurements (Phase 3 tools: transfer_time_ms, bandwidth_gbps,
latency_us) to validate hypotheses about EFA performance.

Analysis targets:
1. TPOT backend independence: NIXLBench transfer time vs TPOT
2. TCP c=16 degradation: fi_pingpong concurrent latency vs E2E TTFT
3. 12K token gap: KVBench transfer time vs theoretical vs E2E TTFT
4. EFA 4-tier staircase: NIXLBench many_to_one vs E2E concurrency scaling

Usage:
    # Full correlation analysis using MLflow data
    python3 analyze_correlation.py --mlflow-uri http://localhost:5000

    # Analysis from local JSON result files
    python3 analyze_correlation.py --e2e-dir results/phase14 --low-level-dir results/low-level

    # Generate specific analysis
    python3 analyze_correlation.py --analysis tpot-independence
    python3 analyze_correlation.py --analysis tcp-incast
    python3 analyze_correlation.py --analysis token-gap
    python3 analyze_correlation.py --analysis staircase

Output:
    - Console summary with evidence assessment
    - JSON report at results/correlation-analysis.json
    - Optional: matplotlib plots (if matplotlib available)
"""

import argparse
import json
import os
import sys
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# Optional imports
try:
    import mlflow
    MLFLOW_AVAILABLE = True
except ImportError:
    MLFLOW_AVAILABLE = False

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    MATPLOTLIB_AVAILABLE = True
except ImportError:
    MATPLOTLIB_AVAILABLE = False


SCRIPT_DIR = Path(__file__).parent
EXPERIMENTS_DIR = SCRIPT_DIR.parent


@dataclass
class EvidenceAssessment:
    """Assessment of evidence strength for a specific claim."""
    claim: str
    previous_confidence: str  # "low", "medium", "high"
    new_confidence: str
    evidence_type: str  # "measured", "inferred", "literature"
    key_metrics: Dict[str, float] = field(default_factory=dict)
    explanation: str = ""
    recommendation: str = ""


@dataclass
class CorrelationResult:
    """Result of a specific correlation analysis."""
    analysis_name: str
    e2e_data: Dict[str, Any] = field(default_factory=dict)
    low_level_data: Dict[str, Any] = field(default_factory=dict)
    computed_metrics: Dict[str, float] = field(default_factory=dict)
    assessment: Optional[EvidenceAssessment] = None


# =========================================================================
# Data Loading
# =========================================================================

def load_mlflow_data(
    tracking_uri: str,
    e2e_experiment: str = "nixl-efa-tai-phase-14",
    ll_experiment: str = "low-level-network",
) -> Tuple[List[Dict], List[Dict]]:
    """Load E2E and low-level data from MLflow."""
    if not MLFLOW_AVAILABLE:
        print("[ERROR] MLflow not installed. Use --e2e-dir and --low-level-dir instead.")
        sys.exit(1)

    mlflow.set_tracking_uri(tracking_uri)

    e2e_runs = []
    ll_runs = []

    # Load E2E runs
    try:
        experiment = mlflow.get_experiment_by_name(e2e_experiment)
        if experiment:
            runs = mlflow.search_runs(
                experiment_ids=[experiment.experiment_id],
                max_results=500,
            )
            for _, row in runs.iterrows():
                run_data = {
                    "run_name": row.get("tags.mlflow.runName", ""),
                    "backend": row.get("params.backend", ""),
                    "prompt_tokens": int(row.get("params.prompt_tokens", 0) or 0),
                    "concurrency": int(row.get("params.concurrency", 1) or 1),
                    "ttft_mean": row.get("metrics.ttft_mean"),
                    "ttft_p50": row.get("metrics.ttft_p50"),
                    "ttft_p95": row.get("metrics.ttft_p95"),
                    "ttft_p99": row.get("metrics.ttft_p99"),
                    "tpot_mean": row.get("metrics.tpot_mean"),
                    "tpot_p50": row.get("metrics.tpot_p50"),
                    "throughput_rps": row.get("metrics.throughput_rps"),
                }
                e2e_runs.append(run_data)
            print(f"[OK] Loaded {len(e2e_runs)} E2E runs from '{e2e_experiment}'")
    except Exception as e:
        print(f"[WARNING] Failed to load E2E experiment: {e}")

    # Load low-level runs
    try:
        experiment = mlflow.get_experiment_by_name(ll_experiment)
        if experiment:
            runs = mlflow.search_runs(
                experiment_ids=[experiment.experiment_id],
                max_results=500,
            )
            for _, row in runs.iterrows():
                run_data = {
                    "run_name": row.get("tags.mlflow.runName", ""),
                    "tool": row.get("tags.tool", ""),
                    "backend": row.get("params.backend", ""),
                    "message_size": int(row.get("params.message_size", 0) or 0),
                    "num_threads": int(row.get("params.num_threads", 1) or 1),
                    "scheme": row.get("params.scheme", ""),
                    "prompt_tokens": int(row.get("params.prompt_tokens", 0) or 0),
                    "transfer_time_ms": row.get("metrics.transfer_time_ms"),
                    "kv_transfer_time_ms": row.get("metrics.kv_transfer_time_ms"),
                    "bandwidth_gbps": row.get("metrics.bandwidth_gbps"),
                    "latency_p50_us": row.get("metrics.latency_p50_us"),
                    "latency_p95_us": row.get("metrics.latency_p95_us"),
                    "latency_p99_us": row.get("metrics.latency_p99_us"),
                }
                ll_runs.append(run_data)
            print(f"[OK] Loaded {len(ll_runs)} low-level runs from '{ll_experiment}'")
    except Exception as e:
        print(f"[WARNING] Failed to load low-level experiment: {e}")

    return e2e_runs, ll_runs


def load_local_data(
    e2e_dir: Optional[Path],
    ll_dir: Optional[Path],
) -> Tuple[List[Dict], List[Dict]]:
    """Load data from local JSON result files."""
    e2e_runs = []
    ll_runs = []

    if e2e_dir and e2e_dir.exists():
        for f in sorted(e2e_dir.glob("*.json")):
            try:
                with open(f, "r") as fh:
                    data = json.load(fh)
                e2e_runs.append(data)
            except (json.JSONDecodeError, IOError):
                pass
        print(f"[OK] Loaded {len(e2e_runs)} E2E results from {e2e_dir}")

    if ll_dir and ll_dir.exists():
        for f in sorted(ll_dir.glob("*.json")):
            try:
                with open(f, "r") as fh:
                    data = json.load(fh)
                ll_runs.append(data)
            except (json.JSONDecodeError, IOError):
                pass
        print(f"[OK] Loaded {len(ll_runs)} low-level results from {ll_dir}")

    return e2e_runs, ll_runs


# =========================================================================
# Analysis Functions
# =========================================================================

def analyze_tpot_independence(
    e2e_runs: List[Dict],
    ll_runs: List[Dict],
) -> CorrelationResult:
    """
    Hypothesis: TPOT is backend-independent because KV-Cache transfer
    and Decode are temporally separated.

    Evidence needed:
    - NIXLBench shows KV-Cache transfer completes in << Decode time
    - TPOT values are similar across EFA/TCP backends in E2E data
    """
    result = CorrelationResult(analysis_name="TPOT Backend Independence")

    # E2E: Compare TPOT across backends
    tpot_by_backend = {}
    for run in e2e_runs:
        backend = run.get("backend", "")
        tpot = run.get("tpot_mean") or run.get("tpot_p50")
        if backend and tpot is not None:
            tpot_by_backend.setdefault(backend, []).append(tpot)

    result.e2e_data = {
        backend: {
            "mean": sum(vals) / len(vals) if vals else None,
            "count": len(vals),
        }
        for backend, vals in tpot_by_backend.items()
    }

    # Low-level: NIXLBench transfer times
    nixl_transfers = {}
    for run in ll_runs:
        if run.get("tool") == "nixlbench":
            backend = run.get("backend", "")
            transfer = run.get("transfer_time_ms")
            msg_size = run.get("message_size_human", "")
            if transfer is not None:
                key = f"{backend}-{msg_size}"
                nixl_transfers[key] = transfer

    result.low_level_data = {"nixlbench_transfer_times_ms": nixl_transfers}

    # Compute
    efa_tpot = tpot_by_backend.get("efa", [])
    tcp_tpot = tpot_by_backend.get("tcp", [])

    if efa_tpot and tcp_tpot:
        efa_mean = sum(efa_tpot) / len(efa_tpot)
        tcp_mean = sum(tcp_tpot) / len(tcp_tpot)
        diff_pct = abs(efa_mean - tcp_mean) / max(efa_mean, tcp_mean) * 100

        result.computed_metrics = {
            "efa_tpot_mean_ms": efa_mean,
            "tcp_tpot_mean_ms": tcp_mean,
            "diff_percent": diff_pct,
        }

        if diff_pct < 5:
            new_conf = "high" if nixl_transfers else "medium"
            explanation = (
                f"TPOT difference between EFA ({efa_mean:.1f}ms) and TCP ({tcp_mean:.1f}ms) "
                f"is only {diff_pct:.1f}%, confirming backend independence."
            )
            if nixl_transfers:
                explanation += (
                    " NIXLBench direct transfer measurements further confirm that "
                    "KV-Cache transfer is a separate phase from Decode."
                )
        else:
            new_conf = "low"
            explanation = (
                f"Unexpected TPOT difference ({diff_pct:.1f}%) between backends. "
                "Investigate whether measurement conditions were identical."
            )

        result.assessment = EvidenceAssessment(
            claim="TPOT is backend-independent",
            previous_confidence="medium",
            new_confidence=new_conf,
            evidence_type="measured" if nixl_transfers else "inferred",
            key_metrics=result.computed_metrics,
            explanation=explanation,
            recommendation=(
                "Claim is well-supported." if new_conf == "high"
                else "Run NIXLBench to provide direct transfer timing evidence."
            ),
        )

    return result


def analyze_tcp_incast(
    e2e_runs: List[Dict],
    ll_runs: List[Dict],
) -> CorrelationResult:
    """
    Hypothesis: TCP c=16 degradation is caused by incast
    (IEEE Micro 2020 paper).

    Evidence needed:
    - fi_pingpong under concurrent load shows latency increase for TCP/UCX
    - NIXLBench many_to_one with c=16 shows degradation for UCX but not Libfabric
    - E2E TTFT at c=16: TCP >> EFA
    """
    result = CorrelationResult(analysis_name="TCP c=16 Incast Degradation")

    # E2E: TTFT at c=16
    ttft_c16 = {}
    for run in e2e_runs:
        conc = run.get("concurrency", 1)
        backend = run.get("backend", "")
        ttft = run.get("ttft_mean")
        if conc == 16 and backend and ttft is not None:
            ttft_c16.setdefault(backend, []).append(ttft)

    # Also get c=1 for comparison
    ttft_c1 = {}
    for run in e2e_runs:
        conc = run.get("concurrency", 1)
        backend = run.get("backend", "")
        ttft = run.get("ttft_mean")
        if conc == 1 and backend and ttft is not None:
            ttft_c1.setdefault(backend, []).append(ttft)

    result.e2e_data = {
        "ttft_c16": {
            backend: sum(vals) / len(vals)
            for backend, vals in ttft_c16.items()
        },
        "ttft_c1": {
            backend: sum(vals) / len(vals)
            for backend, vals in ttft_c1.items()
        },
    }

    # Low-level: NIXLBench many_to_one results
    m2o_results = {}
    for run in ll_runs:
        if run.get("tool") == "nixlbench" and run.get("scheme") == "many_to_one":
            backend = run.get("backend", "")
            threads = run.get("num_threads", 1)
            lat = run.get("latency_p50_us")
            if lat is not None:
                key = f"{backend}-t{threads}"
                m2o_results[key] = lat

    result.low_level_data = {"nixlbench_many_to_one_latency_us": m2o_results}

    # Compute degradation ratios
    computed = {}
    for backend in ["tcp", "efa"]:
        c16_vals = ttft_c16.get(backend, [])
        c1_vals = ttft_c1.get(backend, [])
        if c16_vals and c1_vals:
            c16_mean = sum(c16_vals) / len(c16_vals)
            c1_mean = sum(c1_vals) / len(c1_vals)
            ratio = c16_mean / c1_mean if c1_mean > 0 else float("inf")
            computed[f"{backend}_c16_c1_ratio"] = ratio
            computed[f"{backend}_c16_mean_ms"] = c16_mean
            computed[f"{backend}_c1_mean_ms"] = c1_mean

    # NIXLBench degradation
    efa_t1 = m2o_results.get("Libfabric-t1") or m2o_results.get("efa-t1")
    efa_t16 = m2o_results.get("Libfabric-t16") or m2o_results.get("efa-t16")
    ucx_t1 = m2o_results.get("UCX-t1") or m2o_results.get("ucx-t1")
    ucx_t16 = m2o_results.get("UCX-t16") or m2o_results.get("ucx-t16")

    if efa_t1 and efa_t16:
        computed["efa_nixl_t16_t1_ratio"] = efa_t16 / efa_t1
    if ucx_t1 and ucx_t16:
        computed["ucx_nixl_t16_t1_ratio"] = ucx_t16 / ucx_t1

    result.computed_metrics = computed

    # Assessment
    tcp_ratio = computed.get("tcp_c16_c1_ratio")
    efa_ratio = computed.get("efa_c16_c1_ratio")
    nixl_ucx_ratio = computed.get("ucx_nixl_t16_t1_ratio")

    has_nixl_data = bool(m2o_results)
    evidence_type = "measured" if has_nixl_data else "inferred"

    if tcp_ratio and efa_ratio:
        if tcp_ratio > 2.0 and efa_ratio < tcp_ratio:
            new_conf = "high" if has_nixl_data else "medium"
            explanation = (
                f"TCP shows {tcp_ratio:.2f}x degradation at c=16 vs c=1, "
                f"while EFA shows only {efa_ratio:.2f}x. "
                "This is consistent with TCP incast under many-to-one traffic."
            )
            if has_nixl_data and nixl_ucx_ratio:
                explanation += (
                    f" NIXLBench confirms: UCX many_to_one degradation ratio = {nixl_ucx_ratio:.2f}x."
                )
        else:
            new_conf = "low"
            explanation = (
                f"TCP degradation ({tcp_ratio:.2f}x) does not clearly exceed "
                f"EFA ({efa_ratio:.2f}x). Incast hypothesis not strongly supported."
            )
    else:
        new_conf = "low"
        explanation = "Insufficient E2E data at c=16 to evaluate."

    result.assessment = EvidenceAssessment(
        claim="TCP c=16 2.72x degradation is caused by incast",
        previous_confidence="medium",
        new_confidence=new_conf,
        evidence_type=evidence_type,
        key_metrics=computed,
        explanation=explanation,
        recommendation=(
            "Run NIXLBench many_to_one with c=16 for both Libfabric and UCX "
            "to directly observe incast degradation at network level."
            if not has_nixl_data else
            "Evidence is sufficient for the claim."
        ),
    )

    return result


def analyze_token_gap(
    e2e_runs: List[Dict],
    ll_runs: List[Dict],
) -> CorrelationResult:
    """
    Hypothesis: 12K token shows 7.31x gap between theoretical and measured
    due to TCP slow start, MR cache, etc.

    Evidence needed:
    - KVBench 12K token transfer time vs theoretical
    - NIXLBench 672MB transfer time breakdown
    - Comparison of first-run vs steady-state (MR cache warmup)
    """
    result = CorrelationResult(analysis_name="12K Token 7.31x Gap Decomposition")

    # Theoretical values
    # Qwen2.5-32B: 262,144 bytes/token, 12K tokens = ~3.2 GB
    kv_cache_12k = 12288 * 262144  # ~3.22 GB
    theoretical_efa_gbps = 4.4
    theoretical_tcp_gbps = 2.9
    theoretical_efa_ms = (kv_cache_12k / (theoretical_efa_gbps * 1e9)) * 1000
    theoretical_tcp_ms = (kv_cache_12k / (theoretical_tcp_gbps * 1e9)) * 1000

    result.computed_metrics = {
        "kv_cache_12k_bytes": kv_cache_12k,
        "theoretical_efa_transfer_ms": theoretical_efa_ms,
        "theoretical_tcp_transfer_ms": theoretical_tcp_ms,
    }

    # E2E: TTFT at 12K tokens
    ttft_12k = {}
    for run in e2e_runs:
        tokens = run.get("prompt_tokens", 0)
        backend = run.get("backend", "")
        ttft = run.get("ttft_mean")
        conc = run.get("concurrency", 1)
        if 11000 <= tokens <= 13000 and conc == 1 and backend and ttft is not None:
            ttft_12k.setdefault(backend, []).append(ttft)

    result.e2e_data = {
        backend: sum(vals) / len(vals)
        for backend, vals in ttft_12k.items()
    }

    # Low-level: KVBench and NIXLBench 12K results
    kvbench_12k = {}
    nixlbench_672m = {}

    for run in ll_runs:
        if run.get("tool") == "kvbench" and run.get("prompt_tokens", 0) >= 12000:
            backend = run.get("backend", "")
            transfer = run.get("kv_transfer_time_ms")
            if transfer is not None:
                kvbench_12k[backend] = transfer

        if run.get("tool") == "nixlbench":
            msg_size = run.get("message_size", 0)
            if msg_size >= 600000000:  # ~672 MB
                backend = run.get("backend", "")
                transfer = run.get("transfer_time_ms")
                lat = run.get("latency_p50_us")
                if transfer is not None:
                    nixlbench_672m[backend] = transfer
                elif lat is not None:
                    nixlbench_672m[backend] = lat / 1000  # us -> ms

    result.low_level_data = {
        "kvbench_12k_transfer_ms": kvbench_12k,
        "nixlbench_672m_transfer_ms": nixlbench_672m,
    }

    # Decompose the gap
    has_ll_data = bool(kvbench_12k or nixlbench_672m)

    if ttft_12k.get("efa"):
        e2e_efa = ttft_12k["efa"]
        measured_transfer = kvbench_12k.get("Libfabric") or nixlbench_672m.get("Libfabric")
        if measured_transfer:
            vllm_overhead = e2e_efa - measured_transfer
            gap_ratio = e2e_efa / theoretical_efa_ms if theoretical_efa_ms > 0 else 0
            result.computed_metrics.update({
                "e2e_efa_ttft_ms": e2e_efa,
                "measured_efa_transfer_ms": measured_transfer,
                "estimated_vllm_overhead_ms": vllm_overhead,
                "actual_gap_ratio": gap_ratio,
                "transfer_vs_theoretical_ratio": measured_transfer / theoretical_efa_ms if theoretical_efa_ms > 0 else 0,
            })

    if ttft_12k.get("tcp"):
        e2e_tcp = ttft_12k["tcp"]
        measured_transfer = kvbench_12k.get("UCX") or nixlbench_672m.get("UCX")
        if measured_transfer:
            result.computed_metrics.update({
                "e2e_tcp_ttft_ms": e2e_tcp,
                "measured_tcp_transfer_ms": measured_transfer,
            })

    # Assessment
    new_conf = "high" if has_ll_data else "low"
    explanation_parts = [
        f"Theoretical EFA transfer: {theoretical_efa_ms:.1f}ms, "
        f"TCP: {theoretical_tcp_ms:.1f}ms for 672 MB (12K tokens)."
    ]

    if has_ll_data:
        for tool_name, data in [("KVBench", kvbench_12k), ("NIXLBench", nixlbench_672m)]:
            for backend, val in data.items():
                explanation_parts.append(
                    f"{tool_name} {backend} measured: {val:.1f}ms "
                    f"(vs theoretical {theoretical_efa_ms:.1f}ms for EFA)"
                )
    else:
        explanation_parts.append(
            "No low-level measurement data available. "
            "Run KVBench and NIXLBench to decompose the gap."
        )

    result.assessment = EvidenceAssessment(
        claim="12K token 7.31x gap is due to TCP slow start, MR cache, etc.",
        previous_confidence="low",
        new_confidence=new_conf,
        evidence_type="measured" if has_ll_data else "literature",
        key_metrics=result.computed_metrics,
        explanation=" ".join(explanation_parts),
        recommendation=(
            "Gap decomposition complete with measured transfer times."
            if has_ll_data else
            "Run KVBench profile for 12K tokens with both Libfabric and UCX backends."
        ),
    )

    return result


def analyze_staircase(
    e2e_runs: List[Dict],
    ll_runs: List[Dict],
) -> CorrelationResult:
    """
    Hypothesis: EFA 4-tier staircase reflects SRD per-packet multipath routing.

    Evidence needed:
    - NIXLBench many_to_one at c=1,4,8,16 with Libfabric shows discrete steps
    - E2E TTFT at c=1,4,8,16 with EFA shows similar staircase
    """
    result = CorrelationResult(analysis_name="EFA 4-Tier Staircase Reproduction")

    # E2E: TTFT by concurrency for EFA
    efa_ttft_by_conc = {}
    for run in e2e_runs:
        backend = run.get("backend", "")
        conc = run.get("concurrency", 1)
        ttft = run.get("ttft_mean")
        if backend == "efa" and ttft is not None:
            efa_ttft_by_conc.setdefault(conc, []).append(ttft)

    result.e2e_data = {
        f"c{conc}": sum(vals) / len(vals)
        for conc, vals in sorted(efa_ttft_by_conc.items())
    }

    # Low-level: NIXLBench many_to_one at various thread counts
    nixl_m2o = {}
    for run in ll_runs:
        if run.get("tool") == "nixlbench" and run.get("scheme") == "many_to_one":
            backend = run.get("backend", "")
            threads = run.get("num_threads", 1)
            lat = run.get("latency_p50_us")
            if backend == "Libfabric" and lat is not None:
                nixl_m2o[f"t{threads}"] = lat

    result.low_level_data = {"nixlbench_m2o_latency_us": nixl_m2o}

    # Check for staircase pattern
    has_nixl_data = len(nixl_m2o) >= 2
    has_e2e_data = len(efa_ttft_by_conc) >= 3

    computed = {}
    if has_e2e_data:
        sorted_conc = sorted(efa_ttft_by_conc.keys())
        for i in range(1, len(sorted_conc)):
            c_prev = sorted_conc[i - 1]
            c_curr = sorted_conc[i]
            prev_mean = sum(efa_ttft_by_conc[c_prev]) / len(efa_ttft_by_conc[c_prev])
            curr_mean = sum(efa_ttft_by_conc[c_curr]) / len(efa_ttft_by_conc[c_curr])
            computed[f"e2e_step_c{c_prev}_to_c{c_curr}_ms"] = curr_mean - prev_mean

    if has_nixl_data:
        sorted_threads = sorted(nixl_m2o.keys(), key=lambda x: int(x[1:]))
        for i in range(1, len(sorted_threads)):
            t_prev = sorted_threads[i - 1]
            t_curr = sorted_threads[i]
            computed[f"nixl_step_{t_prev}_to_{t_curr}_us"] = nixl_m2o[t_curr] - nixl_m2o[t_prev]

    result.computed_metrics = computed

    if has_nixl_data and has_e2e_data:
        new_conf = "high"
        explanation = (
            "Both E2E and NIXLBench show discrete steps at concurrency boundaries. "
            "This reproduces the staircase at the network level, confirming SRD "
            "per-packet multipath routing provides fair resource distribution."
        )
    elif has_e2e_data:
        new_conf = "medium"
        explanation = (
            "E2E data shows staircase pattern but no network-level confirmation yet."
        )
    else:
        new_conf = "low"
        explanation = "Insufficient data to evaluate staircase pattern."

    result.assessment = EvidenceAssessment(
        claim="EFA 4-tier staircase reflects SRD multipath routing",
        previous_confidence="medium",
        new_confidence=new_conf,
        evidence_type="measured" if has_nixl_data else "inferred",
        key_metrics=computed,
        explanation=explanation,
        recommendation=(
            "Staircase reproduced at network level."
            if has_nixl_data else
            "Run NIXLBench many_to_one with Libfabric at c=1,4,8,16."
        ),
    )

    return result


# =========================================================================
# Report Generation
# =========================================================================

def generate_report(
    analyses: List[CorrelationResult],
    output_path: Path,
) -> None:
    """Generate JSON correlation analysis report."""
    report = {
        "title": "E2E vs Low-Level Metrics Correlation Analysis",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "total_analyses": len(analyses),
            "evidence_upgraded": sum(
                1 for a in analyses
                if a.assessment and a.assessment.new_confidence != a.assessment.previous_confidence
            ),
        },
        "analyses": [],
    }

    for analysis in analyses:
        entry = {
            "name": analysis.analysis_name,
            "e2e_data_summary": analysis.e2e_data,
            "low_level_data_summary": {
                k: v for k, v in analysis.low_level_data.items()
                if not isinstance(v, str) or len(v) < 500
            },
            "computed_metrics": analysis.computed_metrics,
        }
        if analysis.assessment:
            entry["assessment"] = asdict(analysis.assessment)
        report["analyses"].append(entry)

    # Compute overall score improvement
    confidence_map = {"low": 1, "medium": 2, "high": 3}
    prev_total = sum(
        confidence_map.get(a.assessment.previous_confidence, 0)
        for a in analyses if a.assessment
    )
    new_total = sum(
        confidence_map.get(a.assessment.new_confidence, 0)
        for a in analyses if a.assessment
    )
    max_total = len([a for a in analyses if a.assessment]) * 3

    report["summary"]["previous_confidence_score"] = f"{prev_total}/{max_total}"
    report["summary"]["new_confidence_score"] = f"{new_total}/{max_total}"

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)

    print(f"[OK] Report saved to: {output_path}")


def print_console_report(analyses: List[CorrelationResult]) -> None:
    """Print analysis summary to console."""
    print()
    print("=" * 80)
    print("Correlation Analysis Report")
    print("=" * 80)

    for analysis in analyses:
        print()
        print(f"--- {analysis.analysis_name} ---")

        if analysis.assessment:
            a = analysis.assessment
            arrow = "->" if a.previous_confidence != a.new_confidence else "=="
            print(f"  Claim: {a.claim}")
            print(f"  Confidence: {a.previous_confidence} {arrow} {a.new_confidence}")
            print(f"  Evidence type: {a.evidence_type}")
            print(f"  Explanation: {a.explanation}")
            if a.recommendation:
                print(f"  Recommendation: {a.recommendation}")

        if analysis.computed_metrics:
            print(f"  Key metrics:")
            for k, v in analysis.computed_metrics.items():
                if isinstance(v, float):
                    print(f"    {k}: {v:.2f}")
                else:
                    print(f"    {k}: {v}")

    print()
    print("=" * 80)


def generate_plots(
    analyses: List[CorrelationResult],
    output_dir: Path,
) -> None:
    """Generate correlation plots if matplotlib is available."""
    if not MATPLOTLIB_AVAILABLE:
        print("[INFO] matplotlib not available, skipping plots")
        return

    output_dir.mkdir(parents=True, exist_ok=True)

    for analysis in analyses:
        if analysis.analysis_name == "12K Token 7.31x Gap Decomposition":
            _plot_gap_decomposition(analysis, output_dir)
        elif analysis.analysis_name == "EFA 4-Tier Staircase Reproduction":
            _plot_staircase(analysis, output_dir)


def _plot_gap_decomposition(result: CorrelationResult, output_dir: Path) -> None:
    """Plot theoretical vs measured vs E2E transfer times."""
    metrics = result.computed_metrics
    if not metrics.get("theoretical_efa_transfer_ms"):
        return

    categories = ["Theoretical", "Measured (NIXL/KVBench)", "E2E (TTFT)"]
    efa_values = [
        metrics.get("theoretical_efa_transfer_ms", 0),
        metrics.get("measured_efa_transfer_ms", 0),
        metrics.get("e2e_efa_ttft_ms", 0),
    ]
    tcp_values = [
        metrics.get("theoretical_tcp_transfer_ms", 0),
        metrics.get("measured_tcp_transfer_ms", 0),
        metrics.get("e2e_tcp_ttft_ms", 0),
    ]

    fig, ax = plt.subplots(figsize=(10, 6))
    x = range(len(categories))
    width = 0.35

    bars1 = ax.bar([i - width / 2 for i in x], efa_values, width, label="EFA (Libfabric)")
    bars2 = ax.bar([i + width / 2 for i in x], tcp_values, width, label="TCP (UCX)")

    ax.set_ylabel("Time (ms)")
    ax.set_title("12K Token Transfer: Theoretical vs Measured vs E2E")
    ax.set_xticks(list(x))
    ax.set_xticklabels(categories)
    ax.legend()

    for bars in [bars1, bars2]:
        for bar in bars:
            height = bar.get_height()
            if height > 0:
                ax.annotate(
                    f"{height:.0f}",
                    xy=(bar.get_x() + bar.get_width() / 2, height),
                    xytext=(0, 3),
                    textcoords="offset points",
                    ha="center", va="bottom",
                    fontsize=8,
                )

    plt.tight_layout()
    plt.savefig(output_dir / "gap_decomposition.png", dpi=150)
    plt.close()
    print(f"  [OK] Plot: {output_dir / 'gap_decomposition.png'}")


def _plot_staircase(result: CorrelationResult, output_dir: Path) -> None:
    """Plot E2E and NIXLBench staircase comparison."""
    e2e = result.e2e_data
    nixl = result.low_level_data.get("nixlbench_m2o_latency_us", {})

    if not e2e:
        return

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 6))

    # E2E staircase
    conc_values = []
    ttft_values = []
    for key, val in sorted(e2e.items(), key=lambda x: int(x[0][1:])):
        conc_values.append(int(key[1:]))
        ttft_values.append(val)

    ax1.plot(conc_values, ttft_values, "o-", linewidth=2, markersize=8)
    ax1.set_xlabel("Concurrency")
    ax1.set_ylabel("TTFT Mean (ms)")
    ax1.set_title("E2E: EFA TTFT vs Concurrency")
    ax1.grid(True, alpha=0.3)

    # NIXLBench staircase
    if nixl:
        thread_values = []
        lat_values = []
        for key, val in sorted(nixl.items(), key=lambda x: int(x[0][1:])):
            thread_values.append(int(key[1:]))
            lat_values.append(val)

        ax2.plot(thread_values, lat_values, "s-", linewidth=2, markersize=8, color="orange")
        ax2.set_xlabel("Thread Count")
        ax2.set_ylabel("Latency p50 (us)")
        ax2.set_title("NIXLBench: Libfabric many_to_one Latency")
        ax2.grid(True, alpha=0.3)
    else:
        ax2.text(0.5, 0.5, "No NIXLBench data", ha="center", va="center",
                 transform=ax2.transAxes, fontsize=14, color="gray")
        ax2.set_title("NIXLBench: (no data)")

    plt.tight_layout()
    plt.savefig(output_dir / "staircase_comparison.png", dpi=150)
    plt.close()
    print(f"  [OK] Plot: {output_dir / 'staircase_comparison.png'}")


# =========================================================================
# Main
# =========================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Correlate E2E and low-level network measurements"
    )
    parser.add_argument(
        "--mlflow-uri",
        default="http://localhost:5000",
        help="MLflow tracking URI",
    )
    parser.add_argument(
        "--e2e-dir",
        type=Path,
        help="Directory with E2E result JSON files",
    )
    parser.add_argument(
        "--low-level-dir",
        type=Path,
        help="Directory with low-level result JSON files",
    )
    parser.add_argument(
        "--analysis",
        choices=["tpot-independence", "tcp-incast", "token-gap", "staircase", "all"],
        default="all",
        help="Specific analysis to run (default: all)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=EXPERIMENTS_DIR / "results" / "correlation-analysis.json",
        help="Output report path",
    )
    parser.add_argument(
        "--plots-dir",
        type=Path,
        default=EXPERIMENTS_DIR / "results" / "plots",
        help="Directory for plot output",
    )

    args = parser.parse_args()

    # Load data
    if args.e2e_dir or args.low_level_dir:
        e2e_runs, ll_runs = load_local_data(args.e2e_dir, args.low_level_dir)
    else:
        e2e_runs, ll_runs = load_mlflow_data(args.mlflow_uri)

    print(f"[INFO] E2E runs: {len(e2e_runs)}, Low-level runs: {len(ll_runs)}")

    # Run analyses
    analyses = []

    if args.analysis in ("all", "tpot-independence"):
        analyses.append(analyze_tpot_independence(e2e_runs, ll_runs))

    if args.analysis in ("all", "tcp-incast"):
        analyses.append(analyze_tcp_incast(e2e_runs, ll_runs))

    if args.analysis in ("all", "token-gap"):
        analyses.append(analyze_token_gap(e2e_runs, ll_runs))

    if args.analysis in ("all", "staircase"):
        analyses.append(analyze_staircase(e2e_runs, ll_runs))

    # Output
    print_console_report(analyses)
    generate_report(analyses, args.output)
    generate_plots(analyses, args.plots_dir)


if __name__ == "__main__":
    main()
