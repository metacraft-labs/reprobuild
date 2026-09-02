#!/usr/bin/env bash
# ============================================================================
# scripts/build_apps.sh must not report success without producing binaries
# ----------------------------------------------------------------------------
# The regression this pins: a build that produced nothing — or that left the
# PREVIOUS run's binaries on disk — being taken for a build that succeeded.
# The damaging shape is not "the build broke"; it is "the build broke and
# ``build/bin/repro`` is still sitting there, executable, weeks old", because
# then a caller asking "did it succeed?" and a caller asking "is the binary
# there?" both get yes, and a change gets reported as verified without ever
# having been compiled.
#
# Pinned contract:
#
#   1. A ``nim c`` that FAILS makes the script exit non-zero, and the stale
#      binary for that entrypoint is removed rather than left to answer for a
#      build that did not happen.
#   2. A ``nim c`` that exits 0 without writing its ``--out`` target is
#      likewise a failure: the artifact check does not take the compiler's
#      word for it.
#   3. An artifact that survives from an EARLIER run — present, executable,
#      non-empty, and simply not rebuilt — fails the same way. Existence is
#      not freshness.
#   4. The loop reports every failing entrypoint, not just the first.
#   5. A missing or failing io-mon shim builder is a hard failure.
#   6. The last line of output states the verdict, so a log read through a
#      pipeline that dropped the exit status (``| tee``, ``| tail`` — neither
#      is run under ``pipefail`` outside the Justfile) still says which way
#      the build went.
#   7. ``REPRO_DEFER_SHIM_PUBLISH=1`` stays an intentional SKIP of the shim
#      publish, not a failure.
#
# The test drives the real ``scripts/build_apps.sh`` inside a throwaway
# sandbox against a fake ``nim`` and a fake io-mon shim builder, so it pins
# the script's own control flow in about a second and never invokes the Nim
# toolchain.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "${SCRIPT_DIR}/../.." && pwd )"
BUILD_APPS="${REPO_ROOT}/scripts/build_apps.sh"
SOURCE_PATHS="${REPO_ROOT}/scripts/source_paths.sh"

for required in "${BUILD_APPS}" "${SOURCE_PATHS}"; do
  if [ ! -f "${required}" ]; then
    echo "FIXTURE ERROR: missing ${required}" >&2
    exit 2
  fi
done

# The Windows arm of build_apps.sh stages clingo.dll and exits 1 when it
# cannot find one, which is a separate (and deliberate) contract. Exercising
# the artifact accounting there would require faking a clingo install too, so
# this case declares itself out of scope rather than pretending to cover it.
case "${OSTYPE:-}" in
  msys*|cygwin*|win32)
    echo "SKIP: build_apps.sh's Windows DLL staging is out of scope for this test"
    exit 0
    ;;
esac

# build_apps.sh uses ``mapfile``, so it needs bash 4+. macOS still ships 3.2 as
# /bin/bash; the dev shell supplies a current one. Drive the script with the
# interpreter running this test rather than with whatever ``bash`` PATH
# resolves to inside the sandbox, and say so plainly when that interpreter is
# too old instead of reporting the resulting 127 as a build defect.
BASH_UNDER_TEST="${BASH:-bash}"
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "SKIP: ${BASH_UNDER_TEST} is bash ${BASH_VERSION}; build_apps.sh needs bash 4+ (run inside the dev shell)"
  exit 0
fi

failures=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1" >&2; failures=$((failures + 1)); }

check() {
  # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1 (expected '$2', got '$3')"
  fi
}

SANDBOX_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/t_build_apps_reports_failure.XXXXXX")"
# KEEP_SANDBOX=1 leaves the sandboxes (and each case's run.log) in place, which
# is the only way to read what the script actually printed when a case fails.
cleanup() {
  if [ "${KEEP_SANDBOX:-0}" = "1" ]; then
    echo "sandboxes kept at ${SANDBOX_ROOT}" >&2
    return 0
  fi
  rm -rf "${SANDBOX_ROOT}"
}
trap cleanup EXIT

