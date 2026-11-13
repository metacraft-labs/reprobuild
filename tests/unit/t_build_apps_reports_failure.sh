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
#      binary for that entrypoint no longer sits at ``build/bin/<name>`` to
#      answer for a build that did not happen. It is not destroyed either: it
#      is set aside, byte-for-byte, as ``build/bin/<name>.stale``, because a
#      failure from outside the tree (a stale sibling checkout, say) must not
#      cost the developer the tool that worked a minute earlier. A newer
#      set-aside replaces an older one; with nothing to set aside, an existing
#      ``.stale`` is left alone; a successful build removes it, so packaging
#      that copies ``build/bin/*`` never ships one. Only a PREVIOUS build is
#      set aside: an artifact the failing step wrote itself is removed, so it
#      cannot replace the last good ``.stale``. The DSL runtime library
#      follows the same rule.
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
#   8. Both entrypoints and the DSL library receive exactly one requested
#      --parallelBuild value, with unset/empty/0 retaining automatic mode.
#      This stub observes argv only; it does not claim real C-job containment.
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
# ``build_apps.sh`` sources these two before it does anything, so the sandbox
# has to carry them: the loader-inertness library it uses to refuse a monitor
# shim that imposes a C runtime, and the dev-shell library that one falls back
# to for the glibc symbol-version readers. Copied verbatim, like the two
# scripts under test — a stub would let the sandbox disagree with the code that
# ships about when a shim is refused.
PRELOADED_SHIM_LOADER="${REPO_ROOT}/scripts/lib/preloaded_shim_loader.sh"
DEV_SHELL_OVERRIDES="${REPO_ROOT}/scripts/lib/dev_shell_overrides.sh"
# The non-Windows arm stages the nix daemon helper through this script, so a
# sandbox without it fails every run with python3's exit 2 before the parts
# under test are reached. Copied verbatim for the same reason as the others.
STAGE_NIX_DAEMON="${REPO_ROOT}/scripts/stage_nix_daemon.py"
# ``build_apps.sh`` asks this script for the source revision it embeds, and
# stops when it cannot run it. Copied verbatim for the same reason. The
# sandbox is not a git work tree, so it reports the revision unknown and the
# fake ``nim`` sees no ``-d:ReprobuildSourceRevision=`` define.
SOURCE_REVISION="${REPO_ROOT}/scripts/source_revision.sh"

for required in "${BUILD_APPS}" "${SOURCE_PATHS}" \
  "${PRELOADED_SHIM_LOADER}" "${DEV_SHELL_OVERRIDES}" \
  "${STAGE_NIX_DAEMON}" "${SOURCE_REVISION}"; do
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
    "${sandbox}/scripts/lib" \
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
  cp "${PRELOADED_SHIM_LOADER}" "${sandbox}/scripts/lib/preloaded_shim_loader.sh"
  cp "${DEV_SHELL_OVERRIDES}" "${sandbox}/scripts/lib/dev_shell_overrides.sh"
  cp "${STAGE_NIX_DAEMON}" "${sandbox}/scripts/stage_nix_daemon.py"
  cp "${SOURCE_REVISION}" "${sandbox}/scripts/source_revision.sh"

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
parallel_count=0
parallel_value=""
for arg in "$@"; do
  case "${arg}" in
    --out:*) out="${arg#--out:}" ;;
    --parallelBuild:*)
      parallel_count=$((parallel_count + 1))
      parallel_value="${arg#--parallelBuild:}"
      ;;
  esac
done
target="$(basename "${out}")"
if [ -n "${FAKE_NIM_PARALLEL_LOG:-}" ]; then
  printf '%s\t%s\t%s\n' "${target}" "${parallel_count}" "${parallel_value}" \
    >> "${FAKE_NIM_PARALLEL_LOG}"
fi
if [ -n "${FAKE_NIM_EXPECT_PARALLEL_BUILD:-}" ] && \
    { [ "${parallel_count}" -ne 1 ] || \
      [ "${parallel_value}" != "${FAKE_NIM_EXPECT_PARALLEL_BUILD}" ]; }; then
  echo "fake nim: missing, duplicated or incorrect compiler worker request" >&2
  exit 3
fi
for skipped in ${FAKE_NIM_FAIL:-}; do
  if [ "${target}" = "${skipped}" ]; then
    echo "fake nim: ld: library not found for -lcrypto" >&2
    exit 1
  fi
done
for skipped in ${FAKE_NIM_PARTIAL_FAIL:-}; do
  if [ "${target}" = "${skipped}" ]; then
    # Writes a truncated artifact and then fails, as a link cut short by a
    # full disk does.
    mkdir -p "$(dirname "${out}")"
    printf 'trunc' > "${out}"
    echo "fake nim: ld: write failed: No space left on device" >&2
    exit 1
  fi
