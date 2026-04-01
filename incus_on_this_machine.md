# Incus Environment: System-Specific Facts

This document summarizes findings and configurations specific to the Incus setup on this machine (Fedora 43) discovered during the initial provisioning of Warden.

## 1. Distribution & Kernel
- **OS:** Fedora Linux 43 (x86_64)
- **Kernel:** `6.19.9-200.fc43.x86_64`
- **Incus Version:** `6.19.1`
- **Storage Driver:** `btrfs` (Version 6.19.1)

## 2. Remote Configuration
- **Missing Remotes:** The standard `ubuntu` remote (simplestreams) is **not** configured by default on this installation.
- **Available Remotes:** Only `local` (unix socket) and `images` (https://images.linuxcontainers.org) are present.
- **Provisioning Note:** All image fetches must use the `images:` prefix (e.g., `images:ubuntu/24.04/cloud`).

## 3. ID Mapping (Subuid/Subgid)
- **Problem:** The system initially lacked a functional `idmap` for the root user, preventing unprivileged container creation.
- **Current State:** 
  - User `mike` has a mapping (`524288:65536`).
  - `root` mapping was manually added: `root:1000000:65536`.
- **Note:** Any re-installation or system reset must ensure these entries exist in both `/etc/subuid` and `/etc/subgid`.

## 4. Network & Mirror Bottlenecks
- **Environment:** ISP (Starlink) exhibits high latency/timeouts with the primary `archive.ubuntu.com` mirrors.
- **Optimization:** The `cloud-init.yaml` has been modified to use the mirror redirector (`http://mirror://mirrors.ubuntu.com/mirrors.txt`). This is critical for preventing provisioning hangs during the `apt` phase.

## 6. Firewalld & Networking (Fedora 43)
- **Problem:** Fedora's default `firewalld` configuration blocks DHCP requests from Incus containers, preventing them from obtaining an IPv4 address on `incusbr0`.
- **Solution:** A dedicated `incus` zone was created with permissions for `dhcp`, `dns`, and `dhcpv6` services. The interface `incusbr0` must be explicitly assigned to this zone.
- **Commands:**
  ```bash
  sudo firewall-cmd --permanent --new-zone=incus
  sudo firewall-cmd --permanent --zone=incus --add-service=dhcp
  sudo firewall-cmd --permanent --zone=incus --add-service=dns
  sudo firewall-cmd --permanent --zone=incus --add-service=dhcpv6
  sudo firewall-cmd --permanent --zone=incus --set-target=ACCEPT
  sudo firewall-cmd --permanent --zone=incus --add-interface=incusbr0
  sudo firewall-cmd --reload
  ```
- **Note:** This is necessary on Fedora because `nftables` rules managed by Incus can be overridden or blocked by `firewalld`'s default policies.

## 7. Gotchas & Debugging Tips

### IPv4 vs. IPv6 Detection
- **Issue:** `warden.sh` (and `incus list`) may report a container as having networking if it only has an IPv6 address. SSH and most dev tools in this project currently require IPv4.
- **Earlier Detection:** Always check `incus list` for a `10.x.x.x` address specifically. If you only see an `fd42:...` address, DHCP (IPv4) is likely being blocked by the host firewall.

### Silent Cloud-Init Failures
- **Issue:** `cloud-init status --wait` can return `done` even if package installation failed (e.g., due to a bad mirror URL or blocked network).
- **Earlier Detection:** 
  - Check the logs inside the container: `incus exec <name> -- tail -f /var/log/cloud-init-output.log`
  - Verify critical services: `incus exec <name> -- systemctl status ssh`
  - If SSH is missing, the base image provisioning likely failed silently.

### Mirror URL Syntax
- **Issue:** The `mirror://` scheme in `cloud-init.yaml` is sensitive. Using `http://mirror://` will cause DNS resolution failures for the literal hostname "mirror".
- **Correct Syntax:** `uri: mirror://mirrors.ubuntu.com/mirrors.txt`

### Terminal & Cursor Issues (Kitty, etc.)
- **Issue:** Connecting via `warden.sh connect` may result in broken backspace, cursor keys, or "unknown terminal type" errors (e.g., `'xterm-kitty': unknown terminal type`).
- **Cause:** The container lacks the terminfo definitions for the host terminal. Standard Ubuntu images often miss `ncurses-term` and specialized definitions like `kitty-terminfo`.
- **Solution:** 
  - New containers include `ncurses-term` and `kitty-terminfo` via `cloud-init.yaml`.
  - For existing containers, use: `./warden.sh fix-terminal <name>`.
  - The `connect` command now includes a fallback to `xterm-256color` if the host's `TERM` is not recognized by the container.
