// Purpose: Protocol constants: handshake, tags, DC IPs, WS paths.
/// MTProto obfuscated2 and transport constants.
///
/// Ported from Flowseal's `proxy/utils.py`.
library;

/// Length of the obfuscated2 init/handshake block.
const int handshakeLen = 64;

/// Offset of the pre-key inside the handshake.
const int skipLen = 8;

/// AES key length used by obfuscated2.
const int prekeyLen = 32;

/// AES key length.
const int keyLen = 32;

/// AES-CTR IV length.
const int ivLen = 16;

/// Offset of the transport protocol tag in the decrypted handshake.
const int protoTagPos = 56;

/// Offset of the signed DC id in the decrypted handshake.
const int dcIdxPos = 60;

/// Abridged transport tag.
const List<int> protoTagAbridged = [0xEF, 0xEF, 0xEF, 0xEF];

/// Intermediate transport tag.
const List<int> protoTagIntermediate = [0xEE, 0xEE, 0xEE, 0xEE];

/// Padded intermediate transport tag.
const List<int> protoTagPaddedIntermediate = [0xDD, 0xDD, 0xDD, 0xDD];

/// Abridged transport tag as a little-endian int.
const int protoAbridgedInt = 0xEFEFEFEF;

/// Intermediate transport tag as a little-endian int.
const int protoIntermediateInt = 0xEEEEEEEE;

/// Padded intermediate transport tag as a little-endian int.
const int protoPaddedIntermediateInt = 0xDDDDDDDD;

/// First byte that must not start an obfuscated2 init.
const int reservedFirstByte = 0xEF;

/// Four-byte prefixes that must not start an obfuscated2 init.
const List<List<int>> reservedStarts = [
  [0x48, 0x45, 0x41, 0x44], // HEAD
  [0x50, 0x4F, 0x53, 0x54], // POST
  [0x47, 0x45, 0x54, 0x20], // GET
  [0xEE, 0xEE, 0xEE, 0xEE],
  [0xDD, 0xDD, 0xDD, 0xDD],
  [0x16, 0x03, 0x01, 0x02], // TLS 1.0 record
  [0x4F, 0x50, 0x54, 0x49], // OPTI
];

/// Bytes 4..8 must not be all zero.
const List<int> reservedContinue = [0, 0, 0, 0];

/// Telegram DC addresses used when the user leaves DC selection on auto.
const Map<int, String> dcDefaultIps = {
  1: '149.154.175.50',
  2: '149.154.167.51',
  3: '149.154.175.100',
  4: '149.154.167.91',
  5: '149.154.171.5',
  203: '91.105.192.100',
};

/// Telegram test DC addresses.
const Map<int, String> dcTestIps = {
  1: '149.154.175.10',
  2: '149.154.167.40',
  3: '149.154.175.117',
};

/// Path of the Cloudflare Worker/WebSocket endpoint.
const String wsPath = '/apiws';

/// Path used for test DCs.
const String wsPathTest = '${wsPath}_test';

/// Returns the WebSocket host names for a DC (mirrors Python `ws_domains`).
List<String> wsDomains(int dc, bool isMedia) {
  final normalized = dc == 203 ? 2 : dc;
  if (!isMedia) {
    return ['kws$normalized.web.telegram.org'];
  }
  return [
    'kws$normalized-1.web.telegram.org',
    'kws$normalized.web.telegram.org',
  ];
}
