import 'package:mcp_bundle/ports.dart';
import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:test/test.dart';

import '../../helpers/mocks.dart';

void main() {
  // ==========================================================================
  // JobManager Tests
  // ==========================================================================
  group('JobManager', () {
    late InMemoryStorage<AnalysisJob> storage;
    late JobManager manager;

    setUp(() {
      storage = InMemoryStorage<AnalysisJob>();
      manager = JobManager(storage: storage);
    });

    // TC-001: createJob returns job with unique non-empty jobId
    test('TC-001: createJob returns job with unique non-empty jobId', () async {
      final job = await manager.createJob(
        specId: 'spec-001',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );

      expect(job.jobId, isNotEmpty);
      expect(job.jobId, startsWith('job-'));
    });

    // TC-002: Created job has status = queued
    test('TC-002: created job has status queued', () async {
      final job = await manager.createJob(
        specId: 'spec-001',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );

      expect(job.status, equals(AnalysisJobStatus.queued));
    });

    // TC-003: Created job has progress = 0.0
    test('TC-003: created job has progress 0.0', () async {
      final job = await manager.createJob(
        specId: 'spec-001',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );

      expect(job.progress, equals(0.0));
    });

    // TC-004: Two consecutive jobs have different jobIds
    test('TC-004: two consecutive jobs have different jobIds', () async {
      final job1 = await manager.createJob(
        specId: 'spec-001',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );
      final job2 = await manager.createJob(
        specId: 'spec-002',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.adhoc,
      );

      expect(job1.jobId, isNot(equals(job2.jobId)));
    });

    // TC-005: Created job is persisted in storage
    test('TC-005: created job persisted in storage', () async {
      final job = await manager.createJob(
        specId: 'spec-001',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );

      final stored = await storage.get(job.jobId);
      expect(stored, isNotNull);
      expect(stored!.jobId, equals(job.jobId));
      expect(stored.specId, equals('spec-001'));
      expect(stored.specVersion, equals('1.0.0'));
      expect(stored.mode, equals(AnalysisExecutionMode.batch));
    });

    // TC-006: startJob transitions queued -> running
    test('TC-006: startJob transitions queued to running', () async {
      final job = await manager.createJob(
        specId: 'spec-001',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );
      expect(job.status, equals(AnalysisJobStatus.queued));

      final running = await manager.startJob(job.jobId);
      expect(running.status, equals(AnalysisJobStatus.running));
      expect(running.startTime, isNotNull);
    });

    // TC-007: completeJob transitions running -> completed with artifacts
    test('TC-007: completeJob transitions running to completed with artifacts',
        () async {
      final job = await manager.createJob(
        specId: 'spec-001',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );
      await manager.startJob(job.jobId);

      final completed = await manager.completeJob(
        job.jobId,
        artifactIds: ['artifact-1', 'artifact-2'],
      );

      expect(completed.status, equals(AnalysisJobStatus.completed));
      expect(completed.progress, equals(1.0));
      expect(completed.endTime, isNotNull);
      expect(completed.artifactIds, equals(['artifact-1', 'artifact-2']));
    });

    // TC-008: failJob transitions running -> failed with error recorded
    test('TC-008: failJob transitions running to failed with error recorded',
        () async {
      final job = await manager.createJob(
        specId: 'spec-001',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );
      await manager.startJob(job.jobId);

      final error = AnalysisError(
        code: 'test.error',
        message: 'Something went wrong',
        timestamp: DateTime.now(),
      );
      final failed = await manager.failJob(
        job.jobId,
        errors: [error],
      );

      expect(failed.status, equals(AnalysisJobStatus.failed));
      expect(failed.endTime, isNotNull);
      expect(failed.errors, hasLength(1));
      expect(failed.errors.first.code, equals('test.error'));
    });

    // TC-009: cancelJob transitions running -> canceled
    test('TC-009: cancelJob transitions running to canceled', () async {
      final job = await manager.createJob(
        specId: 'spec-001',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );
      await manager.startJob(job.jobId);

      final canceled = await manager.cancelJob(job.jobId);

      expect(canceled.status, equals(AnalysisJobStatus.canceled));
      expect(canceled.endTime, isNotNull);
      // cancelJob appends a job.canceled error automatically
      expect(
        canceled.errors.any((e) => e.code == 'job.canceled'),
        isTrue,
      );
    });

    // TC-010: cancelJob on completed job throws job.invalid_transition
    test('TC-010: cancelJob on completed job throws job.invalid_transition',
        () async {
      final job = await manager.createJob(
        specId: 'spec-001',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );
      await manager.startJob(job.jobId);
      await manager.completeJob(job.jobId);

      expect(
        () => manager.cancelJob(job.jobId),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'job.invalid_transition',
          ),
        ),
      );
    });

    // TC-011: cancelJob on failed job throws job.invalid_transition
    test('TC-011: cancelJob on failed job throws job.invalid_transition',
        () async {
      final job = await manager.createJob(
        specId: 'spec-001',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );
      await manager.startJob(job.jobId);
      await manager.failJob(job.jobId);

      expect(
        () => manager.cancelJob(job.jobId),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'job.invalid_transition',
          ),
        ),
      );
    });

    // TC-012: getJob returns stored job
    test('TC-012: getJob returns stored job', () async {
      final created = await manager.createJob(
        specId: 'spec-001',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );

      final fetched = await manager.getJob(created.jobId);
      expect(fetched, isNotNull);
      expect(fetched!.jobId, equals(created.jobId));
      expect(fetched.specId, equals('spec-001'));
    });

    // TC-013: getJob returns null for non-existent
    test('TC-013: getJob returns null for non-existent job', () async {
      final result = await manager.getJob('non-existent-job');
      expect(result, isNull);
    });

    // TC-014: updateProgress sets progress to 0.5
    test('TC-014: updateProgress sets progress to 0.5', () async {
      final job = await manager.createJob(
        specId: 'spec-001',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );
      await manager.startJob(job.jobId);

      await manager.updateProgress(job.jobId, 0.5);

      final updated = await manager.getJob(job.jobId);
      expect(updated, isNotNull);
      expect(updated!.progress, equals(0.5));
    });

    // TC-015 (spec): listJobs returns all stored Jobs
    test('TC-015: listJobs returns all stored jobs', () async {
      for (var i = 0; i < 3; i++) {
        await manager.createJob(
          specId: 'spec-$i',
          specVersion: '1.0.0',
          mode: AnalysisExecutionMode.batch,
        );
      }

      final jobs = await manager.listJobs();
      expect(jobs, hasLength(3));
    });

    // TC-016 (spec): addError appends error to running Job
    test('TC-016: addError appends error to running job', () async {
      final job = await manager.createJob(
        specId: 'spec-001',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );
      await manager.startJob(job.jobId);

      final error = AnalysisError(
        code: 'stream.error',
        message: 'test error',
      );
      await manager.addError(job.jobId, error);

      final updated = await manager.getJob(job.jobId);
      expect(updated, isNotNull);
      expect(updated!.errors, isNotEmpty);
      expect(updated.errors.any((e) => e.code == 'stream.error'), isTrue);
      expect(updated.status, equals(AnalysisJobStatus.running));
    });

    // TC-017 (spec): addError throws for non-existent Job
    test('TC-017: addError throws job.not_found for non-existent job',
        () async {
      final error = AnalysisError(
        code: 'stream.error',
        message: 'test error',
      );
      expect(
        () async => manager.addError('nonexistent', error),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'job.not_found',
          ),
        ),
      );
    });

    // TC-018 (spec): queued → canceled (valid)
    test('TC-018: cancelJob on queued job succeeds', () async {
      final job = await manager.createJob(
        specId: 'spec-001',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );
      expect(job.status, equals(AnalysisJobStatus.queued));

      final canceled = await manager.cancelJob(job.jobId);
      expect(canceled.status, equals(AnalysisJobStatus.canceled));
    });

    // TC-019 (spec): failJob with multiple errors stores all
    test('TC-019: failJob with errors list stores all errors', () async {
      final job = await manager.createJob(
        specId: 'spec-001',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );
      await manager.startJob(job.jobId);

      final errors = [
        AnalysisError(code: 'err.1', message: 'First'),
        AnalysisError(code: 'err.2', message: 'Second'),
        AnalysisError(code: 'err.3', message: 'Third'),
      ];
      final failed = await manager.failJob(job.jobId, errors: errors);

      expect(failed.status, equals(AnalysisJobStatus.failed));
      expect(failed.errors, hasLength(3));
      expect(failed.errors[0].code, 'err.1');
      expect(failed.errors[1].code, 'err.2');
      expect(failed.errors[2].code, 'err.3');
    });
  });

  // ==========================================================================
  // StepLogger Tests
  // ==========================================================================
  group('StepLogger', () {
    late StepLogger logger;

    setUp(() {
      logger = StepLogger();
    });

    // TC-001: logStep adds 1 log entry
    test('TC-001: logStep adds 1 log entry', () {
      expect(logger.logs, isEmpty);

      logger.logStep(
        step: 'source:factgraph',
        inputSize: 0,
        outputSize: 100,
        executionTime: const Duration(milliseconds: 50),
      );

      expect(logger.logs, hasLength(1));
    });

    // TC-002: Multiple logStep calls preserve order
    test('TC-002: multiple logStep calls preserve order', () {
      logger.logStep(
        step: 'step-1',
        inputSize: 0,
        outputSize: 10,
        executionTime: const Duration(milliseconds: 10),
      );
      logger.logStep(
        step: 'step-2',
        inputSize: 10,
        outputSize: 20,
        executionTime: const Duration(milliseconds: 20),
      );
      logger.logStep(
        step: 'step-3',
        inputSize: 20,
        outputSize: 30,
        executionTime: const Duration(milliseconds: 30),
      );

      expect(logger.logs, hasLength(3));
      expect(logger.logs[0].step, equals('step-1'));
      expect(logger.logs[1].step, equals('step-2'));
      expect(logger.logs[2].step, equals('step-3'));
    });

    // TC-003: Log entry includes step name
    test('TC-003: log entry includes step name', () {
      logger.logStep(
        step: 'transform:pipeline',
        inputSize: 100,
        outputSize: 80,
        executionTime: const Duration(milliseconds: 200),
      );

      final entry = logger.logs.first;
      expect(entry.step, equals('transform:pipeline'));
      expect(entry.inputSize, equals(100));
      expect(entry.outputSize, equals(80));
      expect(entry.executionTime, equals(const Duration(milliseconds: 200)));
      expect(entry.timestamp, isNotNull);
    });

    // TC-004: clear results in empty list
    test('TC-004: clear results in empty list', () {
      logger.logStep(
        step: 'step-1',
        inputSize: 0,
        outputSize: 10,
        executionTime: const Duration(milliseconds: 10),
      );
      logger.logStep(
        step: 'step-2',
        inputSize: 10,
        outputSize: 20,
        executionTime: const Duration(milliseconds: 20),
      );

      expect(logger.logs, hasLength(2));

      logger.clear();
      expect(logger.logs, isEmpty);
    });

    // TC-005: logs getter returns unmodifiable list
    test('TC-005: logs getter returns unmodifiable list', () {
      logger.logStep(
        step: 'step-1',
        inputSize: 0,
        outputSize: 10,
        executionTime: const Duration(milliseconds: 10),
      );

      final logs = logger.logs;
      expect(
        () => logs.add(AnalysisJobLog(
          step: 'injected',
          timestamp: DateTime.now(),
          inputSize: 0,
          outputSize: 0,
          executionTime: Duration.zero,
        )),
        throwsA(isA<UnsupportedError>()),
      );
    });

    // TC-006: logStep records correct inputSize and outputSize
    test('TC-006: logStep records correct inputSize and outputSize', () {
      logger.logStep(
        step: 'function:descriptive_stats',
        inputSize: 500,
        outputSize: 5,
        executionTime: const Duration(seconds: 1),
      );

      final entry = logger.logs.first;
      expect(entry.inputSize, equals(500));
      expect(entry.outputSize, equals(5));
    });

    // TC-007: logStep records execution time
    test('TC-007: logStep records execution time', () {
      logger.logStep(
        step: 'function:anomaly_detect',
        inputSize: 100,
        outputSize: 3,
        executionTime: const Duration(milliseconds: 1500),
      );

      final entry = logger.logs.first;
      expect(entry.executionTime.inMilliseconds, equals(1500));
    });

    // TC-008: logStep records timestamp
    test('TC-008: logStep records timestamp', () {
      final before = DateTime.now();
      logger.logStep(
        step: 'source:io',
        inputSize: 0,
        outputSize: 50,
        executionTime: const Duration(milliseconds: 100),
      );
      final after = DateTime.now();

      final entry = logger.logs.first;
      // Timestamp should be between before and after
      expect(
        entry.timestamp.isAfter(before) ||
            entry.timestamp.isAtSameMomentAs(before),
        isTrue,
      );
      expect(
        entry.timestamp.isBefore(after) ||
            entry.timestamp.isAtSameMomentAs(after),
        isTrue,
      );
    });
  });

  // ==========================================================================
  // Integration Tests
  // ==========================================================================
  group('Integration', () {
    late InMemoryStorage<AnalysisJob> storage;
    late JobManager manager;

    setUp(() {
      storage = InMemoryStorage<AnalysisJob>();
      manager = JobManager(storage: storage);
    });

    // IT-001: Full lifecycle: create -> start -> complete -> verified status
    test('IT-001: full lifecycle create -> start -> complete', () async {
      // Create
      final created = await manager.createJob(
        specId: 'lifecycle-spec',
        specVersion: '2.0.0',
        mode: AnalysisExecutionMode.adhoc,
        parameters: {'threshold': 0.8},
      );
      expect(created.status, equals(AnalysisJobStatus.queued));
      expect(created.progress, equals(0.0));
      expect(created.specId, equals('lifecycle-spec'));
      expect(created.specVersion, equals('2.0.0'));
      expect(created.mode, equals(AnalysisExecutionMode.adhoc));

      // Start
      final started = await manager.startJob(created.jobId);
      expect(started.status, equals(AnalysisJobStatus.running));
      expect(started.startTime, isNotNull);

      // Update progress
      await manager.updateProgress(created.jobId, 0.5);
      final midJob = await manager.getJob(created.jobId);
      expect(midJob!.progress, equals(0.5));

      // Complete
      final completed = await manager.completeJob(
        created.jobId,
        artifactIds: ['art-1'],
        logs: [
          AnalysisJobLog(
            step: 'source:factgraph',
            timestamp: DateTime.now(),
            inputSize: 0,
            outputSize: 100,
            executionTime: const Duration(milliseconds: 50),
          ),
        ],
      );
      expect(completed.status, equals(AnalysisJobStatus.completed));
      expect(completed.progress, equals(1.0));
      expect(completed.endTime, isNotNull);
      expect(completed.artifactIds, equals(['art-1']));
      expect(completed.logs, hasLength(1));

      // Verify persisted
      final final_ = await manager.getJob(created.jobId);
      expect(final_!.status, equals(AnalysisJobStatus.completed));

      // Verify listJobs includes the job
      final allJobs = await manager.listJobs();
      expect(allJobs, hasLength(1));
      expect(allJobs.first.jobId, equals(created.jobId));
    });

    // IT-002: Cancel with registered handler invokes handler
    test('IT-002: cancel with registered handler invokes handler', () async {
      final job = await manager.createJob(
        specId: 'cancel-spec',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.streaming,
      );
      await manager.startJob(job.jobId);

      var handlerInvoked = false;
      manager.registerCancelHandler(job.jobId, () {
        handlerInvoked = true;
      });

      final canceled = await manager.cancelJob(job.jobId);

      expect(handlerInvoked, isTrue);
      expect(canceled.status, equals(AnalysisJobStatus.canceled));
    });

    // IT-003: cancelJob on queued job (valid, queued is allowed)
    test('IT-003: cancelJob on queued job succeeds', () async {
      final job = await manager.createJob(
        specId: 'cancel-queued-spec',
        specVersion: '1.0.0',
        mode: AnalysisExecutionMode.batch,
      );
      expect(job.status, equals(AnalysisJobStatus.queued));

      final canceled = await manager.cancelJob(job.jobId);
      expect(canceled.status, equals(AnalysisJobStatus.canceled));
    });

    // IT-004: startJob on non-existent job throws job.not_found
    test('IT-004: startJob on non-existent job throws job.not_found', () async {
      expect(
        () => manager.startJob('ghost-job'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'job.not_found',
          ),
        ),
      );
    });

    // IT-005: completeJob on non-existent job throws job.not_found
    test('IT-005: completeJob on non-existent job throws job.not_found',
        () async {
      expect(
        () => manager.completeJob('ghost-job'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'job.not_found',
          ),
        ),
      );
    });

    // IT-006: failJob on non-existent job throws job.not_found
    test('IT-006: failJob on non-existent job throws job.not_found', () async {
      expect(
        () => manager.failJob('ghost-job'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'job.not_found',
          ),
        ),
      );
    });

    // IT-007: cancelJob on non-existent job throws job.not_found
    test('IT-007: cancelJob on non-existent job throws job.not_found',
        () async {
      expect(
        () => manager.cancelJob('ghost-job'),
        throwsA(
          isA<AnalysisError>().having(
            (e) => e.code,
            'code',
            'job.not_found',
          ),
        ),
      );
    });
  });
}
