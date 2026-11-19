import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:tg_proxy_core/tg_proxy_core.dart';

void main() {
  final secret = Uint8List.fromList(List.generate(16, (i) => i + 1));

  test('verifies a client hello and rejects replay/wrong secret/stale time',
      () {
    final server = FakeTlsServer(
      secret: secret,
      random: Random(1),
      replayCache: FakeTlsReplayCache(now: () => DateTime(2026, 11, 18)),
    );
    final hello = _clientHello(secret, timestamp: _now());

    final first = server.acceptClientHello(hello);
    expect(first, isNotNull);
    expect(first!.info.cipherSuites, contains(0x1301));
    expect(first.info.keyShares[groupX25519], x25519KeyLen);
    expect(server.acceptClientHello(hello), isNull);

    final other = FakeTlsServer(secret: Uint8List(16))
        .acceptClientHello(_clientHello(secret, timestamp: _now()));
    expect(other, isNull);

    final stale = FakeTlsServer(secret: secret)
        .acceptClientHello(_clientHello(secret, timestamp: _now() - 121));
    expect(stale, isNull);
  });

  test('builds a server hello with valid HMAC and record shape', () {
    final server =
        FakeTlsServer(secret: secret, random: Random(2), appDataLength: 80);
    final hello =
        server.acceptClientHello(_clientHello(secret, timestamp: _now()))!;
    final response = server.buildServerHello(hello);

    expect(response[0], tlsRecordHandshake);
    expect(response[1], 0x03);
    expect(response[2], 0x03);
    expect(response[5], 0x02);

    final clientRandom = hello.clientRandom;
    final zeroed = Uint8List.fromList(response);
    zeroed.fillRange(serverRandomOffset, serverRandomOffset + 32, 0);
    final expected =
        Hmac(sha256, secret).convert([...clientRandom, ...zeroed]).bytes;
    expect(
      response.sublist(serverRandomOffset, serverRandomOffset + 32),
      expected,
    );

    final records = _records(response);
    expect(records.map((r) => r.type),
        [tlsRecordHandshake, tlsRecordCcs, tlsRecordAppData]);
    expect(records.last.body.length, 80);
  });

  test('selects hybrid key share when the client offers it', () {
    final server = FakeTlsServer(secret: secret, random: Random(3));
    final hello = server.acceptClientHello(
      _clientHello(
        secret,
        timestamp: _now(),
        keyShares: {
          groupX25519: 32,
          groupX25519MlKem768: x25519MlKem768ClientShareLen,
        },
      ),
    )!;
    final response = server.buildServerHello(hello);
    expect(_keyShareGroup(response), groupX25519MlKem768);
  });

  test('decodes fragmented appdata and wraps writes', () async {
    final data = Uint8List.fromList(utf8Bytes('hello'));
    final transport = _QueueTransport();
    final records = wrapTlsRecords(data);
    transport.feed(records.sublist(0, 3));
    transport.feed(records.sublist(3));
    final stream = FakeTlsStream(transport);

    expect(await stream.readExact(5), data);
    expect(await stream.receive(), isNull);

    await stream.send(data);
    expect(transport.sent.single, wrapTlsRecords(data));
  });

  test('skips CCS and handles a split TLS record', () async {
    final transport = _QueueTransport();
    final payload = Uint8List.fromList(utf8Bytes('abcdef'));
    final record = wrapTlsRecords(payload);
    transport.feed(Uint8List.fromList(ccsFrame));
    transport.feed(record.sublist(0, 4));
    transport.feed(record.sublist(4));

    final stream = FakeTlsStream(transport);
    expect(await stream.readExact(3), payload.sublist(0, 3));
    expect(await stream.readExact(3), payload.sublist(3));
  });

  test('wrapTlsRecords splits at 16384 bytes', () {
    final data = Uint8List(16385);
    final records = _records(wrapTlsRecords(data));
    expect(records.length, 2);
    expect(records[0].body.length, 16384);
    expect(records[1].body.length, 1);
  });
}

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

