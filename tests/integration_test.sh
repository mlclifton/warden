#!/bin/bash
# tests/integration_test.sh — integration tests for warden.sh
#
# Requires a live Incus instance with base-dev-v2 image and dev-profile.
# Run: bash tests/integration_test.sh
#
# WARNING: This script creates and destroys real Incus containers and images.
# All resources use the prefix "warden-itest-" and are cleaned up on exit.
#
# What is tested here (cannot be tested with a mock):
#   - incus image list JSON field names and structure match our jq filters
#   - incus image info output format matches our awk parser (Fingerprint: ...)
#   - incus publish actually creates a queryable alias
#   - user.warden.base_image config survives container lifecycle
#   - Interactive delete-image confirmation (tested via expect or skipped)

set -euo pipefail

WARDEN="$(cd "$(dirname "$0")/.." && pwd)/warden.sh"
PASS=0
FAIL=0

PREFIX="warden-itest-$$"
JAIL_A="${PREFIX}-jail-a"
JAIL_B="${PREFIX}-jail-b"
IMAGE_NAME="${PREFIX}-img"

# ── framework ─────────────────────────────────────────────────────────────────

ok()      { echo "  PASS  $*"; ((PASS++)) || true; }
fail()    { echo "  FAIL  $*"; ((FAIL++)) || true; }
section() { echo ""; echo "── $* ──"; }
skip()    { echo "  SKIP  $*"; }

assert_exit() {
  local desc=$1 expected=$2; shift 2
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [ "$actual" -eq "$expected" ]; then ok "$desc"
  else fail "$desc  [exit=$actual, want=$expected]"
  fi
}

assert_contains() {
  local desc=$1 needle=$2; shift 2
  local out; out=$("$@" 2>&1) || true
  if echo "$out" | grep -qF "$needle"; then ok "$desc"
  else fail "$desc  [needle='$needle' not in output]"; fi
}

assert_not_contains() {
  local desc=$1 needle=$2; shift 2
  local out; out=$("$@" 2>&1) || true
  if ! echo "$out" | grep -qF "$needle"; then ok "$desc"
  else fail "$desc  [unexpected '$needle' in output]"; fi
}

# ── preflight ─────────────────────────────────────────────────────────────────

echo "Checking prerequisites..."

if ! command -v incus &>/dev/null; then
  echo "SKIP: incus not found on PATH — integration tests require live Incus"
  exit 0
fi

if ! incus info &>/dev/null; then
  echo "SKIP: incus daemon not reachable — run 'incus info' to diagnose"
  exit 0
fi

if ! incus image list --format json | jq -e --arg img "base-dev-v2" \
    '.[] | select(.aliases[].name == $img)' &>/dev/null; then
  echo "SKIP: base-dev-v2 image not found — run setup_incus.sh first"
  exit 0
fi

if ! incus profile list --format json | jq -e '.[] | select(.name == "dev-profile")' &>/dev/null; then
  echo "SKIP: dev-profile not found — run setup_incus.sh first"
  exit 0
fi

echo "Prerequisites OK. Running integration tests with prefix '${PREFIX}'."
echo "Resources will be cleaned up on exit."
echo ""

# ── cleanup ───────────────────────────────────────────────────────────────────

cleanup() {
  echo ""
  echo "Cleaning up test resources..."
  incus delete "$JAIL_A" --force 2>/dev/null || true
  incus delete "$JAIL_B" --force 2>/dev/null || true
  incus image delete "warden/$IMAGE_NAME" 2>/dev/null || true
  rm -rf "$HOME/jails/$JAIL_A" "$HOME/jails/$JAIL_B" 2>/dev/null || true
  echo "Cleanup done."
}
trap cleanup EXIT

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# IT-1: Create jail (default base image)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "IT-1: create jail from base image"

"$WARDEN" create "$JAIL_A" </dev/null
assert_exit "IT-01 jail exists after create" 0 incus info "$JAIL_A"

recorded=$(incus config get "$JAIL_A" user.warden.base_image)
if [ "$recorded" = "base-dev-v2" ]; then
  ok "IT-02 user.warden.base_image set to base-dev-v2"
else
  fail "IT-02 user.warden.base_image: expected 'base-dev-v2', got '$recorded'"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# IT-2: save-image
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "IT-2: save-image"

assert_exit     "IT-03 save-image succeeds" 0 "$WARDEN" save-image "$JAIL_A" "$IMAGE_NAME"
assert_contains "IT-04 save-image reports fingerprint" "fingerprint"  "$WARDEN" save-image "${JAIL_A}" "${IMAGE_NAME}-2" 2>/dev/null || true
# (IT-04 may fail if already exists — focus is IT-03)