done
for skipped in ${FAKE_NIM_EMPTY:-}; do
  if [ "${target}" = "${skipped}" ]; then
    # Exits 0 having written an empty artifact.
    mkdir -p "$(dirname "${out}")"
    : > "${out}"
    exit 0
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
executable() { if [ -x "$1" ]; then echo yes; else echo no; fi; }
# The file's bytes, or a marker that cannot collide with any fixture content
# when it is missing — so a "contents equal" check also fails on absence.
contents() { if [ -f "$1" ]; then cat "$1"; else echo '<missing>'; fi; }

# The DSL runtime library's platform extension, mirroring build_apps.sh's own
# host detection closely enough for the hosts this test runs on (Windows is
# skipped above).
case "$(uname -s)" in
  Darwin) dsl_ext="dylib" ;;
  *) dsl_ext="so" ;;
esac

# Worker forwarding is checked through the real complete producer, not a
# copied argument builder. The existing compiler stub requires and records
# each invocation, so omitting the flag from either producer arm is red.
for request in unset empty 0 1 2; do
  sandbox="$(new_sandbox "workers_${request}")"
  expected="${request}"
  case "${request}" in
    unset|empty) expected=0 ;;
  esac
  log="${sandbox}/parallel.log"
  if [ "${request}" = unset ]; then
    status="$(unset NIX_BUILD_CORES; run_build "${sandbox}" \
      FAKE_NIM_EXPECT_PARALLEL_BUILD="${expected}" FAKE_NIM_PARALLEL_LOG="${log}")"
  elif [ "${request}" = empty ]; then
    status="$(run_build "${sandbox}" NIX_BUILD_CORES= \
      FAKE_NIM_EXPECT_PARALLEL_BUILD="${expected}" FAKE_NIM_PARALLEL_LOG="${log}")"
  else
    status="$(run_build "${sandbox}" NIX_BUILD_CORES="${request}" \
      FAKE_NIM_EXPECT_PARALLEL_BUILD="${expected}" FAKE_NIM_PARALLEL_LOG="${log}")"
  fi
  check "workers ${request}: complete producer succeeds" 0 "${status}"
  check "workers ${request}: all three compiler calls recorded" 3 \
    "$(wc -l < "${log}" | tr -d '[:space:]')"
  for target in alpha beta "librepro_project_dsl_runtime.new.${dsl_ext}"; do
    count="$(grep -Fxc "$(printf '%s\t1\t%s' "${target}" "${expected}")" "${log}" || true)"
    check "workers ${request}: ${target} receives exactly the requested flag" 1 "${count}"
  done
done

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
#    file is moved off its canonical name, so "is the binary there?" stops
#    answering yes for a binary nobody built, while the old build stays
#    runnable as build/bin/alpha.stale.
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
check "stale artifact: the stale binary is kept byte-for-byte as build/bin/alpha.stale" \
  "binary from three weeks ago" "$(contents "${sandbox}/build/bin/alpha.stale")"
if grep -qi "stale\|predates" "${sandbox}/run.log"; then
  pass "stale artifact: the diagnostic says the artifact predates the run"
else
  fail "stale artifact: the diagnostic says the artifact predates the run"
fi

# ----------------------------------------------------------------------------
# 4. A genuine compile/link failure fails the build and moves the stale binary
#    off its canonical name (keeping it as .stale) — and the loop keeps going,
#    so BOTH failures are reported.
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
check "link failure: the stale alpha is kept byte-for-byte as build/bin/alpha.stale" \
  "binary from three weeks ago" "$(contents "${sandbox}/build/bin/alpha.stale")"
check "link failure: the stale beta is kept byte-for-byte as build/bin/beta.stale" \
  "binary from three weeks ago" "$(contents "${sandbox}/build/bin/beta.stale")"
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

# ----------------------------------------------------------------------------
# 9. THE ISSUE SCENARIO. A previous run produced a working build; a later
#    rebuild of one entrypoint fails for a reason outside the tree. The build
#    still fails and build/bin/alpha is gone, but the working binary survives,
#    still executable, as build/bin/alpha.stale — and the diagnostic says so.
# ----------------------------------------------------------------------------
sandbox="$(new_sandbox last_good)"
status="$(run_build "${sandbox}")"
check "last good: the first build succeeds" "0" "${status}"
cp "${sandbox}/build/bin/alpha" "${sandbox}/last_good_alpha"
status="$(run_build "${sandbox}" FAKE_NIM_FAIL="alpha")"
check "last good: the failing rebuild exits non-zero" "yes" "$(nonzero "${status}")"
check "last good: build/bin/alpha is absent after the failed rebuild" \
  "no" "$(exists "${sandbox}/build/bin/alpha")"
