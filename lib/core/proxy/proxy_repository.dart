// Purpose: Flutter-side client for the Android proxy service control channel.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:talker/talker.dart';
import 'package:url_launcher/url_launcher.dart';

import 'mac_proxy_engine.dart';
import 'proxy_models.dart';

/// Bridges the UI to the platform proxy backend: Kotlin `ProxyBridge` on
/// Android/iOS, or an in-process [MacProxyEngine] on macOS.
///
/// The constructor is intentionally side-effect free: widget tests can create
/// it without a platform channel. [init] is called from `main`.
class ProxyRepository extends ChangeNotifier {
  static const _channel = MethodChannel('com.example.tgwsproxy/proxy');
  static const _events = EventChannel('com.example.tgwsproxy/proxy_events');
  static const _menuChannel = MethodChannel(
    'com.whitetigersoft.tgwsproxy/menu',
  );

  ProxySnapshot state = const ProxySnapshot();
  Map<String, dynamic> settings = <String, dynamic>{};
  String link = '';
  String secret = '';
  String engineVersion = '0.1.0';
  String? error;
  bool secretMigrated = false;

  final Talker talker = Talker(settings: TalkerSettings(maxHistoryItems: 2000));
  StreamSubscription<dynamic>? _subscription;
  StreamSubscription<TalkerData>? _macLogs;
  MacProxyEngine? _mac;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // macOS has no platform channel: the Dart core runs in this isolate.
    if (Platform.isMacOS && !Platform.environment.containsKey('FLUTTER_TEST')) {
      final mac = MacProxyEngine();
      await mac.load();
      mac.onState = (map) {
        state = ProxySnapshot.fromMap(map);
        notifyListeners();
        _notifyMenu();
      };
      _macLogs = mac.logs.listen((data) {
        final name = data.logLevel?.name;
        final level = switch (name) {
          'error' => LogLevel.error,
          'warning' => LogLevel.warning,
          'debug' || 'verbose' => LogLevel.debug,
          'critical' => LogLevel.critical,
          _ => LogLevel.info,
        };
        talker.log(data.displayMessage, logLevel: level);
      });
      _mac = mac;
      _menuChannel.setMethodCallHandler(_handleMenuCall);
      await refresh();
      return;
    }

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
    if (_mac != null) {
      _applyBootstrap(ProxyBootstrap.fromMap(await _mac!.bootstrap()));
      return;
    }
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

  Future<void> start() => _mac != null ? _runMac(_mac!.start) : _run('start');

  Future<void> stop() => _mac != null ? _runMac(_mac!.stop) : _run('stop');

  Future<void> restart() =>
      _mac != null ? _runMac(_mac!.restart) : _run('restart');

  Future<void> updateSettings(Map<String, dynamic> next) async {
    if (_mac != null) {
      try {
        await _mac!.updateSettings(next);
      } catch (err) {
        error = err.toString();
      }
      await refresh();
      return;
    }
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
    if (_mac != null) {
      await _mac!.regenerateSecret();
      await refresh();
      return;
    }
    await _run('regenerateSecret');
    await refresh();
  }

  Future<void> acknowledgeSecretMigration() async {
    if (_mac != null) {
      secretMigrated = false;
      notifyListeners();
      return;
    }
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
    if (_mac != null) {
      try {
        await launchUrl(
          Uri.parse(_mac!.link()),
          mode: LaunchMode.externalApplication,
        );
      } catch (err) {
        error = err.toString();
        notifyListeners();
      }
      return;
    }
    try {
      await _channel.invokeMethod<void>('openInTelegram');
    } on PlatformException catch (err) {
      error = err.message ?? err.code;
      notifyListeners();
    }
  }

  Future<String> getSecret() async {
    if (_mac != null) {
      secret = _mac!.secret;
      notifyListeners();
      return secret;
    }
    final value = await _channel.invokeMethod<String>('getSecret');
    if (value != null) {
      secret = value;
      notifyListeners();
    }
    return secret;
  }

  Future<String> getProxyLink() async {
    if (_mac != null) return _mac!.link();
    final value = await _channel.invokeMethod<String>('getProxyLink');
    return value ?? link;
  }

  Future<String> exportSettings() async {
    if (_mac != null) return _mac!.exportSettings();
    final value = await _channel.invokeMethod<String>('exportSettings');
    return value ?? '';
  }

  Future<bool> importSettings(String raw) async {
    if (_mac != null) {
      final ok = await _mac!.importSettings(raw);
      await refresh();
      return ok;
    }
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
    if (_mac != null) return _mac!.diagnostics();
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'getDiagnostics',
    );
    return raw == null ? <String, dynamic>{} : Map<String, dynamic>.from(raw);
  }

  Future<void> openBatterySettings() async {
    if (_mac != null) return;
    try {
      await _channel.invokeMethod<void>('openBatterySettings');
    } on PlatformException catch (err) {
      error = err.message ?? err.code;
      notifyListeners();
    }
  }

  Future<void> _runMac(Future<void> Function() action) async {
    error = null;
    try {
      await action();
    } catch (err) {
      error = err.toString();
    }
    await refresh();
  }

  Future<dynamic> _handleMenuCall(MethodCall call) async {
    switch (call.method) {
      case 'toggle':
        if (state.running) {
          await stop();
        } else {
          await start();
        }
      case 'openTelegram':
        await openInTelegram();
      case 'sync':
        _notifyMenu();
    }
    return null;
  }

  void _notifyMenu() {
    final mac = _mac;
    if (mac == null) return;
    unawaited(
      _menuChannel
          .invokeMethod<void>('state', <String, dynamic>{
            'running': state.running,
            'starting': state.starting,
            'port': state.port,
            'link': link.isNotEmpty ? link : mac.link(),
          })
          .catchError((_) {}),
    );
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
    _notifyMenu();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _macLogs?.cancel();
    final mac = _mac;
    if (mac != null) {
      _menuChannel.setMethodCallHandler(null);
      unawaited(mac.dispose());
    }
    super.dispose();
  }
}
