// Purpose: Fast CF route failover with automatic TLS/plain fallback.
import 'dart:async';
import 'dart:collection';

import '../config/proxy_config.dart';
import '../logging/proxy_log.dart';
import '../stats/proxy_stats.dart';
import 'proxy_transport.dart';
import 'raw_websocket.dart';
import 'ws_pool.dart';

const _stagger = Duration(seconds: 1);
const _attemptTimeout = Duration(seconds: 8);
const _budget = Duration(seconds: 15);
const _plainDelay = Duration(seconds: 3);
const _cooldownInitial = Duration(seconds: 30);
const _cooldownMax = Duration(seconds: 300);
const _tlsProbeInterval = Duration(seconds: 60);
const _maxParallel = 4;

enum CfRouteKind { worker, proxy }

/// One candidate WebSocket route. [key] is the domain used for cooldown.
class CfRoute {
  const CfRoute({
    required this.key,
    required this.host,
    required this.path,
    required this.kind,
  });

  final String key;
  final String host;
  final String path;
  final CfRouteKind kind;

  @override
  String toString() => '${kind.name} $host';
}

class CfRouteResult {
  const CfRouteResult({
    required this.transport,
    required this.route,
    required this.secure,
  });

  final ProxyTransport transport;
  final CfRoute route;
  final bool secure;
}

class _Candidate {
  const _Candidate(this.route, this.secure);

  final CfRoute route;
  final bool secure;
}

class _Attempt {
  const _Attempt(this.candidate, this.transport, this.error);

  final _Candidate candidate;
  final ProxyTransport? transport;
  final Object? error;
}

class _Running {
  _Running(this.candidate, Future<_Attempt> attempt) {
    future = attempt.then((result) {
      this.attempt = result;
      return this;
    });
  }

  final _Candidate candidate;
  late final Future<_Running> future;
  _Attempt? attempt;
}

/// Races CF routes the way the Cf2 build does: staggered parallel attempts,
/// fast failover, per-route cooldown and automatic fallback from TLS 443 to
/// plain HTTP 80 when the ISP blocks the TLS handshake.
class CfRouteConnector {
  CfRouteConnector({
    required this.config,
    required this.stats,
    WsConnector? connector,
    DateTime Function()? now,
    this.stagger = _stagger,
    this.attemptTimeout = _attemptTimeout,
    this.plainDelay = _plainDelay,
    this.cooldownInitial = _cooldownInitial,
  })  : _connector = connector ?? defaultWsConnector,
        _now = now ?? DateTime.now;

  final ProxyConfig config;
  final ProxyStats stats;
  final WsConnector _connector;
  final DateTime Function() _now;
  final Duration stagger;
  final Duration attemptTimeout;
  final Duration plainDelay;
  final Duration cooldownInitial;

  /// Lets the worker pool apply its own HTTP 429 cooldown.
  void Function(CfRoute route, Object error)? onFailure;

  final Map<String, int> _failures = {};
  final Map<String, DateTime> _retryAfter = {};
  final Map<CfRouteKind, bool> _preferPlain = {};
  final Map<CfRouteKind, DateTime> _nextTlsProbe = {};

  /// Connects to the first healthy route, or returns null after [budget].
  ///
  /// All routes must be of the same kind so plain/TLS preference is shared.
  Future<CfRouteResult?> connect(
    List<CfRoute> routes, {
    Duration budget = _budget,
  }) async {
    if (routes.isEmpty) return null;
    final kind = routes.first.kind;
    final now = _now();
    final probeTls =
        _preferPlain[kind] == true && !now.isBefore(_nextTlsProbe[kind] ?? now);
    if (probeTls) _nextTlsProbe[kind] = now.add(_tlsProbeInterval);
    final preferPlain = _preferPlain[kind] == true && !probeTls;

    final modes = config.disableSecure ? const [false] : const [true, false];
    var tls = Queue.of(_candidates(routes, true, modes, now));
    var plain = Queue.of(_candidates(routes, false, modes, now));
    if (tls.isEmpty && plain.isEmpty) {
      // Every route is cooling down: ignore the cooldown and retry now.
      tls = Queue.of([
        for (final route in _dedup(routes))
          if (modes.contains(true)) _Candidate(route, true),
      ]);
      plain = Queue.of([
        for (final route in _dedup(routes))
          if (modes.contains(false)) _Candidate(route, false),
      ]);
    }

    final deadline = now.add(budget);
    final plainAt = now.add(plainDelay);
    final active = <_Running>[];
    var nextStart = now;
    var tlsTried = false;
    CfRouteResult? winner;

    _Candidate? pick() {
      final time = _now();
      if (preferPlain) {
        if (plain.isNotEmpty) return plain.removeFirst();
        if (tls.isNotEmpty) return tls.removeFirst();
        return null;
      }
      final activeTls = active.where((r) => r.candidate.secure).length;
      if (tls.isNotEmpty && time.isBefore(plainAt)) {
        return tls.removeFirst();
      }
      if (plain.isNotEmpty &&
          (!time.isBefore(plainAt) || (tls.isEmpty && activeTls == 0))) {
        return plain.removeFirst();
      }
      if (tls.isNotEmpty) return tls.removeFirst();
      return null;
    }

    while (winner == null && _now().isBefore(deadline)) {
      while (active.length < _maxParallel && !_now().isBefore(nextStart)) {
        final candidate = pick();
        if (candidate == null) break;
        if (candidate.secure) tlsTried = true;
        active.add(_Running(candidate, _connect(candidate)));
        nextStart = _now().add(stagger);
      }

      if (active.isEmpty) {
        if (tls.isEmpty && plain.isEmpty) break;
        final wait = _waitUntil(nextStart, deadline);
        await Future<void>.delayed(wait);
        continue;
      }

      final hasPending = tls.isNotEmpty || plain.isNotEmpty;
      final wait = active.length < _maxParallel && hasPending
          ? _waitUntil(nextStart, deadline)
          : _waitUntil(deadline, deadline);
      final done = await Future.any<_Running?>([
        for (final running in active) running.future,
        Future<_Running?>.delayed(wait, () => null),
      ]);
      if (done == null) continue;

      active.remove(done);
      final attempt = done.attempt;
      if (attempt == null) continue;
      if (attempt.transport != null) {
        winner = CfRouteResult(
          transport: attempt.transport!,
          route: attempt.candidate.route,
          secure: attempt.candidate.secure,
        );
        _clearFailure(attempt.candidate);
        if (attempt.candidate.secure) {
          _preferPlain.remove(kind);
          _nextTlsProbe.remove(kind);
        } else if (tlsTried && modes.length > 1) {
          _preferPlain[kind] = true;
          _nextTlsProbe[kind] = _now().add(_tlsProbeInterval);
          proxyInfo(
            'CF ${kind.name}: TLS unavailable, switched to plain HTTP',
          );
        }
        break;
      }

      _noteFailure(attempt.candidate, attempt.error);
      nextStart = _now(); // A fast failure must not wait for the stagger.
    }

    if (winner != null) {
      for (final running in active) {
        running.future.then((done) {
          final transport = done.attempt?.transport;
          if (transport != null && !identical(transport, winner!.transport)) {
            unawaited(transport.close());
          }
        });
      }
    } else {
      for (final running in active) {
        running.future.then((done) {
          final transport = done.attempt?.transport;
          if (transport != null) unawaited(transport.close());
        });
      }
    }
    return winner;
  }

