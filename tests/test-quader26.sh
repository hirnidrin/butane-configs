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

# --- zfs ----------------------------------------------------------------------
check "zfs sysext enabled" test "$(ign_file "$ign" /etc/flatcar/enabled-sysext.conf)" = zfs
check "pools found by scan on a fresh /etc" test \
	"$(ign_link "$ign" /etc/systemd/system/zfs-import.target.wants/zfs-import-scan.service)" = /usr/lib/systemd/system/zfs-import-scan.service
check "zfs udevd drop-in masked (flatcar/Flatcar#2422 boot deadlock)" test \
	"$(ign_link "$ign" /etc/systemd/system/systemd-udevd.service.d/10-zfs.conf)" = /dev/null
check "Ignition never touches disks" jqe '(.storage.disks // []) == [] and (.storage.filesystems // []) == []' "$ign"

# --- snapshots ----------------------------------------------------------------
snapconf="$(ign_file "$ign" /etc/zfs-autosnap.conf)"
check "snapshots: dataset" contains "$snapconf" "AUTOSNAP_DATASET=tank/projects"
check "snapshots: keep 24 hourly" contains "$snapconf" "AUTOSNAP_KEEP_HOURLY=24"
check "snapshots: keep 14 daily" contains "$snapconf" "AUTOSNAP_KEEP_DAILY=14"
check "snapshots: keep 8 weekly" contains "$snapconf" "AUTOSNAP_KEEP_WEEKLY=8"
check "snapshots: script installed executable" jqe '.storage.files[] | select(.path == "/opt/bin/zfs-autosnap") | .mode == 493' "$ign"
snapsvc="$(ign_unit "$ign" zfs-autosnap@.service)"
check "snapshots: service requires zfs-mount" contains "$snapsvc" "Requires=zfs-mount.service"
check "snapshots: timer fires on its class" contains "$(ign_unit "$ign" zfs-autosnap@.timer)" "OnCalendar=%i"
for c in hourly daily weekly; do
	check "snapshots: $c timer enabled" ign_unit_enabled "$ign" "zfs-autosnap@$c.timer"
done

# --- k3s ----------------------------------------------------------------------
check "k3s sysext pinned by hash" test "$(ign_remote "$ign" /opt/extensions/k3s/k3s-v1.36.4+k3s1-x86-64.raw)" = \
	"https://extensions.flatcar.org/extensions/k3s-v1.36.4+k3s1-x86-64.raw sha256-d9d3037fefceaead851f9fbf230db0fe7ab9bea04fd6fd109582835950ee9d9d"
check "k3s sysext merged" test "$(ign_link "$ign" /etc/extensions/k3s.raw)" = /opt/extensions/k3s/k3s-v1.36.4+k3s1-x86-64.raw
check "k3s server enabled" test \
	"$(ign_link "$ign" /etc/systemd/system/multi-user.target.wants/k3s.service)" = /usr/local/lib/systemd/system/k3s.service
check "no sysupdate for k3s" test -z "$(jq -r '.storage.files[].path | select(contains("sysupdate"))' "$ign")"
k3sconf="$(ign_file "$ign" /etc/rancher/k3s/config.yaml)"
check "k3s: node ip" contains "$k3sconf" "node-ip: 192.168.123.123"
check "k3s: tls san hostname" contains "$k3sconf" "- quader26"
check "k3s: bundled traefik disabled" contains "$k3sconf" "- traefik"
check "k3s: secrets encrypted at rest" contains "$k3sconf" "secrets-encryption: true"
check "k3s: kubeconfig root-only" contains "$k3sconf" 'write-kubeconfig-mode: "0600"'
check "k3s: config not world-readable" jqe '.storage.files[] | select(.path == "/etc/rancher/k3s/config.yaml") | .mode == 384' "$ign"
dropin="$(ign_dropin "$ign" k3s.service 10-require-zfs.conf)"
check "k3s requires zfs-mount" contains "$dropin" "Requires=zfs-mount.service"
check "k3s ordered after zfs-mount" contains "$dropin" "After=zfs-mount.service"
check "k3s refuses to start without the containerd dataset" contains "$dropin" \
	"ExecStartPre=/usr/bin/mountpoint -q /var/lib/rancher/k3s/agent/containerd"

finish
