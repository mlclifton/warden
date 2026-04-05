# Testing Strategy for warden.sh

## How do I know this works as expected?

Run the automated test suite:

```bash
bash tests/test_warden.sh
```

This takes a few seconds and requires only `bash` and `jq` — no live Incus
instance needed. A clean pass (96/96 at the time of writing) gives high
confidence in the argument parsing, error handling, jq data transformations, and
the key Incus interaction sequences (stop/publish/restart ordering, publish
failure recovery, config recording).

When you have a live Incus instance with `base-dev-v2` and `dev-profile`
available, also run:

```bash
bash tests/integration_test.sh
```

This exercises the full lifecycle against real Incus and is the definitive check
that the jq field names and `incus` output formats match our assumptions.

---

## Why two test scripts?

`warden.sh` has two distinct layers that need different testing approaches:

### Layer 1 — logic that can run offline

- Argument parsing and early exits
- jq expressions (data transformation)
- Control flow: which incus commands get called, in what order, with what arguments
- Error recovery: e.g. restart after failed publish

These are covered by **`tests/test_warden.sh`** using a mock `incus` binary.

### Layer 2 — behaviour that requires real Incus

- Whether `incus image list --format json` actually returns the field names our
  jq expects (the JSON schema is not formally specified)
- Whether `incus image info` output includes a `Fingerprint:` line parseable by
  our `awk` pattern
- Whether `incus publish` actually creates a queryable alias
- Whether container config keys survive the container lifecycle
- The interactive `delete-image` confirmation prompt (requires a TTY)

These are covered by **`tests/integration_test.sh`**, which skips automatically
if the prerequisites are absent.

---

## tests/test_warden.sh — structure and mechanics

### The mock `incus`

`setup_mock` writes a fake `incus` script to a temp directory and prepends that
directory to `PATH`. Every call that `warden.sh` makes to `incus` goes to the
mock instead of the real binary. The mock:

- Logs every call (`$*`) to `$MOCK_LOG` so tests can verify what was called and
  in what order
- Returns canned responses controlled by environment variables

**Environment variables that control mock behaviour:**

| Variable | Effect |
|---|---|
| `MOCK_JAIL_EXISTS` | Space-separated jail names that "exist" (`incus info` succeeds) |
| `MOCK_JAIL_RUNNING` | Space-separated jail names that are "running" (output includes `Status: RUNNING`) |
| `MOCK_IMAGE_LIST` | JSON string returned by `incus image list --format json` |
| `MOCK_CONTAINER_LIST` | JSON string returned by `incus list --format json` |
| `MOCK_PUBLISH_FAIL` | Non-empty → `incus publish` exits 1 |
| `MOCK_STOP_FAIL` | Non-empty → `incus stop` exits 1 |

Set these before running `"$WARDEN" <command>` in a test. Call `reset_log`
between tests that check `assert_called` / `assert_not_called`.

### The JSON fixtures

Inline variables hold realistic Incus JSON for the image list and container list:

| Variable | Contents |
|---|---|
| `IMAGE_LIST_EMPTY` | `[]` |
| `IMAGE_LIST_ONE_WARDEN` | One `warden/python-ds` image |
| `IMAGE_LIST_TWO_WARDEN` | Two warden images |
| `IMAGE_LIST_MIXED` | One warden image + one `base-dev-v2` (tests filtering) |
| `CONTAINER_LIST_WITH_JAIL` | One jail with `user.warden.base_image=python-ds` and an eth0 IP (breaks the network-wait loop immediately) |
| `CONTAINER_LIST_TWO_JAILS` | Two jails with different `base_image` values (tests filtering) |
| `CONTAINER_LIST_EMPTY` | `[]` |

### Assertion helpers

| Helper | Signature | What it checks |
|---|---|---|
| `assert_exit` | `desc expected_code cmd [args…]` | Exit code of a command |
| `assert_contains` | `desc needle cmd [args…]` | stdout+stderr contains `needle` (fixed string) |
| `assert_not_contains` | `desc needle cmd [args…]` | stdout+stderr does NOT contain `needle` |
| `assert_called` | `desc regex` | `$MOCK_LOG` has a line matching the extended regex |
| `assert_not_called` | `desc regex` | `$MOCK_LOG` has NO line matching the extended regex |

**Notes:**
- `assert_contains` / `assert_not_contains` capture both stdout and stderr
  (`2>&1`), so you can check error messages.
- Use `grep -qF -- "$needle"` style (the `--`) for needles that start with `-`
  or `--`, otherwise grep mistakes the needle for an option flag.
