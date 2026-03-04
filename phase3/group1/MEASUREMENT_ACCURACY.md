# 測定精度と再現性の確立

## 概要

Phase 3 実験において、測定精度と再現性を確保するため、以下の問題を特定し、解決しました。

## 問題の特定

### 1. トークン圧縮問題（2026-03-04 発見）

**問題**: 従来の測定では `'a' * N` のような繰り返しテキストを入力として使用していました。

**影響**:
- 12K 目標: `'a' * 12288` → 実際 1,565 tokens（87% 圧縮）
- 32K 目標: `'a' * 32768` → 実際 4,125 tokens（87% 圧縮）

**原因**: Qwen tokenizer が繰り返しパターンを効率的に圧縮するため、実際のトークン数が大幅に減少。

### 2. 測定条件の不一致

**問題**: 各レイヤーの測定条件が統一されていませんでした。

**具体例**:
- Warmup 回数: 2 回 vs 5 回
- サンプル数: 10 回 vs 30 回
- 入力テキスト: 各レイヤーで異なる
- フレームワーク: aiohttp vs requests

**影響**: レイヤー間の公平な比較が困難。

## 解決策

### 1. 検証済みベンチマーク入力の生成

**方針**: 多様な語彙を持つ自然言語風テキストを生成し、トークン圧縮を回避。

**実装**:
```python
# Common words から多様な語彙を選択
COMMON_WORDS = ["the", "be", "to", "of", "and", "system", "computer", ...]

# Qwen tokenizer で実測: 1.0 tokens/word
# 句読点の影響: 約 7% 増加
# 補正係数: 0.93
target_words = int(target_tokens * 0.93)
```

**検証結果** (`/tmp/verify_token_count.py`):
- 12K 入力: 実際 12,210 tokens（目標 12,288、**-0.63%**）[OK]
- 32K 入力: 実際 32,570 tokens（目標 32,768、**-0.60%**）[OK]

**入力ファイル**:
- `benchmark_inputs/benchmark_input_12k.txt`
- `benchmark_inputs/benchmark_input_32k.txt`
- `benchmark_inputs/benchmark_inputs_metadata.json`
- `benchmark_inputs/token_verification_results.json`

### 2. 統一ベンチマークスクリプト

**スクリプト**: `/tmp/unified_benchmark.py`

**統一条件**:
- Warmup: 2 回（固定）
- Measurement: n=10（固定）
- 入力: 検証済みテキスト
- 記録項目: 実際の prompt_tokens を全リクエストで記録
- メタデータ: input_sha256, input_length, timestamp

**使用例**:
```bash
python3 unified_benchmark.py \
  --pattern 12k-c1 \
  --url http://localhost:8100/v1/chat/completions \
  --model "Qwen/Qwen2.5-32B-Instruct" \
  --input /tmp/benchmark_input_12k.txt \
  --output result.json \
  --layer L2-EFA \
  --description "NIXL LIBFABRIC two-sided over EFA"
```

## L2-EFA 再測定結果

### 12K-c1 パターン

**ファイル**: `p3-efa-verified-12k-c1.json`

**入力**:
- 実際の prompt_tokens: **12,239** tokens（目標 12,288、-0.40%）
- SHA256: `0f55d0c382178cc5...`

**TTFT 統計**:
- P50: **1395.0ms**
- P99: 3182.0ms
- Avg: 1573.70ms
- Stdev: 565.10ms
- Min: 1394ms, Max: 3182ms

**観測**: 最初のリクエスト（Request 1）が 3182ms と遅い。Warmup 後でも最初の実測定が遅延。

### 32K-c1 パターン

**ファイル**: `p3-efa-verified-32k-c1.json`

**入力**:
- 実際の prompt_tokens: **32,599** tokens（目標 32,768、-0.52%）
- SHA256: `35c13cf9233798c5...`

**TTFT 統計**:
- P50: **1530.5ms**
- P99: 6915.0ms
- Avg: 2069.40ms
- Stdev: 1702.57ms
- Min: 1530ms, Max: 6915ms

**観測**: 最初のリクエスト（Request 1）が 6915ms と非常に遅い。12K と同様のパターン。

## 重要な発見

### 1. 最初のリクエスト遅延

**現象**: Warmup 後でも、最初の測定リクエストが 2-4 倍 遅い。

**仮説**:
- Warmup のリクエストサイズが小さい（10 tokens）ため、実際の 12K/32K トークン処理パスが初期化されていない
- KV-Cache の初期アロケーションや NIXL バッファの準備に時間がかかる
- GPU メモリのページングや初期化

**対策候補**:
- Warmup で実際のサイズのリクエストを使用
- 最初のリクエストを統計から除外
- より多くの Warmup を実施

### 2. トークン数の精度

**達成**: ±5% 許容範囲内
- 12K: -0.63%
- 32K: -0.60%

**結論**: 自然言語風テキストで正確な測定が可能。

### 3. 測定の再現性

**条件統一**:
- [OK] 同一スクリプト (`unified_benchmark.py`)
- [OK] 同一入力（SHA256 記録）
- [OK] 同一 warmup/measurement 条件
- [OK] 実際の prompt_tokens 記録

## 次のステップ

### 1. すべてのレイヤーを再測定

**対象**:
- [完了] L2-EFA: 検証済み入力で再測定完了
- [TODO] L1-Unified: 統一スクリプトで再測定
- [TODO] L3-TCP: 統一スクリプトで再測定
- [TODO] L4-P2pNccl: 統一スクリプトで再測定（Phase 4?）

### 2. Warmup 戦略の改善

**検討事項**:
- 実際のサイズのリクエストで Warmup
- 最初のリクエストを除外した統計の追加
- Warmup 回数の増加

### 3. 測定精度のドキュメント化

**記録項目**:
- 実際の prompt_tokens（全リクエスト）
- 入力の SHA256
- 測定条件（warmup, n, timestamp）
- 環境情報（model, tensor_parallel_size, etc.）

## まとめ

測定精度と再現性の確立により、フェアな Layer 間比較が可能になりました。

**達成**:
- [OK] トークン圧縮問題の解決（±1% 以内の精度）
- [OK] 統一ベンチマークスクリプトの作成
- [OK] L2-EFA の再測定完了

**今後**:
- すべてのレイヤーを同じ条件で再測定
- Warmup 戦略の最適化
- 測定結果の比較分析

---

**作成日**: 2026-03-04
**最終更新**: 2026-03-04
**関連ファイル**:
- `/tmp/create_benchmark_inputs.py`
- `/tmp/verify_token_count.py`
- `/tmp/unified_benchmark.py`
- `benchmark_inputs/*.txt`
- `p3-efa-verified-*.json`
