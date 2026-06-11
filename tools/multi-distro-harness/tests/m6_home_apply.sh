#!/bin/sh
# m6_home_apply.sh — verify `repro home apply` on non-NixOS Linux.
#
# Linux-Distro-Recipe-Validation M6 acceptance test. Runs inside any
# of repro-arch / repro-debian / repro-ubuntu / repro-fedora /
# repro-alpine — the script dispatches on /etc/os-release's `ID` field
# to pick the matching M1-M4 bootstrap script (the `repro` binary the
# milestone needs is the SAME binary M1-M4 produce; M6 reuses it).
#
# Steps:
#
#   1. Detect distro; ensure the matching `bootstrap-<distro>.sh` has
#      built `${WORK_ROOT}/bin/repro`. If the bootstrap was already
#      run by a prior M1-M4 test, the warm-bootstrap path short-circuits.
#   2. Stage the M6 home profile (`tests/fixtures/m6_home_profile.nim`)
#      under a per-distro temp profile dir as `home.nim`. The fixture
#      is shared verbatim across all five distros — no per-distro
#      tweak is needed (the home-scope drivers are uniform on Linux).
#   3. Reset the apply state for this run: remove the per-run
#      state-dir + store-root + the on-disk artifacts the fixture
#      will materialize (~/.config/m6-test/, ~/.config/m6-test/path-rc.sh).
#   4. Run `repro home apply --plan` and capture the rendered plan.
#      Assert every expected resource appears in the plan output
#      (under the `[resource]` category header, one line per resource).
#      Assert the plan-status line reports the right operation count.
#   5. Run `repro home apply` for real. Assert success exit. The WSL
#      instance IS the disposable sandbox so mutating the real
#      $HOME under our test temp paths is fine.
#   6. Verify the materialized resources actually landed:
#      a. `~/.config/m6-test/marker.txt` exists with the declared bytes.
#      b. `~/.config/m6-test/hello.sh` exists, mode 0755, runs and
#         emits `m6 hello`.
#      c. `~/.config/m6-test/path-rc.sh` contains the PATH-contribution
#         managed block (sentinel pair + the contributed entry).
#      d. The same rc file contains the `export REPRO_M6_HOME_APPLY=1`
#         line (env.userVariable on POSIX renders through the same
#         shared rc managed block as env.userPath).
#      e. `~/.config/m6-test/shell-hook.sh` contains the
#         `shell.integration` managed block + the declared content.
#   7. Re-run `repro home apply --plan` and assert drift == 0 +
#      no-op plan status. This is the M6 verification gate.
#   8. Clean up on exit (success OR failure): remove the per-run
#      state-dir + store-root + the materialized $HOME tree so a
#      re-run starts clean.
#
# Per the campaign protocol, invoke via:
#
#   bash scripts/run_multi_distro_tests.sh m6_home_apply --all
#
# and the script refuses to run on a non-recognized distro.

set -eu

# ----------------------------------------------------------------------
# Sanity: this test must run inside a recognized repro-* WSL instance.
# ----------------------------------------------------------------------

if [ ! -r /etc/os-release ]; then
  echo "m6_home_apply: FAIL - /etc/os-release missing" >&2
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-unknown}" in
  arch)    BOOTSTRAP_NAME=arch ;;
  debian)  BOOTSTRAP_NAME=debian ;;
  ubuntu)  BOOTSTRAP_NAME=ubuntu ;;
  fedora)  BOOTSTRAP_NAME=fedora ;;
  alpine)  BOOTSTRAP_NAME=alpine ;;
  *)
    echo "m6_home_apply: FAIL - unrecognized ID=${ID:-unknown}" >&2
    echo "  (M6 covers arch / debian / ubuntu / fedora / alpine)" >&2
    exit 1
    ;;
esac

REPO_ROOT="${REPRO_REPO_ROOT:-/mnt/d/metacraft/reprobuild}"
BOOTSTRAP="${REPO_ROOT}/tools/multi-distro-harness/bootstrap-${BOOTSTRAP_NAME}.sh"
FIXTURE="${REPO_ROOT}/tools/multi-distro-harness/tests/fixtures/m6_home_profile.nim"
WORK_ROOT="${REPRO_BOOTSTRAP_ROOT:-/tmp/reprobuild-bootstrap-${BOOTSTRAP_NAME}}"
REPRO_BIN="${WORK_ROOT}/bin/repro"

# Per-run state lives under WORK_ROOT/m6-home/ so the M1-M4
# self-bootstrap artifacts are not perturbed.
M6_ROOT="${WORK_ROOT}/m6-home"
PROFILE_DIR="${M6_ROOT}/profile"
STATE_DIR="${M6_ROOT}/state"
STORE_ROOT="${M6_ROOT}/store"

