import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tg_proxy_core/tg_proxy_core.dart';

void main() {
  group('RawWebSocket', () {
    test('upgrades, masks client frames and echoes binary', () async {
      final errors = <Object>[];
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((socket) {
        _handle(socket, (conn) async {
          final request = await conn.readHandshake();
          expect(request.first, contains('GET /apiws HTTP/1.1'));
          expect(
            request.any((line) => line.toLowerCase() == 'host: test.local'),
            isTrue,
          );
          await conn.accept();
          final frame = await conn.readFrame();
          expect(frame.opcode, RawWebSocket.opBinary);
          expect(frame.masked, isTrue);
          expect(frame.payload, [1, 2, 3]);
          await conn.sendFrame(
            RawWebSocket.opBinary,
            Uint8List.fromList([4, 5, 6]),
          );
          await conn.close();
        }, errors);
      });
      addTearDown(server.close);

      final ws = await RawWebSocket.connect(
        '127.0.0.1',
        'test.local',
        port: server.port,
        secure: false,
      );
      await ws.send(Uint8List.fromList([1, 2, 3]));
      expect(await ws.receive(), [4, 5, 6]);
      await ws.close();
      await _settle();
      expect(errors, isEmpty);
    });

    test('reassembles fragmented binary messages', () async {
      final errors = <Object>[];
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((socket) {
        _handle(socket, (conn) async {
          await conn.readHandshake();
          await conn.accept();
          await conn.sendFrame(
            RawWebSocket.opBinary,
            Uint8List.fromList('hel'.codeUnits),
            fin: false,
          );
          await conn.sendFrame(
            RawWebSocket.opContinuation,
            Uint8List.fromList('lo'.codeUnits),
          );
          await _waitForClose(conn);
        }, errors);
      });
      addTearDown(server.close);

      final ws = await RawWebSocket.connect(
        '127.0.0.1',
        'test.local',
        port: server.port,
        secure: false,
      );
      expect(utf8.decode((await ws.receive())!), 'hello');
      await ws.close();
      await _settle();
      expect(errors, isEmpty);
    });

    test('answers ping with pong before delivering binary', () async {
      final errors = <Object>[];
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((socket) {
        _handle(socket, (conn) async {
          await conn.readHandshake();
          await conn.accept();
          await conn.sendFrame(
            RawWebSocket.opPing,
            Uint8List.fromList([9]),
          );
          final pong = await conn.readFrame();
          expect(pong.opcode, RawWebSocket.opPong);
          expect(pong.payload, [9]);
          await conn.sendFrame(
            RawWebSocket.opBinary,
            Uint8List.fromList([7]),
          );
          await _waitForClose(conn);
        }, errors);
      });
      addTearDown(server.close);

      final ws = await RawWebSocket.connect(
        '127.0.0.1',
        'test.local',
        port: server.port,
        secure: false,
      );
      expect(await ws.receive(), [7]);
      await ws.close();
      await _settle();
      expect(errors, isEmpty);
    });

    test('returns null on close frame and replies with close', () async {
      final errors = <Object>[];
      final serverError = Completer<void>();
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((socket) {
        _handle(socket, (conn) async {
          await conn.readHandshake();
          await conn.accept();
          await conn.sendFrame(RawWebSocket.opClose, Uint8List(0));
          final reply = await conn.readFrame();
          expect(reply.opcode, RawWebSocket.opClose);
          await conn.close();
          if (!serverError.isCompleted) serverError.complete();
        }, errors, serverError);
      });
      addTearDown(server.close);

      final ws = await RawWebSocket.connect(
        '127.0.0.1',
        'test.local',
        port: server.port,
        secure: false,
      );
      expect(await ws.receive(), isNull);
      await serverError.future.timeout(const Duration(seconds: 2));
      expect(errors, isEmpty);
    });

    test('throws WsHandshakeError on non-101 response', () async {
      final errors = <Object>[];
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((socket) {
        _handle(socket, (conn) async {
          await conn.readHandshake();
          conn.writeString(
            'HTTP/1.1 403 Forbidden\r\n'
            'Location: https://example.com/\r\n'
            '\r\n',
          );
          await conn.flush();
          await conn.close();
        }, errors);
      });
      addTearDown(server.close);

      await expectLater(
        RawWebSocket.connect(
          '127.0.0.1',
          'test.local',
          port: server.port,
          secure: false,
        ),
        throwsA(
          isA<WsHandshakeError>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.location, 'location', 'https://example.com/'),
        ),
      );
      await _settle();
      expect(errors, isEmpty);
    });
  });
}

Future<void> _settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 30));
}

Future<void> _waitForClose(_TestConnection conn) async {
  try {
    final frame = await conn.readFrame();
    if (frame.opcode == RawWebSocket.opClose) {
      await conn.sendFrame(RawWebSocket.opClose, Uint8List(0));
    }
  } catch (_) {
    // Client may destroy the socket without a close handshake.
  }
}

