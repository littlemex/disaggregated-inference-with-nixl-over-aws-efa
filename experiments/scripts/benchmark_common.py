#!/usr/bin/env python3
"""
Unified Benchmark Script for Disaggregated Inference Experiments

Phase-agnostic benchmark that works with all phases (14, 15, 16, ...).
Phase number is passed via --phase flag and affects:
- MLflow experiment name: nixl-efa-tai-phase-{N}
- Output metadata: phase field in results JSON
- Default model selection (can be overridden with --model)

Based on Phase 15 implementation with improvements:
- Warmup/measurement separation (--warmup-iterations, --num-iterations)
- Layer/Priority tags for experiment tracking
- Phase number parameterization
- Timeout configuration (--request-timeout)

Usage:
  # Unified measurement
  python3 benchmark_common.py --measurement-type online --url http://localhost:8100 \
    --model Qwen/Qwen2.5-7B-Instruct --mode unified --backend none \
    --prompt-tokens 4096 --max-tokens 10 --warmup-iterations 20 --num-iterations 30 \
    --output results.json --phase 14

  # Disaggregated measurement (via Proxy)
  python3 benchmark_common.py --measurement-type online --url http://localhost:8000 \
    --model Qwen/Qwen2.5-32B-Instruct --mode disaggregated --backend efa \
    --prompt-tokens 20000 --max-tokens 10 --warmup-iterations 20 --num-iterations 30 \
    --prefix-cache disabled --output results.json --phase 15
"""
import argparse
import asyncio
import json
import os
import random
import statistics
import string
import subprocess
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

import aiohttp

# MLflow is optional
try:
    import mlflow
    MLFLOW_AVAILABLE = True
except ImportError:
    MLFLOW_AVAILABLE = False

# tokenizer is optional (transformers)
try:
    from transformers import AutoTokenizer
    TOKENIZER_AVAILABLE = True
except ImportError:
    TOKENIZER_AVAILABLE = False


# Random text vocabulary for prompt generation
_VOCAB_WORDS = (
    "the of and to a in is that it was for on are with as his they be at one "
    "have this from by hot but some what there we can out other were all your "
    "when up use word how said an each she which do their time if will way "
    "about many then them would write like so these her long make thing see "
    "him two has look more day could go come did my sound no most number who "
    "over know water than call first people may down side been now find head "
    "stand own page should country found answer school grow study still learn "
    "plant cover food sun four thought let keep eye never last door between "
    "city tree cross since hard start might story saw far sea draw left late "
    "run while press close night real life few stop open seem together next "
    "white children begin got walk example ease paper often always music those "
    "both mark book letter until mile river car feet care second group carry "
    "took rain eat room friend began idea fish mountain north once base hear "
    "horse cut sure watch color face wood main enough plain girl usual young "
    "ready above ever red list though feel talk bird soon body dog family "
    "direct pose leave song measure state product black short numeral class "
    "wind question happen complete ship area half rock order fire south problem "
    "piece told knew pass farm top whole king size heard best hour better true "
    "during hundred remember step early hold west ground interest reach fast "
    "five sing listen six table travel less morning ten simple several vowel "
    "toward war lay against pattern slow center love person money serve appear "
    "road map science rule govern pull cold notice voice fall power town fine "
    "certain fly unit lead cry dark machine note wait plan figure star box "
    "noun field rest correct able pound done beauty drive stood contain front "
    "teach week final gave green oh quick develop sleep warm free minute strong "
    "special mind behind clear tail produce fact street inch lot nothing course "
    "stay wheel full force blue object decide surface deep moon island foot "
    "yet busy test record boat common gold possible plane age dry wonder laugh "
    "thousand ago ran check game shape yes cool miss brought heat snow bed "
    "bring sit perhaps fill east weight language among"
).split()


# =========================================================================
# Utility functions
# =========================================================================

def generate_random_text(num_words: int) -> str:
    """Generate random English text with the specified number of words."""
    return " ".join(random.choices(_VOCAB_WORDS, k=num_words))


