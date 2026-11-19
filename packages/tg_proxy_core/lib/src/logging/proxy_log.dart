// Purpose: shared Talker instance for the pure-Dart proxy core.
//
// The headless engine forwards these records to Kotlin, which relays them to
// the UI logs screen. Keeping one instance here means every transport and
// bridge event has the same source and ordering.
import 'package:talker/talker.dart';

final Talker proxyTalker = Talker(
  settings: TalkerSettings(maxHistoryItems: 2000),
);

/// Short helpers used by the core so call sites stay readable.
void proxyInfo(String message) => proxyTalker.info(message);

void proxyDebug(String message) => proxyTalker.debug(message);

void proxyWarning(String message) => proxyTalker.warning(message);

void proxyError(String message, [Object? error, StackTrace? stackTrace]) {
  proxyTalker.error(message, error, stackTrace);
}
