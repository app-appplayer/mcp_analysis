import 'package:mcp_bundle/ports.dart';

import '../feat/alert/alert_evaluator.dart';
import '../feat/alert/alert_publisher.dart';
import '../feat/datasource/datasource_registry.dart';
import '../feat/datasource/synthetic_source.dart';
import '../feat/datasource/upload_source.dart';
import '../feat/domain/domain_builtin.dart';
import '../feat/function/builtin/anomaly_detect.dart';
import '../feat/function/builtin/classification.dart';
import '../feat/function/builtin/correlation.dart';
import '../feat/function/builtin/descriptive_stats.dart';
import '../feat/function/builtin/dsp_advanced.dart';
import '../feat/function/builtin/dsp_events.dart';
import '../feat/function/builtin/dsp_filter.dart';
import '../feat/function/builtin/dsp_resample.dart';
import '../feat/function/builtin/dsp_spectrum.dart';
import '../feat/function/builtin/event_analysis.dart';
import '../feat/function/builtin/kalman.dart';
import '../feat/function/builtin/lockin.dart';
import '../feat/function/builtin/multivariate.dart';
import '../feat/function/builtin/seasonality.dart';
import '../feat/function/builtin/smoothing.dart';
import '../feat/function/builtin/stats_extended.dart';
import '../feat/function/builtin/time_series.dart';
import '../feat/function/builtin/timeseries_advanced.dart';
import '../feat/function/function_catalog.dart';
import '../feat/function/function_dispatcher.dart';
import '../feat/transform/transform_pipeline.dart';
import '../infra/governance/audit_logger.dart';
import '../infra/governance/rbac_policy.dart';
import 'artifact/artifact_builder.dart';
import 'artifact/artifact_store.dart';
import 'artifact/provenance_tracker.dart';
import 'execution/adhoc_executor.dart';
import 'execution/batch_executor.dart';
import 'execution/execution_engine.dart';
import 'execution/job_manager.dart';
import 'execution/stream_executor.dart';
import 'spec/parameter_resolver.dart';
import 'spec/spec_manager.dart';
import 'spec/spec_validator.dart';

/// The standard built-in function set — the package's own single source of
/// the catalog (statistics · DSP · timeseries · multivariate · domain
/// indicators). Hosts and recipes register from here; hand-copied lists
/// diverge.
List<AnalysisFunction> standardBuiltinFunctions() => <AnalysisFunction>[
      DescriptiveStatsFunction(),
      AnomalyDetectFunction(),
      EventAnalysisFunction(),
      TimeSeriesFunction(),
      CorrelationRegressionFunction(),
      RuleBasedClassificationFunction(),
      SeasonalityFunction(),
      FftFunction(),
      PsdWelchFunction(),
      DigitalFilterFunction(),
      PeakDetectFunction(),
      ZeroCrossingFunction(),
      ResampleFunction(),
      EnvelopeFunction(),
      AcfFunction(),
      CrossCorrelationFunction(),
      ChangepointCusumFunction(),
      HoltWintersFunction(),
      SmoothingFunction(),
      DifferencingFunction(),
      HistogramFunction(),
      CovarianceMatrixFunction(),
      RegressionFunction(),
      HypothesisTestFunction(),
      InterpolateFunction(),
      SpectrogramFunction(),
      CepstrumFunction(),
      HarmonicsFunction(),
      CrossPsdFunction(),
      PcaFunction(),
      LombScargleFunction(),
      KalmanFilterFunction(),
      LockinFunction(),
      VibrationIndicatorsFunction(),
      HrvMetricsFunction(),
      EegBandPowersFunction(),
    ];

/// Public API entry point. Implements AnalysisPort by delegating
/// to internal modules. Pure facade — no business logic.
class AnalysisPortAdapter implements AnalysisPort {
  AnalysisPortAdapter({
    required SpecManager specManager,
    required ExecutionEngine executionEngine,
    required ArtifactStore artifactStore,
    required DataSourceRegistry dataSourceRegistry,
    required AlertEvaluator alertEvaluator,
    FunctionCatalog? functionCatalog,
    JobManager? jobManager,
  })  : _functionCatalog = functionCatalog,
        _jobManager = jobManager,
        _specManager = specManager,
        _executionEngine = executionEngine,
        _artifactStore = artifactStore,
        _dataSourceRegistry = dataSourceRegistry,
        _alertEvaluator = alertEvaluator;