- `assert_called` / `assert_not_called` use extended regex, not fixed strings.
  Escape regex metacharacters if your pattern includes `.`, `*`, etc.

### Test sections

| Section | What's covered | incus mock? |
|---|---|---|
| 1. Argument validation | All early-exit paths before any incus call | No |
| 2. jq expressions | Data transforms invoked directly on fixture JSON | No |
| 3. `cmd_images` | Table output formatting, filtering | Yes |
| 4. `cmd_image_info` | Metadata display, jail list, "(none)" case | Yes |
| 5. `cmd_delete_image` | Non-interactive skip, `--yes` deletion, WARN logic | Yes |
| 6. `cmd_save_image` | All flow variants: stopped/running/fail | Yes |
| 7. `cmd_create --image` | Flag parsing, image validation, init alias, config key | Yes |

### Known gaps (covered only by integration_test.sh)

- **Real Incus JSON schema**: The jq fixture JSON was written by hand from the
  FRD spec. The jq tests confirm the expressions work against the fixtures, but
  do not confirm the fixtures match the actual `incus` output format.
- **`incus image info` output format**: The mock returns a hardcoded
  `Fingerprint: abc123...` line. Whether real Incus uses exactly that key name
  and spacing is only confirmed by the integration test.

---

## tests/integration_test.sh — structure

The script:

1. Checks prerequisites (`incus`, daemon reachable, `base-dev-v2`, `dev-profile`)
   and skips entirely if any are absent.
2. Uses a unique test prefix `warden-itest-$$` for all containers and images so
   it cannot collide with real resources.
3. Registers a `trap cleanup EXIT` that destroys all test resources whether the
   tests pass or fail.
4. Runs the full lifecycle: `create` → `save-image` → `images` → `image-info`
   → `create --image` → `delete-image --yes`.
5. No external tools beyond `bash`, `jq`, and `incus` are required.

---

## Adding new tests

### Adding a mock test

1. Find the right section in `tests/test_warden.sh`, or add a new section with
   `section "N. <name>"`.

2. Set the mock env vars your scenario needs:
   ```bash
   export MOCK_JAIL_EXISTS="my-jail"
   export MOCK_JAIL_RUNNING="my-jail"
   export MOCK_IMAGE_LIST="$IMAGE_LIST_EMPTY"
   ```

3. If you need to check which incus commands were called, call `reset_log`
   first, then run warden.sh, then use `assert_called` / `assert_not_called`:
   ```bash
   reset_log
   "$WARDEN" save-image my-jail test-img >/dev/null 2>&1 || true
   assert_called "stop called before publish" "^stop my-jail"
   ```

4. Pick a test number that continues the sequence (next available T-number).

5. Re-run `bash tests/test_warden.sh` and confirm the new test passes.

### Adding a jq test (Section 2)

If you change a jq expression in `warden.sh`, add a corresponding test in
Section 2 that runs the new expression directly against a fixture:

```bash
result=$(echo "$SOME_FIXTURE" | jq -r 'your expression here')
if [ "$result" = "expected value" ]; then ok "TN description"
else fail "TN description (got '$result')"; fi
```

This catches breakage even if the mock happens to mask an incorrect query.

### Adding a fixture

If you need a new JSON shape not covered by the existing fixtures, add it near
the top of the fixtures block. Use realistic field names — compare against the
existing fixtures for structure. The integration tests will tell you if the real
Incus format differs.

### Adding an integration test

Add assertions to `tests/integration_test.sh` in the relevant lifecycle section
(or a new section). Use the `IT-NN` numbering convention. Keep in mind:

- All resources must use `$PREFIX` in their names so cleanup works.
- Only test behaviour that genuinely requires live Incus. If it can be tested
  with the mock, it should be in `test_warden.sh` instead.

---

## What the tests do NOT cover

| Gap | Reason | Mitigation |
|---|---|---|
| `cmd_connect` | Opens an interactive SSH session | Manual test only |
| `cmd_destroy` directory prompt | `[ -t 0 ]` is false in tests; prompt skipped | Manual test; integration cleanup covers the non-interactive path |
| Password prompt in `cmd_create` | `[ -t 0 ]` is false in tests; prompt skipped | Manual test only |
| `delete-image` TTY prompt (no `--yes`) | `[ -t 0 ]` is false in tests | Covered by `integration_test.sh` IT-27/28; `--yes` path covers the deletion code itself |
| Network wait loop timeout (30s) | Mock returns IP immediately; timeout path not exercised | Acceptable — the loop logic is trivial |
| `cmd_doctor` | Inspects real system state | Run `./warden.sh doctor` manually |
| `cmd_fix_terminal` | Runs apt inside a container | Manual test only |