check "last good: build/bin/alpha.stale holds the previous working build" \
  "$(contents "${sandbox}/last_good_alpha")" "$(contents "${sandbox}/build/bin/alpha.stale")"
check "last good: build/bin/alpha.stale is still executable" \
  "yes" "$(executable "${sandbox}/build/bin/alpha.stale")"
check "last good: beta, which did build, has no .stale copy" \
  "no" "$(exists "${sandbox}/build/bin/beta.stale")"
if grep -q 'alpha:.*kept the previous build as build/bin/alpha\.stale' "${sandbox}/run.log"; then
  pass "last good: the diagnostic names build/bin/alpha.stale"
else
  fail "last good: the diagnostic names build/bin/alpha.stale"
fi
if grep -q 'removed the stale' "${sandbox}/run.log"; then
  fail "last good: the diagnostic no longer claims the binary was removed"
else
  pass "last good: the diagnostic no longer claims the binary was removed"
fi

# ----------------------------------------------------------------------------
# 10. An older .stale and a newer binary both exist and the build fails: the
#     newer binary replaces the older set-aside, so .stale is always the most
#     recent build there was.
# ----------------------------------------------------------------------------
sandbox="$(new_sandbox stale_replaced)"
mkdir -p "${sandbox}/build/bin"
printf 'older set-aside build\n' > "${sandbox}/build/bin/alpha.stale"
printf 'newer build\n' > "${sandbox}/build/bin/alpha"
chmod +x "${sandbox}/build/bin/alpha" "${sandbox}/build/bin/alpha.stale"
touch -t 202001010000 "${sandbox}/build/bin/alpha" "${sandbox}/build/bin/alpha.stale"
status="$(run_build "${sandbox}" FAKE_NIM_FAIL="alpha")"
check "newer replaces older .stale: exits non-zero" "yes" "$(nonzero "${status}")"
check "newer replaces older .stale: build/bin/alpha is absent" \
  "no" "$(exists "${sandbox}/build/bin/alpha")"
check "newer replaces older .stale: build/bin/alpha.stale holds the newer build" \
  "newer build" "$(contents "${sandbox}/build/bin/alpha.stale")"

# ----------------------------------------------------------------------------
# 11. A .stale exists with no current binary (an earlier failed run already
#     set it aside) and the build fails again: there is nothing newer to keep,
#     so the existing .stale is left exactly as it was.
# ----------------------------------------------------------------------------
sandbox="$(new_sandbox stale_untouched)"
mkdir -p "${sandbox}/build/bin"
printf 'set aside by an earlier failed run\n' > "${sandbox}/build/bin/alpha.stale"
chmod +x "${sandbox}/build/bin/alpha.stale"
touch -t 202001010000 "${sandbox}/build/bin/alpha.stale"
cp -p "${sandbox}/build/bin/alpha.stale" "${sandbox}/expected_stale"
status="$(run_build "${sandbox}" FAKE_NIM_FAIL="alpha")"
check "lone .stale: exits non-zero" "yes" "$(nonzero "${status}")"
check "lone .stale: build/bin/alpha is absent" \
  "no" "$(exists "${sandbox}/build/bin/alpha")"
check "lone .stale: build/bin/alpha.stale is untouched" \
  "$(contents "${sandbox}/expected_stale")" "$(contents "${sandbox}/build/bin/alpha.stale")"
if [ "${sandbox}/build/bin/alpha.stale" -nt "${sandbox}/expected_stale" ] ||
   [ "${sandbox}/build/bin/alpha.stale" -ot "${sandbox}/expected_stale" ]; then
  fail "lone .stale: build/bin/alpha.stale keeps its timestamp"
else
  pass "lone .stale: build/bin/alpha.stale keeps its timestamp"
fi
if grep -q 'alpha:.*no previous build was present' "${sandbox}/run.log"; then
  pass "lone .stale: the diagnostic says no previous build was present"
else
  fail "lone .stale: the diagnostic says no previous build was present"
fi

# ----------------------------------------------------------------------------
# 12. A leftover .stale and a build that succeeds: the .stale is removed, so a
#     green build leaves nothing for a ``cp build/bin/*`` packaging step to
#     ship by accident.
# ----------------------------------------------------------------------------
sandbox="$(new_sandbox stale_cleared)"
mkdir -p "${sandbox}/build/bin" "${sandbox}/build/lib"
printf 'set aside by an earlier failed run\n' > "${sandbox}/build/bin/alpha.stale"
printf 'set aside by an earlier failed run\n' > "${sandbox}/build/bin/alpha.exe.stale"
printf 'set aside by an earlier failed run\n' \
  > "${sandbox}/build/lib/librepro_project_dsl_runtime.${dsl_ext}.stale"
