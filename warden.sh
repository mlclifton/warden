#!/bin/bash
# warden.sh - Manage Incus-based development environments

set -e

# Configuration
JAIL_ROOT="$HOME/jails"
BASE_IMAGE="base-dev-v2"
PROFILE="dev-profile"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
  echo "Usage: $0 <command> [arguments]"
  echo ""
  echo "Commands:"
  echo "  create <name> [git_url] [--image <image>]   Create a new dev environment"
  echo "  connect <name>                               Connect to an existing environment"
  echo "  destroy <name>                               Destroy an environment"
  echo "  list                                         List all environments"
  echo "  save-image <jail> <name>                     Save a jail's state as a named image"
  echo "  images                                       List all warden-managed images"
  echo "  image-info <name>                            Show image details and which jails use it"
  echo "  delete-image <name> [--yes]                  Delete a warden-managed image"
  echo "  doctor                                       Check installation and report any issues"
  echo "  fix-terminal <name>                          Fix terminal/backspace issues in an existing container"
  echo ""
}

cmd_doctor() {
  local all_ok=true

  echo "Checking Warden dependencies..."
  echo ""

  # --- CLI tools ---
  check_tool() {
    local cmd=$1 install_hint=$3
    if command -v "$cmd" &>/dev/null; then
      log_success "$cmd found ($(command -v "$cmd"))"
    else
      log_error "$cmd not found"
      echo "         Install: $install_hint"
      all_ok=false
    fi
  }

  check_tool incus  incus   "https://linuxcontainers.org/incus/docs/main/installing/"
  check_tool jq     jq      "sudo dnf install jq  OR  sudo apt install jq"
  check_tool git    git     "sudo dnf install git  OR  sudo apt install git"
  check_tool ssh    openssh "sudo dnf install openssh-clients  OR  sudo apt install openssh-client"
  check_tool zellij zellij  "cargo install zellij  OR  see https://zellij.dev/documentation/installation"

  echo ""
  echo "Checking Incus configuration..."
  echo ""

  # --- incus daemon reachable ---
  if command -v incus &>/dev/null; then
    if incus info &>/dev/null 2>&1; then
      log_success "incus daemon reachable"
    else
      log_error "incus daemon not reachable (permission issue or not running)"
      echo "         Try: sudo systemctl start incus"
      echo "              sudo usermod -aG incus-admin \$USER  (then log out/in)"
      all_ok=false
    fi

    # --- base image ---
    if incus info &>/dev/null 2>&1; then
      if incus image list --format json 2>/dev/null | jq -e --arg img "$BASE_IMAGE" \
          '.[] | select(.aliases[].name == $img)' &>/dev/null; then
        log_success "Base image '$BASE_IMAGE' found"
      else
        log_error "Base image '$BASE_IMAGE' not found"
        echo "         Provision a container with cloud-init.yaml, then snapshot it:"
        echo "           incus launch images:ubuntu/24.04/cloud base-temp -c user.user-data=\"\$(cat cloud-init.yaml)\""
        echo "           # Wait for cloud-init to finish..."
        echo "           incus exec base-temp -- cloud-init status --wait"
        echo "           incus stop base-temp"
        echo "           incus publish base-temp --alias $BASE_IMAGE"
        echo "           incus delete base-temp"
        all_ok=false
      fi

      # --- dev-profile ---
      if incus profile list --format json 2>/dev/null | jq -e --arg p "$PROFILE" \
          '.[] | select(.name == $p)' &>/dev/null; then
        log_success "Profile '$PROFILE' found"
      else
        log_error "Profile '$PROFILE' not found"
        echo "         Create it: incus profile create $PROFILE"
        echo "         Then configure resource limits and security.nesting=true:"
        echo "           incus profile set $PROFILE security.nesting=true"
        all_ok=false
      fi

      # --- incusbr0 network ---
      if incus network list --format json 2>/dev/null | jq -e '.[] | select(.name == "incusbr0")' &>/dev/null; then
        log_success "Network 'incusbr0' found"
      else
        log_error "Network 'incusbr0' not found"
        echo "         Create it: incus network create incusbr0"
        all_ok=false
      fi

      # --- firewalld (Fedora specific) ---
      if [ -f /etc/fedora-release ] && command -v firewall-cmd &>/dev/null; then
        if firewall-cmd --get-active-zones | grep -q "^incus"; then
          log_success "Firewalld 'incus' zone is active"
        else
          log_error "Firewalld 'incus' zone NOT active (networking may be blocked)"
          echo "         Run: ./setup_incus.sh to configure firewall"
          all_ok=false
        fi
      fi
    fi
  fi

  echo ""
  echo "Checking host directories..."
  echo ""

  # --- jail root ---
  if [ -d "$JAIL_ROOT" ]; then
    log_success "Jail root '$JAIL_ROOT' exists"
  else
    log_info "Jail root '$JAIL_ROOT' does not exist (will be created on first 'create')"
  fi

  echo ""
  if $all_ok; then
    log_success "All checks passed. Warden is ready to use."
  else
    log_error "Some checks failed. Resolve the issues above before using Warden."
    echo ""
    log_info "Tip: You can run './setup_incus.sh' to automatically fix most configuration issues."
    return 1
  fi
}

