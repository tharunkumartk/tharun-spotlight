#!/bin/bash
# Builds FastLauncher.app with the Xcode command line tools (no Xcode project),
# and installs fsearch if it isn't already.
#
#   ./build.sh            build into ./build
#   ./build.sh --install  also copy to /Applications and launch it
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null; then
  echo "swiftc not found. Install the command line tools first:  xcode-select --install" >&2
  exit 1
fi

ARCH="$(uname -m)"
APP="build/FastLauncher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Compiling ($ARCH)…"
swiftc -O -swift-version 5 \
  -target "$ARCH-apple-macos13.0" \
  -framework AppKit -framework Carbon -framework ServiceManagement \
  Sources/*.swift -o "$APP/Contents/MacOS/FastLauncher"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  (ad-hoc signing skipped)"
echo "  built $APP"

# fsearch: the CLI and daemon FastLauncher talks to.
if [ -x "$HOME/.local/bin/fsearch" ] || command -v fsearch >/dev/null; then
  echo "→ fsearch already installed"
else
  echo "→ Installing fsearch…"
  TMP="$(mktemp -d)"
  if [ "$ARCH" = "arm64" ]; then
    curl -fsSL https://github.com/noahdunnagan/fsearch/releases/latest/download/fsearch-aarch64-apple-darwin.tar.gz | tar xz -C "$TMP"
    "$TMP/fsearch" install
  elif command -v cargo >/dev/null; then
    git clone --depth 1 https://github.com/noahdunnagan/fsearch "$TMP/fsearch"
    (cd "$TMP/fsearch" && cargo build --release && ./target/release/fsearch install)
  else
    echo "  No prebuilt fsearch for Intel Macs. Install Rust (https://rustup.rs) and run this again." >&2
  fi
  rm -rf "$TMP"
fi

if [ "${1:-}" = "--install" ]; then
  echo "→ Installing to /Applications…"
  osascript -e 'quit app "FastLauncher"' >/dev/null 2>&1 || true
  rm -rf /Applications/FastLauncher.app
  cp -R "$APP" /Applications/
  open /Applications/FastLauncher.app
  echo "  done: look for the magnifying glass in the menu bar"
fi
