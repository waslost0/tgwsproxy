// Purpose: FakeTLS ClientHello/ServerHello and record stream.
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../crypto/hex.dart';
import '../transport/proxy_transport.dart';

// TLS record types. FakeTLS only needs the handshake, change-cipher-spec and
// application-data records; alert records are intentionally not modelled.
const int tlsRecordHandshake = 0x16;
const int tlsRecordCcs = 0x14;
const int tlsRecordAppData = 0x17;

const int tlsVersion10 = 0x0301;
const int tlsVersion12 = 0x0303;
const int tlsVersion13 = 0x0304;

const int clientRandomOffset = 11;
const int clientRandomLen = 32;
const int sessionIdOffset = 44;
const int sessionIdLen = 32;
const int timestampTolerance = 120;
const int tlsAppDataMax = 16384;
const int appDataMin = 64;

const int extSupportedVersions = 0x002b;
const int extKeyShare = 0x0033;
const int groupX25519 = 0x001d;
const int groupX25519MlKem768 = 0x11ec;
const int x25519KeyLen = 32;
const int x25519MlKem768ClientShareLen = 1216;
const int mlKem768CiphertextLen = 1088;

const List<int> cipherPreference = [0x1301, 0x1303, 0x1302];
const List<int> ccsFrame = [0x14, 0x03, 0x03, 0x00, 0x01, 0x01];
const int serverRandomOffset = 11;
const int replayWindowSeconds = timestampTolerance * 2 + 1;
const int replayCacheSize = 65536;

class ClientHelloInfo {
  const ClientHelloInfo({
    required this.cipherSuites,
    required this.keyShares,
  });

  final Set<int> cipherSuites;
  final Map<int, int> keyShares;

  static const empty = ClientHelloInfo(cipherSuites: {}, keyShares: {});
}

class FakeTlsHandshake {
  const FakeTlsHandshake({
    required this.clientRandom,
    required this.sessionId,
    required this.timestamp,
    required this.info,
  });

  final Uint8List clientRandom;
  final Uint8List sessionId;
  final int timestamp;
  final ClientHelloInfo info;
}

