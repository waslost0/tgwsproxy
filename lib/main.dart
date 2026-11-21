// Purpose: UI entrypoint: opens Drift, builds AppModel, runs the Flutter app.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'core/application.dart';
import 'core/db/app_database.dart';
import 'core/model/app_model.dart';
import 'core/notifications/notification_permission.dart';
import 'core/platform/windows_app_data.dart';
import 'core/proxy/proxy_repository.dart';
import 'proxy_main.dart' show runProxyEngine;

/// Headless entrypoint for the service engine. It stays in the root library so
/// Flutter can resolve it from the kernel snapshot.
@pragma('vm:entry-point')
void proxyMain() => runProxyEngine();

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isMacOS && !Platform.isWindows) {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  final dir = await getApplicationSupportDirectory();
  if (Platform.isWindows) {
    await migrateLegacyWindowsAppData(dir);
  }
  final app = AppModel(AppDatabase.open(File(p.join(dir.path, 'app.db'))));
  await app.init();
  final proxy = ProxyRepository();
  await proxy.init();

  // Windows login autostart launches the executable with `--autostart`;
  // the in-app updater restarts it with `--resume` to keep the proxy running.
  final resume = args.contains('--resume');
  if (Platform.isWindows && (args.contains('--autostart') || resume)) {
    final stored = await app.db.read('auto_start');
    final enabled =
        resume ||
        (stored != null
            ? stored == 'true'
            : proxy.settings['autoStart'] == true);
    if (enabled) unawaited(proxy.start());
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: app),
        ChangeNotifierProvider.value(value: proxy),
      ],
      child: const TgWsProxyApp(),
    ),
  );

  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(requestNotificationPermission());
  });
}
