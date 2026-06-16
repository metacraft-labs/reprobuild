#!/bin/sh
# D4 P4 (fourth-fix): first-boot DPREFIX cold-init oneshot driver.
#
# Shebang is sh (busybox ash) NOT bash: R9 ships /bin/bash as a busybox
# applet symlink but busybox-1.30.1 doesn't include the bash applet, so
# invoking `bash` errors "applet not found". The script is POSIX-clean
# (no arrays, no `[[`, no process substitution).
#
# The bake-then-relocate model used in D4 P1..P3 leaves DPREFIXes in a
# half-initialised state: Darling's overlayfs upper layer is populated
# at build time, but the runtime-only sockets (shellspawn.sock,
# .darlingserver.sock, var/run/launchd/sock) are stripped (host tar
# can't copy Unix sockets across DrvFs; even if it could they'd carry
# build-host pids/paths and be unusable). On first invocation Darling
# detects "previously initialised" by the populated prefix dir and
# skips its cold-init path, then hangs forever waiting for
# shellspawn.sock.
#
# Fix shape (D4 P4): ship Mach-O payloads in a separate tree under
# /opt/reproos-foreign/macho-payloads/<tool>/Applications/... and do a
# fresh DPREFIX cold-init on first boot, copying the payload into the
# newly-initialised prefix afterwards. The bake-time DPREFIX is wiped
# clean by the build script so this script can do a true cold-init
# (Darling's prefix-init detector requires an absent or empty target
# dir).
#
# Costs (measured on repro-darling-test): ~5 s per cold-init + ~0.5 s
# per payload copy. With 3 tools (fzf/jq/ripgrep) total ~17 s on first
# boot, well within the VM-harness 120 s CmdTimeout budget.
#
# Subsequent boots: skipped via the /var/lib/reproos-darling-coldinit-
# done sentinel + the systemd unit's ConditionPathExists guard.

# `pipefail` not used: busybox 1.30 ash supports it but dash (other
# POSIX targets) doesn't; rely on direct `|| exit` checks instead.
set -eu

log() { echo "[coldinit] $*" >&2; }

DARLING_BIN="${DARLING_BIN:-/opt/reproos-foreign/darling-binaries/usr/bin/darling}"
PAYLOADS_ROOT="${PAYLOADS_ROOT:-/opt/reproos-foreign/macho-payloads}"
PREFIXES_ROOT="${PREFIXES_ROOT:-/opt/reproos-foreign/dprefixes}"
INIT_SCRIPT="${INIT_SCRIPT:-/usr/local/sbin/darling-prefix-init.sh}"
SENTINEL="${SENTINEL:-/var/lib/reproos-darling-coldinit-done}"

# Darling's first-run setup reads HOME, USER, and SHELL to populate the
# macOS-shaped /Users/<name>/ subtree. systemd executes oneshots with a
# minimal environment that doesn't include these, so darling reports
# "Cannot determine your home directory" + then crashes attempting to
# open `/proc/<pid>/ns/mnt`. Set canonical root values explicitly.
export HOME="${HOME:-/root}"
export USER="${USER:-root}"
export LOGNAME="${LOGNAME:-root}"
export SHELL="${SHELL:-/bin/sh}"
mkdir -p "$HOME"

# Modprobe fuse + ensure /dev/fuse exists. The R8 kernel built FUSE_FS
# in (D4 first fix), but the device node creation can race the boot;
# defence-in-depth here mirrors the reproos-darling-fuse.service.
modprobe fuse 2>/dev/null || true
if [ ! -c /dev/fuse ]; then
  log "creating /dev/fuse c 10 229"
  mknod -m 666 /dev/fuse c 10 229 || true
fi

[ -d "$PAYLOADS_ROOT" ] || { log "payloads root missing: $PAYLOADS_ROOT"; exit 1; }
[ -x "$DARLING_BIN" ]   || { log "darling-bin not executable: $DARLING_BIN"; exit 1; }
[ -x "$INIT_SCRIPT" ]   || { log "init-script not executable: $INIT_SCRIPT"; exit 1; }