class FakeTlsReplayCache {
  FakeTlsReplayCache({
    this.window = const Duration(seconds: replayWindowSeconds),
    this.maxEntries = replayCacheSize,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration window;
  final int maxEntries;
  final DateTime Function() _now;
  final LinkedHashMap<String, DateTime> _seen = LinkedHashMap();

  /// Returns true exactly once per client random inside [window].
  ///
  /// Entries are kept in insertion order, so `keys.first` is always the oldest
  /// one; expired entries are dropped before a duplicate check.
  bool firstSeen(Uint8List clientRandom) {
    final now = _now();
    while (_seen.isNotEmpty && !_seen.values.first.isAfter(now)) {
      _seen.remove(_seen.keys.first);
    }
    final key = bytesToHex(clientRandom);
    if (_seen.containsKey(key)) return false;
    if (_seen.length >= maxEntries) _seen.remove(_seen.keys.first);
    _seen[key] = now.add(window);
    return true;
  }
}

class FakeTlsServer {
  FakeTlsServer({
    required this.secret,
    FakeTlsReplayCache? replayCache,
    Random? random,
    this.appDataLength,
  })  : replayCache = replayCache ?? FakeTlsReplayCache(),
        _random = random ?? Random.secure();

  final Uint8List secret;
  final FakeTlsReplayCache replayCache;
  final Random _random;

  /// Profile of the masking site's first ApplicationData record, if known.
  int? appDataLength;

  /// Verifies the HMAC/timestamp and rejects replayed ClientHellos.
  FakeTlsHandshake? acceptClientHello(Uint8List data) {
    final hello = verifyClientHello(data, secret);
    if (hello == null) return null;
    if (!replayCache.firstSeen(hello.clientRandom)) return null;
    return hello;
  }

  /// Builds the fake TLS 1.3 ServerHello + CCS + first ApplicationData record.
  ///
  /// The server random is intentionally left as 32 zero bytes while the rest
  /// of the response is assembled; the HMAC is written over that layout last,
  /// so it authenticates every byte except its own 32-byte slot.
  Uint8List buildServerHello(
    FakeTlsHandshake hello, {
    int? appDataLen,
    Uint8List? sessionId,
  }) {
    final group = _selectGroup(hello.info);
    final keyExchange = _keyExchange(group);

    // TLS 1.3 extensions: supported_versions and key_share. Lengths are the
    // on-wire lengths, so the key_share extension includes the 4-byte header.
    final extensions = BytesBuilder(copy: false)
      ..add(_u16(extSupportedVersions))
      ..add(_u16(2))
      ..add(_u16(tlsVersion13))
      ..add(_u16(extKeyShare))
      ..add(_u16(4 + keyExchange.length))
      ..add(_u16(group))
      ..add(_u16(keyExchange.length))
      ..add(keyExchange);

    final body = BytesBuilder(copy: false)
      ..add(_u16(tlsVersion12))
      ..add(Uint8List(32))
      ..addByte((sessionId ?? hello.sessionId).length)
      ..add(sessionId ?? hello.sessionId)
      ..add(_u16(_selectCipherSuite(hello.info)))
      ..addByte(0)
      ..add(_u16(extensions.length))
      ..add(extensions.takeBytes());

    final bodyBytes = body.takeBytes();
    final message = BytesBuilder(copy: false)
      ..addByte(0x02)
      ..add(_u24(bodyBytes.length))
      ..add(bodyBytes);
    final messageBytes = message.takeBytes();

    final response = BytesBuilder(copy: false)
      ..addByte(tlsRecordHandshake)
      ..add(_u16(tlsVersion12))
      ..add(_u16(messageBytes.length))
      ..add(messageBytes)
      ..add(ccsFrame);

    final length = appDataLen ?? appDataLength ?? _randomAppDataLength();
    final appData = _randomBytes(length);
    response
      ..addByte(tlsRecordAppData)
      ..add(_u16(tlsVersion12))
      ..add(_u16(appData.length))
      ..add(appData);

    final bytes = response.takeBytes();
    final serverRandom =
        Hmac(sha256, secret).convert([...hello.clientRandom, ...bytes]).bytes;
    bytes.setRange(serverRandomOffset, serverRandomOffset + 32, serverRandom);
    return bytes;
  }

  FakeTlsStream wrap(ProxyTransport transport) => FakeTlsStream(transport);

  int _selectCipherSuite(ClientHelloInfo info) {
    for (final suite in cipherPreference) {
      if (info.cipherSuites.contains(suite)) return suite;
    }
    return cipherPreference.first;
  }

  int _selectGroup(ClientHelloInfo info) {
    if (info.keyShares[groupX25519MlKem768] == x25519MlKem768ClientShareLen) {
      return groupX25519MlKem768;
    }
    return groupX25519;
  }

  Uint8List _keyExchange(int group) {
    if (group == groupX25519MlKem768) {
      return Uint8List.fromList([
        ..._randomBytes(mlKem768CiphertextLen),
        ..._x25519PublicKey(),
      ]);
    }
    return _x25519PublicKey();
  }

  Uint8List _x25519PublicKey() {
    final key = _randomBytes(x25519KeyLen);
    key[key.length - 1] &= 0x7f;
    return key;
  }

  Uint8List _randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }

  int _randomAppDataLength() => appDataMin + _random.nextInt(97);
}

FakeTlsHandshake? verifyClientHello(Uint8List data, Uint8List secret) {
  if (data.length < 43) return null;
  if (data[0] != tlsRecordHandshake) return null;
  if (data[5] != 0x01) return null;

  // The client random is split into an HMAC prefix (28 bytes) and an
  // obfuscated timestamp (4 bytes). Zero the field before hashing so the same
  // HMAC can be recomputed by the server.
  final clientRandom = Uint8List.fromList(
      data.sublist(clientRandomOffset, clientRandomOffset + 32));
  final zeroed = Uint8List.fromList(data);
  zeroed.fillRange(clientRandomOffset, clientRandomOffset + 32, 0);

  final expected = Hmac(sha256, secret).convert(zeroed).bytes;
  for (var i = 0; i < 28; i++) {
    if (expected[i] != clientRandom[i]) return null;
  }

  // Timestamp bytes are XORed with the remaining HMAC bytes, little-endian.
  var timestamp = 0;
  for (var i = 0; i < 4; i++) {
    timestamp |= (clientRandom[28 + i] ^ expected[28 + i]) << (8 * i);
  }
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  if ((now - timestamp).abs() > timestampTolerance) return null;

  var sessionId = Uint8List(sessionIdLen);
  if (data.length >= sessionIdOffset + sessionIdLen && data[43] == 0x20) {
    sessionId = Uint8List.fromList(
      data.sublist(sessionIdOffset, sessionIdOffset + sessionIdLen),
    );
  }

  return FakeTlsHandshake(
    clientRandom: clientRandom,
    sessionId: sessionId,
    timestamp: timestamp,
    info: parseClientHello(data),
  );
}

ClientHelloInfo parseClientHello(Uint8List data) {
  try {
    // Skip TLS record (5), handshake header (4), legacy version (2) and the
    // fixed-size client random. Everything after this point is length-prefixed.
    var pos = 5 + 4 + 2 + clientRandomLen;
    pos += 1 + data[pos]; // session id: one length byte + bytes

    final suitesLen = _readU16(data, pos);
    pos += 2;
    final suitesEnd = pos + suitesLen;
    if (suitesEnd > data.length) return ClientHelloInfo.empty;
    final suites = <int>{};
    for (var off = pos; off + 1 < suitesEnd; off += 2) {
      suites.add(_readU16(data, off));
    }
    pos = suitesEnd;

    pos += 1 + data[pos]; // compression methods: one length byte + bytes

    final extTotal = _readU16(data, pos);
    pos += 2;
    final extEnd = min(pos + extTotal, data.length);
    final keyShares = <int, int>{};
    while (pos + 4 <= extEnd) {
      final extType = _readU16(data, pos);
      final extLen = _readU16(data, pos + 2);
      pos += 4;
      if (extType == extKeyShare && pos + 2 <= extEnd) {
        // key_share: u16 total length, then repeated group + u16 key length +
        // key bytes. Keep the first share per group; later duplicates are
        // ignored, matching the Python parser.
        final sharesEnd = min(pos + 2 + _readU16(data, pos), extEnd);
        var off = pos + 2;
        while (off + 4 <= sharesEnd) {
          final group = _readU16(data, off);
          final keyLen = _readU16(data, off + 2);
          off += 4 + keyLen;
          if (off <= sharesEnd) keyShares.putIfAbsent(group, () => keyLen);
        }
      }
      pos += extLen;
    }
    return ClientHelloInfo(cipherSuites: suites, keyShares: keyShares);
  } catch (_) {
    return ClientHelloInfo.empty;
  }
}

/// Wraps arbitrary bytes into TLS application-data records.
///
/// A single record must not exceed 16 KiB; larger writes are split into
/// multiple records so the outer shape remains valid TLS.
Uint8List wrapTlsRecords(Uint8List data) {
  final out = BytesBuilder(copy: false);
  var offset = 0;
  while (offset < data.length) {
    final end = min(offset + tlsAppDataMax, data.length);
    final chunk = data.sublist(offset, end);
    out
      ..addByte(tlsRecordAppData)
      ..add(_u16(tlsVersion12))
      ..add(_u16(chunk.length))
      ..add(chunk);
    offset = end;
  }
  return out.takeBytes();
}

class FakeTlsClosed implements Exception {
  const FakeTlsClosed();
}

/// Decodes TLS application-data records and writes them back in the same shape.
class FakeTlsStream implements ProxyTransport {
  FakeTlsStream(this._transport);

