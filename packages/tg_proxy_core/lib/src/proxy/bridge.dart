// Purpose: Bidirectional MTProto re-encryption bridge.
import 'dart:async';
import 'dart:typed_data';

import '../logging/proxy_log.dart';
import '../mtproto/handshake.dart';
import '../mtproto/splitter.dart';
import '../stats/proxy_stats.dart';
import '../transport/proxy_transport.dart';

// 64 KiB matches the upstream implementation and keeps memory bounded while
// still allowing large media packets.
const int bridgeChunkSize = 64 * 1024;

/// Relays MTProto between the client and Telegram, re-encrypting each direction.
Future<void> runMtProtoBridge({
  required ProxyTransport client,
  required ProxyTransport remote,
  required MtProtoCryptoContext crypto,
  required ProxyStats stats,
  MsgSplitter? splitter,
  int chunkSize = bridgeChunkSize,
}) async {
  var receivedUp = 0;
  var receivedDown = 0;

  Future<void> upstream() async {
    while (true) {
      final chunk = await client.receive();
      if (chunk == null) {
        proxyDebug('bridge: client closed');
        // The client closed: forward the last partial packet, if any.
        if (splitter != null) {
          for (final part in splitter.flush()) {
            await remote.send(part);
          }
        }
        return;
      }
      receivedUp += chunk.length;
      stats.bytesUp += chunk.length;

      // Telegram sees a different AES-CTR stream than the client. Decrypt with
      // the client key, then encrypt with the relay key. Slice the socket read
      // so one WS message stays under Cloudflare's 1 MiB limit.
      for (var offset = 0; offset < chunk.length; offset += chunkSize) {
        final end = offset + chunkSize < chunk.length
            ? offset + chunkSize
            : chunk.length;
        final slice = offset == 0 && end == chunk.length
            ? chunk
            : Uint8List.sublistView(chunk, offset, end);
        final plain = crypto.clientDecrypt.process(slice);
        if (receivedUp == chunk.length && offset == 0) {
          proxyDebug('bridge: first client chunk ${chunk.length} bytes');
        }
        final outbound = crypto.telegramEncrypt.process(plain);

        // For WS/CF routes Telegram expects individual MTProto frames; the
        // splitter needs plaintext only for lengths and forwards ciphertext.
        if (splitter != null) {
          final parts = splitter.split(outbound, plain);
          for (final part in parts) {
            await remote.send(part);
          }
        } else {
          await remote.send(outbound);
        }
      }

      // Yield after a full-size chunk so downstream reads are not starved on
      // a single-isolate event loop.
      if (chunk.length >= chunkSize) await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> downstream() async {
    while (true) {
      final chunk = await remote.receive();
      if (chunk == null) {
        proxyDebug('bridge: remote closed after $receivedDown bytes');
        return;
      }
      // Reverse direction: undo Telegram's relay encryption, then re-encrypt
      // with the client stream.
      final plain = crypto.telegramDecrypt.process(chunk);
      receivedDown += chunk.length;
      stats.bytesDown += chunk.length;
      if (receivedDown == chunk.length) {
        proxyDebug('bridge: first remote chunk ${chunk.length} bytes');
      }
      await client.send(crypto.clientEncrypt.process(plain));
    }
  }

  final tasks = <Future<void>>[upstream(), downstream()];
  Object? error;
  try {
    // A half-close ends the session; both directions share the same lifetime.
    await Future.any(tasks);
  } catch (caught) {
    error = caught;
  } finally {
    // Close both sides so the other pump cannot hang forever.
    await client.close();
    await remote.close();
  }

  // Do not await the other pump here: closing a socket can leave its blocked
  // read pending until a timeout. Both transports are already closed, so a
  // late error is only noise.
  proxyDebug('bridge: closed up=$receivedUp down=$receivedDown');
  if (error != null) {
    stats.errors++;
    proxyError('bridge failed: $error', error);
    throw error;
  }
}
