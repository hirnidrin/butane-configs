# Butane Configs

This repository contains Butane configuration templates for deploying Fedora CoreOS based server platforms.

## Structure

Each server has its own subdirectory containing:
- `*.butane.template` - Butane config templates with variable placeholders
- `.env.example` - Example environment variables (committed to git)
- `.env` - Real credentials (local only, gitignored)

## Usage

### First Time Setup

1. Navigate to the server directory you want to configure:
   ```bash
   cd ucore-pulpo
   ```

2. Copy the example environment file:
   ```bash
   cp .env.example .env
   ```

3. Edit `.env` with your real credentials:
   ```bash
   # Generate SSH key if needed
   ssh-keygen -t ed25519

   # Generate password hash
   mkpasswd --method yescrypt

   # Edit .env with real values
   nano .env
   ```

### Building Configs

From the repository root:

```bash
# Build all server configs
make

# Build specific server
make ucore-pulpo

# Clean generated files
make clean

# Show help
make help
```

This will:
1. Substitute variables from `.env` into the `.butane.template` file
2. Generate a `.butane` config file
3. Transpile the `.butane` file into an Ignition `.ign` config

### Deploying

The generated `.ign` file can be used to provision your server. Manual example:

1. Copy the `provisioning-config.ign` file to a FAT32 formatted USB stick.
1. Connect that stick and a Fedora CoreOS live USB stick (created from the downloaded ISO image) to the target device.
1  Boot the target device from the live USB stick.
1. Once in the console, run:
   ```bash
   # look what we have
   lsblk
   # mount the stick with the .ign config
   sudo mount /dev/sdc1 /mnt
   # install FCOS using the .ign config
   sudo coreos-installer install /dev/sda --ignition-file /mnt/provisioning-config.ign
   ```
1. Wait for installation to finish. Shutdown, remove USB sticks.
1. Boot -> the ignition config will be applied on first boot.

## Adding New Servers

1. Create a new subdirectory for your server
2. Add a `*.butane.template` file with `${VARIABLE}` placeholders
3. Create a `.env.example` with all required variables
4. Add build target to `Makefile`
5. Follow the usage steps above

## Security

- **Never commit `.env` files** - they contain secrets
- Generated `.butane` and `.ign` files are also gitignored since they contain substituted secrets
- Only commit `.butane.template` and `.env.example` files
