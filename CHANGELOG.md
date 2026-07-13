## 0.1.2 - 2026-07-14 - Standard function catalog + streaming semantics + performance

### Added
- 28 new built-in functions (7 → 35): DSP (fft w/ phase, psd_welch + band
  powers, spectrogram, cepstrum, harmonics/THD, cross_psd/coherence/FRF,
  digital_filter, peak_detect, zero_crossing, resample, envelope), timeseries
  (acf auto-period, cross_correlation, changepoint_cusum, holt_winters,
  kalman_filter, smoothing w/ Savitzky-Golay derivatives, differencing),
  statistics (histogram, covariance_matrix, regression, hypothesis_test,
  pca, lomb_scargle, interpolate), and a built-in domain layer
  (vibration_indicators w/ ISO 10816 zones, hrv_metrics, eeg_band_powers).
- `SyntheticSourceAdapter` (`AnalysisSourceType.synthetic`) — seeded
  signal/Monte-Carlo generator registered as a data source.
- Streaming semantics: `WindowKind.tumbling`, `maxPoints` bounded buffer,
  watermark late-drop, `ReorderBuffer` (`allowedLateness`), drop counters in
  emitted artifacts.
- `descriptive_stats` skewness/kurtosis; `anomaly_detect` `mad` method.
- Bench harness (`bench/`) with recorded baselines and targets.

### Changed
- `WindowAggregator` is incremental (Kahan running sums + monotonic deques):
  add amortized O(1), aggregate O(1) — ~9000x faster at 100K occupancy.
- Floors `mcp_bundle ^0.4.8` (`AnalysisSourceType.synthetic`).

## [0.1.1] - 2026-05-23 - mcp_bundle 0.4.0 cascade

### Changed (cascade)
- `mcp_bundle` caret bumped from `^0.3.0` to `^0.4.0`. mcp_analysis does not touch `UiSection.pages` directly, so this release is a caret-only cascade. Consumers should bump to `^0.1.1`.

## [0.1.0] - 2026-04-28 - Initial Release

### Added
- Spec subsystem — validator, parameter resolver, spec manager.
- Artifact subsystem — builder, store, provenance tracker.
- Execution subsystem — execution engine, batch / ad-hoc / stream executors, job manager, retry policy, step logger.
- DataSource subsystem with pluggable adapters for multi-source integration.
- Pluggable analysis functions and transforms.
- Alert evaluation.
- MCP integration via tools.
- Standard port adapter implementing `mcp_bundle` analysis Contract Layer.
