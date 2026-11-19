// Purpose: Local HTTP CONNECT proxy for Bot API.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../transport/proxy_transport.dart';

typedef BotApiConnector = Future<ProxyTransport> Function(
    String host, int port);

/// Minimal HTTP CONNECT proxy for the Telegram Bot API.
///
/// The bot client points its HTTP proxy at this listener. Only
/// `api.telegram.org:443` is allowed; the upstream connector is expected to
/// tunnel to the same host through the CF Worker (`/apiws?dst=...`).
class BotApiProxy {
  BotApiProxy({
    required this.connector,
    this.bindAddress = '127.0.0.1',
    this.port = 8081,
    this.allowedHosts = const {'api.telegram.org'},
    this.headTimeout = const Duration(seconds: 10),
    this.maxHeaderBytes = 16384,
  });

  final BotApiConnector connector;
  final String bindAddress;
  final int port;
  final Set<String> allowedHosts;
  final Duration headTimeout;
  final int maxHeaderBytes;

  ServerSocket? _server;
  final Set<Socket> _clients = {};
  int _active = 0;
  int _total = 0;

  int get boundPort => _server?.port ?? port;
  int get activeConnections => _active;
  int get totalConnections => _total;

  Future<int> start() async {
    if (_server != null) return boundPort;
    final server = await ServerSocket.bind(bindAddress, port);
    _server = server;
    server.listen(_handleClient);
    return server.port;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close();
    for (final client in _clients.toList()) {
      client.destroy();
    }
    _clients.clear();
    _active = 0;
  }

  Future<void> _handleClient(Socket client) async {
    _clients.add(client);
    _active++;
    _total++;
    client.setOption(SocketOption.tcpNoDelay, true);

    final reader = _SocketReader(client);
    ProxyTransport? upstream;
    try {
      final head = await reader.readHead(maxHeaderBytes, headTimeout);
      if (head == null) return;

      final requestLine = head.split(' ');
      if (requestLine.length < 2 || requestLine[0] != 'CONNECT') {
        await _respond(client, '405 Method Not Allowed');
        return;
      }

      final target = _parseTarget(requestLine[1]);
      if (target == null || !allowedHosts.contains(target.$1)) {
        await _respond(client, '403 Forbidden');
        return;
      }

      try {
        upstream = await connector(target.$1, target.$2);
      } catch (_) {
        await _respond(client, '502 Bad Gateway');
        return;
      }

      await _writeAscii(
        client,
        'HTTP/1.1 200 Connection Established\r\n'
        'Proxy-Agent: tgwsproxy\r\n'
        '\r\n',
      );
      await _relay(client, reader, upstream);
    } catch (_) {
      // Client disconnected or upstream failed; cleanup below is enough.
    } finally {
      await reader.cancel();
      await upstream?.close();
      client.destroy();
      _clients.remove(client);
      _active--;
    }
  }

  (String, int)? _parseTarget(String target) {
    final colon = target.lastIndexOf(':');
    if (colon <= 0 || colon == target.length - 1) return null;
    final host = target.substring(0, colon);
    final port = int.tryParse(target.substring(colon + 1));
    if (port == null || port < 1 || port > 65535) return null;
    return (host, port);
  }

  Future<void> _respond(Socket client, String status) async {
    await _writeAscii(
      client,
      'HTTP/1.1 $status\r\n'
      'Content-Length: 0\r\n'
      'Connection: close\r\n'
      '\r\n',
    );
  }

  Future<void> _writeAscii(Socket socket, String text) async {
    socket.add(text.codeUnits);
    await socket.flush();
  }

  Future<void> _relay(
    Socket client,
    _SocketReader reader,
    ProxyTransport upstream,
  ) async {
    Future<void> fromClient() async {
      while (true) {
        final chunk = await reader.next();
        if (chunk == null) break;
        await upstream.send(chunk);
      }
    }

    Future<void> fromUpstream() async {
      while (true) {
        final chunk = await upstream.receive();
        if (chunk == null) break;
        client.add(chunk);
        await client.flush();
      }
    }

    final pumps = [
      fromClient().catchError((_) {}),
      fromUpstream().catchError((_) {}),
    ];
    await Future.any(pumps);
  }
}

class _SocketReader {
  _SocketReader(Socket socket) : _iterator = StreamIterator<Uint8List>(socket);

  final StreamIterator<Uint8List> _iterator;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  Uint8List? _pending;

  Future<String?> readHead(int maxBytes, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_buffer.length <= maxBytes) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return null;
      final hasNext = await _iterator.moveNext().timeout(remaining);
      if (!hasNext) return null;
      _buffer.add(_iterator.current);
      final bytes = _buffer.toBytes();
      final end = _headerEnd(bytes);
      if (end >= 0) {
        _pending = Uint8List.fromList(bytes.sublist(end));
        return String.fromCharCodes(bytes.sublist(0, end));
      }
    }
    return null;
  }

  Future<Uint8List?> next() async {
    final pending = _pending;
    if (pending != null && pending.isNotEmpty) {
      _pending = null;
      return pending;
    }
    if (!await _iterator.moveNext()) return null;
    return _iterator.current;
  }

  Future<void> cancel() => _iterator.cancel();

  int _headerEnd(Uint8List bytes) {
    for (var i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        return i + 4;
      }
    }
    return -1;
  }
}
