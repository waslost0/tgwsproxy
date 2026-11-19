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
import 'core/proxy/proxy_repository.dart';
import 'proxy_main.dart' show runProxyEngine;

/// Headless entrypoint for the service engine. It stays in the root library so
/// Flutter can resolve it from the kernel snapshot.
@pragma('vm:entry-point')
void proxyMain() => runProxyEngine();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isMacOS) {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  final dir = await getApplicationSupportDirectory();
  final app = AppModel(AppDatabase.open(File(p.join(dir.path, 'app.db'))));
  await app.init();
  final proxy = ProxyRepository();
  await proxy.init();

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