void _handle(
  Socket socket,
  Future<void> Function(_TestConnection) body,
  List<Object> errors, [
  Completer<void>? done,
]) {
  final conn = _TestConnection(socket);
  body(conn).catchError((Object error, StackTrace stack) {
    errors.add(error);
    if (done != null && !done.isCompleted) {
      done.completeError(error, stack);
    }
  }).whenComplete(() {
    conn.destroy();
    if (done != null && !done.isCompleted) done.complete();
  });
}

class _TestConnection {
  _TestConnection(this._socket) : _reader = _ByteReader(_socket);

  final Socket _socket;
  final _ByteReader _reader;

  Future<List<String>> readHandshake() async {
    final lines = <String>[];
    while (true) {
      final line = await _reader.readLine();
      if (line.isEmpty) break;
      lines.add(line);
    }
    return lines;
  }

  Future<void> accept() async {
    writeString(
      'HTTP/1.1 101 Switching Protocols\r\n'
      'Upgrade: websocket\r\n'
      'Connection: Upgrade\r\n'
      'Sec-WebSocket-Accept: test\r\n'
      '\r\n',
    );
    await flush();
  }

  void writeString(String value) {
    _socket.add(utf8.encode(value));
  }

  Future<void> flush() => _socket.flush();

  Future<_TestFrame> readFrame() async {
    final first = await _reader.readExact(2);
    final fin = (first[0] & 0x80) != 0;
    final opcode = first[0] & 0x0F;
    final masked = (first[1] & 0x80) != 0;
    var length = first[1] & 0x7F;
    if (length == 126) {
      final ext = await _reader.readExact(2);
      length = (ext[0] << 8) | ext[1];
    } else if (length == 127) {
      final ext = await _reader.readExact(8);
      length = 0;
      for (final byte in ext) {
        length = (length << 8) | byte;
      }
    }
    final mask = masked ? await _reader.readExact(4) : null;
    final payload = await _reader.readExact(length);
    if (mask != null) {
      for (var i = 0; i < payload.length; i++) {
        payload[i] ^= mask[i & 3];
      }
    }
    return _TestFrame(
      fin: fin,
      opcode: opcode,
      masked: masked,
      payload: payload,
    );
  }

  Future<void> sendFrame(
    int opcode,
    Uint8List payload, {
    bool fin = true,
  }) async {
    _socket.add(_encodeFrame(opcode, payload, fin: fin));
    await _socket.flush();
  }

  Future<void> close() async {
    await _socket.flush();
    await _socket.close();
  }

  void destroy() => _socket.destroy();
}

class _TestFrame {
  const _TestFrame({
    required this.fin,
    required this.opcode,
    required this.masked,
    required this.payload,
  });

  final bool fin;
  final int opcode;
  final bool masked;
  final Uint8List payload;
}

Uint8List _encodeFrame(
  int opcode,
  Uint8List payload, {
  bool fin = true,
}) {
  final length = payload.length;
  final headerLength = 2 + (length < 126 ? 0 : (length < 65536 ? 2 : 8));
  final out = Uint8List(headerLength + length);
  out[0] = (fin ? 0x80 : 0) | opcode;
  var offset = 2;
  if (length < 126) {
    out[1] = length;
  } else if (length < 65536) {
    out[1] = 126;
    out[offset++] = (length >> 8) & 0xFF;
    out[offset++] = length & 0xFF;
  } else {
    out[1] = 127;
    final data = ByteData(8)..setUint64(0, length);
    out.setRange(offset, offset + 8, data.buffer.asUint8List());
    offset += 8;
  }
  out.setRange(offset, offset + length, payload);
  return out;
}

class _ByteReader {
  _ByteReader(Socket socket) : _iterator = StreamIterator(socket);

  final StreamIterator<Uint8List> _iterator;
  final List<Uint8List> _chunks = [];
  int _offset = 0;
  int _available = 0;

  Future<bool> _fill() async {
    while (true) {
      if (!await _iterator.moveNext()) return false;
      final chunk = _iterator.current;
      if (chunk.isEmpty) continue;
      _chunks.add(chunk);
      _available += chunk.length;
      return true;
    }
  }

  Future<Uint8List> readExact(int count) async {
    while (_available < count) {
      if (!await _fill()) {
        throw const SocketException('unexpected end of stream');
      }
    }
    final out = Uint8List(count);
    var written = 0;
    while (written < count) {
      final first = _chunks.first;
      final take = _min(first.length - _offset, count - written);
      out.setRange(written, written + take, first, _offset);
      written += take;
      _offset += take;
      _available -= take;
      if (_offset == first.length) {
        _chunks.removeAt(0);
        _offset = 0;
      }
    }
    return out;
  }

  Future<String> readLine() async {
    final bytes = <int>[];
    while (true) {
      final byte = (await readExact(1))[0];
      if (byte == 10) break;
      if (byte != 13) bytes.add(byte);
    }
    return utf8.decode(bytes);
  }
}

int _min(int a, int b) => a < b ? a : b;
