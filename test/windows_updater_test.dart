import 'package:flutter_test/flutter_test.dart';
import 'package:tgwsproxy/core/platform/windows_updater.dart';

void main() {
  test('builds a script that waits, extracts, copies and restarts', () {
    final script = WindowsUpdater.buildScript(
      pid: 4242,
      zip: r'C:\Temp\tgwsproxy-0.5.3-windows-x64.zip',
      installDir: r'C:\Users\Mark\AppData\Local\Programs\TG WS Proxy',
      exeName: 'tgwsproxy.exe',
      log: r'C:\Temp\update.log',
      resume: true,
    );

    expect(script, contains('Wait-Process -Id 4242'));
    expect(script, isNot(contains(r'Wait-Process -Id $pid')));
    expect(script, contains("-ArgumentList '--resume'"));
    expect(
      script,
      contains(
        r"Expand-Archive -LiteralPath 'C:\Temp\tgwsproxy-0.5.3-windows-x64.zip'",
      ),
    );
    expect(
      script,
      contains(
        r"robocopy $stage 'C:\Users\Mark\AppData\Local\Programs\TG WS Proxy'",
      ),
    );
    expect(
      script,
      contains(
        r"$exe = Join-Path 'C:\Users\Mark\AppData\Local\Programs\TG WS Proxy' 'tgwsproxy.exe'",
      ),
    );
    expect(script, contains(r'Start-Process -FilePath $exe'));
    expect(script, contains(r'$stage = Join-Path $env:TEMP'));
  });

  test('does not pass --resume when the proxy was stopped', () {
    final script = WindowsUpdater.buildScript(
      pid: 1,
      zip: r'C:\Temp\update.zip',
      installDir: r'C:\App',
      exeName: 'tgwsproxy.exe',
      log: r'C:\Temp\update.log',
    );
    expect(script, isNot(contains('--resume')));
  });
}
