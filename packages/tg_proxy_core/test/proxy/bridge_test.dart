import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tg_proxy_core/tg_proxy_core.dart';

void main() {
  test('slices a large client read before sending upstream', () async {
    final chunk = Uint8List(200000);
    for (var i = 0; i < chunk.length; i++) {
      chunk[i] = i & 0xff;
    }
    final client = _Client(chunk);
    final remote = _Remote();
    final crypto = buildCryptoContext(
      Uint8List.fromList(List.generate(48, (i) => i)),
      Uint8List.fromList(List.generate(16, (i) => i)),
      Uint8List.fromList(List.generate(64, (i) => i)),
    );

    await runMtProtoBridge(
      client: client,
      remote: remote,
      crypto: crypto,
      stats: ProxyStats(),
    );

    expect(remote.sent, isNotEmpty);
    expect(remote.sent.every((data) => data.length <= bridgeChunkSize), isTrue);
    expect(
      remote.sent.fold<int>(0, (sum, data) => sum + data.length),
      chunk.length,
    );
  });
}

class _Client implements ProxyTransport {
  _Client(this._chunk);

  final Uint8List _chunk;
  var _reads = 0;
  var _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Future<Uint8List?> receive() async {
    if (_closed || _reads++ > 0) return null;
    return _chunk;
  }

  @override
  Future<void> send(Uint8List data) async {}

  @override
  Future<void> close() async {
    _closed = true;
  }
}

class _Remote implements ProxyTransport {
  final sent = <Uint8List>[];
  final _closed = Completer<void>();

  @override
  bool get isClosed => _closed.isCompleted;

  @override
  Future<Uint8List?> receive() async {
    await _closed.future;
    return null;
  }

  @override
  Future<void> send(Uint8List data) async {
    sent.add(data);
  }

  @override
  Future<void> close() async {
    if (!_closed.isCompleted) _closed.complete();
  }
}
