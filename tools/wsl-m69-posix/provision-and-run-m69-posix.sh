#!/usr/bin/env bash
#
# provision-and-run-m69-posix.sh - runs INSIDE a throwaway Ubuntu 22.04
# WSL distro to exercise the M69 Linux destructive gates AND the
# post-M69 / M83 Linux driver gates (M83 step 13).
#
# Baseline M69 gates (4):
#
#   tests/e2e/m69/t_e2e_repro_infra_passwd_user_safe_destroy.nim
#       REPRO_M69_PASSWD_VM=1   - real useradd / usermod / userdel
#   tests/e2e/m69/t_e2e_repro_infra_fs_system_file.nim
#       REPRO_M69_FS_VM=1       - real /etc/ file write / drift / rollback
#   tests/e2e/m69/t_e2e_repro_infra_env_system_variable.nim
#       REPRO_M69_ENV_VM=1      - real /etc/profile.d/ fragment write
#   tests/e2e/m69/t_e2e_repro_infra_systemd_system_unit.nim
#       REPRO_M69_SYSTEMD_VM=1  - real /etc/systemd/system/ unit write +
#                                 `systemctl daemon-reload` (no
#                                 `enable --now`, see the gate header
#                                 for the WSL systemd-as-PID-1 rationale)
#
# Post-M69 / M83 system-scope driver gates (added by step 13):
#
#   linux.sysctl              REPRO_M69_SYSCTL_VM
#   linux.polkitRule          REPRO_M69_POLKIT_VM
#   linux.sudoersRule         REPRO_M69_SUDOERS_VM
#   linux.tmpfilesRule        REPRO_M69_TMPFILES_VM
#   linux.nixDaemonSetting    REPRO_M69_NIX_VM
#   systemd.systemTimer       REPRO_M69_SYSTEMD_TIMER_VM
#   linux.udevRule            REPRO_M69_UDEV_VM
#   linux.firewallRule        REPRO_M69_LINUX_FIREWALL_VM
#   os.timezone (POSIX)       REPRO_M69_OS_TIMEZONE_VM
#   os.hostname (POSIX)       REPRO_M69_OS_HOSTNAME_VM
#   passwd.group              REPRO_M69_PASSWD_GROUP_VM
#
# M68 / M83 home-scope driver gates added by step 13:
#
#   fs.userFile (POSIX)       REPRO_M69_FS_USER_FILE_VM
#   fs.managedBlock (POSIX)   REPRO_M69_FS_MANAGED_BLOCK_VM
#   env.userPath (POSIX)      REPRO_M69_ENV_USER_PATH_VM
#   shell.integration (POSIX) REPRO_M69_SHELL_INTEGRATION_VM
#   linux.dconfKey            REPRO_M69_DCONF_KEY_VM
#   linux.kdeConfigKey        REPRO_M69_KDE_CONFIG_KEY_VM
#   systemd.userUnit          REPRO_M69_SYSTEMD_USER_UNIT_VM
#
# Gates that cannot realistically run inside a bare WSL Ubuntu 22.04
# rootfs (no systemd-as-PID-1, no dbus session, no live nftables kernel
# hooks, no KDE / dconf / udev daemons) are designed to write
# `SKIP: <gate> (<reason>)` to the sentinel file rather than failing
# the harness. The "what WSL cannot test, the next Linux VM catches"
# guidance from the M83 step-13 design lets us validate coverage
# parity for what WSL realistically supports.
#
# macOS-only drivers (`launchd.userAgent`, `launchd.systemDaemon`,
# `macos.systemDefault`, `macos.userDefault`) are out of scope for
# this harness — macOS testing happens on a separate Mac per the
# 2026-05-28 directive.
#
# The script:
#
#   Stage A - install C toolchain (gcc + libsqlite3-dev + curl + xz-utils
#             + systemd for the systemctl binary)
#   Stage B - download + extract Nim 2.2.8 to /opt/nim-2.2.8
#   Stage C - copy the repo source out of the read-only /mnt/d/ mount
#             into a writable workdir at /work/reprobuild (and the
#             sibling runquota repo at /work/runquota)
#   Stage D - install verification shims for useradd/usermod/userdel/
#             systemctl that LOG argv + forward to the real binary
#   Stage E - build + run each gate sequentially, capturing per-gate
#             stdout/stderr/exit. Each gate gets its own env var
#             only set for that gate's run.
#   Stage F - copy logs + RESULT.txt to the OUTPUT folder, write DONE
#
# Inputs (env, set by the host-side runner via `wsl --exec env ...`):
#   REPRO_HOST_OUT_DIR   - host OUTPUT dir, e.g. /mnt/d/metacraft/wsl-m69-posix-out
#   REPRO_HOST_REPO_DIR  - host repo dir,  e.g. /mnt/d/metacraft/reprobuild
#   REPRO_HOST_RUNQUOTA  - host sibling,   e.g. /mnt/d/metacraft/runquota
#   REPRO_HOST_NIM_TAR   - cached Nim tarball, e.g. /mnt/d/metacraft/wsl-m69-posix-cache/nim-2.2.8-linux_x64.tar.xz
#
# Output to ${REPRO_HOST_OUT_DIR}:
#   00-provision.log                    - stage-by-stage provisioning log
#   01-<gate>-build.log                 - per-gate compile log
#   02-<gate>-run.txt                   - per-gate stdout/stderr + exit code
#   03-passwd-cmd-trace.log             - useradd/usermod/userdel argv trace
#   04-systemd-cmd-trace.log            - systemctl argv trace
#   RESULT.txt                          - per-stage + per-gate status, overall verdict
#   DONE                                - sentinel (written last)
#
# This script's exit code is informational; the host runner reads
# DONE + RESULT.txt for the real verdict. The script never aborts on
# an individual gate failure - it records the failure and pushes on,
# so the host runner always gets a RESULT.txt + DONE.

set -u
# NOTE: no `set -e`: we want each stage to record its own failure and
# still flush logs to the host.

