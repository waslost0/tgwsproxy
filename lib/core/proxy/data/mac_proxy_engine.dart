// Purpose: runs the Dart proxy core in-process for the macOS build.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:talker/talker.dart';
import 'package:tg_proxy_core/tg_proxy_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/proxy_backend.dart';
import '../domain/proxy_models.dart';

/// macOS counterpart of the Kotlin service: settings live in a JSON file next
/// to `app.db`, and the relay runs on the main isolate.
class MacProxyEngine implements ProxyBackend {
  static const _menuChannel = MethodChannel(
    'com.whitetigersoft.tgwsproxy/menu',
  );

  bool _menuHandlerSet = false;

  MacProxyEngine({this.directory}) {
    _logSub = proxyTalker.stream.listen((data) {
      _add({
        'type': 'log',
        'line': data.displayMessage,
        'level': data.logLevel?.name,
      });
    });
  }

  final String? directory;

  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<TalkerData>? _logSub;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  ProxyEngine? _engine;
  Timer? _statsTimer;
  File? _file;
  bool _starting = false;
  String? _error;

  static const _legacySecret = 'e6472c7872a569823465f0186d4e62b0';

  final Map<String, dynamic> _settings = <String, dynamic>{
    'host': '127.0.0.1',
    'port': 1443,
    'dcRedirects': <String, String>{
      '2': '149.154.167.220',
      '4': '149.154.167.220',
    },
    'poolSize': 4,
    'cfproxyEnabled': true,
    'cfUserDomains': <String>[],
    'cfWorkerDomains': <String>[],
    'cfWorkerEnabled': false,
    'fakeTlsDomain': '',
    'forceTestDc': false,
    'noSecure': true,
    'proxyProtocol': false,
    'botApiEnabled': false,
    'botApiPort': 8081,
    'autoStart': false,
    'checkUpdates': true,
    'settingsVersion': 1,
    'platform': 'macos',
  };

  String _secret = '';

  String get secret => _secret;
  bool get isRunning => _engine?.isRunning == true;

  Future<void> load() async {
    final override = directory;
    final dir = override != null
        ? Directory(override)
        : await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    _file = File(p.join(dir.path, 'proxy_settings.json'));
    if (await _file!.exists()) {
      var version = 0;
      try {
        final raw = jsonDecode(await _file!.readAsString());
        if (raw is Map) {
          version = _asInt(raw['settingsVersion']) ?? 0;
          for (final entry in raw.entries) {
            if (entry.key == 'secret') continue;
            if (_settings.containsKey(entry.key)) {
              _settings[entry.key] = entry.value;
            }
          }
          _secret = raw['secret']?.toString() ?? '';
        }
      } catch (_) {
        // A corrupt file is replaced with defaults below.
      }
      // Desktop upstream works over plain HTTP; TLS to Cloudflare is blocked
      // on many ISPs. Existing macOS settings keep the old insecure default.
      if (version < 1) {
        _settings['noSecure'] = true;
        _settings['settingsVersion'] = 1;
        await _save();
      }
    }
    final valid =
        _secret.length == 32 &&
        _secret.codeUnits.every(_isHex) &&
        _secret != _legacySecret;
    if (!valid) {
      _secret = _generateSecret();
      await _save();
    }
  }