Uint8List _clientHello(
  Uint8List secret, {
  required int timestamp,
  Map<int, int>? keyShares,
}) {
  final random = Uint8List(32);
  final session = Uint8List.fromList(List.generate(32, (i) => 0x40 + i));
  final shares = keyShares ?? {groupX25519: x25519KeyLen};

  final sharesLength = shares.entries.fold<int>(0, (n, e) => n + 4 + e.value);
  final extensions = BytesBuilder(copy: false)
    ..add(_u16(extSupportedVersions))
    ..add(_u16(2))
    ..add(_u16(tlsVersion13))
    ..add(_u16(extKeyShare))
    ..add(_u16(2 + sharesLength));

  final shareData = BytesBuilder(copy: false)..add(_u16(sharesLength));
  for (final entry in shares.entries) {
    shareData
      ..add(_u16(entry.key))
      ..add(_u16(entry.value))
      ..add(Uint8List(entry.value));
  }
  extensions.add(shareData.takeBytes());

  final body = BytesBuilder(copy: false)
    ..add(_u16(tlsVersion12))
    ..add(random)
    ..addByte(session.length)
    ..add(session)
    ..add(_u16(2))
    ..add(_u16(0x1301))
    ..addByte(1)
    ..addByte(0)
    ..add(_u16(extensions.length))
    ..add(extensions.takeBytes());
  final bodyBytes = body.takeBytes();

  final handshake = BytesBuilder(copy: false)
    ..addByte(0x01)
    ..add(_u24(bodyBytes.length))
    ..add(bodyBytes);
  final handshakeBytes = handshake.takeBytes();

  final record = BytesBuilder(copy: false)
    ..addByte(tlsRecordHandshake)
    ..add(_u16(tlsVersion10))
    ..add(_u16(handshakeBytes.length))
    ..add(handshakeBytes);
  final bytes = record.takeBytes();

  final zeroed = Uint8List.fromList(bytes);
  zeroed.fillRange(clientRandomOffset, clientRandomOffset + 32, 0);
  final mac = Hmac(sha256, secret).convert(zeroed).bytes;

  bytes.setRange(
      clientRandomOffset, clientRandomOffset + 28, mac.sublist(0, 28));
  for (var i = 0; i < 4; i++) {
    bytes[clientRandomOffset + 28 + i] =
        ((timestamp >> (8 * i)) & 0xff) ^ mac[28 + i];
  }
  return bytes;
}

int _keyShareGroup(Uint8List response) {
  var pos = 5 + 4;
  pos += 2; // version
  pos += 32; // random
  pos += 1 + response[pos]; // session id
  pos += 2; // cipher
  pos += 1; // compression
  final extLen = _readU16(response, pos);
  pos += 2;
  final end = pos + extLen;
  while (pos + 4 <= end) {
    final type = _readU16(response, pos);
    final len = _readU16(response, pos + 2);
    pos += 4;
    if (type == extKeyShare) return _readU16(response, pos);
    pos += len;
  }
  return -1;
}

List<_Record> _records(Uint8List bytes) {
  final out = <_Record>[];
  var pos = 0;
  while (pos + 5 <= bytes.length) {
    final type = bytes[pos];
    final len = (bytes[pos + 3] << 8) | bytes[pos + 4];
    final body = bytes.sublist(pos + 5, pos + 5 + len);
    out.add(_Record(type, body));
    pos += 5 + len;
  }
  return out;
}

class _Record {
  const _Record(this.type, this.body);

  final int type;
  final Uint8List body;
}

class _QueueTransport implements ProxyTransport {
  final List<Uint8List> _incoming = [];
  final List<Uint8List> sent = [];
  bool _closed = false;

  void feed(Uint8List data) => _incoming.add(data);

  @override
  bool get isClosed => _closed;

  @override
  Future<Uint8List?> receive() async =>
      _incoming.isEmpty ? null : _incoming.removeAt(0);

  @override
  Future<void> send(Uint8List data) async => sent.add(Uint8List.fromList(data));

  @override
  Future<void> close() async => _closed = true;
}

Uint8List utf8Bytes(String value) => Uint8List.fromList(value.codeUnits);

int _readU16(Uint8List data, int offset) =>
    (data[offset] << 8) | data[offset + 1];

Uint8List _u16(int value) =>
    Uint8List.fromList([(value >> 8) & 0xff, value & 0xff]);

Uint8List _u24(int value) => Uint8List.fromList([
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ]);
