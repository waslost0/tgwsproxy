// Purpose: MTProto packet splitter for abridged/intermediate.
import 'dart:typed_data';

import '../constants.dart';

/// Splits a decrypted MTProto TCP stream into transport packets.
///
/// The wire bytes are ciphertext, so the splitter keeps a parallel plaintext
/// buffer only to read packet lengths. If a length is invalid, it stops
/// splitting and passes the rest through unchanged, matching the Python core.
class MsgSplitter {
  MsgSplitter(int protoInt) : _proto = protoInt;

  final int _proto;

  // The relay must forward the original ciphertext, but packet boundaries are
  // only visible after decryption. Keep both streams in lockstep.
  final BytesBuilder _cipherBuf = BytesBuilder(copy: false);
  final BytesBuilder _plainBuf = BytesBuilder(copy: false);
  bool _disabled = false;

  /// Returns complete ciphertext packets. [chunk] and [plain] must be the
  /// same length; [plain] is the decrypted form of [chunk].
  List<Uint8List> split(Uint8List chunk, Uint8List plain) {
    if (chunk.isEmpty) {
      return const [];
    }
    if (plain.length != chunk.length) {
      throw ArgumentError.value(
        plain.length,
        'plain',
        'must match chunk length ${chunk.length}',
      );
    }
    if (_disabled) {
      return [chunk];
    }

    // A single socket read can contain a partial frame or several frames.
    _cipherBuf.add(chunk);
    _plainBuf.add(plain);

    final cipher = _cipherBuf.toBytes();
    final plainBuf = _plainBuf.toBytes();
    final parts = <Uint8List>[];
    var offset = 0;
    final bufLen = cipher.length;

    while (offset < bufLen) {
      final packetLen = _nextPacketLen(plainBuf, offset, bufLen - offset);
      // Not enough bytes for the next length/header yet; keep the tail.
      if (packetLen == null) {
        break;
      }
      // The peer sent an impossible length. Stop interpreting the stream and
      // forward the remainder verbatim, as the Python implementation does.
      if (packetLen <= 0) {
        parts.add(
          Uint8List.fromList(
            offset == 0 ? cipher : cipher.sublist(offset),
          ),
        );
        offset = bufLen;
        _disabled = true;
        break;
      }
      if (offset == 0 && packetLen == bufLen) {
        parts.add(Uint8List.fromList(cipher));
      } else {
        parts.add(
            Uint8List.fromList(cipher.sublist(offset, offset + packetLen)));
      }
      offset += packetLen;
    }

    if (offset > 0) {
      _replaceBuffers(cipher.sublist(offset), plainBuf.sublist(offset));
    }
    return parts;
  }

  /// Returns any incomplete tail as a single packet.
  List<Uint8List> flush() {
    final cipher = _cipherBuf.toBytes();
    if (cipher.isEmpty) {
      return const [];
    }
    _replaceBuffers(Uint8List(0), Uint8List(0));
    return [Uint8List.fromList(cipher)];
  }

  int? _nextPacketLen(Uint8List plain, int offset, int avail) {
    if (avail <= 0) {
      return null;
    }
    // Abridged uses 1-byte or 4-byte headers; intermediate uses a 4-byte
    // little-endian length. Unknown protocols are passed through.
    if (_proto == protoAbridgedInt) {
      return _nextAbridgedLen(plain, offset, avail);
    }
    if (_proto == protoIntermediateInt ||
        _proto == protoPaddedIntermediateInt) {
      return _nextIntermediateLen(plain, offset, avail);
    }
    return 0;
  }

  int? _nextAbridgedLen(Uint8List plain, int offset, int avail) {
    final first = plain[offset];
    final int payloadLen;
    final int headerLen;
    // 0x7F/0xFF select the 3-byte little-endian long form. The length counts
    // 4-byte words, not bytes.
    if (first == 0x7F || first == 0xFF) {
      if (avail < 4) {
        return null;
      }
      payloadLen = (plain[offset + 1] |
              (plain[offset + 2] << 8) |
              (plain[offset + 3] << 16)) *
          4;
      headerLen = 4;
    } else {
      payloadLen = (first & 0x7F) * 4;
      headerLen = 1;
    }
    if (payloadLen <= 0) {
      return 0;
    }
    final packetLen = headerLen + payloadLen;
    return avail < packetLen ? null : packetLen;
  }

  int? _nextIntermediateLen(Uint8List plain, int offset, int avail) {
    if (avail < 4) {
      return null;
    }
    // Top bit is reserved for the transport; mask it before using the length.
    final payloadLen = (plain[offset] |
            (plain[offset + 1] << 8) |
            (plain[offset + 2] << 16) |
            (plain[offset + 3] << 24)) &
        0x7FFFFFFF;
    if (payloadLen <= 0) {
      return 0;
    }
    final packetLen = 4 + payloadLen;
    return avail < packetLen ? null : packetLen;
  }

  void _replaceBuffers(Uint8List cipher, Uint8List plain) {
    _cipherBuf.clear();
    _plainBuf.clear();
    if (cipher.isNotEmpty) {
      _cipherBuf.add(cipher);
      _plainBuf.add(plain);
    }
  }
}
