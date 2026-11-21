import 'package:flutter_test/flutter_test.dart';
import 'package:tgwsproxy/core/update/update_checker.dart';

void main() {
  group('UpdateChecker.isNewer', () {
    test('compares numeric parts', () {
      expect(UpdateChecker.isNewer('0.2.1', '0.2.0'), isTrue);
      expect(UpdateChecker.isNewer('0.3', '0.2.9'), isTrue);
      expect(UpdateChecker.isNewer('0.2.0', '0.2.0'), isFalse);
      expect(UpdateChecker.isNewer('0.1.9', '0.2.0'), isFalse);
    });
  });

  group('UpdateChecker.isOfficialDownload', () {
    test('accepts this repository release assets', () {
      expect(
        UpdateChecker.isOfficialDownload(
          'https://github.com/waslost0/tgwsproxy/releases/download/v0.2.1/tgwsproxy-0.2.1.apk',
        ),
        isTrue,
      );
    });

    test('rejects other hosts and repositories', () {
      expect(
        UpdateChecker.isOfficialDownload('https://evil.example/app.apk'),
        isFalse,
      );
      expect(
        UpdateChecker.isOfficialDownload(
          'https://github.com/other/repo/releases/download/v1/app.apk',
        ),
        isFalse,
      );
    });
  });

  test('parseSha256 finds the matching asset', () {
    const sums = 'aaa  tgwsproxy-0.2.1.apk\nbbb  other.apk\n';
    expect(UpdateChecker.parseSha256(sums, 'tgwsproxy-0.2.1.apk'), 'aaa');
    expect(UpdateChecker.parseSha256(sums, 'missing.apk'), isNull);
  });

  test('parseRelease picks the Windows zip and SHA256SUMS', () {
    const base =
        'https://github.com/waslost0/tgwsproxy/releases/download/v0.5.2';
    final info = UpdateChecker.parseRelease({
      'tag_name': 'v0.5.2',
      'html_url': 'https://github.com/waslost0/tgwsproxy/releases/tag/v0.5.2',
      'assets': [
        {
          'name': 'tgwsproxy-0.5.2.apk',
          'browser_download_url': '$base/tgwsproxy-0.5.2.apk',
        },
        {
          'name': 'tgwsproxy-0.5.2-windows-x64.zip',
          'browser_download_url': '$base/tgwsproxy-0.5.2-windows-x64.zip',
        },
        {
          'name': 'tgwsproxy-0.5.2-macos.zip',
          'browser_download_url': '$base/tgwsproxy-0.5.2-macos.zip',
        },
        {'name': 'SHA256SUMS', 'browser_download_url': '$base/SHA256SUMS'},
      ],
    });
    expect(info.version, '0.5.2');
    expect(info.windowsUrl, endsWith('tgwsproxy-0.5.2-windows-x64.zip'));
    expect(info.apkUrl, endsWith('tgwsproxy-0.5.2.apk'));
    expect(info.sumsUrl, endsWith('/SHA256SUMS'));
  });

  test('parseRelease tolerates releases without platform assets', () {
    final info = UpdateChecker.parseRelease({
      'tag_name': 'v0.1.0',
      'html_url': 'https://github.com/waslost0/tgwsproxy/releases/tag/v0.1.0',
      'assets': const [],
    });
    expect(info.version, '0.1.0');
    expect(info.windowsUrl, isNull);
    expect(info.sumsUrl, isNull);
    expect(info.apkUrl, isNull);
  });
}