  List<_Candidate> _candidates(
    List<CfRoute> routes,
    bool secure,
    List<bool> modes,
    DateTime now,
  ) {
    if (!modes.contains(secure)) return [];
    return [
      for (final route in _dedup(routes))
        if (!_isCooling(route, secure, now)) _Candidate(route, secure),
    ];
  }

  List<CfRoute> _dedup(List<CfRoute> routes) {
    final seen = <String>{};
    return [
      for (final route in routes)
        if (seen.add('${route.kind.name}|${route.key}')) route,
    ];
  }

  bool _isCooling(CfRoute route, bool secure, DateTime now) {
    final until = _retryAfter[_routeKey(route, secure)];
    return until != null && until.isAfter(now);
  }

  void _noteFailure(_Candidate candidate, Object? error) {
    stats.bad++;
    if (error != null) onFailure?.call(candidate.route, error);
    final failures =
        (_failures[_routeKey(candidate.route, candidate.secure)] ?? 0) + 1;
    final exponent = (failures - 1).clamp(0, 10).toInt();
    final seconds = cooldownInitial.inSeconds * (1 << exponent);
    final capped =
        seconds > _cooldownMax.inSeconds ? _cooldownMax.inSeconds : seconds;
    final until = _now().add(Duration(seconds: capped));
    _retryAfter[_routeKey(candidate.route, candidate.secure)] = until;
    if (error is WsHandshakeError && candidate.secure) {
      _retryAfter[_routeKey(candidate.route, false)] = until;
    }
    proxyWarning(
      'CF ${candidate.route} ${candidate.secure ? 'TLS' : 'HTTP'} failed: '
      '$error (retry in ${capped}s)',
    );
  }

  void _clearFailure(_Candidate candidate) {
    _failures.remove(_routeKey(candidate.route, candidate.secure));
    _retryAfter.remove(_routeKey(candidate.route, candidate.secure));
  }

  String _routeKey(CfRoute route, bool secure) =>
      '${route.kind.name}|${route.key}|$secure';

  Future<_Attempt> _connect(_Candidate candidate) async {
    var late = false;
    final pending = _connector(
      host: candidate.route.host,
      domain: candidate.route.host,
      secure: candidate.secure,
      path: candidate.route.path,
      timeout: attemptTimeout,
    );
    // A connector that ignores its own timeout can still return a socket
    // after this attempt lost; close it instead of leaking it.
    unawaited(
      pending.then(
        (transport) {
          if (late) return transport.close();
          return Future<void>.value();
        },
        onError: (_) {},
      ),
    );
    try {
      final transport = await pending.timeout(
        attemptTimeout,
        onTimeout: () {
          late = true;
          throw TimeoutException('CF route timeout', attemptTimeout);
        },
      );
      return _Attempt(candidate, transport, null);
    } catch (error) {
      return _Attempt(candidate, null, error);
    }
  }

  Duration _waitUntil(DateTime target, DateTime deadline) {
    final end = target.isBefore(deadline) ? target : deadline;
    final wait = end.difference(_now());
    return wait.isNegative || wait == Duration.zero
        ? const Duration(milliseconds: 20)
        : wait;
  }
}