def generate_prompt_by_tokens(target_tokens: int, model_name: str) -> str:
    """Generate a prompt with the specified number of tokens.

    Uses tokenizer if available, otherwise falls back to word count estimation.
    """
    prefix = "Please read the following text carefully and summarize it:\n\n"

    if TOKENIZER_AVAILABLE:
        try:
            tokenizer = AutoTokenizer.from_pretrained(
                model_name, trust_remote_code=True
            )
            prefix_tokens = len(tokenizer.encode(prefix))
            remaining_tokens = max(target_tokens - prefix_tokens, 10)

            estimated_words = int(remaining_tokens * 0.75)
            text = generate_random_text(estimated_words)

            for _ in range(10):
                actual_tokens = len(tokenizer.encode(prefix + text))
                diff = target_tokens - actual_tokens
                if abs(diff) <= 2:
                    break
                if diff > 0:
                    text = text + " " + generate_random_text(
                        max(int(abs(diff) * 0.75), 1)
                    )
                else:
                    words = text.split()
                    trim = max(int(abs(diff) * 0.75), 1)
                    text = (
                        " ".join(words[:-trim])
                        if len(words) > trim
                        else " ".join(words[:1])
                    )

            actual = len(tokenizer.encode(prefix + text))
            print(
                "[INFO] Prompt generated: target={} tokens, actual={} tokens".format(
                    target_tokens, actual
                )
            )
            return prefix + text
        except Exception as e:
            print("[WARNING] tokenizer error, using estimate: {}".format(e))

    # Fallback: no tokenizer
    estimated_words = int(target_tokens * 0.75)
    text = generate_random_text(max(estimated_words, 10))
    print(
        "[INFO] Prompt generated: target={} tokens (estimated, no tokenizer)".format(
            target_tokens
        )
    )
    return prefix + text


def generate_random_suffix(length: int = 12) -> str:
    """Generate random suffix to prevent Prefix Cache hits."""
    return "".join(random.choices(string.ascii_lowercase + string.digits, k=length))


def parse_tags(tags_str: Optional[str]) -> Dict[str, str]:
    """Parse user-specified tags string. Format: 'key1=value1,key2=value2'"""
    if not tags_str:
        return {}
    result = {}
    for pair in tags_str.split(","):
        pair = pair.strip()
        if "=" in pair:
            key, value = pair.split("=", 1)
            result[key.strip()] = value.strip()
    return result


