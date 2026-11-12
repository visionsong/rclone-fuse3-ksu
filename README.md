# Rclone KernelSU Module

A KernelSU module that brings [rclone](https://rclone.org) with FUSE 3 support to Android: remotes are mounted automatically at boot, kept available through `/sdcard`, and can be managed from a Web GUI.

将 [rclone](https://rclone.org)（含 FUSE 3.17.x）集成到 Android 的 **KernelSU** 模块：开机自动挂载远程存储、通过 `/sdcard` 访问、并提供网页管理界面。

> **Migrating from the Magisk version?** See [Migrating from Magisk](#migrating-from-magisk--从-magisk-迁移). Config files and the module id are unchanged.

## Why this is KernelSU-native / 为什么是原生 KernelSU 模块

The previous Magisk version installed its binaries into `system/vendor/bin/`. On KernelSU that path is unsafe: `/vendor` is covered by dm-verity/SELinux, and overlaying it via KernelSU's OverlayFS is what produced the boot loop. This version:

- **Never touches `/vendor`.** All binaries live in `system/bin/` and are additionally invoked by absolute module path, so nothing breaks if `/system` is not overlaid.
- **Works without a metamodule.** KernelSU only mounts a module's `system/` directory through a metamodule such as [meta-overlayfs](https://github.com/KernelSU-Modules/meta-overlayfs). Every script here calls `$MODDIR/system/bin/rclone` directly, so mounts, sync and the Web GUI work either way. Install a metamodule only if you also want plain `rclone` on `PATH`.
- **Never blocks init.** `service.sh` has a bounded `sys.boot_completed` gate and detaches the mount work into the background. If boot does not complete, it exits `0` instead of hanging.
- **Plain POSIX `ash`.** KernelSU runs scripts with BusyBox `ash` in standalone mode; no bash arrays, no `function` keyword, no `[[ ]]`.

> **Note:** KernelSU already starts `service.sh` without waiting (`ScriptWait::NoWait`), but a script that leaves broken mounts behind is still a bad boot. The gate and the backgrounding are deliberate.

## Installation / 安装

1. Install [KernelSU](https://github.com/tiann/KernelSU) and a manager app.
2. Download `ksu-rclone_<abi>.zip` from [Releases](https://github.com/visionsong/rclone-fuse3-ksu/releases).
3. In the KernelSU manager: **Modules → Install from storage**, pick the zip, reboot.

The zip root contains `module.prop` directly, which is what KernelSU requires.

**Optional:** if you want `rclone` available on `PATH` for other apps and shells, install [meta-overlayfs](https://github.com/KernelSU-Modules/meta-overlayfs). Without it the module still fully works — every script uses absolute paths.

## Usage / 使用

- **Action button** — KernelSU shows an *Action* button for this module. Tap it to start the rclone Web GUI; tap again to stop it. The URL is printed in the KernelSU action output.
- **Automatic mounts** — every remote in your rclone config is mounted at boot to `/mnt/rclone-<remote>` and bound into `/sdcard/<remote>`.
- **Sync jobs** — lines in `conf/sync` and `conf/copy` run periodically in the background.
- **Manual control** — from a root shell:
  ```sh
  /data/adb/modules/rclone/system/bin/rclone-config       # edit remotes
  /data/adb/modules/rclone/system/bin/rclone-mount gdrive # mount one remote now
  /data/adb/modules/rclone/system/bin/rclone-kill-all     # unmount + kill everything
  ```

### Configuration / 配置

Everything lives in `/data/adb/modules/rclone/conf/` (unchanged from the Magisk version):

| Path | Purpose / 用途 |
| --- | --- |
| `conf/rclone.conf` | Main rclone config — create with `rclone-config` / rclone 主配置 |
| `conf/env` | Overrides for any `RCLONE_*` variable / 自定义参数 |
| `conf/htpasswd` | Web GUI username:password / 网页账号密码 |
| `conf/sync` | Sync jobs, one per line / 同步任务 |
| `conf/copy` | Copy jobs, one per line / 复制任务 |

`conf/env` is sourced last, so it wins over the module defaults in `env`.

### `rclone-mount`

```sh
rclone-mount <remote> [extra rclone mount flags]
```

Mounts `<remote>:` at `/mnt/rclone-<remote>`, then binds it to `/data/media/0/<remote>`, `/mnt/pass_through/0/emulated/0/<remote>` and `/mnt/runtime/default/emulated/0/<remote>`. It runs rclone in the foreground unless you pass `--daemon`.

### `rclone-sync`

```sh
rclone-sync remote:/path /local/path [options]
```

One-shot `rclone sync` with the module environment loaded (and `RCLONE_RC` cleared, so it runs the command instead of talking to a running rc server).

### `rclone-web` / `rclone-config` / `rclone-kill-all`

- `rclone-web [flags]` — starts `rclone rcd --rc-web-gui` with the module settings.
- `rclone-config` — opens the interactive rclone config editor.
- `rclone-kill-all` — unmounts every `fuse.rclone` mount (via `fusermount3`, falling back to a lazy `umount`) and kills rclone processes.

## Sync & copy jobs / 同步与复制任务

Put one job per line in `conf/sync` (uses `rclone sync`) or `conf/copy` (uses `rclone copy`):

```
<remote>:<remote_path> <local_path> [optional options]
```

Example:

```
gdrive:/Documents "/sdcard/My Documents"
onedrive:/Photos "/sdcard/OneDrive Photos" --delete-excluded
mybox:/Backup "/data/backup" --dry-run
```

- Paths with spaces must be quoted / 路径含空格时请用双引号包裹
- Blank lines and lines starting with `#` are skipped / 空行与 `#` 开头的行会被跳过
- Jobs run with low priority (`nice -n 19 ionice -c3`); logs default to `/data/local/tmp/rclone_sync.log` and `rclone_copy.log`
- The loop interval is `RCLONE_SYNC_INTERVAL` (default `180` seconds)

## Tuning / 可调参数

Boot waits are bounded and overridable from `conf/env`:

| Variable | Default | Meaning / 含义 |
| --- | --- | --- |
| `RCLONE_BOOT_WAIT_TRIES` | `30` | Polls of `sys.boot_completed` before giving up / 轮询次数 |
| `RCLONE_BOOT_WAIT_INTERVAL` | `4` | Seconds between polls / 间隔秒数 |
| `RCLONE_NET_WAIT_TRIES` | `6` | Polls for a default route / 等待网络次数 |
| `RCLONE_NET_WAIT_INTERVAL` | `5` | Seconds between network polls / 网络轮询间隔 |
| `RCLONE_SYNC_INTERVAL` | `180` | Seconds between sync rounds / 同步轮询间隔 |
| `RCLONE_MOUNT_DIR` | `/mnt` | Parent of the mount points / 挂载点父目录 |
| `RCLONE_LOG_DIR` | `/data/local/tmp` | Logs and pid files / 日志与 pid 文件 |
| `RCLONE_RC_ADDR` | `:5572` | Web GUI listen address / 网页监听地址 |

If boot never completes, `service.sh` logs the reason to `$RCLONE_LOG_DIR/rclone-boot.log` and exits without mounting — the next boot simply tries again.

## Building / 构建

```sh
./patch.sh                       # patch the libfuse submodule
pip install meson ninja
./build.sh arm64-v8a <tag>       # or x86_64 / armeabi-v7a / x86
```

`build.sh` downloads the matching rclone build, cross-compiles `fusermount3` with the NDK, writes `update-<abi>.json`, and packs `ksu-rclone_<abi>.zip`. The zip also carries a Magisk installer under `META-INF/` so the same artifact still installs on Magisk; KernelSU ignores that directory and uses its own installer.

CI (`.github/workflows/build-android.yml`) builds both ABIs and uploads them to the release for the pushed tag.

## Testing / 测试

```sh
sh tests/check-package.sh                          # static checks (layout, schema, POSIX syntax, bootloop invariants)
sh tests/check-package.sh ksu-rclone out/x.zip     # also validate a packed zip
sh tests/verify-boot.sh                            # on-device, non-flashing runtime test
```

`tests/verify-boot.sh` must run **as root on the device**. It copies the module into a sandbox under `/data/local/tmp`, runs `service.sh` against a local dummy remote, checks that the mount is established and readable, exercises the Web GUI start/stop toggle, and cleans up after itself. It never touches the installed module.

## Migrating from Magisk / 从 Magisk 迁移

1. Uninstall the old Magisk module, or disable it — do not run both.
2. Your config is preserved: the module id is still `rclone`, so `/data/adb/modules/rclone/conf/` keeps working.
3. Your installed `updateJson` still points at the upstream feed, which will keep offering the old Magisk builds. Reinstall from this repository's Releases once to switch feeds.

## Automated updates / 自动更新

A daily workflow checks for new rclone releases and opens a pull request with the version bump. Merging it builds and publishes the release.

## License / 许可证

MIT — see [LICENSE](LICENSE).