# ----------------------------------------------------------------------------
# Sandbox construction.
#
# Everything build_apps.sh reaches for is either copied verbatim (the two
# scripts under test) or stubbed with the smallest thing that satisfies the
# probe. No flake.nix is created: resolve_repo_source_path only shells out to
# ``nix eval`` when one is present, and this test has no business waiting on
# flake evaluation.
# ----------------------------------------------------------------------------
new_sandbox() {
  local sandbox="${SANDBOX_ROOT}/$1"
  mkdir -p \
    "${sandbox}/scripts" \
    "${sandbox}/apps/alpha" \
    "${sandbox}/apps/beta" \
    "${sandbox}/tools/reprobuild-nix-daemon" \
    "${sandbox}/libs/repro_project_dsl_runtime_dll/src" \
    "${sandbox}/deps/bearssl/bearssl/abi" \
    "${sandbox}/deps/shmqueue" \
    "${sandbox}/io-mon/scripts" \
    "${sandbox}/bin"

  cp "${BUILD_APPS}" "${sandbox}/scripts/build_apps.sh"
  cp "${SOURCE_PATHS}" "${sandbox}/scripts/source_paths.sh"

  cat > "${sandbox}/apps/entrypoints.txt" <<'ENTRYPOINTS'
# name path [extra-nim-flags...]
alpha apps/alpha/alpha.nim --define:ssl
beta apps/beta/beta.nim
ENTRYPOINTS

  echo 'discard' > "${sandbox}/apps/alpha/alpha.nim"
  echo 'discard' > "${sandbox}/apps/beta/beta.nim"
  echo 'discard' \
    > "${sandbox}/libs/repro_project_dsl_runtime_dll/src/repro_project_dsl_runtime_entry.nim"
  echo '#!/bin/sh' > "${sandbox}/tools/reprobuild-nix-daemon/reprobuild-nix-daemon"
  echo 'type Consttypes = int' > "${sandbox}/deps/bearssl/bearssl/abi/consttypes.nim"
  echo 'type ShmQueue = int' > "${sandbox}/deps/shmqueue/shm_queue.nim"

  # Fake io-mon shim builder: produces the staged library under every
  # platform extension so the sandbox does not have to agree with the host
  # about which one build_apps.sh will look for.
  cat > "${sandbox}/io-mon/scripts/build_shim.sh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
if [ "${FAKE_IO_MON_FAIL:-0}" = "1" ]; then
  echo "fake io-mon: Error: undeclared identifier: 'KillEvidence'" >&2
  exit 1
fi
mkdir -p "${IO_MON_SHIM_OUT_DIR}"
for ext in dylib so dll; do
  printf 'fake-shim\n' > "${IO_MON_SHIM_OUT_DIR}/librepro_monitor_shim.${ext}"
done
SHIM
  chmod +x "${sandbox}/io-mon/scripts/build_shim.sh"

  # Fake nim: honours --out:, and can be told to fail, or to "succeed"
  # without writing anything — which is the exact shape the artifact check
  # exists to catch.
  cat > "${sandbox}/bin/nim" <<'NIM'
#!/usr/bin/env bash
set -uo pipefail
out=""
for arg in "$@"; do
  case "${arg}" in
    --out:*) out="${arg#--out:}" ;;
  esac
done
target="$(basename "${out}")"
for skipped in ${FAKE_NIM_FAIL:-}; do
  if [ "${target}" = "${skipped}" ]; then
    echo "fake nim: ld: library not found for -lcrypto" >&2
    exit 1
  fi
done
for skipped in ${FAKE_NIM_SILENT_NOOP:-}; do
  if [ "${target}" = "${skipped}" ]; then
    # Exits 0, writes nothing. The compiler claims success; there is no
    # artifact.
    exit 0
  fi
done
mkdir -p "$(dirname "${out}")"
printf 'fake-binary\n' > "${out}"
chmod +x "${out}" 2>/dev/null || true
exit 0
NIM
  chmod +x "${sandbox}/bin/nim"

  printf '%s\n' "${sandbox}"
}

