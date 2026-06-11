#!/bin/sh
# m7_infra_plan.sh — verify `repro infra plan` on non-NixOS Linux.
#
# Linux-Distro-Recipe-Validation M7 acceptance test. Runs inside any
# of repro-arch / repro-debian / repro-ubuntu / repro-fedora /
# repro-alpine — the script dispatches on /etc/os-release's `ID` field
# to pick the matching M1-M4 bootstrap script (the `repro` binary the
# milestone needs is the SAME binary M1-M4 produce; M7 reuses it).
#
# Steps:
#
#   1. Detect distro; ensure the matching `bootstrap-<distro>.sh` has
#      built `${WORK_ROOT}/bin/repro`. If the bootstrap was already
#      run by a prior M1-M4 / M6 test, the warm-bootstrap path
#      short-circuits.
#   2. Stage the M7 system profile (`tests/fixtures/m7_system_profile.nim`)
#      under a per-distro temp profile dir as `system.nim` (the
#      conventional file name `repro infra` looks for). The fixture
#      is shared verbatim across all five distros — no per-distro
#      tweak is needed (the typed-DSL primitives are platform-pure
#      and the system parser is uniform on Linux).
#   3. Reset the plan state for this run: remove the per-run
#      state-dir (no apply runs, so there are no on-disk artifacts
#      to clean up beyond `${STATE_DIR}`).
#   4. Run `repro infra plan --profile=<...>/system.nim
#      --state-dir=<...>` and capture the rendered plan.
#      Assert plan exits 0 + lists the three expected resources
#      (systemd unit, fs file, timezone).
#   5. Capture the per-distro operation count for the README table.
#   6. DO NOT run `repro infra apply`. The M9 spec milestone exercises
#      rollback in a controlled environment; the M7 brief is read-
#      only plan validation only.
#   7. Clean up on exit (success OR failure): remove the per-run
#      state-dir so a re-run starts clean.
#
# Per the campaign protocol, invoke via:
#
#   bash scripts/run_multi_distro_tests.sh m7_infra_plan --all
#
# and the script refuses to run on a non-recognized distro.

set -eu

# ----------------------------------------------------------------------
# Sanity: this test must run inside a recognized repro-* WSL instance.
# ----------------------------------------------------------------------

if [ ! -r /etc/os-release ]; then
  echo "m7_infra_plan: FAIL - /etc/os-release missing" >&2
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
    echo "m7_infra_plan: FAIL - unrecognized ID=${ID:-unknown}" >&2
    echo "  (M7 covers arch / debian / ubuntu / fedora / alpine)" >&2
    exit 1
    ;;
esac

REPO_ROOT="${REPRO_REPO_ROOT:-/mnt/d/metacraft/reprobuild}"
BOOTSTRAP="${REPO_ROOT}/tools/multi-distro-harness/bootstrap-${BOOTSTRAP_NAME}.sh"
FIXTURE="${REPO_ROOT}/tools/multi-distro-harness/tests/fixtures/m7_system_profile.nim"
WORK_ROOT="${REPRO_BOOTSTRAP_ROOT:-/tmp/reprobuild-bootstrap-${BOOTSTRAP_NAME}}"
REPRO_BIN="${WORK_ROOT}/bin/repro"

# Per-run state lives under WORK_ROOT/m7-infra/ so the M1-M4/M6
# artifacts are not perturbed.
M7_ROOT="${WORK_ROOT}/m7-infra"
PROFILE_DIR="${M7_ROOT}/profile"
PROFILE_PATH="${PROFILE_DIR}/system.nim"
STATE_DIR="${M7_ROOT}/state"

# ----------------------------------------------------------------------
# Cleanup helper. Invoked on EXIT so a partial failure leaves no
# residue in the WSL instance for the next run. We do NOT touch
# /etc/m7-test/ because the test does NOT run `infra apply`; no host
# files were ever materialized.
# ----------------------------------------------------------------------