def get_instance_type() -> str:
    """Get EC2 instance type from metadata. Returns 'unknown' on failure."""
    try:
        result = subprocess.run(
            [
                "curl", "-s", "--connect-timeout", "2",
                "http://169.254.169.254/latest/meta-data/instance-type",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except Exception:
        pass
    return "unknown"


def get_vllm_version() -> str:
    """Get vLLM version string."""
    try:
        import vllm
        return vllm.__version__
    except Exception:
        return "unknown"


def compute_percentiles(values: List[float]) -> Dict[str, Any]:
    """
    [FIXED HIGH-8] Compute P50, P95, P99 percentiles with interpolation.

    Uses statistics.quantiles() for accurate percentile calculation with linear
    interpolation, avoiding off-by-one errors from int() truncation.
    """
    if not values:
        return {
            "p50": 0, "p95": 0, "p99": 0,
            "mean": 0, "stdev": 0, "min": 0, "max": 0,
            "raw": [],
        }

    # statistics.quantiles(data, n=100) で 100分位数を計算
    # 50th percentile = quantiles[49], 95th = quantiles[94], 99th = quantiles[98]
    try:
        quantiles = statistics.quantiles(values, n=100, method='inclusive')
        p50 = quantiles[49]  # 50th percentile
        p95 = quantiles[94]  # 95th percentile
        p99 = quantiles[98]  # 99th percentile
    except statistics.StatisticsError:
        # データが少なすぎる場合（n < 2）はフォールバック
        sorted_vals = sorted(values)
        n = len(sorted_vals)
        p50 = sorted_vals[n // 2] if n > 0 else 0
        p95 = sorted_vals[min(int(n * 0.95), n - 1)] if n > 0 else 0
        p99 = sorted_vals[min(int(n * 0.99), n - 1)] if n > 0 else 0

    return {
        "p50": p50,
        "p95": p95,
        "p99": p99,
        "mean": statistics.mean(values),
        "stdev": statistics.stdev(values) if len(values) > 1 else 0,
        "min": min(values),
        "max": max(values),
        "raw": values,
    }


def analyze_bimodality(values: List[float], threshold_ratio: float = 0.3) -> Dict[str, Any]:
    """
    [P0-3] Analyze bimodal distribution and separate into Phase A/B

    Simple bimodal detection: split by median if stdev is large

    Args:
        values: List of measured values
        threshold_ratio: CV (coefficient of variation) threshold

    Returns:
        {
            "bimodal": True/False,
            "phase_a": [values],  # Slow phase
            "phase_b": [values],  # Fast phase
            "phase_a_stats": {...},
            "phase_b_stats": {...},
            "raw_stats": {...}
        }

    Note:
        For advanced detection, use diptest + KMeans:
        ```python
        from diptest import diptest
        from sklearn.cluster import KMeans
        dip_stat, p_value = diptest(values)
        if p_value < 0.05:
            kmeans = KMeans(n_clusters=2).fit(np.array(values).reshape(-1, 1))
            ...
        ```
    """
    if len(values) < 10:
        return {
            "bimodal": False,
            "phase_a": [],
            "phase_b": values,
            "phase_a_stats": {},
            "phase_b_stats": compute_percentiles(values),
            "raw_stats": compute_percentiles(values),
        }

    mean_val = statistics.mean(values)
    stdev_val = statistics.stdev(values)
    cv = stdev_val / mean_val if mean_val > 0 else 0

    if cv > threshold_ratio:
        median_val = statistics.median(values)
        phase_a = [v for v in values if v > median_val]  # Slow
        phase_b = [v for v in values if v <= median_val]  # Fast

        if len(phase_a) > 0 and len(phase_b) > 0:
            return {
                "bimodal": True,
                "phase_a": phase_a,
                "phase_b": phase_b,
                "phase_a_stats": compute_percentiles(phase_a),
                "phase_b_stats": compute_percentiles(phase_b),
                "raw_stats": compute_percentiles(values),
                "cv": cv,
                "threshold": threshold_ratio,
            }

    return {
        "bimodal": False,
        "phase_a": [],
        "phase_b": values,
        "phase_a_stats": {},
        "phase_b_stats": compute_percentiles(values),
        "raw_stats": compute_percentiles(values),
        "cv": cv,
        "threshold": threshold_ratio,
    }


# =========================================================================
# Online measurement (aiohttp-based)
# =========================================================================

async def measure_streaming(
    session: aiohttp.ClientSession,
    url: str,
    payload: dict,
    request_timeout: int = 600,
) -> Dict[str, Any]:
    """Measure TTFT and TPOT via SSE streaming."""
    payload_copy = {**payload, "stream": True}
    request_start = time.perf_counter()
    first_token_time = None
    token_times = []
    tokens = []
    proxy_timing = {}  # [CRITICAL] Proxy タイミングヘッダーを記録

    try:
        async with session.post(
            url,
            json=payload_copy,
            timeout=aiohttp.ClientTimeout(total=request_timeout),
        ) as response:
            if response.status != 200:
                error_text = await response.text()
                return {
                    "error": "HTTP {}: {}".format(response.status, error_text[:200])
                }

            # [CRITICAL] Proxy のタイミングヘッダーを読み取る
            if "X-Proxy-Prefill-Time" in response.headers:
                try:
                    proxy_timing["prefill_time_ms"] = float(response.headers["X-Proxy-Prefill-Time"])
                except (ValueError, KeyError):
                    pass
            if "X-Proxy-KV-Extract-Time" in response.headers:
                try:
                    proxy_timing["kv_extract_time_ms"] = float(response.headers["X-Proxy-KV-Extract-Time"])
                except (ValueError, KeyError):
                    pass
            async for line in response.content:
                line = line.decode("utf-8").strip()
                if not line or not line.startswith("data: "):
                    continue
                if line == "data: [DONE]":
                    break
                chunk_time = time.perf_counter()
                try:
                    data = json.loads(line[6:])
                    token_text = data["choices"][0].get("text", "")
                    if token_text:
                        if first_token_time is None:
                            first_token_time = chunk_time
                        token_times.append(chunk_time)
                        tokens.append(token_text)
                except json.JSONDecodeError:
                    continue

        end_time = time.perf_counter()
        if first_token_time is None or len(tokens) == 0:
            return {"error": "No tokens generated"}

        ttft = first_token_time - request_start
        e2e_latency = end_time - request_start
        itls = [
            token_times[i] - token_times[i - 1]
            for i in range(1, len(token_times))
        ]
        tpot = (e2e_latency - ttft) / max(len(tokens) - 1, 1)

        result = {
            "ttft_ms": ttft * 1000,
            "e2e_latency_ms": e2e_latency * 1000,
            "tpot_ms": tpot * 1000,
            "avg_itl_ms": (statistics.mean(itls) * 1000) if itls else 0,
            "median_itl_ms": (statistics.median(itls) * 1000) if itls else 0,
            "p95_itl_ms": (
                sorted(itls)[int(len(itls) * 0.95)] * 1000
            ) if len(itls) > 1 else 0,
            "completion_tokens": len(tokens),
            "throughput_tok_per_sec": (
                len(tokens) / e2e_latency if e2e_latency > 0 else 0
            ),
            "request_start": request_start,
        }

        # [CRITICAL] Proxy タイミング情報を結果に追加
        if proxy_timing:
            result["proxy_timing"] = proxy_timing

        return result
    except asyncio.TimeoutError:
        return {"error": "Request timeout ({}s)".format(request_timeout)}
    except Exception as e:
        return {"error": str(e)}


async def measure_with_semaphore(
    semaphore: asyncio.Semaphore,
    session: aiohttp.ClientSession,
    url: str,
    model: str,
    prompt: str,
    max_tokens: int,
    request_timeout: int = 600,
) -> Dict[str, Any]:
    """Semaphore-based concurrency control for a single request."""
    async with semaphore:
        payload = {
            "model": model,
            "prompt": prompt,
            "max_tokens": max_tokens,
            "temperature": 0.7,
        }
        return await measure_streaming(
            session,
            "{}/v1/completions".format(url),
            payload,
            request_timeout=request_timeout,
        )


async def run_warmup(
    session: aiohttp.ClientSession,
    url: str,
    model: str,
    warmup_count: int = 20,
):
    """Run warmup requests.

    NIXL Multi-level State Transition mitigation (discovered in Phase 14):
    default 20 warmup requests to ensure stable state.
    """
    print("[INFO] Running warmup ({} requests)...".format(warmup_count))
    for i in range(warmup_count):
        payload = {
            "model": model,
            "prompt": "Hello world. " + generate_random_suffix(),
            "max_tokens": 10,
            "temperature": 0.7,
        }
        r = await measure_streaming(
            session, "{}/v1/completions".format(url), payload
        )
        if "ttft_ms" in r:
            status = "TTFT={:.2f}ms".format(r["ttft_ms"])
        else:
            status = "ERROR: {}".format(r.get("error", "unknown"))
        if (i + 1) % 5 == 0 or i == 0:
            print("  Warmup {}/{}: {}".format(i + 1, warmup_count, status))
        await asyncio.sleep(0.5)
    print("[INFO] Warmup complete")
    print()


async def run_serial_benchmark(
    session: aiohttp.ClientSession,
    url: str,
    model: str,
    base_prompt: str,
    max_tokens: int,
    num_iterations: int,
    disable_prefix_caching: bool,
    request_timeout: int = 600,
) -> List[Dict[str, Any]]:
    """Run serial benchmark (concurrency=1)."""
    all_results = []

    for i in range(num_iterations):
        prompt = base_prompt
        if disable_prefix_caching:
            prompt = base_prompt + "\n[request_id:{}]".format(
                generate_random_suffix()
            )

        payload = {
            "model": model,
            "prompt": prompt,
            "max_tokens": max_tokens,
            "temperature": 0.7,
        }
        r = await measure_streaming(
            session,
            "{}/v1/completions".format(url),
            payload,
            request_timeout=request_timeout,
        )
        if "error" in r:
            print(
                "  Iter {}/{}: ERROR - {}".format(
                    i + 1, num_iterations, r["error"]
                )
            )
            continue

        print(
            "  Iter {}/{}: TTFT={:.2f}ms, TPOT={:.2f}ms, E2E={:.2f}ms".format(
                i + 1,
                num_iterations,
                r["ttft_ms"],
                r["tpot_ms"],
                r["e2e_latency_ms"],
            )
        )
        all_results.append(r)
        await asyncio.sleep(0.5)

    return all_results


async def run_concurrent_benchmark(
    session: aiohttp.ClientSession,
    url: str,
    model: str,
    base_prompt: str,
    max_tokens: int,
    num_iterations: int,
    concurrency: int,
    disable_prefix_caching: bool,
    request_timeout: int = 600,
) -> List[Dict[str, Any]]:
    """Run concurrent benchmark."""
    all_results = []
    semaphore = asyncio.Semaphore(concurrency)

    for round_num in range(num_iterations):
        tasks = []
        for _ in range(concurrency):
            prompt = base_prompt
            if disable_prefix_caching:
                prompt = base_prompt + "\n[request_id:{}]".format(
                    generate_random_suffix()
                )

            task = asyncio.create_task(
                measure_with_semaphore(
                    semaphore,
                    session,
                    url,
                    model,
                    prompt,
                    max_tokens,
                    request_timeout,
                )
            )
            tasks.append(task)

        results = await asyncio.gather(*tasks)

        successes = 0
        errors = 0
        round_ttfts = []
        for r in results:
            if "error" in r:
                errors += 1
            else:
                successes += 1
                all_results.append(r)
                round_ttfts.append(r["ttft_ms"])

        if round_ttfts:
            print(
                "  Round {}/{}: success={}, errors={}, "
                "TTFT range={:.2f}-{:.2f}ms".format(
                    round_num + 1,
                    num_iterations,
                    successes,
                    errors,
                    min(round_ttfts),
                    max(round_ttfts),
                )
            )
        else:
            print(
                "  Round {}/{}: success={}, errors={}".format(
                    round_num + 1, num_iterations, successes, errors
                )
            )

        await asyncio.sleep(1)

    return all_results


# =========================================================================
# MLflow integration
# =========================================================================

def log_to_mlflow(
    args, output: Dict[str, Any], output_file: str
) -> Optional[str]:
    """Log parameters, metrics, tags and artifacts to MLflow."""
    if not MLFLOW_AVAILABLE:
        print("[WARNING] mlflow not installed. Skipping MLflow logging.")
        return None

    if not getattr(args, "mlflow_tracking_uri", None):
        print("[INFO] --mlflow-tracking-uri not set. Skipping MLflow logging.")
        return None

    try:
        mlflow.set_tracking_uri(args.mlflow_tracking_uri)
        mlflow.set_experiment(args.mlflow_experiment_name)

        run_name = getattr(args, "mlflow_run_name", None)
        if not run_name:
            timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
            prefix_str = "nocache" if args.prefix_cache == "disabled" else "cache"
            run_name = "{}-{}-{}-pt{}-c{}-{}".format(
                args.mode,
                args.backend,
                prefix_str,
                args.prompt_tokens,
                args.concurrency,
                timestamp,
            )

        with mlflow.start_run(run_name=run_name) as run:
            run_id = run.info.run_id

            # Parameters
            params = {
                "phase": str(args.phase),
                "mode": args.mode,
                "backend": args.backend,
                "prefix_cache": args.prefix_cache,
                "prompt_tokens": args.prompt_tokens,
                "max_tokens": args.max_tokens,
                "warmup_iterations": args.warmup_iterations,
                "measurement_iterations": args.num_iterations,
                "concurrency": args.concurrency,
                "measurement_type": args.measurement_type,
                "model": args.model,
                "vllm_version": get_vllm_version(),
            }

            if hasattr(args, "url") and args.url:
                params["url"] = args.url

            mlflow.log_params(params)

            # Tags
            auto_tags = {
                "phase": str(args.phase),
                "mode": args.mode,
                "backend": args.backend,
                "prefix_cache": args.prefix_cache,
                "prompt_tokens": str(args.prompt_tokens),
                "concurrency": str(args.concurrency),
                "measurement_type": args.measurement_type,
                "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                "instance_type": get_instance_type(),
            }

            if hasattr(args, "layer") and args.layer:
                auto_tags["layer"] = args.layer
            if hasattr(args, "priority") and args.priority:
                auto_tags["priority"] = args.priority

            mlflow.set_tags(auto_tags)

            # User-specified tags
            user_tags = parse_tags(getattr(args, "tags", None))
            if user_tags:
                mlflow.set_tags(user_tags)

            # Metrics
            results = output.get("results", {})
            ttft = results.get("ttft", {})
            tpot = results.get("tpot", {})
            e2e = results.get("e2e_latency", {})

            for stat_key in ["p50", "p95", "p99", "mean", "stdev"]:
                val = ttft.get(stat_key)
                if val is not None:
                    mlflow.log_metric("ttft_{}".format(stat_key), val)
                val = tpot.get(stat_key)
                if val is not None:
                    mlflow.log_metric("tpot_{}".format(stat_key), val)
                val = e2e.get(stat_key)
                if val is not None:
                    mlflow.log_metric("e2e_{}".format(stat_key), val)

            throughput = results.get("throughput_rps")
            if throughput is not None and throughput > 0:
                mlflow.log_metric("throughput_rps", throughput)

            # Artifacts
            if os.path.exists(output_file):
                mlflow.log_artifact(output_file)

            print("[INFO] MLflow run_id: {}".format(run_id))
            print("[INFO] MLflow run_name: {}".format(run_name))
            return run_id

    except Exception as e:
        print("[WARNING] MLflow logging failed: {}".format(e))
        return None


# =========================================================================
# Main benchmark execution
# =========================================================================

async def run_benchmark(args):
    """Main benchmark execution function."""
    phase = args.phase

    print("=" * 70)
    print("Benchmark - Phase {} - {}".format(phase, args.mode))
    print("=" * 70)
    print("[INFO] Phase: {}".format(phase))
    print("[INFO] Measurement type: {}".format(args.measurement_type))
    print("[INFO] Mode: {}".format(args.mode))
    print("[INFO] Backend: {}".format(args.backend))
    print("[INFO] Model: {}".format(args.model))
    print("[INFO] Prompt tokens: {}".format(args.prompt_tokens))
    print("[INFO] Max tokens: {}".format(args.max_tokens))
    print("[INFO] Warmup iterations: {}".format(args.warmup_iterations))
    print("[INFO] Measurement iterations: {}".format(args.num_iterations))
    print("[INFO] Concurrency: {}".format(args.concurrency))
    print("[INFO] Prefix caching: {}".format(args.prefix_cache))
    print("[INFO] URL: {}".format(args.url))
    print()

    # Generate prompt
    print(
        "[INFO] Generating prompt ({} tokens)...".format(args.prompt_tokens)
    )
    base_prompt = generate_prompt_by_tokens(args.prompt_tokens, args.model)
    print()

    # Run benchmark
    async with aiohttp.ClientSession() as session:
        # Warmup
        await run_warmup(
            session, args.url, args.model, args.warmup_iterations
        )

        # Measurement
        if args.concurrency > 1:
            print(
                "[CONCURRENT] Running benchmark with concurrency={}".format(
                    args.concurrency
                )
            )
            print()
            raw_results = await run_concurrent_benchmark(
                session=session,
                url=args.url,
                model=args.model,
                base_prompt=base_prompt,
                max_tokens=args.max_tokens,
                num_iterations=args.num_iterations,
                concurrency=args.concurrency,
                disable_prefix_caching=(args.prefix_cache == "disabled"),
                request_timeout=args.request_timeout,
            )
        else:
            print("[SERIAL] Running benchmark (concurrency=1)")
            print()
            raw_results = await run_serial_benchmark(
                session=session,
                url=args.url,
                model=args.model,
                base_prompt=base_prompt,
                max_tokens=args.max_tokens,
                num_iterations=args.num_iterations,
                disable_prefix_caching=(args.prefix_cache == "disabled"),
                request_timeout=args.request_timeout,
            )

    # Aggregate results
    if not raw_results:
        print("[ERROR] No successful results. Exiting.")
        return

    # [FIXED H-2] エラー率の確認と警告
    total_expected = args.num_iterations * (args.concurrency if args.concurrency > 1 else 1)
    successful_requests = len(raw_results)
    error_rate = (total_expected - successful_requests) / total_expected if total_expected > 0 else 0

    if error_rate > 0.1:
        print(f"[WARNING] High error rate detected: {error_rate * 100:.1f}% ({total_expected - successful_requests}/{total_expected} requests failed)")
        print("[WARNING] Throughput value may be overestimated due to missing failed requests")

    ttft_values = [r["ttft_ms"] for r in raw_results]
    tpot_values = [r["tpot_ms"] for r in raw_results]
    e2e_values = [r["e2e_latency_ms"] for r in raw_results]

    ttft_stats = compute_percentiles(ttft_values)
    tpot_stats = compute_percentiles(tpot_values)

    # [FIXED H-1] 二峰性分布の分析を追加
    ttft_bimodal = analyze_bimodality(ttft_values)

    # [FIXED MEDIUM-1] TPOT にも二峰性分析を追加
    tpot_bimodal = analyze_bimodality(tpot_values)

    # [FIXED CRITICAL-1] Proxy タイミングデータの集約
    proxy_prefill_times = [
        r["proxy_timing"]["prefill_time_ms"]
        for r in raw_results
        if "proxy_timing" in r and "prefill_time_ms" in r["proxy_timing"]
    ]
    proxy_kv_extract_times = [
        r["proxy_timing"]["kv_extract_time_ms"]
        for r in raw_results
        if "proxy_timing" in r and "kv_extract_time_ms" in r["proxy_timing"]
    ]

    # Throughput calculation
    # [FIXED P0-1, M-3] request_start タイムスタンプから直接計算（シリアル/並行共通）
    total_requests = len(raw_results)

    # シリアル/並行の両方で同じロジックを使用
    # 最初のリクエスト開始から最後のリクエスト完了までの実測 wall time
    first_start = min(r["request_start"] for r in raw_results)
    last_end = max(
        r["request_start"] + r["e2e_latency_ms"] / 1000 for r in raw_results
    )
    total_wall_time = last_end - first_start
    throughput_rps = (
        total_requests / total_wall_time if total_wall_time > 0 else 0
    )

    # Build output JSON
    output = {
        "metadata": {
            "phase": phase,
            "mode": args.mode,
            "backend": args.backend,
            "prefix_cache": args.prefix_cache == "enabled",
            "prompt_tokens": args.prompt_tokens,
            "max_tokens": args.max_tokens,
            "warmup_iterations": args.warmup_iterations,
            "measurement_iterations": args.num_iterations,
            "concurrency": args.concurrency,
            "measurement_type": "online",
            "measurement_method": "aiohttp",
            "timestamp": datetime.now().isoformat(),
            "model": args.model,
            "vllm_version": get_vllm_version(),
            "instance_type": get_instance_type(),
            "total_successful_requests": total_requests,
        },
        "results": {
            "ttft": ttft_stats,
            "ttft_bimodal": ttft_bimodal,  # [FIXED H-1] 二峰性分布の分析結果
            "tpot": tpot_stats,
            "tpot_bimodal": tpot_bimodal,  # [FIXED MEDIUM-1] TPOT の二峰性分布
            "e2e_latency": compute_percentiles(e2e_values),
            "throughput_rps": throughput_rps,
        },
    }

    # [FIXED CRITICAL-1] Proxy タイミングデータを results に追加
    if proxy_prefill_times:
        output["results"]["proxy_prefill_time"] = compute_percentiles(
            proxy_prefill_times
        )
    if proxy_kv_extract_times:
        output["results"]["proxy_kv_extract_time"] = compute_percentiles(
            proxy_kv_extract_times
        )

    # Add Layer/Priority metadata
    if hasattr(args, "layer") and args.layer:
        output["metadata"]["layer"] = args.layer
    if hasattr(args, "priority") and args.priority:
        output["metadata"]["priority"] = args.priority

    # Save JSON
    with open(args.output, "w") as f:
        json.dump(output, f, indent=2, default=str)
    print()
    print("[INFO] Results saved to {}".format(args.output))

    # MLflow logging
    run_id = log_to_mlflow(args, output, args.output)
    if run_id:
        output["metadata"]["mlflow_run_id"] = run_id
        with open(args.output, "w") as f:
            json.dump(output, f, indent=2, default=str)

    # Summary display
    print()
    print("=" * 70)
    print("SUMMARY")
    print("=" * 70)
    print("  Phase:           {}".format(phase))
    print("  Mode:            {}".format(args.mode))
    print("  Backend:         {}".format(args.backend))
    print("  Prefix Cache:    {}".format(args.prefix_cache))
    print("  Prompt tokens:   {}".format(args.prompt_tokens))
    print("  Concurrency:     {}".format(args.concurrency))
    print("  Warmup:          {}".format(args.warmup_iterations))
    print("  Measurement:     {}".format(args.num_iterations))
    print(
        "  Successful:      {}".format(
            output["metadata"]["total_successful_requests"]
        )
    )
    print()

    results = output["results"]
    ttft_stats = results["ttft"]
    tpot_stats = results["tpot"]

    print(
        "  TTFT (ms):  mean={:.2f}  P50={:.2f}  P95={:.2f}  "
        "P99={:.2f}  stdev={:.2f}".format(
            ttft_stats["mean"],
            ttft_stats["p50"],
            ttft_stats["p95"],
            ttft_stats["p99"],
            ttft_stats["stdev"],
        )
    )

    if tpot_stats["mean"] > 0:
        print(
            "  TPOT (ms):  mean={:.2f}  P50={:.2f}  P95={:.2f}  "
            "P99={:.2f}  stdev={:.2f}".format(
                tpot_stats["mean"],
                tpot_stats["p50"],
                tpot_stats["p95"],
                tpot_stats["p99"],
                tpot_stats["stdev"],
            )
        )

    if results["throughput_rps"] > 0:
        print("  Throughput: {:.2f} req/s".format(results["throughput_rps"]))
    print("=" * 70)


def main():
    parser = argparse.ArgumentParser(
        description="Unified Benchmark for Disaggregated Inference Experiments"
    )

    # Phase number
    parser.add_argument(
        "--phase",
        type=int,
        required=True,
        help="Phase number (e.g., 14, 15, 16)",
    )

    # Measurement type
    parser.add_argument(
        "--measurement-type",
        type=str,
        required=True,
        choices=["online"],
        help="Measurement type: online (HTTP API)",
    )

    # Online parameters
    parser.add_argument(
        "--url",
        type=str,
        required=True,
        help="vLLM endpoint URL",
    )

    # Model settings
    parser.add_argument(
        "--model",
        type=str,
        default="Qwen/Qwen2.5-7B-Instruct",
        help="Model name",
    )
    parser.add_argument(
        "--mode",
        type=str,
        default="unified",
        choices=["unified", "disaggregated"],
        help="Operation mode",
    )
    parser.add_argument(
        "--backend",
        type=str,
        default="none",
        choices=["none", "tcp", "efa"],
        help="Network backend",
    )

    # Benchmark settings
    parser.add_argument(
        "--prompt-tokens",
        type=int,
        default=4096,
        help="Prompt length in tokens",
    )
    parser.add_argument(
        "--max-tokens",
        type=int,
        default=100,
        help="Max generated tokens (default: 100, accurate TPOT measurement. Use --max-tokens 10 for Phase 14 compatibility)",
    )
    parser.add_argument(
        "--warmup-iterations",
        type=int,
        default=20,
        help="Warmup iterations (default: 20)",
    )
    parser.add_argument(
        "--num-iterations",
        type=int,
        default=30,
        help="Measurement iterations (default: 30)",
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=1,
        help="Concurrent requests (default: 1)",
    )
    parser.add_argument(
        "--request-timeout",
        type=int,
        default=600,
        help="Request timeout in seconds (default: 600)",
    )

    # Prefix Cache control
    parser.add_argument(
        "--prefix-cache",
        type=str,
        default="disabled",
        choices=["enabled", "disabled"],
        help="Prefix Cache state (for recording)",
    )

    # Output
    parser.add_argument(
        "--output",
        type=str,
        required=True,
        help="Output JSON file path",
    )

    # MLflow parameters
    parser.add_argument(
        "--mlflow-tracking-uri",
        type=str,
        default=None,
        help="MLflow tracking server URI",
    )
    parser.add_argument(
        "--mlflow-experiment-name",
        type=str,
        default=None,
        help="MLflow experiment name (default: nixl-efa-tai-phase-{N})",
    )
    parser.add_argument(
        "--mlflow-run-name",
        type=str,
        default=None,
        help="MLflow run name (auto-generated if not specified)",
    )
    parser.add_argument(
        "--tags",
        type=str,
        default=None,
        help="Additional tags (e.g., 'phase=15,tp_size=4')",
    )

    # Layer/Priority tags
    parser.add_argument(
        "--layer",
        type=str,
        default=None,
        help="Layer tag",
    )
    parser.add_argument(
        "--priority",
        type=str,
        default=None,
        help="Priority tag",
    )

    args = parser.parse_args()

    # Default MLflow experiment name
    if not args.mlflow_experiment_name:
        args.mlflow_experiment_name = "nixl-efa-tai-phase-{}".format(
            args.phase
        )

    asyncio.run(run_benchmark(args))


if __name__ == "__main__":
    main()