# ---- Inputs / defaults -----------------------------------------------------
OUT_DIR="${REPRO_HOST_OUT_DIR:-/mnt/d/metacraft/wsl-m69-posix-out}"
REPO_HOST="${REPRO_HOST_REPO_DIR:-/mnt/d/metacraft/reprobuild}"
RUNQUOTA_HOST="${REPRO_HOST_RUNQUOTA:-/mnt/d/metacraft/runquota}"
NIM_TAR="${REPRO_HOST_NIM_TAR:-/mnt/d/metacraft/wsl-m69-posix-cache/nim-2.2.8-linux_x64.tar.xz}"

WORK_ROOT="/work"
REPO_WORK="${WORK_ROOT}/reprobuild"
RUNQUOTA_WORK="${WORK_ROOT}/runquota"
NIM_ROOT="/opt/nim-2.2.8"
NIM_BIN="${NIM_ROOT}/bin/nim"

PASSWD_TRACE_LOG="${OUT_DIR}/03-passwd-cmd-trace.log"
SYSTEMD_TRACE_LOG="${OUT_DIR}/04-systemd-cmd-trace.log"

# M83 step 13: the sentinel file is the gate's success signal. Each
# new gate appends `OK: <name>` or `SKIP: <name> (<reason>)` to this
# file; the orchestrator counts the lines at verdict time.
SENTINEL_FILE="${OUT_DIR}/05-vm-gate-sentinels.txt"
export REPRO_M69_VM_SENTINEL_FILE="${SENTINEL_FILE}"

# ---- Result table accumulator ---------------------------------------------
declare -A RESULTS
RESULTS_ORDER=()
record() {
  local key="$1" val="$2"
  RESULTS["$key"]="$val"
  RESULTS_ORDER+=("$key")
  printf '[%s] RESULT  %s = %s\n' "$(date -u +%H:%M:%S)" "$key" "$val" \
    | tee -a "${LOG_FILE}" >/dev/null 2>&1 || true
}

log() {
  local msg="$1"
  printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$msg" \
    | tee -a "${LOG_FILE}" >/dev/null 2>&1 || true
  printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$msg"
}

section() {
  log ""
  log "============================================================"
  log "$1"
  log "============================================================"
}

# Always-runs finalizer: writes RESULT.txt then DONE so the host
# runner is never stuck polling. Idempotent.
finalize() {
  local verdict="$1"
  {
    echo "M69 POSIX destructive-gate WSL harness - RESULT"
    echo "generated: $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
    echo "distro: $(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")"
    echo "kernel: $(uname -a)"
    echo "user: $(id -u -n) (uid=$(id -u))"
    echo ""
    for k in "${RESULTS_ORDER[@]}"; do
      printf '%-40s %s\n' "$k" "${RESULTS[$k]}"
    done
    echo ""
    echo "VERDICT: ${verdict}"
  } > "${OUT_DIR}/RESULT.txt" 2>/dev/null || true
  # DONE last - signals to the host that all other artifacts are flushed.
  printf 'done %s\n' "$(date -u +'%Y-%m-%d %H:%M:%S UTC')" \
    > "${OUT_DIR}/DONE" 2>/dev/null || true
  log "FINALIZED: ${verdict}"
}

# ---- Output dir + log file -------------------------------------------------
mkdir -p "${OUT_DIR}" 2>/dev/null || true
LOG_FILE="${OUT_DIR}/00-provision.log"
: > "${LOG_FILE}" 2>/dev/null || true
: > "${PASSWD_TRACE_LOG}" 2>/dev/null || true
: > "${SYSTEMD_TRACE_LOG}" 2>/dev/null || true
: > "${SENTINEL_FILE}" 2>/dev/null || true

log "M69 POSIX destructive-gate WSL harness starting (multi-gate)."
log "OUT_DIR        = ${OUT_DIR}"
log "REPO_HOST      = ${REPO_HOST}"
log "RUNQUOTA_HOST  = ${RUNQUOTA_HOST}"
log "NIM_TAR        = ${NIM_TAR}"
log "running as: $(id -u -n) (uid=$(id -u))"

# Top-level trap: ensure RESULT.txt + DONE always exist, even on
# unexpected exit. If finalize already wrote them, this is a no-op.
trap '[ -f "${OUT_DIR}/DONE" ] || finalize "ERROR - script exited unexpectedly"' EXIT

# ===========================================================================
# Stage A - apt-install C toolchain + libsqlite3 + curl + xz + systemd
#          + M83 step 13 packages for the post-M69 Linux driver gates.
# ===========================================================================
section "Stage A - apt-install baseline + M83 step 13 driver packages"
export DEBIAN_FRONTEND=noninteractive
# The rootfs ships without an updated apt cache; refresh once.
# `systemd` brings the `systemctl` binary the systemd.systemUnit gate
# needs even when systemd is NOT PID 1 - daemon-reload and `systemctl
# show` parse from the unit file on disk regardless. We do NOT
# activate systemd-as-PID-1 in this harness; the gates that depend on
# PID-1 systemd (the runtime-state paths) emit SKIP sentinels instead
# of failing.
#
# M83 step 13 additions:
#   - sudo: provides `visudo` for the linux.sudoersRule gate's
#     `visudo -c -f <tmp>` validation step.
#   - dconf-cli: provides the `dconf` binary the linux.dconfKey gate
#     wraps. dconf still needs a live dbus session (which a bare WSL
#     rootfs does NOT have); the gate's pre-check emits SKIP when the
#     bus is unreachable.
#   - libkf5config-bin: provides `kwriteconfig5` / `kreadconfig5` for
#     the linux.kdeConfigKey gate. Best-effort; package may be
#     unavailable in some apt mirrors.
#   - nftables: provides the `nft` binary for linux.firewallRule.
#     The WSL kernel typically lacks the netfilter hooks; the gate's
#     pre-check emits SKIP when nftables is not reachable.
#   - dbus / dbus-user-session: if installed, enables a best-effort
#     attempt at systemctl --user / dconf bus activation. We do NOT
#     activate the system dbus daemon — WSL without PID-1 systemd
#     cannot do so consistently — so the gates that need a live bus
#     fall back to SKIP.
#   - dbus-x11: provides `/usr/bin/dbus-run-session`, the per-
#     invocation transient session-bus launcher the
#     `linux.dconfKey` driver wraps `dconf write` / `dconf read` /
#     `dconf reset` with when `$DBUS_SESSION_BUS_ADDRESS` is
#     empty. Without this binary the dconfKey gate fails on a bare
#     rootfs with "Could not connect: No such file or directory"
#     (the bus the wrapper would spawn does not exist) and the
#     gate cannot run end-to-end.
#   - kmod: provides `udevadm`'s prereqs. udev daemon itself is NOT
#     running in this harness; linux.udevRule's gate catches the
#     reload failure and emits SKIP.
{
  apt-get update -y -qq 2>&1
  # `dbus` (NOT `dbus-user-session`) is the minimum to get `dbus-daemon`
  # for the optional session-bus startup; `dbus-user-session` pulls in
  # `libpam-systemd` which mutates PAM and breaks the baseline
  # passwd.user gate's `useradd`/`usermod` post-apply re-probes (the
  # PAM hook adds extra setup that diverges from the canonical
  # observed state). We do NOT install `dbus-user-session`.
  #
  # `dbus-x11` ships `dbus-run-session` standalone — the
  # `linux.dconfKey` driver wraps every `dconf` invocation with
  # `dbus-run-session --` when there is no session bus, so this
  # binary MUST be present for the dconfKey gate to pass.
  #
  # `kmod` is similarly NOT installed — udev is not running in this
  # harness, and `kmod` pulls in shared libraries that perturb the
  # other gates' PAM/setup flows.
  apt-get install -y --no-install-recommends \
    ca-certificates curl xz-utils gcc libc6-dev libsqlite3-dev passwd \
    systemd \
    sudo \
    dconf-cli \
    libkf5config-bin \
    nftables \
    dbus \
    dbus-x11 \
    2>&1
} >> "${LOG_FILE}" 2>&1
APT_STATUS=$?
if [ "${APT_STATUS}" -eq 0 ] \
   && command -v gcc >/dev/null \
   && [ -f /usr/lib/x86_64-linux-gnu/libsqlite3.so ] \
       || [ -f /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 ]; then
  record "stageA_apt"          "OK"
