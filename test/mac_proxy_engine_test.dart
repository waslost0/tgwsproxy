import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tgwsproxy/core/proxy/mac_proxy_engine.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tgws_mac_test');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('generates and persists a 32-char hex secret', () async {
    final first = MacProxyEngine(directory: dir.path);
    await first.load();
    expect(first.secret, matches(RegExp(r'^[0-9a-f]{32}$')));

    final second = MacProxyEngine(directory: dir.path);
    await second.load();
    expect(second.secret, first.secret);
  });

  test('validates imported host and port', () async {
    final engine = MacProxyEngine(directory: dir.path);
    await engine.load();

    expect(await engine.importSettings('{"host":"evil.example"}'), isTrue);
    var settings = (await engine.bootstrap())['settings'] as Map;
    expect(settings['host'], '127.0.0.1');

    expect(
      await engine.importSettings('{"host":"127.0.0.2","port":1234}'),
      isTrue,
    );
    settings = (await engine.bootstrap())['settings'] as Map;
    expect(settings['host'], '127.0.0.2');
    expect(settings['port'], 1234);
  });

  test('export does not include the secret', () async {
    final engine = MacProxyEngine(directory: dir.path);
    await engine.load();
    final json = jsonDecode(engine.exportSettings()) as Map;
    expect(json.containsKey('secret'), isFalse);
    expect(json['platform'], 'macos');
  });

  test('migrates old settings to the working plain transport', () async {
    await File('${dir.path}/proxy_settings.json')
        .writeAsString('{"noSecure":false}');
    final engine = MacProxyEngine(directory: dir.path);
    await engine.load();
    final settings = (await engine.bootstrap())['settings'] as Map;
    expect(settings['noSecure'], isTrue);
  });

  test('starts and stops the loopback listener', () async {
    final engine = MacProxyEngine(directory: dir.path);
    await engine.load();
    await engine.importSettings('{"port":1555,"botApiEnabled":false}');
    await engine.start();
    expect(engine.isRunning, isTrue);
    expect(engine.link(), contains('port=1555'));
    await engine.stop();
    expect(engine.isRunning, isFalse);
  });
}