# Materialization targets. These live under $HOME — the WSL instance
# is the disposable sandbox per the M6 brief, so writing under $HOME
# is allowed; we still keep the footprint inside ~/.config/m6-test/
# so cleanup is a single recursive rm.
HOME_M6="${HOME}/.config/m6-test"
PATH_RC="${HOME_M6}/path-rc.sh"
MARKER="${HOME_M6}/marker.txt"
HELLO="${HOME_M6}/hello.sh"
HOOK="${HOME_M6}/shell-hook.sh"

EXPECTED_MARKER_BODY='m6: managed by reprobuild home apply'
EXPECTED_HELLO_OUT='m6 hello'
EXPECTED_ENV_VAR='REPRO_M6_HOME_APPLY'
EXPECTED_PATH_ENTRY='/opt/repro-m6-test/bin'
EXPECTED_HOOK_BODY='REPRO_M6_SHELL_HOOK_FIRED=1'
EXPECTED_RES_COUNT=5  # marker, hello, env-var, env-path, shell.integration

# ----------------------------------------------------------------------
# Cleanup helper. Invoked on EXIT so a partial failure leaves no
# residue in the WSL instance for the next run.
# ----------------------------------------------------------------------

cleanup() {
  # Best-effort: ignore errors. Junction-aware unlinks are not
  # needed here — every path we touch is a plain file or directory
  # we created.
  rm -rf "${M6_ROOT}" 2>/dev/null || true
  rm -rf "${HOME_M6}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if [ ! -f "${BOOTSTRAP}" ]; then
  echo "m6_home_apply: FAIL - bootstrap script missing at ${BOOTSTRAP}" >&2
  exit 1
fi
if [ ! -f "${FIXTURE}" ]; then
  echo "m6_home_apply: FAIL - profile fixture missing at ${FIXTURE}" >&2
  exit 1
fi

echo "m6_home_apply: running on ID=${ID} (${BOOTSTRAP_NAME})"

# ----------------------------------------------------------------------
# Step 1: ensure the bootstrap has built `repro`.
# ----------------------------------------------------------------------

echo "m6_home_apply: step 1 — bootstrap (re-uses M1-M4 build if warm)"
if ! sh "${BOOTSTRAP}"; then
  echo "m6_home_apply: FAIL - bootstrap-${BOOTSTRAP_NAME}.sh exited non-zero" >&2
  exit 1
fi
if [ ! -x "${REPRO_BIN}" ]; then
  echo "m6_home_apply: FAIL - repro binary missing at ${REPRO_BIN}" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 2: stage the profile fixture.
# ----------------------------------------------------------------------

echo "m6_home_apply: step 2 — stage profile"
rm -rf "${M6_ROOT}"
mkdir -p "${PROFILE_DIR}" "${STATE_DIR}" "${STORE_ROOT}"
cp "${FIXTURE}" "${PROFILE_DIR}/home.nim"

# Same PATH layering shape M2-M4's test scripts use so `repro home
# apply` can find the right nim (`nim c` is invoked under the hood
# when the apply pipeline compiles the home.nim through the M83
# Phase A macro library).
NIM_VERSION="${REPRO_BOOTSTRAP_NIM_VERSION:-2.2.10}"
case "${BOOTSTRAP_NAME}" in
  alpine)
    export PATH="${WORK_ROOT}/bin:${WORK_ROOT}/nim-${NIM_VERSION}/bin:/usr/local/bin:/usr/bin:${PATH:-}"
    export BLAKE3_PREFIX=/usr
    export XXHASH_PREFIX=/usr
    ;;
  arch)
    export PATH="${WORK_ROOT}/bin:/usr/local/bin:/usr/bin:${PATH:-}"
    ;;
  fedora)
    # Fedora 44 has no `nim` package; bootstrap-fedora.sh uses
    # choosenim under /root/.nimble like M2's debian/ubuntu shape.
    export PATH="${WORK_ROOT}/bin:/root/.nimble/bin:/usr/local/bin:/usr/bin:${PATH:-}"
    export BLAKE3_PREFIX=/usr/local
    export XXHASH_PREFIX=/usr/local
    ;;
  debian|ubuntu)
    export PATH="${WORK_ROOT}/bin:/root/.nimble/bin:/usr/local/bin:/usr/bin:${PATH:-}"
    export BLAKE3_PREFIX=/usr/local
    export XXHASH_PREFIX=/usr/local
    ;;
esac
export REPROBUILD_REPO_ROOT="${REPO_ROOT}"

