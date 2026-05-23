# Butane Configs

This repository contains Butane configuration templates for deploying Fedora CoreOS based servers.

## Server Summary

| Server | Base image | Notable extras |
|--------|-----------|----------------|
| `ucore-pulpo` | `ghcr.io/ublue-os/ucore:stable` | Syncthing container (user-space quadlet) |
| `ucore-hci` | `ghcr.io/ublue-os/ucore-hci:stable` | Minimal, no extras |
| `ucore-quader` | `ghcr.io/ublue-os/ucore:stable` | Syncthing + IPMI fan control |
| `brucore-quader` | `ghcr.io/hirnidrin/brucore:latest` | Custom image, IPMI fan control |
| `wucore-quader` | `ghcr.io/hirnidrin/wucore:latest` | Custom image, IPMI fans, k3s on NVMe BTRFS RAID1 |
| `fcos-wg-easy` | plain FCOS (no rebase) | wg-easy WireGuard VPN UI (system quadlet, nftables) |

Additional details for some setups see below.

### fcos-wg-easy

* Static WireGuard endpoint in LAN, with Webadmin for client config management.
* Simple, efficient and free alternative to corporate VPN server solutions.

Notes

* WireGuard service listens on port 51820 for incoming road warrior connections
  * Setup port-forwarding: firewall WAN port 51820 -> fcos-wg-easy LAN IP address, port 51820
* wg-easy webadmin listens on fcos-wg-easy LAN IP address, port 8843 - don't expose this to WAN
  * `https://<fcos-wg-easy-server-ip>:8843`
  * Webadmin TLS connection secured by a `caddy`reverse proxy, issues a self-signed cert
* After initial setup, open the webadmin and
  * run the config steps
  * Change the default legacy `iptables`-based **PostUp** and **PostDown** hooks to `nftables`, see [wg-easy documentation](https://wg-easy.github.io/wg-easy/latest/examples/tutorials/podman-nft/#edit-hooks)
  * Reboot -> ready for setting up road warrior client configs.

## Repo structure

Each server has its own subdirectory containing:
- `*.butane.template` - Butane config templates with variable placeholders
- `.env.example` - Example environment variables (committed to git)
- `.env` - Real credentials (local only, gitignored)

## Repo usage

### Use an existing server config

1. Navigate to the server directory you want to configure:
   ```sh
   cd ucore-pulpo
   ```

2. Copy the example environment file:
   ```sh
   cp .env.example .env
   ```

3. Edit `.env` with your real credentials:
   ```sh
   # Generate SSH key if needed
   ssh-keygen -t ed25519

   # Generate password hash
   mkpasswd --method yescrypt

   # Populate .env with real values
   nano .env
   ```

### Building configs

From the repository root:

```sh
# Build all server configs
make

# Build specific server
make ucore-pulpo

# Clean generated files
make clean

# Show help
make help
```

Building will:
1. Substitute variables from `.env` into the `*.butane.template` file
2. Generate a `.butane` config file
3. Transpile the `.butane` file into an ignition `.ign` config

### Deploying

The generated `.ign` file can be used to provision your server. Manual example:

1. Copy the `provisioning-config.ign` file to a FAT32 formatted USB stick.
1. Connect that stick and a Fedora CoreOS live USB stick (created from the downloaded ISO image) to the target device.
1  Boot the target device from the live USB stick.
1. Once in the console, run:
   ```sh
   # look what we have
   lsblk
   # mount the stick with the .ign config
   sudo mount /dev/sdc1 /mnt
   # install FCOS using the .ign config
   sudo coreos-installer install /dev/sda --ignition-file /mnt/provisioning-config.ign
   ```
1. Wait for installation to finish. Shutdown, remove USB sticks.
1. Boot -> the ignition config will be applied on first boot.
1. Login as user `core` with the provisioned password or SSH pubkey.

## Adding new servers

1. Create a new subdirectory for your server
2. Add a `*.butane.template` file with `${VARIABLE}` placeholders
3. Create a `.env.example` with all required variables
4. Add build target to `Makefile`
5. Follow the usage steps above

## Security

- **Never commit `.env` files** - they contain secrets
- Generated `.butane` and `.ign` files are also gitignored since they contain substituted secrets
- Only commit `.butane.template` and `.env.example` files
