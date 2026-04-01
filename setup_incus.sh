#!/bin/bash
# setup_incus.sh - Guide the user through setting up Incus for Warden

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
echo "  Warden: Incus Environment Setup"
if [ "$DRY_RUN" = true ]; then
    echo "  *** DRY-RUN MODE: Reporting required actions only ***"
fi
echo "================================================================="

# Helper to execute or dry-run
execute() {
    local msg=$1
    local cmd=$2
    if [ "$DRY_RUN" = true ]; then
        log_dry "Action required: $msg"
    else
        log_info "$msg"
        eval "$cmd"
    fi
}

# 1. Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
fi

# 2. Check Dependencies
echo "--- Checking Dependencies ---"
check_tool() {
    local tool=$1
    if command -v "$tool" &>/dev/null; then
        log_success "Tool '$tool' is installed."
        return 0
    else
        log_warn "Tool '$tool' is missing."
        return 1
    fi
}

MISSING_TOOLS=false
for t in incus jq git zellij; do
    if ! check_tool "$t"; then MISSING_TOOLS=true; fi
done

if [ "$MISSING_TOOLS" = true ]; then
    case "$OS" in
        ubuntu|debian)
            execute "Install missing tools via apt (incus, jq, git, snapd, zellij)" "sudo apt update && sudo apt install -y incus jq git snapd && sudo snap install zellij --classic"
            ;;
        fedora)
            execute "Install missing tools via dnf (incus, jq, git, zellij)" "sudo dnf install -y incus jq git zellij"
            ;;
        *)
            log_error "Automatic installation not supported for $OS. Please install missing tools manually."
            [ "$DRY_RUN" = false ] && exit 1
            ;;
    esac
fi

# 3. Check Daemon & Permissions
echo ""
echo "--- Checking Incus Daemon ---"
DAEMON_REACHABLE=false
if command -v incus &>/dev/null; then
    if incus info &>/dev/null; then
        log_success "Incus daemon is reachable."
        DAEMON_REACHABLE=true
    else
        log_warn "Incus daemon is NOT reachable."
        if groups | grep -q "incus-admin"; then
            execute "Start incus service" "sudo systemctl start incus"
        else
            execute "Add $USER to 'incus-admin' group (Requires logout/login)" "sudo usermod -aG incus-admin $USER"
        fi
    fi
else
    log_dry "Cannot check daemon until 'incus' is installed."
fi

# 4. Check Initialization (Network)
echo ""
echo "--- Checking Initialization ---"
if [ "$DAEMON_REACHABLE" = true ]; then
    if incus network list --format json | jq -e '.[] | select(.name == "incusbr0")' &>/dev/null; then
        log_success "Incus is initialized (incusbr0 found)."
    else
        execute "Initialize Incus (incus admin init --auto)" "sudo incus admin init --auto"
    fi
else
    log_dry "Check skipped: Daemon not reachable."
fi

# 5. Check Profile
echo ""
echo "--- Checking Profile ---"
if [ "$DAEMON_REACHABLE" = true ]; then
    if incus profile list --format json | jq -e --arg p "$PROFILE" '.[] | select(.name == $p)' &>/dev/null; then
        log_success "Profile '$PROFILE' exists."
    else
        execute "Create and configure profile '$PROFILE'" "incus profile create $PROFILE && incus profile set $PROFILE security.nesting=true && incus profile set $PROFILE limits.cpu=4 && incus profile set $PROFILE limits.memory=8GB"
    fi
else
    log_dry "Check skipped: Daemon not reachable."
fi

# 6. Check Base Image
echo ""
echo "--- Checking Base Image ---"
if [ "$DAEMON_REACHABLE" = true ]; then
    if incus image list --format json | jq -e --arg img "$BASE_IMAGE" '.[] | select(.aliases[].name == $img)' &>/dev/null; then
        log_success "Base image '$BASE_IMAGE' exists."
    else
        if [ -f "$CLOUD_INIT" ]; then
            execute "Provision base image '$BASE_IMAGE' using $CLOUD_INIT" "echo 'Provisioning... (this would run incus launch, wait for cloud-init, and publish)'"
        else
            log_error "Cloud-init file '$CLOUD_INIT' missing. Cannot provision image."
        fi
    fi
else
    log_dry "Check skipped: Daemon not reachable."
fi

echo ""
echo "-----------------------------------------------------------------"
if [ "$DRY_RUN" = true ]; then
    log_info "Dry-run complete."
else
    log_success "Setup script finished."
    ./warden.sh doctor
fi