else
  record "stageA_apt"          "FAIL (apt-get exit=${APT_STATUS})"
fi
record "stageA_gcc_version"  "$(gcc --version 2>/dev/null | head -n1 || echo 'gcc not found')"
record "stageA_useradd"      "$(which useradd 2>/dev/null || echo 'useradd not found')"
record "stageA_systemctl"    "$(which systemctl 2>/dev/null || echo 'systemctl not found')"
record "stageA_visudo"       "$(which visudo 2>/dev/null || echo 'visudo not found')"
record "stageA_dconf"        "$(which dconf 2>/dev/null || echo 'dconf not found')"
record "stageA_kwriteconfig5" "$(which kwriteconfig5 2>/dev/null || echo 'kwriteconfig5 not found')"
record "stageA_nft"          "$(which nft 2>/dev/null || echo 'nft not found')"
record "stageA_udevadm"      "$(which udevadm 2>/dev/null || echo 'udevadm not installed (kmod skipped)')"
record "stageA_dbus_daemon"  "$(which dbus-daemon 2>/dev/null || echo 'dbus-daemon not found')"
record "stageA_dbus_run_session" "$(which dbus-run-session 2>/dev/null || echo 'dbus-run-session not found (linux.dconfKey gate will FAIL)')"

# ===========================================================================
# Stage B - install Nim 2.2.8 from the cached prebuilt linux x64 tarball
# ===========================================================================
section "Stage B - install Nim 2.2.8 to ${NIM_ROOT}"
if [ -x "${NIM_BIN}" ]; then
  log "Nim already present at ${NIM_BIN}"
  record "stageB_nim"          "OK (cached)"
elif [ ! -f "${NIM_TAR}" ]; then
  record "stageB_nim"          "FAIL - tarball missing: ${NIM_TAR}"
else
  mkdir -p "${NIM_ROOT}" /opt
  log "extracting ${NIM_TAR} -> ${NIM_ROOT}"
  # tarball expands to nim-2.2.8/; move its contents up.
  tmpdir=$(mktemp -d)
  if tar -xJf "${NIM_TAR}" -C "${tmpdir}" >> "${LOG_FILE}" 2>&1; then
    inner="${tmpdir}/nim-2.2.8"
    if [ -d "${inner}" ]; then
      # Copy with -a to preserve perms; the prebuilt tarball ships exec bits.
      cp -a "${inner}/." "${NIM_ROOT}/"
      rm -rf "${tmpdir}"
    else
      log "  unexpected tarball layout under ${tmpdir}:"
      ls -la "${tmpdir}" >> "${LOG_FILE}" 2>&1 || true
    fi
  else
    log "  tar -xJf FAILED (status $?)"
  fi
  if [ -x "${NIM_BIN}" ]; then
    record "stageB_nim"        "OK"
  else
    record "stageB_nim"        "FAIL - extraction did not produce ${NIM_BIN}"
  fi
fi
record "stageB_nim_version"   "$("${NIM_BIN}" --version 2>/dev/null | head -n1 || echo 'nim not runnable')"
export PATH="${NIM_ROOT}/bin:${PATH}"

# ===========================================================================
# Stage C - copy the repo + runquota into a writable workdir
# ===========================================================================
section "Stage C - stage the repo source into ${WORK_ROOT}"
mkdir -p "${WORK_ROOT}"
# Clean any previous run's leftovers (idempotence).
rm -rf "${REPO_WORK}" "${RUNQUOTA_WORK}" 2>/dev/null || true

copy_repo() {
  local src="$1" dst="$2" label="$3" excludes="$4"
  if [ ! -d "${src}" ]; then
    log "  MISSING ${label}: ${src}"
    return 1
  fi
  log "  copy ${label}: ${src} -> ${dst}"
  log "    excluding: ${excludes}"
  mkdir -p "${dst}"
  # rsync is not in the rootfs by default; cp -a with a find-based
  # top-level exclusion is robust and dependency-free.
  (cd "${src}" && find . -mindepth 1 -maxdepth 1 \
      ! -name 'build' ! -name '.git' ! -name 'target' \
      ! -name 'bench-results' ! -name 'test-logs' \
      ! -name 'references' \
      -exec cp -a -t "${dst}" -- {} +) >> "${LOG_FILE}" 2>&1
  local cp_status=$?
  # Pull in only the vendored hash headers/c that config.nims actually
  # needs.
  if [ -d "${src}/references/mold/third-party" ]; then
    mkdir -p "${dst}/references/mold/third-party"
    for sub in blake3 xxhash; do
      if [ -d "${src}/references/mold/third-party/${sub}" ]; then
        cp -a "${src}/references/mold/third-party/${sub}" \
          "${dst}/references/mold/third-party/" >> "${LOG_FILE}" 2>&1
      fi
    done
  fi
  return ${cp_status}
}

