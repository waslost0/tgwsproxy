// Purpose: AES-256-CTR stream with protocol keystream skip.
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// AES-CTR stream that can process data incrementally.
///
/// MTProto obfuscated2 discards the first 64 bytes of each client/relay
/// keystream, so [skip] is part of the protocol rather than an optimisation.
class AesCtr {
  AesCtr(Uint8List key, Uint8List iv) : _cipher = CTRStreamCipher(AESEngine()) {
    if (key.length != 32) {
      throw ArgumentError.value(key.length, 'key', 'AES-256 requires 32 bytes');
    }
    if (iv.length != 16) {
      throw ArgumentError.value(iv.length, 'iv', 'AES-CTR requires 16 bytes');
    }
    _cipher.init(false, ParametersWithIV(KeyParameter(key), iv));
  }

  final CTRStreamCipher _cipher;

  /// XORs [data] with the next keystream bytes and advances the counter.
  Uint8List process(Uint8List data) => _cipher.process(data);

  /// Advances the keystream by [count] bytes without exposing the output.
  void skip(int count) {
    if (count < 0) {
      throw ArgumentError.value(count, 'count', 'must not be negative');
    }
    if (count > 0) {
      _cipher.process(Uint8List(count));
    }
  }
}
