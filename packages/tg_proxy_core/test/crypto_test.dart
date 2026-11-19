import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tg_proxy_core/tg_proxy_core.dart';

void main() {
  group('AES-256-CTR', () {
    const keyHex =
        '603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4';
    const ivHex = 'f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff';
    const plainHex =
        '6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51';
    const cipherHex =
        '601ec313775789a5b7a7f504bbf3d228f443e3ca4d62b59aca84e990cacaf5c5';

    test('matches the NIST SP 800-38A vector', () {
      final key = hexToBytes(keyHex);
      final iv = hexToBytes(ivHex);
      final plain = hexToBytes(plainHex);
      final cipher = AesCtr(key, iv).process(plain);
      expect(bytesToHex(cipher), cipherHex);
    });

    test('skip advances the same keystream as processing zeros', () {
      final key = hexToBytes(keyHex);
      final iv = hexToBytes(ivHex);
      final skipped = AesCtr(key, iv)..skip(64);
      final reference = AesCtr(key, iv).process(Uint8List(80));

      expect(
        bytesToHex(skipped.process(Uint8List(16))),
        bytesToHex(reference.sublist(64)),
      );
    });

    test('incremental processing matches one-shot processing', () {
      final key = hexToBytes(keyHex);
      final iv = hexToBytes(ivHex);
      final plain = hexToBytes(plainHex);
      final oneShot = AesCtr(key, iv).process(plain);

      final incremental = AesCtr(key, iv);
      final first = incremental.process(plain.sublist(0, 13));
      final second = incremental.process(plain.sublist(13));
      expect([...first, ...second], oneShot);
    });
  });
}
