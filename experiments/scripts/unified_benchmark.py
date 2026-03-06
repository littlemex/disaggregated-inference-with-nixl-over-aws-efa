#!/usr/bin/env python3
"""
統一ベンチマークスクリプト - すべてのレイヤーで同じ条件で測定

使用方法:
  python3 unified_benchmark.py \
    --pattern 12k-c1 \
    --url http://localhost:8000/v1/completions \
    --model "Qwen/Qwen2.5-32B-Instruct" \
    --input /tmp/benchmark_input_12k.txt \
    --output /home/ubuntu/result.json \
    --layer L2-EFA \
    --description "NIXL LIBFABRIC two-sided over EFA"

Note: このスクリプトは /v1/completions API (prompt 文字列) を使用します。
      /v1/chat/completions (messages 配列) ではありません。
"""
import argparse
import requests
import time
import json
import statistics
import hashlib
from pathlib import Path


def load_input_text(input_file):
    """入力テキストを読み込み、SHA256 を計算"""
    with open(input_file, 'r') as f:
        text = f.read()

    sha256_hash = hashlib.sha256(text.encode()).hexdigest()

    return text, sha256_hash


def run_benchmark(args):
    """統一ベンチマーク実行"""
    print("\n" + "="*60)
    print(f"Unified Benchmark: {args.pattern}")
    print("="*60)
    print(f"[INFO] Layer: {args.layer}")
    print(f"[INFO] URL: {args.url}")
    print(f"[INFO] Model: {args.model}")
    print(f"[INFO] Input: {args.input}")
    print()

    # Load input text
    input_text, input_sha256 = load_input_text(args.input)
    print(f"[INFO] Input text loaded")
    print(f"  Length: {len(input_text)} chars")
    print(f"  SHA256: {input_sha256}")
    print()

    # Warmup
    print(f"[INFO] Warmup ({args.warmup} requests)...")
    for i in range(args.warmup):
        try:
            requests.post(args.url, json={
                "model": args.model,
                "prompt": "warmup",
                "max_tokens": 10
            }, timeout=120)
            print(f"[INFO] Warmup {i+1}/{args.warmup} done")
        except Exception as e:
            print(f"[WARNING] Warmup {i+1} failed: {e}")
        time.sleep(2)

    print()

    # Measurement
    print(f"[INFO] Measurement (n={args.n})...")
    results = []

    for i in range(args.n):
        try:
            start_time = time.time()
            response = requests.post(args.url, json={
                "model": args.model,
                "prompt": input_text,
                "max_tokens": 50
            }, timeout=120)
            end_time = time.time()

            ttft_ms = int((end_time - start_time) * 1000)

            response_json = response.json()
            usage = response_json.get("usage", {})
            prompt_tokens = usage.get("prompt_tokens", 0)
            completion_tokens = usage.get("completion_tokens", 0)

            print(f"[INFO] Request {i+1}/{args.n}... TTFT={ttft_ms}ms, tokens={prompt_tokens}/{completion_tokens}")

            results.append({
                "request_num": i+1,
                "ttft_ms": ttft_ms,
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "timestamp": time.strftime("%Y-%m-%d %H:%M:%S")
            })

        except Exception as e:
            print(f"[ERROR] Request {i+1} failed: {e}")
            results.append({
                "request_num": i+1,
                "error": str(e),
                "timestamp": time.strftime("%Y-%m-%d %H:%M:%S")
            })

        time.sleep(1)

    # Statistics
    ttfts = [r["ttft_ms"] for r in results if "ttft_ms" in r]

    if not ttfts:
        print("\n[ERROR] No successful measurements")
        return None

    stats = {
        "n": len(ttfts),
        "ttft_ms": {
            "avg": statistics.mean(ttfts),
            "min": min(ttfts),
            "max": max(ttfts),
            "p50": statistics.median(ttfts),
            "p99": sorted(ttfts)[int(len(ttfts) * 0.99)] if len(ttfts) > 1 else ttfts[0],
            "stdev": statistics.stdev(ttfts) if len(ttfts) > 1 else 0
        }
    }

    # Print results
    print("\n" + "="*60)
    print(f"[RESULTS] {args.pattern}")
    print("="*60)
    for r in results:
        if "ttft_ms" in r:
            print(f"Request {r['request_num']}: TTFT={r['ttft_ms']}ms, tokens={r['prompt_tokens']}/{r['completion_tokens']}")
        else:
            print(f"Request {r['request_num']}: ERROR - {r.get('error', 'Unknown')}")

    print(f"\nStatistics:")
    print(f"  P50: {stats['ttft_ms']['p50']:.1f}ms")
    print(f"  P99: {stats['ttft_ms']['p99']:.1f}ms")
    print(f"  Avg: {stats['ttft_ms']['avg']:.2f}ms")
    print(f"  Stdev: {stats['ttft_ms']['stdev']:.2f}ms")
    print(f"  Min: {stats['ttft_ms']['min']}ms, Max: {stats['ttft_ms']['max']}ms")

    # Output
    output = {
        "benchmark": "Phase 3 Unified Benchmark",
        "layer": args.layer,
        "pattern": args.pattern,
        "description": args.description,
        "timestamp": time.strftime("%Y%m%d_%H%M%S"),
        "config": {
            "model": args.model,
            "url": args.url,
            "warmup": args.warmup,
            "n": args.n,
            "input_file": str(args.input),
            "input_sha256": input_sha256,
            "input_length": len(input_text)
        },
        "statistics": stats,
        "results": results
    }

    # Save
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with open(output_path, 'w') as f:
        json.dump(output, f, indent=2)

    print(f"\n[OK] Saved to {args.output}")

    return output


def main():
    parser = argparse.ArgumentParser(description="Unified benchmark script")
    parser.add_argument("--pattern", required=True, help="Benchmark pattern (e.g., 12k-c1)")
    parser.add_argument("--url", required=True, help="API endpoint URL")
    parser.add_argument("--model", required=True, help="Model name")
    parser.add_argument("--input", required=True, help="Input text file")
    parser.add_argument("--output", required=True, help="Output JSON file")
    parser.add_argument("--layer", required=True, help="Layer name (e.g., L2-EFA)")
    parser.add_argument("--description", default="", help="Layer description")
    parser.add_argument("--warmup", type=int, default=2, help="Warmup iterations (default: 2)")
    parser.add_argument("--n", type=int, default=10, help="Measurement iterations (default: 10)")

    args = parser.parse_args()

    run_benchmark(args)


if __name__ == "__main__":
    main()
