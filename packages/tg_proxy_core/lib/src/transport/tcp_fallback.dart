// Purpose: Direct TCP fallback with backoff.
import 'dart:async';

import 'proxy_transport.dart';

typedef TcpConnector = Future<ProxyTransport> Function(
  String host,
  int port, {
  required Duration timeout,
});

Future<ProxyTransport> _defaultTcpConnector(
  String host,
  int port, {
  required Duration timeout,
}) {
  return TcpTransport.connect(host, port, timeout: timeout);
}

class TcpFallback {
  TcpFallback({
    TcpConnector? connector,
    DateTime Function()? now,
  })  : _connector = connector ?? _defaultTcpConnector,
        _now = now ?? DateTime.now;

  static const backoffInitial = Duration(seconds: 30);
  static const backoffMax = Duration(hours: 1);
  static const connectingTtl = Duration(seconds: 30);

  final TcpConnector _connector;
  final DateTime Function() _now;
  final Map<String, int> _failures = {};
  final Map<String, DateTime> _retryAfter = {};
  final Map<String, DateTime> _connecting = {};

  Future<ProxyTransport?> connect(
    String host, {
    int port = 443,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final key = '$host:$port';
    final now = _now();
    final retryAfter = _retryAfter[key];
    if (retryAfter != null && retryAfter.isAfter(now)) return null;
    final connectingAt = _connecting[key];
    if (connectingAt != null && now.difference(connectingAt) < connectingTtl) {
      return null;
    }

    _connecting[key] = now;
    try {
      final transport = await _connector(host, port, timeout: timeout);
      _failures.remove(key);
      _retryAfter.remove(key);
      return transport;
    } catch (_) {
      _noteFailure(key);
      return null;
    } finally {
      _connecting.remove(key);
    }
  }

  void reset() {
    _failures.clear();
    _retryAfter.clear();
    _connecting.clear();
  }

  void _noteFailure(String key) {
    final failures = (_failures[key] ?? 0) + 1;
    _failures[key] = failures;
    final exponent = (failures - 1).clamp(0, 7).toInt();
    final seconds = backoffInitial.inSeconds * (1 << exponent);
    final capped =
        seconds > backoffMax.inSeconds ? backoffMax.inSeconds : seconds;
    _retryAfter[key] = _now().add(Duration(seconds: capped));
  }
}
