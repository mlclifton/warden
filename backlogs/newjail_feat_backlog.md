# Backlog: Custom Jail Images Feature

**FRD:** [docs/newjail_image_frd.md](../docs/newjail_image_frd.md)  
**Status:** Awaiting FRD approval

**Scope:** Single-developer "configured starting points" — save a jail state as a named image, create new jails from it, manage the image inventory.

All tasks modify `warden.sh` only unless stated otherwise. Implement in order — later tasks depend on earlier ones.

---

## Tasks

### TASK-1: Parse `--image` flag in `cmd_create()`

**File:** `warden.sh` — `cmd_create()` function  
**What:** Add argument parsing so `create <name> [git_url] [--image <image-name>]` is accepted. The `--image` value should default to `$BASE_IMAGE` if omitted.  
**Acceptance:**
- `warden.sh create foo` uses `base-dev-v2` (unchanged behaviour)
- `warden.sh create foo https://github.com/x/y.git` still works
- `warden.sh create foo --image python-ds` sets image to `warden/python-ds`
- `warden.sh create foo https://... --image python-ds` handles both
- Error if `--image` value given but image `warden/<name>` does not exist in Incus
- `incus init` uses the resolved image name (either `$BASE_IMAGE` or `warden/<image-name>`)

---

### TASK-2: Record base image in container config after `create`

**File:** `warden.sh` — `cmd_create()`, after `incus init`  
**What:** After successfully initialising the container, run:
```bash
incus config set "$name" user.warden.base_image "$image_name"
```
where `$image_name` is the short name used (e.g. `base-dev-v2` or `python-ds`).  
**Acceptance:**
- `incus config get <jail> user.warden.base_image` returns the correct value for jails created with and without `--image`

---

### TASK-3: Implement `cmd_save_image()`

**File:** `warden.sh` — new function  
**What:** Implement `save-image <jail-name> <image-name>`:
1. Validate args (both required)
2. Check jail exists via `incus info`
3. Check `warden/<image-name>` alias does NOT already exist
4. If jail is RUNNING: stop it (record that it was running)
5. `incus publish <jail> --alias warden/<image-name> --property user.warden.image_name=<image-name> --property user.warden.saved_from=<jail>`
6. If jail was running: restart it
7. Log fingerprint on success  

**Error handling:** If publish fails, still attempt restart if jail was stopped; then exit 1.  
**Acceptance:**
- `warden.sh save-image my-project python-ds` creates alias `warden/python-ds` in `incus image list`
- Running jail is stopped and restarted around the publish
- Duplicate image name gives clear error

---

### TASK-4: Implement `cmd_images()`

**File:** `warden.sh` — new function  
**What:** Implement `images` (no args): list all Incus images whose aliases start with `warden/`. Display a formatted table:

```
NAME            FINGERPRINT   SIZE      CREATED              SAVED FROM
--------------  ------------  --------  -------------------  ----------
python-ds       abc123def456  1.2 GiB   2026-04-05 14:32     my-project
```

Use `incus image list --format json | jq` to filter and extract fields.  
**Acceptance:**
- Shows only warden-managed images (not `base-dev-v2` or other system images)
- Shows informational message when no warden images exist
- NAME column strips the `warden/` prefix

---

### TASK-5: Implement `cmd_image_info()`

**File:** `warden.sh` — new function  
**What:** Implement `image-info <image-name>`: display metadata for `warden/<image-name>` and list all current jails whose `user.warden.base_image` config matches `<image-name>`.

Output format:
```
Image: python-ds
  Fingerprint : abc123...
  Size        : 1.2 GiB
  Created     : 2026-04-05 14:32:00
  Saved from  : my-project

Jails created from this image:
  ds-experiment-1   (RUNNING)
  ds-experiment-2   (STOPPED)
```

If no jails use the image, print `  (none)`.  
**Acceptance:**
- Error if image does not exist
- Correctly lists jails regardless of their current state

---

### TASK-6: Implement `cmd_delete_image()`

**File:** `warden.sh` — new function  
**What:** Implement `delete-image <image-name>`:
1. Validate arg
2. Check image exists
3. Query jails that used this image (same logic as `image-info`)
4. If any jails found: print a warning listing them
5. Prompt `Delete image '<name>'? [y/N]` (respect non-interactive mode: skip and log)
6. On confirmation: `incus image delete warden/<image-name>`  

**Acceptance:**
- Image is gone from `incus image list` after deletion
- Warning shown but not blocking when dependent jails exist
- Non-interactive mode skips prompt and logs that deletion was skipped

---

### TASK-7: Update `usage()` and dispatch

**File:** `warden.sh` — `usage()` function and `case` block  
**What:**
- Update `create` usage line to: `create <name> [git_url] [--image <image>]   Create a new dev environment`
- Add four new lines to usage:
  ```
  save-image <jail> <name>  Save a jail's state as a named image
  images                    List all warden-managed images
  image-info <name>         Show image details and which jails use it
  delete-image <name>       Delete a warden-managed image
  ```
- Add `case` branches: `save-image`, `images`, `image-info`, `delete-image`

**Acceptance:**
- `warden.sh` with no args shows all new commands
- All new commands are routable via the dispatcher

---

### TASK-8: Lint and format

**What:** Run `shellcheck warden.sh` and `shfmt -w warden.sh` and fix any issues.  
**Acceptance:**
- `shellcheck warden.sh` exits 0
- `shfmt -w warden.sh` produces no diff after running

---

### TASK-9: Update documentation

**Files:** `docs/user_guide.md`, `README.md`  
**What:**
- Add a section to `docs/user_guide.md` documenting each new command with usage, description, and an example (follow the existing per-command format).
- Update the command reference table in `README.md` to include the four new commands.

**Acceptance:**
- All new commands appear in user-facing docs with accurate syntax and examples
