// Purpose: manages the per-user Windows "Run at login" entry.
import 'dart:io';

/// Windows autostart uses `HKCU\...\CurrentVersion\Run`, so no elevation is
/// required. The entry starts the app with `--autostart`, which tells the Dart
/// entrypoint to bring the proxy up immediately.
class WindowsAutoStart {
  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _valueName = 'TGWSProxy';

  /// Adds or removes the current executable from the login startup list.
  static Future<bool> setEnabled(bool enabled) async {
    if (!Platform.isWindows) return false;
    final result = enabled
        ? await Process.run('reg', [
            'add',
            _runKey,
            '/v',
            _valueName,
            '/t',
            'REG_SZ',
            '/d',
            '"${Platform.resolvedExecutable}" --autostart',
            '/f',
          ])
        : await Process.run('reg', ['delete', _runKey, '/v', _valueName, '/f']);
    // Deleting a missing value is not an error for our purposes.
    return result.exitCode == 0 || (!enabled && result.exitCode != 0);
  }

  /// Reads the current registry value; used by diagnostics and tests.
  static Future<bool> isEnabled() async {
    if (!Platform.isWindows) return false;
    final result = await Process.run('reg', [
      'query',
      _runKey,
      '/v',
      _valueName,
    ]);
    return result.exitCode == 0;
  }
}
