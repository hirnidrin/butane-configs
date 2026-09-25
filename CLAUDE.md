# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repo manages Butane/Ignition provisioning configs for Fedora CoreOS (FCOS) and Flatcar Container Linux servers.

A server is **composed**, not written from scratch: `servers/<name>/server.yaml` names a list
of reusable snippets from `snippets/` and adds a small frame of its own. `build.sh` deep-merges
those fragments, substitutes `${VARIABLE}` placeholders from the server's local `.env`, and
transpiles the result into an Ignition `.ign` config.

Server directories are named after the **real server** (`nuc26`), never after the base image.

**Tools required:** `butane` (transpiler), `yq` (mikefarah/yq v4, YAML merge), `envsubst`
(variable substitution), `mkpasswd` (password hashing); for `make test` also `jq`,
`shellcheck`, `python3`

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
tests/lib.sh                       test helpers: build_example, ign_file, check, …
tests/test-<server>.sh             checks on a server's generated Ignition JSON
tests/test-<script>.sh             tests for a payload script with logic
tests/run.sh                       runs every tests/test-*.sh, then shellcheck
```

## Build commands

```sh
make              # list targets and known servers (default goal)
make nuc26        # build one server (also: make servers/nuc26, make servers/nuc26/)
./build.sh nuc26  # same thing without make
make clean
make test         # run every tests/test-*.sh (each builds its server from .env.example
                  # into a temp dir), then shellcheck build.sh, tests/ and files/opt/bin/
```

`build.sh` takes `BUTANE_ENV_FILE` and `BUTANE_OUT_DIR` to build from another env file into
another directory; the tests use them so they can never overwrite a real build. They are
deliberately not named `ENV_FILE` / `OUT_DIR`: a stray variable of that common name in the
caller's shell must never steer a real build.

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
5. `tests/test-<name>.sh` with checks on the generated config. `make test` only builds
   servers that have one, so a server without it goes untested.
6. `make <name>` and `make test` to verify. The Makefile discovers servers by wildcard, so it
   needs no edit.

## Writing a snippet

1. One concern per snippet. Prefix by kind: `base-`, `net-`, `storage-`, `hw-`, `sysext-`,
   `app-`.
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
   missing from `.env`, so keep it noise-free. The same goes for payload scripts, which are
   staged through `envsubst`: write script-local variables without braces (`$dataset`, not
   `${dataset}`). `${VAR:-default}` and `${!var}` are safe, the leftover check ignores them.
7. State the variant in the header comment if the snippet only works on one
   (e.g. networkd vs NetworkManager), and in the README's Variant column.
8. Flatcar's `/usr` is read-only (sysexts overlay it, `/usr/local` included):
   host scripts go to `/opt/bin`, which is writable on FCOS too.
9. Downloaded artifacts (sysexts, binaries) always carry
   `verification.hash`. Versions and hashes go in `defaults.env`.
10. Add checks for the snippet to the server's `tests/test-<server>.sh`;
    scripts with logic get their own `tests/test-<script>.sh`. Shell scripts go under
    `files/opt/bin/`, which is where `tests/run.sh` shellchecks them.

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

## Public repo: no instance details

This repo is public. It holds reusable config, not a record of real machines:

- No real IPs, hostnames beyond the server name, disk serials or by-id names, MAC
  addresses, network layout (VLANs, what can reach what), or credentials. Runbooks use
  placeholders (`<serial>`, `<quader26-ip>`); `.env.example` uses example values.
- No links or references to private repos that build on a server. References may point
  *into* this repo, never out of it.
- Instance records (acceptance logs, inventories, incident notes) live outside this repo.
- Check commit messages too, and before pushing: `git log -p origin/main..main`.

## Secrets and generated files

`.env`, `*.butane`, `*.ign` and `.build/` are gitignored. Committed: `*.yaml`, `defaults.env`,
`.env.example`, `files/`, `README.md`s, `tests/`, `build.sh`, `Makefile`. Keep `.env.example` in
sync with the variables a server requires.

## Commits

Conventional prefixes (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`), one decision
per commit.
