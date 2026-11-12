# Copilot Instructions for rclone-fuse3-ksu

## Repository Overview

This repository builds a **KernelSU** module that integrates rclone with FUSE 3.17.x into Android. It mounts configured remotes at boot, exposes them under `/sdcard`, runs periodic sync/copy jobs, and provides the rclone Web GUI behind KernelSU's Action button.

It was forked from a Magisk module. The Magisk-era choices that must **not** come back are listed under [Hard constraints](#hard-constraints-bootloop-safety).

## Technology Stack

- **Primary Languages**: POSIX shell (module scripts), Bash (build scripts), GitHub Actions YAML
- **Build System**: Meson + Ninja (cross-compiled libfuse3)
- **Target Platform**: Android, KernelSU (Magisk still installs the same zip)
- **Dependencies**:
  - rclone (prebuilt Android binaries from `beta.rclone.org` testbuilds)
  - FUSE 3.17.x (libfuse, built from source with patches in `patch-libfuse3/`)
  - Android NDK r27c
  - Python + meson + ninja
  - Standard Unix tools: `wget`, `curl`, `zip`, `patch`

## Repository Structure

```
.
├── .github/
│   ├── workflows/            # CI/CD
│   └── copilot-instructions.md
├── build.sh                  # Builds and packs the module zip
├── patch.sh                  # Applies patch-libfuse3/*.patch to the submodule
├── scripts/
│   ├── build-libfuse3.sh     # Cross-compiles libfuse3 (incl. fusermount3)
│   └── download-rclone.sh    # Fetches the rclone binary for an ABI
├── patch-libfuse3/           # Only place libfuse may be modified
├── tests/
│   ├── check-package.sh      # Static validator (runs anywhere)
│   └── verify-boot.sh        # On-device, non-flashing runtime test
├── ksu-rclone/               # The module tree that gets packaged
│   ├── module.prop           # Metadata (id/name/version/versionCode/author)
│   ├── env                   # Defaults for every RCLONE_* variable
│   ├── service.sh            # Boot-time mount service (late_start)
│   ├── sync.service.sh       # Periodic sync/copy driver
│   ├── action.sh             # Action button: toggle the Web GUI
│   ├── customize.sh          # Install-time script (ksud deletes it after)
│   └── system/bin/           # rclone, fusermount3 (built) + wrapper scripts
└── libfuse/                  # Git submodule
```

## Build Process

### Supported Architectures
- `arm64-v8a` (aarch64) and `x86_64` are built by CI
- `armeabi-v7a` and `x86` are supported by the scripts but not built by default

### Build Steps

1. `git submodule update --init` — libfuse is a submodule
2. `./patch.sh` — apply `patch-libfuse3/*.patch`
3. `pip install meson ninja`
4. `./build.sh <ABI> [TAG_NAME]`:
   - copies `ksu-rclone/` to `ksu-rclone_<ABI>/`
   - downloads the rclone binary into `ksu-rclone_<ABI>/system/bin/rclone`
   - cross-compiles libfuse3 and copies `fusermount3` into `system/bin/`
   - rewrites `updateJson` in the copied `module.prop`
   - writes `update-<ABI>.json`
   - packs `ksu-rclone_<ABI>.zip` with `module.prop` at the zip root

### Build Environment Requirements
- Android NDK r27c (`ANDROID_NDK_HOME`)
- Python with meson and ninja
- `wget`, `curl`, `zip`, `patch`

## Hard Constraints (bootloop safety)

These are not style preferences. Violating them is what made the Magisk-era module reboot-loop on KernelSU.

1. **Never write to `system/vendor/`.** KernelSU overlays `/vendor` through a metamodule, and doing so trips dm-verity / SELinux. All binaries go to `system/bin/`. The static test fails the build if `system/vendor` exists.
2. **Never block init.** No unbounded loops in `service.sh`, no `post-fs-data.sh`. The `sys.boot_completed` gate is bounded by `RCLONE_BOOT_WAIT_TRIES` × `RCLONE_BOOT_WAIT_INTERVAL` and exits `0` when boot does not complete.
3. **Call binaries by absolute module path.** KernelSU only mounts `system/` when a metamodule is installed, so `$MODDIR/system/bin/rclone` is the only reliable invocation. `MODDIR=${0%/*}` — never hardcode the module path.
4. **POSIX `sh` only in `ksu-rclone/`.** KernelSU runs module scripts with BusyBox `ash` in standalone mode (`ASH_STANDALONE=1`). No bash arrays, no `function` keyword, no `[[ ]]`, no `log -t Magisk`.
5. **Detach slow work.** `service.sh` backgrounds the mount loop and returns, so a slow or failed remote can never hold the boot.

`tests/check-package.sh` enforces 1, 2 and 4 mechanically.

## Key Files and Their Purpose

### Version Management
- `ksu-rclone/module.prop` holds `version` (e.g. `v1.76.0`) and `versionCode` (monotonically increasing integer). A version bump must update both.
- `id=rclone` **must not change.** It is the installed directory `/data/adb/modules/rclone/`, which is where users' `conf/` lives.
- `ksu-rclone` is only the in-repo build directory name; it has nothing to do with the installed path.

### Wrapper scripts (`ksu-rclone/system/bin/`)
- `rclone-config` — opens the interactive config editor
- `rclone-web` — `rclone rcd --rc-web-gui`
- `rclone-mount <remote> [flags]` — mounts to `/mnt/rclone-<remote>` and binds into `/sdcard`
- `rclone-sync` — one-shot `rclone sync`
- `rclone-kill-all` — unmounts all `fuse.rclone` mounts and kills rclone

All of them source `$MODDIR/env` first; `env` resolves `RCLONEDIR` from `MODDIR`/`MODPATH` and sets `RCLONE_BIN_DIR`.

### Runtime configuration (`/data/adb/modules/rclone/conf/`)
- `rclone.conf` — remotes
- `env` — user overrides, sourced last so they win
- `htpasswd` — Web GUI credentials
- `sync`, `copy` — one job per line: `<remote>:<path> <local> [options]`

## CI/CD Workflows

### build-android.yml
- Triggers on push to `main`, tags, and PRs
- `check-version` job detects a `ksu-rclone/module.prop` version change and creates the GitHub release
- `build` job builds `arm64-v8a` and `x86_64`, uploads artifacts, and (on a tag) uploads the zips and `update-*.json` to the release

### check-rclone-update.yml
- Runs daily at 10:00 UTC, plus manual dispatch
- Reads the current version, queries the rclone GitHub API for the latest release
- Opens a PR that bumps `version` and increments `versionCode`

## Coding Conventions

### Module scripts (`ksu-rclone/`)
- `#!/system/bin/sh`, POSIX only
- Quote everything: `"$VARIABLE"`
- Log to `$RCLONE_LOG_DIR/*.log` with `echo`, **not** `log -t Magisk`
- Keep `service.sh` early-exit friendly: the boot gate runs before any mount logic

### Build scripts (`build.sh`, `scripts/`)
- Bash is fine here (they run on the CI runner, not on Android)
- Validate the ABI argument before doing work
- Bilingual error messages are welcome (the project documents both languages)

### Version updates
- Update `version=` in `ksu-rclone/module.prop`
- Increment `versionCode=`
- Verify the rclone download URL exists for every built ABI

## Testing

```sh
sh tests/check-package.sh                        # static: layout, prop schema, syntax, bootloop invariants
sh tests/check-package.sh ksu-rclone out/x.zip   # also validate a packed zip
sh tests/verify-boot.sh                          # on-device, root, non-flashing
```

`tests/verify-boot.sh` copies the module into `/data/local/tmp`, runs `service.sh` against a local dummy remote with compressed timings, asserts the mount is present and readable, exercises the Action toggle, and cleans up. It never touches the installed module.

Manual checks before releasing:
- Module installs from the zip in the KernelSU manager
- Boot completes with the module enabled; `$RCLONE_LOG_DIR/rclone-boot.log` has no errors
- Action button starts and stops the Web GUI
- `dmesg` / `logcat` show no SELinux denials for the module

## Important Notes

1. **Submodule**: `libfuse` is a git submodule. `git submodule update --init` before building.
2. **Architecture mapping**: module uses `arm64-v8a`/`x86_64`; rclone URLs use `armv8a`/`x64`; NDK uses `aarch64-linux-android`/`x86_64-linux-android`. Keep the three in sync across `scripts/`.
3. **NDK cross-compilation**: meson cross-files, API level 28 default.
4. **FUSE patches**: never edit `libfuse/` in place; add a patch file to `patch-libfuse3/`.
5. **Automated PRs**: the update checker opens PRs. Review before merging.
6. **Binary source**: rclone comes from `beta.rclone.org` testbuilds (Android-21 compatible), not official release tarballs.
7. **Dual install**: the zip keeps a Magisk installer under `META-INF/`. KernelSU extracts with `-x 'META-INF/*'` and never runs it, so it costs nothing there. Do not add an `install.sh` at the zip root — that would flip KernelSU into its legacy install path.

## Common Tasks

### Adding an architecture
1. Add the platform to `platforms` in `scripts/build-libfuse3.sh`
2. Add the case to `scripts/download-rclone.sh`
3. Add the build step to `.github/workflows/build-android.yml`
4. Test the full build

### Updating documentation
`README.md` is bilingual; keep both languages in sync when editing.

### Fixing build issues
- Confirm NDK env vars are set
- Check meson/ninja versions
- Verify `patch.sh` applies cleanly
- Confirm submodules are initialised

## External Resources

- [rclone documentation](https://rclone.org/)
- [libfuse](https://github.com/libfuse/libfuse)
- [KernelSU module documentation](https://kernelsu.org/guide/module.html)
- [KernelSU module config](https://kernelsu.org/guide/module-config.html)
- [Android NDK](https://developer.android.com/ndk)

## Security Considerations

- Do not commit secrets or credentials
- Review automated update PRs before merging
- Validate download URLs (supply-chain safety)
- Test new rclone versions before release
