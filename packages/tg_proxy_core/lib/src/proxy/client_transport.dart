// Purpose: Buffered client socket transport and exact reads.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../transport/proxy_transport.dart';

/// Buffered client-side transport used before the MTProto handshake is read.
class ClientTransport implements ProxyTransport {
  ClientTransport(this._socket) : _iterator = StreamIterator(_socket) {
    // Telegram speaks MTProto in many small writes. Nagle would hold them
    // waiting for an ACK; the Python core disables it on accepted sockets too.
    _socket.setOption(SocketOption.tcpNoDelay, true);
  }

  final Socket _socket;
  final StreamIterator<Uint8List> _iterator;

  // readExact() can consume more bytes than requested; keep the surplus for
  // the next receive/read call instead of dropping it.
  Uint8List _pending = Uint8List(0);
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Future<void> send(Uint8List data) async {
    if (_closed) throw const SocketException('client transport closed');
    _socket.add(data);
    // Flush before returning so a subsequent read cannot observe partially
    // queued protocol bytes and time out mid-frame.
    await _socket.flush();
  }

  @override
  Future<Uint8List?> receive() async {
    if (_pending.isNotEmpty) {
      final chunk = _pending;
      _pending = Uint8List(0);
      return chunk;
    }
    if (_closed) return null;
    if (await _iterator.moveNext()) {
      final chunk = _iterator.current;
      return chunk.isEmpty ? receive() : chunk;
    }
    _closed = true;
    return null;
  }

  Future<Uint8List> readExact(
    int length, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (length < 0) throw ArgumentError.value(length, 'length');
    // A single socket event may contain less than one protocol field, or
    // several fields at once; accumulate until the requested length is met.
    final builder = BytesBuilder(copy: false);
    while (builder.length < length) {
      final chunk = await _next(timeout);
      if (chunk == null) {
        throw const SocketException('client closed during read');
      }
      builder.add(chunk);
    }
    final all = builder.takeBytes();
    // Preserve the overshoot: a TCP read is not aligned to protocol fields.
    if (all.length > length) _pending = Uint8List.fromList(all.sublist(length));
    return Uint8List.fromList(all.sublist(0, length));
  }

  Future<int> readByte({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final byte = await readExact(1, timeout: timeout);
    return byte[0];
  }

  Future<String> readLine({
    // 107 bytes is the maximum PROXY protocol v1 line, including CRLF.
    int maxLength = 107,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final bytes = <int>[];
    while (bytes.length <= maxLength) {
      final byte = await readByte(timeout: timeout);
      bytes.add(byte);
      if (byte == 0x0a) break;
    }
    if (bytes.isEmpty || bytes.last != 0x0a) {
      throw const FormatException('line too long or not terminated');
    }
    return String.fromCharCodes(bytes).trimRight();
  }

  Future<Uint8List?> _next(Duration timeout) async {
    // Serve buffered overshoot before asking the socket for more bytes.
    if (_pending.isNotEmpty) {
      final chunk = _pending;
      _pending = Uint8List(0);
      return chunk;
    }
    if (_closed) return null;
    try {
      final hasNext = await _iterator.moveNext().timeout(timeout);
      if (!hasNext) {
        _closed = true;
        return null;
      }
      final chunk = _iterator.current;
      if (chunk.isEmpty) return await _next(timeout);
      return chunk;
    } on TimeoutException {
      // Destroy instead of leaving a live socket whose peer may never send
      // the rest of a frame; the caller sees the timeout and closes.
      _closed = true;
      _socket.destroy();
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    // Stop may race with the client handler; closing twice must be harmless.
    if (_closed) return;
    _closed = true;
    await _iterator.cancel();
    _socket.destroy();
  }
}