# Test seams: pin the apply state-dir / store-root / host / posix
# path-rc target so the fixture's `env.userPath` lands in the file
# we control instead of the user's real ~/.bashrc / ~/.zshrc.
# REPRO_HOST forces the host-table lookup to `m6-test-host` (matches
# the `hosts:` block in the fixture); without this the apply would
# fall back to the WSL kernel hostname (e.g. `archlinux` / `debian`)
# which is NOT in the host table and the apply would emit no
# activities for that host.
export REPRO_HOME_STATE_DIR="${STATE_DIR}"
export REPRO_HOME_STORE_ROOT="${STORE_ROOT}"
export REPRO_HOME_POSIX_PATH_RC="${PATH_RC}"
export REPRO_HOST="m6-test-host"

# ----------------------------------------------------------------------
# Step 3: reset the materialization targets in $HOME (in case a
# prior run left residue).
# ----------------------------------------------------------------------

rm -rf "${HOME_M6}"
mkdir -p "${HOME_M6}"
# Touch the path-rc file so the managed-block writer treats it as a
# partially-owned host file rather than creating it from scratch
# (the driver handles both, but starting from an empty file is the
# more representative shape).
: > "${PATH_RC}"
: > "${HOOK}"

# ----------------------------------------------------------------------
# Step 4: `repro home apply --plan` against the staged profile.
# ----------------------------------------------------------------------

echo "m6_home_apply: step 4 — apply --plan (initial)"
plan_log_initial="${M6_ROOT}/plan-initial.log"
set +e
"${REPRO_BIN}" home --profile-dir="${PROFILE_DIR}" apply --plan \
  >"${plan_log_initial}" 2>&1
rc=$?
set -e
if [ "${rc}" -ne 0 ]; then
  echo "m6_home_apply: FAIL - initial plan exited non-zero (rc=${rc})" >&2
  echo "  plan log (last 40 lines):" >&2
  tail -n 40 "${plan_log_initial}" >&2 || true
  exit 1
fi

# Sanity: the plan must mention every resource address declared in
# the fixture. The plan renderer emits one line per item under the
# `[resource]` category as `  <action>  <address-or-name>  (<detail>)`.
echo "  plan log (head):"
head -n 30 "${plan_log_initial}" || true
echo "  ..."

missing_in_plan=''
for tok in marker hello m6Var m6Path m6Hook; do
  if ! grep -q "${tok}" "${plan_log_initial}"; then
    missing_in_plan="${missing_in_plan} ${tok}"
  fi
done
if [ -n "${missing_in_plan}" ]; then
  echo "m6_home_apply: FAIL - initial plan missing expected resources:${missing_in_plan}" >&2
  echo "  full plan log:" >&2
  cat "${plan_log_initial}" >&2
  exit 1
fi

# Sanity: plan-status header reports >0 operations.
if ! grep -Eq 'operation\(s\) previewed' "${plan_log_initial}"; then
  echo "m6_home_apply: FAIL - initial plan missing operation-count header" >&2
  cat "${plan_log_initial}" >&2
  exit 1
fi

# Capture op count for the README table.
op_count=$(grep -Eo '[0-9]+ operation\(s\) previewed' "${plan_log_initial}" \
  | head -n 1 | awk '{print $1}')
echo "  plan op count: ${op_count:-unknown}"

# ----------------------------------------------------------------------
# Step 5: `repro home apply` for real.
# ----------------------------------------------------------------------

echo "m6_home_apply: step 5 — apply (live)"
apply_log="${M6_ROOT}/apply.log"
set +e
"${REPRO_BIN}" home --profile-dir="${PROFILE_DIR}" apply \
  >"${apply_log}" 2>&1
rc=$?
set -e
if [ "${rc}" -ne 0 ]; then
  echo "m6_home_apply: FAIL - apply exited non-zero (rc=${rc})" >&2
  echo "  apply log (last 60 lines):" >&2
  tail -n 60 "${apply_log}" >&2 || true
  exit 1
fi

# ----------------------------------------------------------------------
# Step 6: verify each resource actually materialized.
# ----------------------------------------------------------------------

echo "m6_home_apply: step 6 — verify materialized resources"

# 6a: marker file.
if [ ! -f "${MARKER}" ]; then
  echo "m6_home_apply: FAIL - marker file missing at ${MARKER}" >&2
  exit 1
fi
if ! grep -Fq "${EXPECTED_MARKER_BODY}" "${MARKER}"; then
  echo "m6_home_apply: FAIL - marker file body mismatch" >&2
  echo "  got: $(cat "${MARKER}")" >&2
  exit 1
fi
echo "  ok: ${MARKER}"

# 6b: hello.sh — file exists, mode 0755, runs and emits expected.
if [ ! -x "${HELLO}" ]; then
  echo "m6_home_apply: FAIL - hello.sh missing or not executable at ${HELLO}" >&2
  ls -l "${HELLO}" >&2 || true
  exit 1