cleanup() {
  rm -rf "${M7_ROOT}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if [ ! -f "${BOOTSTRAP}" ]; then
  echo "m7_infra_plan: FAIL - bootstrap script missing at ${BOOTSTRAP}" >&2
  exit 1
fi
if [ ! -f "${FIXTURE}" ]; then
  echo "m7_infra_plan: FAIL - profile fixture missing at ${FIXTURE}" >&2
  exit 1
fi

echo "m7_infra_plan: running on ID=${ID} (${BOOTSTRAP_NAME})"

# ----------------------------------------------------------------------
# Step 1: ensure the bootstrap has built `repro`.
# ----------------------------------------------------------------------

echo "m7_infra_plan: step 1 - bootstrap (re-uses M1-M4 build if warm)"
if ! sh "${BOOTSTRAP}"; then
  echo "m7_infra_plan: FAIL - bootstrap-${BOOTSTRAP_NAME}.sh exited non-zero" >&2
  exit 1
fi
if [ ! -x "${REPRO_BIN}" ]; then
  echo "m7_infra_plan: FAIL - repro binary missing at ${REPRO_BIN}" >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 2: stage the profile fixture.
# ----------------------------------------------------------------------

echo "m7_infra_plan: step 2 - stage profile"
rm -rf "${M7_ROOT}"
mkdir -p "${PROFILE_DIR}" "${STATE_DIR}"
cp "${FIXTURE}" "${PROFILE_PATH}"

# Same PATH layering shape M6 / M2-M4's test scripts use so the
# `__repro-compile-profile` helper subcommand finds the right `nim`
# (the helper invokes `nim c` under the hood when compiling the
# typed-DSL system.nim through the M83 Phase A macro library).
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

# ----------------------------------------------------------------------
# Step 3: `repro infra plan` against the staged profile.
# ----------------------------------------------------------------------

echo "m7_infra_plan: step 3 - infra plan"
plan_log="${M7_ROOT}/plan.log"
set +e
"${REPRO_BIN}" infra plan \
  --profile="${PROFILE_PATH}" \
  --state-dir="${STATE_DIR}" \
  >"${plan_log}" 2>&1
rc=$?
set -e
if [ "${rc}" -ne 0 ]; then
  echo "m7_infra_plan: FAIL - infra plan exited non-zero (rc=${rc})" >&2
  echo "  plan log (last 60 lines):" >&2
  tail -n 60 "${plan_log}" >&2 || true
  exit 1
fi

# Sanity: show the head of the plan log for the CI captures.
echo "  plan log (head):"
head -n 30 "${plan_log}" || true
echo "  ..."

# Sanity: the plan must mention every resource address declared in
# the fixture. The infra plan renderer emits one line per operation
# as `  * <summary>  [<action>]` (or `    <summary>  [no-op]`); the
# resource address appears in <summary>.
missing_in_plan=''
for tok in m7HelloUnit m7Marker m7Timezone; do
  if ! grep -q "${tok}" "${plan_log}"; then
    missing_in_plan="${missing_in_plan} ${tok}"
  fi
done
# Fall back to kind-tag search if the addresses don't show up in
# the summary line (the planner's summary format may vary across
# resource kinds).
if [ -n "${missing_in_plan}" ]; then
  echo "  note: address-name search missed${missing_in_plan}; falling back to kind-tag scan"
  missing_in_plan=''
  for tok in 'systemd.systemUnit' 'fs.systemFile' 'os.timezone'; do
    if ! grep -Fq "${tok}" "${plan_log}"; then
      missing_in_plan="${missing_in_plan} ${tok}"
    fi
  done
fi
if [ -n "${missing_in_plan}" ]; then
  echo "m7_infra_plan: FAIL - plan missing expected resources:${missing_in_plan}" >&2
  echo "  full plan log:" >&2
  cat "${plan_log}" >&2
  exit 1
fi

# Sanity: plan must end with either the "would change" header or
# the no-op header. Either is a successful plan.
if grep -Eq 'would change the system|apply would be a no-op' "${plan_log}"; then
  : # ok
else
  echo "m7_infra_plan: FAIL - plan missing terminal change/no-op header" >&2
  cat "${plan_log}" >&2
  exit 1
fi

# Capture op count for the README table. The infra plan renderer
# writes one of two headers:
#   "  N operation(s) would change the system."
#   "  (no changes - apply would be a no-op)"
op_count=$(grep -Eo '[0-9]+ operation\(s\) would change the system' "${plan_log}" \
  | head -n 1 | awk '{print $1}')
if [ -z "${op_count}" ]; then
  if grep -q 'apply would be a no-op' "${plan_log}"; then
    op_count=0
  else
    op_count='?'
  fi
fi
echo "  plan op count: ${op_count}"

# Per-distro divergence note. The brief asks us to document path
# conventions + systemd availability under WSL. The PLANNER itself
# is platform-pure; per-distro divergence surfaces at APPLY time
# (which M7 deliberately doesn't exercise). But we surface what
# the plan output reports for the systemd-unit observation so
# follow-up milestones can read the per-distro state.
echo ""
echo "  per-distro plan-time observation summary (systemd availability,"
echo "  /etc/localtime convention, etc.):"
case "${BOOTSTRAP_NAME}" in
  arch)
    echo "    arch: pacman-managed systemd. /etc/localtime is the live tz pin."
    ;;
  debian|ubuntu)
    echo "    ${BOOTSTRAP_NAME}: apt-managed systemd; WSL default has systemd"
    echo "      disabled unless /etc/wsl.conf opts in. Plan observation is"
    echo "      filesystem-only so this does not block the gate."
    ;;
  fedora)
    echo "    fedora: dnf-managed systemd. /etc/systemd/system/ is the canonical"
    echo "      unit drop-in directory; /usr/lib/systemd/system/ holds the"
    echo "      distro-shipped units."
    ;;
  alpine)
    echo "    alpine: NO systemd; openrc is the real init. The plan-time"
    echo "      observation of the unit file is filesystem-only (a missing"
    echo "      unit file is a 'create' action), so the planner returns a"
    echo "      legal plan even though apply would need a systemd shim or"
    echo "      a per-distro driver variant to actually enable the unit."
    ;;
esac

# ----------------------------------------------------------------------
# Step 4: assert the gate's verification rules.
#
# NB: we DO NOT re-run plan + check drift; the M7 brief is a single-
# pass read-only validation. Drift / no-op-on-second-plan are M6's
# gate (home scope, where the apply path actually materializes
# resources) and M9's gate (rollback). Soft-warn (do not hard-fail)
# if any primitive surfaces a known-driver-not-wired arm; mirror the
# M6 env.userVariable soft-warn pattern.
# ----------------------------------------------------------------------

if grep -qi 'driver not wired\|not implemented\|unsupported on' "${plan_log}"; then
  echo "  WARN: plan log mentions an un-wired driver path:"
  grep -i 'driver not wired\|not implemented\|unsupported on' "${plan_log}" \
    | head -n 5 || true
fi

# ----------------------------------------------------------------------
# Success.
# ----------------------------------------------------------------------

echo "m7_infra_plan: OK"
echo "  distro:           ${BOOTSTRAP_NAME} (${PRETTY_NAME:-unknown})"
echo "  profile:          ${PROFILE_PATH}"
echo "  state-dir:        ${STATE_DIR}"
echo "  plan op count:    ${op_count}"
exit 0
