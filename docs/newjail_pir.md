# PIR: Custom Jail Images Feature

**Date:** 2026-04-05  
**Feature:** Custom jail images (`save-image`, `images`, `image-info`, `delete-image`, `create --image`)  
**Spec:** [docs/newjail_image_frd.md](newjail_image_frd.md)  
**Backlog:** [backlogs/newjail_feat_backlog.md](../backlogs/newjail_feat_backlog.md)  
**Status:** Complete

---

## What Was Built

Four new commands and one modified command in `warden.sh`, adding the ability to snapshot a jail as a named image and use it as the starting point for future jails.

### Commands added

| Command | What it does |
|---|---|
| `save-image <jail> <name>` | Stops the jail if running, publishes it as an Incus image with alias `warden/<name>`, restarts, reports fingerprint |
| `images` | Lists all Incus images whose alias starts with `warden/` in a formatted table |
| `image-info <name>` | Shows metadata for a warden image and lists all jails with `user.warden.base_image == <name>` |
| `delete-image <name>` | Warns about dependent jails, prompts interactively, deletes the image |

### `create` modified

Added `--image <name>` flag. When given, validates `warden/<name>` exists, then passes it to `incus init` in place of `$BASE_IMAGE`. After init, records `incus config set <jail> user.warden.base_image <image-name>` regardless of whether `--image` was used (default `base-dev-v2` is recorded too).

### Design decisions made during implementation

The FRD was complete and unambiguous. No design decisions were escalated. One implementation choice worth noting: `cmd_image_info` calls `incus image list --format json` twice (once for the existence check, once to extract data). This is slightly inefficient but keeps the code simple and stateless, consistent with the rest of the script.

### Files changed

| File | What changed |
|---|---|
| `warden.sh` | Added `log_warn`, 4 new `cmd_*` functions, modified `cmd_create`, updated `usage()` and `case` dispatch |
| `docs/user_guide.md` | Updated `create` docs; added sections for all 4 new commands |
| `README.md` | Updated command reference table |
| `backlogs/newjail_feat_backlog.md` | All 9 tasks marked done |

---

## Bugs Found During Implementation

Two bugs were caught by the test suite that would have reached production undetected.

### Bug 1: `shift` exits non-zero under `set -e` when called with zero args

**Where:** `cmd_create()`, after the refactor to parse `--image`.

**What happened:** The original `cmd_create` took `$1` and `$2` as positional
locals. The rewrite needed a `while` loop over remaining args, so it added
`local name=$1; shift` at the top. When `warden.sh create` is called with no
arguments, `shift` with `$#=0` exits non-zero. Under `set -e`, the script exits
silently at that point — before reaching the `[ -z "$name" ]` check that would
print "Project name required."

**Symptom:** `./warden.sh create` exited 1 but produced no output.

**Fix:** Check `$name` before shifting:
```bash
local name=${1:-}
if [ -z "$name" ]; then ...exit 1...; fi
shift
```

**Lesson:** In a `set -e` script, any reorganisation of argument handling that
moves `shift` earlier in a function is a silent failure risk if the function can
be called with fewer args than expected.

### Bug 2: `grep -qF` treats a needle starting with `--` as an option flag

**Where:** The `assert_contains` helper in `tests/test_warden.sh`.

**What happened:** The needle `"--image requires a value"` was passed to
`grep -qF "$needle"`. Even with `-F` (fixed-string mode), grep parsed
`--image requires a value` as a long option name and threw an error.

**Fix:** `grep -qF -- "$needle"` (double-dash terminates option processing).

**Lesson:** Always use `--` before the pattern argument in any grep call where
the pattern is a variable, especially in test code where patterns are often
error messages that include CLI flags.

Both bugs are documented in detail in [docs/this_i_learned.md](this_i_learned.md).

---

## Testing Strategy

Full details in [docs/test_strategy.md](test_strategy.md). Summary:

### Two-layer approach

`warden.sh` mixes pure shell logic with calls to external programs (`incus`, `jq`). These need different testing strategies:

