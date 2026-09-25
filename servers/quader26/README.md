# quader26: Flatcar host with ZFS mirror and k3s

Flatcar Container Linux on the Supermicro M11SDV-8C-LN4F (EPYC 3251, 128 GB
ECC, IPMI): a single-node k3s host whose data lives on a ZFS mirror. Built
with `make quader26` from the repo root.

* OS disk: Crucial M500 240 GB. Disposable: nothing on it is precious.
* Data: 2× 4 TB NVMe (Kingston KC3000) as ZFS mirror `tank`. Never touched by Ignition.
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

One-time BIOS setup (the Flatcar ISO boots in legacy BIOS mode only):
Boot → Boot Mode Select `DUAL`; Advanced → PCIe/PCI/PnP → Onboard Video
Option ROM `Legacy`. The installed system boots either way.

1. Write the current Flatcar Stable ISO to a USB stick. The BMC's virtual
   media only mounts ISOs from an SMB share.
   ```sh
   lsblk                               # find the stick; NOT the laptop's disk
   sudo dd if=flatcar_production_iso_image.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```
2. Boot quader from the stick: F11, the **non-UEFI** USB entry. Open the
   iKVM console.
3. In the console, make the live system reachable:
   ```sh
   sudo passwd core        # live session only
   ip -4 addr
   ```
4. From the workstation, push the config (nothing on the workstation has to
   listen, and it works when the host's network can't reach the workstation):
   ```sh
   scp servers/quader26/quader26.ign core@<live-ip>:
   ```
   In the console, compare `sha256sum ~/quader26.ign` with the workstation's.
5. **Identify the OS disk by id. Never use `/dev/sdX`.** The two 4 TB NVMe
   disks hold the pool; installing onto one of them destroys it.
   ```sh
   lsblk -o NAME,SIZE,MODEL,SERIAL     # the 240 GB Crucial is the OS disk
   ls -l /dev/disk/by-id/ | grep -v part
   ```
6. Install:
   ```sh
   sudo flatcar-install -d /dev/disk/by-id/ata-Crucial_CT240M500SSD1_<serial> -C stable -i ~/quader26.ign
   ```
7. `sudo poweroff`, pull the stick, power on. On a reprovision, clear the
   old host key on the workstation: `ssh-keygen -R <quader26-ip>`.
8. `ssh core@quader26`

On first boot Flatcar downloads the zfs sysext, and Ignition downloads the
ipmitool and k3s sysexts. The box needs internet access.

## First provision only: create the pool

Skip this on a reprovision: the pool is found and imported automatically.

k3s fails to start until this is done. That is intended.

```sh
ls -l /dev/disk/by-id/ | grep -v part          # identify the two 4 TB NVMe disks
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

## Reprovision only: pool not imported?

After a reprovision the pool should be imported automatically
(`zpool status tank`). If it isn't:

```sh
sudo zpool import                  # lists pools found on the disks
sudo zpool import tank
```

If that refuses with "pool was previously in use from another system", the
new install has a different host id. Then, and only then:

```sh
sudo zpool import -f tank
```

`-f` on **import** of your own pool is safe. `-f` on **create** never is.
Do not run the first-provision commands on a reprovision.

## Reprovision only: reset the containerd cache

The containerd store survives on the pool, but the cluster state on the OS
disk does not. Start containerd clean; it is a cache, not data.

k3s must not run during the reset. Stopping the service is not enough:
it leaves the container shims running, and their mounts keep the dataset
busy. So mask k3s and reboot, which leaves nothing running on the dataset:

```sh
sudo systemctl mask k3s && sudo systemctl reboot
# after the reboot:
sudo zfs destroy -r tank/system/containerd
sudo zfs create -o mountpoint=/var/lib/rancher/k3s/agent/containerd tank/system/containerd
sudo systemctl unmask k3s && sudo systemctl start k3s
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
