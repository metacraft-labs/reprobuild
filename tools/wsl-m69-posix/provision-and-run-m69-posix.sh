#!/usr/bin/env bash
#
# provision-and-run-m69-posix.sh - runs INSIDE a throwaway Ubuntu 22.04
# WSL distro to exercise the M69 Linux destructive gate:
#
#   tests/e2e/m69/t_e2e_repro_infra_passwd_user_safe_destroy.nim
#
# The non-destructive halves of the gate already pass on every host;
# this script's job is the real-mutation half (real useradd / usermod /
# userdel against a sandboxed account). The script:
#
#   Stage A - install C toolchain (gcc + libsqlite3-dev + curl + xz-utils)
#   Stage B - download + extract Nim 2.2.8 to /opt/nim-2.2.8
#   Stage C - copy the repo source out of the read-only /mnt/d/ mount
#             into a writable workdir at /work/reprobuild (and the
#             sibling runquota repo at /work/runquota)
#   Stage D - nim c -r the gate, with REPRO_M69_PASSWD_VM=1 set
#   Stage E - copy logs + RESULT.txt to the OUTPUT folder, write DONE
#
# Inputs (env, set by the host-side runner via `wsl --exec env ...`):
#   REPRO_HOST_OUT_DIR   - host OUTPUT dir, e.g. /mnt/d/metacraft/wsl-m69-posix-out
#   REPRO_HOST_REPO_DIR  - host repo dir,  e.g. /mnt/d/metacraft/reprobuild
#   REPRO_HOST_RUNQUOTA  - host sibling,   e.g. /mnt/d/metacraft/runquota
#   REPRO_HOST_NIM_TAR   - cached Nim tarball, e.g. /mnt/d/metacraft/wsl-m69-posix-cache/nim-2.2.8-linux_x64.tar.xz
#
# Output to ${REPRO_HOST_OUT_DIR}:
#   00-provision.log    - stage-by-stage provisioning log
#   01-gate-build.log   - gate compile log
#   02-gate-run.txt     - gate stdout/stderr + exit code
#   RESULT.txt          - per-stage status + verdict
#   DONE                - sentinel (written last)
#
# This script's exit code is informational; the host runner reads
# DONE + RESULT.txt for the real verdict. The script never aborts on
# an individual stage failure - it records the failure and pushes on,
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
      printf '%-32s %s\n' "$k" "${RESULTS[$k]}"
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

log "M69 POSIX destructive-gate WSL harness starting."
log "OUT_DIR        = ${OUT_DIR}"
log "REPO_HOST      = ${REPO_HOST}"
log "RUNQUOTA_HOST  = ${RUNQUOTA_HOST}"
log "NIM_TAR        = ${NIM_TAR}"
log "running as: $(id -u -n) (uid=$(id -u))"

# Top-level trap: ensure RESULT.txt + DONE always exist, even on
# unexpected exit. If finalize already wrote them, this is a no-op.
trap '[ -f "${OUT_DIR}/DONE" ] || finalize "ERROR - script exited unexpectedly"' EXIT

