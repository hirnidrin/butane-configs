# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repo manages Butane/Ignition provisioning configs for Fedora CoreOS (FCOS) based servers.

A server is **composed**, not written from scratch: `servers/<name>/server.yaml` names a list
of reusable snippets from `snippets/` and adds a small frame of its own. `build.sh` deep-merges
those fragments, substitutes `${VARIABLE}` placeholders from the server's local `.env`, and
transpiles the result into an Ignition `.ign` config.

Server directories are named after the **real server** (`nuc26`), never after the base image.

**Tools required:** `butane` (transpiler), `yq` (mikefarah/yq v4, YAML merge), `envsubst`
(variable substitution), `mkpasswd` (password hashing)

## Layout

```
snippets/<snippet>/snippet.yaml    partial Butane config (the reusable unit)
snippets/<snippet>/defaults.env    optional default values for its variables
snippets/<snippet>/files/…         optional payload files (quadlets, scripts, units)
servers/<name>/server.yaml         snippet list + frame (variant, version, overrides)
servers/<name>/README.md           what this machine is, plus its post-install steps
servers/<name>/.env.example        every variable the server must supply (committed)
servers/<name>/.env                real values (gitignored)
servers/<name>/files/…             optional per-server overrides of snippet payload files
servers/<name>/<name>.ign          build output (gitignored)
servers/<name>/.build/             staging: merged.yaml + substituted payloads (gitignored)
```

## Build commands

```sh
make              # list targets and known servers (default goal)
make nuc26        # build one server (also: make servers/nuc26, make servers/nuc26/)
./build.sh nuc26  # same thing without make
make clean
```

Pipeline per server: snippet `defaults.env` + server `.env` → snippet fragments + frame
→ `yq` deep-merge (`*+`: maps merge, arrays append) → `envsubst` → `butane --strict --files-dir`
→ `.ign`.

Inspect `servers/<name>/.build/merged.yaml` and `servers/<name>/<name>.butane` when debugging a
build — they are the pre- and post-substitution intermediates.

## Adding a server

1. `mkdir servers/<name>` — named after the machine, never after its base image.
2. `server.yaml`: the snippet list plus the frame (`variant`, `version`, any overrides).
3. `.env.example` covering every variable those snippets require but do not default.
4. `README.md` describing the machine and its post-install steps, linked from the servers
   table in the repo README.
5. `make <name>` to verify. The Makefile discovers servers by wildcard, so it needs no edit.

## Writing a snippet

1. One concern per snippet. Prefix by kind: `base-`, `net-`, `storage-`, `hw-`, `app-`.
2. `snippet.yaml` is a **partial** Butane config — no `variant`/`version`, those live in the frame.
3. Open it with a comment block stating what it does, its required vars, and its optional vars.
4. Put anything longer than a few lines in `files/` and reference it, instead of inlining it:
   - storage files → `contents: {local: <path under files/>}`, mirroring the destination path
     (e.g. `files/etc/containers/systemd/foo.container`)
   - systemd units → `contents_local: units/<unit name>`
   This keeps the YAML readable and gives the payload proper syntax highlighting.
5. Give every optional variable a value in `defaults.env`; a server's `.env` overrides it.
   Required variables (secrets, addresses) belong in the server's `.env.example` instead.
6. Never write a literal `${...}` in a snippet comment or payload unless it is a real variable —
   the build fails on any placeholder left unsubstituted. That check is what catches a variable
   missing from `.env`, so keep it noise-free.

Snippets are merged in the order listed, with the frame merged last, so the frame's scalars win.
Two snippets writing the same file path is an error — `butane --strict` catches it.

## Architecture: boot-time provisioning sequence

One-shot setup services use a **flag-file sequencing pattern** to chain steps across reboots.
Each step checks `ConditionPathExists` for the previous step's flag, does its work, writes its own
flag under `/etc/ignition-task-tracking/`, and disables itself (rebooting if needed). A snippet
that needs this must declare the directory in `storage.directories`.

Flag files use **descriptive names** (`rebase-to-signed`, not `1-rebase-to-signed`). Snippets are
composed in varying combinations, so no snippet can know its own position in a global sequence;
ordering is expressed by naming the flag it waits on, plus `After=` on the unit.

Services that must run on **every** boot (e.g. `hw-ipmi-fans`) need no flag file at all.

## Secrets and generated files

`.env`, `*.butane`, `*.ign` and `.build/` are gitignored — only `*.yaml`, `files/`, and
`.env.example` are committed. Keep `.env.example` in sync with the variables a server requires.
