// Purpose: checks whether Cloudflare is reachable over TLS and plain HTTP.
import 'dart:async';

import 'cf_domains.dart';
import 'raw_websocket.dart';

class CfProbeResult {
  const CfProbeResult({required this.tls, required this.plain});

  final bool tls;
  final bool plain;

  bool get tlsBlocked => !tls && plain;
}

/// Opens a WebSocket upgrade through up to [sampleSize] Cloudflare domains.
///
/// `tls` and `plain` are probed independently: on some ISPs port 443 is
/// filtered by SNI while port 80 still works. Returning both lets the service
/// decide whether to switch the transport to plain HTTP.
Future<CfProbeResult> probeCf({
  List<String> domains = const [],
  String dst = '149.154.167.51',
  int dc = 2,
  int sampleSize = 3,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final pool = domains.where(isValidDomain).toList();
  final candidates =
      (pool.isEmpty ? cfproxyDefaultDomains : pool).take(sampleSize).toList();
  if (candidates.isEmpty) return const CfProbeResult(tls: false, plain: false);

  final path = '/apiws?dst=${Uri.encodeQueryComponent(dst)}&dc=$dc';

  for (final domain in candidates) {
    final results = await Future.wait([
      _canConnect(domain, path, true, timeout),
      _canConnect(domain, path, false, timeout),
    ]);
    final tls = results[0];
    final plain = results[1];
    if (tls || plain) return CfProbeResult(tls: tls, plain: plain);
  }
  return const CfProbeResult(tls: false, plain: false);
}

Future<bool> _canConnect(
  String domain,
  String path,
  bool secure,
  Duration timeout,
) async {
  RawWebSocket? socket;
  try {
    socket = await RawWebSocket.connect(
      domain,
      domain,
      secure: secure,
      path: path,
      timeout: timeout,
    );
    return true;
  } catch (_) {
    return false;
  } finally {
    await socket?.close();
  }
}
