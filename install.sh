#!/bin/sh
# Install Whorl.
#
#   curl -fsSL https://raw.githubusercontent.com/fenil210-cactus/whorl/main/install.sh | sh
#
# Options (environment):
#   WHORL_ZIP=path/to/Whorl.zip   install a local build instead of downloading
#   WHORL_APP_DIR=…               where Whorl.app goes   (default /Applications, else ~/Applications)
#   WHORL_BIN_DIR=…               where the `whorl` command goes (default /usr/local/bin, else ~/.local/bin)
#   WHORL_NO_LAUNCH=1             do not open the app afterwards
#   ./install.sh --uninstall      remove the app and the command
set -eu

REPO="fenil210-cactus/whorl"
APP_NAME="Whorl.app"
LINK_NAME="whorl"

say() { printf '%s\n' "$*"; }
die() { printf 'whorl install: %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "Whorl runs on macOS."
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 13 ] || die "Whorl needs macOS 13 or newer."

pick_dir() { # <preferred> <fallback>
  if [ -d "$1" ] && [ -w "$1" ]; then printf '%s' "$1"; else mkdir -p "$2"; printf '%s' "$2"; fi
}
APP_DIR="${WHORL_APP_DIR:-$(pick_dir /Applications "$HOME/Applications")}"
BIN_DIR="${WHORL_BIN_DIR:-$(pick_dir /usr/local/bin "$HOME/.local/bin")}"
DEST="$APP_DIR/$APP_NAME"
LINK="$BIN_DIR/$LINK_NAME"

if [ "${1:-}" = "--uninstall" ]; then
  pkill -x Whorl 2>/dev/null || true
  rm -rf "$DEST" "/Applications/$APP_NAME" "$HOME/Applications/$APP_NAME"
  rm -f "$LINK" "/usr/local/bin/$LINK_NAME" "$HOME/.local/bin/$LINK_NAME"
  say "Removed Whorl. Your settings stay in ~/Library/Preferences/com.fenil210.whorl.plist."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ZIP="${WHORL_ZIP:-${1:-}}"
if [ -z "$ZIP" ]; then
  BASE="https://github.com/$REPO/releases/latest/download"
  say "Downloading Whorl…"
  curl -fL --progress-bar "$BASE/Whorl.zip" -o "$TMP/Whorl.zip" || die "Could not download a release. Is there one yet? https://github.com/$REPO/releases"
  if curl -fsSL "$BASE/Whorl.zip.sha256" -o "$TMP/Whorl.zip.sha256" 2>/dev/null; then
    WANT=$(cut -d' ' -f1 "$TMP/Whorl.zip.sha256")
    GOT=$(shasum -a 256 "$TMP/Whorl.zip" | cut -d' ' -f1)
    [ "$WANT" = "$GOT" ] || die "Download failed its checksum. Try again."
  fi
  ZIP="$TMP/Whorl.zip"
fi
[ -f "$ZIP" ] || die "No such file: $ZIP"

ditto -x -k "$ZIP" "$TMP/unpacked"
[ -d "$TMP/unpacked/$APP_NAME" ] || die "That zip does not contain $APP_NAME."

pkill -x Whorl 2>/dev/null || true
mkdir -p "$APP_DIR" "$BIN_DIR"
rm -rf "$DEST"
ditto "$TMP/unpacked/$APP_NAME" "$DEST"
# The app is signed ad hoc (no paid Apple account), so clear the download flag instead of asking you to right-click → Open.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
ln -sfn "$DEST/Contents/MacOS/Whorl" "$LINK"

say "Installed $DEST"
say "Command:   $LINK"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) say "Note: add $BIN_DIR to your PATH to use the \`whorl\` command." ;; esac

if [ -z "${WHORL_NO_LAUNCH:-}" ]; then
  open "$DEST"
  say "Whorl is open. Look for its icon in the menu bar, or drop a file on its window."
fi