C_REPO=0
copy_repo "${REPO_HOST}" "${REPO_WORK}" "host reprobuild repo" \
  "build .git target bench-results test-logs references-except-blake3-xxhash" \
  || C_REPO=1
C_RQ=0
if [ -d "${RUNQUOTA_HOST}" ]; then
  log "  copy runquota: ${RUNQUOTA_HOST} -> ${RUNQUOTA_WORK}"
  mkdir -p "${RUNQUOTA_WORK}"
  (cd "${RUNQUOTA_HOST}" && find . -mindepth 1 -maxdepth 1 \
      ! -name 'build' ! -name '.git' ! -name 'target' \
      -exec cp -a -t "${RUNQUOTA_WORK}" -- {} +) >> "${LOG_FILE}" 2>&1 \
    || C_RQ=1
else
  log "  MISSING host runquota repo: ${RUNQUOTA_HOST}"
  C_RQ=1
fi

# Size sanity check + assert every baseline gate source is present.
# M83 step 13 gate sources are checked best-effort: a missing M83 gate
# is recorded but does not fail Stage C (the gate's own run-time
# branch handles the missing-source case via the gate-list filter
# below).
ALL_GATES_PRESENT=1
for src in \
    tests/e2e/m69/t_e2e_repro_infra_passwd_user_safe_destroy.nim \
    tests/e2e/m69/t_e2e_repro_infra_fs_system_file.nim \
    tests/e2e/m69/t_e2e_repro_infra_env_system_variable.nim \
    tests/e2e/m69/t_e2e_repro_infra_systemd_system_unit.nim ; do
  if [ ! -f "${REPO_WORK}/${src}" ]; then
    log "  MISSING gate source: ${src}"
    ALL_GATES_PRESENT=0
  fi
done
if [ "${C_REPO}" -eq 0 ] && [ "${ALL_GATES_PRESENT}" -eq 1 ]; then
  record "stageC_repo_copy"     "OK ($(du -sh "${REPO_WORK}" 2>/dev/null | awk '{print $1}'))"
else
  record "stageC_repo_copy"     "FAIL"
fi
if [ "${C_RQ}" -eq 0 ]; then
  record "stageC_runquota_copy" "OK ($(du -sh "${RUNQUOTA_WORK}" 2>/dev/null | awk '{print $1}'))"
else
  record "stageC_runquota_copy" "FAIL"
fi

# ===========================================================================
# Stage D - install verification shims for the destructive commands
# every gate may exercise. The shim logs argv to its trace log and
# FORWARDS to the real binary (renamed `<name>.real`). Without this,
# a `[OK]` from the test could in principle come from a misconfigured
# else-branch that silently no-ops. After each gate runs we assert
# its trace log contains the expected destructive shell-outs.
# ===========================================================================
section "Stage D - install verification shims"

install_shim() {
  local bin_path="$1" trace_log="$2"
  local bin_name="$(basename "${bin_path}")"
  if [ ! -x "${bin_path}" ]; then
    log "  WARN: ${bin_path} not present - skipping shim"
    return 0
  fi
  if [ -x "${bin_path}.real" ]; then
    log "  shim already installed for ${bin_path}"
    return 0
  fi
  cp -a "${bin_path}" "${bin_path}.real"
  cat > "${bin_path}" <<SHIM
#!/bin/bash
echo "[\$(date -u +%H:%M:%S)] ${bin_name} \$@" >> ${trace_log}
exec ${bin_path}.real "\$@"
SHIM
  chmod +x "${bin_path}"
  log "    ${bin_path} -> ${bin_path}.real (shimmed; trace=${trace_log})"
}

log "  installing useradd / usermod / userdel verification shims:"
for bin in useradd usermod userdel; do
  install_shim "/usr/sbin/${bin}" "${PASSWD_TRACE_LOG}"
done

log "  installing systemctl verification shim:"
# systemctl can live in /bin/systemctl, /usr/bin/systemctl, or
# /usr/sbin/systemctl depending on the distro; install for whichever
# the live binary resolves to so the trace captures it.
SYSTEMCTL_LIVE="$(command -v systemctl 2>/dev/null || true)"
if [ -n "${SYSTEMCTL_LIVE}" ]; then
  # Resolve symlinks to the real on-disk path so we don't shim a link.
  SYSTEMCTL_REAL_PATH="$(readlink -f "${SYSTEMCTL_LIVE}" 2>/dev/null || echo "${SYSTEMCTL_LIVE}")"
  install_shim "${SYSTEMCTL_REAL_PATH}" "${SYSTEMD_TRACE_LOG}"
else
  log "    systemctl NOT FOUND in PATH - systemd gate will skip"
fi

record "stageD_passwd_shims"   "useradd/usermod/userdel shimmed"
record "stageD_systemctl_shim" "${SYSTEMCTL_LIVE:-not-found}"

# ===========================================================================
# Stage E - build + run each gate sequentially
# ===========================================================================
section "Stage E - build + run each M69 Linux destructive gate"