  /// Standard one-line construction of the full in-memory engine — the
  /// production builder hosts adopt directly (spec / batch·adhoc·stream
  /// execution / artifact / audit / RBAC), with [standardBuiltinFunctions]
  /// registered and the `synthetic` simulation data source wired. In-memory
  /// storage suits session-scoped engines; a persistent host swaps storage
  /// via the main constructor. [eventPort] / [metricPort] wire alert
  /// delivery / telemetry (default no-op). Extra data sources (io / api /
  /// upload / factgraph) and custom functions can be registered on the
  /// returned adapter via [dataSourceRegistry] and [extraFunctions].
  factory AnalysisPortAdapter.inMemory({
    EventPort? eventPort,
    MetricPort? metricPort,
    List<AnalysisFunction> extraFunctions = const [],
  }) {
    final catalog = FunctionCatalog();
    final specManager = SpecManager(
      storage: _InMemoryStorage<AnalysisSpec>(),
      validator: SpecValidator(),
      parameterResolver: ParameterResolver(),
      // Read through the catalog rather than a snapshot: functions
      // registered after construction are checkable too.
      declaredResultFields: () => {
        for (final info in catalog.getAll())
          info.functionName: info.results.keys.toSet(),
      },
      versionStorage: _InMemoryStorage<AnalysisSpec>(),
    );
    final jobManager = JobManager(storage: _InMemoryStorage<AnalysisJob>());
    final artifactStore =
        ArtifactStore(storage: _InMemoryStorage<AnalysisArtifact>());
    // Both adapters that need nothing from the host. `io` needs a stream
    // port, `external` an HTTP client and `factgraph` a facts port, so
    // those stay the host's to register through [dataSourceRegistry].
    final dataSourceRegistry = DataSourceRegistry()
      ..register(AnalysisSourceType.synthetic, SyntheticSourceAdapter())
      ..register(AnalysisSourceType.upload, UploadSourceAdapter());

    final functionDispatcher = FunctionDispatcher(catalog: catalog);
    for (final fn in [...standardBuiltinFunctions(), ...extraFunctions]) {
      catalog.register(fn.info);
      functionDispatcher.registerImplementation(fn.info.functionName, fn);
    }

    final alertEvaluator = AlertEvaluator(
      publisher: AlertPublisher(eventPort: eventPort ?? _NoopEventPort()),
    );
    final transformPipeline = TransformPipeline();
    final artifactBuilder = ArtifactBuilder();
    final provenanceTracker = ProvenanceTracker();

    final batchExecutor = BatchExecutor(
      jobManager: jobManager,
      dataSourceRegistry: dataSourceRegistry,
      transformPipeline: transformPipeline,
      functionDispatcher: functionDispatcher,
      artifactBuilder: artifactBuilder,
      artifactStore: artifactStore,
      provenanceTracker: provenanceTracker,
      alertEvaluator: alertEvaluator,
    );
    final adhocExecutor = AdhocExecutor(
      jobManager: jobManager,
      dataSourceRegistry: dataSourceRegistry,
      transformPipeline: transformPipeline,
      functionDispatcher: functionDispatcher,
      artifactBuilder: artifactBuilder,
      artifactStore: artifactStore,
      provenanceTracker: provenanceTracker,
      alertEvaluator: alertEvaluator,
    );
    final streamExecutor = StreamExecutor(
      jobManager: jobManager,
      dataSourceRegistry: dataSourceRegistry,
      transformPipeline: transformPipeline,
      artifactBuilder: artifactBuilder,
      artifactStore: artifactStore,
      provenanceTracker: provenanceTracker,
      alertEvaluator: alertEvaluator,
    );

    final executionEngine = ExecutionEngine(
      specManager: specManager,
      jobManager: jobManager,
      batchExecutor: batchExecutor,
      adhocExecutor: adhocExecutor,
      streamExecutor: streamExecutor,
      rbac: RbacPolicy(),
      auditLogger: AuditLogger(storage: _InMemoryStorage<AuditRecord>()),
      metricPort: metricPort ?? _NoopMetricPort(),
    );

    return AnalysisPortAdapter(
      specManager: specManager,
      executionEngine: executionEngine,
      artifactStore: artifactStore,
      dataSourceRegistry: dataSourceRegistry,
      alertEvaluator: alertEvaluator,
      functionCatalog: catalog,
      jobManager: jobManager,
    );
  }
  final SpecManager _specManager;
  final ExecutionEngine _executionEngine;
  final ArtifactStore _artifactStore;
  final DataSourceRegistry _dataSourceRegistry;
  final AlertEvaluator _alertEvaluator;

