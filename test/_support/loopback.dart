import 'dart:async';
import 'dart:io';

/// Stands up an `HttpServer` on `127.0.0.1:0` (random free port) and
/// calls [handle] for every incoming request. The returned [Uri] is
/// the server root with a trailing slash so callers can do
/// `serverUri.resolve('-/npm/v1/keys')`.
///
/// Caller closes the server (`server.close(force: true)`).
Future<({HttpServer server, Uri uri})> startLoopback(
  FutureOr<void> Function(HttpRequest req) handle,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  // Don't await inside listen() — that would serialize requests and
  // mask real concurrency bugs in the caller. Spawn each handler.
  server.listen((req) {
    () async {
      try {
        await handle(req);
      } on Object catch (e, st) {
        // Surface handler errors via the response so the test fails
        // with a useful message rather than hanging.
        req.response.statusCode = 500;
        req.response.write('handler error: $e\n$st');
      } finally {
        await req.response.close();
      }
    }();
  });
  final uri = Uri.parse('http://${server.address.host}:${server.port}/');
  return (server: server, uri: uri);
}
