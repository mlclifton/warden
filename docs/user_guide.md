# Jail Manager User Guide

The `warden.sh` script is a utility to manage isolated development environments (jails) using Incus containers. It allows you to create, connect to, and destroy project-specific containers while keeping your source code synchronized between the host and the container.

## Getting Started

Before using Warden, you need to set up Incus and the base development image on your system.

### 1. Initial Setup
Run the setup script to install dependencies, configure Incus, and provision the base image. You can use the `--dry-run` flag to see what will happen before any changes are made:

```bash
./setup_incus.sh --dry-run
```

To perform the actual setup:

```bash
./setup_incus.sh
```

**Note:** The base image provisioning can take 3-10 minutes. You can monitor the progress in a separate terminal by running:
```bash
incus exec base-temp -- tail -f /var/log/cloud-init-output.log
```

This script will:
- Install `incus`, `jq`, `git`, and `zellij`.
- Initialize the Incus daemon.
- Create the `dev-profile`.
- Build the `base-dev-v2` image using Cloud-init.

### 2. Verify Installation
You can verify your environment at any time using the `doctor` command:

```bash
./warden.sh doctor
```

## Overview

Each "jail" is a lightweight Linux container based on a pre-configured image. The primary benefit is that development dependencies (compilers, runtimes, databases) stay inside the container, keeping your host system clean.

### Core Concepts

- **Host Project Directory**: Located at `~/jails/<project_name>`.
- **Container Project Directory**: Located at `/home/dev/project` inside the container.
- **Bi-directional Sync**: Changes made in `~/jails/<project_name>` on your host appear immediately in `/home/dev/project` inside the container, and vice-versa.
- **User Mapping**: The script automatically handles permissions so that your host user owns the files on the host, and the `dev` user owns them inside the container.

---

## Command Reference

### 1. `create`
Creates a new development environment.

**Usage:**
```bash
./warden.sh create <name> [git_url] [--image <image>]
```

**What it does:**
1. Creates a directory at `~/jails/<name>` on your host.
2. (Optional) Clones the provided `git_url` into that directory.
3. Initializes an Incus container named `<name>` from the base image (default: `base-dev-v2`, or a custom warden image if `--image` is given).
4. Mounts your host directory into the container at `/home/dev/project`.
5. Starts the container.
6. Prompts you to set a password for the `dev` user (optional).

Use `--image <name>` to start from a previously saved warden image instead of the default base. See `save-image` below.

**Examples:**
```bash
# Standard create (uses base-dev-v2)
./warden.sh create my-webapp https://github.com/example/my-webapp.git

# Create from a saved warden image
./warden.sh create my-webapp --image python-ds

# Create from a saved image with a git clone
./warden.sh create my-webapp https://github.com/example/repo.git --image python-ds
```

### 2. `connect`
Connects to an existing environment via SSH and attaches a terminal multiplexer (`zellij`). Note that the initial SSH connection does not required a password.

**Usage:**
```bash
./warden.sh connect <name>
```

**What it does:**
1. Checks if the container is running; if not, it starts it.
2. Retrieves the container's IP address.
3. Connects via SSH as the `dev` user.
4. Automatically starts or attaches to a `zellij` session for a persistent workspace.

**Example:**
```bash
./warden.sh connect my-webapp
```

### 3. `list`
Lists all active development environments and their status.

**Usage:**
```bash
./warden.sh list
```

### 4. `destroy`
Deletes a development environment.

**Usage:**
```bash
./warden.sh destroy <name>
```

**What it does:**
1. Forcefully deletes the Incus container.
2. Prompts you to decide whether to delete the project directory on your host (`~/jails/<name>`).

**Example:**
```bash
./warden.sh destroy my-webapp
```

### 5. `save-image`
Saves a jail's current state as a named warden image so it can be used as a starting point for future jails.

**Usage:**
```bash
./warden.sh save-image <jail-name> <image-name>
```

**What it does:**
1. Stops the jail temporarily if it is running (for a consistent snapshot).
2. Publishes the jail as an Incus image with the alias `warden/<image-name>`.
3. Restarts the jail if it was running.
4. Reports the image fingerprint on success.

Errors if the jail does not exist or if an image with that name already exists (use `delete-image` first).

**Example:**
```bash
./warden.sh save-image my-project python-ds
# [INFO] Stopping my-project for consistent snapshot...
# [INFO] Publishing image 'python-ds'...
# [INFO] Restarting my-project...
# [SUCCESS] Image 'python-ds' saved (fingerprint: abc123def456...).
```

---

### 6. `images`
Lists all warden-managed images.

**Usage:**
```bash
./warden.sh images
```