  final ProxyTransport _transport;
  final BytesBuilder _raw = BytesBuilder(copy: false);
  final BytesBuilder _readBuffer = BytesBuilder(copy: false);
  bool _closed = false;

  @override
  bool get isClosed => _closed || _transport.isClosed;

  /// Reads exactly [length] decoded application bytes.
  ///
  /// One TLS record can contain more data than the caller asked for, so the
  /// overshoot is put back into [_readBuffer] for the next call.
  Future<Uint8List> readExact(int length) async {
    while (_readBuffer.length < length) {
      final payload = await _readTlsPayload();
      if (payload == null) throw const FakeTlsClosed();
      _readBuffer.add(payload);
    }
    final all = _readBuffer.takeBytes();
    final result = Uint8List.fromList(all.sublist(0, length));
    if (all.length > length) _readBuffer.add(all.sublist(length));
    return result;
  }

  @override
  Future<Uint8List?> receive() => _readTlsPayload();

  /// Reads one TLS record and returns only application data.
  ///
  /// TLS 1.3 sends a ChangeCipherSpec record between ServerHello and appdata;
  /// it has no payload for us, so skip it and keep looking. A close/alert or
  /// any other record type ends the stream.
  Future<Uint8List?> _readTlsPayload() async {
    while (true) {
      final header = await _readRawExact(5);
      if (header == null) return null;
      final type = header[0];
      final length = (header[3] << 8) | header[4];

      if (type == tlsRecordCcs) {
        // CCS body is normally one byte; consume it so the next header aligns.
        if (length > 0) await _readRawExact(length);
        continue;
      }
      if (type != tlsRecordAppData) return null;
      return _readRawExact(length);
    }
  }

  /// Reads exactly [length] raw TLS bytes from the underlying transport.
  ///
  /// A transport read may return a partial record or several records at once;
  /// keep the overshoot in [_raw] so the next header starts at the right byte.
  Future<Uint8List?> _readRawExact(int length) async {
    while (_raw.length < length) {
      final chunk = await _transport.receive();
      if (chunk == null || chunk.isEmpty) return null;
      _raw.add(chunk);
    }
    final all = _raw.takeBytes();
    if (all.length > length) _raw.add(all.sublist(length));
    return Uint8List.fromList(all.sublist(0, length));
  }

  @override
  Future<void> send(Uint8List data) async {
    if (_closed) throw const FakeTlsClosed();
    // The peer expects TLS application-data records, not raw MTProto bytes.
    await _transport.send(wrapTlsRecords(data));
  }

  @override
  Future<void> close() async {
    // Server shutdown and a client error may race; close only once.
    if (_closed) return;
    _closed = true;
    await _transport.close();
  }
}

int _readU16(Uint8List data, int offset) =>
    (data[offset] << 8) | data[offset + 1];

Uint8List _u16(int value) =>
    Uint8List.fromList([(value >> 8) & 0xff, value & 0xff]);

Uint8List _u24(int value) => Uint8List.fromList(
    [(value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff]);
