## 0.1.1

- Prepare automated pub.dev publishing through GitHub Actions.

## 0.1.0

- Add the Flash Debug logger and uploader.
- Add complete event serialization for FDLP v1.
- Add bounded batching, retries, redaction, queue overflow policies, `flush`, and `close`.
- Snapshot and validate nested event data before enqueueing.
- Add event and batch byte limits with explicit drop diagnostics.
- Improve retry backoff and preserve one serialized request body across retries.
- Bound close-time flushing and remove permanent failure batches.
