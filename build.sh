#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# dev：常规应用，编译带 KORGI_DEV。Dock 和 ⌘Tab 里都有 Korgino。
# --release：发布包。最低系统 15.0，一份包 15 和 26 都能开。Pro 用 KORGI_TEST_PRO 开到 2026-12-31。
#   产出 dist/Korgino.app，不覆盖 ~/Applications。见 docs/adr/0074-one-package.md。
# --no-install：只产出 .app，不签本机证书，不覆盖 ~/Applications，不启动。给 CI 用。
# 见 docs/adr/0070-test-pro-until-year-end.md。主窗口之后不再写 LSUIElement。
RELEASE=0
NO_INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --release) RELEASE=1 ;;
    --no-install) NO_INSTALL=1 ;;
    --macos15|--macos26)
      echo "$arg was removed; one package covers macOS 15 and later. Use --release." >&2
      exit 1
      ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

APP=build/Korgino.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Prefer macOS 26.x SDK when available (host is 26.x).
SDKROOT_CANDIDATES=(
  "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
  "/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
  "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk"
  "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.sdk"
)
SDKROOT=""
for s in "${SDKROOT_CANDIDATES[@]}"; do
  if [[ -d "$s" ]]; then SDKROOT="$s"; break; fi
done
if [[ -z "$SDKROOT" ]]; then
  SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
fi
echo "Using SDKROOT=$SDKROOT"

