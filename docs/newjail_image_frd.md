# FRD: Custom Jail Images for `warden.sh`

**Status:** Draft  
**Date:** 2026-04-05

---

## Overview

Currently `warden.sh create` always clones new jails from a single fixed base image (`base-dev-v2`). This feature allows users to snapshot the current state of any jail, give that snapshot a named alias, and use it as the starting point for future jails.

## Motivation

**Configured starting points.** A user installs project-specific dependencies (language runtimes, build tools, AI tool configuration) into a jail, saves the image, then stamps out further jails from that image without repeating the setup work.

---

## User Stories

| ID | As a... | I want to... | So that... |
|----|---------|-------------|-----------|
| US-1 | developer | save a jail's current state as a named image | I can reuse a configured environment |
| US-2 | developer | create a new jail from a named image | I get a pre-configured environment without manual setup |
| US-3 | developer | list all available warden-managed images | I know what starting points are available |
| US-4 | developer | view details about a specific image | I understand what it contains and which jails use it |
| US-5 | developer | delete a warden image I no longer need | I free up storage and keep the image list clean |

---

## Command Specification

### Modified: `create`

```
warden.sh create <name> [git_url] [--image <image-name>]
```

- Adds an optional `--image <image-name>` flag.
- If `--image` is omitted, behaviour is identical to today (uses `BASE_IMAGE = base-dev-v2`).
- If `--image` is provided, the named warden image is used instead of `BASE_IMAGE`.
- Error if the named image does not exist.
- The image name used is recorded in the container's metadata (`user.warden.base_image`) so it can be queried later.

**Examples:**
```bash
warden.sh create my-project                                    # uses base-dev-v2 (unchanged)
warden.sh create my-project https://github.com/x/y.git        # unchanged
warden.sh create my-project --image python-ds                  # uses custom image
warden.sh create my-project https://github.com/x/y.git --image python-ds
```

---

### New: `save-image`

```
warden.sh save-image <jail-name> <image-name>
```

Publishes the current state of `<jail-name>` as a new Incus image with the warden-managed alias `warden/<image-name>`. If the jail is running it will be stopped temporarily for a consistent snapshot, then restarted.

- Errors if `<jail-name>` does not exist.
- Errors if `warden/<image-name>` already exists (use `delete-image` first).
- Stores a warden metadata property on the image: `user.warden.saved_from=<jail-name>` and `user.warden.image_name=<image-name>`.
- Reports the Incus image fingerprint on success.

**Example:**
```bash
warden.sh save-image my-project python-ds
# [INFO] Stopping my-project for consistent snapshot...
# [INFO] Publishing image 'python-ds'...
# [INFO] Restarting my-project...
# [SUCCESS] Image 'python-ds' saved (fingerprint: abc123).
```

---

### New: `images`

```
warden.sh images
```

Lists all warden-managed images (those with the `warden/` alias prefix). Displays:

| Column | Source |
|--------|--------|
| NAME | alias after `warden/` prefix |
| FINGERPRINT | first 12 chars of image fingerprint |
| SIZE | image size |
| CREATED | creation timestamp |
| DESCRIPTION | `user.warden.saved_from` property |

**Example output:**
```
NAME            FINGERPRINT   SIZE     CREATED              SAVED FROM
--------------  ------------  -------  -------------------  ----------
python-ds       abc123def456  1.2 GiB  2026-04-05 14:32     my-project
ml-base         beef00112233  2.1 GiB  2026-04-01 09:10     ml-sandbox
```

If no warden images exist, prints an informational message.

---

### New: `image-info`

```
warden.sh image-info <image-name>
```

Displays full details about a warden image, including which currently-existing jails were created from it.

**Output sections:**
1. **Image metadata:** fingerprint, size, creation date, saved-from jail.
2. **Jails using this image:** list of jail names where `user.warden.base_image == image-name`.

**Example output:**
```
Image: python-ds
  Fingerprint : abc123def456abc123def456
  Size        : 1.2 GiB
  Created     : 2026-04-05 14:32:00
  Saved from  : my-project

Jails created from this image:
  ds-experiment-1   (RUNNING)
  ds-experiment-2   (STOPPED)
```

Error if the image does not exist.

---

### New: `delete-image`

```
warden.sh delete-image <image-name>
```

Removes the warden-managed image alias and the underlying Incus image (if no other aliases point to it).

- Prompts for confirmation before deleting.
- Warns (but does not block) if existing jails were created from this image — those jails remain functional, they just lose the ability to be traced back to a named image.
- Error if the image does not exist.

**Example:**
```bash
warden.sh delete-image python-ds
# [WARN] 2 jail(s) were created from 'python-ds' (ds-experiment-1, ds-experiment-2).
#        Deleting this image will not affect those jails.
# Delete image 'python-ds'? [y/N] y
# [SUCCESS] Image 'python-ds' deleted.
```

---

## Technical Design

### Incus Image Aliases (Namespace)

All warden-managed custom images use the alias prefix `warden/`. This separates them cleanly from the default `base-dev-v2` image and any other images on the system.

| User-facing name | Incus alias |
|-----------------|-------------|
| `python-ds` | `warden/python-ds` |
| `ml-base` | `warden/ml-base` |

The default `base-dev-v2` image is **not** in the `warden/` namespace and is left unchanged.

### Image Metadata

Warden stores metadata in Incus image properties at publish time. These are set via `incus image edit` or by passing `--property` during `incus publish`. The relevant properties are:

