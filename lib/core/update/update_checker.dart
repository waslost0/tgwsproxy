// Purpose: checks the latest GitHub release without embedding credentials.
import 'dart:convert';

import 'package:http/http.dart' as http;

class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.pageUrl,
    this.apkUrl,
    this.windowsUrl,
    this.sumsUrl,
  });

  final String version;
  final String pageUrl;
  final String? apkUrl;

  /// `tgwsproxy-<version>-windows-x64.zip` from the release assets.
  final String? windowsUrl;

  /// `SHA256SUMS` next to the release assets.
  final String? sumsUrl;
}

class UpdateCheckException implements Exception {
  const UpdateCheckException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The repository is public, so the latest GitHub release is readable without
/// credentials. The UI falls back to the releases page on errors.
class UpdateChecker {
  static const repository = 'waslost0/tgwsproxy';
  static const releasesPage = 'https://github.com/$repository/releases/latest';
  static const _downloadPrefix =
      'https://github.com/$repository/releases/download/';

  /// Only release assets served from this repository may be opened.
  static bool isOfficialDownload(String url) => url.startsWith(_downloadPrefix);

  /// Extracts the SHA-256 for [assetName] from a `SHA256SUMS` body.
  static String? parseSha256(String sums, String assetName) {
    for (final line in const LineSplitter().convert(sums)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2 && parts.last == assetName) {
        return parts.first.toLowerCase();
      }
    }
    return null;
  }

  static Future<ReleaseInfo> latest() async {
    final response = await http
        .get(
          Uri.parse('https://api.github.com/repos/$repository/releases/latest'),
          headers: const {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'tgwsproxy',
          },
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode == 404) {
      throw const UpdateCheckException('На GitHub пока нет релизов.');
    }
    if (response.statusCode != 200) {
      throw UpdateCheckException('GitHub ответил ${response.statusCode}.');
    }

    final raw = jsonDecode(response.body);
    if (raw is! Map) {
      throw const UpdateCheckException('Некорректный ответ GitHub.');
    }
    return parseRelease(raw);
  }

  /// Exposed for tests: picks the platform assets out of the release JSON.
  static ReleaseInfo parseRelease(Map raw) {
    final tag = raw['tag_name']?.toString() ?? '';
    final page = raw['html_url']?.toString() ?? releasesPage;
    String? apk;
    String? windows;
    String? sums;
    final assets = raw['assets'];
    if (assets is List) {
      for (final asset in assets) {
        if (asset is! Map) continue;
        final name = asset['name']?.toString() ?? '';
        final url = asset['browser_download_url']?.toString();
        if (url == null) continue;
        final lower = name.toLowerCase();
        if (lower.endsWith('.apk')) apk ??= url;
        if (lower.endsWith('windows-x64.zip')) windows ??= url;
        if (name == 'SHA256SUMS') sums ??= url;
      }
    }
    return ReleaseInfo(
      version: tag.replaceFirst(RegExp(r'^v'), ''),
      pageUrl: page,
      apkUrl: apk,
      windowsUrl: windows,
      sumsUrl: sums,
    );
  }

  static bool isNewer(String latest, String current) {
    final a = _parts(latest);
    final b = _parts(current);
    final length = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final left = i < a.length ? a[i] : 0;
      final right = i < b.length ? b[i] : 0;
      if (left != right) return left > right;
    }
    return false;
  }

  static List<int> _parts(String version) {
    return version
        .split(RegExp(r'[.+-]'))
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
  }
}
