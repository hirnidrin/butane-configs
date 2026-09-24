# quader26: Flatcar host with ZFS mirror and k3s

Flatcar Container Linux on the Supermicro M11SDV-8C-LN4F (EPYC 3251, 128 GB
ECC, IPMI): a single-node k3s host whose data lives on a ZFS mirror. Built
with `make quader26` from the repo root.

* OS disk: Crucial M500 240 GB. Disposable: nothing on it is precious.
* Data: 2× 4 TB as ZFS mirror `tank`. Never touched by Ignition.
* Fans pinned via IPMI on every boot.
* Snapshots of `tank/projects`: 24 hourly, 14 daily, 8 weekly.
* Single-node k3s (pinned); refuses to start without the pool.
* Flatcar Stable, automatic updates, reboots Sundays 04:00–05:00.

## Build

```sh
cd servers/quader26 && cp .env.example .env && nano .env   # real IP, key, hash
cd ../.. && make quader26                                   # -> servers/quader26/quader26.ign
```

## Install (first provision and reprovision)

1. On the workstation, serve the config for the installer (LAN only, stop it
   right after):
   ```sh
   cd servers/quader26 && python3 -m http.server 8000
   ```
2. IPMI web UI → virtual media: mount the current Flatcar Stable ISO, boot
   from it, open the remote console.
3. **Identify the OS disk by id. Never use `/dev/sdX`.** The two 4 TB disks
   hold the pool; installing onto one of them destroys it.
   ```sh
   ls -l /dev/disk/by-id/ | grep -v part
   # pick the ata-Crucial_CT240M500... entry
   ```
4. Install:
   ```sh
   curl -O http://<workstation-ip>:8000/quader26.ign
   sudo flatcar-install -d /dev/disk/by-id/ata-Crucial_CT240M500SSD1_<serial> -C stable -i quader26.ign
   ```
5. Unmount the ISO, reboot. Stop the workstation's http server.
6. `ssh core@quader26`

On first boot Flatcar downloads the zfs sysext, and Ignition downloads the
ipmitool and k3s sysexts. The box needs internet access.

## First provision only: create the pool

Skip this on a reprovision: the pool is found and imported automatically.

k3s fails to start until this is done. That is intended.

```sh
ls -l /dev/disk/by-id/ | grep -v part          # identify the two 4 TB disks
sudo zpool create \
  -o ashift=12 \
  -O compression=zstd -O atime=off -O xattr=sa -O acltype=posixacl \
  -O mountpoint=/tank \
  tank mirror /dev/disk/by-id/<disk-a> /dev/disk/by-id/<disk-b>
sudo zfs create -p -o mountpoint=/var/lib/rancher/k3s/agent/containerd tank/system/containerd
sudo zfs create tank/projects
sudo systemctl restart k3s
```

**Never add `-f` to `zpool create`.** Without it, ZFS refuses disks that
already carry a pool, which is the only thing standing between a mistyped
command and an empty pool.

## Reprovision only: reset the containerd cache

The containerd store survives on the pool, but the cluster state on the OS
disk does not. Start containerd clean; it is a cache, not data:

```sh
sudo systemctl stop k3s
sudo zfs destroy -r tank/system/containerd
sudo zfs create -o mountpoint=/var/lib/rancher/k3s/agent/containerd tank/system/containerd
sudo systemctl start k3s
```

`tank/projects` is untouched: project data carries over.

## Kubeconfig for the workstation

```sh
ssh core@quader26 sudo cat /etc/rancher/k3s/k3s.yaml \
  | sed 's/127.0.0.1/<quader26-ip>/' > ~/.kube/quader26.yaml
chmod 600 ~/.kube/quader26.yaml
export KUBECONFIG=~/.kube/quader26.yaml && kubectl get nodes
```

This is cluster-admin. It stays on the workstation and never goes into a pod.

## Checks

```sh
systemd-sysext status                     # zfs, ipmitool, k3s; no docker-flatcar / containerd-flatcar
systemctl status fanspeed                 # succeeded
sudo ipmitool sensor | grep -i fan
zpool status tank                         # mirror, ONLINE
systemctl list-timers 'zfs-autosnap@*'
zfs list -t snapshot -r tank/projects
```

## Upgrading k3s

Pick a version and hash from
`https://extensions.flatcar.org/extensions/k3s/SHA256SUMS`, set `K3S_VERSION`
and `K3S_SHA256` in `.env` (or bump `snippets/app-k3s-server/defaults.env`),
rebuild and reprovision. Stay within a minor release unless you mean to
upgrade Kubernetes.