cmd_create() {
  local name=${1:-}

  if [ -z "$name" ]; then
    log_error "Project name required."
    usage
    exit 1
  fi
  shift

  local git_url=""
  local image_name="$BASE_IMAGE"
  local init_image="$BASE_IMAGE"

  # Parse remaining args: [git_url] [--image <name>]
  while [ $# -gt 0 ]; do
    case "$1" in
      --image)
        shift
        if [ -z "$1" ]; then
          log_error "--image requires a value."
          exit 1
        fi
        image_name="$1"
        init_image="warden/$1"
        ;;
      -*)
        log_error "Unknown option: $1"
        usage
        exit 1
        ;;
      *)
        if [ -z "$git_url" ]; then
          git_url="$1"
        else
          log_error "Unexpected argument: $1"
          usage
          exit 1
        fi
        ;;
    esac
    shift
  done

  # Validate custom image exists if --image was specified
  if [ "$init_image" != "$BASE_IMAGE" ]; then
    local img_count
    img_count=$(incus image list --format json | jq --arg a "$init_image" \
      '[.[] | select(any(.aliases[]; .name == $a))] | length')
    if [ "$img_count" -eq 0 ]; then
      log_error "Image '$image_name' not found. Use '$0 images' to see available images."
      exit 1
    fi
  fi

  local project_dir="$JAIL_ROOT/$name"

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
    if [ "$(ls -A "$project_dir")" ]; then
      log_info "Directory not empty, skipping git clone."
    else
      log_info "Cloning $git_url..."
      git clone "$git_url" "$project_dir"
    fi
  fi

  # 3. Initialize Container
  log_info "Initializing container from $init_image..."
  incus init "$init_image" "$name" -p default -p "$PROFILE"

  # 4. Record which image this jail was built from
  incus config set "$name" user.warden.base_image "$image_name"

  # 5. Configure ID Mapping (Skipped in favor of shift=true)
  # Using shift=true on the disk device handles the mapping cleanly on modern kernels.

  log_info "Mounting $project_dir to /home/dev/project..."
  incus config device add "$name" project_code disk source="$project_dir" path=/home/dev/project shift=true

  # 6. Start Container
  log_info "Starting container..."
  incus start "$name"

  # 7. Set User Password
  if [ -t 0 ]; then
    echo -n "Set password for 'dev' user (press Enter to skip): "
    read -rs PASSWORD
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
  for _ in {1..30}; do
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
  local ip
  ip=$(incus list "$name" --format json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet") | .address' | head -n 1)

  if [ -z "$ip" ] || [ "$ip" == "null" ]; then
    log_error "Could not determine IP address. Is networking active?"
    exit 1
  fi

  log_info "Connecting to $name ($ip)..."
  
  # Ensure we have a sane terminal environment
  local term_to_use="${TERM:-xterm-256color}"

  # Using -o StrictHostKeyChecking=no to avoid known_hosts issues with ephemeral containers
  # We first check if the remote system knows about our TERM. If not, fallback to xterm-256color.
  # Then run 'stty sane' and launch zellij.
  ssh -A -o StrictHostKeyChecking=no "dev@$ip" -t "
    if ! infocmp $term_to_use >/dev/null 2>&1; then
      export TERM=xterm-256color
    else
      export TERM=$term_to_use
    fi
    stty sane; zellij attach -c options || zellij -l default
  "
}

cmd_destroy() {
  local name=$1
  if [ -z "$name" ]; then
    log_error "Project name required."
    usage
    exit 1
  fi

  if ! incus info "$name" &>/dev/null; then
    log_error "Instance '$name' not found. Run '$0 list' to see available jails."
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
      rm -rf "${JAIL_ROOT:?}/$name"
      log_success "Directory deleted."
    fi
  else
    log_info "Skipping directory deletion prompt (non-interactive)."
  fi
}

