import 'proxy_models.dart';

/// Contract the presentation layer uses to control the proxy.
///
/// Android/iOS implement it over MethodChannel, macOS runs the Dart core
/// in-process. The facade ([ProxyRepository]) owns all UI state.
abstract class ProxyBackend {
  Stream<Map<String, dynamic>> get events;

  Future<ProxyBootstrap> bootstrap();

  Future<void> start();

  Future<void> stop();

  Future<void> restart();

  Future<void> updateSettings(Map<String, dynamic> values);

  Future<String> regenerateSecret();

  Future<void> acknowledgeSecretMigration();

  Future<void> openInTelegram();

  Future<void> openBatterySettings();

  Future<String> getSecret();

  Future<String> getProxyLink();

  Future<String> exportSettings();

  Future<bool> importSettings(String raw);

  Future<Map<String, dynamic>> getDiagnostics();

  Future<void> dispose();

  /// macOS-only hook: pushes the current state to the menu bar item.
  /// No-op on other platforms.
  Future<void> pushMenuState(Map<String, dynamic> state) async {}
}