**Layer 1 — offline, automated (`tests/test_warden.sh`, 91 tests):**  
A fake `incus` binary is written to a temp directory and prepended to `PATH`. Behaviour is controlled by environment variables (`MOCK_JAIL_EXISTS`, `MOCK_IMAGE_LIST`, `MOCK_PUBLISH_FAIL`, etc.). All calls are logged so tests can assert not just exit codes and output but also *which incus commands were called in what order*.

Sections:
1. Argument validation (no mock needed — exits before any incus call)
2. jq expressions tested directly against fixture JSON
3–7. Each new command tested with mock incus

**Layer 2 — live Incus (`tests/integration_test.sh`, 28 tests):**  
Exercises the full lifecycle against real Incus. Skips gracefully if prerequisites are absent. Uses `expect` for the interactive `delete-image` prompt. Cleans up all resources via `trap … EXIT`.

### What the tests confirmed

- All argument validation and error paths exit with the right code and message
- jq field names (`aliases[].name`, `fingerprint`, `size`, `created_at`, `properties["user.warden.saved_from"]`, `config["user.warden.base_image"]`, `state.status`) match the fixture JSON and produce correct output
- `save-image` stops before publishing and restarts after, in the right order, even when publish fails
- `create --image` passes `warden/<name>` to `incus init` and records the short name (not the alias) in `user.warden.base_image`
- `delete-image` never calls `incus image delete` in non-interactive mode

### What the tests do not cover

- **Interactive prompts** (`delete-image` confirmation, `create` password prompt, `destroy` directory prompt) — requires a TTY; integration test uses `expect` for `delete-image`
- **Real Incus JSON schema** — jq tests confirm expressions work against hand-written fixtures, not against actual `incus` output
- `connect`, `doctor`, `fix-terminal` — not part of this feature

---

## What Went Well

**The FRD was implementation-ready.** The "FEATURE STARTING CONTEXT" section in the FRD listed exact Incus commands, jq queries, key variable names, and where to add code. Implementation could start immediately without any research or clarifying questions.

**The two-layer testing approach caught real bugs.** Both bugs found during this work were caught by the automated test suite, not by manual testing. The mock-log approach (logging all incus calls to a file and asserting on the log) was especially effective at catching the `shift` bug, which produced no output — a silent failure that manual testing might have missed.

**`|| publish_ok=false` correctly shields `set -e`.** The error recovery in `save-image` (restart the jail even if publish fails) required careful handling of `set -e`. The pattern worked correctly and was verified by tests T78–T81.

**Namespace design is clean.** Using `warden/` as an Incus alias prefix keeps warden images completely separate from system images. No risk of collision with `base-dev-v2` or any other image, and filtering is a single `startswith("warden/")` check.

---

## What Could Have Gone Better

**The `shift` bug was an own-goal.** It was introduced by the rewrite of `cmd_create`'s argument handling and is exactly the kind of subtle `set -e` interaction that's easy to miss in code review. The fix is simple but the pattern (`local name=${1:-}` before shifting) should be the default approach whenever a function can be called with optional args.

**`cmd_image_info` calls `incus image list` twice.** The existence check and the data extraction are separate calls. A single call with the result stored in a variable would be cleaner and avoid the redundant invocation. This was a minor convenience trade-off that is fine at this scale but worth noting.

