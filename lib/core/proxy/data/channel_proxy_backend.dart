import 'dart:io';

import 'package:flutter/services.dart';

import '../domain/proxy_backend.dart';
import '../domain/proxy_models.dart';

/// Proxy control over the platform channels used by Android and iOS.
class ChannelProxyBackend implements ProxyBackend {
  static const _methods = MethodChannel('com.example.tgwsproxy/proxy');
  static const _events = EventChannel('com.example.tgwsproxy/proxy_events');

  @override
  Stream<Map<String, dynamic>> get events =>
      _events.receiveBroadcastStream().map(
        (event) => event is Map
            ? Map<String, dynamic>.from(event)
            : <String, dynamic>{},
      );

  @override
  Future<ProxyBootstrap> bootstrap() async {
    final raw = await _methods.invokeMethod<Map<dynamic, dynamic>>(
      'getBootstrap',
    );
    if (raw == null) {
      // Widget tests and hosts without the native side still need a backend.
      const platform =
          bool.fromEnvironment('flutter.inspector.structuredErrors')
          ? 'flutter_test'
          : null;
      return ProxyBootstrap(
        state: const ProxySnapshot(),
        settings: <String, dynamic>{'platform': platform ?? _platformName()},
        link: '',
        secret: '',
        engineVersion: '0.1.0',
      );
    }
    return ProxyBootstrap.fromMap(raw);
  }

  static String _platformName() {
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.environment.containsKey('FLUTTER_TEST')) return 'test';
    return 'android';
  }

  @override
  Future<void> start() => _invoke('start');

  @override
  Future<void> stop() => _invoke('stop');

  @override
  Future<void> restart() => _invoke('restart');

  @override
  Future<void> updateSettings(Map<String, dynamic> values) =>
      _invoke('updateSettings', values);

  @override
  Future<String> regenerateSecret() async =>
      await _methods.invokeMethod<String>('regenerateSecret') ?? '';

  @override
  Future<void> acknowledgeSecretMigration() =>
      _invoke('acknowledgeSecretMigration');

  @override
  Future<void> openInTelegram() => _invoke('openInTelegram');

  @override
  Future<void> openBatterySettings() => _invoke('openBatterySettings');

  @override
  Future<String> getSecret() async =>
      await _methods.invokeMethod<String>('getSecret') ?? '';

  @override
  Future<String> getProxyLink() async =>
      await _methods.invokeMethod<String>('getProxyLink') ?? '';

  @override
  Future<String> exportSettings() async =>
      await _methods.invokeMethod<String>('exportSettings') ?? '';

  @override
  Future<bool> importSettings(String raw) async =>
      await _methods.invokeMethod<bool>('importSettings', raw) ?? false;

  @override
  Future<Map<String, dynamic>> getDiagnostics() async {
    final raw = await _methods.invokeMethod<Map<dynamic, dynamic>>(
      'getDiagnostics',
    );
    return raw == null ? <String, dynamic>{} : Map<String, dynamic>.from(raw);
  }

  Future<void> _invoke(String method, [Object? arguments]) async {
    await _methods.invokeMethod<void>(method, arguments);
  }

  @override
  Future<void> pushMenuState(Map<String, dynamic> state) async {}

  @override
  Future<void> dispose() async {}
}
