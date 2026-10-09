#!/usr/bin/env bash
# Builds a ready runner VM disk with the runner PAT inside; import it as the VM's system disk.
# Usage: ./image.sh <host> <out.img>   (hosts: flake.nix; reads the PAT from stdin)
# The output is fully allocated raw: some hypervisors size an imported disk by its file size.
set -euo pipefail
host=${1:?usage: image.sh <host> <out.img>}
out=${2:?usage: image.sh <host> <out.img>}
here=$(cd "$(dirname "$0")" && pwd)

read -rsp "Runner PAT: " token; echo
[ -n "$token" ] || { echo "empty token" >&2; exit 1; }
read -rsp "Console root password (blank: root stays locked): " password; echo
if [ -n "$password" ]; then
  hash=$(printf '%s' "$password" | nix shell nixpkgs#mkpasswd -c mkpasswd -m yescrypt -s)
else
  hash='!'
fi

built=$(nix build "$here#nixosConfigurations.$host.config.system.build.diskoImages" --no-link --print-out-paths)
work="$out.qcow2"
install -m 600 "$built/main.qcow2" "$work"
trap 'rm -f "$work"' EXIT

printf '%s' "$token" | nix shell nixpkgs#libguestfs-with-appliance -c guestfish --rw -a "$work" \
  -m /dev/disk/by-partlabel/disk-main-root \
  mkdir-p /var/lib/ci-secrets : chmod 0700 /var/lib/ci-secrets \
  : upload - /var/lib/ci-secrets/token : chmod 0600 /var/lib/ci-secrets/token
printf '%s\n' "$hash" | nix shell nixpkgs#libguestfs-with-appliance -c guestfish --rw -a "$work" \
  -m /dev/disk/by-partlabel/disk-main-root \
  upload - /var/lib/ci-secrets/root-password : chmod 0600 /var/lib/ci-secrets/root-password

install -m 600 /dev/null "$out"
nix shell nixpkgs#qemu-utils -c qemu-img convert -f qcow2 -O raw -S 0 "$work" "$out"
chmod 600 "$out"
echo "$out holds the runner PAT; delete it once the VM has booted."