if grep -E -n '^import (AppKit|SwiftUI|NaturalLanguage|Speech|AVFoundation|Security|Translation|ScreenCaptureKit|CoreMedia)' Engine/*.swift; then
  echo "Engine imports an Apple-only framework" >&2
  exit 1
fi

# Every L() key must exist in every language bundle; missing ones fall back to
# the Chinese source string and English users see it.
./tools/check-strings.sh

# Font sizes live in Theme.TypeScale. A raw .system(size: anywhere else means a
# size slipped past the seven steps.
if found=$(grep -n -F '.system(size:' Sources/*.swift | grep -v '^Sources/Theme.swift:'); then
  echo "$found" >&2
  echo "Sources/ uses .system(size: outside Theme.swift" >&2
  exit 1
fi

# One universal binary: arm64 for Apple silicon, x86_64 for Intel Macs still on macOS 15.
# Slices compile in parallel; lipo merges them. Deployment target stays 15.0.
SLICE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/korgino-slices.XXXXXX")"

compile_slice() {
  local arch="$1"
  echo "Compiling $arch"
  # 本机开发包带 KORGI_DEV，Pro 默认当作已购买。
  # --release 不带这个开关，改由 KORGI_TEST_PRO 把 Pro 开到 2026-12-31。
  local defines=(-D KORGI_DEV)
  if [[ "$RELEASE" -eq 1 ]]; then
    defines=(-D KORGI_TEST_PRO)
  fi
  swiftc -O -swift-version 5 "${defines[@]}" \
    -sdk "$SDKROOT" \
    -target "${arch}-apple-macosx15.0" \
    -framework Vision -framework Translation -framework Carbon \
    -Xlinker -weak_framework -Xlinker ScreenCaptureKit \
    -framework WebKit -framework PDFKit -framework Speech -framework AVFoundation -framework AVKit -framework StoreKit -framework Quartz -framework IOKit -framework CoreML -framework Accelerate -framework JavaScriptCore \
    Engine/*.swift Sources/*.swift \
    -o "$SLICE_DIR/Korgino-$arch"
}

compile_slice arm64 &
pid_arm=$!
compile_slice x86_64 &
pid_x86=$!
status=0
wait "$pid_arm" || status=$?
wait "$pid_x86" || status=$?
if [[ "$status" -ne 0 ]]; then
  echo "swiftc failed" >&2
  exit 1
fi

lipo -create "$SLICE_DIR/Korgino-arm64" "$SLICE_DIR/Korgino-x86_64" \
  -output "$APP/Contents/MacOS/Korgino"
rm -rf "$SLICE_DIR"
echo "Architectures: $(lipo -info "$APP/Contents/MacOS/Korgino")"
# Local symbols are only for crash logs and the debugger. Drop them before signing.
strip -x "$APP/Contents/MacOS/Korgino"
cp Info.plist "$APP/Contents/Info.plist"
# Classic Mac OS type/creator — helps Launch Services treat the bundle as APPL
echo -n 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -f Assets/AppIcon.icns ]]; then
  cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
if ls Resources/*.lproj >/dev/null 2>&1; then
  mkdir -p "$APP/Contents/Resources"
  cp -R Resources/*.lproj "$APP/Contents/Resources/"
fi
# AGPL-3.0 §4, Apache-2.0 §4(a), CC BY 4.0: ship the licence text and the change notes with the app.
mkdir -p "$APP/Contents/Resources/LICENSES"
cp LICENSE COPYRIGHT "$APP/Contents/Resources/"
cp LICENSES/*.txt "$APP/Contents/Resources/LICENSES/"
cp THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/"
if [[ -f Assets/MenuBarTemplate.png ]]; then
  cp Assets/MenuBarTemplate.png "$APP/Contents/Resources/"
  cp Assets/diana.k@example.org "$APP/Contents/Resources/" 2>/dev/null || true
fi
if [[ -d Assets/ProviderIcons ]]; then
  cp -R Assets/ProviderIcons "$APP/Contents/Resources/"
fi
if [[ -f Assets/WeChatQR.jpg ]]; then
  cp Assets/WeChatQR.jpg "$APP/Contents/Resources/WeChatQR.jpg"
fi
xattr -cr "$APP"

if [[ "$NO_INSTALL" -eq 1 ]]; then
  # CI has no login keychain and no Developer ID. Ad-hoc is enough to bundle a dmg.
  codesign --force --deep -s - "$APP"
  if [[ "$RELEASE" -eq 1 ]]; then
    mkdir -p dist
    rm -rf dist/Korgino.app dist/Korgino-macos15.app dist/Korgino-macos26.app
    cp -R "$APP" dist/Korgino.app
    echo "BUILD OK -> $PWD/dist/Korgino.app"
    echo "Release package: macOS 15 or later, regular app, Pro until 2026-12-31."
  else
    echo "BUILD OK -> $PWD/$APP"
  fi
  exit 0
fi

# A fixed self-signed identity keeps the designated requirement stable, so
# Accessibility / Input Monitoring grants survive rebuilds (docs/adr/0026).
SIGN_ID="Korgino Dev"
ensure_sign_identity() {
  local ids tmp
  ids="$(security find-identity -p codesigning 2>/dev/null || true)"
  [[ "$ids" == *"\"$SIGN_ID\""* ]] && return 0
  tmp="$(mktemp -d)"
  cat > "$tmp/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $SIGN_ID
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
  # /usr/bin/openssl (LibreSSL) writes a PKCS#12 that `security import` accepts.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cfg" \
      -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1 \
    && /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
      -name "$SIGN_ID" -passout pass:korgi -out "$tmp/id.p12" \
    && security import "$tmp/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
      -P korgi -T /usr/bin/codesign >/dev/null
  local ok=$?
  rm -rf "$tmp"
  return $ok
}
if ensure_sign_identity && codesign --force --deep -s "$SIGN_ID" "$APP" 2>/dev/null; then
  echo "Signed with $SIGN_ID"
else
  echo "WARNING: could not sign with \"$SIGN_ID\"; using ad-hoc. Re-grant Accessibility / Input Monitoring after this build." >&2
  codesign --force --deep -s - "$APP"
fi

if [[ "$RELEASE" -eq 1 ]]; then
  mkdir -p dist
  rm -rf dist/Korgino.app dist/Korgino-macos15.app dist/Korgino-macos26.app
  cp -R "$APP" dist/Korgino.app
  echo "BUILD OK -> $PWD/dist/Korgino.app"
  echo "Release package: macOS 15 or later, regular app, Pro until 2026-12-31."
  exit 0
fi

mkdir -p "$HOME/Applications"
# 三个名字都杀：改名前后留下的旧进程如果还活着，用户点到的是旧二进制的窗口。
pkill -x Korgino 2>/dev/null || true
pkill -x SelectTranslate 2>/dev/null || true
pkill -x KorgiTranslate 2>/dev/null || true
sleep 0.3

LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LSREG -u "$PWD/build/Korgino.app" 2>/dev/null || true
$LSREG -u "$HOME/Applications/Korgino.app" 2>/dev/null || true
$LSREG -u "$HOME/Applications/SelectTranslate.app" 2>/dev/null || true
rm -rf "$HOME/Applications/Korgino.app" "$HOME/Applications/SelectTranslate.app"
cp -R "$APP" "$HOME/Applications/"
# Do not leave the build-tree copy as the preferred LS registration
$LSREG -u "$PWD/build/Korgino.app" 2>/dev/null || true
$LSREG -f -R -trusted "$HOME/Applications/Korgino.app" 2>/dev/null || true

echo "BUILD OK -> $HOME/Applications/Korgino.app"
open "$HOME/Applications/Korgino.app"
