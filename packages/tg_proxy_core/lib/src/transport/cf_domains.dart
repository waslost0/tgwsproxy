// Purpose: CF domain list, decoding, balancer and refresh.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

const cfproxyDomainsUrl =
    'https://raw.githubusercontent.com/Flowseal/tg-ws-proxy/main/'
    '.github/cfproxy-domains.txt';

const _cfproxyMinValidDomains = 3;

const _cfproxyEncoded = [
  'virkgj.com',
  'vmmzovy.com',
  'mkuosckvso.com',
  'zaewayzmplad.com',
  'twdmbzcm.com',
  'awzwsldi.com',
  'clngqrflngqin.com',
  'tjacxbqtj.com',
  'bxaxtxmrw.com',
  'dmohrsgmohcrwb.com',
  'vwbmtmoi.com',
  'khgrre.com',
  'ulihssf.com',
  'tmhqsdqmfpmk.com',
  'xwuwoqbm.com',
  'orgcnunpj.com',
  'zhkuldz.com',
  'zypoljnslxa.com',
  'efabnxaowuzs.com',
  'zaftuzsftqdq.com',
];

/// Decodes one entry of the embedded CF proxy domain list.
String decodeCfproxyDomain(String encoded) {
  if (!encoded.endsWith('.com')) return encoded;
  final prefix = encoded.substring(0, encoded.length - 4);
  final shift = prefix.split('').where((c) => _isAlpha(c)).length;
  final out = StringBuffer();
  for (final code in prefix.codeUnits) {
    final ch = String.fromCharCode(code);
    if (!_isAlpha(ch)) {
      out.write(ch);
      continue;
    }
    final base = code >= 97 ? 97 : 65;
    out.writeCharCode(((code - base - shift) % 26 + 26) % 26 + base);
  }
  return '$out.co.uk';
}

bool _isAlpha(String ch) {
  final code = ch.codeUnitAt(0);
  return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
}

final List<String> cfproxyDefaultDomains =
    List.unmodifiable(_cfproxyEncoded.map(decodeCfproxyDomain));

bool isValidDomain(String domain) {
  if (domain.isEmpty || domain.length > 253) return false;
  if (domain.startsWith('.') || domain.endsWith('.')) return false;
  final labels = domain.split('.');
  if (labels.length < 2) return false;
  for (final label in labels) {
    if (label.isEmpty || label.length > 63) return false;
    if (label.startsWith('-') || label.endsWith('-')) return false;
    if (!label.split('').every(
          (c) => RegExp(r'[A-Za-z0-9-]').hasMatch(c),
        )) {
      return false;
    }
  }
  final tld = labels.last;
  return tld.length >= 2 &&
      tld.split('').any((c) => RegExp(r'[A-Za-z]').hasMatch(c));
}

List<String> normalizeDomainPool(Iterable<String> domains) {
  final seen = <String>{};
  final out = <String>[];
  for (final raw in domains) {
    final item = raw.trim().toLowerCase();
    if (!isValidDomain(item) || !seen.add(item)) continue;
    out.add(item);
  }
  return out;
}

List<String> parseDomainList(String value) {
  final seen = <String>{};
  final out = <String>[];
  for (final item
      in value.replaceAll(RegExp(r'[,;]'), ' ').split(RegExp(r'\s+'))) {
    final domain = item.trim();
    if (domain.isEmpty) continue;
    if (seen.add(domain.toLowerCase())) out.add(domain);
  }
  return out;
}

class CfDomainBalancer {
  CfDomainBalancer({Random? random}) : _random = random ?? Random();

  final Random _random;
  List<String> _domains = const [];
  final Map<int, String> _dcToDomain = {};

  List<String> get domains => List.unmodifiable(_domains);

  void updateDomains(List<String> domains) {
    if (_sameDomains(_domains, domains)) return;
    _domains = List.of(domains);
    _dcToDomain.clear();
    if (_domains.isEmpty) return;
    for (final dc in const [1, 2, 3, 4, 5, 203]) {
      _dcToDomain[dc] = _domains[_random.nextInt(_domains.length)];
    }
  }

  bool updateDomainForDc(int dc, String domain) {
    if (_dcToDomain[dc] == domain) return false;
    _dcToDomain[dc] = domain;
    return true;
  }

  Iterable<String> getDomainsForDc(int dc) sync* {
    final current = _dcToDomain[dc];
    if (current != null) yield current;
    final shuffled = List.of(_domains)..shuffle(_random);
    for (final domain in shuffled) {
      if (domain != current) yield domain;
    }
  }

  static bool _sameDomains(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    final counts = <String, int>{};
    for (final item in a) {
      counts[item] = (counts[item] ?? 0) + 1;
    }
    for (final item in b) {
      final count = counts[item];
      if (count == null || count == 0) return false;
      counts[item] = count - 1;
    }
    return true;
  }
}

/// Keeps the balancer supplied with the embedded list and refreshes it hourly.
class CfDomainManager {
  CfDomainManager({
    required this.balancer,
    this.userDomains = const [],
    Future<List<String>> Function()? fetcher,
  }) : _fetcher = fetcher ?? _fetchRemote;

  final CfDomainBalancer balancer;
  final List<String> userDomains;
  final Future<List<String>> Function() _fetcher;
  Timer? _timer;

  void start({bool refreshNow = true}) {
    final initial = userDomains.isNotEmpty
        ? normalizeDomainPool(userDomains)
        : cfproxyDefaultDomains;
    balancer.updateDomains(initial);
    if (userDomains.isNotEmpty) return;
    if (refreshNow) unawaited(refresh());
    _timer = Timer.periodic(
      const Duration(hours: 1),
      (_) => unawaited(refresh()),
    );
  }

  Future<void> refresh() async {
    if (userDomains.isNotEmpty) return;
    try {
      final fetched = await _fetcher();
      final pool = normalizeDomainPool(fetched);
      if (pool.length >= _cfproxyMinValidDomains) {
        balancer.updateDomains(pool);
      }
    } catch (_) {
      // Keep the current pool; a failed refresh is not fatal.
    }
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
  }

  static Future<List<String>> _fetchRemote() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(
        Uri.parse('$cfproxyDomainsUrl?refresh'),
      );
      request.headers.set(HttpHeaders.userAgentHeader, 'tg-ws-proxy-dart');
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      return text
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && !line.startsWith('#'))
          .map(decodeCfproxyDomain)
          .toList();
    } finally {
      client.close(force: true);
    }
  }
}
