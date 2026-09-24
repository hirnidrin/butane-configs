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

# --- fans ---------------------------------------------------------------------
check "ipmitool sysext pinned by hash" test "$(ign_remote "$ign" /opt/extensions/ipmitool/ipmitool-1.8.19-x86-64.raw)" = \
	"https://github.com/hirnidrin/sysext-bakery/releases/download/ipmitool-1.8.19/ipmitool-1.8.19-x86-64.raw sha256-dd8a382ffa281566ff89ae9edd16f3149a3efbb97c943b7c7f3d98a0ef423e38"
check "ipmitool sysext merged" test "$(ign_link "$ign" /etc/extensions/ipmitool.raw)" = /opt/extensions/ipmitool/ipmitool-1.8.19-x86-64.raw
mods="$(ign_file "$ign" /etc/modules-load.d/ipmi.conf)"
check "ipmi_devintf loaded at boot" contains "$mods" ipmi_devintf
check "ipmi_si loaded at boot" contains "$mods" ipmi_si
fans="$(ign_file "$ign" /opt/bin/set-fanspeeds.sh)"
check "fan script in /opt/bin with duty substituted" contains "$fans" "0x70 0x66 0x01 0x00 0x2A"
check "nothing written under read-only /usr" test -z "$(jq -r '.storage.files[].path | select(startswith("/usr/"))' "$ign")"
fanunit="$(ign_unit "$ign" fanspeed.service)"
check "fanspeed.service enabled" ign_unit_enabled "$ign" fanspeed.service
check "fanspeed runs after sysexts are merged" contains "$fanunit" "After=systemd-sysext.service systemd-modules-load.service"
check "fanspeed calls /opt/bin" contains "$fanunit" "ExecStart=/opt/bin/set-fanspeeds.sh"

finish
