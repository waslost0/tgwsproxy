// Purpose: Transport interface and TCP implementation.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// A bidirectional byte transport used by the MTProto bridge.
abstract interface class ProxyTransport {
  Future<void> send(Uint8List data);

  /// Returns the next chunk, or `null` when the peer closed the connection.
  Future<Uint8List?> receive();

  Future<void> close();

  bool get isClosed;
}

class TcpTransport implements ProxyTransport {
  TcpTransport._(this._socket) : _iterator = StreamIterator(_socket);

  final Socket _socket;
  final StreamIterator<Uint8List> _iterator;
  bool _closed = false;

  static Future<TcpTransport> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    return TcpTransport._(socket);
  }

  @override
  bool get isClosed => _closed;

  @override
  Future<void> send(Uint8List data) async {
    if (_closed) throw const SocketException('transport closed');
    _socket.add(data);
    await _socket.flush();
  }

  @override
  Future<Uint8List?> receive() async {
    if (_closed) return null;
    while (await _iterator.moveNext()) {
      final chunk = _iterator.current;
      if (chunk.isNotEmpty) return chunk;
    }
    _closed = true;
    return null;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _iterator.cancel();
    _socket.destroy();
  }
}
