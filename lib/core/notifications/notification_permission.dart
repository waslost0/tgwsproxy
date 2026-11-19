// Purpose: requests the Android 13+ runtime permission for the foreground
// service notification. Without it the proxy still runs, but its notification
// is hidden from the drawer.
import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

Future<void> requestNotificationPermission() async {
  if (!Platform.isAndroid) return;
  if (await Permission.notification.isGranted) return;
  await Permission.notification.request();
}
