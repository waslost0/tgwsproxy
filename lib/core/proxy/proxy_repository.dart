// Purpose: Flutter-side client for the Android proxy service control channel.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:talker/talker.dart';

import 'proxy_models.dart';

/// Bridges the UI to Kotlin `ProxyBridge`.
///
/// The constructor is intentionally side-effect free: widget tests can create
/// it without a platform channel. [init] is called from `main`.
class ProxyRepository extends ChangeNotifier {
  static const _channel = MethodChannel('com.example.tgwsproxy/proxy');
  static const _events = EventChannel('com.example.tgwsproxy/proxy_events');

  ProxySnapshot state = const ProxySnapshot();
  Map<String, dynamic> settings = <String, dynamic>{};
  String link = '';
  String secret = '';
  String engineVersion = '0.1.0';
  String? error;
  bool secretMigrated = false;

  final Talker talker = Talker(settings: TalkerSettings(maxHistoryItems: 2000));
  StreamSubscription<dynamic>? _subscription;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // The event stream carries state/stats updates while the service runs.
    _subscription = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object err) {
        error = err.toString();
        notifyListeners();
      },
    );
    await refresh();
  }

  Future<void> refresh() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getBootstrap',
      );
      if (raw == null) return;
      _applyBootstrap(ProxyBootstrap.fromMap(raw));
    } on MissingPluginException {
      // Desktop/widget tests have no Android bridge; keep the local defaults.
    } on PlatformException catch (err) {
      error = err.message ?? err.code;
      notifyListeners();
    }
  }

  Future<void> start() => _run('start');

  Future<void> stop() => _run('stop');

  Future<void> restart() => _run('restart');

  Future<void> updateSettings(Map<String, dynamic> next) async {
    try {
      await _channel.invokeMethod<void>('updateSettings', next);
      settings = Map<String, dynamic>.from(next);
      notifyListeners();
      await refresh();
    } on PlatformException catch (err) {
      error = err.message ?? err.code;
      notifyListeners();
    }
  }

  Future<void> regenerateSecret() async {
    await _run('regenerateSecret');
    await refresh();
  }

  Future<void> acknowledgeSecretMigration() async {
    try {
      await _channel.invokeMethod<void>('acknowledgeSecretMigration');
    } on MissingPluginException {
      // Android has no migration state.
    } on PlatformException catch (err) {
      error = err.message ?? err.code;
      notifyListeners();
      return;
    }
    secretMigrated = false;
    notifyListeners();
  }

  Future<void> openInTelegram() async {
    try {
      await _channel.invokeMethod<void>('openInTelegram');
    } on PlatformException catch (err) {
      error = err.message ?? err.code;
      notifyListeners();
    }
  }

  Future<String> getSecret() async {
    final value = await _channel.invokeMethod<String>('getSecret');
    if (value != null) {
      secret = value;
      notifyListeners();
    }
    return secret;
  }

  Future<String> getProxyLink() async {
    final value = await _channel.invokeMethod<String>('getProxyLink');
    return value ?? link;
  }

  Future<String> exportSettings() async {
    final value = await _channel.invokeMethod<String>('exportSettings');
    return value ?? '';
  }

  Future<bool> importSettings(String raw) async {
    try {
      final ok = await _channel.invokeMethod<bool>('importSettings', raw);
      await refresh();
      return ok ?? false;
    } on PlatformException catch (err) {
      error = err.message ?? err.code;
      notifyListeners();
      return false;
    }
  }

  Future<Map<String, dynamic>> getDiagnostics() async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'getDiagnostics',
    );
    return raw == null ? <String, dynamic>{} : Map<String, dynamic>.from(raw);
  }

  Future<void> openBatterySettings() async {
    try {
      await _channel.invokeMethod<void>('openBatterySettings');
    } on PlatformException catch (err) {
      error = err.message ?? err.code;
      notifyListeners();
    }
  }

  Future<void> _run(String method) async {
    error = null;
    state = ProxySnapshot(
      running: method == 'stop' ? false : state.running,
      starting: method != 'stop',
      host: state.host,
      port: state.port,
      coreVersion: state.coreVersion,
    );
    notifyListeners();
    try {
      await _channel.invokeMethod<void>(method);
      await refresh();
    } on MissingPluginException {
      state = const ProxySnapshot();
      notifyListeners();
    } on PlatformException catch (err) {
      error = err.message ?? err.code;
      state = ProxySnapshot(
        host: state.host,
        port: state.port,
        error: error,
        coreVersion: state.coreVersion,
      );
      notifyListeners();
    }
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final type = event['type'];
    if (type == 'state') {
      // Kotlin sends a flat map with the `type` discriminator plus state
      // fields; older bridge versions nested it under `state`.
      final raw = event['state'] is Map ? event['state'] : event;
      if (raw is Map) {
        state = ProxySnapshot.fromMap(raw);
        notifyListeners();
      }
    } else if (type == 'log') {
      _onLog(event);
    } else if (type == 'error') {
      error = event['message'] as String?;
      notifyListeners();
    }
  }

  void _onLog(Map event) {
    final line = event['line'] as String? ?? '';
    if (line.isEmpty) return;
    final level = switch ((event['level'] as String?)?.toLowerCase()) {
      'error' => LogLevel.error,
      'warning' => LogLevel.warning,
      'debug' || 'verbose' => LogLevel.debug,
      'critical' => LogLevel.critical,
      _ => LogLevel.info,
    };
    talker.log(line, logLevel: level);
  }

  void _applyBootstrap(ProxyBootstrap bootstrap) {
    state = bootstrap.state;
    settings = bootstrap.settings;
    link = bootstrap.link;
    secret = bootstrap.secret;
    engineVersion = bootstrap.engineVersion;
    secretMigrated = bootstrap.secretMigrated;
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