# D4 fifth-fix: darlingserver does `mount("/", "/", MS_SLAVE|MS_REC)` to
# isolate its overlay mount from the parent NS. On the R9 initramfs
# rootfs, `/` is not a normal mount point and the remount fails with
# EINVAL, leaving the cold-init half-done (shellspawn.sock un-created).
#
# Belt-and-braces: the unit file requests PrivateMounts=yes +
# MountFlags=slave; in addition we explicitly slave-remount every
# mount under this NS via busybox `mount --make-rslave /`. If that
# also fails (e.g. systemd PrivateMounts already left `/` slavable),
# the failure is logged but ignored — darlingserver's own remount
# becomes a no-op when the propagation type is already slave.
if command -v mount >/dev/null 2>&1; then
  log "ensuring / propagation is slave (darlingserver MS_SLAVE remount)"
  mount --make-rslave / 2>&1 | sed 's/^/[coldinit][mount] /' >&2 || \
    log "  mount --make-rslave / failed (non-fatal if PrivateMounts already slaved)"
fi

mkdir -p "$PREFIXES_ROOT"
mkdir -p "$(dirname "$SENTINEL")"

# Iterate every tool directory under macho-payloads/.
for tool_dir in "$PAYLOADS_ROOT"/*/; do
  [ -d "$tool_dir" ] || continue
  tool="$(basename "$tool_dir")"
  prefix="$PREFIXES_ROOT/$tool"

  log "$tool: cold-init prefix=$prefix"

  # Wipe any half-baked prior state so darling-prefix-init.sh's "empty
  # or absent" detector fires its cold-init path.
  rm -rf "$prefix"

  # The init script absolute-paths the prefix dir itself; we point it
  # at the bundled Darling. Capture the exit code out-of-band of the
  # pipe to `sed` (busybox ash supports `pipefail` but other targets
  # may not; explicit capture is portable). Hard-fail if the init
  # script didn't exit zero.
  init_log="$prefix.init.log"
  init_status=0
  "$INIT_SCRIPT" \
    --prefix-dir "$prefix" \
    --darling-bin "$DARLING_BIN" \
    > "$init_log" 2>&1 || init_status=$?
  sed "s/^/[coldinit][$tool] /" < "$init_log" >&2 || true
  if [ "$init_status" -ne 0 ]; then
    log "$tool: darling-prefix-init.sh failed with exit $init_status"
    # D4 fifth-fix diagnostics: dump prefix state + parent NS info so
    # the cascade-7 investigator has data without needing a second
    # rebuild. Cheap (<1 KB serial output) — only emitted on failure.
    log "$tool: DIAG: /proc/self/mountinfo (first 5 lines)"
    head -n 5 /proc/self/mountinfo 2>&1 | sed "s/^/[diag][$tool] /" >&2 || true
    log "$tool: DIAG: prefix tree top-level"
    ls -la "$prefix/" 2>&1 | head -25 | sed "s/^/[diag][$tool] /" >&2 || true
    log "$tool: DIAG: var/run state"
    ls -la "$prefix/var/run/" 2>&1 | head -15 | sed "s/^/[diag][$tool] /" >&2 || true
    ls -la "$prefix/private/var/run/" 2>&1 | head -15 | sed "s/^/[diag][$tool] /" >&2 || true
    log "$tool: DIAG: dserver.log"
    cat "$prefix/private/var/log/dserver.log" 2>&1 | tail -20 | sed "s/^/[diag][$tool] /" >&2 || true
    log "$tool: DIAG: live launchd/darlingserver/shellspawn procs"
    ps -o pid,ppid,stat,comm 2>&1 | grep -E 'darling|launchd|shellspawn|mldr' | head -10 | sed "s/^/[diag][$tool] /" >&2 || true
    log "$tool: DIAG: core_pattern"
    cat /proc/sys/kernel/core_pattern 2>&1 | sed "s/^/[diag][$tool] /" >&2 || true
    exit 1
  fi
  rm -f "$init_log"

  # Copy the Mach-O payload into the freshly initialised DPREFIX. The
  # payload tree mirrors the in-prefix layout
  # (Applications/repro-store/<tool>/bin/<name>) so a recursive cp -a
  # of the per-tool dir's contents lands the executable at the
  # canonical /Applications/repro-store/<tool>/bin/<name> macOS-shaped
  # path that the launcher manifests bake.
  if [ -d "$tool_dir/Applications" ]; then
    cp -a "$tool_dir/Applications/." "$prefix/Applications/"
    log "$tool: payload copied"
  else
    log "$tool: WARN no Applications/ subtree in payload"
  fi
done

touch "$SENTINEL"
log "complete; sentinel=$SENTINEL"
