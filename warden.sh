#!/bin/bash
# warden.sh - Manage Incus-based development environments

set -e

# Configuration
JAIL_ROOT="$HOME/jails"
BASE_IMAGE="base-dev-v1"
PROFILE="dev-profile"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
  echo "Usage: $0 <command> [arguments]"
  echo ""
  echo "Commands:"
  echo "  create <name> [git_url]   Create a new dev environment"
  echo "  connect <name>            Connect to an existing environment"
  echo "  destroy <name>            Destroy an environment"
  echo "  list                      List all environments"
  echo ""
}

cmd_create() {
  local name=$1
  local git_url=$2
  local project_dir="$JAIL_ROOT/$name"

  if [ -z "$name" ]; then
    log_error "Project name required."
    usage
    exit 1
  fi

  if incus info "$name" &>/dev/null; then
    log_error "Instance '$name' already exists."
    exit 1
  fi

  log_info "Creating project '$name'..."

  # 1. Prepare Host Directory
  if [ -d "$project_dir" ]; then
    log_info "Directory $project_dir already exists. Using it."
  else
    log_info "Creating directory $project_dir..."
    mkdir -p "$project_dir"
  fi

  # 2. Git Clone (if requested)
  if [ -n "$git_url" ]; then
    if [ "$(ls -A $project_dir)" ]; then
      log_info "Directory not empty, skipping git clone."
    else
      log_info "Cloning $git_url..."
      git clone "$git_url" "$project_dir"
    fi
  fi

  # 3. Initialize Container
  log_info "Initializing container from $BASE_IMAGE..."
  incus init "$BASE_IMAGE" "$name" -p default -p "$PROFILE"

  # 4. Configure ID Mapping (Skipped in favor of shift=true)
  # Using shift=true on the disk device handles the mapping cleanly on modern kernels.

  log_info "Mounting $project_dir to /home/dev/project..."
  incus config device add "$name" project_code disk source="$project_dir" path=/home/dev/project shift=true

  # 6. Start Container
  log_info "Starting container..."
  incus start "$name"

  # 7. Set User Password
  if [ -t 0 ]; then
    echo -n "Set password for 'dev' user (press Enter to skip): "
    read -s PASSWORD
    echo
    if [ -n "$PASSWORD" ]; then
      log_info "Setting password..."
      # Wait a moment for the container to be ready to execute commands
      sleep 2
      echo "dev:$PASSWORD" | incus exec "$name" -- chpasswd
      log_success "Password set successfully."
    fi
  fi

  # 8. Wait for Network
  log_info "Waiting for networking..."
  # We use a simple check for cloud-init status as a proxy for 'booted' since cloud-init runs on boot
  # Or just wait for an IP.
  for i in {1..30}; do
    if incus list "$name" --format json | jq -e '.[0].state.network.eth0.addresses | length > 0' >/dev/null; then
      break
    fi
    sleep 1
  done

  log_success "Environment '$name' created!"
  log_info "Connect using: $0 connect $name"
}

cmd_connect() {
  local name=$1
  if [ -z "$name" ]; then
    log_error "Project name required."
    usage
    exit 1
  fi

  # Ensure running
  if ! incus info "$name" | grep -q "Status: RUNNING"; then
    log_info "Starting $name..."
    incus start "$name"
    sleep 5
  fi

  # Get IP
  local ip=$(incus list "$name" --format json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet") | .address' | head -n 1)

  if [ -z "$ip" ] || [ "$ip" == "null" ]; then
    log_error "Could not determine IP address. Is networking active?"
    exit 1
  fi

  log_info "Connecting to $name ($ip)..."
  # Using -o StrictHostKeyChecking=no to avoid known_hosts issues with ephemeral containers
  ssh -A -o StrictHostKeyChecking=no "dev@$ip" -t "zellij attach -c options || zellij -l default"
}

cmd_destroy() {
  local name=$1
  if [ -z "$name" ]; then
    log_error "Project name required."
    usage
    exit 1
  fi

  log_info "Destroying container $name..."
  incus delete "$name" --force

  log_info "Note: Project directory $JAIL_ROOT/$name was NOT deleted."
  # Non-interactive check if needed, but for now interactive
  if [ -t 0 ]; then
    read -p "Delete project directory? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      rm -rf "$JAIL_ROOT/$name"
      log_success "Directory deleted."
    fi
  else
    log_info "Skipping directory deletion prompt (non-interactive)."
  fi
}

cmd_list() {
  incus list --columns n,s,4,t
}

# Main
if [ $# -lt 1 ]; then
  usage
  exit 1
fi

COMMAND=$1
shift

case "$COMMAND" in
create)
  cmd_create "$@"
  ;;
connect)
  cmd_connect "$@"
  ;;
destroy)
  cmd_destroy "$@"
  ;;
list)
  cmd_list "$@"
  ;;
*)
  log_error "Unknown command: $COMMAND"
  usage
  exit 1
  ;;
esac
