// Purpose: moves app data created by older Windows builds to the current
// product-name folder after the executable metadata changed.
import 'dart:io';

import 'package:path/path.dart' as p;

const _productFolder = 'TG WS Proxy';
const _dataFiles = [
  'proxy_settings.json',
  'app.db',
  'app.db-wal',
  'app.db-shm',
];

/// Older Windows builds derived the app-data folder from the executable's
/// company metadata, which produced `%APPDATA%\<company>\TG WS Proxy`.
/// The current build uses only the product name, so this looks for a matching
/// sibling folder and copies its settings and UI database once.
Future<void> migrateLegacyWindowsAppData(
  Directory target, {
  String? appDataPath,
}) async {
  final appData = appDataPath ?? Platform.environment['APPDATA'];
  if (appData == null) return;
  if (appDataPath == null && !Platform.isWindows) return;

  if (File(p.join(target.path, 'proxy_settings.json')).existsSync()) {
    return;
  }

  Directory? source;
  DateTime? newest;
  try {
    await for (final entry in Directory(appData).list(followLinks: false)) {
      if (entry is! Directory) continue;
      final candidate = Directory(p.join(entry.path, _productFolder));
      if (p.equals(candidate.path, target.path)) continue;
      DateTime? stamp;
      for (final name in _dataFiles) {
        final file = File(p.join(candidate.path, name));
        if (!file.existsSync()) continue;
        final modified = file.lastModifiedSync();
        if (stamp == null || modified.isAfter(stamp)) stamp = modified;
      }
      if (stamp == null) continue;
      if (newest == null || stamp.isAfter(newest)) {
        newest = stamp;
        source = candidate;
      }
    }
  } on FileSystemException {
    return;
  }
  if (source == null) return;

  await target.create(recursive: true);
  for (final name in _dataFiles) {
    final from = File(p.join(source.path, name));
    if (!await from.exists()) continue;
    final to = File(p.join(target.path, name));
    if (await to.exists()) continue;
    try {
      await from.copy(to.path);
    } on FileSystemException {
      // A locked database must not stop the settings from being copied.
    }
  }
}
