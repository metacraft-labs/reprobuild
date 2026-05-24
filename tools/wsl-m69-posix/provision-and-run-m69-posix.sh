#!/usr/bin/env bash
#
# provision-and-run-m69-posix.sh - runs INSIDE a throwaway Ubuntu 22.04
# WSL distro to exercise the FOUR M69 Linux destructive gates:
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
# The non-destructive halves of every gate already pass on every host;
# this script's job is the real-mutation half for all four in ONE
# distro session. The script:
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
# ===========================================================================
section "Stage A - apt-install gcc, libsqlite3-dev, curl, xz-utils, systemd"
export DEBIAN_FRONTEND=noninteractive
# The rootfs ships without an updated apt cache; refresh once.
# `systemd` brings the `systemctl` binary the systemd.systemUnit gate
# needs even when systemd is NOT PID 1 - daemon-reload and `systemctl
# show` parse from the unit file on disk regardless. We do NOT
# activate systemd-as-PID-1 in this harness; the gate is scoped to
# the file-on-disk + daemon-reload path per its header.
{
  apt-get update -y -qq 2>&1
  apt-get install -y --no-install-recommends \
    ca-certificates curl xz-utils gcc libc6-dev libsqlite3-dev passwd \
    systemd \
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

# Size sanity check + assert every gate source is present.
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
  env -i \
    PATH="${PATH}" \
    HOME="${HOME:-/root}" \
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

ALL_OK=1
for ec in "${PASSWD_EXIT}" "${FS_EXIT}" "${ENV_EXIT}" "${SYSTEMD_EXIT}"; do
  if [ "${ec}" != "0" ]; then
    ALL_OK=0
    break
  fi
done

if [ "${ALL_OK}" = "1" ]; then
  finalize "PASS - all four M69 Linux destructive gates exited 0 inside the throwaway WSL distro."
else
  finalize "FAIL - one or more gates exited non-zero (passwd=${PASSWD_EXIT} fs=${FS_EXIT} env=${ENV_EXIT} systemd=${SYSTEMD_EXIT}) - see 02-<gate>-run.txt + 01-<gate>-build.log."
fi

# Disarm the trap so we don't double-finalize.
trap - EXIT
exit 0