# run_build <sandbox> [VAR=VALUE ...] -> writes stdout+stderr to
# <sandbox>/run.log, echoes the exit status.
run_build() {
  local sandbox="$1"
  shift
  local status=0
  (
    cd "${sandbox}"
    env \
      PATH="${sandbox}/bin:${PATH}" \
      IO_MON_SRC="${sandbox}/io-mon" \
      BEARSSL_SRC="${sandbox}/deps/bearssl" \
      SHM_QUEUE_SRC="${sandbox}/deps/shmqueue" \
      NIX_LDFLAGS="" \
      LD_LIBRARY_PATH="" \
      CLINGO_PREFIX="" \
      ZSTD_PREFIX="" \
      "$@" \
      "${BASH_UNDER_TEST}" scripts/build_apps.sh
  ) > "${sandbox}/run.log" 2>&1 || status=$?
  printf '%s\n' "${status}"
}

nonzero() { if [ "$1" -ne 0 ]; then echo yes; else echo no; fi; }
exists() { if [ -e "$1" ]; then echo yes; else echo no; fi; }

# ----------------------------------------------------------------------------
# 1. Control: when every step really does produce its artifact, the script
#    succeeds. Without this the rest of the file could pass by being broken.
# ----------------------------------------------------------------------------
sandbox="$(new_sandbox control)"
status="$(run_build "${sandbox}")"
check "control: a build that produces everything exits 0" "0" "${status}"
check "control: build/bin/alpha exists" "yes" "$(exists "${sandbox}/build/bin/alpha")"
check "control: build/bin/beta exists" "yes" "$(exists "${sandbox}/build/bin/beta")"
check "control: the nix daemon is staged" \
  "yes" "$(exists "${sandbox}/build/bin/reprobuild-nix-daemon")"
if tail -n 1 "${sandbox}/run.log" | grep -q '^build_apps: OK'; then
  pass "control: the last line of output is the OK verdict"
else
  fail "control: the last line of output is the OK verdict (got: $(tail -n 1 "${sandbox}/run.log"))"
fi

# ----------------------------------------------------------------------------
# 2. A compiler that exits 0 without writing its --out target is a failure.
# ----------------------------------------------------------------------------
sandbox="$(new_sandbox silent_noop)"
status="$(run_build "${sandbox}" FAKE_NIM_SILENT_NOOP="alpha")"
check "silent no-op: exits non-zero" "yes" "$(nonzero "${status}")"
check "silent no-op: build/bin/alpha is absent" \
  "no" "$(exists "${sandbox}/build/bin/alpha")"
if grep -q "alpha" "${sandbox}/run.log"; then
  pass "silent no-op: the failing entrypoint is named in the output"
else
  fail "silent no-op: the failing entrypoint is named in the output"
fi

# ----------------------------------------------------------------------------
# 3. THE HEADLINE CASE. A binary left over from an earlier run must not be
#    accepted as this run's output. Existence is not freshness — and the stale
#    file is removed, so "is the binary there?" stops answering yes for a
#    binary nobody built.
# ----------------------------------------------------------------------------
sandbox="$(new_sandbox stale)"
mkdir -p "${sandbox}/build/bin"
printf 'binary from three weeks ago\n' > "${sandbox}/build/bin/alpha"
chmod +x "${sandbox}/build/bin/alpha"
touch -t 202001010000 "${sandbox}/build/bin/alpha"
status="$(run_build "${sandbox}" FAKE_NIM_SILENT_NOOP="alpha")"
check "stale artifact: exits non-zero" "yes" "$(nonzero "${status}")"
check "stale artifact: the stale build/bin/alpha is removed" \
  "no" "$(exists "${sandbox}/build/bin/alpha")"
if grep -qi "stale\|predates" "${sandbox}/run.log"; then
  pass "stale artifact: the diagnostic says the artifact predates the run"
else
  fail "stale artifact: the diagnostic says the artifact predates the run"
fi

# ----------------------------------------------------------------------------
# 4. A genuine compile/link failure fails the build and takes the stale binary
#    with it — and the loop keeps going, so BOTH failures are reported.
# ----------------------------------------------------------------------------
sandbox="$(new_sandbox link_failure)"
mkdir -p "${sandbox}/build/bin"
for leftover in alpha beta; do
  printf 'binary from three weeks ago\n' > "${sandbox}/build/bin/${leftover}"
  chmod +x "${sandbox}/build/bin/${leftover}"
  touch -t 202001010000 "${sandbox}/build/bin/${leftover}"
