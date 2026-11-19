// Purpose: Local MTProto listener and per-client orchestration.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../config/proxy_config.dart';
import '../crypto/hex.dart';
import '../faketls/fake_tls.dart';
import '../mtproto/handshake.dart';
import '../mtproto/splitter.dart';
import '../stats/proxy_stats.dart';
import '../transport/proxy_transport.dart';
import '../logging/proxy_log.dart';
import '../transport/transport_router.dart';
import 'bridge.dart';
import 'client_transport.dart';

/// Opens the remote side for one client.
///
/// Production uses [TransportRouter]; tests inject a connector returning
/// in-memory transports so the server can be exercised without TLS or CF.
typedef RelayConnector = Future<ConnectedTransport?> Function(
  int dc, {
  required bool media,
  required bool test,
});

/// Binds the local MTProto port and runs one independent relay per client.
class ProxyServer {
  factory ProxyServer({
    required ProxyConfig config,
    required ProxyStats stats,
    required TransportRouter router,
    Uint8List? secret,
    FakeTlsServer? fakeTls,
    RelayConnector? connector,
    Duration? handshakeDelay,
  }) {
    // The config carries the secret as hex; tests may inject raw bytes.
    final secretBytes = secret ?? hexToBytes(config.secret);
    if (secretBytes.length != 16) {
      throw ArgumentError.value(
        secretBytes.length,
        'secret',
        'must be 16 bytes',
      );
    }
    final tls = fakeTls ??
        (config.fakeTlsDomain.isNotEmpty
            ? FakeTlsServer(secret: secretBytes)
            : null);
    return ProxyServer._(
      config: config,
      stats: stats,
      router: router,
      secret: secretBytes,
      fakeTls: tls,
      connector: connector,
      handshakeDelay: handshakeDelay,
    );
  }

  ProxyServer._({
    required this.config,
    required this.stats,
    required this.router,
    required this.secret,
    required this.fakeTls,
    required this.connector,
    required this.handshakeDelay,
  });

  final ProxyConfig config;
  final ProxyStats stats;
  final TransportRouter router;
  final Uint8List secret;
  final FakeTlsServer? fakeTls;
  final RelayConnector? connector;
  final Duration? handshakeDelay;

  final Random _random = Random.secure();
  final Set<ProxyTransport> _active = {};
  ServerSocket? _server;
  StreamSubscription<Socket>? _acceptSubscription;

  bool get isRunning => _server != null;

  Future<int> start() async {
    if (_server != null) throw StateError('proxy server already started');
    final server = await ServerSocket.bind(config.host, config.port);
    _server = server;
    _acceptSubscription = server.listen(
      _accept,
      onError: (Object error, StackTrace stackTrace) {
        stats.errors++;
      },
    );
    return server.port;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await _acceptSubscription?.cancel();
    _acceptSubscription = null;
    await server?.close();
    final transports = _active.toList(growable: false);
    _active.clear();
    await Future.wait(
      transports.map((transport) async {
        try {
          await transport.close();
        } catch (_) {
          // The client may already be gone.
        }
      }),
    );
  }

  void _accept(Socket socket) {
    final client = ClientTransport(socket);
    _active.add(client);
    unawaited(_handle(client));
  }

  Future<void> _handle(ClientTransport client) async {
    ProxyTransport? activeClient = client;
    ProxyTransport? remote;
    try {
      // Count the connection before parsing so failed handshakes are visible.
      stats.total++;
      stats.active++;
      final init = await _readClientInit(client);
      if (init == null) return;
      // FakeTLS wraps the raw socket; track the transport that actually writes.
      activeClient = init.transport;
      _active
        ..remove(client)
        ..add(activeClient);

      final handshake = tryHandshake(init.handshake, secret);
      if (handshake == null) {
        stats.bad++;
        proxyWarning('bad MTProto handshake');
        return;
      }
      proxyDebug('handshake dc=${handshake.dcId} media=${handshake.isMedia}');

      var dc = handshake.dcId;
      if (dc <= 0) {
        stats.bad++;
        return;
      }
      // Telegram marks test DCs as 10000 + real DC id; forceTestDc overrides.
      final test = config.forceTestDc || dc >= 10000;
      if (dc >= 10000) dc -= 10000;

      final proto = protoTagToInt(handshake.protoTag);
      if (proto == null) {
        stats.bad++;
        return;
      }

      final media = handshake.isMedia;
      // The relay init is encrypted for Telegram and must be sent verbatim
      // before any client payload.
      final relayInit = generateRelayInit(
        handshake.protoTag,
        media ? -dc : dc,
      );
      final crypto = buildCryptoContext(
        handshake.prekeyIv,
        secret,
        relayInit,
      );

      final connection = connector != null
          ? await connector!(dc, media: media, test: test)
          : await router.connect(dc, media: media, test: test);
      if (connection == null) {
        stats.errors++;
        proxyError('no route for DC$dc media=$media test=$test');
        return;
      }
      remote = connection.transport;
      _active.add(remote);
      proxyInfo(
        'route=${connection.route} dc=$dc media=$media '
        'domain=${connection.domain}',
      );

      await remote.send(relayInit);
      // Raw WS and CF proxy carry length-framed MTProto; CF worker and TCP
      // are byte streams, so they must not be split.
      final splitter = connection.route == 'ws' || connection.route == 'cf'
          ? MsgSplitter(proto)
          : null;
      await runMtProtoBridge(
        client: activeClient,
        remote: remote,
        crypto: crypto,
        stats: stats,
        splitter: splitter,
      );
    } on TimeoutException {
      stats.errors++;
      proxyWarning('client timeout');
    } on SocketException catch (error) {
      stats.errors++;
      proxyWarning('socket error: $error');
    } on FakeTlsClosed {
      stats.errors++;
      proxyDebug('faketls closed');
    } catch (error, stack) {
      stats.errors++;
      proxyError('handler error', error, stack);
    } finally {
      // Every exit path must release the slot and both sockets, including
      // handshake failures before a remote transport existed.
      stats.active--;
      _active
        ..remove(client)
        ..remove(activeClient);
      if (remote != null) _active.remove(remote);
      final clientToClose = activeClient;
      if (clientToClose != null) {
        try {
          await clientToClose.close();
        } catch (_) {
          // Already closed.
        }
      }
      if (remote != null) {
        try {
          await remote.close();
        } catch (_) {
          // Already closed.
        }
      }
    }
  }