| Property | Value | Purpose |
|----------|-------|---------|
| `user.warden.image_name` | e.g. `python-ds` | Machine-readable name |
| `user.warden.saved_from` | e.g. `my-project` | Provenance: which jail it came from |

### Container Metadata

When `create` uses a named image, the jail records it:

```bash
incus config set <jail-name> user.warden.base_image <image-name>
```

This config key is queried by `image-info` to find all jails linked to an image.

### Publishing Flow (`save-image`)

```
1. Verify jail exists (incus info)
2. Check warden/<image-name> alias does not already exist
3. If jail is RUNNING: incus stop <jail-name>  [remember to restart later]
4. incus publish <jail-name> --alias warden/<image-name> \
       --property user.warden.image_name=<image-name> \
       --property user.warden.saved_from=<jail-name>
5. If jail was RUNNING before step 3: incus start <jail-name>
6. Report success with fingerprint
```

### Querying Warden Images (`images` command)

```bash
incus image list --format json | jq '[.[] | select(.aliases[].name | startswith("warden/"))]'
```

Extract the user-facing name by stripping the `warden/` prefix from the alias.

### Querying Jail Provenance (`image-info`)

```bash
incus list --format json | jq --arg img "python-ds" \
  '[.[] | select(.config["user.warden.base_image"] == $img) | {name: .name, status: .state.status}]'
```

---

## Error Handling

| Scenario | Behaviour |
|----------|-----------|
| `create --image` with unknown image | `log_error` + exit 1 |
| `save-image` with unknown jail | `log_error` + exit 1 |
| `save-image` with already-existing image name | `log_error` + exit 1 |
| `image-info` with unknown image | `log_error` + exit 1 |
| `delete-image` with unknown image | `log_error` + exit 1 |
| `save-image` jail stops fail | `log_error` + exit 1 (no publish attempted) |
| `save-image` publish fails | `log_error` + attempt restart if jail was stopped; exit 1 |

---

## `usage()` Updates

The help text shown by `warden.sh` with no arguments must be updated to include all new commands:

```
  save-image <jail> <name>  Save a jail's state as a named image
  images                    List all warden-managed images
  image-info <name>         Show image details and which jails use it
  delete-image <name>       Delete a warden-managed image
```

And the `create` usage line updated to:

```
  create <name> [git_url] [--image <image>]   Create a new dev environment
```

---

## Out of Scope

- Exporting/importing images to/from external registries or other hosts.
- Modifying the `base-dev-v2` default image — that remains managed by `setup_incus.sh`.
- Interactive resource configuration during `create` (a separate PRD item from `warden_prd.md`).

---

## FEATURE STARTING CONTEXT

This section provides all context a coding agent needs to implement this feature with an empty conversation context.

### What Warden Is

`warden.sh` is a single-file Bash CLI (`/home/mike/src/warden/warden.sh`) that wraps Incus to manage isolated AI coding sandboxes ("jails"). Key commands: `create`, `connect`, `destroy`, `list`, `doctor`, `fix-terminal`. Each command is implemented as a `cmd_<name>()` function dispatched by a `case` statement at the bottom of the file.

### Relevant Files

| File | Purpose |
|------|---------|
| `warden.sh` | Main CLI — the only file that needs modification |
| `CLAUDE.md` | Coding standards and architecture notes for AI agents |
| `docs/newjail_image_frd.md` | **This document** — full feature specification |
| `docs/user_guide.md` | End-user documentation (update after implementation) |
| `README.md` | Project overview with command table (update after implementation) |
| `docs/incus_on_this_machine.md` | System-specific Incus facts (read for context, no changes needed) |

### Coding Standards (from `CLAUDE.md` and `README.md`)

- Language: `#!/bin/bash`, `set -e` at top
- Indentation: 2 spaces (match existing file style)
- Variables: double-quoted `"$var"`, `${var}` for clarity
- Logging: use existing `log_info`, `log_success`, `log_error` functions
- Lint: `shellcheck *.sh` and `shfmt -w *.sh` must pass

### Key Incus Commands for This Feature

```bash
# Publish a container as an image with an alias and properties
incus publish <jail-name> --alias warden/<image-name> \
    --property user.warden.image_name=<image-name> \
    --property user.warden.saved_from=<jail-name>

# List images as JSON (filter to warden/ aliases)
incus image list --format json

# Delete an image by alias
incus image delete warden/<image-name>

# Get info about an image
incus image info warden/<image-name>

# Set container config (tracks which image a jail was built from)
incus config set <jail-name> user.warden.base_image <image-name>

# Query all jails for their base_image config
incus list --format json
```

### Architecture Decisions for This Feature

1. **Alias namespace:** All warden custom images use the `warden/` alias prefix in Incus. Users refer to images by the short name (without `warden/`).
2. **Default unchanged:** The existing `BASE_IMAGE="base-dev-v2"` variable and its behaviour are not modified.
3. **Image selection in `create`:** Added as `--image <name>` flag parsed before positional args; the selected image name (or `base-dev-v2` for default) is recorded in `incus config set <jail> user.warden.base_image`.
4. **Provenance tracking:** Done entirely via Incus config/properties — no external state files.
5. **Consistent snapshots:** `save-image` stops a running jail before publishing, then restarts it.

### Where to Add Code in `warden.sh`

- Add `cmd_save_image()`, `cmd_images()`, `cmd_image_info()`, `cmd_delete_image()` functions (follow existing `cmd_*` pattern).
- Modify `cmd_create()` to parse `--image` flag and call `incus config set` after container init.
- Modify `usage()` to document new commands and updated `create` syntax.
- Add new `case` branches at the bottom dispatcher.
