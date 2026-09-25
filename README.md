# Butane Configs

Butane/Ignition provisioning configs for Fedora CoreOS and Flatcar Container Linux servers.

Each server is composed from reusable snippets rather than written as one monolithic template:
`servers/<name>/server.yaml` lists the snippets it wants, `.env` supplies the secrets and
addresses, and `make <name>` produces the Ignition config.

## Servers

| Server | Base | What it does |
|--------|------|--------------|
| [`nuc26`](./servers/nuc26/README.md) | plain FCOS (no rebase) | WireGuard VPN gateway — wg-easy + caddy TLS proxy |
| [`quader26`](./servers/quader26/README.md) | Flatcar | homelab host: ZFS mirror + single-node k3s |

## Snippets

| Snippet | Variant | Purpose |
|---------|---------|---------|
| `base-core-user` | any | `core` user with SSH key and password hash |
| `base-hostname` | any | static hostname |
| `base-ssh-key-only` | any | SSH with keys only: no passwords, no keyboard-interactive, no root |
| `base-flatcar-updates` | Flatcar | automatic updates, reboots in a weekly window |
| `base-flatcar-no-docker` | Flatcar | disable the bundled docker and containerd sysexts |
| `net-static-ip` | FCOS | static IPv4 on one ethernet interface, IPv6 disabled (NetworkManager) |
| `net-static-ip-networkd` | Flatcar | static IPv4 on one ethernet interface, IPv6 disabled (systemd-networkd) |
| `storage-btrfs-raid1` | any | two NVMe devices mirrored into one btrfs RAID1, mounted at boot |
| `storage-zfs-import` | Flatcar | ZFS sysext; import existing pools at boot (never creates one) |
| `storage-zfs-snapshots` | any | hourly/daily/weekly recursive snapshots with pruning |
| `sysext-ipmitool` | Flatcar | hash-pinned ipmitool sysext + OpenIPMI modules |
| `hw-ipmi-fans` | any | pin IPMI fan duty cycles on every boot (needs `ipmitool`: `sysext-ipmitool` on Flatcar) |
| `app-wg-easy` | FCOS | wg-easy WireGuard engine + webadmin, as a system quadlet (Podman) |
| `app-caddy-tls-proxy` | FCOS | caddy on the host network, TLS for a localhost-only upstream (Podman) |
| `app-k3s-server` | Flatcar | pinned single-node k3s that refuses to start without its ZFS dataset |

Each snippet documents its variables in the comment block at the top of its `snippet.yaml`, and
ships defaults for the optional ones in `defaults.env`.

## Repo structure

```
snippets/<snippet>/snippet.yaml    partial Butane config
snippets/<snippet>/defaults.env    default values for its optional variables
snippets/<snippet>/files/…         payload files: quadlets, scripts, systemd units
servers/<name>/server.yaml         snippet list + frame (variant, version, overrides)
servers/<name>/README.md           what this machine is and its post-install steps
servers/<name>/.env.example        variables the server must supply (committed)
servers/<name>/.env                real values (gitignored)
servers/<name>/files/…             optional per-server overrides of snippet payloads
tests/                             build checks: make test
```

## Usage

### Build an existing server

```sh
cd servers/nuc26
cp .env.example .env

# Generate an SSH key if needed
ssh-keygen -t ed25519
# Generate a password hash
mkpasswd --method yescrypt

nano .env            # fill in real values
cd ../.. && make nuc26
```

Building substitutes the variables, merges the snippets, and transpiles the result to
`servers/nuc26/nuc26.ign`.

```sh
make                 # show help and the list of known servers
make nuc26           # build one server (also: make servers/nuc26/)
make clean           # remove generated files
make test            # build each server that has tests/test-<server>.sh, run the checks
```

If a variable is missing from `.env`, the build stops and tells you which one.

### Add a server

1. `mkdir servers/<name>`
2. Write `server.yaml`: the snippets you want, plus `variant` / `version`
3. Write `.env.example` covering every variable those snippets require, copy it to `.env`
4. Write a `README.md` describing the machine, and link it from the servers table above
5. `make <name>` — no Makefile edit needed, servers are discovered automatically

### Add a snippet

See [CLAUDE.md](./CLAUDE.md#writing-a-snippet) for the conventions.

## Deploying

FCOS servers, as below. Flatcar servers: see the server's own README (IPMI + `flatcar-install`).

1. Copy the generated `.ign` file to a FAT32 formatted USB stick.
1. Connect that stick and a Fedora CoreOS live USB stick (created from the downloaded ISO image) to the target device.
1. Boot the target device from the live USB stick.
1. Once in the console, run:
   ```sh
   # look what we have
   lsblk
   # mount the stick with the .ign config
   sudo mount /dev/sdc1 /mnt
   # install FCOS using the .ign config
   sudo coreos-installer install /dev/sda --ignition-file /mnt/nuc26.ign
   ```
1. Wait for installation to finish. Shutdown, remove USB sticks.
1. Boot -> the ignition config will be applied on first boot.
1. Login as user `core` with the provisioned password or SSH pubkey.

## Security

- **Never commit `.env` files** — they contain secrets
- Generated `.butane`, `.ign` and `.build/` are gitignored too, since they contain substituted secrets
- Only commit `server.yaml`, `snippet.yaml`, `defaults.env`, `files/` and `.env.example`
