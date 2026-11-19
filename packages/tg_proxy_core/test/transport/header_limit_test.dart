import 'dart:io';

import 'package:test/test.dart';
import 'package:tg_proxy_core/tg_proxy_core.dart';

void main() {
  test('rejects oversized HTTP response headers', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      socket.write('HTTP/1.1 200 OK\r\n');
      for (var i = 0; i < 2000; i++) {
        socket.write('X-Pad-$i: ${'a' * 32}\r\n');
      }
      socket.write('\r\n');
    });
    addTearDown(server.close);

    await expectLater(
      RawWebSocket.connect(
        '127.0.0.1',
        'test.local',
        port: server.port,
        secure: false,
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