Displays a table of images created by `save-image`, showing name, fingerprint, size, creation date, and the jail they were saved from. Prints an informational message if no warden images exist.

**Example output:**
```
NAME              FINGERPRINT   SIZE      CREATED              SAVED FROM
----------------  ------------  --------  -------------------  ----------
python-ds         abc123def456  1.2 GiB   2026-04-05 14:32     my-project
ml-base           beef00112233  2.1 GiB   2026-04-01 09:10     ml-sandbox
```

---

### 7. `image-info`
Shows details about a specific warden image and lists all current jails that were created from it.

**Usage:**
```bash
./warden.sh image-info <image-name>
```

**Example output:**
```
Image: python-ds
  Fingerprint : abc123def456abc123def456
  Size        : 1.2 GiB
  Created     : 2026-04-05 14:32:00
  Saved from  : my-project

Jails created from this image:
  ds-experiment-1   (Running)
  ds-experiment-2   (Stopped)
```

Errors if the image does not exist.

---

### 8. `delete-image`
Deletes a warden-managed image.

**Usage:**
```bash
./warden.sh delete-image <image-name>
```

**What it does:**
1. Warns (but does not block) if existing jails were created from this image — those jails remain functional.
2. Prompts for confirmation before deleting.
3. Removes the image from Incus.

Skips the confirmation prompt and logs a message in non-interactive mode.

**Example:**
```bash
./warden.sh delete-image python-ds
# [WARN] 2 jail(s) were created from 'python-ds' (ds-experiment-1, ds-experiment-2).
# [WARN] Deleting this image will not affect those jails.
# Delete image 'python-ds'? [y/N] y
# [SUCCESS] Image 'python-ds' deleted.
```

---

### 9. `doctor`
Checks your host system for dependencies and reports any configuration issues.

**Usage:**
```bash
./warden.sh doctor
```

### 10. `fix-terminal`
Repairs terminal issues (like broken backspace or cursor keys) in an existing container by installing missing terminal definitions (`ncurses-term`).

**Usage:**
```bash
./warden.sh fix-terminal <name>
```

---

## Configuration & Environment

### Script Variables
The following variables are defined at the top of `warden.sh` and can be modified if your setup differs:
- **`JAIL_ROOT`**: Default is `~/jails`. This is where project directories are stored on the host.
- **`BASE_IMAGE`**: Default is `base-dev-v2`. The Incus image used to create new containers.
- **`PROFILE`**: Default is `dev-profile`. The Incus profile applied to new containers.

### Environment Details
- **Default User**: `dev` (UID/GID 1000).
- **Default Shell**: `zsh` with Oh My Zsh.
- **Default Editor**: `neovim` with **LazyVim** pre-configured.
- **Sudo Access**: The `dev` user has passwordless sudo access inside the container.
- **SSH Access**:
  - The host's SSH agent is forwarded to the container (`ssh -A`).
  - The host's public key is injected into `/home/dev/.authorized_keys` during base image creation.
- **Networking**: Containers are assigned IP addresses via the `incusbr0` bridge. Service discovery is available via `<container_name>.incus`.

### Advanced Configuration
If you need to customize the container (e.g., adding GPUs or changing resource limits), you can modify the `dev-profile`:
```bash
incus profile edit dev-profile
```
Common additions include:
- **CPU/Memory Limits**: `limits.cpu`, `limits.memory`.
- **GPU Passthrough**: `nvidia.runtime=true`.
- **Nested Virtualization**: `security.nesting=true` (enabled by default for Docker support).

---

## Interacting with Your Project

The "magic" of this setup is the directory mapping. You can use your favorite tools on your host machine while executing code in the container.

### Editing Files
You don't need to edit files inside the container. You can open your host-side directory in any editor:

```bash
# Example: Using VS Code on the host
code ~/jails/my-webapp
```

Any changes you save will be instantly reflected inside the container at `/home/dev/project`.

### Running Code
To run your application, run tests, or install dependencies, connect to the jail:

```bash
./warden.sh connect my-webapp
# Inside the container:
cd project
npm install
npm start
```

### SSH Agent Forwarding
The `connect` command uses `ssh -A`, which enables SSH agent forwarding. This means if you have SSH keys added to your host's agent (`ssh-add -l`), you can use those same keys inside the container for operations like `git push` or `git pull` without copying your private keys into the container.

---

## Configuration Details

The script uses the following defaults:
- **Base Image**: `base-dev-v2` (must be created beforehand).
- **Profile**: `dev-profile` (must be created beforehand).
- **Storage**: Containers are stored in the default Incus storage pool.
- **Root Path**: All project directories are stored in `~/jails/`.
