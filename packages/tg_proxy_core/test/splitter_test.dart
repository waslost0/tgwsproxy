import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tg_proxy_core/tg_proxy_core.dart';

void main() {
  Uint8List cipher(int length) =>
      Uint8List.fromList(List.generate(length, (i) => 0xA0 + i));

  Uint8List plain(List<int> bytes) => Uint8List.fromList(bytes);

  group('MsgSplitter abridged', () {
    test('emits a single short-form packet', () {
      final splitter = MsgSplitter(protoAbridgedInt);
      final data = cipher(9);
      final parts = splitter.split(data, plain([0x02, 0, 0, 0, 0, 0, 0, 0, 0]));
      expect(parts, hasLength(1));
      expect(parts.single, data);
    });

    test('emits a single long-form packet', () {
      final splitter = MsgSplitter(protoAbridgedInt);
      final data = cipher(12);
      final parts = splitter.split(
          data, plain([0x7F, 0x02, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0, 0]));
      expect(parts, hasLength(1));
      expect(parts.single, data);
    });

    test('emits two packets from one chunk', () {
      final splitter = MsgSplitter(protoAbridgedInt);
      final data = cipher(14);
      final parts = splitter.split(
          data, plain([0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0, 0, 0, 0]));
      expect(parts, hasLength(2));
      expect(parts[0], data.sublist(0, 9));
      expect(parts[1], data.sublist(9));
    });

    test('waits for a partial packet and keeps the tail for flush', () {
      final splitter = MsgSplitter(protoAbridgedInt);
      expect(splitter.split(cipher(4), plain([0x02, 0, 0, 0])), isEmpty);

      final rest = cipher(5);
      final parts = splitter.split(rest, plain([0x00, 0x00, 0x00, 0x00, 0x00]));
      expect(parts, hasLength(1));
      expect(parts.single, [...cipher(4), ...rest]);
    });
  });

  group('MsgSplitter intermediate', () {
    test('uses a 4-byte little-endian length', () {
      final splitter = MsgSplitter(protoIntermediateInt);
      final data = cipher(9);
      final parts =
          splitter.split(data, plain([0x05, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0]));
      expect(parts, hasLength(1));
      expect(parts.single, data);
    });

    test('padded intermediate uses the same framing', () {
      final splitter = MsgSplitter(protoPaddedIntermediateInt);
      final data = cipher(9);
      final parts =
          splitter.split(data, plain([0x05, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0]));
      expect(parts, hasLength(1));
      expect(parts.single, data);
    });

    test('waits for the length header', () {
      final splitter = MsgSplitter(protoIntermediateInt);
      expect(splitter.split(cipher(2), plain([0x05, 0x00])), isEmpty);
      final parts = splitter.flush();
      expect(parts, hasLength(1));
      expect(parts.single, cipher(2));
    });
  });

  group('MsgSplitter fallback', () {
    test('passes data through after an invalid length', () {
      final splitter = MsgSplitter(protoAbridgedInt);
      final first = cipher(3);
      final parts = splitter.split(first, plain([0x00, 0x00, 0x00]));
      expect(parts.single, first);

      final next = cipher(5);
      expect(splitter.split(next, plain([0x02, 0, 0, 0, 0])).single, next);
    });

    test('passes unknown transport data through unchanged', () {
      final splitter = MsgSplitter(0x01020304);
      final data = cipher(7);
      expect(splitter.split(data, plain([1, 2, 3, 4, 5, 6, 7])).single, data);
    });

    test('flush returns an incomplete tail once', () {
      final splitter = MsgSplitter(protoAbridgedInt);
      expect(splitter.split(cipher(4), plain([0x02, 0, 0, 0])), isEmpty);
      expect(splitter.flush().single, cipher(4));
      expect(splitter.flush(), isEmpty);
    });
  });
}
