import 'package:flutter_test/flutter_test.dart';
import 'package:tgwsproxy/core/proxy/proxy_repository.dart';

import 'support/fake_proxy_backend.dart';

void main() {
  test('facade applies migration ack', () async {
    final backend = FakeProxyBackend();
    final repository = ProxyRepository(backend: backend);
    await repository.init();
    await repository.acknowledgeSecretMigration();
    expect(backend.acked, isTrue);
    expect(repository.secretMigrated, isFalse);
    repository.dispose();
  });

  test('facade reacts to menu toggle event', () async {
    final backend = FakeProxyBackend();
    final repository = ProxyRepository(backend: backend);
    await repository.init();
    backend.running = true;
    backend.emitState();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    backend.emitMenu('toggle');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(repository.state.running, isFalse);
    repository.dispose();
  });

  test('facade applies backend state and settings', () async {
    final backend = FakeProxyBackend();
    final repository = ProxyRepository(backend: backend);
    await repository.init();

    expect(repository.state.running, isFalse);
    expect(repository.settings['platform'], 'test');

    await repository.start();
    expect(repository.state.running, isTrue);

    backend.emitState();
    await Future<void>.delayed(Duration.zero);
    expect(repository.state.running, isTrue);

    await repository.updateSettings(<String, dynamic>{'port': 1555});
    expect(repository.settings['port'], 1555);

    repository.dispose();
  });
}
