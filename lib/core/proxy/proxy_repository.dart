// Purpose: presentation facade over the platform proxy backends.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:talker/talker.dart';

import 'data/channel_proxy_backend.dart';
import 'data/mac_proxy_engine.dart';
import 'domain/proxy_backend.dart';
import 'domain/proxy_models.dart';

/// Single state holder the UI talks to.
///
/// Android/iOS use a [ChannelProxyBackend]; macOS runs [MacProxyEngine]
/// in-process. Tests may inject any [ProxyBackend].
class ProxyRepository extends ChangeNotifier {
  ProxyRepository({ProxyBackend? backend}) {
    _backend = backend;
  }

  static const _menuChannel = MethodChannel(
    'com.whitetigersoft.tgwsproxy/menu',
  );

  ProxyBackend? _backend;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  bool _initialized = false;

  ProxySnapshot state = const ProxySnapshot();
  Map<String, dynamic> settings = <String, dynamic>{};
  String link = '';
  String secret = '';
  String engineVersion = '0.1.0';
  String? error;
  bool secretMigrated = false;

  final Talker talker = Talker(settings: TalkerSettings(maxHistoryItems: 2000));

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    var backend = _backend;
    if (backend == null) {
      if (_isMacDesktop) {
        final mac = MacProxyEngine();
        await mac.load();
        backend = mac;
      } else {
        backend = ChannelProxyBackend();
      }
    }
    _backend = backend;

    _subscription = backend.events.listen(
      _onEvent,
      onError: (Object err) {
        error = err.toString();
        notifyListeners();
      },
    );
    if (backend is MacProxyEngine) {
      _menuChannel.setMethodCallHandler(_handleMenuCall);
    }
    await refresh();
  }

  bool get _isMacDesktop =>
      Platform.isMacOS && !Platform.environment.containsKey('FLUTTER_TEST');

  Future<void> refresh() async {
    try {
      final bootstrap = await _requireBackend().bootstrap();
      _applyBootstrap(bootstrap);
    } on MissingPluginException {
      // Widget tests and unsupported platforms keep local defaults.
    } on PlatformException catch (err) {
      error = err.message ?? err.code;
      notifyListeners();
    }
  }

  Future<void> start() => _run((backend) => backend.start());

  Future<void> stop() => _run((backend) => backend.stop(), stopping: true);

  Future<void> restart() => _run((backend) => backend.restart());

  Future<void> updateSettings(Map<String, dynamic> next) async {
    try {
      await _requireBackend().updateSettings(next);
      settings = <String, dynamic>{...settings, ...next};
      await refresh();
    } catch (err) {
      error = err.toString();
      notifyListeners();
    }
  }

  Future<void> regenerateSecret() async {
    await _run((backend) async {
      await backend.regenerateSecret();
    });
  }

  Future<void> acknowledgeSecretMigration() async {
    try {
      await _requireBackend().acknowledgeSecretMigration();
    } catch (err) {
      error = err.toString();
      notifyListeners();
      return;
    }
    secretMigrated = false;
    notifyListeners();
  }

  Future<void> openInTelegram() async {
    try {
      await _requireBackend().openInTelegram();
    } catch (err) {
      error = err.toString();
      notifyListeners();
    }
  }

  Future<String> getSecret() async {
    try {
      secret = await _requireBackend().getSecret();
      notifyListeners();
    } catch (err) {
      error = err.toString();
      notifyListeners();
    }
    return secret;
  }

  Future<String> getProxyLink() async {
    try {
      return await _requireBackend().getProxyLink();
    } catch (err) {
      error = err.toString();
      notifyListeners();
      return link;
    }
  }

  Future<String> exportSettings() async {
    try {
      return await _requireBackend().exportSettings();
    } catch (err) {
      error = err.toString();
      notifyListeners();
      return '';
    }
  }

  Future<bool> importSettings(String raw) async {
    try {
      final ok = await _requireBackend().importSettings(raw);
      await refresh();
      return ok;
    } catch (err) {
      error = err.toString();
      notifyListeners();
      return false;
    }
  }

  Future<Map<String, dynamic>> getDiagnostics() async {
    try {
      return await _requireBackend().getDiagnostics();
    } catch (err) {
      error = err.toString();
      notifyListeners();
      return <String, dynamic>{};
    }
  }

  Future<void> openBatterySettings() async {
    try {
      await _requireBackend().openBatterySettings();
    } catch (err) {
      error = err.toString();
      notifyListeners();
    }
  }

  ProxyBackend _requireBackend() {
    final backend = _backend;
    if (backend == null) {
      throw StateError('ProxyRepository.init() was not called');
    }
    return backend;
  }

  Future<void> _run(
    Future<void> Function(ProxyBackend backend) action, {
    bool stopping = false,
  }) async {
    error = null;
    state = ProxySnapshot(
      running: stopping ? false : state.running,
      starting: !stopping,
      host: state.host,
      port: state.port,
      coreVersion: state.coreVersion,
    );
    notifyListeners();
    try {
      await action(_requireBackend());
      await refresh();
    } on MissingPluginException {
      state = const ProxySnapshot();
      notifyListeners();
    } catch (err) {
      error = err.toString();
      state = ProxySnapshot(
        host: state.host,
        port: state.port,
        error: error,
        coreVersion: state.coreVersion,
      );
      notifyListeners();
    }
  }

  void _onEvent(Map<String, dynamic> event) {
    final type = event['type'];
    if (type == 'state') {
      final raw = event['state'] is Map ? event['state'] : event;
      state = ProxySnapshot.fromMap(raw as Map);
      notifyListeners();
      unawaited(_notifyMenu());
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
    unawaited(_notifyMenu());
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
        await _notifyMenu();
    }
    return null;
  }

  Future<void> _notifyMenu() async {
    final backend = _backend;
    if (backend is! MacProxyEngine) return;
    final proxyLink = link.isNotEmpty ? link : await backend.getProxyLink();
    try {
      await _menuChannel.invokeMethod<void>('state', <String, dynamic>{
        'running': state.running,
        'starting': state.starting,
        'port': state.port,
        'link': proxyLink,
      });
    } on MissingPluginException {
      // Tests and non-macOS hosts have no menu channel.
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    if (_backend is MacProxyEngine) {
      _menuChannel.setMethodCallHandler(null);
    }
    final backend = _backend;
    if (backend != null) unawaited(backend.dispose());
    super.dispose();
  }
}
