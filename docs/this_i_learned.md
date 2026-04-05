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

## `delete-image` interactive prompt cannot be driven by piped stdin

**Date:** 2026-04-05  
**Context:** Designing automated tests for `cmd_delete_image`.

The `[ -t 0 ]` check in `cmd_delete_image` tests whether stdin is a terminal.
When running as a subprocess (test harness, CI, `echo y | ./warden.sh ...`),
`[ -t 0 ]` is false even if you pipe `y` to stdin. The function takes the
non-interactive branch and returns without deleting anything.

The actual delete path requires a real TTY. In automated tests, this is handled
by `expect` (see `integration_test.sh IT-25`). The mock test suite only covers
the non-interactive path (T52–T54).