run_gate() {
  # $1 = short name (e.g. passwd-user)
  # $2 = gate source path (relative to repo)
  # $3 = env-var to set (e.g. REPRO_M69_PASSWD_VM)
  # $4 = expected destructive trace log (or "" if none expected)
  # $5 = expected trace-grep pattern (or "")
  local name="$1" src="$2" env_var="$3" trace_log="$4" trace_pattern="$5"
  local build_log="${OUT_DIR}/01-${name}-build.log"
  local run_out="${OUT_DIR}/02-${name}-run.txt"
  local bin_out="/tmp/m69-${name}-gate"
  local nimcache="/tmp/m69-${name}-nimcache"

  : > "${build_log}"
  : > "${run_out}"

  if [ ! -x "${NIM_BIN}" ] || [ ! -d "${REPO_WORK}" ] || [ ! -f "${REPO_WORK}/${src}" ]; then
    record "gateE_${name}_exit"     "PRE-FAIL (nim/workdir/src missing)"
    return 1
  fi

  log "  --- build ${name} ---"
  pushd "${REPO_WORK}" >/dev/null || true
  "${NIM_BIN}" c \
      --hints:off \
      --warning:UnusedImport:off \
      --warning:CaseTransition:off \
      --threads:on \
      "--nimcache:${nimcache}" \
      "--out:${bin_out}" \
      "${src}" \
      > "${build_log}" 2>&1
  local build_exit=$?
  log "    nim c exit=${build_exit}"
  record "gateE_${name}_build_exit"  "${build_exit}"
  if [ "${build_exit}" -ne 0 ] || [ ! -x "${bin_out}" ]; then
    record "gateE_${name}_exit"      "BUILD-FAILED"
    popd >/dev/null || true
    return 1
  fi

  log "  --- run ${name} (${env_var}=1) ---"
  {
    echo "COMMAND: ${bin_out}"
    echo "ENV: ${env_var}=1"
    echo "USER: $(id -u -n) (uid=$(id -u))"
    echo "DISTRO: $(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")"
    echo ""
    echo "----- STDOUT + STDERR -----"
  } >> "${run_out}"

  # Set ONLY this gate's env var for this gate's invocation. The
  # other gates' env vars are kept unset so an accidental cross-
  # pollination (one gate triggering another's destructive path) is
  # impossible.
  #
  # `REPRO_M69_VM_SENTINEL_FILE` is forwarded through `env -i` so the
  # M83 step-13 gates know where to append their `OK:` / `SKIP:`
  # lines. `DBUS_SESSION_BUS_ADDRESS` is forwarded so the dconf /
  # systemd-user-unit gates can reach a live session bus (if one was
  # started in the prologue).
  env -i \
    PATH="${PATH}" \
    HOME="${HOME:-/root}" \
    REPRO_M69_VM_SENTINEL_FILE="${REPRO_M69_VM_SENTINEL_FILE:-${SENTINEL_FILE}}" \
    DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" \
    "${env_var}=1" \
    "${bin_out}" >> "${run_out}" 2>&1
  local gate_exit=$?
  {
    echo ""
    echo "----- END -----"
    echo "EXIT CODE: ${gate_exit}"
  } >> "${run_out}"
  log "    gate exit=${gate_exit}"
  record "gateE_${name}_exit"        "${gate_exit}"

  # Verify the destructive trace log captured the expected shell-out,
  # if a pattern was supplied. The trace log is APPEND-only per gate
  # and SHARED across gates with similar shell-outs (the systemd gate
  # appends to systemd-cmd-trace.log; the passwd gate appends to
  # passwd-cmd-trace.log). We grep for the gate-specific marker the
  # call-site uses.
  if [ -n "${trace_log}" ] && [ -n "${trace_pattern}" ]; then
    local trace_hits
    trace_hits=$(grep -cE "${trace_pattern}" "${trace_log}" 2>/dev/null || true)
    record "gateE_${name}_trace_hits"  "${trace_hits} (pattern=${trace_pattern})"
    if [ "${trace_hits}" -ge 1 ]; then
      record "gateE_${name}_destructive_verified" "YES"
    else
      record "gateE_${name}_destructive_verified" "NO - gate may have skipped the destructive branch"
    fi
  fi

  popd >/dev/null || true
  return ${gate_exit}
}

# --- Gate 1: passwd.user ---------------------------------------------------
log ""
log "============================================================"
log "Gate 1/4: passwd.user (REPRO_M69_PASSWD_VM=1)"
log "============================================================"
run_gate \
  "passwd-user" \
  "tests/e2e/m69/t_e2e_repro_infra_passwd_user_safe_destroy.nim" \
  "REPRO_M69_PASSWD_VM" \
  "${PASSWD_TRACE_LOG}" \
  '^\[..:..:..\] useradd '
PASSWD_EXIT=$?

# --- Stage-D cleanup for passwd: defence in depth, remove any stray
#    reprotest* accounts the gate may have left behind on failure. -----
for u in $(getent passwd | awk -F: '/^reprotest/ {print $1}'); do
  log "  cleanup: userdel -r ${u}"
  /usr/sbin/userdel.real -r "${u}" >> "${LOG_FILE}" 2>&1 || \
    userdel -r "${u}" >> "${LOG_FILE}" 2>&1 || true
done

# --- Gate 2: fs.systemFile -------------------------------------------------
log ""
log "============================================================"
log "Gate 2/4: fs.systemFile (REPRO_M69_FS_VM=1)"
log "============================================================"
run_gate \
  "fs-system-file" \
  "tests/e2e/m69/t_e2e_repro_infra_fs_system_file.nim" \
  "REPRO_M69_FS_VM" \
  "" \
  ""
FS_EXIT=$?
# Belt-and-braces: remove any stray /etc/repro-m69-fs-gate-*.conf.
for f in /etc/repro-m69-fs-gate-*.conf; do
  [ -f "${f}" ] || continue
  log "  cleanup: rm -f ${f}"
  rm -f "${f}" >> "${LOG_FILE}" 2>&1 || true
done

# --- Gate 3: env.systemVariable --------------------------------------------
log ""
log "============================================================"
log "Gate 3/4: env.systemVariable (REPRO_M69_ENV_VM=1)"
log "============================================================"
run_gate \
  "env-system-variable" \
  "tests/e2e/m69/t_e2e_repro_infra_env_system_variable.nim" \
  "REPRO_M69_ENV_VM" \
  "" \
  ""
ENV_EXIT=$?
# Belt-and-braces: remove any stray /etc/profile.d/repro-system-env-*.sh
# fragments. Match by lowercased prefix.
for f in /etc/profile.d/repro-system-env-repro_m69_gate_var_*.sh; do
  [ -f "${f}" ] || continue
  log "  cleanup: rm -f ${f}"
  rm -f "${f}" >> "${LOG_FILE}" 2>&1 || true
done

