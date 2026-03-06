#!/usr/bin/env python3
"""
圧縮されない入力テキストを生成し、tokenizer で検証
"""
import random
import hashlib
import json

# Qwen2 tokenizer をシミュレート（実際には vLLM の tokenizer を使う）
# ここでは簡易的に英単語ベースで見積もり
# 平均的な英単語 = 約 1.3 tokens

# 一般的な英単語リスト（圧縮されにくい）
COMMON_WORDS = [
    "the", "be", "to", "of", "and", "a", "in", "that", "have", "I",
    "it", "for", "not", "on", "with", "he", "as", "you", "do", "at",
    "this", "but", "his", "by", "from", "they", "we", "say", "her", "she",
    "or", "an", "will", "my", "one", "all", "would", "there", "their", "what",
    "so", "up", "out", "if", "about", "who", "get", "which", "go", "me",
    "when", "make", "can", "like", "time", "no", "just", "him", "know", "take",
    "people", "into", "year", "your", "good", "some", "could", "them", "see", "other",
    "than", "then", "now", "look", "only", "come", "its", "over", "think", "also",
    "back", "after", "use", "two", "how", "our", "work", "first", "well", "way",
    "even", "new", "want", "because", "any", "these", "give", "day", "most", "us",
    "system", "computer", "network", "data", "process", "information", "technology", "software",
    "hardware", "algorithm", "function", "variable", "method", "class", "object", "array",
    "string", "integer", "boolean", "file", "directory", "server", "client", "database",
    "query", "result", "output", "input", "error", "exception", "debug", "test",
]

def generate_natural_text(target_tokens, seed=42):
    """
    自然言語風のテキストを生成

    Args:
        target_tokens: 目標 token 数
        seed: 乱数シード（再現性のため）

    Returns:
        (text, estimated_tokens)
    """
    random.seed(seed)

    words = []
    estimated_tokens = 0

    # 英単語の平均 token 数: Qwen tokenizer で実測 1.0
    # 句読点の影響で約7%増加するため、補正係数 0.93 を適用
    target_words = int(target_tokens * 0.93)

    for i in range(target_words):
        word = random.choice(COMMON_WORDS)
        words.append(word)

        # 10-20 単語ごとに句読点
        if (i + 1) % random.randint(10, 20) == 0:
            words.append(random.choice(['.', ',', ';']))

    text = ' '.join(words)
    estimated_tokens = len(words)

    return text, estimated_tokens

def generate_lorem_ipsum(target_tokens):
    """
    Lorem ipsum 風のテキストを生成
    """
    lorem_base = """Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod
    tempor incididunt ut labore et dolore magna aliqua Ut enim ad minim veniam quis
    nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat
    Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore
    eu fugiat nulla pariatur Excepteur sint occaecat cupidatat non proident sunt
    in culpa qui officia deserunt mollit anim id est laborum"""

    # Lorem ipsum を繰り返して目標 token 数に近づける
    lorem_words = lorem_base.split()
    avg_tokens_per_word = 1.3

    target_words = int(target_tokens / avg_tokens_per_word)
    repetitions = (target_words // len(lorem_words)) + 1

    words = (lorem_words * repetitions)[:target_words]
    text = ' '.join(words)
    estimated_tokens = int(len(words) * avg_tokens_per_word)

    return text, estimated_tokens

def generate_inputs():
    """
    12K, 32K の入力を生成
    """
    inputs = {}

    # 12K tokens
    print("[INFO] Generating 12K tokens input...")
    text_12k, est_12k = generate_natural_text(12288, seed=42)
    text_hash_12k = hashlib.sha256(text_12k.encode()).hexdigest()[:16]

    inputs['12k'] = {
        'target_tokens': 12288,
        'text': text_12k,
        'estimated_tokens': est_12k,
        'text_length': len(text_12k),
        'word_count': len(text_12k.split()),
        'sha256_prefix': text_hash_12k,
        'generation_method': 'natural_text',
        'seed': 42
    }

    print(f"  Estimated tokens: {est_12k}")
    print(f"  Text length: {len(text_12k)} chars")
    print(f"  Word count: {len(text_12k.split())}")
    print(f"  SHA256 prefix: {text_hash_12k}")

    # 32K tokens
    print("\n[INFO] Generating 32K tokens input...")
    text_32k, est_32k = generate_natural_text(32768, seed=43)
    text_hash_32k = hashlib.sha256(text_32k.encode()).hexdigest()[:16]

    inputs['32k'] = {
        'target_tokens': 32768,
        'text': text_32k,
        'estimated_tokens': est_32k,
        'text_length': len(text_32k),
        'word_count': len(text_32k.split()),
        'sha256_prefix': text_hash_32k,
        'generation_method': 'natural_text',
        'seed': 43
    }

    print(f"  Estimated tokens: {est_32k}")
    print(f"  Text length: {len(text_32k)} chars")
    print(f"  Word count: {len(text_32k.split())}")
    print(f"  SHA256 prefix: {text_hash_32k}")

    # Save to files
    with open('/tmp/benchmark_input_12k.txt', 'w') as f:
        f.write(text_12k)

    with open('/tmp/benchmark_input_32k.txt', 'w') as f:
        f.write(text_32k)

    # Save metadata
    with open('/tmp/benchmark_inputs_metadata.json', 'w') as f:
        json.dump(inputs, f, indent=2)

    print("\n[OK] Input files saved:")
    print("  - /tmp/benchmark_input_12k.txt")
    print("  - /tmp/benchmark_input_32k.txt")
    print("  - /tmp/benchmark_inputs_metadata.json")

    return inputs

if __name__ == '__main__':
    print("="*60)
    print("ベンチマーク入力テキスト生成")
    print("="*60)
    print()

    inputs = generate_inputs()

    print("\n" + "="*60)
    print("次のステップ:")
    print("="*60)
    print("1. これらの入力を vLLM の tokenizer で検証")
    print("2. 実際の token 数が target の ±5% 以内か確認")
    print("3. OK なら統一ベンチマークスクリプトを作成")
