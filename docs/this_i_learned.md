# This I Learned

Notes on things that didn't work as expected during development.

---

## `shift` with zero args exits non-zero under `set -e`

**Date:** 2026-04-05  
**Context:** Implementing `cmd_create()` with argument parsing.

I rewrote `cmd_create` to do `local name=$1; shift` at the top so remaining args
could be parsed in a `while` loop. This introduced a bug: when `warden.sh create`
is called with no arguments, `$#` is 0 inside `cmd_create`, and `shift` (i.e.
`shift 1`) returns non-zero. With `set -e` active, the script exits silently at
that point — before the `[ -z "$name" ]` guard that would print the useful error.

**Fix:** Check for the empty name *before* shifting:

```bash
cmd_create() {
  local name=${1:-}
  if [ -z "$name" ]; then
    log_error "Project name required."
    usage
    exit 1
  fi
  shift
  ...
}
```

Discovered by the test suite (T05 failed: empty output when error message expected).

---

## `grep -qF "$needle"` treats needle starting with `--` as an option

**Date:** 2026-04-05  
**Context:** Writing test harness `assert_contains` helper.

When the search needle starts with `--` (e.g. `"--image requires a value"`),
`grep -qF "$needle"` fails with `grep: unrecognized option '--image ...'`. Even
with `-F` (fixed-string mode), grep still processes leading `--foo` as a long
option before seeing the pattern.

**Fix:** Use `--` to terminate option processing: `grep -qF -- "$needle"`.

This matters whenever test needles are user-facing error strings that include
flag names like `--image`.

---

## `[ -t 0 ]` guards make deletion paths untestable without a TTY — use `--yes` instead

**Date:** 2026-04-05  
**Context:** Designing automated tests for `cmd_delete_image`.

The `[ -t 0 ]` check in `cmd_delete_image` tests whether stdin is a terminal.
When running as a subprocess (test harness, CI, `echo y | ./warden.sh ...`),
`[ -t 0 ]` is false even if you pipe `y` to stdin. The function takes the
non-interactive branch and returns without deleting anything — which means the
actual `incus image delete` call is never reached by any automated test.

The integration test initially worked around this with `expect` to drive a real
TTY, but `expect` is not universally installed and adds an external dependency
for a single test path.

**Fix:** Add a `--yes` flag that bypasses the prompt without changing the safe
default behaviour:
- Without `--yes`: unchanged (prompt when TTY, skip-with-message when not)
- With `--yes`: skip the prompt and proceed directly to deletion

The deletion code path is now reachable in the mock suite (T92–T96) and the
integration suite (IT-25–IT-26) with no `expect` dependency.

**Lesson:** For any command that has a `[ -t 0 ]` confirmation guard and is
also meant to be scriptable, add `--yes`/`-y` from the start. The guard is
correct for interactive safety; `--yes` is the intended escape hatch for scripts
and tests. Relying on `expect` to test TTY-gated paths is fragile — it moves an
external tool requirement into the test suite unnecessarily.
