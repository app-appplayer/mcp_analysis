## 0.2.0 - 2026-09-01

### Added
- Steps compose: `AnalysisStep.input` names an earlier step and the result
  field to read, and the executor builds that step's dataset from it.
- `AnalysisStep.transforms` — transforms applied to one step's data, after
  its input is resolved and before its function runs.
- Outputs select a result field: `AnalysisOutputDef.field` and
  `indexField`. Charts and series carry the named values; a chart's axes
  are labelled by the fields they come from.
- All 35 built-in functions with fixed result keys declare them in
  `AnalysisFunctionInfo.results`. `descriptive_stats` keys its results by
  column name and declares none.
- `AnalysisInputSource.columnAliases` and `merge` (`append` | `join`).
  `SourceMerger` replaces the private merge in batch and ad-hoc execution.
  Joining two sources that share a column name raises
  `source.column_collision`.
- `KvBackedStorage` — a `StoragePort` over the host's `KvStoragePort`.
- `SpecManager.getSpecVersion`, `listSpecVersions` and an optional
  `versionStorage`; `AnalysisPortAdapter` exposes both.
- `DataSourceRegistry.hasAdapter` and `registeredTypes`.
- The standard builder registers `upload` alongside `synthetic`.

### Changed
- Implements the widened `AnalysisPort` (mcp_bundle 0.4.10): every method
  takes an optional `AnalysisActor`, which becomes the engine's
  `RbacContext`; `listJobs`, `cancelJob`, `deleteSpec` and `listFunctions`
  join the port. `cancelJob` moves onto the port from the adapter.
- **`createSpec` rejects spec shapes that 0.1.4 accepted.** Each produced
  an artifact built from nothing:
  `spec.invalid.duplicate_step_key`, `spec.invalid.unresolved_output_source`,
  `spec.invalid.unknown_result_field`, `spec.invalid.unresolved_step_input`,
  `spec.invalid.step_input_order`. An output may also read the keys a
  streaming job emits from its window — `windowState`, `pointCount`,
  `lateDropped`, `overflowDropped` (`SpecValidator.engineSuppliedResultKeys`)
  — which no step produces.
- A chart built with no named field labels its axes `index` and `value`.
- `analysis_options.yaml` added; the package is `dart analyze` and
  `dart format` clean.
- `mcp_bundle` floor raised to `^0.4.10` for the analysis contract this
  release uses. Dev floors: `lints ^6.1.0`, `mockito ^5.8.1`,
  `test ^1.31.2`.

### Fixed
- `getArtifacts(jobId:)` and `getArtifacts(tags:)` filter. Artifacts record
  `provenance.jobId`, and the store applies every filter itself rather than
  passing it to the storage as criteria.
- An output bound to a step carries that step's results; a metric no longer
  reports `0.0` for an unresolved binding.
- An output bound to a result field the run did not produce yields no
  artifact and records `artifact.unproduced_field` on the job. A
  conditional field — `criticalValue` for one test but not another,
  `bandPowers` only when bands were requested — is declared by the function
  and so passes validation; building the artifact anyway reported `0.0`
  for a number nobody computed.
- Two steps calling one function keep both results, keyed by
  `AnalysisStep.resultKey`.
- Chart artifacts carry their series.
- Alert artifacts take their severity from the function's result or the
  output's `parameters`.
- Uploaded JSON is parsed with `dart:convert`: escape sequences, unicode,
  nested values and numeric formats are preserved, malformed input raises
  `source.schema_mismatch`, and parsing always terminates.
- Uploaded CSV is read per RFC 4180: quoted fields may hold the delimiter,
  a newline or a doubled quote; CRLF is handled; a column is typed by its
  first present value.
- API source errors carry the scheme, host and path, the method, and the
  names of headers and query parameters — not the source configuration, the
  query string or any userinfo.
- A series or chart indexed by a numeric field keeps its points distinct:
  the index range is normalized onto the point axis rather than scaled by a
  fixed multiplier, which merged values less than 0.001 apart.
- Batch and ad-hoc failures record the cause of the error they wrap.

## 0.1.4 - 2026-07-14 - Standard in-memory builder

### Added
- `AnalysisPortAdapter.inMemory()` — one-line production engine builder
  (full catalog + `synthetic` source), closing the standard-builder gap the
  other capability packages already meet.
- `standardBuiltinFunctions()` — single source of the built-in catalog.
- `dataSourceRegistry` getter for post-construction adapter registration.

### Fixed
- Summary artifacts now carry the full function-results map as JSON when no
  'text' key is present — rich results (fft, lockin, ...) were unreachable
  through the port artifact surface.

## 0.1.3 - 2026-07-14 - Filter completion, lock-in, model simulation

### Added
- `digital_filter`: notch, Butterworth order cascade (2..8), median — filter
  family completion.
- `lockin` — software lock-in amplifier (synchronous demodulation) for weak
  tone amplitude/phase extraction (36 built-in functions).
- Synthetic source model kinds `state_space` / `transfer_function` / `rlc`
  (RK4, ZOH input) and Monte Carlo `ensemble` percentile bands — in-core
  linear system simulation and simulation-based prediction.

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
