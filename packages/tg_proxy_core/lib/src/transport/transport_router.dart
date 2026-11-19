// Purpose: Route selection and connected transport metadata.
import 'dart:async';

import '../config/proxy_config.dart';
import '../constants.dart';
import '../stats/proxy_stats.dart';
import 'cf_domains.dart';
import '../logging/proxy_log.dart';
import 'cf_worker_pool.dart';
import 'proxy_transport.dart';
import 'raw_websocket.dart';
import 'tcp_fallback.dart';
import 'ws_pool.dart';

class ConnectedTransport {
  const ConnectedTransport({
    required this.transport,
    required this.route,
    required this.dc,
    required this.media,
    required this.test,
    this.domain,
  });

  final ProxyTransport transport;
  final String route;
  final int dc;
  final bool media;
  final bool test;
  final String? domain;
}

/// Chooses the same route order as the Python core:
/// direct Telegram web WebSocket, CF worker, CF proxy domain, direct TCP.
class TransportRouter {
  TransportRouter({
    required this.config,
    required this.stats,
    required this.balancer,
    WsPool? wsPool,
    CfWorkerPool? cfWorkerPool,
    TcpFallback? tcpFallback,
    WsConnector? connector,
  })  : wsPool = wsPool ??
            WsPool(config: config, stats: stats, connector: connector),
        cfWorkerPool = cfWorkerPool ??
            CfWorkerPool(config: config, stats: stats, connector: connector),
        tcpFallback = tcpFallback ?? TcpFallback();

  final ProxyConfig config;
  final ProxyStats stats;
  final CfDomainBalancer balancer;
  final WsPool wsPool;
  final CfWorkerPool cfWorkerPool;
  final TcpFallback tcpFallback;

  Future<ConnectedTransport?> connect(
    int dc, {
    required bool media,
    bool test = false,
  }) async {
    final direct = await wsPool.acquire(dc, media: media, test: test);
    if (direct != null) {
      stats.ws++;
      return ConnectedTransport(
        transport: direct,
        route: 'ws',
        dc: dc,
        media: media,
        test: test,
      );
    }

    proxyDebug('direct WS unavailable for DC$dc');
    final fallbackDst = config.fallbackIp(dc, test: test);
    if (fallbackDst == null) return null;

    if (!test &&
        config.cfWorkerEnabled &&
        config.cfproxyWorkerDomains.isNotEmpty) {
      final worker = await cfWorkerPool.acquire(
        dc,
        fallbackDst,
        config.cfproxyWorkerDomains,
      );
      if (worker != null) {
        stats.cf++;
        return ConnectedTransport(
          transport: worker,
          route: 'cf_worker',
          dc: dc,
          media: media,
          test: test,
        );
      }
    }

    if (!test && config.fallbackCfproxy) {
      final cf = await _connectCfProxy(dc);
      if (cf != null) {
        stats.cf++;
        return ConnectedTransport(
          transport: cf.transport,
          route: 'cf',
          dc: dc,
          media: media,
          test: test,
          domain: cf.domain,
        );
      }
    }

    final tcp = await tcpFallback.connect(fallbackDst);
    if (tcp != null) {
      stats.tcpFallback++;
      return ConnectedTransport(
        transport: tcp,
        route: 'tcp',
        dc: dc,
        media: media,
        test: test,
      );
    }
    return null;
  }

  Future<({ProxyTransport transport, String domain})?> _connectCfProxy(
    int dc,
  ) async {
    for (final base in balancer.getDomainsForDc(dc)) {
      final domain = 'kws$dc.$base';
      try {
        final transport = await RawWebSocket.connect(
          domain,
          domain,
          secure: !config.disableSecure,
          timeout: const Duration(seconds: 10),
        );
        balancer.updateDomainForDc(dc, base);
        proxyInfo(
          'CF proxy connected $domain secure=${!config.disableSecure}',
        );
        return (transport: transport, domain: base);
      } catch (error) {
        stats.bad++;
        proxyWarning('CF proxy $domain failed: $error');
      }
    }
    proxyError('CF proxy: all domains failed for DC$dc');
    return null;
  }

  Future<void> warmup() async {
    await wsPool.warmup();
    final fallbackDcs = <int, String>{};
    for (final entry in dcDefaultIps.entries) {
      if (!config.dcRedirects.containsKey(entry.key)) {
        fallbackDcs[entry.key] = entry.value;
      }
    }
    await cfWorkerPool.warmup(fallbackDcs);
  }

  Future<void> dispose() async {
    await wsPool.dispose();
    await cfWorkerPool.dispose();
  }
}
