# Implementation Plan: AI Jail Sandbox Setup

Based on `ai_jail_setup.md`, this plan details the steps to build the Incus-based development environment.

## Phase 0: Prerequisite Verification
**Goal:** Ensure the host environment meets all necessary requirements before installation.

1.  **Check OS & Kernel:** Verify Linux kernel version supports Incus (usually 5.4+).
2.  **Check Dependencies:** Ensure `curl`, `git`, `jq` (for script parsing) are installed on the host.
3.  **Check Virtualization:** Verify `kvm` or relevant virtualization extensions are enabled (optional but recommended for performance).

## Phase 1: Host System Configuration
**Goal:** Prepare the host Linux system to run Incus containers with proper networking and DNS resolution.

1.  **Install & Initialize Incus**
    *   Install Incus package (e.g., via distro repo or independent repository).
    *   Run `incus admin init` to set up the storage pool (default/dir/btrfs) and network bridge (`incusbr0`).
2.  **Create "Dev" Profile**
    *   Create a reusable profile named `dev-profile`.
    *   Config: `security.nesting=true` (for Docker).
    *   Limits: `limits.cpu=4`, `limits.memory=8GB`.
    *   Devices: `eth0` attached to `incusbr0`.
    *   *Benefit:* Simplifies the `create` script and centralizes configuration.
3.  **Configure DNS Resolution (`.incus` domains)**
    *   Locate the `incusbr0` IP address.
    *   Configure `systemd-resolved` to route `*.incus` queries to the Incus DNS server.
    *   *Action:* Create `/etc/systemd/resolved.conf.d/incus.conf` containing the bridge IP as DNS.
    *   Verify resolution: `resolvectl query test.incus` (after a test container is launched).
4.  **Prepare User ID Mapping**
    *   Verify `/etc/subuid` and `/etc/subgid` allow the current user to map a sufficient range of IDs (at least 65536).
    *   Ensure the current user is in the `incus-admin` (or `incus`) group.

## Phase 2: "Gold Image" Definition (Cloud-init)
**Goal:** Create a reproducible configuration file (`cloud-init.yaml`) that defines the software and state of the base development container.

1.  **Define User & Access**
    *   Create user `dev` (UID 1000) to match standard host user.
    *   Configure `sudo` access (nopasswd) for convenience.
    *   Add host's SSH public key to `authorized_keys`.
2.  **Package Installation**
    *   Core: `git`, `curl`, `wget`, `vim`, `zsh`, `jq`.
    *   Dev Tools: `build-essential`, `python3`, `python3-pip`, `python3-venv`, `nodejs`, `npm`.
    *   Container Tools: `docker.io`, `docker-compose`.
    *   Networking: `openssh-server`, `avahi-daemon`.
3.  **Tool Installation (Binary)**
    *   **Zellij:** Download latest binary release from GitHub to `/usr/local/bin` (faster than cargo build).
4.  **System Configuration**
    *   Enable Docker service (`systemctl enable docker`).
    *   Add `dev` user to `docker` group.
    *   Set default shell to `zsh` for user `dev`.
    *   (Optional) Configure `oh-my-zsh` via a generic install script in `runcmd`.

## Phase 3: Base Container Construction
**Goal:** Build and snapshot the `base-dev-v1` image.

1.  **Launch Base Container**
    *   Command: `incus launch images:ubuntu/24.04 base-dev -p default -p dev-profile -c user.user-data=$(cat cloud-init.yaml)`
2.  **Wait for Provisioning**
    *   Monitor `cloud-init status --wait` inside the container to ensure all packages are installed.
3.  **Finalize & Snapshot**
    *   Stop container: `incus stop base-dev`.
    *   Create snapshot: `incus snapshot create base-dev v1`.
    *   Publish image: `incus publish base-dev/v1 --alias base-dev-v1`.
    *   **Cleanup:** Delete the temporary `base-dev` container to free resources.

## Phase 4: Automation Script (`warden.sh`)
**Goal:** Create the CLI tool to manage project lifecycles.

1.  **Script Skeleton**
    *   Setup argument parsing for `create`, `connect`, `destroy`.
    *   Define variables: `JAIL_ROOT=~/jails`, `BASE_IMAGE=base-dev-v1`, `PROFILE=dev-profile`.
2.  **Implement `create <project_name> [git_url]`**
    *   **Host Dir:** Create `$JAIL_ROOT/<project_name>`.
    *   **Git:** If provided, `git clone [url]` into that directory.
    *   **Incus Init (Not Launch):** `incus init $BASE_IMAGE <project_name> -p default -p $PROFILE`.
    *   **ID Mapping:** Configure `raw.idmap` to map Host UID/GID -> Container 1000.
        *   `printf "uid $(id -u) 1000\ngid $(id -g) 1000" | incus config set <project_name> raw.idmap -`
    *   **Disk Mount:** Add the project directory mount.
        *   `incus config device add <project_name> project_code disk source=$JAIL_ROOT/<project_name> path=/home/dev/project`
    *   **Start:** `incus start <project_name>`.
    *   **Wait:** Wait for networking (grep for IP or use `incus exec <project_name> -- cloud-init status --wait`).
3.  **Implement `connect <project_name>`**
    *   Check if container is running; start if stopped.
    *   Command: `ssh -A dev@<project_name>.incus -t "zellij attach -c options"`
    *   (Fallback) If DNS fails, use `incus list` to get IP.
4.  **Implement `destroy <project_name>`**
    *   Stop and delete container.
    *   Prompt user before deleting local files in `$JAIL_ROOT`.

## Phase 5: Verification & Testing
**Goal:** Ensure the system meets security and usability requirements.

1.  **Isolation Test:** Verify `dev` user inside container cannot write to system paths outside `/home/dev` (except `/tmp`).
2.  **Persistence Test:** Create file in `/home/dev/project` inside container -> Verify it appears in `~/jails/<project_name>` on host with correct ownership (user:user).
3.  **Docker-in-Incus:** Run `docker run hello-world` inside the container.
4.  **Agent Connectivity:**
    *   Verify `curl https://google.com` works (internet access).
    *   Verify SSH Agent forwarding allows `git pull` from a private repo (if applicable).
    *   Verify host browser can reach `http://<project_name>.incus:8080` (start a simple python http server to test).