# --- Gate 4: systemd.systemUnit --------------------------------------------
log ""
log "============================================================"
log "Gate 4/4: systemd.systemUnit (REPRO_M69_SYSTEMD_VM=1)"
log "============================================================"
run_gate \
  "systemd-system-unit" \
  "tests/e2e/m69/t_e2e_repro_infra_systemd_system_unit.nim" \
  "REPRO_M69_SYSTEMD_VM" \
  "${SYSTEMD_TRACE_LOG}" \
  '^\[..:..:..\] systemctl( .*)? daemon-reload'
SYSTEMD_EXIT=$?
# Belt-and-braces: remove any stray /etc/systemd/system/repro-m69-gate-*.service.
for f in /etc/systemd/system/repro-m69-gate-*.service; do
  [ -f "${f}" ] || continue
  log "  cleanup: rm -f ${f}"
  rm -f "${f}" >> "${LOG_FILE}" 2>&1 || true
done
# A final daemon-reload so systemd's view of /etc/systemd/system/ is
# consistent with what's on disk (defensive; the distro is unregistered
# next anyway).
systemctl daemon-reload >> "${LOG_FILE}" 2>&1 || true

# ===========================================================================
# Stage E (continued) - M83 step 13: post-M69 / M83 Linux driver gates
#
# These gates were added by M83 step 13 to extend WSL coverage beyond
# the 4 baseline M69 destructive gates. Each gate:
#   * is independent (a failure in one does NOT poison the next);
#   * writes `OK:` or `SKIP:` to ${SENTINEL_FILE};
#   * cleans up its own artifacts on success.
#
# Gates that cannot realistically run in a bare WSL Ubuntu 22.04
# rootfs without systemd-as-PID-1 (systemd.userUnit, os.timezone,
# os.hostname, linux.firewallRule, linux.dconfKey, linux.kdeConfigKey,
# linux.udevRule) self-detect the missing prerequisites and emit
# `SKIP:` sentinels; the destructive paths are deferred to a real-
# Linux / Hyper-V VM, exactly as M69's existing sandbox-deferred
# runtime paths are.
# ===========================================================================
section "Stage E (M83 step 13) - post-M69 Linux driver gates"
mkdir -p /tmp/repro-vm-test 2>/dev/null || true

# The harness deliberately does NOT pre-start a session DBus daemon
# any more — the `linux.dconfKey` driver auto-wraps every `dconf`
# invocation with `dbus-run-session --` when `$DBUS_SESSION_BUS_
# ADDRESS` is empty, so a per-invocation transient bus is the
# canonical bare-rootfs path. The previous `dbus-daemon --session
# --print-address --fork` produced an address pointing at a socket
# the forked daemon never actually bound (the `dbus-daemon` parent
# exit semantics under WSL leave the printed address stale before
# the gate reads it), which broke the driver's "bus is set →ride
# the operator's bus" branch and surfaced as "Could not connect:
# No such file or directory" inside `dconf write`. Unsetting the
# address keeps the driver on its own bootstrap path.
unset DBUS_SESSION_BUS_ADDRESS
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi
if [ ! -d "${XDG_RUNTIME_DIR}" ]; then
  mkdir -p "${XDG_RUNTIME_DIR}" 2>/dev/null || true
  chmod 700 "${XDG_RUNTIME_DIR}" 2>/dev/null || true
fi
record "stageE_dbus_session" "not-attempted (driver bootstraps via dbus-run-session)"

run_m83_gate() {
  # A thinner wrapper than run_gate above: M83 step-13 gates are NOT
  # tied to the passwd/systemd trace logs and have no trace pattern,
  # so the wrapper just builds + runs + records exit.
  # $1 = short name (e.g. linux-sysctl)
  # $2 = gate source path (relative to repo)
  # $3 = env-var to set (e.g. REPRO_M69_SYSCTL_VM)
  local name="$1" src="$2" env_var="$3"
  if [ ! -f "${REPO_WORK}/${src}" ]; then
    log "  ${name}: source missing, skipping"
    record "gateM83_${name}_exit" "SOURCE-MISSING"
    return 0
  fi
  run_gate "${name}" "${src}" "${env_var}" "" "" || true
}

# --- System-scope post-M69 gates -------------------------------------------
log ""
log "------------------------------------------------------------"
log "M83 system-scope gates"
log "------------------------------------------------------------"
run_m83_gate "linux-sysctl" \
  "tests/e2e/m69/t_e2e_repro_infra_linux_sysctl_vm.nim" \
  "REPRO_M69_SYSCTL_VM"
run_m83_gate "linux-polkitrule" \
  "tests/e2e/m69/t_e2e_repro_infra_linux_polkitrule_vm.nim" \
  "REPRO_M69_POLKIT_VM"
run_m83_gate "linux-sudoersrule" \
  "tests/e2e/m69/t_e2e_repro_infra_linux_sudoersrule_vm.nim" \
  "REPRO_M69_SUDOERS_VM"
run_m83_gate "linux-tmpfilesrule" \
  "tests/e2e/m69/t_e2e_repro_infra_linux_tmpfilesrule_vm.nim" \
  "REPRO_M69_TMPFILES_VM"
run_m83_gate "linux-nixdaemonsetting" \
  "tests/e2e/m69/t_e2e_repro_infra_linux_nixdaemonsetting_vm.nim" \
  "REPRO_M69_NIX_VM"
run_m83_gate "systemd-system-timer" \
  "tests/e2e/m69/t_e2e_repro_infra_systemd_system_timer_vm.nim" \
  "REPRO_M69_SYSTEMD_TIMER_VM"
run_m83_gate "linux-udevrule" \
  "tests/e2e/m69/t_e2e_repro_infra_linux_udevrule_vm.nim" \
  "REPRO_M69_UDEV_VM"
run_m83_gate "linux-firewallrule" \
  "tests/e2e/m69/t_e2e_repro_infra_linux_firewallrule_vm.nim" \
  "REPRO_M69_LINUX_FIREWALL_VM"
run_m83_gate "os-timezone-posix" \
  "tests/e2e/m69/t_e2e_repro_infra_os_timezone_posix_vm.nim" \
  "REPRO_M69_OS_TIMEZONE_VM"
run_m83_gate "os-hostname-posix" \
  "tests/e2e/m69/t_e2e_repro_infra_os_hostname_posix_vm.nim" \
  "REPRO_M69_OS_HOSTNAME_VM"
