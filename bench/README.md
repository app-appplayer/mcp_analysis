# mcp_analysis bench

`dart run bench/analysis_bench.dart` — batch throughput (rows/s), streaming
window hot path (per-point add, per-emit aggregate p50/p95), RSS delta.
Deterministic seeds; a meter, not a test.

## Recorded runs (macOS arm64, Dart 3.11.3)

### Baseline — 2026-07-13, pre-incremental (full-rescan WindowAggregator)

| scenario | metric | value |
|---|---|---|
| stats 10K / 100K / 1M | rows/s | 4.73M / 4.43M / 3.02M |
| anomaly zscore 100K | rows/s | 16.58M |
| correlation 100K | rows/s | 34.81M |
| transform filter 1M | rows/s | 37.39M |
| window occ=300 | add pts/s · emit p95 | 403.1K · 0.03ms |
| window occ=10K | add pts/s · emit p95 | 16.1K · 0.45ms |
| **window occ=100K** | **add pts/s · emit p95** | **781 · 17.46ms** |
| memory | 1M rows RSS Δ | 396MB |

Reading: batch tier healthy; the O(n)-rescan window collapsed with occupancy
(cannot sustain a 1 kHz stream at 100K occupancy).

### After incremental rewrite — 2026-07-13 (Kahan running sums + monotonic deques)

| scenario | add pts/s | emit p95 | vs baseline |
|---|---|---|---|
| window occ=300 | 3.65M | ~0ms | ×9 |
| window occ=10K | 8.70M | ~0ms | ×540 |
| **window occ=100K** | **7.00M** | **~0ms** | **×~9000** |

Occupancy-independent (flat) — O(1) amortized add / O(1) aggregate confirmed.
Equivalence + drift pinned by `test/feat/alert/window_aggregator_incremental_test.dart`.

## Working targets (PC tier)

- window add ≥ 1M pts/s at any occupancy ≤ 1M (met)
- emit aggregate p95 ≤ 0.1ms (met)
- batch stats ≥ 2M rows/s at 1M rows (met)
- memory: dataset dominates (~400B/row row-major) — columnar layout is a
  future lever, out of scope for the current roadmap.
