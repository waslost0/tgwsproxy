// Purpose: Settings view-model; persists UI preferences.
import '../../core/base/base_model.dart';
import '../../core/db/app_database.dart';
import '../../core/proxy/proxy_repository.dart';

class SettingsWM extends BaseModel {
  SettingsWM(this.db, this.proxy);

  final AppDatabase db;
  final ProxyRepository proxy;

  bool autoStart = true;
  bool checkUpdates = true;
  bool noSecure = false;
  bool cfWorkerEnabled = false;
  bool forceTestDc = false;
  bool proxyProtocol = false;
  bool botApiEnabled = true;
  int botApiPort = 8081;
  String host = '127.0.0.1';
  int port = 1443;
  int poolSize = 4;
  String cfDomain = '';
  String workerDomains = '';
  String fakeTlsDomain = '';
  bool botApiSupported = true;
  Map<int, String> dcRedirects = const {};
  bool loaded = false;

  Future<void> load() async {
    autoStart = (await db.read('auto_start')) != 'false';
    checkUpdates = (await db.read('check_updates')) != 'false';
    noSecure = proxy.settings['noSecure'] == true;
    cfWorkerEnabled = proxy.settings['cfWorkerEnabled'] == true;
    forceTestDc = proxy.settings['forceTestDc'] == true;
    proxyProtocol = proxy.settings['proxyProtocol'] == true;
    botApiSupported = proxy.settings['platform'] != 'ios';
    botApiEnabled = proxy.settings['botApiEnabled'] != false;
    botApiPort = (proxy.settings['botApiPort'] as num?)?.toInt() ?? 8081;
    host = proxy.settings['host']?.toString() ?? '127.0.0.1';
    port = (proxy.settings['port'] as num?)?.toInt() ?? 1443;
    poolSize = (proxy.settings['poolSize'] as num?)?.toInt() ?? 4;
    fakeTlsDomain = proxy.settings['fakeTlsDomain']?.toString() ?? '';
    final redirects = proxy.settings['dcRedirects'];
    dcRedirects = <int, String>{
      if (redirects is Map)
        for (final entry in redirects.entries)
          if (int.tryParse('${entry.key}') case final dc?)
            if (entry.value?.toString().isNotEmpty == true)
              dc: entry.value.toString(),
    };
    final domains = proxy.settings['cfUserDomains'];
    if (domains is List && domains.isNotEmpty) {
      cfDomain = domains.first.toString();
    }
    final workers = proxy.settings['cfWorkerDomains'];
    if (workers is List) {
      workerDomains = workers.join(', ');
    }
    loaded = true;
    notifyModelListeners();
  }

  Future<void> setCfDomain(String value) async {
    cfDomain = value.trim().toLowerCase();
    notifyModelListeners();
    await proxy.updateSettings({
      'cfUserDomains': cfDomain.isEmpty ? <String>[] : [cfDomain],
    });
  }

  Future<void> useSharedRoute() async {
    // AndMTProto on the same network reaches CF over plain port 80; TLS to
    // Cloudflare is DPI-blocked here. A stale user domain must also be
    // removed, otherwise the shared domain list is never used.
    noSecure = true;
    cfWorkerEnabled = false;
    cfDomain = '';
    notifyModelListeners();
    await proxy.updateSettings({
      'noSecure': true,
      'cfWorkerEnabled': false,
      'cfUserDomains': <String>[],
    });
  }

  Future<void> setCfWorkerEnabled(bool value) async {
    cfWorkerEnabled = value;
    notifyModelListeners();
    await proxy.updateSettings({'cfWorkerEnabled': value});
  }

  Future<void> setNoSecure(bool value) async {
    noSecure = value;
    notifyModelListeners();
    await proxy.updateSettings({'noSecure': value});
  }

  Future<void> setForceTestDc(bool value) async {
    forceTestDc = value;
    notifyModelListeners();
    await proxy.updateSettings({'forceTestDc': value});
  }

  Future<void> setPoolSize(int value) async {
    poolSize = value.clamp(1, 16);
    notifyModelListeners();
    await proxy.updateSettings({'poolSize': poolSize});
  }

  Future<void> setFakeTlsDomain(String value) async {
    fakeTlsDomain = value.trim().toLowerCase();
    notifyModelListeners();
    await proxy.updateSettings({'fakeTlsDomain': fakeTlsDomain});
  }

  Future<void> setProxyProtocol(bool value) async {
    proxyProtocol = value;
    notifyModelListeners();
    await proxy.updateSettings({'proxyProtocol': value});
  }

  Future<void> setBotApiEnabled(bool value) async {
    botApiEnabled = value;
    notifyModelListeners();
    await proxy.updateSettings({'botApiEnabled': value});
  }

  Future<void> setBotApiPort(int value) async {
    botApiPort = value.clamp(1, 65535);
    notifyModelListeners();
    await proxy.updateSettings({'botApiPort': botApiPort});
  }

  Future<void> setAddress(String value, int valuePort) async {
    host = value.trim();
    port = valuePort.clamp(1, 65535);
    notifyModelListeners();
    await proxy.updateSettings({'host': host, 'port': port});
  }

  Future<void> setDcRedirects(Map<int, String> value) async {
    dcRedirects = Map<int, String>.from(value);
    notifyModelListeners();
    await proxy.updateSettings({
      'dcRedirects': dcRedirects.map((key, ip) => MapEntry('$key', ip)),
    });
  }

  Future<void> setAutoStart(bool value) async {
    autoStart = value;
    notifyModelListeners();
    await db.write('auto_start', '$value');
  }

  Future<void> setCheckUpdates(bool value) async {
    checkUpdates = value;
    notifyModelListeners();
    await db.write('check_updates', '$value');
  }
}