run_m83_gate "passwd-group" \
  "tests/e2e/m69/t_e2e_repro_infra_passwd_group_vm.nim" \
  "REPRO_M69_PASSWD_GROUP_VM"

# --- Home-scope POSIX gates -----------------------------------------------
log ""
log "------------------------------------------------------------"
log "M83 home-scope POSIX gates"
log "------------------------------------------------------------"
run_m83_gate "fs-user-file" \
  "tests/e2e/m69/t_e2e_repro_home_fs_user_file_vm.nim" \
  "REPRO_M69_FS_USER_FILE_VM"
run_m83_gate "fs-managed-block" \
  "tests/e2e/m69/t_e2e_repro_home_fs_managed_block_vm.nim" \
  "REPRO_M69_FS_MANAGED_BLOCK_VM"
run_m83_gate "env-user-path" \
  "tests/e2e/m69/t_e2e_repro_home_env_user_path_vm.nim" \
  "REPRO_M69_ENV_USER_PATH_VM"
run_m83_gate "shell-integration" \
  "tests/e2e/m69/t_e2e_repro_home_shell_integration_vm.nim" \
  "REPRO_M69_SHELL_INTEGRATION_VM"
run_m83_gate "linux-dconfkey" \
  "tests/e2e/m69/t_e2e_repro_home_linux_dconfkey_vm.nim" \
  "REPRO_M69_DCONF_KEY_VM"
run_m83_gate "linux-kdeconfigkey" \
  "tests/e2e/m69/t_e2e_repro_home_linux_kdeconfigkey_vm.nim" \
  "REPRO_M69_KDE_CONFIG_KEY_VM"
run_m83_gate "systemd-user-unit" \
  "tests/e2e/m69/t_e2e_repro_home_systemd_user_unit_vm.nim" \
  "REPRO_M69_SYSTEMD_USER_UNIT_VM"

# --- M83 cleanup belt-and-braces -------------------------------------------
# Each gate cleans up its own artifacts; this is defence in depth for
# the cases where a gate exited non-zero before reaching its destroy
# call.
for f in /etc/sysctl.d/99-reprobuild-m83-vm-test-*.conf; do
  [ -f "${f}" ] || continue; rm -f "${f}" >> "${LOG_FILE}" 2>&1 || true
done
for f in /etc/polkit-1/rules.d/99-reprobuild-m83-vm-test-*.rules; do
  [ -f "${f}" ] || continue; rm -f "${f}" >> "${LOG_FILE}" 2>&1 || true
done
for f in /etc/sudoers.d/reprobuild-m83-vm-test-*; do
  [ -f "${f}" ] || continue; rm -f "${f}" >> "${LOG_FILE}" 2>&1 || true
done
for f in /etc/tmpfiles.d/reprobuild-m83-vm-test-*.conf; do
  [ -f "${f}" ] || continue; rm -f "${f}" >> "${LOG_FILE}" 2>&1 || true
done
for f in /etc/nix/nix.conf.d/99-reprobuild-m83-vm-test-*.conf; do
  [ -f "${f}" ] || continue; rm -f "${f}" >> "${LOG_FILE}" 2>&1 || true
done
for f in /etc/systemd/system/repro-m83-vm-test-*.timer; do
  [ -f "${f}" ] || continue; rm -f "${f}" >> "${LOG_FILE}" 2>&1 || true
done
for f in /etc/udev/rules.d/99-reprobuild-m83-vm-test-*.rules; do
  [ -f "${f}" ] || continue; rm -f "${f}" >> "${LOG_FILE}" 2>&1 || true
done
# Stray groups left by a failed passwd.group gate.
for g in $(getent group | awk -F: '/^reprom83vm/ {print $1}'); do
  log "  cleanup: groupdel ${g}"
  groupdel "${g}" >> "${LOG_FILE}" 2>&1 || true
done
systemctl daemon-reload >> "${LOG_FILE}" 2>&1 || true

# ===========================================================================
# Per-gate destructive-trace inline summary
# ===========================================================================
section "Stage E - destructive-trace inline summary"
log "  passwd-cmd-trace:"
if [ -s "${PASSWD_TRACE_LOG}" ]; then
  while IFS= read -r line; do log "    ${line}"; done < "${PASSWD_TRACE_LOG}"
else
  log "    (empty)"
fi
log "  systemd-cmd-trace:"
if [ -s "${SYSTEMD_TRACE_LOG}" ]; then
  while IFS= read -r line; do log "    ${line}"; done < "${SYSTEMD_TRACE_LOG}"
else
  log "    (empty)"
fi

# Per-gate trace-summary records.
record "trace_useradd_calls"  "$(grep -cE '^\[..:..:..\] useradd ' "${PASSWD_TRACE_LOG}" 2>/dev/null || echo 0)"
record "trace_usermod_calls"  "$(grep -cE '^\[..:..:..\] usermod ' "${PASSWD_TRACE_LOG}" 2>/dev/null || echo 0)"
record "trace_userdel_calls"  "$(grep -cE '^\[..:..:..\] userdel ' "${PASSWD_TRACE_LOG}" 2>/dev/null || echo 0)"
record "trace_systemctl_calls" "$(grep -cE '^\[..:..:..\] systemctl ' "${SYSTEMD_TRACE_LOG}" 2>/dev/null || echo 0)"
record "trace_daemon_reload_calls" \
  "$(grep -cE '^\[..:..:..\] systemctl( .*)? daemon-reload' "${SYSTEMD_TRACE_LOG}" 2>/dev/null || echo 0)"

# ===========================================================================
# Stage F - verdict
# ===========================================================================
section "Stage F - verdict"
record "gate_passwd_user_exit"           "${PASSWD_EXIT}"
record "gate_fs_system_file_exit"        "${FS_EXIT}"
record "gate_env_system_variable_exit"   "${ENV_EXIT}"
record "gate_systemd_system_unit_exit"   "${SYSTEMD_EXIT}"

# Baseline M69 verdict: all four exits must be 0.
BASELINE_OK=1
for ec in "${PASSWD_EXIT}" "${FS_EXIT}" "${ENV_EXIT}" "${SYSTEMD_EXIT}"; do
  if [ "${ec}" != "0" ]; then
    BASELINE_OK=0
    break
  fi
