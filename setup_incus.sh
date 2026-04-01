#!/bin/bash
# setup_incus.sh - Guided Setup for Warden Development Environments

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${BLUE}STEP $1:${NC} $2"; }
log_dry() { echo -e "${YELLOW}[DRY-RUN]${NC} $1"; }

# Configuration
BASE_IMAGE="base-dev-v1"
PROFILE="dev-profile"
CLOUD_INIT="cloud-init.yaml"
DRY_RUN=false

# Parse arguments
for arg in "$@"; do
  case $arg in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
  esac
done

echo "================================================================="
echo "  Warden Setup Wizard"
if [ "$DRY_RUN" = true ]; then
    echo "  (Dry-run mode: Reporting necessary changes only)"
fi
echo "================================================================="
echo "This wizard will ensure your environment meets the requirements"
echo "for Warden jails. It will only modify settings where needed."

# Helper to execute or dry-run
execute() {
    local msg=$1
    local cmd=$2
    if [ "$DRY_RUN" = true ]; then
        log_dry "Would perform: $msg"
    else
        log_info "$msg..."
        eval "$cmd"
    fi
}

# 1. Host System Detection
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
fi

# 2. System Dependencies
log_step 1 "Checking System Dependencies"
MISSING_PKGS=""
for tool in incus jq git zellij; do
    if ! command -v "$tool" &>/dev/null; then
        MISSING_PKGS="$MISSING_PKGS $tool"
    fi
done

if [ -n "$MISSING_PKGS" ]; then
    log_warn "The following tools are missing:$MISSING_PKGS"
    case "$OS" in
        ubuntu|debian)
            execute "Install missing tools via apt and snap" "sudo apt update && sudo apt install -y incus jq git snapd && sudo snap install zellij --classic"
            ;;
        fedora)
            execute "Install missing tools via dnf" "sudo dnf install -y incus jq git zellij"
            ;;
        *)
            log_error "Automatic installation not supported for $OS. Please install:$MISSING_PKGS"
            [ "$DRY_RUN" = false ] && exit 1
            ;;
    esac
else
    log_success "All system dependencies are present."
fi

# 3. Incus Service & Access
log_step 2 "Checking Incus Service & Access"
if command -v incus &>/dev/null; then
    if incus info &>/dev/null; then
        log_success "Incus daemon is reachable and you have permission."
        
        # Check for idmap (subuid/subgid for root)
        if ! grep -q "^root:" /etc/subuid 2>/dev/null || ! grep -q "^root:" /etc/subgid 2>/dev/null; then
            log_warn "System may lack a functional idmap for unprivileged containers."
            log_info "Recommendation: Add mappings for 'root' to /etc/subuid and /etc/subgid:"
            echo "    sudo sh -c 'echo \"root:1000000:65536\" >> /etc/subuid'"
            echo "    sudo sh -c 'echo \"root:1000000:65536\" >> /etc/subgid'"
            echo "    sudo systemctl restart incus"
            if [ "$DRY_RUN" = false ]; then
                log_warn "If container creation fails, please run the commands above."
            fi
        fi
    else
        if groups | grep -q "incus-admin"; then
            execute "Start incus service" "sudo systemctl start incus"
        else
            log_warn "Current user '$USER' is not in the 'incus-admin' group."
            execute "Add $USER to 'incus-admin' group (Requires logout/login)" "sudo usermod -aG incus-admin $USER"
            if [ "$DRY_RUN" = false ]; then
                log_info "Please log out and back in to apply group changes, then re-run this script."
                exit 0
            fi
        fi
    fi
else
    log_dry "Incus not installed; skipping service checks."
fi

# 4. Incus Initialization
log_step 3 "Checking Incus Initialization"
if command -v incus &>/dev/null && incus info &>/dev/null 2>&1; then
    if incus network list --format json | jq -e '.[] | select(.name == "incusbr0")' &>/dev/null; then
        log_success "Incus is already initialized with 'incusbr0'."
    else
        log_warn "Incus does not appear to be initialized."
        execute "Initialize Incus with default settings" "sudo incus admin init --auto"
    fi
else
    log_dry "Incus not reachable; skipping initialization check."
fi

# 5. Warden-Specific Components
log_step 4 "Provisioning Warden Components"

# Profile
if command -v incus &>/dev/null && incus info &>/dev/null 2>&1; then
    if incus profile list --format json | jq -e --arg p "$PROFILE" '.[] | select(.name == $p)' &>/dev/null; then
        log_success "Warden profile '$PROFILE' already exists."
    else
        execute "Create and configure '$PROFILE' (nesting=true, limits.cpu=4, limits.memory=8GB)" \
                "incus profile create $PROFILE && \
                 incus profile set $PROFILE security.nesting=true && \
                 incus profile set $PROFILE limits.cpu=4 && \
                 incus profile set $PROFILE limits.memory=8GB"
    fi
fi

# Base Image
if command -v incus &>/dev/null && incus info &>/dev/null 2>&1; then
    if incus image list --format json | jq -e --arg img "$BASE_IMAGE" '.[] | select(.aliases[].name == $img)' &>/dev/null; then
        log_success "Base image '$BASE_IMAGE' already exists."
    else
        if [ -f "$CLOUD_INIT" ]; then
            # Using images:ubuntu/24.04 as it is the most portable source for the community images server
            execute "Provision base image '$BASE_IMAGE' (this involves launching a temporary container and may take time)" \
                    "incus launch images:ubuntu/24.04 base-temp -c user.user-data=\"\$(cat $CLOUD_INIT)\" && \
                     incus exec base-temp -- cloud-init status --wait && \
                     incus stop base-temp && \
                     incus publish base-temp --alias $BASE_IMAGE && \
                     incus delete base-temp"
        else
            log_error "Required file '$CLOUD_INIT' missing. Cannot provision base image."
        fi
    fi
fi

echo ""
echo "================================================================="
if [ "$DRY_RUN" = true ]; then
    log_info "Setup check complete. Run without --dry-run to apply necessary changes."
else
    log_success "Warden setup wizard finished!"
    log_info "You can run './warden.sh doctor' for a full diagnostic report."
fi