  @override
  Future<void> start() async {
    if (isRunning) return;
    _starting = true;
    _error = null;
    _emit();
    final engine = ProxyEngine(config: _config());
    try {
      await engine.start();
      _engine = engine;
      _statsTimer?.cancel();
      _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) => _emit());
    } catch (error) {
      _error = 'Не удалось запустить прокси: $error';
      rethrow;
    } finally {
      _starting = false;
      _emit();
    }
  }

  @override
  Future<void> stop() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    final engine = _engine;
    _engine = null;
    if (engine != null) await engine.stop();
    _emit();
  }

  @override
  Future<void> restart() async {
    await stop();
    await start();
  }

  @override
  Future<void> updateSettings(Map<String, dynamic> values) async {
    for (final entry in values.entries) {
      if (!_settings.containsKey(entry.key)) continue;
      final value = entry.value;
      switch (entry.key) {
        case 'host':
          if (_isValidHost(value.toString())) _settings['host'] = value;
        case 'port':
          final port = _asInt(value);
          if (port != null && port >= 1 && port <= 65535) {
            _settings['port'] = port;
          }
        case 'botApiPort':
          final port = _asInt(value);
          if (port != null && port >= 1 && port <= 65535) {
            _settings['botApiPort'] = port;
          }
        case 'poolSize':
          final size = _asInt(value);
          if (size != null) _settings['poolSize'] = size.clamp(1, 16);
        case 'dcRedirects':
          final redirects = _stringMap(value);
          if (redirects.isNotEmpty) _settings['dcRedirects'] = redirects;
        case 'cfUserDomains':
        case 'cfWorkerDomains':
          _settings[entry.key] = _stringList(value);
        case 'fakeTlsDomain':
          _settings['fakeTlsDomain'] = value.toString().trim();
        default:
          if (value is bool) _settings[entry.key] = value;
      }
    }
    await _save();
    if (isRunning) await restart();
    _emit();
  }

  @override
  Future<String> regenerateSecret() async {
    _secret = _generateSecret();
    await _save();
    if (isRunning) await restart();
    _emit();
    return _secret;
  }

  @override
  Future<ProxyBootstrap> bootstrap() async => ProxyBootstrap(
    state: ProxySnapshot.fromMap(_state()),
    settings: _publicSettings(),
    link: link(),
    secret: _secret,
    engineVersion: 'dart-macos',
  );

  Map<String, dynamic> _publicSettings() => {
    for (final entry in _settings.entries)
      if (entry.key != 'secret') entry.key: entry.value,
  };

  Map<String, dynamic> _state() {
    final stats = _engine?.statsSnapshot;
    return {
      'running': isRunning,
      'starting': _starting,
      'host': _settings['host'],
      'port': _engine?.port ?? _settings['port'],
      'botApiPort': _engine?.botApiPort ?? _settings['botApiPort'],
      'botApiError': _engine?.botApiError,
      'activeConnections': stats?.active ?? 0,
      'totalConnections': stats?.total ?? 0,
      'bytesUp': stats?.bytesUp ?? 0,
      'bytesDown': stats?.bytesDown ?? 0,
      'ws': stats?.ws ?? 0,
      'cf': stats?.cf ?? 0,
      'tcpFallback': stats?.tcpFallback ?? 0,
      'error': _error,
      'coreVersion': 'dart-macos',
    };
  }

  void _emit() => _add({'type': 'state', ..._state()});

  void _add(Map<String, dynamic> event) {
    if (!_events.isClosed) _events.add(event);
  }

  String link() {
    final host = _settings['host'];
    final port = _engine?.port ?? _settings['port'];
    final domain = _settings['fakeTlsDomain']?.toString() ?? '';
    final prefix = domain.isEmpty
        ? 'dd$_secret'
        : 'ee$_secret${utf8.encode(domain).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    return 'tg://proxy?server=$host&port=$port&secret=$prefix';
  }

  @override
  Future<String> exportSettings() async => jsonEncode(_publicSettings());

  @override
  Future<String> getSecret() async => _secret;

  @override
  Future<String> getProxyLink() async => link();

  @override
  Future<void> openInTelegram() async {
    await launchUrl(Uri.parse(link()), mode: LaunchMode.externalApplication);
  }

  @override
  Future<void> openBatterySettings() async {}

  @override
  Future<void> pushMenuState(Map<String, dynamic> state) async {
    _ensureMenuHandler();
    try {
      await _menuChannel.invokeMethod<void>('state', state);
    } on MissingPluginException {
      // Tests and non-macOS hosts have no menu channel.
    }
  }

  void _ensureMenuHandler() {
    if (_menuHandlerSet) return;
    _menuHandlerSet = true;
    _menuChannel.setMethodCallHandler(_handleMenuCall);
  }

  Future<dynamic> _handleMenuCall(MethodCall call) async {
    switch (call.method) {
      case 'toggle':
        _add(const <String, dynamic>{'type': 'menu', 'action': 'toggle'});
      case 'openTelegram':
        _add(const <String, dynamic>{'type': 'menu', 'action': 'openTelegram'});
      case 'sync':
        _emit();
    }
    return null;
  }

  @override
  Future<void> acknowledgeSecretMigration() async {}
  @override
  Future<bool> importSettings(String raw) async {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return false;
      await updateSettings(
        decoded.map((key, value) => MapEntry('$key', value)),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Map<String, dynamic>> getDiagnostics() async {
    final info = await PackageInfo.fromPlatform();
    return {
      'version': info.version,
      'platform': 'macOS ${Platform.operatingSystemVersion}',
      'state': _state(),
    };
  }

  ProxyConfig _config() => ProxyConfig.fromJson({
    'host': _settings['host'],
    'port': _settings['port'],
    'secret': _secret,
    'dcRedirects': _settings['dcRedirects'],
    'poolSize': _settings['poolSize'],
    'cfproxy': _settings['cfproxyEnabled'],
    'cfproxyUserDomains': _settings['cfUserDomains'],
    'cfproxyWorkerDomains': _settings['cfWorkerDomains'],
    'cfWorkerEnabled': _settings['cfWorkerEnabled'],
    'fakeTlsDomain': _settings['fakeTlsDomain'],
    'forceTestDc': _settings['forceTestDc'],
    'disableSecure': _settings['noSecure'],
    'proxyProtocol': _settings['proxyProtocol'],
    'botApiEnabled': _settings['botApiEnabled'],
    'botApiPort': _settings['botApiPort'],
  });

  Future<void> _save() async {
    final file = _file;
    if (file == null) return;
    await file.writeAsString(
      jsonEncode({..._publicSettings(), 'secret': _secret}),
    );
  }

  @override
  Future<void> dispose() async {
    if (_menuHandlerSet) _menuChannel.setMethodCallHandler(null);
    _logSub?.cancel();
    _logSub = null;
    await stop();
    await _events.close();
  }

  static String _generateSecret() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  static bool _isHex(int code) =>
      (code >= 48 && code <= 57) ||
      (code >= 97 && code <= 102) ||
      (code >= 65 && code <= 70);

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static bool _isValidHost(String value) {
    if (value == 'localhost' || value == '0.0.0.0') return true;
    final parts = value.split('.');
    if (parts.length != 4) return false;
    for (final part in parts) {
      final number = int.tryParse(part);
      if (number == null || number < 0 || number > 255) return false;
    }
    return true;
  }

  static List<String> _stringList(Object? value) {
    if (value is List) {
      return value
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList();
    }
    return value
        .toString()
        .split(RegExp(r'[,;\s]+'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  static Map<String, String> _stringMap(Object? value) {
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        if (int.tryParse('${entry.key}') != null &&
            entry.value.toString().trim().isNotEmpty)
          '${entry.key}': entry.value.toString().trim(),
    };
  }
}