done

# M83 step 13 verdict: each gate's binary exits 0 on either OK or
# SKIP (the SKIP path is explicit and intended — see the failure-
# resistance note in the M83 step 13 design). A binary that exits
# non-zero is a hard failure and is counted as such. We collect the
# OK / SKIP / FAIL counts from the sentinel file PLUS the
# `gateE_<name>_exit` records to spot binaries that crashed before
# writing a sentinel line.
M83_GATES_LIST=(
  "linux-sysctl|linux.sysctl"
  "linux-polkitrule|linux.polkitRule"
  "linux-sudoersrule|linux.sudoersRule"
  "linux-tmpfilesrule|linux.tmpfilesRule"
  "linux-nixdaemonsetting|linux.nixDaemonSetting"
  "systemd-system-timer|systemd.systemTimer"
  "linux-udevrule|linux.udevRule"
  "linux-firewallrule|linux.firewallRule"
  "os-timezone-posix|os.timezone (POSIX)"
  "os-hostname-posix|os.hostname (POSIX)"
  "passwd-group|passwd.group"
  "fs-user-file|fs.userFile (POSIX)"
  "fs-managed-block|fs.managedBlock (POSIX)"
  "env-user-path|env.userPath (POSIX)"
  "shell-integration|shell.integration (POSIX)"
  "linux-dconfkey|linux.dconfKey"
  "linux-kdeconfigkey|linux.kdeConfigKey"
  "systemd-user-unit|systemd.userUnit"
)

M83_OK_COUNT=0
M83_SKIP_COUNT=0
M83_FAIL_COUNT=0
M83_FAIL_NAMES=""

log ""
log "------------------------------------------------------------"
log "M83 step 13 per-gate verdict"
log "------------------------------------------------------------"
for entry in "${M83_GATES_LIST[@]}"; do
  short="${entry%%|*}"
  display="${entry##*|}"
  exit_rec="${RESULTS[gateE_${short}_exit]:-MISSING}"
  if [ "${exit_rec}" = "SOURCE-MISSING" ]; then
    log "  ${display}: SOURCE-MISSING (gate file not in repo workdir)"
    record "gateM83_${short}_verdict" "SOURCE-MISSING"
    M83_FAIL_COUNT=$((M83_FAIL_COUNT + 1))
    M83_FAIL_NAMES="${M83_FAIL_NAMES} ${display}"
    continue
  fi
  if [ "${exit_rec}" = "MISSING" ]; then
    log "  ${display}: NOT-RUN"
    record "gateM83_${short}_verdict" "NOT-RUN"
    M83_FAIL_COUNT=$((M83_FAIL_COUNT + 1))
    M83_FAIL_NAMES="${M83_FAIL_NAMES} ${display}"
    continue
  fi
  if [ "${exit_rec}" != "0" ]; then
    log "  ${display}: FAIL (exit=${exit_rec})"
    record "gateM83_${short}_verdict" "FAIL (exit=${exit_rec})"
    M83_FAIL_COUNT=$((M83_FAIL_COUNT + 1))
    M83_FAIL_NAMES="${M83_FAIL_NAMES} ${display}"
    continue
  fi
  # Exit 0 — look at the sentinel for OK vs SKIP.
  sentinel_line=$(grep -F ": ${display}" "${SENTINEL_FILE}" 2>/dev/null | tail -n1 || true)
  if [ -z "${sentinel_line}" ]; then
    # Binary exited 0 but did not write a sentinel — treat as FAIL
    # because the test path that writes the sentinel was not reached.
    log "  ${display}: NO-SENTINEL (exit 0 but no sentinel line)"
    record "gateM83_${short}_verdict" "NO-SENTINEL"
    M83_FAIL_COUNT=$((M83_FAIL_COUNT + 1))
    M83_FAIL_NAMES="${M83_FAIL_NAMES} ${display}"
    continue
  fi
  case "${sentinel_line}" in
    OK:*)
      log "  ${display}: PASS (${sentinel_line})"
      record "gateM83_${short}_verdict" "PASS"
      M83_OK_COUNT=$((M83_OK_COUNT + 1))
      ;;
    SKIP:*)
      log "  ${display}: SKIP (${sentinel_line})"
      record "gateM83_${short}_verdict" "SKIP"
      M83_SKIP_COUNT=$((M83_SKIP_COUNT + 1))
      ;;
    *)
      log "  ${display}: UNKNOWN-SENTINEL (${sentinel_line})"
      record "gateM83_${short}_verdict" "UNKNOWN-SENTINEL"
      M83_FAIL_COUNT=$((M83_FAIL_COUNT + 1))
      M83_FAIL_NAMES="${M83_FAIL_NAMES} ${display}"
      ;;
  esac
done

record "m83_gates_passed"  "${M83_OK_COUNT}"
record "m83_gates_skipped" "${M83_SKIP_COUNT}"
record "m83_gates_failed"  "${M83_FAIL_COUNT}"

if [ "${BASELINE_OK}" = "1" ] && [ "${M83_FAIL_COUNT}" -eq 0 ]; then
  finalize "PASS - all four M69 baseline gates + ${M83_OK_COUNT} M83 step-13 gates exited 0 (${M83_SKIP_COUNT} SKIPped for unsupported WSL prerequisites)."
elif [ "${BASELINE_OK}" = "1" ]; then
  finalize "FAIL - baseline M69 gates passed but ${M83_FAIL_COUNT} M83 step-13 gate(s) failed:${M83_FAIL_NAMES} (passed=${M83_OK_COUNT}, skipped=${M83_SKIP_COUNT}). See 02-<gate>-run.txt + 01-<gate>-build.log + 05-vm-gate-sentinels.txt."
else
  finalize "FAIL - one or more baseline M69 gates exited non-zero (passwd=${PASSWD_EXIT} fs=${FS_EXIT} env=${ENV_EXIT} systemd=${SYSTEMD_EXIT}); M83 step-13: passed=${M83_OK_COUNT}, skipped=${M83_SKIP_COUNT}, failed=${M83_FAIL_COUNT}${M83_FAIL_NAMES}. See 02-<gate>-run.txt + 01-<gate>-build.log."
fi

# Disarm the trap so we don't double-finalize.
trap - EXIT
exit 0
