#!/bin/bash
# tests/test_warden.sh — automated unit + mock tests for warden.sh
#
# Tests are split into sections:
#   1. Argument validation   — exit before any incus call; no mock needed
#   2. jq expression tests   — test data transformation logic with fixture JSON
#   3. cmd_images            — table output with mock incus
#   4. cmd_image_info        — metadata display with mock incus
#   5. cmd_delete_image      — non-interactive path + warning logic
#   6. cmd_save_image        — all flow variants (stop/run/fail)
#   7. cmd_create --image    — argument parsing + image validation
#
# Run: bash tests/test_warden.sh
# Requirements: jq must be installed. No live incus required.

set -euo pipefail

WARDEN="$(cd "$(dirname "$0")/.." && pwd)/warden.sh"
PASS=0
FAIL=0

# ── test framework ────────────────────────────────────────────────────────────

ok()   { echo "  PASS  $*"; ((PASS++)) || true; }
fail() { echo "  FAIL  $*"; ((FAIL++)) || true; }

section() { echo ""; echo "── $* ──"; }

# Run command, check exit code
assert_exit() {
  local desc=$1 expected=$2; shift 2
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    ok "$desc"
  else
    fail "$desc  [exit=$actual, want=$expected]"
  fi
}

# Run command, check stdout+stderr contains a fixed string
assert_contains() {
  local desc=$1 needle=$2; shift 2
  local out; out=$("$@" 2>&1) || true
  if echo "$out" | grep -qF -- "$needle"; then
    ok "$desc"
  else
    fail "$desc  [needle='$needle' not in output]"
    echo "    output was: $(echo "$out" | head -5)"
  fi
}

# Run command, check stdout+stderr does NOT contain a fixed string
assert_not_contains() {
  local desc=$1 needle=$2; shift 2
  local out; out=$("$@" 2>&1) || true
  if ! echo "$out" | grep -qF -- "$needle"; then
    ok "$desc"
  else
    fail "$desc  [unexpected '$needle' in output]"
  fi
}

# Check mock log for a call matching an extended-regex pattern
assert_called() {
  local desc=$1 pattern=$2
  if grep -qE "$pattern" "$MOCK_LOG" 2>/dev/null; then
    ok "$desc"
  else
    fail "$desc  [no call matching '$pattern']"
    echo "    mock log: $(cat "$MOCK_LOG" 2>/dev/null | head -10)"
  fi
}

# Check mock log does NOT contain a call matching an extended-regex pattern
assert_not_called() {
  local desc=$1 pattern=$2
  if ! grep -qE "$pattern" "$MOCK_LOG" 2>/dev/null; then
    ok "$desc"
  else
    fail "$desc  [unexpected call matching '$pattern']"
  fi
}

# ── mock incus setup ──────────────────────────────────────────────────────────

MOCK_DIR=""
MOCK_LOG=""

