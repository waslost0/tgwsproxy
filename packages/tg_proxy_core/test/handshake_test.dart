import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tg_proxy_core/tg_proxy_core.dart';

void main() {
  final secret = hexToBytes('000102030405060708090a0b0c0d0e0f');
  final prekeyIv = hexToBytes(
    '08090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    '202122232425262728292a2b2c2d2e2f3031323334353637',
  );
  final relayInit = hexToBytes(
    '000102030405060708090a0b0c0d0e0f1011121314151617'
    '18191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f'
    '303132333435363738393a3b3c3d3e3f',
  );

  group('tryHandshake', () {
    test('parses an abridged handshake for DC 2', () {
      final result = tryHandshake(
        hexToBytes(
          '000102030405060708090a0b0c0d0e0f1011121314151617'
          '18191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f'
          '30313233343536374d85959fbb083960',
        ),
        secret,
      );

      expect(result, isNotNull);
      expect(result!.dcId, 2);
      expect(result.isMedia, isFalse);
      expect(result.protoTag, protoTagAbridged);
      expect(bytesToHex(result.prekeyIv), bytesToHex(prekeyIv));
    });

    test('parses a media handshake for DC 4', () {
      final result = tryHandshake(
        hexToBytes(
          '000102030405060708090a0b0c0d0e0f1011121314151617'
          '18191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f'
          '30313233343536374c84949e45f73960',
        ),
        secret,
      );

      expect(result, isNotNull);
      expect(result!.dcId, 4);
      expect(result.isMedia, isTrue);
      expect(result.protoTag, protoTagIntermediate);
    });

    test('returns null for an unknown protocol tag', () {
      final result = tryHandshake(
        hexToBytes(
          '000102030405060708090a0b0c0d0e0f1011121314151617'
          '18191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f'
          '3031323334353637a3687974bb083960',
        ),
        secret,
      );
      expect(result, isNull);
    });

    test('rejects short handshakes and secrets', () {
      expect(
        () => tryHandshake(Uint8List(63), secret),
        throwsArgumentError,
      );
      expect(
        () => tryHandshake(Uint8List(64), Uint8List(15)),
        throwsArgumentError,
      );
    });
  });

  group('generateRelayInit', () {
    test('avoids reserved prefixes and encrypts proto/dc tail', () {
      final rng = Random(7);
      for (var i = 0; i < 100; i++) {
        final init = generateRelayInit(
          protoTagPaddedIntermediate,
          -4,
          random: rng,
        );

        expect(init, hasLength(64));
        expect(init[0], isNot(reservedFirstByte));
        expect(
          reservedStarts.any((start) => _startsWith(init, start)),
          isFalse,
        );
        expect(_startsWith(init, reservedContinue, offset: 4), isFalse);

        final keystream = AesCtr(
          Uint8List.fromList(init.sublist(8, 40)),
          Uint8List.fromList(init.sublist(40, 56)),
        ).process(Uint8List(64));
        final tail = List<int>.generate(
          8,
          (j) => init[56 + j] ^ keystream[56 + j],
        );

        expect(tail.sublist(0, 4), protoTagPaddedIntermediate);
        expect(
          ByteData.sublistView(
            Uint8List.fromList(tail),
          ).getInt16(4, Endian.little),
          -4,
        );
      }
    });
  });

  group('buildCryptoContext', () {
    test('matches Python keystreams after the 64-byte skip', () {
      final ctx = buildCryptoContext(prekeyIv, secret, relayInit);

      expect(
        bytesToHex(ctx.clientDecrypt.process(Uint8List(16))),
        '56decc6a1a716c4ddc43210950313d5c',
      );
      expect(
        bytesToHex(ctx.clientEncrypt.process(Uint8List(16))),
        'a009d788844755e13983ff70624a393b',
      );
      expect(
        bytesToHex(ctx.telegramEncrypt.process(Uint8List(16))),
        '32a9c12838f1654122b190bd1da2b20b',
      );
      expect(
        bytesToHex(ctx.telegramDecrypt.process(Uint8List(16))),
        '2f9de370decc064095d931e30a267b69',
      );
    });
  });
}

bool _startsWith(List<int> data, List<int> prefix, {int offset = 0}) {
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
