// Purpose: Lifecycle facade that wires the relay server, transports and Bot API.
import 'dart:async';
import 'dart:typed_data';

import '../botapi/bot_api_proxy.dart';
import '../config/proxy_config.dart';
import '../stats/proxy_stats.dart';
import '../transport/cf_domains.dart';
import '../transport/raw_websocket.dart';
import '../transport/transport_router.dart';
import '../proxy/proxy_server.dart';

/// Filesystem locations supplied by the Android service.
class EnginePaths {
  const EnginePaths({
    required this.cacheDir,
    required this.logDir,
    required this.filesDir,
  });

  final String cacheDir;
  final String logDir;
  final String filesDir;

  factory EnginePaths.fromJson(Map<String, dynamic> json) => EnginePaths(
        cacheDir: json['cacheDir'] as String? ?? '',
        logDir: json['logDir'] as String? ?? '',
        filesDir: json['filesDir'] as String? ?? '',
      );
}

/// Opens a Bot API tunnel through a configured Cloudflare Worker.
///
/// The worker accepts `/apiws?dst=<host>` and relays raw TLS bytes; Bot API
/// does not use MTProto re-encryption, so this is a plain byte pipe.
BotApiConnector botApiCfConnector(ProxyConfig config) {
  return (host, port) async {
    final workerDomains = config.cfproxyWorkerDomains;
    if (workerDomains.isEmpty) {
      throw StateError('No CF worker domain configured for Bot API');
    }
    Object? lastError;
    for (final domain in workerDomains) {
      try {
        return await RawWebSocket.connect(
          domain,
          domain,
          secure: !config.disableSecure,
          path: Uri(
            path: '/apiws',
            queryParameters: {'dst': host},
          ).toString(),
        );
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError('Bot API worker unavailable: $lastError');
  };
}

/// Owns everything that lives inside the headless proxy engine.
///
/// The Android service calls [start] / [stop]; the Dart channel entrypoint
/// forwards those calls and reads [statsSnapshot] for notifications and UI.
class ProxyEngine {
  ProxyEngine({required this.config, ProxyStats? stats})
      : stats = stats ?? ProxyStats();

  final ProxyConfig config;
  final ProxyStats stats;

  CfDomainManager? _domains;
  TransportRouter? _router;
  ProxyServer? _server;
  BotApiProxy? _botApi;

  int? _port;
  int? _botApiPort;
  String? _botApiError;

  bool get isRunning => _server != null;
  int? get port => _port;
  int? get botApiPort => _botApiPort;
  String? get botApiError => _botApiError;
  StatsSnapshot get statsSnapshot => stats.snapshot();

  /// Binds the MTProto listener and, when configured, the Bot API listener.
  ///
  /// Pool warmup is deliberately not awaited: the foreground service must be
  /// able to show "running" even when the network is temporarily unavailable.
  Future<int> start() async {
    if (_server != null) return _port!;

    final balancer = CfDomainBalancer();
    final domains = CfDomainManager(
      balancer: balancer,
      userDomains: config.cfproxyUserDomains,
    );
    domains.start();

    final router =
        TransportRouter(config: config, stats: stats, balancer: balancer);
    unawaited(router.warmup());

    final server = ProxyServer(config: config, stats: stats, router: router);
    int boundPort;
    try {
      boundPort = await server.start();
    } catch (_) {
      await domains.dispose();
      await router.dispose();
      rethrow;
    }

    _domains = domains;
    _router = router;
    _server = server;
    _port = boundPort;

    if (config.botApiEnabled) {
      try {
        final bot = BotApiProxy(
          connector: botApiCfConnector(config),
          port: config.botApiPort,
        );
        _botApiPort = await bot.start();
        _botApi = bot;
      } catch (error) {
        // Bot API is optional; a bind/worker failure must not stop Telegram.
        _botApiError = error.toString();
      }
    }
    return boundPort;
  }

  Future<void> stop() async {
    final bot = _botApi;
    _botApi = null;
    _botApiPort = null;
    if (bot != null) await bot.stop();

    final server = _server;
    _server = null;
    _port = null;
    if (server != null) await server.stop();

    final domains = _domains;
    _domains = null;
    if (domains != null) await domains.dispose();

    final router = _router;
    _router = null;
    if (router != null) await router.dispose();
  }

  /// Kept for the engine channel; the link itself is built by Kotlin because
  /// the secret must not leave the Keystore-backed store.
  Uint8List? get secretBytes {
    final value = config.secret;
    if (value.length != 32) return null;
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = int.parse(value.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
