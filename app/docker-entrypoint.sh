#!/bin/sh
# Prepare the mounted volume, then drop privileges.
#
# Docker creates a fresh named volume owned by root:root. Running the server
# unprivileged from the start would leave it unable to create /data/releases on
# a first boot -- and the failure surfaces later, as an upload error, rather
# than at startup where it belongs.
set -eu

DATA_DIR="${CONUSAI_DATA_DIR:-/data}"

mkdir -p "$DATA_DIR/releases" "$DATA_DIR/channels"

# Only chown when it is actually wrong: on a volume holding hundreds of
# megabytes of artifacts, an unconditional recursive chown adds seconds to
# every restart for no reason.
if [ "$(stat -c '%u' "$DATA_DIR")" != "$(id -u bun)" ]; then
  echo "entrypoint: taking ownership of $DATA_DIR"
  chown -R bun:bun "$DATA_DIR"
fi

exec su-exec bun "$@"
