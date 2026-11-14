import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'flash_debug_types.dart';

const int flashDebugProtocolVersion = 1;

class FlashDebugLogger {
  FlashDebugLogger(this.options)
      : _client = options.httpClient ?? http.Client(),
        _ownsClient = options.httpClient == null,
        _baseUrl = _normalizeBaseUrl(options.baseUrl),
        _bootId = _createBootId();

  final FlashDebugOptions options;
  final http.Client _client;
  final bool _ownsClient;
  final String _baseUrl;
  final String _bootId;
  final List<DebugLogRecord> _queue = <DebugLogRecord>[];

  Timer? _flushTimer;
  Future<void>? _flushFuture;
  int _sequence = 0;
  int _droppedCount = 0;
  bool _closed = false;

  int get droppedCount => _droppedCount;
  int get queuedCount => _queue.length;
  bool get isClosed => _closed;

  void log({
    required String message,
    String level = 'info',
    String type = 'log',
    String? content,
    String? contentFormat,
    String? tag,
    DebugLogAttributes? attributes,
    DebugLogAttributes? metadata,
  }) {
    _ensureOpen();
    final record = DebugLogRecord(
      id: '$_bootId-${_sequence++}',
      timestamp: DateTime.now().toUtc(),
      level: level,
      type: type,
      source: options.source,
      message: message,
      content: content,
      contentFormat: contentFormat,
      tag: tag,
      clientId: options.clientId,
      deviceId: options.deviceId,
      sessionId: options.sessionId,
      attributes: attributes,
      metadata: metadata,
    );
    _enqueue(_redact(record));
  }

  void debug(
    String message, {
    String type = 'log',
    String? content,
    String? contentFormat,
    String? tag,
    DebugLogAttributes? attributes,
    DebugLogAttributes? metadata,
  }) {
    log(
      message: message,
      level: 'debug',
      type: type,
      content: content,
      contentFormat: contentFormat,
      tag: tag,
      attributes: attributes,
      metadata: metadata,
    );
  }

  void info(
    String message, {
    String type = 'log',
    String? content,
    String? contentFormat,
    String? tag,
    DebugLogAttributes? attributes,
    DebugLogAttributes? metadata,
  }) {
    log(
      message: message,
      level: 'info',
      type: type,
      content: content,
      contentFormat: contentFormat,
      tag: tag,
      attributes: attributes,
      metadata: metadata,
    );
  }

  void warning(
    String message, {
    String type = 'log',
    String? content,
    String? contentFormat,
    String? tag,
    DebugLogAttributes? attributes,
    DebugLogAttributes? metadata,
  }) {
    log(
      message: message,
      level: 'warning',
      type: type,
      content: content,
      contentFormat: contentFormat,
      tag: tag,
      attributes: attributes,
      metadata: metadata,
    );
  }

  void error(
    String message, {
    String type = 'exception',
    Object? exception,
    StackTrace? stackTrace,
    String? content,
    String? contentFormat,
    String? tag,
    DebugLogAttributes? attributes,
    DebugLogAttributes? metadata,
  }) {
    _ensureOpen();
    final record = DebugLogRecord(
      id: '$_bootId-${_sequence++}',
      timestamp: DateTime.now().toUtc(),
      level: 'error',
      type: type,
      source: options.source,
      message: message,
      content: content,
      contentFormat: contentFormat,
      tag: tag,
      clientId: options.clientId,
      deviceId: options.deviceId,
      sessionId: options.sessionId,
      error: exception?.toString(),
      stackTrace: stackTrace?.toString(),
      attributes: attributes,
      metadata: metadata,
    );
    _enqueue(_redact(record));
  }

  Future<void> flush() {
    if (_flushFuture != null) {
      return _flushFuture!;
    }
    _flushTimer?.cancel();
    _flushTimer = null;
    _flushFuture = _flushQueue().whenComplete(() => _flushFuture = null);
    return _flushFuture!;
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    try {
      await flush();
    } finally {
      if (_ownsClient) {
        _client.close();
      }
    }
  }

  DebugLogRecord _redact(DebugLogRecord record) {
    final redact = options.redact;
    if (redact == null) {
      return record;
    }
    try {
      return redact(record);
    } catch (error, stackTrace) {
      _reportError(error, stackTrace);
      rethrow;
    }
  }

