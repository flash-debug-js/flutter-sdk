# flash_debug

Flutter and Dart logger SDK for sending complete events to Flash Debug.

## Install

```yaml
dependencies:
  flash_debug: ^0.1.0
```

## Usage

```dart
import 'package:flash_debug/flash_debug.dart';

final logger = FlashDebugLogger(
  const FlashDebugOptions(
    baseUrl: 'https://debug.example.com',
    clientId: 'flutter-app',
    deviceId: 'pixel-8',
    token: 'ingest-token',
  ),
);

logger.info(
  'request completed',
  type: 'network',
  content: '{"status":200}',
  contentFormat: 'json',
);

try {
  await loadData();
}
catch (error, stackTrace) {
  logger.error(
    'request failed',
    exception: error,
    stackTrace: stackTrace,
  );
}

await logger.flush();
await logger.close();
```

The SDK sends batches to `{baseUrl}/api/v1/logs/batch`. Each event is complete and immutable. Retries preserve the same event ID so the server can deduplicate repeated uploads.

## Configuration

`FlashDebugOptions` supports `baseUrl`, `clientId`, `source`, `deviceId`, `sessionId`, `token`, `batchSize`, `flushInterval`, `queueLimit`, `timeout`, `maxRetries`, `retryBaseDelay`, queue overflow policy, redaction, and error callbacks.

The SDK does not start Inspector, Nitro, or a tunnel. It only implements the producer-side logger and uploader contract defined by Flash Debug Logger Protocol v1.

## Development

```bash
dart pub get
dart analyze
dart test
```
