# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repo manages Butane/Ignition provisioning configs for Fedora CoreOS (FCOS) based servers. Each server directory contains a `*.butane.template` with `${VARIABLE}` placeholders that get substituted from a local `.env` file to produce a `.butane` file, which `butane` then transpiles into a `.ign` Ignition config.

**Tools required:** `butane` (transpiler), `envsubst` (variable substitution), `mkpasswd` (password hashing)

## Build Commands

```bash
make                    # Build all server configs (except wucore-quader)
make <server-name>      # Build a specific server (e.g. make wucore-quader)
make clean              # Remove all generated .butane and .ign files
```

The build pipeline per server: `.env` + `*.butane.template` → `envsubst` → `*.butane` → `butane --strict` → `*.ign`

## Adding or Modifying a Server

1. Edit `<server>/autorebase.butane.template` — use `${VAR}` placeholders for anything secret or environment-specific
2. Keep `.env.example` in sync with all variables used in the template
3. If adding a new server, also add it to the `.PHONY` list and targets in `Makefile`
4. Run `make <server>` to validate — `butane --strict` will catch YAML/schema errors

## Architecture: Boot-time Provisioning Sequence

One-shot setup services use a **flag-file sequencing pattern** to chain steps across reboots. Each step:
1. Checks `ConditionPathExists` for a flag file from the previous step
2. Runs its work
3. Writes its own flag file
4. Disables itself (and reboots if needed)

**All new servers must use `/etc/ignition-task-tracking/` with numerically-prefixed flag files** (e.g. `0-firewall-configured`, `1-rebase-to-signed`). Declare the directory in `storage.directories`. The numeric prefix makes execution order explicit and unambiguous.

Older servers (`ucore-pulpo`, `ucore-hci`, `ucore-quader`) use ad-hoc flag paths under `/etc/ucore-autorebase/` — leave those as-is.

## Server Summary

| Server | Base image | Notable extras |
|--------|-----------|----------------|
| `ucore-pulpo` | `ghcr.io/ublue-os/ucore:stable` | Syncthing container (Quadlet) |
| `ucore-hci` | `ghcr.io/ublue-os/ucore-hci:stable` | Minimal, no extras |
| `ucore-quader` | `ghcr.io/ublue-os/ucore:stable` | Syncthing + IPMI fan control |
| `brucore-quader` | `ghcr.io/hirnidrin/brucore:latest` | Custom image, IPMI fan control |
| `wucore-quader` | `ghcr.io/hirnidrin/wucore:latest` | Custom image, IPMI fans, k3s on NVMe BTRFS RAID1 |
| `fcos-wg-easy` | plain FCOS (no rebase) | wg-easy WireGuard VPN UI (system quadlet, nftables) |

## Secrets and Generated Files

`.env`, `*.butane`, and `*.ign` are gitignored — only `*.butane.template` and `.env.example` are committed. To set up a server locally:

```bash
cp <server>/.env.example <server>/.env
# Generate SSH key: ssh-keygen -t ed25519
# Generate password hash: mkpasswd --method yescrypt
# Edit <server>/.env with real values
make <server>
```
