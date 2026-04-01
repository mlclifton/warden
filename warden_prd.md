# Why "The Warden"?

This utility is intended to help with setup and management of AI coding sandboxes aka "jails" - The Warden looks after the jail!

## Goals & Success Criteria

The primary objective is to establish a secure, performant, and flexible development environment tailored for working with AI coding agents (OpenCode, Gemini CLI, etc.). The setup must balance strict isolation preventing unauthorized host system modification with the usability required for efficient development.

## Core Requirements

* **Security & Isolation:** The coding agent must operate within a confined boundary, preventing accidental or malicious damage to the main host system.
* **Experimentation:** Support for rapid creation, destruction, and restoration of environments (snapshots) to test code safely.
* **Performance:** The environment must offer near-native performance (CPU, I/O), avoiding the overhead of traditional heavy virtual machines.
* **Host Interaction:**
  * **Web:** A browser on the host OS must be able to easily connect to web services/APIs running inside the sandbox.
  * **Files:** A specific host directory must be mapped to the container for persistence and access via host-side GUI tools.
* **Network Control:** The container requires controlled internet access for package installation and API calls, with specific capabilities to restrict or monitor traffic if needed.
* **Tooling Familiarity:** The environment must support standard terminal workflows (zsh, oh-my-zsh, Zellij, Neovim), Docker containers, and the AI agents themselves.
* **Automation:** The entire lifecycle (creation, configuration, connection) should be scriptable to manage multiple project-specific jails easily.
* **Configuration:** When creating a new container, the user should be allowed to configure key parameters such as resources (cpu / memory) through a series of questions that offer sensible defaults.

# Proposed Solution Architecture

The solution utilizes **Incus** (a modern fork of LXD) to create system containers. This provides the density and speed of containers with the behavior of a full virtual machine (init system, distinct userspace).

## A. Container Strategy

* **Technology:** Incus Containers.
* **Isolation Level:** Unprivileged containers (default safe mode).
* **Nested Virtualization:** Enable `security.nesting=true` to allow running Docker/Podman *inside* the jail. This is critical for agents that need to spin up databases or microservices via `docker-compose`.
* **Resource Limits:** Apply soft limits to prevent runaway processes from impacting the host:
  * `limits.cpu: 4` (Cap at 4 vCPUs)
  * `limits.memory: 8GB` (Cap memory usage)
* **Hardware Acceleration (Optional):** Enable device passthrough for projects requiring local AI inference (e.g., Ollama, local LLMs).

## B. Filesystem & Permissions (Crucial)

* **Structure:**
  * **Host Path:** `~/jails/<project_name>` (Created per project).
  * **Container Path:** `/home/dev/project`.
* **Permission Handling (ID Mapping):**
  * Instead of generic shared folders which cause permission issues (root vs. user ownership), we will implement **explicit ID mapping**.
  * The host user's UID/GID (e.g., 1000) will be mapped directly to the container user's UID/GID.
  * *Result:* Files created inside the container are owned by `user:1000` on the host, allowing seamless editing from both sides without `chmod` hacks.

## C. Networking & Discovery

* **Connectivity:** Containers run on the standard `incusbr0` bridge.
* **Service Discovery (Primary - Incus DNS):**
  * Utilize Incus's built-in DNS to resolve container names (e.g., `http://project-alpha.incus`).
  * *Host Config:* Configure `systemd-resolved` (or `/etc/hosts` automation) to direct `*.incus` queries to the Incus bridge IP. This is more reliable than mDNS.
* **Service Discovery (Secondary - mDNS):**
  * Include `avahi-daemon` as a fallback for `.local` resolution if DNS configuration is not possible.
* **Fallbacks:** Incus `proxy` devices can be used if specific stable port binding to `localhost` is required.

## D. Identity & Secrets

* **Git Access:** Use SSH Agent Forwarding. The host's SSH agent (holding GitHub/GitLab keys) is forwarded to the container, allowing the agent to pull/push code without storing private keys inside the container image.
* **SSH Access:** Inject the host's public key (`~/.ssh/id_rsa.pub` or similar) into the container's `authorized_keys` via Cloud-init during creation.
* **API Keys:** Secrets for AI agents should not be baked into the image. They will be passed via environment variables during container launch or mounted as temporary in-memory files.

## E. Base Image & Provisioning

* **Construction:**
  * Use a **Cloud-init** configuration to define the "Gold Image" state. This serves as "documentation-as-code".
  * **Installed Software:**
    * `zsh` + `oh-my-zsh` (configured defaults)
    * `zellij` (terminal multiplexer)
    * `git`, `curl`, `wget`
    * `docker.io`, `docker-compose` (enabled via systemd)
    * Language runtimes: `python3`, `nodejs`, `npm`
    * AI Tools: `gemini-cli`, `opencode` (if available via npm/pip)
    * `openssh-server`
    * `avahi-daemon`
* **Optimization:** Once provisioned via Cloud-init, the container is stopped and snapshotted as `base-dev-v1`. New projects are cloned from this snapshot for instant startup (seconds).

# Automation Workflow

A master management script, `warden.sh`, will handle the complexity, exposing simple commands to the user:

1. **`create <project_name> [git_url]`**:
    * Checks if `~/jails/<project_name>` exists; prompts to create.
    * **Git Clone:** If `git_url` is provided, clones the repository directly into `~/jails/<project_name>` on the host.
    * **Dotfiles:** Optionally symlinks or copies standard dotfiles (vimrc, zshrc) into the project directory or container home.
    * **Container Clone:** Clones `base-dev-v1` to new container `<project_name>`.
    * **Config:**
        * Configures ID mapping (Host 1000 <-> Container 1000).
        * Adds disk device mapping (`path` -> `/home/dev/project`).
        * Injects SSH public key.
    * **Start:** Starts container and waits for Cloud-init/Network readiness.

2. **`connect <project_name>`**:
    * Fetches container IP or uses hostname (`<project_name>.incus`).
    * Executes SSH command with agent forwarding: `ssh -A dev@<project_name>.incus -t "zellij attach -c"`

3. **`destroy <project_name>`**:
    * Stops and deletes the container.
    * *Safeguard:* Prompts before removing the host `~/jails/<project_name>` directory (default action: keep data).

4. **`info <project_name>`**:
    * shows key info about the project including container status

5. **`help`**:
    * prints help and usage to the console

# Validation Strategy

To ensure the sandbox meets all requirements (persistence, networking, isolation, and host interaction), we use a real-world test case: Developing an Obsidian Plugin.

## Test Case: Obsidian Chronology Plugin

We will verify the environment by cloning, building, and modifying the [Chronology Plugin](https://github.com/Canna71/obsidian-chronology).

**Required Steps:**

1. **Clone:** Pull source code into the container.
2. **Vault Setup:** Create a test Obsidian Vault inside the container (mapped directory).
3. **Host Access:** Open that vault using the Obsidian app on the Host OS.
4. **Build:** Compile the plugin inside the container (`npm run build`).
5. **Install:** Deploy the compiled assets to the vault's plugin folder.
6. **Verify:** Enable the plugin in Obsidian (Host) and confirm it loads.
7. **Modify:** Change the source code in the container, rebuild, and confirm the change appears in the Host app.

**Automated Guide:**
A script, `validate_setup.sh` will guide the user through the process above.
