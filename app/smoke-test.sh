#!/usr/bin/env bash
# smoke-test.sh — exercise the release host end to end against a throwaway
# data dir and a throwaway signing key.
#
# Every assertion here corresponds to a way this service could fail OPEN --
# serve something it should not, or accept something it should refuse. The
# partial-release case is not hypothetical: an amd64-only build was once
# promoted to `stable` and 404'd install.sh on three of four platforms while
# every CI run showed green.
#
# Usage:  app/smoke-test.sh [port]
set -euo pipefail

PORT="${1:-8799}"
H="http://127.0.0.1:$PORT"
TOKEN="smoke-token-0123456789abcdef0123456789abcdef"
AUTH="Authorization: Bearer $TOKEN"
WORK="$(mktemp -d)"
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_PID=""

cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

pass=0; fail=0
chk() {
  if [[ "$2" == "$3" ]]; then printf '  ✓ %-46s %s\n' "$1" "$3"; pass=$((pass+1))
  else printf '  ✗ %-46s want %s got %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
code() { curl -sS -o /dev/null -w '%{http_code}' "$@"; }

command -v minisign >/dev/null || { echo "minisign required"; exit 1; }

echo "▸ building a signed fixture release"
mkdir -p "$WORK/data" "$WORK/fix/b"
minisign -G -W -p "$WORK/test.pub" -s "$WORK/test.key" >/dev/null 2>&1
printf '#!/bin/sh\necho smoke\n' > "$WORK/fix/b/conusai"
chmod +x "$WORK/fix/b/conusai"
( cd "$WORK/fix"
  for t in linux-amd64 linux-arm64 darwin-amd64 darwin-arm64; do
    tar -czf "conusai-$t.tar.gz" -C b conusai
    shasum -a 256 "conusai-$t.tar.gz" > "conusai-$t.tar.gz.sha256"
    minisign -S -s "$WORK/test.key" -x "conusai-$t.tar.gz.minisig" \
      -m "conusai-$t.tar.gz" -t "smoke" >/dev/null
  done
  rm -rf b
  cat ./*.tar.gz.sha256 > checksums.txt
  printf '#!/usr/bin/env bash\necho installer\n' > install.sh )

echo "▸ starting server"
CONUSAI_DATA_DIR="$WORK/data" CONUSAI_PUBLISH_TOKEN="$TOKEN" \
PORT="$PORT" PUBLIC_URL="$H" bun run "$APP_DIR/server.ts" > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 40); do
  curl -fsS "$H/healthz" >/dev/null 2>&1 && break
  sleep 0.25
done

echo
echo "── refuses before anything is published ──"
chk "healthz"                 200 "$(code "$H/healthz")"
chk "landing renders empty"   200 "$(code "$H/")"
chk "no channel yet"          404 "$(code "$H/channels/beta")"
chk "install.sh unavailable"  503 "$(code "$H/install.sh")"

echo
echo "── authentication and path safety ──"
chk "PUT without token"       401 "$(code -X PUT --data x "$H/api/releases/v1.0.0/a.txt")"
chk "PUT wrong token"         401 "$(code -X PUT -H 'Authorization: Bearer nope-nope-nope-nope-nope-nope-nope' --data x "$H/api/releases/v1.0.0/a.txt")"
chk "traversal in filename"   400 "$(code -X PUT -H "$AUTH" --data x "$H/api/releases/v1.0.0/..%2f..%2fetc%2fpasswd")"
chk "traversal in tag"        400 "$(code -X PUT -H "$AUTH" --data x "$H/api/releases/..%2f..%2fetc/x")"
chk "non-version tag"         400 "$(code -X PUT -H "$AUTH" --data x "$H/api/releases/notaversion/a.txt")"
chk "unknown channel"         400 "$(code -X POST -H "$AUTH" --data v1.0.0 "$H/api/channels/wibble")"

echo
echo "── publish lifecycle ──"
for f in "$WORK"/fix/*; do
  code -X PUT -H "$AUTH" --data-binary "@$f" "$H/api/releases/v9.9.9-smoke.1/$(basename "$f")" >/dev/null
done
chk "invisible before finalize" 404 "$(code "$H/releases/v9.9.9-smoke.1/checksums.txt")"
chk "promote before finalize"   409 "$(code -X POST -H "$AUTH" --data 'v9.9.9-smoke.1' "$H/api/channels/beta")"
chk "finalize"                  200 "$(code -X POST -H "$AUTH" "$H/api/releases/v9.9.9-smoke.1/finalize")"
chk "artifact served"           200 "$(code "$H/releases/v9.9.9-smoke.1/conusai-linux-amd64.tar.gz")"
chk "immutable without force"   409 "$(code -X PUT -H "$AUTH" --data x "$H/api/releases/v9.9.9-smoke.1/a.txt")"
chk "promote beta"              200 "$(code -X POST -H "$AUTH" --data 'v9.9.9-smoke.1' "$H/api/channels/beta")"
chk "channel resolves"          "v9.9.9-smoke.1" "$(curl -fsS "$H/channels/beta" | tr -d '\n')"
chk "install.sh served"         200 "$(code "$H/install.sh")"
chk "delete promoted blocked"   409 "$(code -X DELETE -H "$AUTH" "$H/api/releases/v9.9.9-smoke.1")"

L="$(shasum -a 256 "$WORK/fix/conusai-linux-amd64.tar.gz" | awk '{print $1}')"
R="$(curl -fsSL "$H/releases/v9.9.9-smoke.1/conusai-linux-amd64.tar.gz" | shasum -a 256 | awk '{print $1}')"
chk "served bytes match local"  "$L" "$R"
chk "range request"             206 "$(code -H 'Range: bytes=0-99' "$H/releases/v9.9.9-smoke.1/conusai-linux-amd64.tar.gz")"

echo
echo "── finalize refuses damaged releases ──"
printf 'tampered' > "$WORK/bad.tar.gz"
code -X PUT -H "$AUTH" --data-binary "@$WORK/bad.tar.gz"                       "$H/api/releases/v9.9.9-smoke.2/conusai-linux-amd64.tar.gz" >/dev/null
code -X PUT -H "$AUTH" --data-binary "@$WORK/fix/conusai-linux-amd64.tar.gz.sha256"  "$H/api/releases/v9.9.9-smoke.2/conusai-linux-amd64.tar.gz.sha256" >/dev/null
code -X PUT -H "$AUTH" --data-binary "@$WORK/fix/conusai-linux-amd64.tar.gz.minisig" "$H/api/releases/v9.9.9-smoke.2/conusai-linux-amd64.tar.gz.minisig" >/dev/null
code -X PUT -H "$AUTH" --data-binary "@$WORK/fix/install.sh"                    "$H/api/releases/v9.9.9-smoke.2/install.sh" >/dev/null
chk "checksum mismatch rejected" 400 "$(code -X POST -H "$AUTH" "$H/api/releases/v9.9.9-smoke.2/finalize")"

code -X PUT -H "$AUTH" --data-binary "@$WORK/fix/conusai-linux-amd64.tar.gz"        "$H/api/releases/v9.9.9-smoke.3/conusai-linux-amd64.tar.gz" >/dev/null
code -X PUT -H "$AUTH" --data-binary "@$WORK/fix/conusai-linux-amd64.tar.gz.sha256" "$H/api/releases/v9.9.9-smoke.3/conusai-linux-amd64.tar.gz.sha256" >/dev/null
code -X PUT -H "$AUTH" --data-binary "@$WORK/fix/install.sh"                        "$H/api/releases/v9.9.9-smoke.3/install.sh" >/dev/null
chk "unsigned artifact rejected" 400 "$(code -X POST -H "$AUTH" "$H/api/releases/v9.9.9-smoke.3/finalize")"

echo
echo "── the amd64-only incident ──"
for f in conusai-linux-amd64.tar.gz conusai-linux-amd64.tar.gz.sha256 conusai-linux-amd64.tar.gz.minisig install.sh; do
  code -X PUT -H "$AUTH" --data-binary "@$WORK/fix/$f" "$H/api/releases/v9.9.9-smoke.4/$f" >/dev/null
done
chk "partial release finalizes"       200 "$(code -X POST -H "$AUTH" "$H/api/releases/v9.9.9-smoke.4/finalize")"
chk "but will not promote"            409 "$(code -X POST -H "$AUTH" --data 'v9.9.9-smoke.4' "$H/api/channels/stable")"
chk "unless explicitly overridden"    200 "$(code -X POST -H "$AUTH" -H 'X-Conusai-Allow-Partial: true' --data 'v9.9.9-smoke.4' "$H/api/channels/stable")"

echo
if [[ "$fail" -eq 0 ]]; then
  echo "✓ all $pass checks passed"
else
  echo "✗ $fail of $((pass+fail)) checks FAILED"
  echo "--- server log ---"; cat "$WORK/server.log"
  exit 1
fi
