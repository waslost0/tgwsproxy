import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:tg_proxy_core/tg_proxy_core.dart';

void main() {
  final secret = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
  final prekey = Uint8List.fromList(List<int>.generate(32, (i) => i + 11));
  final iv = Uint8List.fromList(List<int>.generate(16, (i) => i + 41));
  final handshake = _clientHandshake(
    secret: secret,
    prekey: prekey,
    iv: iv,
    protoTag: const [0xef, 0xef, 0xef, 0xef],
    dc: 2,
  );

  test('relays re-encrypted MTProto in both directions', () async {
    final stats = ProxyStats();
    final config = ProxyConfig(port: 0, secret: bytesToHex(secret));
    final remote = _FakeTransport();
    final server = ProxyServer(
      config: config,
      stats: stats,
      router: TransportRouter(
        config: config,
        stats: stats,
        balancer: CfDomainBalancer(),
      ),
      secret: secret,
      handshakeDelay: Duration.zero,
      connector: (dc, {required media, required test}) async {
        expect(dc, 2);
        expect(media, isFalse);
        expect(test, isFalse);
        return ConnectedTransport(
          transport: remote,
          route: 'ws',
          dc: dc,
          media: media,
          test: test,
        );
      },
    );
    final port = await server.start();
    final client = await Socket.connect('127.0.0.1', port);
    final reader = StreamIterator<Uint8List>(client);

    client.add(handshake);
    await client.flush();
    await _waitFor(() => remote.sent.isNotEmpty);

    final relay = remote.sent.first;
    expect(relay.length, 64);
    final relayPlain = AesCtr(
      relay.sublist(8, 40),
      relay.sublist(40, 56),
    ).process(relay);
    expect(relayPlain.sublist(56, 60), [0xef, 0xef, 0xef, 0xef]);
    expect(
      ByteData.sublistView(relayPlain).getInt16(60, Endian.little),
      2,
    );

    final clientKey = Uint8List.fromList(
      sha256.convert([...prekey, ...secret]).bytes,
    );
    final clientStream = AesCtr(clientKey, iv)..skip(64);
    // Abridged header 0x01 means four payload bytes.
    final clientPlain = Uint8List.fromList([0x01, 0x42, 0x43, 0x44, 0x45]);
    client.add(clientStream.process(clientPlain));
    await client.flush();
    await _waitFor(() => remote.sent.length >= 2);

    final telegramStream = AesCtr(
      relay.sublist(8, 40),
      relay.sublist(40, 56),
    )..skip(64);
    expect(telegramStream.process(remote.sent[1]), clientPlain);

    final relayReverse = Uint8List.fromList(
      relay.sublist(8, 56).reversed.toList(),
    );
    final telegramDown = AesCtr(
      relayReverse.sublist(0, 32),
      relayReverse.sublist(32, 48),
    );
    final downPlain = Uint8List.fromList([0x02, 0x99]);
    remote.incoming(telegramDown.process(downPlain));
    await reader.moveNext();
    final encryptedDown = reader.current;

    final prekeyIv = Uint8List.fromList([...prekey, ...iv]);
    final reversed = Uint8List.fromList(prekeyIv.reversed.toList());
    final clientDownKey = Uint8List.fromList(
      sha256.convert([...reversed.sublist(0, 32), ...secret]).bytes,
    );
    final clientDown = AesCtr(
      clientDownKey,
      reversed.sublist(32, 48),
    );
    expect(clientDown.process(encryptedDown), downPlain);

    await reader.cancel();
    await client.close();
    await server.stop();
    await remote.close();
    expect(stats.total, 1);
    expect(stats.active, 0);
  });

  test('rejects an invalid handshake and closes the client', () async {
    final stats = ProxyStats();
    final config = ProxyConfig(port: 0, secret: bytesToHex(secret));
    final remote = _FakeTransport();
    final server = ProxyServer(
      config: config,
      stats: stats,
      router: TransportRouter(
        config: config,
        stats: stats,
        balancer: CfDomainBalancer(),
      ),
      secret: secret,
      connector: (dc, {required media, required test}) async {
        return ConnectedTransport(
          transport: remote,
          route: 'tcp',
          dc: dc,
          media: media,
          test: test,
        );
      },
    );
    final port = await server.start();
    final client = await Socket.connect('127.0.0.1', port);
    client.add(Uint8List(64));
    await client.flush();
    await _waitFor(() => stats.bad == 1);
    await _waitFor(() => stats.active == 0);
    await client.close();
    await server.stop();
    expect(remote.sent, isEmpty);
  });

  test('stop closes the listener', () async {
    final stats = ProxyStats();
    final config = ProxyConfig(port: 0, secret: bytesToHex(secret));
    final server = ProxyServer(
      config: config,
      stats: stats,
      router: TransportRouter(
        config: config,
        stats: stats,
        balancer: CfDomainBalancer(),
      ),
      secret: secret,
    );
    final port = await server.start();
    await server.stop();
    await expectLater(
      Socket.connect('127.0.0.1', port),
      throwsA(isA<SocketException>()),
    );
  });
}

Uint8List _clientHandshake({
  required Uint8List secret,
  required Uint8List prekey,
  required Uint8List iv,
  required List<int> protoTag,
  required int dc,
}) {
  final init = Uint8List(64);
  init.setRange(8, 40, prekey);
  init.setRange(40, 56, iv);
  final tail = Uint8List(8);
  tail.setRange(0, 4, protoTag);
  ByteData.sublistView(tail).setInt16(4, dc, Endian.little);
  tail[6] = 0xaa;
  tail[7] = 0xbb;
  final key = Uint8List.fromList(
    sha256.convert([...prekey, ...secret]).bytes,
  );
  final stream = AesCtr(key, iv)..skip(56);
  init.setRange(56, 64, stream.process(tail));
  return init;
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition was not met in time');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _FakeTransport implements ProxyTransport {
  final _incoming = StreamController<Uint8List>();
  late final StreamIterator<Uint8List> _iterator =
      StreamIterator(_incoming.stream);
  final List<Uint8List> sent = [];
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Future<void> send(Uint8List data) async {
    sent.add(Uint8List.fromList(data));
  }

  @override
  Future<Uint8List?> receive() async {
    if (_closed) return null;
    if (await _iterator.moveNext()) return _iterator.current;
    return null;
  }

  void incoming(Uint8List data) {
    _incoming.add(Uint8List.fromList(data));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incoming.close();
    await _iterator.cancel();
  }
}
