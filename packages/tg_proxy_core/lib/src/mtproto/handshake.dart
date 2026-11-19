// Purpose: Obfuscated2 handshake, relay init and crypto context.
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../constants.dart';
import '../crypto/aes_ctr.dart';

/// Result of a valid obfuscated2 client handshake.
class HandshakeResult {
  const HandshakeResult({
    required this.dcId,
    required this.isMedia,
    required this.protoTag,
    required this.prekeyIv,
  });

  final int dcId;
  final bool isMedia;
  final List<int> protoTag;
  final Uint8List prekeyIv;
}

/// Parses and decrypts a 64-byte obfuscated2 init.
///
/// Returns `null` for an unknown transport tag. Throws [ArgumentError] for
/// malformed lengths or secret.
HandshakeResult? tryHandshake(Uint8List handshake, Uint8List secret) {
  if (handshake.length != handshakeLen) {
    throw ArgumentError.value(
      handshake.length,
      'handshake',
      'must be $handshakeLen bytes',
    );
  }
  if (secret.length != 16) {
    throw ArgumentError.value(secret.length, 'secret', 'must be 16 bytes');
  }

  final prekeyIv = Uint8List.fromList(
    handshake.sublist(skipLen, skipLen + prekeyLen + ivLen),
  );
  final prekey = prekeyIv.sublist(0, prekeyLen);
  final iv = prekeyIv.sublist(prekeyLen);

  final decKey = sha256.convert([...prekey, ...secret]).bytes;
  final decrypted = AesCtr(Uint8List.fromList(decKey), iv).process(handshake);

  final protoTag = decrypted.sublist(protoTagPos, protoTagPos + 4);
  if (protoTagToInt(protoTag) == null) {
    return null;
  }

  final dcIdx = ByteData.sublistView(
    decrypted,
  ).getInt16(dcIdxPos, Endian.little);
  return HandshakeResult(
    dcId: dcIdx.abs(),
    isMedia: dcIdx < 0,
    protoTag: protoTag,
    prekeyIv: prekeyIv,
  );
}

/// Builds a 64-byte relay init that Telegram's DC will accept.
///
/// The first 56 bytes are random; the last 8 contain the encrypted protocol
/// tag, signed DC id and two random bytes.
Uint8List generateRelayInit(
  List<int> protoTag,
  int dcIdx, {
  Random? random,
}) {
  if (protoTag.length != 4) {
    throw ArgumentError.value(protoTag, 'protoTag', 'must be 4 bytes');
  }
  if (dcIdx < -0x8000 || dcIdx > 0x7FFF) {
    throw ArgumentError.value(dcIdx, 'dcIdx', 'must fit int16');
  }

  final rng = random ?? Random.secure();
  late Uint8List init;

  for (var attempt = 0; attempt < 100000; attempt++) {
    init = Uint8List.fromList(
      List<int>.generate(handshakeLen, (_) => rng.nextInt(256)),
    );
    if (init[0] == reservedFirstByte) {
      continue;
    }
    if (reservedStarts.any((start) => _startsWith(init, start))) {
      continue;
    }
    if (_startsWith(init, reservedContinue, offset: 4)) {
      continue;
    }
    break;
  }

  final encKey = init.sublist(skipLen, skipLen + prekeyLen);
  final encIv = init.sublist(skipLen + prekeyLen, skipLen + prekeyLen + ivLen);
  final keystream = AesCtr(
    Uint8List.fromList(encKey),
    Uint8List.fromList(encIv),
  ).process(Uint8List(handshakeLen));

  final tailPlain = Uint8List(8)
    ..setRange(0, 4, protoTag)
    ..[6] = rng.nextInt(256)
    ..[7] = rng.nextInt(256);
  ByteData.sublistView(tailPlain).setInt16(4, dcIdx, Endian.little);

  for (var i = 0; i < 8; i++) {
    init[protoTagPos + i] = tailPlain[i] ^ keystream[protoTagPos + i];
  }
  return init;
}

/// Four independent AES-CTR streams used by one MTProto bridge.
class MtProtoCryptoContext {
  const MtProtoCryptoContext({
    required this.clientDecrypt,
    required this.clientEncrypt,
    required this.telegramEncrypt,
    required this.telegramDecrypt,
  });

  final AesCtr clientDecrypt;
  final AesCtr clientEncrypt;
  final AesCtr telegramEncrypt;
  final AesCtr telegramDecrypt;
}

/// Derives client and relay streams from the client init and relay init.
///
/// Client decrypt and Telegram encrypt skip the first 64 keystream bytes,
/// matching the Python core.
MtProtoCryptoContext buildCryptoContext(
  Uint8List prekeyIv,
  Uint8List secret,
  Uint8List relayInit,
) {
  if (prekeyIv.length != prekeyLen + ivLen) {
    throw ArgumentError.value(
      prekeyIv.length,
      'prekeyIv',
      'must be 48 bytes',
    );
  }
  if (secret.length != 16) {
    throw ArgumentError.value(secret.length, 'secret', 'must be 16 bytes');
  }
  if (relayInit.length != handshakeLen) {
    throw ArgumentError.value(
      relayInit.length,
      'relayInit',
      'must be 64 bytes',
    );
  }

  final clientDecryptKey = sha256.convert([
    ...prekeyIv.sublist(0, prekeyLen),
    ...secret,
  ]).bytes;

  final reversed = Uint8List.fromList(prekeyIv.reversed.toList());
  final clientEncryptKey = sha256.convert([
    ...reversed.sublist(0, prekeyLen),
    ...secret,
  ]).bytes;

  final relayEncryptKey = relayInit.sublist(
    skipLen,
    skipLen + prekeyLen,
  );
  final relayEncryptIv = relayInit.sublist(
    skipLen + prekeyLen,
    skipLen + prekeyLen + ivLen,
  );

  final relayDecrypt = Uint8List.fromList(
    relayInit.sublist(skipLen, skipLen + prekeyLen + ivLen).reversed.toList(),
  );

  return MtProtoCryptoContext(
    clientDecrypt: AesCtr(
      Uint8List.fromList(clientDecryptKey),
      prekeyIv.sublist(prekeyLen),
    )..skip(handshakeLen),
    clientEncrypt: AesCtr(
      Uint8List.fromList(clientEncryptKey),
      reversed.sublist(prekeyLen),
    ),
    telegramEncrypt: AesCtr(
      Uint8List.fromList(relayEncryptKey),
      Uint8List.fromList(relayEncryptIv),
    )..skip(handshakeLen),
    telegramDecrypt: AesCtr(
      Uint8List.fromList(relayDecrypt.sublist(0, keyLen)),
      Uint8List.fromList(relayDecrypt.sublist(keyLen)),
    ),
  );
}

/// Converts a known 4-byte transport tag to its int value, or `null`.
int? protoTagToInt(List<int> tag) {
  if (tag.length != 4) {
    return null;
  }
  final value = ByteData.sublistView(
    Uint8List.fromList(tag),
  ).getUint32(0, Endian.little);
  return switch (value) {
    protoAbridgedInt ||
    protoIntermediateInt ||
    protoPaddedIntermediateInt =>
      value,
    _ => null,
  };
}

bool _startsWith(Uint8List data, List<int> prefix, {int offset = 0}) {
  if (offset + prefix.length > data.length) {
    return false;
  }
  for (var i = 0; i < prefix.length; i++) {
    if (data[offset + i] != prefix[i]) {
      return false;
    }
  }
  return true;
}
