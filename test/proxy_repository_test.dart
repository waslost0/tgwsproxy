import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tgwsproxy/core/proxy/domain/proxy_backend.dart';
import 'package:tgwsproxy/core/proxy/domain/proxy_models.dart';
import 'package:tgwsproxy/core/proxy/proxy_repository.dart';

class _FakeBackend implements ProxyBackend {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  bool running = false;
  Map<String, dynamic> settings = <String, dynamic>{
    'host': '127.0.0.1',
    'port': 1443,
    'platform': 'test',
  };

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<void> pushMenuState(Map<String, dynamic> state) async {}

  Map<String, dynamic> _state() => <String, dynamic>{
    'running': running,
    'starting': false,
    'host': settings['host'],
    'port': settings['port'],
  };

  void emitState() =>
      _events.add(<String, dynamic>{'type': 'state', ..._state()});

  @override
  Future<ProxyBootstrap> bootstrap() async => ProxyBootstrap(
    state: ProxySnapshot.fromMap(_state()),
    settings: settings,
    link: 'tg://proxy?server=127.0.0.1&port=1443&secret=dd00',
    secret: '00' * 16,
    engineVersion: 'fake',
  );

  @override
  Future<void> start() async {
    running = true;
    emitState();
  }

  @override
  Future<void> stop() async {
    running = false;
    emitState();
  }

  @override
  Future<void> restart() async {
    await stop();
    await start();
  }

  @override
  Future<void> updateSettings(Map<String, dynamic> values) async {
    settings = <String, dynamic>{...settings, ...values};
  }

  @override
  Future<String> regenerateSecret() async => '11' * 16;

  bool acked = false;

  @override
  Future<void> acknowledgeSecretMigration() async {
    acked = true;
  }

  @override
  Future<void> openInTelegram() async {}

  @override
  Future<void> openBatterySettings() async {}

  @override
  Future<String> getSecret() async => '00' * 16;

  @override
  Future<String> getProxyLink() async => 'tg://proxy?server=127.0.0.1';

  @override
  Future<String> exportSettings() async => '{}';

  @override
  Future<bool> importSettings(String raw) async => true;

  @override
  Future<Map<String, dynamic>> getDiagnostics() async => <String, dynamic>{};

  @override
  Future<void> dispose() async => _events.close();
}

void main() {
  test('facade applies migration ack', () async {
    final backend = _FakeBackend();
    final repository = ProxyRepository(backend: backend);
    await repository.init();
    await repository.acknowledgeSecretMigration();
    expect(backend.acked, isTrue);
    expect(repository.secretMigrated, isFalse);
    repository.dispose();
  });

  test('facade reacts to menu toggle event', () async {
    final backend = _FakeBackend();
    final repository = ProxyRepository(backend: backend);
    await repository.init();
    backend.running = true;
    backend.emitState();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    backend._events.add(<String, dynamic>{'type': 'menu', 'action': 'toggle'});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(repository.state.running, isFalse);
    repository.dispose();
  });

  test('facade applies backend state and settings', () async {
    final backend = _FakeBackend();
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
