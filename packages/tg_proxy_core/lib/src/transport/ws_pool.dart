// Purpose: Direct Telegram WebSocket pool.
import 'dart:async';

import '../config/proxy_config.dart';
import '../constants.dart';
import '../stats/proxy_stats.dart';
import 'proxy_transport.dart';
import 'raw_websocket.dart';

typedef _PoolKey = ({int dc, bool media, bool test});

typedef WsConnector = Future<ProxyTransport> Function({
  required String host,
  required String domain,
  required bool secure,
  required String path,
  String? sni,
  required Duration timeout,
});

Future<ProxyTransport> defaultWsConnector({
  required String host,
  required String domain,
  required bool secure,
  required String path,
  String? sni,
  required Duration timeout,
}) {
  return RawWebSocket.connect(
    host,
    domain,
    secure: secure,
    path: path,
    sni: sni,
    timeout: timeout,
  );
}

class _Pooled {
  _Pooled(this.transport, this.createdAt);

  final ProxyTransport transport;
  final DateTime createdAt;
}

/// Idle WebSocket connections to Telegram's `kws*.web.telegram.org` hosts.
class WsPool {
  WsPool({
    required this.config,
    required this.stats,
    WsConnector? connector,
    DateTime Function()? now,
  })  : _connector = connector ?? defaultWsConnector,
        _now = now ?? DateTime.now;

  static const reuseMaxAge = Duration(seconds: 120);
  static const refillBackoffInitial = Duration(seconds: 1);
  static const refillBackoffMax = Duration(hours: 1);

  final ProxyConfig config;
  final ProxyStats stats;
  final WsConnector _connector;
  final DateTime Function() _now;
  final Map<_PoolKey, List<_Pooled>> _idle = {};
  final Set<_PoolKey> _refilling = {};
  final Map<_PoolKey, int> _failures = {};
  final Map<_PoolKey, DateTime> _retryAfter = {};
  bool _disposed = false;

  /// Takes a live idle socket. A miss returns null immediately: the caller
  /// falls back to CF/TCP while the pool refills in the background. Connecting
  /// on the request path would stall every new session for the TLS timeout
  /// when direct Telegram WS is DPI-blocked (the usual mobile case).
  Future<ProxyTransport?> acquire(
    int dc, {
    required bool media,
    bool test = false,
  }) async {
    if (_disposed || config.poolSize <= 0) return null;
    final targetIp = config.redirectIp(dc);
    if (targetIp == null) return null;

    final key = (dc: dc, media: media, test: test);
    final bucket = _idle.putIfAbsent(key, () => []);
    while (bucket.isNotEmpty) {
      final pooled = bucket.removeAt(0);
      if (_isStale(pooled)) {
        unawaited(pooled.transport.close());
        continue;
      }
      stats.poolHits++;
      _scheduleRefill(key, targetIp);
      return pooled.transport;
    }

    stats.poolMisses++;
    _scheduleRefill(key, targetIp);
    return null;
  }

  Future<void> warmup() async {
    for (final entry in config.dcRedirects.entries) {
      for (final media in const [false, true]) {
        final key = (dc: entry.key, media: media, test: config.forceTestDc);
        _scheduleRefill(key, entry.value);
      }
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final bucket in _idle.values) {
      for (final pooled in bucket) {
        await pooled.transport.close();
      }
    }
    _idle.clear();
  }

  void _scheduleRefill(_PoolKey key, String targetIp) {
    if (_disposed ||
        _refilling.contains(key) ||
        (_retryAfter[key]?.isAfter(_now()) ?? false)) {
      return;
    }
    _refilling.add(key);
    unawaited(
        _refill(key, targetIp).whenComplete(() => _refilling.remove(key)));
  }

  Future<void> _refill(_PoolKey key, String targetIp) async {
    try {
      final bucket = _idle.putIfAbsent(key, () => []);
      while (!_disposed && bucket.length < config.poolSize) {
        final transport = await _connectOne(
          targetIp,
          key.dc,
          key.media,
          key.test,
        );
        if (transport == null) {
          _noteFailure(key);
          return;
        }
        if (_disposed) {
          await transport.close();
          return;
        }
        bucket.add(_Pooled(transport, _now()));
      }
      _failures.remove(key);
      _retryAfter.remove(key);
    } catch (_) {
      _noteFailure(key);
    }
  }

  Future<ProxyTransport?> _connectOne(
    String targetIp,
    int dc,
    bool media,
    bool test,
  ) async {
    final path = test ? wsPathTest : wsPath;
    for (final domain in wsDomains(dc, media)) {
      try {
        return await _connector(
          host: targetIp,
          domain: domain,
          secure: !config.disableSecure,
          path: path,
          timeout: const Duration(seconds: 8),
        );
      } catch (_) {
        stats.bad++;
      }
    }
    return null;
  }

  bool _isStale(_Pooled pooled) =>
      pooled.transport.isClosed ||
      _now().difference(pooled.createdAt) >= reuseMaxAge;

  void _noteFailure(_PoolKey key) {
    final failures = (_failures[key] ?? 0) + 1;
    _failures[key] = failures;
    final exponent = (failures - 1).clamp(0, 12).toInt();
    final seconds = refillBackoffInitial.inSeconds * (1 << exponent);
    final capped = seconds > refillBackoffMax.inSeconds
        ? refillBackoffMax.inSeconds
        : seconds;
    _retryAfter[key] = _now().add(Duration(seconds: capped));
  }
}