  void _enqueue(DebugLogRecord record) {
    if (_queue.length >= options.queueLimit) {
      switch (options.overflowPolicy) {
        case QueueOverflowPolicy.dropOldest:
          final dropped = _queue.removeAt(0);
          _reportDrop(dropped);
        case QueueOverflowPolicy.dropNewest:
          _reportDrop(record);
          return;
        case QueueOverflowPolicy.throwError:
          throw StateError('Flash Debug logger queue limit reached');
      }
    }

    _queue.add(record);
    if (_queue.length >= options.batchSize) {
      unawaited(flush());
    } else {
      _scheduleFlush();
    }
  }

  void _scheduleFlush() {
    if (_flushTimer != null || options.flushInterval == Duration.zero) {
      if (options.flushInterval == Duration.zero) {
        unawaited(flush());
      }
      return;
    }
    _flushTimer = Timer(options.flushInterval, () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  Future<void> _flushQueue() async {
    while (_queue.isNotEmpty) {
      final count = min(options.batchSize, _queue.length);
      final batch = _queue.sublist(0, count);
      try {
        await _sendWithRetry(batch);
        _queue.removeRange(0, count);
      } catch (error, stackTrace) {
        _reportError(error, stackTrace);
        rethrow;
      }
    }
  }

  Future<void> _sendWithRetry(List<DebugLogRecord> batch) async {
    Object? lastError;
    StackTrace? lastStackTrace;

    for (var attempt = 0; attempt <= options.maxRetries; attempt += 1) {
      try {
        final response = await _client
            .post(
              Uri.parse('$_baseUrl/api/v1/logs/batch'),
              headers: <String, String>{
                'Content-Type': 'application/json',
                if (options.token != null)
                  'Authorization': 'Bearer ${options.token}',
              },
              body: jsonEncode(<String, Object?>{
                'protocolVersion': flashDebugProtocolVersion,
                'clientId': options.clientId,
                'sdk': <String, String>{
                  'name': options.sdkName,
                  'version': options.sdkVersion,
                },
                'items': batch.map((record) => record.toJson()).toList(),
              }),
            )
            .timeout(options.timeout);

        if (response.statusCode >= 200 && response.statusCode < 300) {
          return;
        }

        final exception = FlashDebugHttpException(
          statusCode: response.statusCode,
          message: 'Flash Debug upload failed with HTTP ${response.statusCode}',
          body: response.body,
        );
        if (!exception.isRetryable || attempt == options.maxRetries) {
          throw exception;
        }
        lastError = exception;
        lastStackTrace = StackTrace.current;
        await _delayBeforeRetry(attempt, response.headers['retry-after']);
      } catch (error, stackTrace) {
        if (error is FlashDebugHttpException && !error.isRetryable) {
          rethrow;
        }
        if (attempt == options.maxRetries) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        lastError = error;
        lastStackTrace = stackTrace;
        await _delayBeforeRetry(attempt, null);
      }
    }

    if (lastError != null) {
      Error.throwWithStackTrace(
          lastError, lastStackTrace ?? StackTrace.current);
    }
  }

  Future<void> _delayBeforeRetry(int attempt, String? retryAfter) async {
    final retryAfterSeconds = int.tryParse(retryAfter ?? '');
    final delay = retryAfterSeconds == null
        ? options.retryBaseDelay * (1 << attempt)
        : Duration(seconds: retryAfterSeconds);
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
  }

  void _reportDrop(DebugLogRecord record) {
    _droppedCount += 1;
    options.onDrop?.call(record);
  }

  void _reportError(Object error, StackTrace stackTrace) {
    options.onError?.call(error, stackTrace);
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('Flash Debug logger is closed');
    }
  }
}

String _normalizeBaseUrl(String baseUrl) {
  final normalized = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
  final uri = Uri.tryParse(normalized);
  if (normalized.isEmpty || uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw ArgumentError.value(
        baseUrl, 'baseUrl', 'Expected an absolute HTTP or HTTPS URL');
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw ArgumentError.value(
        baseUrl, 'baseUrl', 'Expected an HTTP or HTTPS URL');
  }
  return normalized;
}

String _createBootId() {
  final random = Random.secure();
  final value = List<int>.generate(8, (_) => random.nextInt(256));
  return value.map((part) => part.toRadixString(16).padLeft(2, '0')).join();
}
