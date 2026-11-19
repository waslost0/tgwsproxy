// Purpose: headless Dart entrypoint for the foreground proxy service.
//
// This entrypoint is started by Kotlin in a separate FlutterEngine. It has no
// widgets, no plugins and no UI; it only owns ProxyEngine and speaks JSON over
// the engine MethodChannel.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:talker/talker.dart';
import 'package:tg_proxy_core/tg_proxy_core.dart';

const _channel = MethodChannel('com.example.tgwsproxy/engine');
StreamSubscription<dynamic>? _logSubscription;

@pragma('vm:entry-point')
void runProxyEngine() {
  debugPrint('TGWS proxy engine: binding');
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('TGWS proxy engine: binding ready');
  final host = _EngineHost();
  _channel.setMethodCallHandler(host.handle);
  // Kotlin waits for this signal before sending the first start command.
  unawaited(_channel.invokeMethod<void>('ready'));
  _forwardLogs();
  debugPrint('TGWS proxy engine: ready sent');
}

void _forwardLogs() {
  _logSubscription?.cancel();
  _logSubscription = proxyTalker.stream.listen((data) {
    final line = [
      data.displayMessage,
      data.displayException,
      data.displayStackTrace,
    ].where((part) => part.isNotEmpty).join(' ');
    unawaited(
      _channel
          .invokeMethod<void>('log', {
            'level': data.logLevel?.name ?? 'info',
            'title': data.title ?? 'proxy',
            'line': line,
            'time': data.time.toIso8601String(),
          })
          .catchError((_) {
            // Kotlin may not have attached the handler yet during startup.
          }),
    );
  });
}

class _EngineHost {
  ProxyEngine? _engine;
  ProxyConfig? _config;
  Timer? _statsTimer;

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'start':
        return _start(call.arguments as Map<Object?, Object?>);
      case 'stop':
        await _stop();
        return null;
      case 'getStats':
        return _engine?.isRunning == true
            ? _engine!.statsSnapshot.toJson()
            : null;
      case 'ping':
        return true;
      case 'probeCf':
        return _probeCf(call.arguments as Map<Object?, Object?>? ?? const {});
      case 'updateConfig':
        await _stop();
        return _start(call.arguments as Map<Object?, Object?>);
      default:
        throw MissingPluginException('Unknown engine method ${call.method}');
    }
  }

  Future<Map<String, Object?>> _start(Map<Object?, Object?> args) async {
    debugPrint('TGWS proxy engine: start requested');
    await _stop();

    // Kotlin serializes the config to JSON before crossing the channel; also
    // accept a map so tests and future callers can pass structured data.
    final rawConfig = args['config'];
    final configMap = rawConfig is String
        ? jsonDecode(rawConfig) as Map<String, dynamic>
        : Map<String, dynamic>.from(rawConfig as Map? ?? const {});
    final config = ProxyConfig.fromJson(configMap);
    _config = config;
    final engine = ProxyEngine(config: config);
    try {
      final port = await engine.start();
      debugPrint('TGWS proxy engine: listening on $port');
      _engine = engine;
      _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        final current = _engine;
        if (current == null || !current.isRunning) return;
        unawaited(
          _channel.invokeMethod<void>('stats', current.statsSnapshot.toJson()),
        );
      });
      final result = <String, Object?>{
        'port': port,
        'botApiPort': engine.botApiPort,
        'botApiError': engine.botApiError,
      };
      await _channel.invokeMethod<void>('started', result);
      return result;
    } catch (error) {
      await engine.stop();
      _engine = null;
      await _channel.invokeMethod<void>('error', {
        'code': 'ENGINE_START_FAILED',
        'message': error.toString(),
      });
      rethrow;
    }
  }

  Future<Map<String, Object?>> _probeCf(Map<Object?, Object?> args) async {
    final config = _config;
    final rawDomains = args['domains'];
    final domains = rawDomains is List
        ? rawDomains.map((value) => value.toString()).toList()
        : config?.cfproxyUserDomains ?? const <String>[];
    final dst = config?.fallbackIp(2, test: false) ?? '149.154.167.51';
    final result = await probeCf(domains: domains, dst: dst, dc: 2);
    return {
      'tls': result.tls,
      'plain': result.plain,
      'tlsBlocked': result.tlsBlocked,
    };
  }

  Future<void> _stop() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    _config = null;
    final engine = _engine;
    _engine = null;
    if (engine == null) return;
    try {
      await engine.stop();
      await _channel.invokeMethod<void>('stopped');
    } catch (error) {
      await _channel.invokeMethod<void>('error', {
        'code': 'ENGINE_STOP_FAILED',
        'message': error.toString(),
      });
    }
  }
}