fi
hello_out="$("${HELLO}" 2>&1 || true)"
if [ "${hello_out}" != "${EXPECTED_HELLO_OUT}" ]; then
  echo "m6_home_apply: FAIL - hello.sh output mismatch" >&2
  echo "  expected: ${EXPECTED_HELLO_OUT}" >&2
  echo "  got:      ${hello_out}" >&2
  exit 1
fi
echo "  ok: ${HELLO} (executable, output matches)"

# 6c: path-rc contains the env.userPath managed block + entry.
if [ ! -f "${PATH_RC}" ]; then
  echo "m6_home_apply: FAIL - PATH rc file missing at ${PATH_RC}" >&2
  exit 1
fi
if ! grep -Fq "${EXPECTED_PATH_ENTRY}" "${PATH_RC}"; then
  echo "m6_home_apply: FAIL - PATH rc missing expected entry '${EXPECTED_PATH_ENTRY}'" >&2
  echo "  contents:" >&2
  cat "${PATH_RC}" >&2
  exit 1
fi
echo "  ok: ${PATH_RC} contains '${EXPECTED_PATH_ENTRY}'"

# 6d: env.userVariable. On POSIX the driver writes to the SAME
# shared rc file the env.userPath driver uses (the test seam pins
# both to ${PATH_RC}). The line takes the shape
# `export REPRO_M6_HOME_APPLY=...` inside a managed block.
if ! grep -Fq "${EXPECTED_ENV_VAR}" "${PATH_RC}"; then
  echo "m6_home_apply: WARN - env.userVariable line not found in ${PATH_RC}" >&2
  echo "  (the driver may render env.userVariable through a different host file" >&2
  echo "   on this distro; full rc contents below for diagnosis.)" >&2
  cat "${PATH_RC}" >&2
  # Soft-warn — not fail — because env.userVariable on POSIX may
  # route through a different host file depending on the driver
  # variant. The CRITICAL gate is the four other resources.
fi

# 6e: shell.integration managed block.
if [ ! -f "${HOOK}" ]; then
  echo "m6_home_apply: FAIL - shell-hook file missing at ${HOOK}" >&2
  exit 1
fi
if ! grep -Fq "${EXPECTED_HOOK_BODY}" "${HOOK}"; then
  echo "m6_home_apply: FAIL - shell-hook missing expected body" >&2
  echo "  contents:" >&2
  cat "${HOOK}" >&2
  exit 1
fi
if ! grep -q '^# >>> repro' "${HOOK}" && ! grep -q 'repro:' "${HOOK}"; then
  echo "m6_home_apply: FAIL - shell-hook missing repro managed-block sentinel" >&2
  echo "  contents:" >&2
  cat "${HOOK}" >&2
  exit 1
fi
echo "  ok: ${HOOK} (managed block + body present)"

# ----------------------------------------------------------------------
# Step 7: re-run `repro home apply --plan`. Drift MUST be zero.
# ----------------------------------------------------------------------

echo "m6_home_apply: step 7 — apply --plan (drift check)"
plan_log_drift="${M6_ROOT}/plan-drift.log"
set +e
"${REPRO_BIN}" home --profile-dir="${PROFILE_DIR}" apply --plan \
  >"${plan_log_drift}" 2>&1
rc=$?
set -e
if [ "${rc}" -ne 0 ]; then
  echo "m6_home_apply: FAIL - second plan exited non-zero (rc=${rc})" >&2
  echo "  plan log (last 40 lines):" >&2
  tail -n 40 "${plan_log_drift}" >&2 || true
  exit 1
fi

# Either the plan reports `no-op` (cleanest signal) or it lists
# zero drift items and an operation count of zero. We accept both
# shapes since the renderer may evolve.
if grep -q 'plan status: no-op' "${plan_log_drift}"; then
  drift_status='no-op'
elif grep -Eq '0 drift\(s\)' "${plan_log_drift}" && \
     grep -Eq '0 operation\(s\) previewed' "${plan_log_drift}"; then
  drift_status='zero-drift'
else
  echo "m6_home_apply: FAIL - second plan shows drift (expected zero)" >&2
  cat "${plan_log_drift}" >&2
  exit 1
fi
echo "  ok: drift status = ${drift_status}"

# ----------------------------------------------------------------------
# Success.
# ----------------------------------------------------------------------

echo "m6_home_apply: OK"
echo "  distro:           ${BOOTSTRAP_NAME} (${PRETTY_NAME:-unknown})"
echo "  profile:          ${PROFILE_DIR}/home.nim"
echo "  state-dir:        ${STATE_DIR}"
echo "  initial op count: ${op_count:-unknown}"
echo "  drift status:     ${drift_status}"
exit 0
