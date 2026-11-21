import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tgwsproxy/core/proxy/data/desktop_proxy_engine.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tgws_desktop_test');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('reports the Windows platform and keeps it across reloads', () async {
    final engine = DesktopProxyEngine(directory: dir.path, platform: 'windows');
    await engine.load();

    final settings = (await engine.bootstrap()).settings;
    expect(settings['platform'], 'windows');
    expect((await engine.bootstrap()).engineVersion, 'dart-windows');
  });

  test(
    'keeps a user Cloudflare domain and Workers from iOS settings',
    () async {
      final engine = DesktopProxyEngine(
        directory: dir.path,
        platform: 'windows',
      );
      await engine.load();

      const raw =
          '{"botApiPort":8081,"poolSize":4,"botApiEnabled":false,'
          '"autoStart":true,"cfUserDomains":["wts-tbss-test.ru"],'
          '"cfproxyEnabled":true,"forceTestDc":false,"proxyProtocol":false,'
          '"cfWorkerDomains":["mute-fog-3f89.alexkoh-x.workers.dev",'
          '"bold-mud-3930.alexkoh-x.workers.dev"],"host":"127.0.0.1",'
          '"checkUpdates":true,"port":1443,'
          '"dcRedirects":{"2":"149.154.167.220","4":"149.154.167.220"},'
          '"fakeTlsDomain":"","noSecure":false,"domain":"wts-tbss-test.ru",'
          '"cfWorkerEnabled":true,"platform":"ios"}';

      expect(await engine.importSettings(raw), isTrue);

      var settings = (await engine.bootstrap()).settings;
      expect(settings['cfUserDomains'], ['wts-tbss-test.ru']);
      expect(settings['cfWorkerDomains'], [
        'mute-fog-3f89.alexkoh-x.workers.dev',
        'bold-mud-3930.alexkoh-x.workers.dev',
      ]);
      expect(settings['cfWorkerEnabled'], isTrue);
      expect(settings['cfproxyEnabled'], isTrue);
      // The settings file was exported by iOS; the backend always reports the
      // real host platform so the UI enables the right features.
      expect(settings['platform'], 'windows');

      // The next launch reads the same values from proxy_settings.json.
      final reloaded = DesktopProxyEngine(
        directory: dir.path,
        platform: 'windows',
      );
      await reloaded.load();
      settings = (await reloaded.bootstrap()).settings;
      expect(settings['cfUserDomains'], ['wts-tbss-test.ru']);
      expect(settings['cfWorkerDomains'], [
        'mute-fog-3f89.alexkoh-x.workers.dev',
        'bold-mud-3930.alexkoh-x.workers.dev',
      ]);
      expect(settings['cfWorkerEnabled'], isTrue);
      expect(settings['platform'], 'windows');

      final exported = jsonDecode(await reloaded.exportSettings()) as Map;
      expect(exported['cfUserDomains'], ['wts-tbss-test.ru']);
      expect(exported['domain'], 'wts-tbss-test.ru');
      expect(exported.containsKey('secret'), isFalse);
    },
  );

  test('uses the iOS single domain when cfUserDomains is missing', () async {
    final engine = DesktopProxyEngine(directory: dir.path, platform: 'windows');
    await engine.load();

    expect(await engine.importSettings('{"domain":"example.com"}'), isTrue);
    final settings = (await engine.bootstrap()).settings;
    expect(settings['cfUserDomains'], ['example.com']);
    expect(settings['domain'], 'example.com');
  });
}