  /// Catalog behind [listFunctions]. Absent when a host assembles the
  /// adapter without one; the port then reports an empty catalog rather
  /// than pretending the engine has no functions.
  final FunctionCatalog? _functionCatalog;

  /// Job store behind [listJobs].
  final JobManager? _jobManager;

  /// The port's own translation of an actor into the governance context
  /// the engine has always accepted. Callers had no way to supply one, so
  /// role checks never evaluated and every audit record read `system`.
  static RbacContext? _context(AnalysisActor? actor) => actor == null
      ? null
      : RbacContext(
          actorId: actor.id,
          role: actor.role,
          groups: actor.groups,
        );

  /// The engine's data source registry — register additional adapters
  /// (io / api / upload / factgraph) on an [AnalysisPortAdapter.inMemory]
  /// engine.
  DataSourceRegistry get dataSourceRegistry => _dataSourceRegistry;

  /// Retrieve a single Spec by ID.
  Future<AnalysisSpec?> getSpec(String specId) async {
    return _specManager.getSpec(specId);
  }

  /// Retrieve the exact version an artifact's provenance names.
  Future<AnalysisSpec?> getSpecVersion(String specId, String version) {
    return _specManager.getSpecVersion(specId, version);
  }

  /// Versions of [specId] that can still be retrieved.
  Future<List<String>> listSpecVersions(String specId) {
    return _specManager.listSpecVersions(specId);
  }