cmd_list() {
  local json
  json=$(incus list --format json 2>/dev/null)

  if [ "$(echo "$json" | jq 'length')" -eq 0 ]; then
    log_info "No jails found."
    return
  fi

  printf "%-28s  %-10s  %-16s  %-11s  %s\n" "NAME" "STATE" "IPV4" "TYPE" "PROJECT DIR"
  printf "%-28s  %-10s  %-16s  %-11s  %s\n" \
    "----------------------------" "----------" "----------------" "-----------" "--------------------"

  echo "$json" | jq -r '.[] | [
    .name,
    .state.status,
    ((.state.network.eth0.addresses // []) | map(select(.family=="inet")) | .[0].address // "-"),
    .type
  ] | @tsv' | while IFS=$'\t' read -r name state ip type; do
    local dir="$JAIL_ROOT/$name"
    [ -d "$dir" ] || dir="-"
    printf "%-28s  %-10s  %-16s  %-11s  %s\n" "$name" "$state" "$ip" "$type" "$dir"
  done
}

cmd_fix_terminal() {
  local name=$1
  if [ -z "$name" ]; then
    log_error "Project name required."
    exit 1
  fi
  
  if ! incus info "$name" &>/dev/null; then
    log_error "Instance '$name' not found."
    exit 1
  fi

  log_info "Updating terminal definitions in '$name'..."
  # Use non-interactive apt and skip if already installed
  incus exec "$name" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y ncurses-term kitty-terminfo"
  
  log_success "Terminal definitions updated. Try connecting again with './warden.sh connect $name'."
}

cmd_save_image() {
  local jail_name=$1
  local image_name=$2

  if [ -z "$jail_name" ] || [ -z "$image_name" ]; then
    log_error "Usage: $0 save-image <jail-name> <image-name>"
    exit 1
  fi

  # Check jail exists
  if ! incus info "$jail_name" &>/dev/null; then
    log_error "Instance '$jail_name' not found."
    exit 1
  fi

  # Check alias does not already exist
  local alias_count
  alias_count=$(incus image list --format json | jq --arg a "warden/$image_name" \
    '[.[] | select(any(.aliases[]; .name == $a))] | length')
  if [ "$alias_count" -gt 0 ]; then
    log_error "Image '$image_name' already exists. Use '$0 delete-image $image_name' first."
    exit 1
  fi

  # Stop jail if running (remember state for restart)
  local was_running=false
  if incus info "$jail_name" | grep -q "Status: RUNNING"; then
    was_running=true
    log_info "Stopping '$jail_name' for consistent snapshot..."
    if ! incus stop "$jail_name"; then
      log_error "Failed to stop '$jail_name'."
      exit 1
    fi
  fi

  # Publish image
  log_info "Publishing image '$image_name'..."
  local publish_ok=true
  incus publish "$jail_name" \
    --alias "warden/$image_name" \
    "user.warden.image_name=$image_name" \
    "user.warden.saved_from=$jail_name" || publish_ok=false

  # Restart if jail was running (attempt regardless of publish outcome)
  if $was_running; then
    log_info "Restarting '$jail_name'..."
    incus start "$jail_name" || log_warn "Failed to restart '$jail_name'. Start it manually."
  fi

  if ! $publish_ok; then
    log_error "Failed to publish image '$image_name'."
    exit 1
  fi

  local fingerprint
  fingerprint=$(incus image info "warden/$image_name" | awk '/^Fingerprint:/ {print $2}')
  log_success "Image '$image_name' saved (fingerprint: $fingerprint)."
}

cmd_images() {
  local json
  json=$(incus image list --format json 2>/dev/null)

  local warden_images
  warden_images=$(echo "$json" | jq -r '
    [.[] | select(any(.aliases[]; .name | startswith("warden/")))] |
    if length == 0 then empty
    else .[] | [
      (.aliases[] | select(.name | startswith("warden/")) | .name[7:]),
      .fingerprint[0:12],
      (.size / 1073741824 * 10 | round / 10 | tostring + " GiB"),
      (.created_at | split(".")[0] | gsub("T"; " ")),
      (.properties["user.warden.saved_from"] // "-")
    ] | @tsv
    end')

  if [ -z "$warden_images" ]; then
    log_info "No warden-managed images found. Use '$0 save-image' to create one."
    return
  fi

  printf "%-16s  %-12s  %-8s  %-19s  %s\n" "NAME" "FINGERPRINT" "SIZE" "CREATED" "SAVED FROM"
  printf "%-16s  %-12s  %-8s  %-19s  %s\n" \
    "----------------" "------------" "--------" "-------------------" "----------"

  while IFS=$'\t' read -r name fingerprint size created saved_from; do
    printf "%-16s  %-12s  %-8s  %-19s  %s\n" "$name" "$fingerprint" "$size" "$created" "$saved_from"
  done <<<"$warden_images"
}

cmd_image_info() {
  local image_name=$1

  if [ -z "$image_name" ]; then
    log_error "Usage: $0 image-info <image-name>"
    exit 1
  fi

  # Check image exists and get its data
  local alias_count
  alias_count=$(incus image list --format json | jq --arg a "warden/$image_name" \
    '[.[] | select(any(.aliases[]; .name == $a))] | length')
  if [ "$alias_count" -eq 0 ]; then
    log_error "Image '$image_name' not found."
    exit 1
  fi

  local image_data
  image_data=$(incus image list --format json | jq --arg a "warden/$image_name" \
    '[.[] | select(any(.aliases[]; .name == $a))] | .[0]')

  local fingerprint size created saved_from
  fingerprint=$(echo "$image_data" | jq -r '.fingerprint')
  size=$(echo "$image_data" | jq -r '(.size / 1073741824 * 10 | round / 10 | tostring + " GiB")')
  created=$(echo "$image_data" | jq -r '.created_at | split(".")[0] | gsub("T"; " ")')
  saved_from=$(echo "$image_data" | jq -r '.properties["user.warden.saved_from"] // "-"')

  echo "Image: $image_name"
  echo "  Fingerprint : $fingerprint"
  echo "  Size        : $size"
  echo "  Created     : $created"
  echo "  Saved from  : $saved_from"
  echo ""
  echo "Jails created from this image:"

  local jails
  jails=$(incus list --format json | jq -r --arg img "$image_name" \
    '.[] | select(.config["user.warden.base_image"] == $img) |
     "  " + .name + "   (" + .state.status + ")"')

  if [ -z "$jails" ]; then
    echo "  (none)"
  else
    echo "$jails"
  fi
}

cmd_delete_image() {
  local image_name=""
  local yes_flag=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y)
        yes_flag=true
        ;;
      -*)
        log_error "Unknown option: $1"
        usage
        exit 1
        ;;
      *)
        if [ -z "$image_name" ]; then
          image_name="$1"
        else
          log_error "Unexpected argument: $1"
          usage
          exit 1
        fi
        ;;
    esac
    shift
  done

  if [ -z "$image_name" ]; then
    log_error "Usage: $0 delete-image <image-name>"
    exit 1
  fi

  # Check image exists
  local alias_count
  alias_count=$(incus image list --format json | jq --arg a "warden/$image_name" \
    '[.[] | select(any(.aliases[]; .name == $a))] | length')
  if [ "$alias_count" -eq 0 ]; then
    log_error "Image '$image_name' not found."
    exit 1
  fi

  # Warn about dependent jails
  local dependent_jails
  dependent_jails=$(incus list --format json | jq -r --arg img "$image_name" \
    '[.[] | select(.config["user.warden.base_image"] == $img) | .name] | join(", ")')
  if [ -n "$dependent_jails" ]; then
    local dep_count
    dep_count=$(incus list --format json | jq --arg img "$image_name" \
      '[.[] | select(.config["user.warden.base_image"] == $img)] | length')
    log_warn "$dep_count jail(s) were created from '$image_name' ($dependent_jails)."
    log_warn "Deleting this image will not affect those jails."
  fi

  # Determine whether to proceed: --yes skips the prompt; TTY prompts; non-TTY skips
  if $yes_flag; then
    : # proceed without prompting
  elif [ -t 0 ]; then
    read -r -p "Delete image '$image_name'? [y/N] " reply
    if [[ ! $reply =~ ^[Yy]$ ]]; then
      log_info "Deletion cancelled."
      return
    fi
  else
    log_info "Non-interactive mode: skipping deletion prompt. Use --yes to force deletion."
    return
  fi

  incus image delete "warden/$image_name"
  log_success "Image '$image_name' deleted."
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
save-image)
  cmd_save_image "$@"
  ;;
images)
  cmd_images "$@"
  ;;
image-info)
  cmd_image_info "$@"
  ;;
delete-image)
  cmd_delete_image "$@"
  ;;
doctor)
  cmd_doctor "$@"
  ;;
fix-terminal)
  cmd_fix_terminal "$@"
  ;;
*)
  log_error "Unknown command: $COMMAND"
  usage
  exit 1
  ;;
esac
