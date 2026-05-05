# Backlog: CLI Command Refinement

**Status:** Completed (2026-05-05)

**Scope:** Rework the warden.sh command-line interface to be more intuitive and self-consistent:
- Use unified lifecycle commands (`start`, `stop`, `info`, `delete`)
- Group image operations under an `image` subcommand (`image save`, `image list`, `image info`, `image delete`)
- Rename `--image` to `--from` for clearer semantics
- Add `--yes` flag to `delete`
- Maintain **full backward compatibility** — old command forms continue to work so existing tests pass without modification

---

## Tasks

### TASK-1: Add new jail lifecycle commands (`start`, `stop`, `info`) ✓ DONE

**File:** `warden.sh`

**What:** Implement three new commands using existing incus primitives:

- `start <name>` — Start a stopped jail via `incus start`. Error if name missing or jail not found.
- `stop <name>` — Stop a running jail via `incus stop`. Error if name missing or jail not found.
- `info <name>` — Show jail details: name, state, IP, base image, project directory. Query via `incus info`, `incus config get`, and `incus list`.

**Acceptance:**
- `warden.sh start myjail` starts the container.
- `warden.sh stop myjail` stops the container.
- `warden.sh info myjail` prints formatted details.
- Missing name or unknown jail → exit 1 with clear error.

---

### TASK-2: Rename `destroy` → `delete` and add `--yes` flag ✓ DONE

**File:** `warden.sh` — `cmd_destroy()` (will be renamed `cmd_delete`)

**What:**
- Rename the function internally to `cmd_delete` for consistency.
- Add `--yes` / `-y` flag parsing so scripts can skip the interactive prompt.
- Keep `destroy` as a backward-compatible alias (same function, no behavioural change).

**Backward compat:** `warden.sh destroy myjail` must continue to work exactly as before.

**Acceptance:**
- `warden.sh delete myjail` prompts for confirmation (TTY) or warns and skips (non-TTY).
- `warden.sh delete myjail --yes` deletes without prompting.
- `warden.sh destroy myjail` still works (tested by existing test suite behaviour).

---

### TASK-3: Add `image` subcommand namespace ✓ DONE

**File:** `warden.sh` — dispatcher and new helper

**What:** Add a new top-level `image` command that accepts subcommands, mirroring the existing image operations:

| Old form | New form |
|---|---|
| `save-image <jail> <name>` | `image save <jail> <name>` |
| `images` | `image list` |
| `image-info <name>` | `image info <name>` |
| `delete-image <name> [--yes]` | `image delete <name> [--yes]` |

The old flat commands must remain functional (backward compatibility).

**Implementation:**
- Add a `cmd_image()` dispatcher that routes `save|list|info|delete` to the existing functions.
- Add `case` entries for both old and new forms.

**Acceptance:**
- All four new `image <subcommand>` forms work.
- All four old flat forms still work (existing tests pass unchanged).

---

### TASK-4: Rename `--image` → `--from` in `create` (keep `--image` as alias) ✓ DONE

**File:** `warden.sh` — `cmd_create()`

**What:**
- Accept `--from <name>` as the preferred flag for specifying a custom image.
- Keep `--image <name>` working as a backward-compatible alias.
- Update `usage()` to show `--from` while still describing `--image`.

**Backward compat:** Existing tests use `--image`; they must still pass.

**Acceptance:**
- `warden.sh create foo --from python-ds` resolves to `warden/python-ds`.
- `warden.sh create foo --image python-ds` still works.
- Error messages and help text reference `--from` first.

---

### TASK-5: Update `usage()` text ✓ DONE

**File:** `warden.sh`

**What:** Rewrite `usage()` to reflect the refined command set. Group commands by category (Jail, Image, Utility). Keep descriptions concise.

**Acceptance:**
- Running `warden.sh` with no args shows the new usage layout.
- All commands (new and legacy) are listed.

---

### TASK-6: Update `README.md` command reference ✓ DONE

**File:** `README.md`

**What:** Update the command reference table to show the new syntax. Mention legacy forms where they differ.

**Acceptance:**
- README reflects the refined CLI.
- No stale references to removed commands.

---

### TASK-7: Update `docs/user_guide.md` ✓ DONE

**File:** `docs/user_guide.md`

**What:** Update each command section to document the new syntax. Add new sections for `start`, `stop`, `info`, and `image` subcommands. Keep backward-compatibility notes minimal.

**Acceptance:**
- User guide is internally consistent with the new CLI.
- All examples use the new preferred syntax.

---

### TASK-8: Run tests and verify backward compatibility ✓ DONE

**Files:** `tests/test_warden.sh`, `tests/integration_test.sh`

**What:** Execute both test suites. No test file modifications are permitted.

**Acceptance:**
- `bash tests/test_warden.sh` passes (0 failures).
- `bash tests/integration_test.sh` passes (0 failures) — if prerequisites are met.
- `shellcheck warden.sh` exits 0.

---

## Backward Compatibility Summary

| Legacy command | Maps to | Status |
|---|---|---|
| `destroy <name>` | `delete <name>` | Alias preserved |
| `save-image <jail> <name>` | `image save <jail> <name>` | Alias preserved |
| `images` | `image list` | Alias preserved |
| `image-info <name>` | `image info <name>` | Alias preserved |
| `delete-image <name> [--yes]` | `image delete <name> [--yes]` | Alias preserved |
| `create … --image <name>` | `create … --from <name>` | `--image` still accepted |
