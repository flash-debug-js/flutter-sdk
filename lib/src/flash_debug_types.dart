import 'package:http/http.dart' as http;

typedef DebugLogAttributes = Map<String, Object?>;

enum QueueOverflowPolicy {
  dropOldest,
  dropNewest,
  throwError,
}

class DebugLogRecord {
  const DebugLogRecord({
    required this.id,
    required this.timestamp,
    required this.level,
    required this.type,
    required this.source,
    required this.message,
    this.content,
    this.contentFormat,
    this.tag,
    this.clientId,
    this.deviceId,
    this.sessionId,
    this.error,
    this.stackTrace,
    this.attributes,
    this.metadata,
  });

  final String id;
  final DateTime timestamp;
  final String level;
  final String type;
  final String source;
  final String message;
  final String? content;
  final String? contentFormat;
  final String? tag;
  final String? clientId;
  final String? deviceId;
  final String? sessionId;
  final String? error;
  final String? stackTrace;
  final DebugLogAttributes? attributes;
  final DebugLogAttributes? metadata;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'level': level,
      'type': type,
      'source': source,
      'message': message,
      if (content != null) 'content': content,
      if (contentFormat != null) 'contentFormat': contentFormat,
      if (tag != null) 'tag': tag,
      if (clientId != null) 'clientId': clientId,
      if (deviceId != null) 'deviceId': deviceId,
      if (sessionId != null) 'sessionId': sessionId,
      if (error != null) 'error': error,
      if (stackTrace != null) 'stackTrace': stackTrace,
      if (attributes != null) 'attributes': attributes,
      if (metadata != null) 'metadata': metadata,
    };
  }
}

class FlashDebugOptions {
  const FlashDebugOptions({
    required this.baseUrl,
    required this.clientId,
    this.source = 'flutter',
    this.deviceId,
    this.sessionId,
    this.token,
    this.batchSize = 20,
    this.flushInterval = const Duration(milliseconds: 500),
    this.queueLimit = 1000,
    this.timeout = const Duration(seconds: 10),
    this.maxRetries = 3,
    this.retryBaseDelay = const Duration(milliseconds: 250),
    this.overflowPolicy = QueueOverflowPolicy.dropOldest,
    this.onError,
    this.onDrop,
    this.redact,
    this.httpClient,
    this.sdkName = 'flash-debug-flutter',
    this.sdkVersion = '0.1.0',
  })  : assert(batchSize > 0),
        assert(flushInterval >= Duration.zero),
        assert(queueLimit > 0),
        assert(timeout > Duration.zero),
        assert(maxRetries >= 0),
        assert(retryBaseDelay >= Duration.zero);

  final String baseUrl;
  final String clientId;
  final String source;
  final String? deviceId;
  final String? sessionId;
  final String? token;
  final int batchSize;
  final Duration flushInterval;
  final int queueLimit;
  final Duration timeout;
  final int maxRetries;
  final Duration retryBaseDelay;
  final QueueOverflowPolicy overflowPolicy;
  final void Function(Object error, StackTrace stackTrace)? onError;
  final void Function(DebugLogRecord record)? onDrop;
  final DebugLogRecord Function(DebugLogRecord record)? redact;
  final http.Client? httpClient;
  final String sdkName;
  final String sdkVersion;
}

class FlashDebugException implements Exception {
  const FlashDebugException(this.message);

  final String message;

  @override
  String toString() => 'FlashDebugException: $message';
}

class FlashDebugHttpException extends FlashDebugException {
  const FlashDebugHttpException({
    required this.statusCode,
    required String message,
    this.body,
  }) : super(message);

  final int statusCode;
  final String? body;

  bool get isRetryable =>
      statusCode == 408 || statusCode == 429 || statusCode >= 500;

  @override
  String toString() => 'FlashDebugHttpException($statusCode): $message';
}