# Call before each test section that needs a mock. Prepends a fake 'incus' to PATH.
# Control behavior via env vars (see mock script below).
setup_mock() {
  MOCK_DIR=$(mktemp -d)
  MOCK_LOG="$MOCK_DIR/calls.log"
  touch "$MOCK_LOG"

  cat > "$MOCK_DIR/incus" << 'MOCK_SCRIPT'
#!/bin/bash
# Mock incus — controlled via environment variables:
#
#   MOCK_JAIL_EXISTS    space-separated jail names that "exist"
#   MOCK_JAIL_RUNNING   space-separated jail names that are "running"
#   MOCK_IMAGE_LIST     JSON string for 'incus image list --format json'
#   MOCK_CONTAINER_LIST JSON string for 'incus list [name] --format json'
#   MOCK_PUBLISH_FAIL   non-empty → incus publish exits 1
#   MOCK_STOP_FAIL      non-empty → incus stop exits 1
#   MOCK_LOG            path to call log file

echo "$*" >> "${MOCK_LOG:-/dev/null}"

jail_exists() {
  local n=$1
  for j in ${MOCK_JAIL_EXISTS:-}; do [ "$j" = "$n" ] && return 0; done
  return 1
}

jail_running() {
  local n=$1
  for j in ${MOCK_JAIL_RUNNING:-}; do [ "$j" = "$n" ] && return 0; done
  return 1
}

case "$1" in
  info)
    name=$2
    if jail_exists "$name"; then
      if jail_running "$name"; then
        printf "Name: %s\nStatus: RUNNING\n" "$name"
      else
        printf "Name: %s\nStatus: STOPPED\n" "$name"
      fi
      exit 0
    fi
    echo "Error: Instance not found" >&2
    exit 1
    ;;

  image)
    case "$2" in
      list)
        echo "${MOCK_IMAGE_LIST:-[]}"
        exit 0
        ;;
      info)
        # incus image info warden/<name>
        printf "Fingerprint: abc123def456abc123def456abc123def456\nSize: 1.20GiB (1288490189 bytes)\nCreated: 2026/04/05 14:32 UTC\n"
        exit 0
        ;;
      delete)
        exit 0
        ;;
    esac
    ;;

  list)
    # incus list [<name>] --format json
    # Return fixture regardless of name filter (network-wait loop uses this)
    echo "${MOCK_CONTAINER_LIST:-[]}"
    exit 0
    ;;

  publish)
    [ -n "${MOCK_PUBLISH_FAIL:-}" ] && { echo "Error: publish failed" >&2; exit 1; }
    exit 0
    ;;

  stop)
    [ -n "${MOCK_STOP_FAIL:-}" ] && { echo "Error: stop failed" >&2; exit 1; }
    exit 0
    ;;

  start | init | config | profile | network | exec)
    exit 0
    ;;

  *)
    exit 0
    ;;
esac
MOCK_SCRIPT

  chmod +x "$MOCK_DIR/incus"
  export PATH="$MOCK_DIR:$PATH"
  export MOCK_LOG
}

teardown_mock() {
  [ -n "$MOCK_DIR" ] && rm -rf "$MOCK_DIR"
  MOCK_DIR=""
  MOCK_LOG=""
}

reset_log() { > "$MOCK_LOG"; }

# Cleanup on exit
TEST_JAIL_PREFIX="warden-test-$$"
cleanup() {
  teardown_mock 2>/dev/null || true
  # Remove any host dirs created by cmd_create tests
  rm -rf "$HOME/jails/$TEST_JAIL_PREFIX"* 2>/dev/null || true
}
trap cleanup EXIT

# ── JSON fixtures ─────────────────────────────────────────────────────────────

IMAGE_LIST_EMPTY='[]'

IMAGE_LIST_ONE_WARDEN='[{
  "aliases": [{"name": "warden/python-ds", "description": ""}],
  "fingerprint": "abc123def456abc123def456abc123de",
  "size": 1288490189,
  "created_at": "2026-04-05T14:32:00.000000Z",
  "properties": {
    "user.warden.image_name": "python-ds",
    "user.warden.saved_from": "my-project"
  }
}]'

IMAGE_LIST_TWO_WARDEN='[
  {
    "aliases": [{"name": "warden/python-ds", "description": ""}],
    "fingerprint": "abc123def456abc123def456abc123de",
    "size": 1288490189,
    "created_at": "2026-04-05T14:32:00.000000Z",
    "properties": {"user.warden.image_name": "python-ds", "user.warden.saved_from": "my-project"}
  },
  {
    "aliases": [{"name": "warden/ml-base", "description": ""}],
    "fingerprint": "beef00112233beef00112233beef0011",
    "size": 2254857011,
    "created_at": "2026-04-01T09:10:00.000000Z",
    "properties": {"user.warden.image_name": "ml-base", "user.warden.saved_from": "ml-sandbox"}
  }
]'

