// Purpose: Engine configuration model and DC IP helpers.
import '../constants.dart';

/// Runtime configuration for the pure-Dart proxy engine.
///
/// Field names follow the desktop/Android config where possible so the
/// same JSON can be imported without a translation table.
class ProxyConfig {
  const ProxyConfig({
    this.port = 1443,
    this.host = '127.0.0.1',
    this.secret = '',
    this.dcRedirects = const {
      2: '149.154.167.220',
      4: '149.154.167.220',
    },
    this.bufferSize = 256 * 1024,
    this.poolSize = 4,
    this.fallbackCfproxy = true,
    this.cfproxyUserDomains = const [],
    this.cfproxyWorkerDomains = const [],
    this.cfWorkerEnabled = false,
    this.cfproxyH2Media = false,
    this.disableSecure = false,
    this.fakeTlsDomain = '',
    this.proxyProtocol = false,
    this.forceTestDc = false,
    this.botApiEnabled = true,
    this.botApiPort = 8081,
  });

  final int port;
  final String host;
  final String secret;
  final Map<int, String> dcRedirects;

  /// Kept for config compatibility. `dart:io` cannot change SO_RCVBUF/SNDBUF.
  final int bufferSize;
  final int poolSize;
  final bool fallbackCfproxy;
  final List<String> cfproxyUserDomains;
  final List<String> cfproxyWorkerDomains;

  /// Workers are an explicit opt-in: the shared CF pool usually has lower
  /// latency than a free Worker's Telegram egress.
  final bool cfWorkerEnabled;

  /// HTTP/2 media transport is a later phase. The field is accepted now so
  /// persisted settings remain forward-compatible.
  final bool cfproxyH2Media;
  final bool disableSecure;
  final String fakeTlsDomain;
  final bool proxyProtocol;
  final bool forceTestDc;
  final bool botApiEnabled;
  final int botApiPort;

  bool get h2Enabled => false;

  /// Parses the JSON produced by the Android settings layer.
  ///
  /// Unknown keys are ignored so a newer Kotlin build can add fields without
  /// breaking an older bundled engine. `bufferSizeKb`/`bufKb` are accepted for
  /// import compatibility but cannot change the OS socket buffers.
  factory ProxyConfig.fromJson(Map<String, dynamic> json) {
    final redirects = <int, String>{};
    final rawRedirects = json['dcRedirects'] ?? json['dc_ip'];
    if (rawRedirects is Map) {
      for (final entry in rawRedirects.entries) {
        final dc = int.tryParse('${entry.key}');
        final ip = entry.value?.toString();
        if (dc != null && ip != null && ip.isNotEmpty) redirects[dc] = ip;
      }
    }
    final bufKb = json['bufferSizeKb'] ?? json['bufKb'] ?? json['buf_kb'];
    return ProxyConfig(
      port: (json['port'] as num?)?.toInt() ?? 1443,
      host: json['host']?.toString() ?? '127.0.0.1',
      secret: json['secret']?.toString() ?? '',
      dcRedirects: redirects.isEmpty
          ? const {2: '149.154.167.220', 4: '149.154.167.220'}
          : redirects,
      bufferSize: bufKb is num ? bufKb.toInt() * 1024 : 256 * 1024,
      poolSize: ((json['poolSize'] ?? json['pool_size']) as num?)?.toInt() ?? 4,
      fallbackCfproxy:
          (json['fallbackCfproxy'] ?? json['cfproxy']) as bool? ?? true,
      cfproxyUserDomains: _domainList(
        json['cfproxyUserDomains'] ?? json['cfproxy_user_domain'],
      ),
      cfproxyWorkerDomains: _domainList(
        json['cfproxyWorkerDomains'] ?? json['cfproxy_worker_domain'],
      ),
      cfWorkerEnabled:
          (json['cfWorkerEnabled'] ?? json['cf_worker_enabled']) as bool? ??
              false,
      cfproxyH2Media: (json['cfproxyH2Media'] ?? json['h2']) as bool? ?? false,
      disableSecure: (json['disableSecure'] ??
              json['no_secure'] ??
              json['noSecure']) as bool? ??
          false,
      fakeTlsDomain:
          (json['fakeTlsDomain'] ?? json['fake_tls_domain'])?.toString() ?? '',
      proxyProtocol:
          (json['proxyProtocol'] ?? json['proxy_protocol']) as bool? ?? false,
      forceTestDc:
          (json['forceTestDc'] ?? json['force_test_dc']) as bool? ?? false,
      botApiEnabled:
          (json['botApiEnabled'] ?? json['bot_api']) as bool? ?? true,
      botApiPort:
          ((json['botApiPort'] ?? json['bot_api_port']) as num?)?.toInt() ??
              8081,
    );
  }

  /// Accepts both the JSON list and desktop comma/semicolon/space-separated
  /// string forms so a settings export can be pasted into the engine.
  static List<String> _domainList(Object? value) {
    if (value is String) {
      return value
          .split(RegExp(r'[,;\s]+'))
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    if (value is! List) return const [];
    return value
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  String? redirectIp(int dc) => dcRedirects[dc];

  String? fallbackIp(int dc, {required bool test}) =>
      (test ? dcTestIps : dcDefaultIps)[dc];
}
