// Purpose: Hex encoding helpers for secrets and vectors.
import 'dart:typed_data';

/// Encodes bytes as lowercase hex.
String bytesToHex(List<int> bytes) {
  final out = StringBuffer();
  for (final byte in bytes) {
    out.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

/// Decodes a hex string. Throws [FormatException] on odd length or bad input.
Uint8List hexToBytes(String hex) {
  if (hex.length.isOdd) {
    throw const FormatException('hex string must have an even length');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final byte = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    out[i] = byte;
  }
  return out;
}
