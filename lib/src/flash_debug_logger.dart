import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'flash_debug_types.dart';

const int flashDebugProtocolVersion = 1;
const String flashDebugUploadPath = '/api/v1/logs/batch';

class FlashDebugLogger {
  FlashDebugLogger(this.options)
      : _client = options.httpClient ?? http.Client(),
        _ownsClient = options.httpClient == null,
        _endpoint = Uri.parse(
            '${_normalizeBaseUrl(options.baseUrl)}$flashDebugUploadPath'),
        _bootId = _createBootId();

  final FlashDebugOptions options;
  final http.Client _client;
  final bool _ownsClient;
  final Uri _endpoint;
  final String _bootId;
  final Queue<DebugLogRecord> _queue = Queue<DebugLogRecord>();
  final Random _random = Random();

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
    _enqueueRecord(
      _createRecord(
        message: message,
        level: level,
        type: type,
        content: content,
        contentFormat: contentFormat,
        tag: tag,
        attributes: attributes,
        metadata: metadata,
      ),
    );
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
    _enqueueRecord(
      _createRecord(
        message: message,
        level: 'error',
        type: type,
        content: content,
        contentFormat: contentFormat,
        tag: tag,
        attributes: attributes,
        metadata: metadata,
        exception: exception,
        stackTrace: stackTrace,
      ),
    );
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
      await flush().timeout(options.closeTimeout);
    } on TimeoutException catch (error, stackTrace) {
      _reportError(error, stackTrace);
    } finally {
      if (_ownsClient) {
        _client.close();
      }
    }
  }

  DebugLogRecord _createRecord({
    required String message,
    required String level,
    required String type,
    String? content,
    String? contentFormat,
    String? tag,
    DebugLogAttributes? attributes,
    DebugLogAttributes? metadata,
    Object? exception,
    StackTrace? stackTrace,
  }) {
    _ensureOpen();
    return DebugLogRecord(
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
      error: exception?.toString(),
      stackTrace: stackTrace?.toString(),
      attributes: attributes,
      metadata: metadata,
    );
  }

  void _enqueueRecord(DebugLogRecord record) {
    final prepared = _prepareRecord(record);
    if (prepared != null) {
      _enqueue(prepared);
    }
  }

  DebugLogRecord? _prepareRecord(DebugLogRecord record) {
    final redacted = _redact(record);
    if (redacted == null) {
      return null;
    }

    try {
      final snapshot = _snapshotRecord(redacted);
      final eventBytes = _encodedBytes(jsonEncode(snapshot.toJson()));
      if (eventBytes > options.maxEventBytes) {
        final error = FlashDebugPayloadTooLargeException(
          payload: 'event',
          actualBytes: eventBytes,
          maxBytes: options.maxEventBytes,
        );
        _reportError(error, StackTrace.current);
        _reportDrop(snapshot);
        return null;
      }
      return snapshot;
    } catch (error, stackTrace) {
      _reportError(error, stackTrace);
      _reportDrop(redacted);
      return null;
    }
  }

  DebugLogRecord? _redact(DebugLogRecord record) {
    final redact = options.redact;
    if (redact == null) {
      return record;
    }
    try {
      return redact(record);
    } catch (error, stackTrace) {
      _reportError(error, stackTrace);
      switch (options.redactionFailurePolicy) {
        case RedactionFailurePolicy.drop:
          _reportDrop(record);
          return null;
        case RedactionFailurePolicy.throwError:
          rethrow;
      }
    }
  }

  DebugLogRecord _snapshotRecord(DebugLogRecord record) {
    final seen = Set<Object>.identity();
    return DebugLogRecord(
      id: record.id,
      timestamp: record.timestamp,
      level: record.level,
      type: record.type,
      source: record.source,
      message: record.message,
      content: record.content,
      contentFormat: record.contentFormat,
      tag: record.tag,
      clientId: record.clientId,
      deviceId: record.deviceId,
      sessionId: record.sessionId,
      error: record.error,
      stackTrace: record.stackTrace,
      attributes: _snapshotAttributes(record.attributes, seen, 'attributes'),
      metadata: _snapshotAttributes(record.metadata, seen, 'metadata'),
    );
  }

  DebugLogAttributes? _snapshotAttributes(
    DebugLogAttributes? value,
    Set<Object> seen,
    String path,
  ) {
    if (value == null) {
      return null;
    }
    final snapshot = _snapshotJsonValue(value, seen, path);
    return snapshot as DebugLogAttributes;
  }

  Object? _snapshotJsonValue(
    Object? value,
    Set<Object> seen,
    String path,
  ) {
    if (value == null || value is String || value is bool) {
      return value;
    }
    if (value is num) {
      if (value is double && !value.isFinite) {
        throw FlashDebugSerializationException(
            '$path must not contain an infinite or NaN number');
      }
      return value;
    }
    if (value is Map) {
      if (!seen.add(value)) {
        throw FlashDebugSerializationException('$path contains a cyclic value');
      }
      try {
        final snapshot = <String, Object?>{};
        for (final entry in value.entries) {
          if (entry.key is! String) {
            throw FlashDebugSerializationException(
                '$path contains a non-string map key');
          }
          final key = entry.key as String;
          snapshot[key] = _snapshotJsonValue(entry.value, seen, '$path.$key');
        }
        return Map<String, Object?>.unmodifiable(snapshot);
      } finally {
        seen.remove(value);
      }
    }
    if (value is Iterable) {
      if (!seen.add(value)) {
        throw FlashDebugSerializationException('$path contains a cyclic value');
      }
      try {
        return List<Object?>.unmodifiable(
            value.map((item) => _snapshotJsonValue(item, seen, '$path[]')));
      } finally {
        seen.remove(value);
      }
    }
    throw FlashDebugSerializationException(
        '$path contains an unsupported value of type ${value.runtimeType}');
  }

  void _enqueue(DebugLogRecord record) {
    if (_queue.length >= options.queueLimit) {
      switch (options.overflowPolicy) {
        case QueueOverflowPolicy.dropOldest:
          final dropped = _queue.removeFirst();
          _reportDrop(dropped);
        case QueueOverflowPolicy.dropNewest:
          _reportDrop(record);
          return;
        case QueueOverflowPolicy.throwError:
          throw StateError('Flash Debug logger queue limit reached');
      }
    }

    _queue.addLast(record);
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
      late final _PreparedBatch prepared;
      try {
        prepared = _prepareBatch();
      } catch (error, stackTrace) {
        _reportError(error, stackTrace);
        if (error is FlashDebugPayloadTooLargeException && _queue.isNotEmpty) {
          _reportDrop(_queue.removeFirst());
          continue;
        }
        rethrow;
      }

      try {
        await _sendWithRetry(prepared.body);
        _removeBatch(prepared.records.length);
      } catch (error, stackTrace) {
        _reportError(error, stackTrace);
        if (error is FlashDebugHttpException && !error.isRetryable) {
          _removeBatch(prepared.records.length);
          for (final record in prepared.records) {
            _reportDrop(record);
          }
        }
        rethrow;
      }
    }
  }

  _PreparedBatch _prepareBatch() {
    final maxCount = min(options.batchSize, _queue.length);
    for (var count = maxCount; count > 0; count -= 1) {
      final records = _queue.take(count).toList(growable: false);
      final body = _encodeBatch(records);
      final bodyBytes = _encodedBytes(body);
      if (bodyBytes <= options.maxBatchBytes) {
        return _PreparedBatch(records: records, body: body);
      }
      if (count == 1) {
        throw FlashDebugPayloadTooLargeException(
          payload: 'batch',
          actualBytes: bodyBytes,
          maxBytes: options.maxBatchBytes,
        );
      }
    }
    throw StateError('Unable to prepare a Flash Debug batch');
  }

  String _encodeBatch(Iterable<DebugLogRecord> batch) {
    return jsonEncode(<String, Object?>{
      'protocolVersion': flashDebugProtocolVersion,
      'clientId': options.clientId,
      'sdk': <String, String>{
        'name': options.sdkName,
        'version': options.sdkVersion,
      },
      'items': batch.map((record) => record.toJson()).toList(growable: false),
    });
  }

  Future<void> _sendWithRetry(String body) async {
    for (var attempt = 0; attempt <= options.maxRetries; attempt += 1) {
      try {
        final response = await _client
            .post(
              _endpoint,
              headers: <String, String>{
                'Content-Type': 'application/json',
                if (options.token != null)
                  'Authorization': 'Bearer ${options.token}',
              },
              body: body,
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
        await _delayBeforeRetry(attempt, response.headers['retry-after']);
      } catch (error, stackTrace) {
        if (error is FlashDebugHttpException) {
          rethrow;
        }
        if (attempt == options.maxRetries) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        await _delayBeforeRetry(attempt, null);
      }
    }
    throw StateError('Flash Debug retry loop completed unexpectedly');
  }

  Future<void> _delayBeforeRetry(int attempt, String? retryAfter) async {
    final retryAfterDelay = _parseRetryAfter(retryAfter);
    final exponentialDelay = _exponentialDelay(attempt);
    final requestedDelay = retryAfterDelay ?? exponentialDelay;
    final cappedDelay = Duration(
      microseconds: min(
        requestedDelay.inMicroseconds,
        options.retryMaxDelay.inMicroseconds,
      ),
    );
    final jitterMax = retryAfterDelay == null
        ? (cappedDelay.inMicroseconds * options.retryJitterRatio).round()
        : 0;
    final jitter = jitterMax == 0 ? 0 : _random.nextInt(jitterMax + 1);
    final delay = Duration(
      microseconds: min(
        options.retryMaxDelay.inMicroseconds,
        cappedDelay.inMicroseconds + jitter,
      ),
    );
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
  }

  Duration _exponentialDelay(int attempt) {
    final shift = min(attempt, 30);
    final multiplier = 1 << shift;
    final micros = min(
      options.retryMaxDelay.inMicroseconds,
      options.retryBaseDelay.inMicroseconds * multiplier,
    );
    return Duration(
      microseconds: micros,
    );
  }

  Duration? _parseRetryAfter(String? retryAfter) {
    final value = retryAfter?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    final seconds = int.tryParse(value);
    if (seconds != null) {
      return Duration(seconds: max(0, seconds));
    }
    final date = DateTime.tryParse(value);
    final parsedDate = date ?? _parseHttpDate(value);
    if (parsedDate == null) {
      return null;
    }
    final delay = parsedDate.toUtc().difference(DateTime.now().toUtc());
    return delay > Duration.zero ? delay : Duration.zero;
  }

  DateTime? _parseHttpDate(String value) {
    final match = RegExp(
      r'^[A-Za-z]{3},\s*(\d{1,2})\s+([A-Za-z]{3})\s+'
      r'(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT$',
    ).firstMatch(value);
    if (match == null) {
      return null;
    }

    const months = <String, int>{
      'Jan': 1,
      'Feb': 2,
      'Mar': 3,
      'Apr': 4,
      'May': 5,
      'Jun': 6,
      'Jul': 7,
      'Aug': 8,
      'Sep': 9,
      'Oct': 10,
      'Nov': 11,
      'Dec': 12,
    };
    final month = months[match.group(2)];
    if (month == null) {
      return null;
    }
    return DateTime.utc(
      int.parse(match.group(3)!),
      month,
      int.parse(match.group(1)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
  }

  void _removeBatch(int count) {
    for (var index = 0; index < count; index += 1) {
      _queue.removeFirst();
    }
  }

  int _encodedBytes(String value) => utf8.encode(value).length;

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

class _PreparedBatch {
  const _PreparedBatch({required this.records, required this.body});

  final List<DebugLogRecord> records;
  final String body;
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
