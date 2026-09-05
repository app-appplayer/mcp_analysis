import 'package:mcp_bundle/ports.dart';

/// Retry policy for transient failures with exponential backoff.
class RetryPolicy {
  const RetryPolicy({
    this.maxRetries = 3,
    this.retryDelay = const Duration(seconds: 1),
    this.backoffMultiplier = 2.0,
  });
  final int maxRetries;
  final Duration retryDelay;
  final double backoffMultiplier;

  /// Execute an action with retry logic for transient errors.
  Future<T> withRetry<T>(Future<T> Function() action) async {
    var attempt = 0;
    var currentDelay = retryDelay;

    while (true) {
      try {
        return await action();
      } catch (e) {
        attempt++;
        if (!_isRetryable(e) || attempt > maxRetries) {
          if (attempt > maxRetries && _isRetryable(e)) {
            throw AnalysisError(
              code: 'job.retry_exhausted',
              message: 'All $maxRetries retries exhausted. Last error: $e',
              details: {'attempts': attempt, 'lastError': '$e'},
            );
          }
          rethrow;
        }
        await Future<void>.delayed(currentDelay);
        currentDelay = Duration(
          milliseconds:
              (currentDelay.inMilliseconds * backoffMultiplier).round(),
        );
      }
    }
  }

  /// Check if an error is retryable (transient).
  bool _isRetryable(Object error) {
    if (error is AnalysisError) {
      return error.code == 'source.unavailable' ||
          error.code == 'source.timeout';
    }
    return false;
  }
}
