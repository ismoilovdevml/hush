#!/bin/bash
# Installs Hush from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/ismoilovdevml/hush/main/install.sh | bash
#
# Piping a script into a shell means trusting it, so read it first if you would rather:
#   curl -fsSL .../install.sh -o install.sh && less install.sh && bash install.sh
set -euo pipefail

REPO="ismoilovdevml/hush"
ASSET="Hush.app.zip"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# ---- what are we on? ----------------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "Hush is macOS only (this is $(uname -s))."

macos_version="$(sw_vers -productVersion)"
major="${macos_version%%.*}"
[ "$major" -ge 13 ] || die "macOS 13 or later is required (this is $macos_version)."

arch="$(uname -m)"
case "$arch" in
    arm64)  arch_label="Apple silicon" ;;
    x86_64) arch_label="Intel" ;;
    *)      die "unsupported architecture: $arch" ;;
esac

bold "Hush"
info "macOS $macos_version on $arch_label — supported"

# ---- find the release ---------------------------------------------------------------------

api="https://api.github.com/repos/$REPO/releases/latest"
release="$(curl -fsSL "$api")" || die "could not reach GitHub."

tag="$(printf '%s' "$release" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
url="$(printf '%s' "$release" \
    | tr ',' '\n' | sed -n 's/.*"browser_download_url": *"\([^"]*'"$ASSET"'\)".*/\1/p' | head -1)"
sums_url="$(printf '%s' "$release" \
    | tr ',' '\n' | sed -n 's/.*"browser_download_url": *"\([^"]*checksum.txt\)".*/\1/p' | head -1)"

[ -n "$url" ] || die "the latest release has no $ASSET. See https://github.com/$REPO/releases"
info "release $tag"

# ---- download and verify ------------------------------------------------------------------

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "$url" -o "$tmp/$ASSET" || die "download failed."

if [ -n "$sums_url" ] && curl -fsSL "$sums_url" -o "$tmp/checksum.txt" 2>/dev/null; then
    expected="$(awk '{print $1}' "$tmp/checksum.txt" | head -1)"
    actual="$(shasum -a 256 "$tmp/$ASSET" | awk '{print $1}')"
    [ "$expected" = "$actual" ] || die "checksum mismatch — refusing to install.
    expected $expected
    got      $actual"
    info "checksum verified"
else
    info "no checksum published for this release — skipping verification"
fi

# ---- install ------------------------------------------------------------------------------

if [ -w /Applications ]; then dest="/Applications"; else dest="$HOME/Applications"; fi
mkdir -p "$dest"

pkill -x Hush 2>/dev/null || true
rm -rf "$dest/Hush.app"
ditto -x -k "$tmp/$ASSET" "$tmp/unpacked"
mv "$tmp/unpacked/Hush.app" "$dest/Hush.app"

# The app is ad-hoc signed, not notarised. Without this, Gatekeeper refuses the first launch
# of anything downloaded from the internet.
xattr -dr com.apple.quarantine "$dest/Hush.app" 2>/dev/null || true
info "installed $dest/Hush.app"

# ---- the CLI ------------------------------------------------------------------------------

cli="$dest/Hush.app/Contents/Resources/hush"
if ln -sf "$cli" /usr/local/bin/hush 2>/dev/null; then
    info "linked /usr/local/bin/hush"
else
    mkdir -p "$HOME/.local/bin"
    ln -sf "$cli" "$HOME/.local/bin/hush"
    info "linked $HOME/.local/bin/hush"
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) info "add it to PATH, or run: sudo ln -sf '$cli' /usr/local/bin/hush" ;;
    esac
fi

open -a "$dest/Hush.app"

echo
bold "Done."
info "Hush is in your menu bar. Try: hush status"
