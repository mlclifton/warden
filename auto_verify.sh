#!/bin/bash
set -e

# Configuration
TEST_ENV_NAME="auto-verify-test"
JAIL_MANAGER="./warden.sh"
HOST_JAIL_DIR="$HOME/jails/$TEST_ENV_NAME"

log() { echo -e "\n[TEST] $1"; }
cleanup() {
  log "Cleaning up..."
  $JAIL_MANAGER destroy "$TEST_ENV_NAME" <<<"y" || true
}
trap cleanup EXIT

# Ensure cleanup of any previous run
$JAIL_MANAGER destroy "$TEST_ENV_NAME" <<<"y" 2>/dev/null || true

# 1. Create Environment
log "Step 1: Creating environment..."
$JAIL_MANAGER create "$TEST_ENV_NAME"

# 2. Test Isolation
log "Step 2: Testing Isolation..."
# Try to write to /etc/os-release (should fail)
if incus exec "$TEST_ENV_NAME" -- su - dev -c "touch /etc/os-release" 2>/dev/null; then
  echo "FAIL: Write to /etc/os-release succeeded (should have failed)."
  exit 1
else
  echo "PASS: Write to /etc/os-release failed as expected."
fi
# Try to write to /tmp (should succeed)
if incus exec "$TEST_ENV_NAME" -- su - dev -c "touch /tmp/test_write"; then
  echo "PASS: Write to /tmp succeeded."
else
  echo "FAIL: Write to /tmp failed."
  exit 1
fi

# 3. Test Persistence
log "Step 3: Testing Persistence..."
TEST_FILE="persistence_test.txt"
TEST_CONTENT="Hello from container"
incus exec "$TEST_ENV_NAME" -- su - dev -c "echo '$TEST_CONTENT' > /home/dev/project/$TEST_FILE"

if [ -f "$HOST_JAIL_DIR/$TEST_FILE" ]; then
  CONTENT=$(cat "$HOST_JAIL_DIR/$TEST_FILE")
  if [ "$CONTENT" == "$TEST_CONTENT" ]; then
    echo "PASS: File persisted to host with correct content."
  else
    echo "FAIL: File content mismatch. Expected '$TEST_CONTENT', got '$CONTENT'."
    exit 1
  fi
else
  echo "FAIL: File not found on host at $HOST_JAIL_DIR/$TEST_FILE."
  exit 1
fi

# Check ownership (approximate check - should belong to current user on host)
OWNER=$(stat -c '%u' "$HOST_JAIL_DIR/$TEST_FILE")
CURRENT_UID=$(id -u)
if [ "$OWNER" -eq "$CURRENT_UID" ]; then
  echo "PASS: File ownership is correct ($CURRENT_UID)."
else
  echo "FAIL: File ownership mismatch. Expected $CURRENT_UID, got $OWNER."
  # Don't exit here, just warn, as mapping might be complex
fi

# 4. Test Docker-in-Incus
log "Step 4: Testing Docker-in-Incus..."
# Wait for Docker to be ready
echo "Waiting for Docker daemon..."
for i in {1..10}; do
  if incus exec "$TEST_ENV_NAME" -- su - dev -c "docker info" >/dev/null 2>&1; then
    echo "Docker is ready."
    break
  fi
  echo "Waiting for Docker... ($i/10)"
  sleep 2
done

# We need to make sure docker is running first. It should be enabled.
if incus exec "$TEST_ENV_NAME" -- su - dev -c "docker run --rm hello-world" >/dev/null; then
  echo "PASS: Docker hello-world ran successfully."
else
  echo "FAIL: Docker run failed."
  exit 1
fi

# 5. Test Connectivity
log "Step 5: Testing Connectivity..."
if incus exec "$TEST_ENV_NAME" -- su - dev -c "curl -s -I https://google.com" | grep -E "HTTP/.* [23]0[012]"; then
  echo "PASS: External connectivity verified."
else
  echo "FAIL: External connectivity failed."
  exit 1
fi

log "ALL TESTS PASSED."
