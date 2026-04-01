# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

**Warden** is a shell-based CLI (`warden.sh`) for managing Incus system containers as isolated AI coding sandboxes ("jails"). It wraps `incus` to handle the full lifecycle: create, connect, destroy, list.

## Commands

```bash
# Lint
shellcheck *.sh
shfmt -w *.sh

# Manual test lifecycle
./warden.sh create test-sandbox
./warden.sh list
./warden.sh connect test-sandbox
./migrate_v1_to_v2.sh
./warden.sh destroy test-sandbox

# Guided validation (interactive)
./validate_setup.sh
```

## Architecture

### Container Strategy
- Uses **Incus** unprivileged system containers (not Docker), providing VM-like isolation with container speed.
- New environments are cloned from a pre-built snapshot `base-dev-v2` (defined by `cloud-init.yaml`) for near-instant startup.
- Profile `dev-profile` is applied at init alongside the `default` profile.
- `security.nesting=true` is enabled via the profile to support Docker-in-container.

### File Sharing
- Host path: `~/jails/<name>` → container path: `/home/dev/project`
- Uses `shift=true` on the disk device (idmap shifting) to handle UID/GID mapping — avoids explicit `raw.idmap` config.

### Networking & SSH
- Containers get IPs via `incusbr0`; `connect` resolves the IP dynamically via `incus list ... | jq`.
- SSH uses agent forwarding (`-A`) and `StrictHostKeyChecking=no` (ephemeral containers).
- Inside the container, connects to a Zellij session: `zellij attach -c options || zellij -l default`.

### Base Image (`cloud-init.yaml`)
Defines the `base-dev-v2` gold image: `dev` user (uid/gid 1000), zsh + oh-my-zsh, Zellij, Neovim (LazyVim), Docker, Node, Python, openssh-server. After first provisioning, snapshot this container and use it as `BASE_IMAGE`.

### Key Variables (`warden.sh`)
- `JAIL_ROOT="$HOME/jails"` — host-side project directories
- `BASE_IMAGE="base-dev-v2"` — Incus image/snapshot to clone from
- `PROFILE="dev-profile"` — Incus profile with resource limits and nesting

## Dependencies
`incus`, `jq`, `git`, `ssh` must be available on the host.
