# Butane Configs

Butane/Ignition provisioning configs for Fedora CoreOS based servers.

Each server is composed from reusable snippets rather than written as one monolithic template:
`servers/<name>/server.yaml` lists the snippets it wants, `.env` supplies the secrets and
addresses, and `make <name>` produces the Ignition config.

## Servers

| Server | Base | What it does |
|--------|------|--------------|
| `nuc26` | plain FCOS (no rebase) | WireGuard VPN gateway — wg-easy + caddy TLS proxy |

## Snippets

| Snippet | Purpose |
|---------|---------|
| `base-core-user` | `core` user with SSH key and password hash |
| `base-hostname` | static hostname |
| `net-static-ip` | static IPv4 on one ethernet interface, IPv6 disabled |
| `storage-btrfs-raid1` | two NVMe devices mirrored into one btrfs RAID1, mounted at boot |
| `app-wg-easy` | wg-easy WireGuard engine + webadmin, as a system quadlet |
| `app-caddy-tls-proxy` | caddy on the host network, TLS for a localhost-only upstream |
| `hw-ipmi-fans` | pin IPMI fan duty cycles on every boot (needs `ipmitool` in the image) |

Each snippet documents its variables in the comment block at the top of its `snippet.yaml`, and
ships defaults for the optional ones in `defaults.env`.

## Repo structure

```
snippets/<snippet>/snippet.yaml    partial Butane config
snippets/<snippet>/defaults.env    default values for its optional variables
snippets/<snippet>/files/…         payload files: quadlets, scripts, systemd units
servers/<name>/server.yaml         snippet list + frame (variant, version, overrides)
servers/<name>/.env.example        variables the server must supply (committed)
servers/<name>/.env                real values (gitignored)
servers/<name>/files/…             optional per-server overrides of snippet payloads
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
```

If a variable is missing from `.env`, the build stops and tells you which one.

### Add a server

1. `mkdir servers/<name>`
2. Write `server.yaml`: the snippets you want, plus `variant` / `version`
3. Write `.env.example` covering every variable those snippets require, copy it to `.env`
4. `make <name>` — no Makefile edit needed, servers are discovered automatically

### Add a snippet

See [CLAUDE.md](./CLAUDE.md#writing-a-snippet) for the conventions.

## Deploying

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

## nuc26: WireGuard VPN gateway

* Static WireGuard endpoint in the LAN, with a webadmin for client config management.
* Simple, efficient and free alternative to corporate VPN server solutions.

Notes

* WireGuard listens on UDP port 51820 for incoming road warrior connections
  * Set up port forwarding: firewall WAN port 51820 -> nuc26 LAN IP address, port 51820
* The wg-easy webadmin listens on the nuc26 LAN IP address, port 8443 — don't expose this to the WAN
  * `https://<nuc26-ip>:8443`
  * TLS is terminated by a `caddy` reverse proxy with a self-signed cert; wg-easy's own webadmin
    port is published to localhost only, and port 51821 redirects to the secure port
* After initial setup, open the webadmin and
  * run the config steps
  * Change the default legacy `iptables`-based **PostUp** and **PostDown** hooks to `nftables`, see [wg-easy documentation](https://wg-easy.github.io/wg-easy/latest/examples/tutorials/podman-nft/#edit-hooks)
  * Reboot -> ready for setting up road warrior client configs.

## Security

- **Never commit `.env` files** — they contain secrets
- Generated `.butane`, `.ign` and `.build/` are gitignored too, since they contain substituted secrets
- Only commit `server.yaml`, `snippet.yaml`, `defaults.env`, `files/` and `.env.example`
