// Purpose: Raw RFC6455 client over TLS/TCP.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../constants.dart';
import 'proxy_transport.dart';

class WsHandshakeError implements Exception {
  WsHandshakeError(
    this.statusCode,
    this.statusLine, {
    this.headers = const {},
    this.location,
  });

  final int statusCode;
  final String statusLine;
  final Map<String, String> headers;
  final String? location;

  bool get isRedirect => const {301, 302, 303, 307, 308}.contains(statusCode);

  @override
  String toString() => 'HTTP $statusCode: $statusLine';
}

class WsConnectionClosed implements Exception {
  const WsConnectionClosed();

  @override
  String toString() => 'WebSocket closed';
}

class _SocketReader {
  _SocketReader(Socket socket) : _iterator = StreamIterator(socket);

  final StreamIterator<Uint8List> _iterator;
  final List<Uint8List> _chunks = [];
  int _firstOffset = 0;
  int _available = 0;

  Future<bool> _fill(Duration timeout) async {
    while (true) {
      final hasNext = await _iterator.moveNext().timeout(timeout);
      if (!hasNext) return false;
      final chunk = _iterator.current;
      if (chunk.isEmpty) continue;
      _chunks.add(chunk);
      _available += chunk.length;
      return true;
    }
  }

  Future<Uint8List> readExact(int count, Duration timeout) async {
    while (_available < count) {
      if (!await _fill(timeout)) throw const WsConnectionClosed();
    }
    final out = Uint8List(count);
    var written = 0;
    while (written < count) {
      final first = _chunks.first;
      final take = min(first.length - _firstOffset, count - written);
      out.setRange(written, written + take, first, _firstOffset);
      written += take;
      _firstOffset += take;
      _available -= take;
      if (_firstOffset == first.length) {
        _chunks.removeAt(0);
        _firstOffset = 0;
      }
    }
    return out;
  }

  Future<int> readByte(Duration timeout) async {
    final byte = await readExact(1, timeout);
    return byte[0];
  }

  Future<String> readLine(Duration timeout) async {
    final bytes = <int>[];
    while (true) {
      final byte = await readByte(timeout);
      if (byte == 10) break;
      if (byte != 13) bytes.add(byte);
      if (bytes.length > 64 * 1024) {
        throw const FormatException('HTTP header line too long');
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<void> cancel() => _iterator.cancel();
}

class RawWebSocket implements ProxyTransport {
  RawWebSocket._(this._socket, this._reader) {
    _keepAlive = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_closed) return;
      if (DateTime.now().difference(_lastActivity).inSeconds < 20) return;
      unawaited(_sendPing());
    });
  }

  static const int opContinuation = 0x0;
  static const int opBinary = 0x2;
  static const int opClose = 0x8;
  static const int opPing = 0x9;
  static const int opPong = 0xA;
  static const int maxMessageLength = 16 * 1024 * 1024;

  final Socket _socket;
  final _SocketReader _reader;
  final List<int> _fragment = [];
  bool _closed = false;
  Timer? _keepAlive;
  DateTime _lastActivity = DateTime.now();