  @override
  Future<List<AnalysisSpec>> listSpecs({
    String? search,
    int? limit,
    int? offset,
    AnalysisActor? actor,
  }) {
    return _specManager.listSpecs(
      search: search,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<AnalysisSpec> createSpec(AnalysisSpec spec, {AnalysisActor? actor}) {
    return _specManager.createSpec(spec);
  }

  @override
  Future<AnalysisSpec> updateSpec(
    String specId,
    AnalysisSpec spec, {
    AnalysisActor? actor,
  }) {
    return _specManager.updateSpec(specId, spec);
  }

  @override
  Future<void> deleteSpec(String specId, {AnalysisActor? actor}) {
    return _specManager.deleteSpec(specId);
  }

  @override
  Future<List<AnalysisFunctionInfo>> listFunctions({
    String? search,
    AnalysisActor? actor,
  }) async {
    final catalog = _functionCatalog;
    if (catalog == null) return const [];
    if (search == null || search.isEmpty) return catalog.getAll();
    final query = search.toLowerCase();
    return catalog
        .getAll()
        .where((f) =>
            f.functionName.toLowerCase().contains(query) ||
            f.description.toLowerCase().contains(query))
        .toList();
  }

  @override
  Future<AnalysisJob> runAnalysis({
    required String specId,
    required Map<String, dynamic> parameters,
    AnalysisExecutionMode mode = AnalysisExecutionMode.batch,
    AnalysisTimeRange? timeRange,
    AnalysisActor? actor,
  }) {
    return _executionEngine.runAnalysis(
      specId: specId,
      parameters: parameters,
      mode: mode,
      timeRange: timeRange,
      rbacContext: _context(actor),
    );
  }

  @override
  Future<AnalysisJob?> getJob(String jobId, {AnalysisActor? actor}) {
    return _executionEngine.getJob(jobId);
  }

  @override
  Future<List<AnalysisJob>> listJobs({
    String? specId,
    AnalysisJobStatus? status,
    int? limit,
    AnalysisActor? actor,
  }) async {
    final manager = _jobManager;
    if (manager == null) return const [];
    var jobs = await manager.listJobs();
    jobs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (specId != null) {
      jobs = jobs.where((j) => j.specId == specId).toList();
    }
    if (status != null) {
      jobs = jobs.where((j) => j.status == status).toList();
    }
    if (limit != null && limit > 0 && limit < jobs.length) {
      jobs = jobs.sublist(0, limit);
    }
    return jobs;
  }

  @override
  Future<List<AnalysisArtifact>> getArtifacts({
    String? jobId,
    String? specId,
    AnalysisArtifactType? type,
    List<String>? tags,
    AnalysisTimeRange? timeRange,
    int? limit,
    AnalysisActor? actor,
  }) {
    return _artifactStore.query(
      jobId: jobId,
      specId: specId,
      type: type,
      tags: tags,
      timeRange: timeRange,
      limit: limit,
    );
  }

  @override
  Future<AnalysisJob> cancelJob(String jobId, {AnalysisActor? actor}) async {
    return _executionEngine.cancelJob(jobId, rbacContext: _context(actor));
  }

  @override
  Future<AnalysisAlert> evaluateAlert(
    String alertRuleId, {
    AnalysisActor? actor,
  }) async {
    // 1. Lookup the AlertRule artifact by ID
    final artifact = await _artifactStore.get(alertRuleId);
    if (artifact == null || artifact is! AnalysisAlertRuleArtifact) {
      throw AnalysisError(
        code: 'artifact.not_found',
        message: 'Alert rule artifact "$alertRuleId" not found',
        details: {'alertRuleId': alertRuleId},
      );
    }

    final rule = artifact;

    // 2. Resolve the original Spec from provenance
    final specId = rule.provenance.specId;
    final spec = await _specManager.getSpec(specId);

    if (spec == null) {
      throw AnalysisError(
        code: 'spec.not_found',
        message: 'Spec "$specId" for alert rule not found',
        details: {'specId': specId, 'alertRuleId': alertRuleId},
      );
    }

    // 3. Query current data from original sources
    AnalysisDataSet? currentData;
    for (final source in spec.inputSources) {
      try {
        currentData = await _dataSourceRegistry.queryData(
          sourceType: source.sourceType,
          query: source.query ?? '',
          filter: source.filter,
          timeRange: source.timeRange,
        );
        break;
      } catch (_) {
        // Try next source
      }
    }

    if (currentData == null) {
      throw AnalysisError(
        code: 'source.unavailable',
        message: 'Could not query data for alert evaluation',
        details: {'alertRuleId': alertRuleId, 'specId': specId},
      );
    }

    // 4. Delegate to AlertEvaluator
    return _alertEvaluator.evaluate(rule, currentData);
  }
}

/// Trivial in-memory [StoragePort] backing [AnalysisPortAdapter.inMemory].
class _InMemoryStorage<T> implements StoragePort<T> {
  final Map<String, T> _store = <String, T>{};

  @override
  Future<void> save(String id, T item) async => _store[id] = item;

  @override
  Future<T?> get(String id) async => _store[id];

  @override
  Future<void> delete(String id) async => _store.remove(id);

  @override
  Future<List<T>> getAll() async => _store.values.toList();

  @override
  Future<List<T>> query(Map<String, dynamic> criteria) async =>
      _store.values.toList();

  @override
  Future<bool> exists(String id) async => _store.containsKey(id);
}

class _NoopEventPort implements EventPort {
  @override
  Future<void> publish(PortEvent event) async {}

  @override
  Stream<PortEvent> subscribe(String eventType) =>
      const Stream<PortEvent>.empty();

  @override
  Stream<PortEvent> subscribeAll() => const Stream<PortEvent>.empty();

  @override
  Future<void> unsubscribe(String eventType) async {}
}

class _NoopMetricPort implements MetricPort {
  @override
  Future<MetricValue> compute(
          String metricName, Map<String, dynamic> context) async =>
      MetricValue(value: 0.0, timestamp: DateTime.now());

  @override
  Future<void> record(String metricName, double value,
      {Map<String, String>? tags}) async {}

  @override
  Stream<MetricEvent> watch(String metricName) =>
      const Stream<MetricEvent>.empty();

  @override
  Future<List<MetricValue>> history(String metricName,
          {DateTime? start, DateTime? end, int? limit}) async =>
      <MetricValue>[];
}
