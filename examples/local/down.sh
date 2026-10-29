#!/usr/bin/env sh
# Removes the containers and everything up.sh and Conn3x created here.
set -eu
cd "$(dirname "$0")"
name=${NAME:-circuit-bind}
for c in "$name" "$name-secondary"; do
  ${PODMAN:-podman} rm -f -v "$c" >/dev/null 2>&1 || true
done
rm -rf id_ed25519 id_ed25519.pub known_hosts known_hosts.new .terraform .terraform.lock.hcl terraform.tfstate terraform.tfstate.backup
echo "Removed."
