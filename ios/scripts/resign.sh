#!/usr/bin/env bash
# Re-sign the Flutter iOS build after `flutter build ios --release`.
# Flutter/Xcode leaves Flutter.framework's Info.plist unbound on this toolchain;
# this script signs nested code first, then the extension and the app with the
# entitlements from the matching provisioning profiles.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:-$ROOT/build/ios/iphoneos/Runner.app}"
TEAM="${TGWS_TEAM:-2XZ277USL9}"
IDENTITY="${TGWS_IDENTITY:-Apple Development: Mark Koh (K92S8544K6)}"
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

find_profile() {
  local wanted="$1"
  local file id
  for file in "$PROFILES"/*.mobileprovision; do
    [ -e "$file" ] || continue
    id="$(security cms -D -i "$file" 2>/dev/null \
      | plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null || true)"
    if [ "$id" = "$wanted" ]; then
      printf '%s' "$file"
      return 0
    fi
  done
  return 1
}

sign_path() {
  local path="$1"
  local entitlements="${2:-}"
  [ -e "$path" ] || return 0
  if [ -n "$entitlements" ]; then
    codesign --force --timestamp=none --sign "$IDENTITY" \
      --entitlements "$entitlements" "$path"
  else
    codesign --force --timestamp=none --sign "$IDENTITY" "$path"
  fi
}

APP_PROFILE="$(find_profile "$TEAM.com.whitetigersoft.tgwsproxy")" || {
  echo "App provisioning profile not found" >&2; exit 1;
}
TUNNEL_PROFILE="$(find_profile "$TEAM.com.whitetigersoft.tgwsproxy.tunnel")" || {
  echo "Tunnel provisioning profile not found" >&2; exit 1;
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
security cms -D -i "$APP_PROFILE" 2>/dev/null \
  | plutil -extract Entitlements xml1 -o "$TMP/app.xcent" -
security cms -D -i "$TUNNEL_PROFILE" 2>/dev/null \
  | plutil -extract Entitlements xml1 -o "$TMP/tunnel.xcent" -

# Nested frameworks must not inherit app entitlements.
while IFS= read -r -d '' framework; do
  sign_path "$framework"
done < <(find "$APP/Frameworks" -maxdepth 1 -name '*.framework' -print0)

while IFS= read -r -d '' appex; do
  sign_path "$appex" "$TMP/tunnel.xcent"
done < <(find "$APP/PlugIns" -maxdepth 1 -name '*.appex' -print0)

sign_path "$APP" "$TMP/app.xcent"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Re-signed: $APP"