**`delete-image` is untestable without `expect`.** The `[ -t 0 ]` guard is correct behaviour (you don't want automated scripts accidentally deleting images), but it means the critical deletion code path — the `incus image delete` call itself — cannot be reached without a TTY or `expect`. Future confirmation-prompt implementations might consider an explicit `--yes` / `-y` flag for scriptability, which would be fully testable.

**No pre-flight check for jq availability.** The new commands depend heavily on `jq`. `cmd_doctor` does not check for `jq`, though it is listed as a dependency in `CLAUDE.md`. Not a blocker (jq was already a pre-existing dependency), but worth flagging.

---

## Start / Stop / Continue

### Start

**Start validating input args before calling `shift`.** Any function that does
`shift` to consume a positional arg must validate that arg first:
```bash
local name=${1:-}
if [ -z "$name" ]; then ...; fi
shift
```
This pattern prevents the silent `set -e` exit when a function is called with
fewer args than expected.

**Start writing the test harness alongside the implementation, not after.**
The mock and fixture approach was designed retrospectively after the feature was
coded. Had the fixtures been written first (or in parallel), the `shift` bug
would have been caught before the implementation was complete rather than in a
separate testing pass.

**Start using `grep -qF -- "$needle"` everywhere in test helpers.** The `--`
is cheap insurance against needles that contain flag-like strings. Make it the
default in any test helper that passes a variable to grep.

**Start adding `--yes` / `-y` flags to interactive confirmation prompts.**
`[ -t 0 ]` guards are correct for safety, but they make the confirmation branch
untestable without `expect`. A `--yes` flag would allow automated tests to
exercise the actual deletion/destruction code path directly.

### Stop

**Stop calling `incus image list --format json` twice in the same function.**
`cmd_image_info` and `cmd_delete_image` each call `incus list` twice in a row.
Cache the result in a local variable:
```bash
local image_json
image_json=$(incus image list --format json)
```
Then pipe `$image_json` into subsequent `jq` calls. Reduces latency and makes
it obvious the data is from a single consistent snapshot.

**Stop assuming `set -e` is "safe".** `set -e` provides a false sense of
security: it catches some failures (unexpected non-zero exit) but causes others
(silent exit before intended error handling). Every function should be read with
`set -e` semantics explicitly in mind, particularly around `shift`, pipes, and
subshell substitutions.

### Continue

**Continue the two-layer testing strategy (mock + integration).** It correctly
separates concerns: the mock tests prove the logic, the integration tests prove
the assumptions about external tools. The 91-test automated suite runs in
seconds and is the primary safety net. Keep this pattern for any future
commands.

**Continue the mock-log approach for asserting incus call sequences.** Logging
`$*` to a file and grepping for ordered line numbers is simple and effective.
It caught ordering issues (stop before publish, publish before restart) that
output-only assertions would have missed.

**Continue the FRD "FEATURE STARTING CONTEXT" section convention.** Having exact
Incus commands, jq queries, and code placement guidance in the spec document
made implementation fast and unambiguous. This section should be a required part
of any future FRD for features that touch external tools.

**Continue recording unexpected findings in `docs/this_i_learned.md`** as
implementation progresses. It keeps institutional knowledge close to the code
and provides the raw material for future PIRs.

---

## Addendum: `delete-image --yes` flag (2026-04-05)

**What changed:** `delete-image` gained a `--yes` / `-y` flag that bypasses the
interactive confirmation prompt without altering the safe default behaviour.

**Why it was needed:** Post-implementation integration testing revealed that
IT-25 and IT-26 — which exercise the actual `incus image delete` code path —
were being skipped whenever `expect` was not installed. The original design used
`[ -t 0 ]` to gate the prompt (correct for safety) and `expect` to drive the TTY
in tests. But `expect` is not universally available and is a heavyweight
dependency for a single code path.

**Design:** `--yes` skips the prompt; it does not skip the warning about
dependent jails. The safe default (skip-with-message in non-interactive mode)
is unchanged for callers that do not pass `--yes`.

**Test impact:**
- Mock suite: 5 new tests (T92–T96) covering the `--yes` path, unknown-image
  guard, and that warnings still appear with `--yes`.
- Integration suite: IT-25 and IT-26 now use `--yes` directly; the `expect`
  block and its skip fallback are removed. No external tools beyond `incus` are
  required to run the full integration suite.
- Total: 91 → 96 mock tests; 28/28 integration tests with 0 skipped.

**Lesson reinforced:** Any confirmation-guarded command that is also meant to be
scriptable should have `--yes` from the start. See `docs/this_i_learned.md` for
the full note.
