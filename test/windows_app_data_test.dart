import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tgwsproxy/core/platform/windows_app_data.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tgws_appdata_test');
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('copies settings and the UI database from the legacy folder', () async {
    final legacy = Directory(
      p.join(root.path, 'Legacy Company', 'TG WS Proxy'),
    );
    await legacy.create(recursive: true);
    await File(p.join(legacy.path, 'proxy_settings.json'))
        .writeAsString('{"port":1443}');
    await File(p.join(legacy.path, 'app.db')).writeAsString('db');

    final target = Directory(p.join(root.path, 'TG WS Proxy'));
    await migrateLegacyWindowsAppData(target, appDataPath: root.path);

    expect(
      await File(p.join(target.path, 'proxy_settings.json')).readAsString(),
      '{"port":1443}',
    );
    expect(await File(p.join(target.path, 'app.db')).readAsString(), 'db');
  });

  test('does not overwrite an existing target', () async {
    final legacy = Directory(
      p.join(root.path, 'Legacy Company', 'TG WS Proxy'),
    );
    await legacy.create(recursive: true);
    await File(p.join(legacy.path, 'proxy_settings.json'))
        .writeAsString('{"port":1443}');

    final target = Directory(p.join(root.path, 'TG WS Proxy'));
    await target.create(recursive: true);
    await File(p.join(target.path, 'proxy_settings.json'))
        .writeAsString('{"port":1555}');

    await migrateLegacyWindowsAppData(target, appDataPath: root.path);

    expect(
      await File(p.join(target.path, 'proxy_settings.json')).readAsString(),
      '{"port":1555}',
    );
  });
}
