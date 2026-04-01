#!/bin/bash
# migrate_v1_to_v2.sh - Migrate Warden jails from base-dev-v1 to base-dev-v2

set -euo pipefail

# Configuration
OLD_IMAGE="base-dev-v1"
NEW_IMAGE="base-dev-v2"
PROFILE="dev-profile"
JAIL_ROOT="$HOME/jails"

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

# Check for new image
if ! incus image list --format json | jq -e --arg img "$NEW_IMAGE" '.[] | select(.aliases[].name == $img)' &>/dev/null; then
    log_error "New image '$NEW_IMAGE' not found. Please run ./setup_incus.sh first."
    exit 1
fi

# List containers
log_info "Searching for jails to migrate..."
# We look for containers that were created from base-dev-v1. 
# Since Incus might store the fingerprint, we check volatile.base_image if available or just list all.
# Actually, the simplest way is to check all containers and see which one we want to migrate.

JAILS=$(incus list --format json | jq -r '.[] | .name')

if [ -z "$JAILS" ]; then
    log_info "No containers found."
    exit 0
fi

echo "The following containers were found:"
for jail in $JAILS; do
    echo " - $jail"
done
echo ""

read -p "Migrate all containers to $NEW_IMAGE? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Migration cancelled."
    exit 0
fi

for name in $JAILS; do
    log_info "Migrating '$name'..."

    # 1. Check if it's a Warden jail (has the project_code disk device)
    if ! incus config device show "$name" | grep -q "project_code:"; then
        log_warn "Skipping '$name': Not a recognized Warden jail (missing project_code device)."
        continue
    fi

    # 2. Get the host path
    host_path=$(incus config device get "$name" project_code source)
    if [ -z "$host_path" ]; then
        log_error "Could not determine host path for '$name'. Skipping."
        continue
    fi

    log_info "  Host path: $host_path"

    # 3. Stop and Rename old container
    log_info "  Stopping and renaming old container..."
    incus stop "$name" --force || true
    incus rename "$name" "${name}-v1-backup"

    # 4. Create new container from v2
    log_info "  Creating new container from $NEW_IMAGE..."
    incus init "$NEW_IMAGE" "$name" -p default -p "$PROFILE"

    # 5. Re-attach the project directory
    log_info "  Attaching project directory..."
    incus config device add "$name" project_code disk source="$host_path" path=/home/dev/project shift=true

    # 6. Start
    log_info "  Starting new container..."
    incus start "$name"

    log_success "  '$name' successfully migrated to $NEW_IMAGE."
    log_info "  (Old container kept as '${name}-v1-backup')"
done

log_info "Migration complete!"
log_info "You can delete old backups manually with: incus delete <name>-v1-backup"
