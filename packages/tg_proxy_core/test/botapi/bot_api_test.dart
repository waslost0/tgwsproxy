import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tg_proxy_core/tg_proxy_core.dart';

void main() {
  late ServerSocket echoServer;
  late BotApiProxy proxy;

  setUp(() async {
    echoServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    echoServer.listen((socket) {
      socket.listen(socket.add);
    });
    proxy = BotApiProxy(
      port: 0,
      connector: (host, port) async {
        expect(host, 'api.telegram.org');
        expect(port, 443);
        return TcpTransport.connect('127.0.0.1', echoServer.port);
      },
    );
    await proxy.start();
  });

  tearDown(() async {
    await proxy.stop();
    await echoServer.close();
  });

  test('tunnels CONNECT bytes through the connector', () async {
    final client = await Socket.connect('127.0.0.1', proxy.boundPort);
    final reader = _ClientReader(client);
    client.write(
      'CONNECT api.telegram.org:443 HTTP/1.1\r\n'
      'Host: api.telegram.org:443\r\n'
      '\r\n',
    );
    expect(
        await reader.until('\r\n\r\n'), contains('200 Connection Established'));

    client.add(Uint8List.fromList([1, 2, 3, 4]));
    expect(await reader.exact(4), [1, 2, 3, 4]);

    client.destroy();
    await reader.cancel();
  });

  test('rejects non-allowlisted hosts', () async {
    final client = await Socket.connect('127.0.0.1', proxy.boundPort);
    final reader = _ClientReader(client);
    client.write('CONNECT example.com:443 HTTP/1.1\r\n\r\n');
    expect(await reader.until('\r\n\r\n'), contains('403 Forbidden'));

    client.destroy();
    await reader.cancel();
  });

  test('rejects non-CONNECT requests', () async {
    final client = await Socket.connect('127.0.0.1', proxy.boundPort);
    final reader = _ClientReader(client);
    client.write('GET / HTTP/1.1\r\nHost: api.telegram.org\r\n\r\n');
    expect(await reader.until('\r\n\r\n'), contains('405 Method Not Allowed'));

    client.destroy();
    await reader.cancel();
  });

  test('returns 502 when upstream connect fails', () async {
    await proxy.stop();
    proxy = BotApiProxy(
      port: 0,
      connector: (_, __) async => throw const SocketException('down'),
    );
    await proxy.start();

    final client = await Socket.connect('127.0.0.1', proxy.boundPort);
    final reader = _ClientReader(client);
    client.write('CONNECT api.telegram.org:443 HTTP/1.1\r\n\r\n');
    expect(await reader.until('\r\n\r\n'), contains('502 Bad Gateway'));

    client.destroy();
    await reader.cancel();
  });
}

class _ClientReader {
  _ClientReader(Socket socket) : _iterator = StreamIterator<Uint8List>(socket);

  final StreamIterator<Uint8List> _iterator;
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  Future<List<int>> exact(int length) async {
    while (_buffer.length < length) {
      if (!await _iterator.moveNext()) throw StateError('closed');
      _buffer.add(_iterator.current);
    }
    final all = _buffer.takeBytes();
    if (all.length > length) _buffer.add(all.sublist(length));
    return all.sublist(0, length);
  }

  Future<String> until(String marker) async {
    while (true) {
      final bytes = _buffer.toBytes();
      final text = String.fromCharCodes(bytes);
      final index = text.indexOf(marker);
      if (index >= 0) {
        final end = index + marker.length;
        _buffer.clear();
        _buffer.add(bytes.sublist(end));
        return text.substring(0, end);
      }
      if (!await _iterator.moveNext()) return text;
      _buffer.add(_iterator.current);
    }
  }

  Future<void> cancel() => _iterator.cancel();
}
