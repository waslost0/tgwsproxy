import 'dart:math';

import 'package:test/test.dart';
import 'package:tg_proxy_core/tg_proxy_core.dart';

void main() {
  group('CF proxy domains', () {
    test('decodes the embedded list', () {
      expect(decodeCfproxyDomain('virkgj.com'), 'pclead.co.uk');
      expect(cfproxyDefaultDomains, hasLength(20));
      expect(cfproxyDefaultDomains.toSet(), hasLength(20));
      expect(cfproxyDefaultDomains, everyElement(endsWith('.co.uk')));
      expect(cfproxyDefaultDomains, everyElement(isValidDomain));
    });

    test('normalizes, deduplicates and parses lists', () {
      expect(
        normalizeDomainPool([
          ' Example.COM ',
          'example.com',
          'bad_domain.com',
          '-bad.com',
          'ok.co.uk',
        ]),
        ['example.com', 'ok.co.uk'],
      );
      expect(
        parseDomainList('a.com, b.com; c.com\nA.COM'),
        ['a.com', 'b.com', 'c.com'],
      );
    });

    test('balancer keeps a per-DC preference and covers all domains', () {
      final balancer = CfDomainBalancer(random: _Random(1));
      balancer.updateDomains(['a.com', 'b.com', 'c.com']);
      expect(balancer.updateDomainForDc(2, 'b.com'), isTrue);
      expect(balancer.updateDomainForDc(2, 'b.com'), isFalse);
      final domains = balancer.getDomainsForDc(2).toList();
      expect(domains.first, 'b.com');
      expect(domains.toSet(), {'a.com', 'b.com', 'c.com'});
    });

    test('manager keeps defaults when refresh returns too few domains',
        () async {
      final balancer = CfDomainBalancer(random: _Random(2));
      final manager = CfDomainManager(
        balancer: balancer,
        fetcher: () async => ['only-one.com'],
      );
      manager.start(refreshNow: false);
      await manager.refresh();
      expect(balancer.domains, cfproxyDefaultDomains);
      await manager.dispose();
    });

    test('manager applies a valid remote refresh', () async {
      final balancer = CfDomainBalancer(random: _Random(3));
      final manager = CfDomainManager(
        balancer: balancer,
        fetcher: () async => ['one.com', 'two.com', 'three.com'],
      );
      manager.start(refreshNow: false);
      await manager.refresh();
      expect(balancer.domains, ['one.com', 'two.com', 'three.com']);
      await manager.dispose();
    });

    test('user domains win and skip remote refresh', () async {
      final balancer = CfDomainBalancer(random: _Random(4));
      var fetched = false;
      final manager = CfDomainManager(
        balancer: balancer,
        userDomains: const ['my.example.com'],
        fetcher: () async {
          fetched = true;
          return ['remote.com'];
        },
      );
      manager.start(refreshNow: true);
      await manager.refresh();
      expect(balancer.domains, ['my.example.com']);
      expect(fetched, isFalse);
      await manager.dispose();
    });
  });
}

class _Random implements Random {
  _Random(this.seed);

  final int seed;
  int _state = 0;

  int _next() {
    _state = _state == 0 ? seed : _state;
    _state = (_state * 1103515245 + 12345) & 0x7FFFFFFF;
    return _state;
  }

  @override
  bool nextBool() => _next().isEven;

  @override
  double nextDouble() => _next() / 0x7FFFFFFF;

  @override
  int nextInt(int max) => _next() % max;
}