done
status="$(run_build "${sandbox}" FAKE_NIM_FAIL="alpha beta")"
check "link failure: exits non-zero" "yes" "$(nonzero "${status}")"
check "link failure: the stale build/bin/alpha is removed" \
  "no" "$(exists "${sandbox}/build/bin/alpha")"
check "link failure: the stale build/bin/beta is removed" \
  "no" "$(exists "${sandbox}/build/bin/beta")"
reported="$(grep -c '^build_apps: FAILED: ' "${sandbox}/run.log" || true)"
check "link failure: both failing entrypoints are reported, not just the first" \
  "2" "${reported}"

# ----------------------------------------------------------------------------
# 5. The verdict survives a pipeline that drops the exit status. This is how
#    the failure was missed: a build read through ``| tail`` in a shell with
#    no pipefail reports tail's zero, so the LOG has to say it too.
# ----------------------------------------------------------------------------
sandbox="$(new_sandbox pipeline)"
piped_status=0
(
  cd "${sandbox}"
  set +o pipefail
  env \
    PATH="${sandbox}/bin:${PATH}" \
    IO_MON_SRC="${sandbox}/io-mon" \
    BEARSSL_SRC="${sandbox}/deps/bearssl" \
    SHM_QUEUE_SRC="${sandbox}/deps/shmqueue" \
    NIX_LDFLAGS="" \
    FAKE_NIM_SILENT_NOOP="alpha" \
    "${BASH_UNDER_TEST}" scripts/build_apps.sh 2>&1 | tail -n 40 > "${sandbox}/piped.log"
) || piped_status=$?
check "pipeline: the swallowed exit status really is 0 (the trap that was set)" \
  "0" "${piped_status}"
if grep -q '^build_apps: FAILED' "${sandbox}/piped.log"; then
  pass "pipeline: the log still states the build FAILED"
else
  fail "pipeline: the log still states the build FAILED"
fi

# ----------------------------------------------------------------------------
# 6/7. The io-mon shim is a hard prerequisite: missing builder, or a builder
#      that fails, must both stop the build.
# ----------------------------------------------------------------------------
sandbox="$(new_sandbox io_mon_missing)"
rm -rf "${sandbox}/io-mon"
status="$(run_build "${sandbox}")"
check "missing io-mon builder: exits non-zero" "yes" "$(nonzero "${status}")"
check "missing io-mon builder: no binary is produced" \
  "no" "$(exists "${sandbox}/build/bin/alpha")"

sandbox="$(new_sandbox io_mon_broken)"
status="$(run_build "${sandbox}" FAKE_IO_MON_FAIL=1)"
check "failing io-mon builder: exits non-zero" "yes" "$(nonzero "${status}")"
check "failing io-mon builder: no binary is produced" \
  "no" "$(exists "${sandbox}/build/bin/alpha")"
if grep -q "io-mon" "${sandbox}/run.log"; then
  pass "failing io-mon builder: the diagnostic names io-mon, not reprobuild"
else
  fail "failing io-mon builder: the diagnostic names io-mon, not reprobuild"
fi

# ----------------------------------------------------------------------------
# 8. Intentional skips stay skips. REPRO_DEFER_SHIM_PUBLISH=1 hands the publish
#    to a follow-up edge; the run must still succeed with the shim staged but
#    unpublished. Hardening the failure paths must not turn this into an error.
# ----------------------------------------------------------------------------
sandbox="$(new_sandbox deferred_publish)"
status="$(run_build "${sandbox}" REPRO_DEFER_SHIM_PUBLISH=1)"
check "deferred shim publish: still exits 0" "0" "${status}"
if ls "${sandbox}/build/lib/tmp/"librepro_monitor_shim.* >/dev/null 2>&1; then
  pass "deferred shim publish: the staged shim is kept"
else
  fail "deferred shim publish: the staged shim is kept"
fi
check "deferred shim publish: alpha is still built" \
  "yes" "$(exists "${sandbox}/build/bin/alpha")"

echo ""
if [ "${failures}" -ne 0 ]; then
  echo "${failures} check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