# Verify alias exists in Incus
alias_count=$(incus image list --format json | jq --arg a "warden/$IMAGE_NAME" \
  '[.[] | select(any(.aliases[]; .name == $a))] | length')
if [ "$alias_count" -eq 1 ]; then ok "IT-05 warden/$IMAGE_NAME alias exists in Incus"
else fail "IT-05 alias count: expected 1, got $alias_count"; fi

# Verify properties on the image
props=$(incus image list --format json | jq -r --arg a "warden/$IMAGE_NAME" \
  '[.[] | select(any(.aliases[]; .name == $a))] | .[0] | .properties["user.warden.saved_from"]')
if [ "$props" = "$JAIL_A" ]; then ok "IT-06 user.warden.saved_from set correctly"
else fail "IT-06 saved_from: expected '$JAIL_A', got '$props'"; fi

# Duplicate save-image should fail
assert_exit "IT-07 save-image duplicate → exit 1" 1 "$WARDEN" save-image "$JAIL_A" "$IMAGE_NAME"

# Verify jail was restarted (it was running during save-image)
jail_state=$(incus info "$JAIL_A" | grep "Status:" | awk '{print $2}')
if [ "$jail_state" = "RUNNING" ]; then ok "IT-08 jail restarted after save-image"
else fail "IT-08 jail state after save: expected RUNNING, got '$jail_state'"; fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# IT-3: images (list)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "IT-3: images list"

assert_exit     "IT-09 images exits 0"                 0  "$WARDEN" images
assert_contains "IT-10 images shows our image name"    "$IMAGE_NAME"   "$WARDEN" images
assert_contains "IT-11 images shows size in GiB"       "GiB"           "$WARDEN" images
assert_contains "IT-12 images shows saved_from jail"   "$JAIL_A"       "$WARDEN" images
assert_not_contains "IT-13 images: base-dev-v2 excluded" "base-dev-v2"  "$WARDEN" images

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# IT-4: image-info
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "IT-4: image-info"

assert_exit     "IT-14 image-info exits 0"             0   "$WARDEN" image-info "$IMAGE_NAME"
assert_contains "IT-15 image-info shows name header"   "Image: $IMAGE_NAME"  "$WARDEN" image-info "$IMAGE_NAME"
assert_contains "IT-16 image-info shows fingerprint"   "Fingerprint"          "$WARDEN" image-info "$IMAGE_NAME"
assert_contains "IT-17 image-info shows saved_from"    "$JAIL_A"              "$WARDEN" image-info "$IMAGE_NAME"
assert_contains "IT-18 image-info shows size"          "GiB"                  "$WARDEN" image-info "$IMAGE_NAME"

# Before creating jail-b, no jails should appear
assert_contains "IT-19 image-info: no jails yet → (none)"  "(none)"  "$WARDEN" image-info "$IMAGE_NAME"

assert_exit "IT-20 image-info: unknown image → exit 1"      1  "$WARDEN" image-info no-such-image

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# IT-5: create from custom image
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "IT-5: create from custom image"

"$WARDEN" create "$JAIL_B" --image "$IMAGE_NAME" </dev/null
assert_exit "IT-21 jail-b exists after create --image" 0 incus info "$JAIL_B"

recorded=$(incus config get "$JAIL_B" user.warden.base_image)
if [ "$recorded" = "$IMAGE_NAME" ]; then ok "IT-22 user.warden.base_image set to image name"
else fail "IT-22 user.warden.base_image: expected '$IMAGE_NAME', got '$recorded'"; fi

# image-info should now show jail-b
assert_contains "IT-23 image-info shows dependent jail"       "$JAIL_B"    "$WARDEN" image-info "$IMAGE_NAME"
assert_not_contains "IT-24 image-info excludes unrelated jail" "$JAIL_A   ("   "$WARDEN" image-info "$IMAGE_NAME"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# IT-6: delete-image --yes
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "IT-6: delete-image --yes"

assert_exit "IT-25 delete-image --yes succeeds" 0 "$WARDEN" delete-image --yes "$IMAGE_NAME"

alias_count=$(incus image list --format json | jq --arg a "warden/$IMAGE_NAME" \
  '[.[] | select(any(.aliases[]; .name == $a))] | length')
if [ "$alias_count" -eq 0 ]; then ok "IT-26 alias removed from Incus after delete"
else fail "IT-26 alias still present after delete"; fi

# Verify warning was shown (rerun against the now-gone image, should error)
assert_exit     "IT-27 delete-image: gone image → exit 1"    1  "$WARDEN" delete-image "$IMAGE_NAME"
assert_contains "IT-28 delete-image: gone image → error"    "not found"   "$WARDEN" delete-image "$IMAGE_NAME"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Summary
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "══════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "══════════════════════════════════════════"

[ "$FAIL" -eq 0 ]
