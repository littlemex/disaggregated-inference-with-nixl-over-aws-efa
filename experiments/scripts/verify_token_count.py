#!/usr/bin/env python3
"""
vLLM の tokenizer で実際の token 数を検証
"""
import sys
import json

try:
    from transformers import AutoTokenizer
except ImportError:
    print("[ERROR] transformers not found. Install with: pip install transformers")
    sys.exit(1)

def verify_token_count(text_file, target_tokens):
    """
    テキストファイルの実際の token 数を検証

    Args:
        text_file: 入力テキストファイル
        target_tokens: 目標 token 数

    Returns:
        actual_tokens: 実際の token 数
    """
    # Load tokenizer (Qwen2.5)
    print(f"[INFO] Loading tokenizer: Qwen/Qwen2.5-32B-Instruct...")
    tokenizer = AutoTokenizer.from_pretrained("Qwen/Qwen2.5-32B-Instruct")

    # Read text
    with open(text_file, 'r') as f:
        text = f.read()

    # Tokenize
    print(f"[INFO] Tokenizing {text_file}...")
    tokens = tokenizer.encode(text)
    actual_tokens = len(tokens)

    # Calculate difference
    diff = actual_tokens - target_tokens
    diff_pct = (diff / target_tokens) * 100

    print(f"\n[RESULTS] {text_file}")
    print(f"  Target tokens: {target_tokens:,}")
    print(f"  Actual tokens: {actual_tokens:,}")
    print(f"  Difference: {diff:+,} ({diff_pct:+.2f}%)")

    if abs(diff_pct) <= 5:
        print(f"  Status: [OK] Within ±5% tolerance")
        return True, actual_tokens
    else:
        print(f"  Status: [FAIL] Outside ±5% tolerance")
        return False, actual_tokens

def main():
    print("="*60)
    print("Token Count Verification")
    print("="*60)
    print()

    results = {}

    # Verify 12K
    ok_12k, actual_12k = verify_token_count('/tmp/benchmark_input_12k.txt', 12288)
    results['12k'] = {
        'target': 12288,
        'actual': actual_12k,
        'valid': ok_12k
    }

    print()

    # Verify 32K
    ok_32k, actual_32k = verify_token_count('/tmp/benchmark_input_32k.txt', 32768)
    results['32k'] = {
        'target': 32768,
        'actual': actual_32k,
        'valid': ok_32k
    }

    # Save results
    with open('/tmp/token_verification_results.json', 'w') as f:
        json.dump(results, f, indent=2)

    print("\n" + "="*60)
    if ok_12k and ok_32k:
        print("[OK] All inputs are valid!")
        print("Next: Create unified benchmark script")
    else:
        print("[FAIL] Some inputs need adjustment")
        print("Next: Regenerate inputs with adjusted parameters")
    print("="*60)

if __name__ == '__main__':
    main()
