#!/usr/bin/env bash
# quader26: Flatcar host with a ZFS mirror and single-node k3s.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ign="$(build_example quader26)"

# --- base ---------------------------------------------------------------------
check "Ignition 3.4.0 (butane flatcar 1.1.0)" test "$(jq -r .ignition.version "$ign")" = 3.4.0
check "hostname" test "$(ign_file "$ign" /etc/hostname)" = quader26
check "core user has an ssh key" jqe '.passwd.users[] | select(.name == "core") | .sshAuthorizedKeys | length == 1' "$ign"

net="$(ign_file "$ign" /etc/systemd/network/10-static-eno1.network)"
check "networkd: matches eno1" contains "$net" "Name=eno1"
check "networkd: static address" contains "$net" "Address=192.168.123.123/24"
check "networkd: gateway" contains "$net" "Gateway=192.168.123.254"
check "networkd: dns" contains "$net" "DNS=9.9.9.9"
check "networkd: no ipv6 autoconf" contains "$net" "IPv6AcceptRA=no"
check "no NetworkManager keyfile" test -z "$(jq -r '.storage.files[].path | select(startswith("/etc/NetworkManager"))' "$ign")"

upd="$(ign_file "$ign" /etc/flatcar/update.conf)"
check "updates: stable channel" contains "$upd" "GROUP=stable"
check "updates: reboot strategy" contains "$upd" "REBOOT_STRATEGY=reboot"
check "updates: weekly window start" contains "$upd" 'LOCKSMITHD_REBOOT_WINDOW_START="Sun 04:00"'
check "updates: window length" contains "$upd" "LOCKSMITHD_REBOOT_WINDOW_LENGTH=1h"

check "docker-flatcar sysext disabled" test "$(ign_link "$ign" /etc/extensions/docker-flatcar.raw)" = /dev/null
check "containerd-flatcar sysext disabled" test "$(ign_link "$ign" /etc/extensions/containerd-flatcar.raw)" = /dev/null

finish
