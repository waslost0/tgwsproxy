import 'package:test/test.dart';
import 'package:tg_proxy_core/tg_proxy_core.dart';

void main() {
  test('keeps defaults for an empty document', () {
    final config = ProxyConfig.fromJson(const {});

    expect(config.port, 1443);
    expect(config.dcRedirects, {2: '149.154.167.220', 4: '149.154.167.220'});
    expect(config.botApiEnabled, isTrue);
    expect(config.botApiPort, 8081);
  });

  test('parses desktop-style dc_ip and buffer keys', () {
    final config = ProxyConfig.fromJson({
      'port': 2443,
      'bufKb': 512,
      'pool_size': 7,
      'dc_ip': {'2': '1.2.3.4', '203': '5.6.7.8'},
      'cfproxy_user_domain': ['a.example', ' b.example '],
      'cfproxy_worker_enabled': true,
      'cfproxy_worker_domain': 'w.example, w2.example',
      'no_secure': true,
      'bot_api': false,
      'bot_api_port': 9090,
    });

    expect(config.port, 2443);
    expect(config.bufferSize, 512 * 1024);
    expect(config.poolSize, 7);
    expect(config.dcRedirects, {2: '1.2.3.4', 203: '5.6.7.8'});
    expect(config.cfproxyUserDomains, ['a.example', 'b.example']);
    expect(config.cfproxyWorkerDomains, ['w.example', 'w2.example']);
    expect(config.disableSecure, isTrue);
    expect(config.botApiEnabled, isFalse);
    expect(config.botApiPort, 9090);
  });

  test('accepts the camelCase noSecure flag from the Android bridge', () {
    final config = ProxyConfig.fromJson({'noSecure': true});

    expect(config.disableSecure, isTrue);
  });

  test('normalizes empty redirects back to the default DC pair', () {
    final config = ProxyConfig.fromJson({'dc_ip': <String, String>{}});

    expect(config.dcRedirects, {2: '149.154.167.220', 4: '149.154.167.220'});
  });
}