  static Future<RawWebSocket> connect(
    String host,
    String domain, {
    Duration timeout = const Duration(seconds: 10),
    String path = wsPath,
    String? sni,
    bool secure = true,
    int? port,
  }) async {
    final raw = await Socket.connect(
      host,
      port ?? (secure ? 443 : 80),
      timeout: timeout,
    );
    raw.setOption(SocketOption.tcpNoDelay, true);

    Socket socket = raw;
    try {
      if (secure) {
        socket = await SecureSocket.secure(
          raw,
          host: sni ?? domain,
        ).timeout(timeout);
      }

      final reader = _SocketReader(socket);
      final key = base64Encode(
        List<int>.generate(16, (_) => Random.secure().nextInt(256)),
      );
      final request = 'GET $path HTTP/1.1\r\n'
          'Host: $domain\r\n'
          'Upgrade: websocket\r\n'
          'Connection: Upgrade\r\n'
          'Sec-WebSocket-Key: $key\r\n'
          'Sec-WebSocket-Version: 13\r\n'
          'Sec-WebSocket-Protocol: binary\r\n'
          '\r\n';
      socket.add(utf8.encode(request));
      await socket.flush();

      final lines = <String>[];
      var headerBytes = 0;
      while (true) {
        final line = await reader.readLine(timeout);
        headerBytes += line.length + 2;
        if (headerBytes > 64 * 1024) {
          throw const FormatException('HTTP headers too large');
        }
        if (line.isEmpty) break;
        lines.add(line);
      }
      if (lines.isEmpty) {
        throw WsHandshakeError(0, 'empty response');
      }

      final parts = lines.first.split(' ');
      final statusCode = parts.length >= 2 ? int.tryParse(parts[1]) ?? 0 : 0;
      if (statusCode == 101) {
        return RawWebSocket._(socket, reader);
      }

      final headers = <String, String>{};
      for (final line in lines.skip(1)) {
        final colon = line.indexOf(':');
        if (colon > 0) {
          headers[line.substring(0, colon).trim().toLowerCase()] =
              line.substring(colon + 1).trim();
        }
      }
      throw WsHandshakeError(
        statusCode,
        lines.first,
        headers: headers,
        location: headers['location'],
      );
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

  @override
  bool get isClosed => _closed;

  @override
  Future<void> send(Uint8List data) async {
    if (_closed) throw const WsConnectionClosed();
    _lastActivity = DateTime.now();
    _socket.add(_encodeFrame(opBinary, data, masked: true));
    await _socket.flush();
  }

  Future<void> sendBatch(List<Uint8List> parts) async {
    if (_closed) throw const WsConnectionClosed();
    final out = BytesBuilder(copy: false);
    for (final part in parts) {
      out.add(_encodeFrame(opBinary, part, masked: true));
    }
    _lastActivity = DateTime.now();
    _socket.add(out.takeBytes());
    await _socket.flush();
  }

  @override
  Future<Uint8List?> receive() async {
    while (!_closed) {
      final frame = await _readFrame();
      _lastActivity = DateTime.now();
      final opcode = frame.opcode;
      final payload = frame.payload;

      if (opcode == opClose) {
        _closed = true;
        try {
          _socket.add(
            _encodeFrame(
              opClose,
              payload.length >= 2 ? payload.sublist(0, 2) : Uint8List(0),
              masked: true,
            ),
          );
          await _socket.flush();
        } catch (_) {
          // Peer is already gone.
        }
        return null;
      }

      if (opcode == opPing) {
        try {
          _socket.add(_encodeFrame(opPong, payload, masked: true));
          await _socket.flush();
        } catch (_) {
          // Ignore a broken control channel.
        }
        continue;
      }
      if (opcode == opPong) continue;

      if (opcode == opContinuation || opcode == 0x1 || opcode == opBinary) {
        if (frame.fin && _fragment.isEmpty) return payload;
        _fragment.addAll(payload);
        if (_fragment.length > maxMessageLength) {
          throw const WsConnectionClosed();
        }
        if (!frame.fin) continue;
        final message = Uint8List.fromList(_fragment);
        _fragment.clear();
        return message;
      }
    }
    return null;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _keepAlive?.cancel();
    try {
      _socket.add(_encodeFrame(opClose, Uint8List(0), masked: true));
      await _socket.flush();
    } catch (_) {
      // Best effort.
    }
    await _reader.cancel();
    _socket.destroy();
  }

  Future<void> _sendPing() async {
    try {
      _socket.add(_encodeFrame(opPing, Uint8List(0), masked: true));
      await _socket.flush();
    } catch (_) {
      // The read side will observe the close.
    }
  }

  Future<_Frame> _readFrame() async {
    final header = await _reader.readExact(2, const Duration(seconds: 15));
    final fin = (header[0] & 0x80) != 0;
    final opcode = header[0] & 0x0F;
    var length = header[1] & 0x7F;
    if (length == 126) {
      final ext = await _reader.readExact(2, const Duration(seconds: 15));
      length = (ext[0] << 8) | ext[1];
    } else if (length == 127) {
      final ext = await _reader.readExact(8, const Duration(seconds: 15));
      var value = 0;
      for (final byte in ext) {
        value = (value << 8) | byte;
      }
      length = value;
    }
    if (length > maxMessageLength) {
      throw const WsConnectionClosed();
    }

    Uint8List? mask;
    if ((header[1] & 0x80) != 0) {
      mask = await _reader.readExact(4, const Duration(seconds: 15));
    }
    final payload = await _reader.readExact(
      length,
      const Duration(seconds: 120),
    );
    if (mask != null) _xorMaskInPlace(payload, mask);
    return _Frame(fin: fin, opcode: opcode, payload: payload);
  }

  static Uint8List _encodeFrame(
    int opcode,
    Uint8List payload, {
    required bool masked,
  }) {
    final length = payload.length;
    final headerLength = 2 + (length < 126 ? 0 : (length < 65536 ? 2 : 8));
    final maskLength = masked ? 4 : 0;
    final out = Uint8List(headerLength + maskLength + length);
    out[0] = 0x80 | opcode;
    var offset = 2;
    if (length < 126) {
      out[1] = (masked ? 0x80 : 0) | length;
    } else if (length < 65536) {
      out[1] = (masked ? 0x80 : 0) | 126;
      out[offset++] = (length >> 8) & 0xFF;
      out[offset++] = length & 0xFF;
    } else {
      out[1] = (masked ? 0x80 : 0) | 127;
      final data = ByteData(8)..setUint64(0, length);
      out.setRange(offset, offset + 8, data.buffer.asUint8List());
      offset += 8;
    }

    if (!masked) {
      out.setRange(offset, offset + length, payload);
      return out;
    }

    final mask = List<int>.generate(4, (_) => Random.secure().nextInt(256));
    out.setRange(offset, offset + 4, mask);
    offset += 4;
    for (var i = 0; i < length; i++) {
      out[offset + i] = payload[i] ^ mask[i & 3];
    }
    return out;
  }

  static void _xorMaskInPlace(Uint8List data, Uint8List mask) {
    for (var i = 0; i < data.length; i++) {
      data[i] ^= mask[i & 3];
    }
  }
}

class _Frame {
  const _Frame({
    required this.fin,
    required this.opcode,
    required this.payload,
  });

  final bool fin;
  final int opcode;
  final Uint8List payload;
}
