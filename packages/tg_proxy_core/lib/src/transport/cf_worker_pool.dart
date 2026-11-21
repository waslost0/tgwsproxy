// Purpose: Cloudflare Worker WebSocket pool.
import 'dart:async';

import '../config/proxy_config.dart';
import '../stats/proxy_stats.dart';
import 'cf_route_connector.dart';
import 'proxy_transport.dart';
import 'raw_websocket.dart';
import 'ws_pool.dart';

class _PooledWorker {
  _PooledWorker(this.transport, this.createdAt, this.domain);

  final ProxyTransport transport;
  final DateTime createdAt;
  final String domain;
}

/// One idle WebSocket per DC to a user-provided Cloudflare Worker.
class CfWorkerPool {
  CfWorkerPool({
    required this.config,
    required this.stats,
    WsConnector? connector,
    CfRouteConnector? cfRoutes,
    DateTime Function()? now,
  })  : _cfRoutes = cfRoutes ??
            CfRouteConnector(
              config: config,
              stats: stats,
              connector: connector,
            ),
        _now = now ?? DateTime.now {
    _cfRoutes.onFailure = (route, error) => reportFailure(route.key, error);
  }

  static const reuseMaxAge = Duration(seconds: 100);
  static const perDcLimit = 1;
  static const refillBackoffInitial = Duration(seconds: 1);
  static const refillBackoffMax = Duration(hours: 1);
  static const exhaustedCooldown = Duration(seconds: 45);

  final ProxyConfig config;
  final ProxyStats stats;
  final CfRouteConnector _cfRoutes;
  final DateTime Function() _now;
  final Map<int, List<_PooledWorker>> _idle = {};
  final Set<int> _refilling = {};
  final Map<int, int> _failures = {};
  final Map<int, DateTime> _retryAfter = {};
  final Map<String, DateTime> _exhaustedUntil = {};
  bool _disposed = false;

  Future<ProxyTransport?> acquire(
    int dc,
    String fallbackDst,
    List<String> workerDomains,
  ) async {
    if (_disposed ||
        config.poolSize <= 0 ||
        workerDomains.isEmpty ||
        fallbackDst.isEmpty) {
      return null;
    }

    final bucket = _idle.putIfAbsent(dc, () => []);
    while (bucket.isNotEmpty) {
      final pooled = bucket.removeAt(0);
      if (_isStale(pooled)) {
        unawaited(pooled.transport.close());
        continue;
      }
      stats.cfPoolHits++;
      _scheduleRefill(dc, fallbackDst, workerDomains);
      return pooled.transport;
    }

    // Never connect on the request path: a dead worker would stall every new
    // session for the full TLS timeout. The router falls through to the CF
    // domain or TCP while this refills in the background.
    stats.cfPoolMisses++;
    _scheduleRefill(dc, fallbackDst, workerDomains);
    return null;
  }

  Future<void> warmup(Map<int, String> fallbackDcs) async {
    if (config.poolSize <= 0 ||
        !config.cfWorkerEnabled ||
        config.cfproxyWorkerDomains.isEmpty) {
      return;
    }
    for (final entry in fallbackDcs.entries) {
      _scheduleRefill(entry.key, entry.value, config.cfproxyWorkerDomains);
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

  List<String> availableDomains(List<String> workerDomains) {
    final now = _now();
    final available = <String>[];
    for (final domain in workerDomains) {
      final until = _exhaustedUntil[domain];
      if (until != null && until.isAfter(now)) continue;
      if (until != null) _exhaustedUntil.remove(domain);
      if (!available.contains(domain)) available.add(domain);
    }
    available.shuffle();
    return available;
  }

  void reportFailure(String workerDomain, Object error) {
    if (error is WsHandshakeError && error.statusCode == 429) {
      _exhaustedUntil[workerDomain] = _now().add(exhaustedCooldown);
    }
  }

  void _scheduleRefill(int dc, String fallbackDst, List<String> workerDomains) {
    if (_disposed ||
        _refilling.contains(dc) ||
        (_retryAfter[dc]?.isAfter(_now()) ?? false)) {
      return;
    }
    _refilling.add(dc);
    unawaited(
      _refill(dc, fallbackDst, workerDomains)
          .whenComplete(() => _refilling.remove(dc)),
    );
  }

  Future<void> _refill(
    int dc,
    String fallbackDst,
    List<String> workerDomains,
  ) async {
    try {
      final bucket = _idle.putIfAbsent(dc, () => []);
      while (!_disposed && bucket.length < perDcLimit) {
        final pooled = await _connectOne(dc, fallbackDst, workerDomains);
        if (pooled == null) {
          _noteFailure(dc);
          return;
        }
        if (_disposed) {
          await pooled.transport.close();
          return;
        }
        bucket.add(pooled);
      }
      _failures.remove(dc);
      _retryAfter.remove(dc);
    } catch (_) {
      _noteFailure(dc);
    }
  }

  Future<_PooledWorker?> _connectOne(
    int dc,
    String fallbackDst,
    List<String> workerDomains,
  ) async {
    final path = Uri(
      path: '/apiws',
      queryParameters: {'dst': fallbackDst, 'dc': '$dc'},
    ).toString();
    final routes = [
      for (final domain in availableDomains(workerDomains))
        CfRoute(
          key: domain,
          host: domain,
          path: path,
          kind: CfRouteKind.worker,
        ),
    ];
    if (routes.isEmpty) return null;
    final result = await _cfRoutes.connect(routes);
    if (result == null) return null;
    return _PooledWorker(result.transport, _now(), result.route.key);
  }

  bool _isStale(_PooledWorker pooled) =>
      pooled.transport.isClosed ||
      _now().difference(pooled.createdAt) >= reuseMaxAge;

  void _noteFailure(int dc) {
    final failures = (_failures[dc] ?? 0) + 1;
    _failures[dc] = failures;
    final exponent = (failures - 1).clamp(0, 12).toInt();
    final seconds = refillBackoffInitial.inSeconds * (1 << exponent);
    final capped = seconds > refillBackoffMax.inSeconds
        ? refillBackoffMax.inSeconds
        : seconds;
    _retryAfter[dc] = _now().add(Duration(seconds: capped));
  }
}