# Image list that also includes a non-warden image (base-dev-v2 should be excluded)
IMAGE_LIST_MIXED='[
  {
    "aliases": [{"name": "base-dev-v2", "description": ""}],
    "fingerprint": "deadbeef0000deadbeef0000deadbeef",
    "size": 900000000,
    "created_at": "2026-03-01T10:00:00.000000Z",
    "properties": {}
  },
  {
    "aliases": [{"name": "warden/python-ds", "description": ""}],
    "fingerprint": "abc123def456abc123def456abc123de",
    "size": 1288490189,
    "created_at": "2026-04-05T14:32:00.000000Z",
    "properties": {"user.warden.image_name": "python-ds", "user.warden.saved_from": "my-project"}
  }
]'

# Container list: one jail built from python-ds image, with network (breaks wait loop)
CONTAINER_LIST_WITH_JAIL='[{
  "name": "my-jail",
  "state": {
    "status": "Running",
    "network": {"eth0": {"addresses": [{"family": "inet", "address": "10.0.0.5"}]}}
  },
  "config": {"user.warden.base_image": "python-ds"},
  "type": "container"
}]'

# Container list: two jails, one from python-ds, one from ml-base
CONTAINER_LIST_TWO_JAILS='[
  {
    "name": "ds-experiment-1",
    "state": {"status": "Running", "network": {"eth0": {"addresses": [{"family": "inet", "address": "10.0.0.5"}]}}},
    "config": {"user.warden.base_image": "python-ds"},
    "type": "container"
  },
  {
    "name": "other-jail",
    "state": {"status": "Stopped", "network": null},
    "config": {"user.warden.base_image": "ml-base"},
    "type": "container"
  }
]'

CONTAINER_LIST_EMPTY='[]'

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SECTION 1: Argument validation (no incus calls)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "1. Argument validation (no incus)"

assert_exit   "T01 no command → exit 1"                            1  "$WARDEN"
assert_exit   "T02 unknown command → exit 1"                       1  "$WARDEN" unknowncmd
assert_contains "T03 unknown command → 'Unknown command' in output"   "Unknown command" "$WARDEN" unknowncmd

assert_exit   "T04 create: no name → exit 1"                      1  "$WARDEN" create
assert_contains "T05 create: no name → 'Project name required'"      "Project name required" "$WARDEN" create

assert_exit   "T06 save-image: no args → exit 1"                   1  "$WARDEN" save-image
assert_exit   "T07 save-image: only jail name → exit 1"            1  "$WARDEN" save-image myjail

assert_exit   "T08 image-info: no args → exit 1"                   1  "$WARDEN" image-info
assert_exit   "T09 delete-image: no args → exit 1"                 1  "$WARDEN" delete-image

assert_exit   "T10 create: --image without value → exit 1"         1  "$WARDEN" create myjail --image
assert_contains "T11 create: --image without value → message"        "--image requires a value" "$WARDEN" create myjail --image

assert_exit   "T12 create: unknown flag → exit 1"                  1  "$WARDEN" create myjail --unknown-flag
assert_exit   "T13 create: extra positional arg → exit 1"          1  "$WARDEN" create myjail https://example.com extra-arg
assert_contains "T14 create: extra arg → 'Unexpected argument'"      "Unexpected argument" "$WARDEN" create myjail https://example.com extra-arg

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SECTION 2: jq expression tests (data transformation, no warden.sh involved)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "2. jq expression tests"

# These test the exact jq filter used by cmd_images to produce TSV rows.
# If the incus JSON format differs from the fixture, these will catch it.

