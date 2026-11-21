// Purpose: macOS-specific entrypoint for the shared desktop proxy backend.
import 'desktop_proxy_engine.dart';

/// Backwards-compatible macOS engine used by existing tests and integrations.
class MacProxyEngine extends DesktopProxyEngine {
  MacProxyEngine({super.directory}) : super(platform: 'macos');
}