  Future<_ClientInit?> _readClientInit(ClientTransport client) async {
    // PROXY v1, when enabled, is a single text line before any MTProto/TLS
    // bytes. Telegram itself does not send it; it is for external frontends.
    if (config.proxyProtocol) {
      final line = await client.readLine();
      if (!line.startsWith('PROXY ')) {
        throw const FormatException('invalid PROXY protocol line');
      }
    }

    // The first byte identifies the stream: 0x16 is a TLS ClientHello (FakeTLS),
    // anything else is either a raw obfuscated2 init or a browser probe.
    final first = await client.readByte();
    final tlsDomain = config.fakeTlsDomain;

    if (tlsDomain.isNotEmpty) {
      if (first != 0x16) {
        // A browser/DPI probe must not learn that this is a proxy.
        stats.masked++;
        await _sendMasking(client, tlsDomain);
        return null;
      }
      final tls = fakeTls;
      if (tls == null) throw StateError('FakeTLS is enabled without a server');
      // TLS record header: type(1) + version(2) + length(2). The type byte is
      // already consumed, so read the remaining four bytes and rebuild it.
      final header = await client.readExact(4);
      final recordLength = (header[2] << 8) | header[3];
      if (recordLength <= 0 || recordLength > 0xffff) {
        throw const FormatException('invalid TLS record length');
      }
      final body = await client.readExact(recordLength);
      final hello = Uint8List.fromList([first, ...header, ...body]);
      // Replay/stale/invalid HMAC all look like ordinary HTTPS traffic: answer
      // with the masking redirect instead of an error Telegram could detect.
      final handshake = tls.acceptClientHello(hello);
      if (handshake == null) {
        stats.masked++;
        await _sendMasking(client, tlsDomain);
        return null;
      }
      final response = tls.buildServerHello(handshake);
      // A real server does not answer in the same microsecond. The jitter is
      // cosmetic but makes the FakeTLS handshake less fingerprintable.
      final delay =
          handshakeDelay ?? Duration(milliseconds: 20 + _random.nextInt(41));
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      await client.send(response);
      // From here the client speaks TLS records; all reads/writes are wrapped.
      final wrapped = tls.wrap(client);
      final mtproto = await wrapped.readExact(64);
      return _ClientInit(transport: wrapped, handshake: mtproto);
    }

    // No FakeTLS: the first byte is part of the 64-byte obfuscated2 init,
    // so only 63 bytes remain to read.
    final rest = await client.readExact(63);
    return _ClientInit(
      transport: client,
      handshake: Uint8List.fromList([first, ...rest]),
    );
  }

  Future<void> _sendMasking(ClientTransport client, String domain) async {
    // Minimal redirect is enough for browsers and keeps the response small.
    final response = 'HTTP/1.1 301 Moved Permanently\r\n'
        'Location: https://$domain/\r\n'
        'Content-Length: 0\r\n'
        'Connection: close\r\n'
        '\r\n';
    await client.send(Uint8List.fromList(utf8.encode(response)));
    await client.close();
  }
}

class _ClientInit {
  const _ClientInit({required this.transport, required this.handshake});

  /// Either the raw socket or a [FakeTlsStream] wrapping it.
  final ProxyTransport transport;

  /// Decrypted 64-byte obfuscated2 init (still encrypted until tryHandshake).
  final Uint8List handshake;
}
