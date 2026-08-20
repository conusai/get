#!/usr/bin/env bash
# ConusAI Cloud installer — https://get.conusai.com
#
#   curl -sSL https://get.conusai.com/install.sh | sh
#
# Installs the `conusai` binary (Linux x86_64 only for now), verifies its
# checksum (and minisign signature when the tooling is available), then
# hands off to `conusai setup` — the interactive wizard that configures
# either deployment mode:
#
#   Mode A — public server:  this machine has a public IP; everything
#            (proxy, TLS, apps, databases) runs right here.
#   Mode B — private origin: this machine stays off the public internet;
#            a tiny ConusAI "anchor" on any cheap VPS forwards traffic to
#            it over WireGuard. TLS still terminates HERE, on your origin.
#
# Non-interactive mode selection:  CONUSAI_MODE=a  or  CONUSAI_MODE=b
# Require signature verification:  CONUSAI_INSTALL_REQUIRE_SIG=1
# Pin a version:                   CONUSAI_VERSION=vX.Y.Z
set -euo pipefail

RELEASES="https://github.com/conusai/get/releases"
INSTALL_DIR="${CONUSAI_INSTALL_DIR:-/usr/local/bin}"
ASSET="conusai-linux-amd64.tar.gz"
# Trust root for release signatures (minisign). Must match the key the
# release pipeline signs with; see github.com/conusai for details.
MINISIGN_PUBKEY="RWQhgxhPH4i6u72ExVdBYcOzuVwM6nenoMd1nUCdlYj0lwRb/EbttgeI"

say()  { printf '\033[1;36m[conusai]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[conusai]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[conusai]\033[0m %s\n' "$*" >&2; exit 1; }

# ── Platform check ─────────────────────────────────────────────────────
[ "$(uname -s)" = "Linux" ]   || die "This installer supports Linux only (got: $(uname -s)). macOS/ARM builds: see $RELEASES"
[ "$(uname -m)" = "x86_64" ]  || die "This installer supports x86_64 only (got: $(uname -m))."
command -v curl >/dev/null    || die "curl is required."
command -v tar  >/dev/null    || die "tar is required."

# ── Docker check (runtime dependency, not needed to install) ───────────
if ! command -v docker >/dev/null 2>&1; then
  warn "Docker is not installed. ConusAI needs Docker to run apps and databases."
  warn "Install it first:  curl -fsSL https://get.docker.com | sh"
fi

# ── Resolve version ────────────────────────────────────────────────────
if [ -n "${CONUSAI_VERSION:-}" ]; then
  TAG="$CONUSAI_VERSION"
else
  TAG="$(curl -fsSL -o /dev/null -w '%{url_effective}' "$RELEASES/latest" | sed 's|.*/tag/||')"
  [ -n "$TAG" ] || die "Could not resolve the latest release tag."
fi
say "Installing ConusAI $TAG (linux/amd64)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BASE="$RELEASES/download/$TAG"

# ── Download + checksum ────────────────────────────────────────────────
say "Downloading $ASSET …"
curl -fSL --progress-bar -o "$TMP/$ASSET" "$BASE/$ASSET"
curl -fsSL -o "$TMP/$ASSET.sha256" "$BASE/$ASSET.sha256"
( cd "$TMP" && sha256sum -c "$ASSET.sha256" >/dev/null ) || die "Checksum verification FAILED — aborting."
say "Checksum OK."

# ── Signature (verified when minisign is available) ────────────────────
if curl -fsSL -o "$TMP/$ASSET.minisig" "$BASE/$ASSET.minisig" 2>/dev/null; then
  if command -v minisign >/dev/null 2>&1; then
    minisign -Vm "$TMP/$ASSET" -P "$MINISIGN_PUBKEY" -x "$TMP/$ASSET.minisig" >/dev/null \
      || die "Signature verification FAILED — aborting."
    say "Signature OK."
  else
    warn "minisign not installed — skipping signature verification."
    [ "${CONUSAI_INSTALL_REQUIRE_SIG:-0}" = "1" ] && die "CONUSAI_INSTALL_REQUIRE_SIG=1 but minisign is unavailable."
  fi
else
  warn "No signature published for this release — checksum-only verification."
  [ "${CONUSAI_INSTALL_REQUIRE_SIG:-0}" = "1" ] && die "CONUSAI_INSTALL_REQUIRE_SIG=1 but no signature is available."
fi

# ── Install ────────────────────────────────────────────────────────────
tar -xzf "$TMP/$ASSET" -C "$TMP"
[ -f "$TMP/conusai" ] || die "Archive did not contain the conusai binary."
chmod +x "$TMP/conusai"

if [ -w "$INSTALL_DIR" ]; then
  mv "$TMP/conusai" "$INSTALL_DIR/conusai"
elif command -v sudo >/dev/null 2>&1; then
  say "Installing to $INSTALL_DIR (sudo)…"
  sudo mv "$TMP/conusai" "$INSTALL_DIR/conusai"
else
  INSTALL_DIR="$HOME/.local/bin"
  mkdir -p "$INSTALL_DIR"
  mv "$TMP/conusai" "$INSTALL_DIR/conusai"
  warn "Installed to $INSTALL_DIR — make sure it is on your PATH."
fi
say "Installed: $("$INSTALL_DIR/conusai" --version 2>/dev/null || echo "$INSTALL_DIR/conusai")"

# ── Hand off to setup (Mode A / Mode B wizard) ─────────────────────────
MODE="${CONUSAI_MODE:-}"
case "$MODE" in
  [Aa]) say "Mode A (public server) selected via CONUSAI_MODE." ;;
  [Bb]) say "Mode B (private origin + anchor) selected via CONUSAI_MODE." ;;
  "")   : ;;
  *)    warn "Unknown CONUSAI_MODE='$MODE' (expected 'a' or 'b') — the wizard will ask." ; MODE="" ;;
esac

if [ -t 0 ] && [ -t 1 ]; then
  say "Launching the setup wizard…"
  exec "$INSTALL_DIR/conusai" setup ${MODE:+--mode "$MODE"}
else
  echo ""
  say "Done. Next step — run the setup wizard:"
  echo ""
  echo "    conusai setup          # asks: Mode A (public server) or Mode B (private origin)"
  echo ""
  say "Mode B pairs this machine with an anchor VPS over WireGuard; the wizard walks you through it."
fi
