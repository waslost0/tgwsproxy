import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tg_proxy_core/tg_proxy_core.dart';

void main() {
  group('WsPool', () {
    test('miss returns null, refills and reuses an idle socket', () async {
      final stats = ProxyStats();
      var created = 0;
      final pool = WsPool(
        config: const ProxyConfig(poolSize: 4),
        stats: stats,
        connector: ({
          required host,
          required domain,
          required secure,
          required path,
          sni,
          required timeout,
        }) async {
          created++;
          return _FakeTransport();
        },
      );
      addTearDown(pool.dispose);

      final first = await pool.acquire(2, media: false);
      expect(first, isNull);
      expect(stats.poolMisses, 1);

      await _waitUntil(() => created >= 4);
      final second = await pool.acquire(2, media: false);
      expect(second, isNotNull);
      expect(stats.poolHits, 1);
    });

    test('drops stale sockets and reconnects', () async {
      final stats = ProxyStats();
      var now = DateTime(2026);
      var created = 0;
      final pool = WsPool(
        config: const ProxyConfig(poolSize: 1),
        stats: stats,
        now: () => now,
        connector: ({
          required host,
          required domain,
          required secure,
          required path,
          sni,
          required timeout,
        }) async {
          created++;
          return _FakeTransport();
        },
      );
      addTearDown(pool.dispose);

      expect(await pool.acquire(2, media: false), isNull);
      await _waitUntil(() => created >= 1);
      final cached = await pool.acquire(2, media: false);
      expect(cached, isNotNull);

      now = now.add(const Duration(seconds: 121));
      expect(await pool.acquire(2, media: false), isNull);
      await _waitUntil(() => created >= 2);
      expect(await pool.acquire(2, media: false), isNotNull);
    });

    test('returns null when no redirect IP exists', () async {
      final pool = WsPool(
        config: const ProxyConfig(dcRedirects: {}),
        stats: ProxyStats(),
      );
      addTearDown(pool.dispose);
      expect(await pool.acquire(2, media: false), isNull);
    });
  });

  group('CfWorkerPool', () {
    test('builds path and reuses an idle worker', () async {
      final stats = ProxyStats();
      var created = 0;
      String? lastPath;
      final pool = CfWorkerPool(
        config: const ProxyConfig(poolSize: 2),
        stats: stats,
        connector: ({
          required host,
          required domain,
          required secure,
          required path,
          sni,
          required timeout,
        }) async {
          created++;
          lastPath = path;
          return _FakeTransport();
        },
      );
      addTearDown(pool.dispose);

      final first = await pool.acquire(2, '149.154.167.220', ['w.example']);
      expect(first, isNull);
      expect(stats.cfPoolMisses, 1);
      await _waitUntil(() => created >= 1);
      expect(lastPath, '/apiws?dst=149.154.167.220&dc=2');
      expect(
        await pool.acquire(2, '149.154.167.220', ['w.example']),
        isNotNull,
      );
      expect(stats.cfPoolHits, 1);
      await _waitUntil(() => created >= 2);
    });

    test('cooldowns a worker after HTTP 429', () {
      final pool = CfWorkerPool(
        config: const ProxyConfig(),
        stats: ProxyStats(),
      );
      addTearDown(pool.dispose);
      pool.reportFailure(
        'w.example',
        WsHandshakeError(429, 'Too Many Requests'),
      );
      expect(pool.availableDomains(['w.example']), isEmpty);
    });

    test('returns null without worker domains', () async {
      final pool = CfWorkerPool(
        config: const ProxyConfig(),
        stats: ProxyStats(),
      );
      addTearDown(pool.dispose);
      expect(await pool.acquire(2, '149.154.167.220', const []), isNull);
    });

    test('does not warm workers while they are disabled', () async {
      var created = 0;
      final pool = CfWorkerPool(
        config: const ProxyConfig(
          poolSize: 3,
          cfproxyWorkerDomains: ['w.example'],
        ),
        stats: ProxyStats(),
        connector: ({
          required host,
          required domain,
          required secure,
          required path,
          sni,
          required timeout,
        }) async {
          created++;
          return _FakeTransport();
        },
      );
      addTearDown(pool.dispose);

      await pool.warmup({2: '149.154.167.220'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(created, 0);
    });
  });

  group('TcpFallback', () {
    test('backs off after failure and retries after the window', () async {
      var now = DateTime(2026);
      var attempts = 0;
      final fallback = TcpFallback(
        now: () => now,
        connector: (host, port, {required timeout}) async {
          attempts++;
          if (attempts == 1) throw StateError('offline');
          return _FakeTransport();
        },
      );

      expect(await fallback.connect('149.154.167.220'), isNull);
      expect(attempts, 1);
      expect(await fallback.connect('149.154.167.220'), isNull);
      expect(attempts, 1);
      now = now.add(const Duration(seconds: 30));
      expect(await fallback.connect('149.154.167.220'), isNotNull);
      expect(attempts, 2);
    });
  });

  group('TransportRouter', () {
    test('uses a pooled direct WS connection', () async {
      final stats = ProxyStats();
      final balancer = CfDomainBalancer()..updateDomains([]);
      var created = 0;
      final router = TransportRouter(
        config: const ProxyConfig(poolSize: 1),
        stats: stats,
        balancer: balancer,
        connector: ({
          required host,
          required domain,
          required secure,
          required path,
          sni,
          required timeout,
        }) async {
          created++;
          return _FakeTransport();
        },
      );
      addTearDown(router.dispose);

      await router.warmup();
      await _waitUntil(() => created >= 1);
      final result = await router.connect(2, media: false);
      expect(result?.route, 'ws');
      expect(stats.ws, 1);
    });

    test('falls back to CF worker before CF proxy and TCP', () async {
      final stats = ProxyStats();
      final balancer = CfDomainBalancer()..updateDomains([]);
      var created = 0;
      final router = TransportRouter(
        config: const ProxyConfig(
          poolSize: 1,
          cfWorkerEnabled: true,
          cfproxyWorkerDomains: ['w.example'],
        ),
        stats: stats,
        balancer: balancer,
        connector: ({
          required host,
          required domain,
          required secure,
          required path,
          sni,
          required timeout,
        }) async {
          if (domain == 'w.example') {
            created++;
            return _FakeTransport();
          }
          throw StateError('direct failed');
        },
      );
      addTearDown(router.dispose);

      await router.cfWorkerPool.acquire(
        2,
        '149.154.167.220',
        const ['w.example'],
      );
      await _waitUntil(() => created >= 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final result = await router.connect(2, media: false);
      expect(result?.route, 'cf_worker');
      expect(stats.cf, 1);
    });

    test('ignores workers while they are disabled', () async {
      final stats = ProxyStats();
      final balancer = CfDomainBalancer()..updateDomains([]);
      final router = TransportRouter(
        config: const ProxyConfig(
          poolSize: 1,
          fallbackCfproxy: false,
          cfproxyWorkerDomains: ['w.example'],
        ),
        stats: stats,
        balancer: balancer,
        connector: ({
          required host,
          required domain,
          required secure,
          required path,
          sni,
          required timeout,
        }) async =>
            throw StateError('direct failed'),
        tcpFallback: TcpFallback(
          connector: (host, port, {required timeout}) async =>
              throw StateError('tcp failed'),
        ),
      );
      addTearDown(router.dispose);

      final result = await router.connect(2, media: false);
      expect(result, isNull);
      expect(stats.cf, 0);
    });

    test('warms workers for redirected DCs too', () async {
      final paths = <String>{};
      final router = TransportRouter(
        config: const ProxyConfig(
          poolSize: 1,
          cfWorkerEnabled: true,
          cfproxyWorkerDomains: ['w.example'],
        ),
        stats: ProxyStats(),
        balancer: CfDomainBalancer()..updateDomains([]),
        connector: ({
          required host,
          required domain,
          required secure,
          required path,
          sni,
          required timeout,
        }) async {
          if (domain == 'w.example') paths.add(path);
          return _FakeTransport();
        },
      );
      addTearDown(router.dispose);

      await router.warmup();
      await _waitUntil(() => paths.length >= 6);

      expect(paths.any((path) => path.contains('dst=149.154.167.51')), isTrue);
      expect(paths.any((path) => path.contains('dst=149.154.167.91')), isTrue);
    });

    test('falls back to direct TCP when WS and CF fail', () async {
      final stats = ProxyStats();
      final balancer = CfDomainBalancer()..updateDomains([]);
      final router = TransportRouter(
        config: const ProxyConfig(poolSize: 1),
        stats: stats,
        balancer: balancer,
        connector: ({
          required host,
          required domain,
          required secure,
          required path,
          sni,
          required timeout,
        }) async =>
            throw StateError('direct failed'),
        tcpFallback: TcpFallback(
          connector: (host, port, {required timeout}) async => _FakeTransport(),
        ),
      );
      addTearDown(router.dispose);

      final result = await router.connect(2, media: false);
      expect(result?.route, 'tcp');
      expect(stats.tcpFallback, 1);
    });
  });
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not met within 2s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _FakeTransport implements ProxyTransport {
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Future<void> send(Uint8List data) async {
    if (_closed) throw StateError('closed');
  }

  @override
  Future<Uint8List?> receive() async => null;

  @override
  Future<void> close() async {
    _closed = true;
  }
}
