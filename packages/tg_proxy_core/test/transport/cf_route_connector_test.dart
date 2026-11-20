import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tg_proxy_core/tg_proxy_core.dart';

void main() {
  group('CfRouteConnector', () {
    test('uses the first healthy route over TLS', () async {
      final calls = <String>[];
      final connector = CfRouteConnector(
        config: const ProxyConfig(),
        stats: ProxyStats(),
        connector: ({
          required host,
          required domain,
          required secure,
          required path,
          sni,
          required timeout,
        }) async {
          calls.add('$host secure=$secure');
          return _FakeTransport();
        },
        stagger: const Duration(milliseconds: 10),
      );

      final result = await connector.connect([_route('a.example')]);

      expect(result?.secure, isTrue);
      expect(result?.route.host, 'a.example');
      expect(calls, ['a.example secure=true']);
    });

    test('moves to the next route immediately after a fast TLS failure',
        () async {
      final calls = <String>[];
      final connector = CfRouteConnector(
        config: const ProxyConfig(),
        stats: ProxyStats(),
        connector: ({
          required host,
          required domain,
          required secure,
          required path,
          sni,
          required timeout,
        }) async {
          calls.add('$host secure=$secure');
          if (host == 'a.example') throw StateError('handshake failed');
          return _FakeTransport();
        },
        stagger: const Duration(seconds: 2),
      );
      final watch = Stopwatch()..start();

      final result = await connector.connect(
        [_route('a.example'), _route('b.example')],
      );
      watch.stop();

      expect(result?.route.host, 'b.example');
      expect(calls, ['a.example secure=true', 'b.example secure=true']);
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
    });

    test('falls back to plain HTTP when TLS hangs', () async {
      final calls = <String>[];
      final connector = CfRouteConnector(
        config: const ProxyConfig(),
        stats: ProxyStats(),
        connector: ({
          required host,
          required domain,
          required secure,
          required path,
          sni,
          required timeout,
        }) {
          calls.add('secure=$secure');
          if (secure) return Completer<ProxyTransport>().future;
          return Future.value(_FakeTransport());
        },
        stagger: const Duration(milliseconds: 10),
        plainDelay: const Duration(milliseconds: 100),
        attemptTimeout: const Duration(seconds: 1),
      );
      final watch = Stopwatch()..start();

      final result = await connector.connect([_route('a.example')]);
      watch.stop();

      expect(result?.secure, isFalse);
      expect(calls, ['secure=true', 'secure=false']);
      expect(watch.elapsed, greaterThan(const Duration(milliseconds: 80)));
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('keeps using plain HTTP after a TLS fallback', () async {
      var secureCalls = 0;
      final connector = CfRouteConnector(
        config: const ProxyConfig(),
        stats: ProxyStats(),
        connector: ({
          required host,
          required domain,
          required secure,
          required path,
          sni,
          required timeout,
        }) {
          if (secure) {
            secureCalls++;
            return Completer<ProxyTransport>().future;
          }
          return Future.value(_FakeTransport());
        },
        stagger: const Duration(milliseconds: 10),
        plainDelay: const Duration(milliseconds: 50),
        attemptTimeout: const Duration(seconds: 1),
      );

      await connector.connect([_route('a.example')]);
      secureCalls = 0;
      final result = await connector.connect([_route('a.example')]);

      expect(result?.secure, isFalse);
      expect(secureCalls, 0);
    });

    test('skips a route that is cooling down', () async {
      final calls = <String>[];
      final connector = CfRouteConnector(
        config: const ProxyConfig(),
        stats: ProxyStats(),
        connector: ({
          required host,
          required domain,
          required secure,
          required path,
          sni,
          required timeout,
        }) async {
          calls.add(host);
          if (host == 'a.example') throw StateError('down');
          return _FakeTransport();
        },
        stagger: const Duration(milliseconds: 10),
      );

      expect(await connector.connect([_route('a.example')]), isNull);
      calls.clear();
      final result = await connector.connect(
        [_route('a.example'), _route('b.example')],
      );

      expect(result?.route.host, 'b.example');
      expect(calls, ['b.example']);
    });

    test('returns null within the budget when every route hangs', () async {
      final connector = CfRouteConnector(
        config: const ProxyConfig(disableSecure: true),
        stats: ProxyStats(),
        connector: ({
          required host,
          required domain,
          required secure,
          required path,
          sni,
          required timeout,
        }) =>
            Completer<ProxyTransport>().future,
        stagger: const Duration(milliseconds: 10),
        attemptTimeout: const Duration(seconds: 2),
      );
      final watch = Stopwatch()..start();

      final result = await connector.connect(
        [_route('a.example')],
        budget: const Duration(milliseconds: 200),
      );
      watch.stop();

      expect(result, isNull);
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('disableSecure forces plain HTTP only', () async {
      final calls = <bool>[];
      final connector = CfRouteConnector(
        config: const ProxyConfig(disableSecure: true),
        stats: ProxyStats(),
        connector: ({
          required host,
          required domain,
          required secure,
          required path,
          sni,
          required timeout,
        }) async {
          calls.add(secure);
          return _FakeTransport();
        },
      );

      final result = await connector.connect([_route('a.example')]);

      expect(result?.secure, isFalse);
      expect(calls, [false]);
    });

    test('closes a transport that arrives after the winner', () async {
      final late = _FakeTransport();
      final connector = CfRouteConnector(
        config: const ProxyConfig(),
        stats: ProxyStats(),
        connector: ({
          required host,
          required domain,
          required secure,
          required path,
          sni,
          required timeout,
        }) async {
          if (secure) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            return late;
          }
          return _FakeTransport();
        },
        stagger: const Duration(milliseconds: 10),
        plainDelay: const Duration(milliseconds: 20),
        attemptTimeout: const Duration(seconds: 1),
      );

      final result = await connector.connect([_route('a.example')]);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(result?.secure, isFalse);
      expect(late.isClosed, isTrue);
    });

    test('closes a transport that ignores its attempt timeout', () async {
      final ignored = _FakeTransport();
      final connector = CfRouteConnector(
        config: const ProxyConfig(disableSecure: true),
        stats: ProxyStats(),
        connector: ({
          required host,
          required domain,
          required secure,
          required path,
          sni,
          required timeout,
        }) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return ignored;
        },
        attemptTimeout: const Duration(milliseconds: 50),
      );

      final result = await connector.connect(
        [_route('a.example')],
        budget: const Duration(milliseconds: 100),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(result, isNull);
      expect(ignored.isClosed, isTrue);
    });
  });

  group('TransportRouter own routes', () {
    test('tries the own CF domain after the own Worker fails', () async {
      final stats = ProxyStats();
      final balancer = CfDomainBalancer()..updateDomains(['own.example']);
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
          if (host == 'w.example') throw StateError('worker down');
          if (host == 'kws2.own.example') return _FakeTransport();
          throw StateError('unexpected $host');
        },
      );
      addTearDown(router.dispose);

      final result = await router.connect(2, media: false);

      expect(result?.route, 'cf');
      expect(result?.domain, 'own.example');
      expect(stats.cf, 1);
    });
  });
}

CfRoute _route(String host) => CfRoute(
      key: host,
      host: host,
      path: '/apiws',
      kind: CfRouteKind.proxy,
    );

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
