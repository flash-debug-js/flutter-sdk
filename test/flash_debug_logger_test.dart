import 'dart:async';
import 'dart:convert';

import 'package:flash_debug/flash_debug.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('uploads a complete batch to the Flash Debug endpoint', () async {
    late Request request;
    final client = MockClient((incoming) async {
      request = incoming;
      return Response(
        jsonEncode(<String, Object?>{
          'ok': true,
          'accepted': 2,
          'cursor': 2,
        }),
        200,
      );
    });
    final logger = FlashDebugLogger(
      FlashDebugOptions(
        baseUrl: 'http://127.0.0.1:4517/',
        clientId: 'flutter-test',
        token: 'secret',
        batchSize: 2,
        flushInterval: Duration(hours: 1),
        httpClient: client,
      ),
    );

    logger.info(
      'request completed',
      type: 'network',
      content: '{"status":200}',
      contentFormat: 'json',
      tag: 'API',
    );
    logger.warning('slow request');
    await logger.flush();

    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final items = body['items'] as List<dynamic>;
    expect(request.url.toString(), 'http://127.0.0.1:4517/api/v1/logs/batch');
    expect(request.headers['authorization'], 'Bearer secret');
    expect(body['protocolVersion'], 1);
    expect(body['clientId'], 'flutter-test');
    expect(
        (body['sdk'] as Map<String, dynamic>)['name'], 'flash-debug-flutter');
    expect(items, hasLength(2));
    expect(items.first['source'], 'flutter');
    expect(items.first['contentFormat'], 'json');

    await logger.close();
  });

  test('retries a retryable response with the same body and event id',
      () async {
    var attempts = 0;
    final bodies = <String>[];
    final client = MockClient((request) async {
      attempts += 1;
      bodies.add(request.body);
      return attempts == 1
          ? Response('temporary failure', 503)
          : Response('{}', 200);
    });
    final logger = FlashDebugLogger(
      FlashDebugOptions(
        baseUrl: 'https://debug.example.com',
        clientId: 'flutter-test',
        maxRetries: 1,
        retryBaseDelay: Duration.zero,
        retryJitterRatio: 0,
        httpClient: client,
      ),
    );

    logger.error('request failed');
    await logger.flush();

    expect(attempts, 2);
    expect(bodies.first, bodies.last);
    final firstItems =
        (jsonDecode(bodies.first) as Map<String, dynamic>)['items'] as List;
    final lastItems =
        (jsonDecode(bodies.last) as Map<String, dynamic>)['items'] as List;
    expect(firstItems.single['id'], lastItems.single['id']);
    await logger.close();
  });

  test('drops a permanent failure batch so close does not retry it', () async {
    var attempts = 0;
    final client = MockClient((_) async {
      attempts += 1;
      return Response('bad request', 400);
    });
    final logger = FlashDebugLogger(
      FlashDebugOptions(
        baseUrl: 'https://debug.example.com',
        clientId: 'flutter-test',
        maxRetries: 3,
        retryBaseDelay: Duration.zero,
        retryJitterRatio: 0,
        httpClient: client,
      ),
    );

    logger.info('invalid payload');
    await expectLater(logger.flush(), throwsA(isA<FlashDebugHttpException>()));

    expect(attempts, 1);
    expect(logger.queuedCount, 0);
    expect(logger.droppedCount, 1);
    await logger.close();
    expect(attempts, 1);
  });

  test('does not retry authorization failures', () async {
    for (final statusCode in [401, 403]) {
      var attempts = 0;
      final logger = FlashDebugLogger(
        FlashDebugOptions(
          baseUrl: 'https://debug.example.com',
          clientId: 'flutter-test',
          retryBaseDelay: Duration.zero,
          retryJitterRatio: 0,
          httpClient: MockClient((_) async {
            attempts += 1;
            return Response('unauthorized', statusCode);
          }),
        ),
      );

      logger.info('authorization failure');
      await expectLater(
          logger.flush(), throwsA(isA<FlashDebugHttpException>()));

      expect(attempts, 1);
      expect(logger.queuedCount, 0);
      await logger.close();
    }
  });

  test('honors a retry-after header before retrying', () async {
    var attempts = 0;
    final client = MockClient((_) async {
      attempts += 1;
      return attempts == 1
          ? Response('temporary failure', 429, headers: {'retry-after': '0'})
          : Response('{}', 200);
    });
    final logger = FlashDebugLogger(
      FlashDebugOptions(
        baseUrl: 'https://debug.example.com',
        clientId: 'flutter-test',
        maxRetries: 1,
        retryBaseDelay: const Duration(seconds: 1),
        retryJitterRatio: 0,
        httpClient: client,
      ),
    );

    logger.info('retry-after');
    await logger.flush();

    expect(attempts, 2);
    await logger.close();
  });

  test('snapshots nested attributes before enqueueing', () async {
    late Request request;
    final client = MockClient((incoming) async {
      request = incoming;
      return Response('{}', 200);
    });
    final attributes = <String, Object?>{
      'nested': <String, Object?>{'value': 'before'},
    };
    final logger = FlashDebugLogger(
      FlashDebugOptions(
        baseUrl: 'https://debug.example.com',
        clientId: 'flutter-test',
        flushInterval: Duration(hours: 1),
        httpClient: client,
      ),
    );

    logger.info('snapshot', attributes: attributes);
    (attributes['nested'] as Map<String, Object?>)['value'] = 'after';
    await logger.flush();

    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final items = body['items'] as List<dynamic>;
    final item = items.single as Map<String, dynamic>;
    final nested = item['attributes'] as Map<String, dynamic>;
    expect((nested['nested'] as Map<String, dynamic>)['value'], 'before');
    await logger.close();
  });

  test('reports and drops unsupported attribute values', () async {
    final errors = <Object>[];
    final client = MockClient((_) async => Response('{}', 200));
    final logger = FlashDebugLogger(
      FlashDebugOptions(
        baseUrl: 'https://debug.example.com',
        clientId: 'flutter-test',
        flushInterval: Duration(hours: 1),
        httpClient: client,
        onError: (error, _) => errors.add(error),
      ),
    );

    logger.info('invalid', attributes: <String, Object?>{'value': Object()});

    expect(logger.queuedCount, 0);
    expect(logger.droppedCount, 1);
    expect(errors.single, isA<FlashDebugSerializationException>());
    await logger.close();
  });

  test('drops redaction failures by default', () async {
    final errors = <Object>[];
    final logger = FlashDebugLogger(
      FlashDebugOptions(
        baseUrl: 'https://debug.example.com',
        clientId: 'flutter-test',
        flushInterval: Duration(hours: 1),
        httpClient: MockClient((_) async => Response('{}', 200)),
        redact: (_) => throw StateError('redactor failed'),
        onError: (error, _) => errors.add(error),
      ),
    );

    logger.info('redacted');

    expect(logger.queuedCount, 0);
    expect(logger.droppedCount, 1);
    expect(errors.single, isA<StateError>());
    await logger.close();
  });

  test('can propagate redaction failures in strict mode', () async {
    final logger = FlashDebugLogger(
      FlashDebugOptions(
        baseUrl: 'https://debug.example.com',
        clientId: 'flutter-test',
        flushInterval: Duration(hours: 1),
        httpClient: MockClient((_) async => Response('{}', 200)),
        redactionFailurePolicy: RedactionFailurePolicy.throwError,
        redact: (_) => throw StateError('redactor failed'),
      ),
    );

    expect(() => logger.info('redacted'), throwsStateError);
    expect(logger.droppedCount, 0);
    await logger.close();
  });

  test('drops events over the configured event size limit', () async {
    final errors = <Object>[];
    final logger = FlashDebugLogger(
      FlashDebugOptions(
        baseUrl: 'https://debug.example.com',
        clientId: 'flutter-test',
        maxEventBytes: 256,
        maxBatchBytes: 512,
        flushInterval: Duration(hours: 1),
        httpClient: MockClient((_) async => Response('{}', 200)),
        onError: (error, _) => errors.add(error),
      ),
    );

    logger.info('large', content: 'x' * 1000);

    expect(logger.queuedCount, 0);
    expect(logger.droppedCount, 1);
    expect(errors.single, isA<FlashDebugPayloadTooLargeException>());
    await logger.close();
  });

  test('splits batches that exceed the configured byte limit', () async {
    final requests = <Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return Response('{}', 200);
    });
    final logger = FlashDebugLogger(
      FlashDebugOptions(
        baseUrl: 'https://debug.example.com',
        clientId: 'flutter-test',
        batchSize: 2,
        maxEventBytes: 400,
        maxBatchBytes: 400,
        flushInterval: Duration(hours: 1),
        httpClient: client,
      ),
    );

    logger.info('first');
    logger.info('second');
    await logger.flush();

    expect(requests, hasLength(2));
    for (final request in requests) {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['items'], hasLength(1));
    }
    await logger.close();
  });

  test('applies queue overflow policy and reports dropped records', () async {
    final dropped = <String>[];
    final logger = FlashDebugLogger(
      FlashDebugOptions(
        baseUrl: 'https://debug.example.com',
        clientId: 'flutter-test',
        queueLimit: 2,
        batchSize: 10,
        flushInterval: Duration(hours: 1),
        httpClient: MockClient((_) async => Response('{}', 200)),
        onDrop: (record) => dropped.add(record.message),
      ),
    );

    logger.info('first');
    logger.info('second');
    logger.info('third');

    expect(logger.queuedCount, 2);
    expect(logger.droppedCount, 1);
    expect(dropped, ['first']);
    await logger.close();
  });

  test('bounds close when the upload does not complete', () async {
    final errors = <Object>[];
    final client = MockClient((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return Response('{}', 200);
    });
    final logger = FlashDebugLogger(
      FlashDebugOptions(
        baseUrl: 'https://debug.example.com',
        clientId: 'flutter-test',
        closeTimeout: const Duration(milliseconds: 10),
        timeout: const Duration(seconds: 1),
        maxRetries: 0,
        flushInterval: Duration(hours: 1),
        httpClient: client,
        onError: (error, _) => errors.add(error),
      ),
    );

    logger.info('slow');
    await logger.close();

    expect(errors.single, isA<TimeoutException>());
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });
}
