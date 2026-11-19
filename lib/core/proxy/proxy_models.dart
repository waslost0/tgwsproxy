// Purpose: immutable proxy state shared by the UI layer and MethodChannel codec.
import 'dart:convert';

/// Snapshot of the Android proxy service and its live counters.
class ProxySnapshot {
  const ProxySnapshot({
    this.running = false,
    this.starting = false,
    this.host = '127.0.0.1',
    this.port = 1443,
    this.botApiPort = 8081,
    this.botApiError,
    this.activeConnections = 0,
    this.totalConnections = 0,
    this.bytesUp = 0,
    this.bytesDown = 0,
    this.ws = 0,
    this.cf = 0,
    this.tcpFallback = 0,
    this.route,
    this.error,
    this.coreVersion = '0.1.0',
  });

  final bool running;
  final bool starting;
  final String host;
  final int port;
  final int botApiPort;
  final String? botApiError;
  final int activeConnections;
  final int totalConnections;
  final int bytesUp;
  final int bytesDown;
  final int ws;
  final int cf;
  final int tcpFallback;
  final String? route;
  final String? error;
  final String coreVersion;

  bool get busy => starting;

  /// The service reports counters independently; route is the most recent
  /// non-zero transport, used only for display.
  String get displayRoute {
    if (route != null && route!.isNotEmpty) return route!;
    if (cf > 0) return 'Cloudflare';
    if (ws > 0) return 'WebSocket';
    if (tcpFallback > 0) return 'TCP fallback';
    return '—';
  }

  factory ProxySnapshot.fromMap(Map<dynamic, dynamic> map) {
    int asInt(String key, int fallback) {
      final value = map[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      return fallback;
    }

    return ProxySnapshot(
      running: map['running'] == true,
      starting: map['starting'] == true,
      host: (map['host'] as String?) ?? '127.0.0.1',
      port: asInt('port', 1443),
      botApiPort: asInt('botApiPort', 8081),
      botApiError: map['botApiError'] as String?,
      activeConnections: asInt('activeConnections', 0),
      totalConnections: asInt('totalConnections', 0),
      bytesUp: asInt('bytesUp', 0),
      bytesDown: asInt('bytesDown', 0),
      ws: asInt('ws', 0),
      cf: asInt('cf', 0),
      tcpFallback: asInt('tcpFallback', 0),
      route: map['route'] as String?,
      error: map['error'] as String?,
      coreVersion: (map['coreVersion'] as String?) ?? '0.1.0',
    );
  }
}

/// Data returned by the service once, when the UI attaches.
class ProxyBootstrap {
  const ProxyBootstrap({
    required this.state,
    required this.settings,
    required this.link,
    required this.secret,
    required this.engineVersion,
  });

  final ProxySnapshot state;
  final Map<String, dynamic> settings;
  final String link;
  final String secret;
  final String engineVersion;

  factory ProxyBootstrap.fromMap(Map<dynamic, dynamic> map) {
    final rawSettings = map['settings'];
    return ProxyBootstrap(
      state: ProxySnapshot.fromMap(
        (map['state'] as Map?) ?? const <String, dynamic>{},
      ),
      settings: rawSettings is Map
          ? Map<String, dynamic>.from(rawSettings)
          : <String, dynamic>{},
      link: (map['link'] as String?) ?? '',
      secret: (map['secret'] as String?) ?? '',
      engineVersion: (map['engineVersion'] as String?) ?? '0.1.0',
    );
  }
}

/// Settings are stored by the Android service; the UI only passes a JSON map.
String encodeSettings(Map<String, dynamic> settings) => jsonEncode(settings);
