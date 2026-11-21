// Purpose: downloads, verifies and applies a Windows release zip in place.
//
// The running executable cannot replace itself, so the app starts a tiny
// PowerShell helper, exits, and lets the helper copy the new files and start
// the new build. Settings live in %APPDATA% and are never touched.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../update/update_checker.dart';

class WindowsUpdateException implements Exception {
  const WindowsUpdateException(this.message);
  final String message;

  @override
  String toString() => message;
}

class WindowsUpdater {
  /// Downloads [zipUrl], verifies it against [sumsUrl], replaces the files in
  /// the current install directory and schedules a restart.
  ///
  /// The process exits on success. Throws [WindowsUpdateException] on any
  /// recoverable error, leaving the current build intact.
  static Future<void> install({
    required String zipUrl,
    required String sumsUrl,
    required String version,
    bool resume = false,
    void Function(double progress)? onProgress,
  }) async {
    if (!Platform.isWindows) {
      throw const WindowsUpdateException(
        'Автоматическое обновление доступно только на Windows.',
      );
    }
    if (!UpdateChecker.isOfficialDownload(zipUrl) ||
        !UpdateChecker.isOfficialDownload(sumsUrl)) {
      throw const WindowsUpdateException('Некорректный адрес обновления.');
    }

    final exe = File(Platform.resolvedExecutable);
    final installDir = exe.parent;
    final zipName = p.basename(Uri.parse(zipUrl).path);
    if (zipName.isEmpty) {
      throw const WindowsUpdateException('В релизе нет Windows-архива.');
    }

    // The helper runs with the current user's rights. Fail early instead of
    // downloading when the app sits in a protected folder.
    try {
      final probe = File(p.join(installDir.path, '.tgwsproxy-update-probe'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
    } on FileSystemException {
      throw const WindowsUpdateException(
        'Нет прав на запись в папку приложения. '
        'Распакуйте программу в папку пользователя, например '
        '%LOCALAPPDATA%\\Programs\\TG WS Proxy.',
      );
    }

    final sums = await http
        .get(Uri.parse(sumsUrl), headers: const {'User-Agent': 'tgwsproxy'})
        .timeout(const Duration(seconds: 20));
    if (sums.statusCode != 200) {
      throw WindowsUpdateException(
        'Не удалось получить SHA256SUMS (${sums.statusCode}).',
      );
    }
    final expected = UpdateChecker.parseSha256(sums.body, zipName);
    if (expected == null) {
      throw WindowsUpdateException('В SHA256SUMS нет файла $zipName.');
    }

    final temp = await Directory.systemTemp.createTemp(
      'tgwsproxy-update-$version-',
    );
    try {
      final zip = File(p.join(temp.path, zipName));
      await _download(zipUrl, zip, onProgress);
      final actual = (await sha256.bind(zip.openRead()).first).toString();
      if (actual != expected) {
        throw const WindowsUpdateException(
          'SHA-256 не совпал. Обновление отменено.',
        );
      }

      final script = File(p.join(temp.path, 'update.ps1'));
      final ready = File(p.join(temp.path, 'ready.txt'));
      await script.writeAsString(
        '\uFEFF${_script(pid: pid, zip: zip.path, installDir: installDir.path, exeName: p.basename(exe.path), log: p.join(temp.path, 'update.log'), ready: ready.path, resume: resume)}',
        flush: true,
      );

      final process = await Process.start(
        _powershell,
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          script.path,
        ],
        workingDirectory: temp.path,
        mode: ProcessStartMode.detached,
      );

      // Do not exit until the helper is actually running. A fast exit can
      // kill it before PowerShell has even started.
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!await ready.exists()) {
        if (DateTime.now().isAfter(deadline)) {
          process.kill();
          throw const WindowsUpdateException(
            'Помощник обновления не запустился. Попробуйте ещё раз.',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } catch (_) {
      await temp.delete(recursive: true);
      rethrow;
    }

    // Let the helper enter its Wait-Process loop, then release the files.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  }

  static String get _powershell {
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final path = p.join(
      root,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    return File(path).existsSync() ? path : 'powershell.exe';
  }

  static Future<void> _download(
    String url,
    File target,
    void Function(double progress)? onProgress,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'tgwsproxy');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw WindowsUpdateException(
          'Скачивание не удалось: HTTP ${response.statusCode}.',
        );
      }
      final total = response.contentLength;
      var received = 0;
      final sink = target.openWrite();
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            onProgress?.call((received / total).clamp(0.0, 1.0));
          }
        }
      } finally {
        await sink.close();
      }
    } on SocketException catch (error) {
      throw WindowsUpdateException('Сеть недоступна: $error');
    } finally {
      client.close(force: true);
    }
  }

  /// Exposed for tests; the real updater embeds these values in the script.
  @visibleForTesting
  static String buildScript({
    required int pid,
    required String zip,
    required String installDir,
    required String exeName,
    required String log,
    required String ready,
    bool resume = false,
  }) => _script(
    pid: pid,
    zip: zip,
    installDir: installDir,
    exeName: exeName,
    log: log,
    ready: ready,
    resume: resume,
  );

  static String _script({
    required int pid,
    required String zip,
    required String installDir,
    required String exeName,
    required String log,
    required String ready,
    required bool resume,
  }) {
    String q(String value) => "'${value.replaceAll("'", "''")}'";
    final startArgs = resume ? " -ArgumentList '--resume'" : '';
    return '''
\$ErrorActionPreference = 'Stop'
\$stage = \$null
try { Set-Content -LiteralPath ${q(ready)} -Value 'ready' -Encoding ascii } catch {}
function Write-Log(\$message) {
  try { "\$(Get-Date -Format o) \$message" | Out-File -FilePath ${q(log)} -Append -Encoding utf8 } catch {}
}
try {
  Write-Log 'waiting for app $pid'
  Wait-Process -Id $pid -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 400
  \$stage = Join-Path \$env:TEMP ("tgwsproxy-stage-" + [guid]::NewGuid().ToString('N'))
  Write-Log "expand to \$stage"
  Expand-Archive -LiteralPath ${q(zip)} -DestinationPath \$stage -Force
  Get-ChildItem -LiteralPath \$stage -Recurse -File | Unblock-File
  Write-Log 'copy'
  \$null = robocopy \$stage ${q(installDir)} /E /IS /IT /COPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS
  \$code = \$LASTEXITCODE
  Write-Log "robocopy exit \$code"
  if (\$code -ge 8) { throw "robocopy failed: \$code" }
  \$exe = Join-Path ${q(installDir)} ${q(exeName)}
  Write-Log "start \$exe"
  Start-Process -FilePath \$exe -WorkingDirectory ${q(installDir)}$startArgs
} catch {
  Write-Log "ERROR: \$_"
  try { Start-Process -FilePath (Join-Path ${q(installDir)} ${q(exeName)}) -WorkingDirectory ${q(installDir)}$startArgs } catch {}
} finally {
  Remove-Item -LiteralPath ${q(zip)} -Force -ErrorAction SilentlyContinue
  if (\$stage) { Remove-Item -LiteralPath \$stage -Recurse -Force -ErrorAction SilentlyContinue }
}
''';
  }
}