status="$(run_build "${sandbox}")"
check "success clears .stale: exits 0" "0" "${status}"
check "success clears .stale: build/bin/alpha is the fresh build" \
  "fake-binary" "$(contents "${sandbox}/build/bin/alpha")"
check "success clears .stale: build/bin/alpha.stale is removed" \
  "no" "$(exists "${sandbox}/build/bin/alpha.stale")"
check "success clears .stale: build/bin/alpha.exe.stale is removed" \
  "no" "$(exists "${sandbox}/build/bin/alpha.exe.stale")"
check "success clears .stale: the DSL runtime library's .stale is removed" \
  "no" "$(exists "${sandbox}/build/lib/librepro_project_dsl_runtime.${dsl_ext}.stale")"
if ls "${sandbox}/build/bin/"*.stale >/dev/null 2>&1; then
  fail "success clears .stale: no *.stale is left in build/bin"
else
  pass "success clears .stale: no *.stale is left in build/bin"
fi

# ----------------------------------------------------------------------------
# 13. The DSL runtime library follows the same rule: when its compile fails,
#     the previously published library is set aside as .stale rather than
#     deleted, and the canonical name no longer answers for it.
# ----------------------------------------------------------------------------
sandbox="$(new_sandbox dsl_runtime_failure)"
mkdir -p "${sandbox}/build/lib"
dsl_lib="${sandbox}/build/lib/librepro_project_dsl_runtime.${dsl_ext}"
printf 'library from three weeks ago\n' > "${dsl_lib}"
touch -t 202001010000 "${dsl_lib}"
status="$(run_build "${sandbox}" \
  FAKE_NIM_FAIL="librepro_project_dsl_runtime.new.${dsl_ext}")"
check "DSL runtime failure: exits non-zero" "yes" "$(nonzero "${status}")"
check "DSL runtime failure: the canonical library is absent" \
  "no" "$(exists "${dsl_lib}")"
check "DSL runtime failure: the previous library is kept byte-for-byte as .stale" \
  "library from three weeks ago" "$(contents "${dsl_lib}.stale")"
if grep -q "librepro_project_dsl_runtime:.*kept the previous build as build/lib/librepro_project_dsl_runtime\.${dsl_ext}\.stale" "${sandbox}/run.log"; then
  pass "DSL runtime failure: the diagnostic names the .stale path"
else
  fail "DSL runtime failure: the diagnostic names the .stale path"
fi

# ----------------------------------------------------------------------------
# 14. Only a PREVIOUS build is set aside. When the failing step itself writes
#     the artifact (a truncated link, or an empty output the freshness check
#     refuses), that file is not a build worth keeping: it is removed, and the
#     last good .stale from an earlier failed run survives untouched instead
#     of being replaced by it.
# ----------------------------------------------------------------------------
for mode in FAKE_NIM_PARTIAL_FAIL FAKE_NIM_EMPTY; do
  sandbox="$(new_sandbox "own_output_${mode}")"
  mkdir -p "${sandbox}/build/bin"
  printf 'last good build\n' > "${sandbox}/build/bin/alpha.stale"
  chmod +x "${sandbox}/build/bin/alpha.stale"
  status="$(run_build "${sandbox}" "${mode}=alpha")"
  check "own output (${mode}): exits non-zero" "yes" "$(nonzero "${status}")"
  check "own output (${mode}): build/bin/alpha is absent" \
    "no" "$(exists "${sandbox}/build/bin/alpha")"
  check "own output (${mode}): the last good .stale is not replaced" \
    "last good build" "$(contents "${sandbox}/build/bin/alpha.stale")"
  if grep -q 'alpha:.*removed build/bin/alpha, which the failed step itself wrote' "${sandbox}/run.log"; then
    pass "own output (${mode}): the diagnostic says the failed step's output was removed"
  else
    fail "own output (${mode}): the diagnostic says the failed step's output was removed"
  fi
  if grep -q 'alpha:.*kept the previous build' "${sandbox}/run.log"; then
    fail "own output (${mode}): the diagnostic does not claim a previous build was kept"
  else
    pass "own output (${mode}): the diagnostic does not claim a previous build was kept"
  fi
done

echo ""
if [ "${failures}" -ne 0 ]; then
  echo "${failures} check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