# ===========================================================================
# Stage A - apt-install C toolchain + libsqlite3 + curl + xz
# ===========================================================================
section "Stage A - apt-install gcc, libsqlite3-dev, curl, xz-utils"
export DEBIAN_FRONTEND=noninteractive
# The rootfs ships without an updated apt cache; refresh once.
{
  apt-get update -y -qq 2>&1
  apt-get install -y --no-install-recommends \
    ca-certificates curl xz-utils gcc libc6-dev libsqlite3-dev passwd \
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
  # top-level exclusion is robust and dependency-free. The excludes
  # arg is a space-separated list of top-level NAMES (e.g.
  # 'build .git target references/llvm-project').
  #
  # We can't pass a "deep" exclude to cp; for nested excludes we
  # copy the parent excluding the deep child, then re-add siblings.
  # For simplicity here: top-level NAMES only, plus the well-known
  # heavy subtrees inside references/ that we DO copy
  # (third-party/blake3 + third-party/xxhash) - other references/*
  # sub-trees are explicitly excluded by name.
  (cd "${src}" && find . -mindepth 1 -maxdepth 1 \
      ! -name 'build' ! -name '.git' ! -name 'target' \
      ! -name 'bench-results' ! -name 'test-logs' \
      ! -name 'references' \
      -exec cp -a -t "${dst}" -- {} +) >> "${LOG_FILE}" 2>&1
  local cp_status=$?
  # Pull in only the vendored hash headers/c that config.nims actually
  # needs - that is references/mold/third-party/{blake3,xxhash}/. Skip
  # everything else under references/ (llvm-project alone is 2.5 GB).
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
# runquota is small (~50 MB); no special exclusion needed beyond build/.git.
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

# Size sanity check.
if [ "${C_REPO}" -eq 0 ] \
   && [ -f "${REPO_WORK}/tests/e2e/m69/t_e2e_repro_infra_passwd_user_safe_destroy.nim" ]; then
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
# Stage D - build + run the gate (one nim c -r invocation)
# ===========================================================================
section "Stage D - build + run the M69 passwd.user gate"
export REPRO_M69_PASSWD_VM=1

if [ ! -x "${NIM_BIN}" ] || [ ! -d "${REPO_WORK}" ]; then
  record "stageD_gate_exit"    "PRE-FAIL - missing nim or workdir"
  GATE_EXIT=255
else
  BUILD_LOG="${OUT_DIR}/01-gate-build.log"
  RUN_OUT="${OUT_DIR}/02-gate-run.txt"
  TRACE_LOG="${OUT_DIR}/03-passwd-cmd-trace.log"
  : > "${BUILD_LOG}"
  : > "${RUN_OUT}"
  : > "${TRACE_LOG}"

  # --- Verification shim: wrap useradd / usermod / userdel so we can
  # PROVE the gate's destructive path really shelled out to them.
  # The shim logs argv to ${TRACE_LOG} and forwards to the real binary
  # (renamed to <name>.real). Without this, a `[OK]` from the test
  # could in principle come from a misconfigured else-branch that
  # silently no-ops. After the gate runs we assert the trace log
  # contains a real useradd AND a real userdel call.
  log "  installing useradd/usermod/userdel verification shims:"
  for bin in useradd usermod userdel; do
    real="/usr/sbin/${bin}"
    if [ -x "${real}" ] && [ ! -x "${real}.real" ]; then
      cp -a "${real}" "${real}.real"
    fi
    # Write the shim. The HOST file path the gate sees is /usr/sbin/<bin>.
    cat > "${real}" <<SHIM
#!/bin/bash
echo "[\$(date -u +%H:%M:%S)] ${bin} \$@" >> ${TRACE_LOG}
exec ${real}.real "\$@"
SHIM
    chmod +x "${real}"
    log "    ${real} -> ${real}.real (shimmed)"
  done

  log "  REPRO_M69_PASSWD_VM=1"
  log "  cd ${REPO_WORK} && nim c -r ..."
  pushd "${REPO_WORK}" >/dev/null || true

  # Build first, so the build log and the run log are separable.
  "${NIM_BIN}" c \
      --hints:off \
      --warning:UnusedImport:off \
      --warning:CaseTransition:off \
      --threads:on \
      --nimcache:/tmp/m69-passwd-nimcache \
      --out:/tmp/m69-passwd-gate \
      tests/e2e/m69/t_e2e_repro_infra_passwd_user_safe_destroy.nim \
      > "${BUILD_LOG}" 2>&1
  BUILD_EXIT=$?
  log "  nim c exit=${BUILD_EXIT}"
  record "stageD_build_exit"   "${BUILD_EXIT}"

  if [ "${BUILD_EXIT}" -eq 0 ] && [ -x /tmp/m69-passwd-gate ]; then
    # We are running as root inside the throwaway distro; the gate's
    # real-mutation scenario expects root (useradd is root-only).
    log "  ./m69-passwd-gate    (REPRO_M69_PASSWD_VM=1)"
    {
      echo "COMMAND: /tmp/m69-passwd-gate"
      echo "ENV: REPRO_M69_PASSWD_VM=1"
      echo "USER: $(id -u -n) (uid=$(id -u))"
      echo "DISTRO: $(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")"
      echo ""
      echo "----- STDOUT + STDERR -----"
    } >> "${RUN_OUT}"
    /tmp/m69-passwd-gate >> "${RUN_OUT}" 2>&1
    GATE_EXIT=$?
    {
      echo ""
      echo "----- END -----"
      echo "EXIT CODE: ${GATE_EXIT}"
    } >> "${RUN_OUT}"
    log "  gate exit=${GATE_EXIT}"
    record "stageD_gate_exit"  "${GATE_EXIT}"

    # --- Verify the trace log: real useradd AND real userdel ran ----
    log "  verifying useradd/userdel were actually invoked (trace log):"
    if [ -s "${TRACE_LOG}" ]; then
      # Show the trace inline for the report.
      while IFS= read -r line; do log "    trace: ${line}"; done < "${TRACE_LOG}"
    else
      log "    trace: (empty)"
    fi
    trace_useradd=$(grep -c '^\[..:..:..\] useradd ' "${TRACE_LOG}" || true)
    trace_userdel=$(grep -c '^\[..:..:..\] userdel ' "${TRACE_LOG}" || true)
    record "stageD_trace_useradd_calls" "${trace_useradd}"
    record "stageD_trace_userdel_calls" "${trace_userdel}"
    if [ "${trace_useradd}" -ge 1 ] && [ "${trace_userdel}" -ge 1 ]; then
      record "stageD_destructive_verified" "YES (useradd=${trace_useradd}, userdel=${trace_userdel})"
    else
      record "stageD_destructive_verified" "NO (useradd=${trace_useradd}, userdel=${trace_userdel}) - gate may have skipped the destructive branch"
    fi
  else
    log "  BUILD FAILED - see 01-gate-build.log"
    record "stageD_gate_exit"  "BUILD-FAILED"
    GATE_EXIT=255
  fi
  popd >/dev/null || true
fi

# Defense in depth: make sure no test user is left behind in the
# distro's /etc/passwd. The distro will be unregistered shortly, so
# this is belt-and-braces only - the gate itself should already clean
# up via runInfraApply destroy, but a failed gate run might leave a
# user named `reprotest*`. We try to delete it; failure is non-fatal.
log "Stage D cleanup - removing any stray reprotest* accounts:"
for u in $(getent passwd | awk -F: '/^reprotest/ {print $1}'); do
  log "  userdel -r ${u}"
  userdel -r "${u}" >> "${LOG_FILE}" 2>&1 || true
done

# ===========================================================================
# Stage E - verdict
# ===========================================================================
section "Stage E - verdict"
if [ "${GATE_EXIT}" = "0" ]; then
  finalize "PASS - gate exited 0 inside the throwaway WSL distro."
else
  finalize "FAIL - gate exited ${GATE_EXIT} - see 02-gate-run.txt and 01-gate-build.log."
fi

# Disarm the trap so we don't double-finalize.
trap - EXIT
exit 0