IMAGES_JQ='[.[] | select(any(.aliases[]; .name | startswith("warden/")))] |
  if length == 0 then empty
  else .[] | [
    (.aliases[] | select(.name | startswith("warden/")) | .name[7:]),
    .fingerprint[0:12],
    (.size / 1073741824 * 10 | round / 10 | tostring + " GiB"),
    (.created_at | split(".")[0] | gsub("T"; " ")),
    (.properties["user.warden.saved_from"] // "-")
  ] | @tsv
  end'

jq_images() { echo "$1" | jq -r "$IMAGES_JQ"; }

result=$(jq_images "$IMAGE_LIST_EMPTY")
if [ -z "$result" ]; then ok "T15 images jq: empty list → empty output"
else fail "T15 images jq: empty list → expected empty, got '$result'"; fi

result=$(jq_images "$IMAGE_LIST_ONE_WARDEN")
if echo "$result" | grep -q "python-ds"; then ok "T16 images jq: warden image → name in output"
else fail "T16 images jq: name 'python-ds' not in output"; fi

if echo "$result" | grep -q "my-project"; then ok "T17 images jq: saved_from in output"
else fail "T17 images jq: saved_from 'my-project' not in output"; fi

if echo "$result" | grep -q "GiB"; then ok "T18 images jq: size formatted as GiB"
else fail "T18 images jq: size not formatted as GiB"; fi

if echo "$result" | grep -q "2026-04-05 14:32"; then ok "T19 images jq: created_at T-replaced with space"
else fail "T19 images jq: created_at not formatted correctly"; fi

result=$(jq_images "$IMAGE_LIST_MIXED")
if echo "$result" | grep -q "base-dev-v2"; then
  fail "T20 images jq: non-warden image leaked into output"
else ok "T20 images jq: non-warden image excluded"; fi

row_count=$(jq_images "$IMAGE_LIST_TWO_WARDEN" | wc -l | tr -d ' ')
if [ "$row_count" -eq 2 ]; then ok "T21 images jq: two warden images → two rows"
else fail "T21 images jq: expected 2 rows, got $row_count"; fi

# Test that the alias name has warden/ stripped (name[7:] slice)
result=$(jq_images "$IMAGE_LIST_ONE_WARDEN" | cut -f1)
if [ "$result" = "python-ds" ]; then ok "T22 images jq: warden/ prefix stripped from name"
else fail "T22 images jq: name should be 'python-ds', got '$result'"; fi

# Container jq: finds jails by user.warden.base_image
CONTAINER_JQ='.[] | select(.config["user.warden.base_image"] == $img) | "  " + .name + "   (" + .state.status + ")"'

result=$(echo "$CONTAINER_LIST_WITH_JAIL" | jq -r --arg img "python-ds" "$CONTAINER_JQ")
if echo "$result" | grep -q "my-jail"; then ok "T23 container jq: finds jail with matching base_image"
else fail "T23 container jq: 'my-jail' not found"; fi

result=$(echo "$CONTAINER_LIST_TWO_JAILS" | jq -r --arg img "python-ds" "$CONTAINER_JQ")
if echo "$result" | grep -q "ds-experiment-1" && ! echo "$result" | grep -q "other-jail"; then
  ok "T24 container jq: only matching jail returned"
else fail "T24 container jq: filter not working correctly"; fi

# Image existence check jq: returns count
ALIAS_JQ='[.[] | select(any(.aliases[]; .name == $a))] | length'
count=$(echo "$IMAGE_LIST_ONE_WARDEN" | jq --arg a "warden/python-ds" "$ALIAS_JQ")
if [ "$count" -eq 1 ]; then ok "T25 alias jq: existing alias → count 1"
else fail "T25 alias jq: expected 1, got $count"; fi

count=$(echo "$IMAGE_LIST_ONE_WARDEN" | jq --arg a "warden/missing" "$ALIAS_JQ")
if [ "$count" -eq 0 ]; then ok "T26 alias jq: missing alias → count 0"
else fail "T26 alias jq: expected 0, got $count"; fi

# Network wait loop jq: must break immediately with the right JSON
result=0
echo "$CONTAINER_LIST_WITH_JAIL" | jq -e '.[0].state.network.eth0.addresses | length > 0' >/dev/null || result=$?
if [ "$result" -eq 0 ]; then ok "T27 network jq: container-with-IP fixture satisfies break condition"
else fail "T27 network jq: break condition not met"; fi

result=0
echo "$CONTAINER_LIST_EMPTY" | jq -e '.[0].state.network.eth0.addresses | length > 0' >/dev/null || result=$?
if [ "$result" -ne 0 ]; then ok "T28 network jq: empty container list does NOT satisfy break condition"
else fail "T28 network jq: empty list should not satisfy break condition"; fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SECTION 3: cmd_images (with mock incus)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "3. cmd_images"
setup_mock

export MOCK_IMAGE_LIST="$IMAGE_LIST_EMPTY"
assert_contains "T29 images: empty → informational message"     "No warden-managed images"  "$WARDEN" images
assert_exit     "T30 images: empty → exit 0"                    0  "$WARDEN" images

export MOCK_IMAGE_LIST="$IMAGE_LIST_ONE_WARDEN"
assert_contains "T31 images: one image → name shown"            "python-ds"   "$WARDEN" images
assert_contains "T32 images: one image → saved_from shown"      "my-project"  "$WARDEN" images
assert_contains "T33 images: one image → fingerprint shown"     "abc123def456" "$WARDEN" images
assert_contains "T34 images: one image → GiB in size column"    "GiB"          "$WARDEN" images

export MOCK_IMAGE_LIST="$IMAGE_LIST_MIXED"
assert_contains     "T35 images: warden image shown"            "python-ds"   "$WARDEN" images
assert_not_contains "T36 images: non-warden image excluded"     "base-dev-v2" "$WARDEN" images

export MOCK_IMAGE_LIST="$IMAGE_LIST_TWO_WARDEN"
out=$("$WARDEN" images 2>&1)
if echo "$out" | grep -q "python-ds" && echo "$out" | grep -q "ml-base"; then
  ok "T37 images: two warden images both shown"
else fail "T37 images: not both images shown"; fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SECTION 4: cmd_image_info (with mock incus)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "4. cmd_image_info"

export MOCK_IMAGE_LIST="$IMAGE_LIST_EMPTY"
assert_exit     "T38 image-info: unknown image → exit 1"        1  "$WARDEN" image-info python-ds
assert_contains "T39 image-info: unknown image → error message" "not found"  "$WARDEN" image-info python-ds

export MOCK_IMAGE_LIST="$IMAGE_LIST_ONE_WARDEN"
export MOCK_CONTAINER_LIST="$CONTAINER_LIST_EMPTY"
assert_exit     "T40 image-info: known image → exit 0"          0  "$WARDEN" image-info python-ds
assert_contains "T41 image-info: shows fingerprint"             "abc123def456abc123def456abc123de" "$WARDEN" image-info python-ds
assert_contains "T42 image-info: shows saved_from"              "my-project"   "$WARDEN" image-info python-ds
assert_contains "T43 image-info: shows created date"            "2026-04-05"   "$WARDEN" image-info python-ds
assert_contains "T44 image-info: shows image name header"       "Image: python-ds" "$WARDEN" image-info python-ds
assert_contains "T45 image-info: no jails → (none)"             "(none)"       "$WARDEN" image-info python-ds

export MOCK_CONTAINER_LIST="$CONTAINER_LIST_WITH_JAIL"
assert_contains "T46 image-info: dependent jail shown"          "my-jail"      "$WARDEN" image-info python-ds
assert_not_contains "T47 image-info: (none) not shown when jail exists" "(none)" "$WARDEN" image-info python-ds

export MOCK_CONTAINER_LIST="$CONTAINER_LIST_TWO_JAILS"
assert_contains     "T48 image-info: shows matching jail"       "ds-experiment-1" "$WARDEN" image-info python-ds
assert_not_contains "T49 image-info: non-matching jail excluded" "other-jail"      "$WARDEN" image-info python-ds

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SECTION 5: cmd_delete_image (with mock incus)
# Note: [ -t 0 ] is false in all automated tests, so the TTY prompt is never
#       reached. The non-interactive path (no --yes) and the --yes path are both
#       tested here. The interactive TTY prompt is covered in integration_test.sh.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "5. cmd_delete_image"

export MOCK_IMAGE_LIST="$IMAGE_LIST_EMPTY"
export MOCK_CONTAINER_LIST="$CONTAINER_LIST_EMPTY"
assert_exit     "T50 delete-image: unknown image → exit 1"       1  "$WARDEN" delete-image python-ds
assert_contains "T51 delete-image: unknown image → error message" "not found"  "$WARDEN" delete-image python-ds

export MOCK_IMAGE_LIST="$IMAGE_LIST_ONE_WARDEN"
assert_exit     "T52 delete-image: non-interactive → exit 0"     0  "$WARDEN" delete-image python-ds
assert_contains "T53 delete-image: non-interactive → skip message" "Non-interactive mode" "$WARDEN" delete-image python-ds

# Verify incus image delete was NOT called (non-interactive path skips it)
reset_log
"$WARDEN" delete-image python-ds >/dev/null 2>&1 || true
assert_not_called "T54 delete-image: non-interactive → incus image delete NOT called" "^image delete"

# Dependent jail warning
export MOCK_CONTAINER_LIST="$CONTAINER_LIST_WITH_JAIL"
assert_contains "T55 delete-image: dependent jail → WARN shown" "[WARN]"    "$WARDEN" delete-image python-ds
assert_contains "T56 delete-image: dependent jail → jail name"  "my-jail"  "$WARDEN" delete-image python-ds

export MOCK_CONTAINER_LIST="$CONTAINER_LIST_EMPTY"
assert_not_contains "T57 delete-image: no jails → no WARN" "[WARN]" "$WARDEN" delete-image python-ds

# --- --yes flag: deletion proceeds without TTY ---
export MOCK_IMAGE_LIST="$IMAGE_LIST_ONE_WARDEN"
export MOCK_CONTAINER_LIST="$CONTAINER_LIST_EMPTY"

reset_log
"$WARDEN" delete-image --yes python-ds >/dev/null 2>&1 || true
# Must delete by fingerprint, NOT by alias (passing "warden/<name>" can be misinterpreted
# by incus as a remote reference, causing "sudo: warden: command not found").
_expected_fp=$(echo "$IMAGE_LIST_ONE_WARDEN" | jq -r '[.[] | select(any(.aliases[]; .name == "warden/python-ds"))] | .[0].fingerprint')
assert_called     "T92 delete-image --yes → incus image delete called with fingerprint" "^image delete ${_expected_fp}"
assert_not_called "T92b delete-image --yes → alias NOT passed to image delete"          "^image delete warden/"

assert_exit       "T93 delete-image --yes: known image → exit 0"          0  "$WARDEN" delete-image --yes python-ds
assert_not_contains "T94 delete-image --yes: no skip message"  "Non-interactive mode"  "$WARDEN" delete-image --yes python-ds

export MOCK_CONTAINER_LIST="$CONTAINER_LIST_WITH_JAIL"
assert_contains   "T95 delete-image --yes: dependent jails → WARN still shown"  "[WARN]"   "$WARDEN" delete-image --yes python-ds

export MOCK_IMAGE_LIST="$IMAGE_LIST_EMPTY"
assert_exit       "T96 delete-image --yes: unknown image → exit 1"        1  "$WARDEN" delete-image --yes no-such-image

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SECTION 6: cmd_save_image (with mock incus)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "6. cmd_save_image"

# --- error paths (no incus calls needed for arg validation) ---
assert_exit     "T58 save-image: no args → exit 1"                1  "$WARDEN" save-image
assert_exit     "T59 save-image: only jail name → exit 1"         1  "$WARDEN" save-image myjail

# --- unknown jail ---
export MOCK_JAIL_EXISTS=""
export MOCK_IMAGE_LIST="$IMAGE_LIST_EMPTY"
assert_exit     "T60 save-image: unknown jail → exit 1"           1  "$WARDEN" save-image no-such-jail test-img
assert_contains "T61 save-image: unknown jail → error message"    "not found"  "$WARDEN" save-image no-such-jail test-img

# --- image already exists ---
export MOCK_JAIL_EXISTS="my-jail"
export MOCK_JAIL_RUNNING=""
export MOCK_IMAGE_LIST="$IMAGE_LIST_ONE_WARDEN"  # already has warden/python-ds
assert_exit     "T62 save-image: alias exists → exit 1"           1  "$WARDEN" save-image my-jail python-ds
assert_contains "T63 save-image: alias exists → error message"    "already exists"  "$WARDEN" save-image my-jail python-ds

# --- stopped jail: happy path ---
export MOCK_IMAGE_LIST="$IMAGE_LIST_EMPTY"
export MOCK_JAIL_EXISTS="my-jail"
export MOCK_JAIL_RUNNING=""
unset MOCK_PUBLISH_FAIL 2>/dev/null || true

reset_log
"$WARDEN" save-image my-jail test-img >/dev/null 2>&1
assert_not_called "T64 save-image: stopped jail → stop NOT called"   "^stop"
assert_called     "T65 save-image: stopped jail → publish called"    "^publish my-jail"
assert_not_called "T66 save-image: stopped jail → start NOT called"  "^start"

assert_exit     "T67 save-image: stopped jail → exit 0"             0  "$WARDEN" save-image my-jail test-img
assert_contains "T68 save-image: stopped jail → SUCCESS message"    "[SUCCESS]"  "$WARDEN" save-image my-jail test-img
assert_contains "T69 save-image: stopped jail → fingerprint shown"  "abc123"     "$WARDEN" save-image my-jail test-img

# --- running jail: stop → publish → restart ---
export MOCK_JAIL_RUNNING="my-jail"

reset_log
"$WARDEN" save-image my-jail test-img >/dev/null 2>&1
assert_called "T70 save-image: running jail → stop called"   "^stop my-jail"
assert_called "T71 save-image: running jail → publish called" "^publish my-jail"
assert_called "T72 save-image: running jail → start called"  "^start my-jail"

# Verify order: stop must appear before publish, publish before start
stop_line=$(grep -n "^stop my-jail" "$MOCK_LOG" | cut -d: -f1 | head -1)
pub_line=$(grep -n "^publish my-jail" "$MOCK_LOG" | cut -d: -f1 | head -1)
start_line=$(grep -n "^start my-jail" "$MOCK_LOG" | cut -d: -f1 | head -1)

if [ -n "$stop_line" ] && [ -n "$pub_line" ] && [ "$stop_line" -lt "$pub_line" ]; then
  ok "T73 save-image: stop happens before publish"
else fail "T73 save-image: stop/publish order wrong (stop=$stop_line pub=$pub_line)"; fi

if [ -n "$pub_line" ] && [ -n "$start_line" ] && [ "$pub_line" -lt "$start_line" ]; then
  ok "T74 save-image: publish happens before restart"
else fail "T74 save-image: publish/start order wrong (pub=$pub_line start=$start_line)"; fi

# --- publish flags: alias and properties ---
reset_log
"$WARDEN" save-image my-jail test-img >/dev/null 2>&1
assert_called "T75 save-image: publish uses warden/ alias"        "publish my-jail.*--alias warden/test-img"
assert_called "T76 save-image: publish sets image_name property"  "user.warden.image_name=test-img"
assert_called "T77 save-image: publish sets saved_from property"  "user.warden.saved_from=my-jail"

# --- publish fails while jail was running: restart still attempted ---
export MOCK_PUBLISH_FAIL=1
export MOCK_JAIL_RUNNING="my-jail"

reset_log
"$WARDEN" save-image my-jail test-img >/dev/null 2>&1 || true  # expect exit 1
assert_called     "T78 save-image: publish fail → stop still called"    "^stop my-jail"
assert_called     "T79 save-image: publish fail → restart still attempted" "^start my-jail"
assert_exit       "T80 save-image: publish fail → exit 1"                1  "$WARDEN" save-image my-jail test-img
assert_contains   "T81 save-image: publish fail → error message"         "Failed to publish"  "$WARDEN" save-image my-jail test-img

unset MOCK_PUBLISH_FAIL

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SECTION 7: cmd_create --image (with mock incus)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "7. cmd_create --image"

# T82-T83 are pure argument validation (already tested in section 1 but
# duplicated here with mock in PATH for safety)
assert_exit     "T82 create --image: missing value → exit 1"     1  "$WARDEN" create myjail --image
assert_contains "T83 create --image: missing value → message"    "--image requires a value"  "$WARDEN" create myjail --image

# Unknown image → validation fails before incus init
export MOCK_IMAGE_LIST="$IMAGE_LIST_EMPTY"
export MOCK_JAIL_EXISTS=""
assert_exit     "T84 create --image: unknown image → exit 1"     1  "$WARDEN" create myjail --image no-such-image
assert_contains "T85 create --image: unknown image → error"      "not found"  "$WARDEN" create myjail --image no-such-image

# Known image → incus init called with warden/ alias
# Note: cmd_create proceeds through full container lifecycle, creating $HOME/jails/<name>
JAIL_NAME="${TEST_JAIL_PREFIX}-a"
export MOCK_IMAGE_LIST="$IMAGE_LIST_ONE_WARDEN"
export MOCK_JAIL_EXISTS=""
export MOCK_JAIL_RUNNING=""
export MOCK_CONTAINER_LIST="$CONTAINER_LIST_WITH_JAIL"  # breaks network wait loop

reset_log
"$WARDEN" create "$JAIL_NAME" --image python-ds </dev/null >/dev/null 2>&1 || true
assert_called "T86 create --image: incus init uses warden/ alias"          "^init warden/python-ds $JAIL_NAME"
assert_called "T87 create --image: config set records short name (not alias)" "user.warden.base_image python-ds"
assert_not_called "T88 create --image: config set does not record warden/ prefix" "user.warden.base_image warden/"

# Default create (no --image) → incus init uses BASE_IMAGE, config set uses base-dev-v2
JAIL_NAME="${TEST_JAIL_PREFIX}-b"
export MOCK_IMAGE_LIST="$IMAGE_LIST_EMPTY"

reset_log
"$WARDEN" create "$JAIL_NAME" </dev/null >/dev/null 2>&1 || true
assert_called     "T89 create: default → incus init uses base-dev-v2"        "^init base-dev-v2 $JAIL_NAME"
assert_called     "T90 create: default → config set records base-dev-v2"     "user.warden.base_image base-dev-v2"
assert_not_called "T91 create: default → image list NOT queried (no --image)" "^image list"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SECTION 8: cmd_create bare non-URL positional arg (regression for image-name-as-git-url bug)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
section "8. cmd_create bare non-URL positional arg"

export MOCK_IMAGE_LIST="$IMAGE_LIST_EMPTY"
export MOCK_JAIL_EXISTS=""

# T97: a bare word with no URL scheme must be rejected, not passed to git clone
assert_exit "T97 create: bare non-URL arg → exit 1" \
  1  "$WARDEN" create myjail not-a-url

# T98: error message should suggest --image, not expose a raw git error
assert_not_contains "T98 create: bare non-URL arg → no raw git error leaked" \
  "fatal: repository" "$WARDEN" create myjail not-a-url

# T99: the error output should hint at --image so the user knows what to do
assert_contains "T99 create: bare non-URL arg → suggests --image flag" \
  "--image" "$WARDEN" create myjail not-a-url

# T100: exact reproduction of the reported bug — image name without --image flag
assert_exit "T100 create: image-like name without --image → exit 1" \
  1  "$WARDEN" create myjail python-ds

assert_contains "T101 create: image-like name without --image → suggests --image flag" \
  "--image" "$WARDEN" create myjail python-ds

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Summary
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "══════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "══════════════════════════════════════════"

teardown_mock
[ "$FAIL" -eq 0 ]
