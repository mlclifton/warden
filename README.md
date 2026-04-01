# Warden: AI Coding Sandboxes via Incus

Warden is a CLI utility for managing isolated, high-performance development environments (jails) using **Incus** system containers. It is specifically designed to provide secure, performant, and flexible sandboxes for working with AI coding agents (like Gemini CLI or OpenCode). For the original design goals and requirements, see [warden_prd.md](warden_prd.md).

## 🚀 Quick Start

```bash
# 1. Initialize Incus and build the base development image
./setup_incus.sh

# 2. Verify your environment
./warden.sh doctor

# 3. Create a new sandbox (jail)
./warden.sh create my-project https://github.com/example/repo.git

# 4. Connect to your sandbox (opens a Zellij session)
./warden.sh connect my-project

# 5. List all active sandboxes
./warden.sh list

# 6. Destroy a sandbox when finished
./warden.sh destroy my-project
```

See the [user_guide.md](user_guide.md) for more detailed usage instructions.

---

## 🏗️ Architecture & Core Concepts

Warden uses **Incus** (a modern fork of LXD) to provide VM-like isolation with the speed and efficiency of containers. Detailed architecture is documented in [warden_prd.md](warden_prd.md).

### Container Strategy
- **Isolation:** Uses unprivileged system containers with `security.nesting=true` to support Docker-in-Incus.
- **Base Image:** Environments are cloned from a pre-configured snapshot (`base-dev-v2`) defined by `cloud-init.yaml`.
- **Resources:** Default limits are 4 vCPUs and 8GB RAM (configurable via `dev-profile`).

### Seamless File Sharing
- **Mapping:** Host path `~/jails/<name>` is mapped to `/home/dev/project` inside the container.
- **Permissions:** Uses `shift=true` (idmap shifting) so files are owned by your host user on the host and the `dev` user inside the jail, avoiding permission conflicts.

### Networking & SSH
- **Discovery:** Accessible via `<name>.incus` DNS.
- **Connection:** `warden.sh connect` uses SSH agent forwarding (`ssh -A`) to allow the jail to use your host's Git credentials securely.
- **Interface:** Automatically attaches to a `Zellij` session upon connection.

---

## 🛠️ Command Reference

For a full breakdown of every command and its effects, refer to the [user_guide.md](user_guide.md).

| Command | Usage | Description |
| :--- | :--- | :--- |
| `create` | `create <name> [url]` | Creates `~/jails/<name>`, clones git repo (optional), and launches the container. |
| `connect` | `connect <name>` | Starts container (if stopped) and connects via SSH + Zellij. |
| `list` | `list` | Shows all Warden containers and their current status. |
| `destroy` | `destroy <name>` | Deletes the container and prompts to remove the host project directory. |
| `doctor` | `doctor` | Validates host dependencies (Incus, jq, git, network). |
| `info` | `info <name>` | Displays detailed metadata about a specific jail. |
| `fix-terminal`| `fix-terminal <name>`| Installs `ncurses-term` to fix broken backspace/cursor keys. |

---

## 💻 Development & Contributing

Guidelines for development, coding standards, and AI assistance can be found in [AGENTS.md](AGENTS.md) and [CLAUDE.md](CLAUDE.md).

### Coding Standards
- **Language:** Always use Bash (`#!/bin/bash`).
- **Safety:** Scripts use `set -euo pipefail`.
- **Style:** 4 spaces for indentation, double quotes for variables `"$var"`, and `${var}` for clarity.
- **Linting:** Use `shellcheck *.sh` and `shfmt -w *.sh` for formatting.

### Maintenance Workflow
1. **Updating Tools:** Modify `cloud-init.yaml` to add/update global tools.
2. **Rebuilding Base:** Run `./setup_incus.sh` to update the `base-dev-v2` gold image.
3. **Migration:** Use `./migrate_v1_to_v2.sh` to move existing projects to a new base image version.

---

## ⚠️ Troubleshooting & Gotchas

A history of system-specific issues and fixes is maintained in [incus_on_this_machine.md](incus_on_this_machine.md).

### Fedora/Firewalld Issues
On Fedora, the default firewall may block Incus DHCP. Ensure `incusbr0` is in the `incus` zone:
```bash
sudo firewall-cmd --permanent --zone=incus --add-interface=incusbr0 && sudo firewall-cmd --reload
```

### Network Bottlenecks
If `apt` hangs during provisioning, Warden uses `mirror://mirrors.ubuntu.com/mirrors.txt` in `cloud-init.yaml` to find the fastest local mirror.

### Terminal Issues
If you see `'xterm-kitty': unknown terminal type`, run `./warden.sh fix-terminal <name>` or ensure `ncurses-term` is in your base image.

---

## 📂 Project Structure

- `warden.sh`: Main CLI manager.
- `setup_incus.sh`: Initial provisioning and base image builder.
- `validate_setup.sh`: Guided walkthrough for testing the sandbox.
- `cloud-init.yaml`: Definition of the "Gold Image" (zsh, Neovim, Docker, etc.).
- `migrate_v1_to_v2.sh`: Script for upgrading existing jails to new base images.
- `incus_on_this_machine.md`: Historical logs of system-specific setup (archived).
