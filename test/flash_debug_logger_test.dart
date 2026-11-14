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

  test('retries a retryable response with the same event id', () async {
    var attempts = 0;
    final ids = <String>[];
    final client = MockClient((request) async {
      attempts += 1;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final items = body['items'] as List<dynamic>;
      ids.add(items.single['id'] as String);
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
        httpClient: client,
      ),
    );

    logger.error('request failed');
    await logger.flush();

    expect(attempts, 2);
    expect(ids.first, ids.last);
    await logger.close();
  });

  test('does not retry a permanent response', () async {
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
        httpClient: client,
      ),
    );

    logger.info('invalid payload');
    await expectLater(logger.flush(), throwsA(isA<FlashDebugHttpException>()));

    expect(attempts, 1);
    await expectLater(logger.close(), throwsA(isA<FlashDebugHttpException>()));
  });
}
