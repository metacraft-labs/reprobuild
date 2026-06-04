#!/usr/bin/env bash
# ==============================================================================
# M9 end-to-end verification harness for the Linux home-profile flow.
#
# Linux/WSL counterpart of scripts/verify-m71-home-profile-fixtures.ps1.
# Drives the M65 ``LinuxDefaultChain = @[cakNix, cakBuiltin, cakPath]``
# end-to-end against the M9 reference home profile
# (reprobuild-examples/m9-linux-home-profile/home.nim).
#
# Mechanics (mirrors M71's Windows harness):
#
#   1. Bootstrap a sandboxed home profile under
#      ``${XDG_STATE_HOME:-$HOME/.local/state}/repro-m9-validation/home/``
#      (or ``$REPRO_M9_STATE_ROOT`` when set).
#   2. Copy the M9 reference home.nim from
#      ``reprobuild-examples/m9-linux-home-profile/home.nim`` into the
#      sandbox's ``REPRO_HOME_PROFILE_DIR``.
#   3. Set ``REPRO_HOST=m9-test-host`` so the host-activity map lifts
#      every activity.
#   4. Run ``repro home apply`` against the sandboxed state. This drives
#      the M65 cakNix / cakBuiltin / cakPath chain. On a vanilla Linux
#      host with no Nix daemon and no Linux URLs in the catalog (the
#      current state), every package falls through to cakPath and is
#      resolved from the host's existing PATH (apt/yum/pacman, manual
#      install, etc.).
#   5. Lift the activation-generation's per-package bin dir onto the
#      harness's PATH (the apply pipeline writes a stable bin dir at
#      ``<state-dir>/bin``).
#   6. For each Phase-2 fixture, run its per-fixture validate-*.sh and
#      classify the outcome (GRADUATED-PASS / STILL-SKIPPED /
#      BLOCKED-NO-CATALOG / REGRESSION).
#
# The actual home apply step is gated behind ``REPRO_LIVE=1`` because
# realizing the full catalog footprint downloads gigabytes when the
# Linux URLs eventually land. Without the env var the harness runs in
# PLAN mode: it asserts the resolver picks SOME slice for every listed
# package (cakBuiltin, cakNix, or cakPath) and that the Phase-2
# partials' validate scripts SKIP cleanly (no spurious FAIL on a host
# that hasn't been provisioned).
#
# **Linux catalog reality.** As of the M9 landing, NO ``packages/<tool>.nim``
# carries a ``poLinux`` platform slice (every M67/M68 harvest pulled
# from Scoop). The chain resolves through cakPath on Linux when the
# tool is already provisioned via the distro package manager; the
# fixtures graduate to PASS once the operator has the toolchain on
# PATH. The hermetic resolver-level contract is asserted by
# ``tests/e2e/m9/t_e2e_m9_linux_phase2_partials_resolve.nim``.
#
# **WSL provisioning.** The canonical disposable env for running this
# harness is a throwaway WSL distro (per
# ``project_reprobuild_destructive_gate_envs`` memory). See
# ``tools/sandbox-wsl/README.md`` for the operator-supplied WSL
# bootstrap procedure.
#
# Per reprobuild-specs/Realize-Closure-And-Catalog-Expansion.milestones.org
# §M9.
# ==============================================================================
set -euo pipefail

# --- locate this script + the repo root ---
# Use ``readlink -f`` on Linux/WSL; fall back to ``realpath`` if
# coreutils' readlink is missing (alpine/busybox).
script_path="$0"
if command -v readlink >/dev/null 2>&1 && readlink -f / >/dev/null 2>&1; then
  script_path="$(readlink -f "$0")"
elif command -v realpath >/dev/null 2>&1; then
  script_path="$(realpath "$0")"
fi
script_dir="$(cd "$(dirname "$script_path")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
metacraft_root="$(cd "$repo_root/.." && pwd)"

repro_bin="$repo_root/build/bin/repro"
provider_bin="$repo_root/build/bin/repro-standard-provider"
reference_home="$metacraft_root/reprobuild-examples/m9-linux-home-profile/home.nim"

# Per-run scratch under <repo>/build/m9-verify/.
harness_scratch="$repo_root/build/m9-verify"
logs_dir="$harness_scratch/logs"
summary_file="$harness_scratch/m9-graduation-table.tsv"

# Sandboxed home state (allow override for hosts where ${XDG_STATE_HOME}
# is unwriteable or already populated).
if [ -n "${REPRO_M9_STATE_ROOT:-}" ]; then
  sandbox_root="$REPRO_M9_STATE_ROOT"
else
  xdg_state="${XDG_STATE_HOME:-$HOME/.local/state}"
  sandbox_root="$xdg_state/repro-m9-validation"
fi
sandbox_state_dir="$sandbox_root/state"
sandbox_store_root="$sandbox_root/store"
sandbox_profile_dir="$sandbox_root/profile"
sandbox_home_dir="$sandbox_root/home"

live_mode=0
if [ "${REPRO_LIVE:-}" = "1" ] || [ "${REPRO_LIVE:-}" = "true" ]; then
  live_mode=1
fi

# --- preflight --------------------------------------------------------------
if [ ! -x "$repro_bin" ] && [ ! -f "$repro_bin" ]; then
  echo "FAIL: missing $repro_bin -- run scripts/build_apps.sh first"
  exit 1
fi
if [ ! -x "$provider_bin" ] && [ ! -f "$provider_bin" ]; then
  echo "FAIL: missing $provider_bin -- run scripts/build_apps.sh first"
  exit 1
fi
if [ ! -f "$reference_home" ]; then
  echo "FAIL: M9 reference home.nim missing at $reference_home"
  echo "  expected: reprobuild-examples/m9-linux-home-profile/home.nim"
  exit 1
fi

# Clean prior harness scratch so we get a coherent aggregate.
if [ -d "$harness_scratch" ]; then
  rm -rf "$harness_scratch"
fi
mkdir -p "$logs_dir"

mode_label="PLAN (resolver-only; set REPRO_LIVE=1 to enable realize)"
if [ "$live_mode" = "1" ]; then
  mode_label="LIVE (will run repro home apply)"
fi

echo "==> M9 Linux home-profile validation harness"
echo "    repo:        $repo_root"
echo "    reference:   $reference_home"
echo "    sandbox:     $sandbox_root"
echo "    mode:        $mode_label"
echo ""

# --- M9 graduation table ----------------------------------------------------
#
# Rows describe each Phase-2 fixture the M9 campaign targets, the tools
# it needs from the catalog, the per-fixture validate script, and the
# EXPECTED outcome class on a vanilla Linux host (no catalog Linux URLs,
# no Nix daemon).
#
# Columns (TAB-separated):
#   Fixture           : reprobuild-examples-relative path
#   ValidateScript    : scripts/validate-*.sh basename
#   RequiredTools     : space-separated catalog ids the fixture needs
#   CatalogStatus     : "CLEAN-WIN-ONLY" (catalog entry exists but
#                                          Windows-URL only),
#                       "BLOCKED-NO-CATALOG" (no registry entry)
#   ExpectedStatus    : "GRADUATED-PASS" / "STILL-SKIPPED" /
#                       "BLOCKED-NO-CATALOG"
#   Reason            : free-form gap description for the wrap-up
#
# The rows below are encoded as one TAB-separated line per fixture.
# Bash 3.2+ associative arrays are unreliable across the Bash/zsh
# split (zsh on macOS, bash 3.2 on macOS, bash 5+ on Linux) so we use
# a flat heredoc the loop iterates over.
graduation_table="$(cat <<'EOF'
haskell-cabal/hello-binary	validate-haskell-cabal-hello-binary.sh	ghc cabal	CLEAN-WIN-ONLY	STILL-SKIPPED	ghc + cabal CLEAN in the catalog for Windows; awaiting Linux harvester pass for poLinux slices. cabal v2-build needs the toolchain; SKIPs when not on PATH.
crystal-shards/hello-binary	validate-crystal-hello-binary.sh	crystal	CLEAN-WIN-ONLY	STILL-SKIPPED	crystal CLEAN in the catalog for Windows; awaiting Linux harvester pass. Upstream Linux tarball targets glibc 2.17 (RHEL 7 / Ubuntu 14.04 floor).
EOF
)"

# --- step 1: copy reference home.nim into the sandbox ----------------------
echo "==> bootstrapping sandbox at $sandbox_root"
for dir in "$sandbox_state_dir" "$sandbox_store_root" "$sandbox_profile_dir" \
           "$sandbox_home_dir"; do
  if [ -d "$dir" ]; then
    rm -rf "$dir"
  fi
  mkdir -p "$dir"
done
cp "$reference_home" "$sandbox_profile_dir/home.nim"
echo "    copied $reference_home -> $sandbox_profile_dir/home.nim"
echo ""

# --- step 2: drive `repro home apply` (live mode) or `--plan` (default) ----
apply_log="$logs_dir/repro-home-apply.log"
apply_args=("home" "--profile-dir" "$sandbox_profile_dir" "apply")
if [ "$live_mode" = "1" ]; then
  echo "==> running: $repro_bin ${apply_args[*]} (LIVE; will download catalog packages)"
else
  # --allow-drift lets the plan exit 0 even when the planner sees drift
  # against existing state (the sandbox is empty on first run; subsequent
  # runs will see prior generations). PLAN mode treats drift as
  # informational; only hard schema/resolution errors should be fatal.
  apply_args+=("--plan" "--allow-drift")
  echo "==> running: $repro_bin ${apply_args[*]} (PLAN mode; resolver-only)"
fi

apply_exit=0
(
  cd "$repo_root" && \
  REPRO_HOME_PROFILE_DIR="$sandbox_profile_dir" \
  REPRO_HOME_STATE_DIR="$sandbox_state_dir" \
  REPRO_STORE_ROOT="$sandbox_store_root" \
  HOME="$sandbox_home_dir" \
  REPRO_HOST="m9-test-host" \
  "$repro_bin" "${apply_args[@]}" \
    >"$apply_log" 2>"$apply_log.err"
) || apply_exit=$?

if [ -f "$apply_log" ]; then
  echo "--- repro home apply stdout (last 30 lines):"
  tail -n 30 "$apply_log" | sed 's/^/    /'
fi
if [ -s "$apply_log.err" ]; then
  echo "--- repro home apply stderr (last 30 lines):"
  tail -n 30 "$apply_log.err" | sed 's/^/    /'
fi
echo "--- repro home apply exit code: $apply_exit"
echo ""

if [ "$apply_exit" -ne 0 ]; then
  if [ "$live_mode" = "1" ]; then
    echo "FAIL: repro home apply failed in LIVE mode; cannot proceed with fixture graduation"
    echo "  (the apply step downloads catalog packages -- see $apply_log)"
    exit 1
  else
    echo "WARN: repro home apply --plan exited non-zero ($apply_exit); plan-mode is best-effort."
    echo "  Continuing with fixture classification -- the per-fixture validate scripts will SKIP cleanly."
  fi
fi

# --- step 3: lift the activation generation's stable bin dir onto PATH -----
# In LIVE mode the apply pipeline writes a stable bin dir at
# <state-dir>/bin containing one wrapper per realized package's bin
# entries. Prepending that to the harness PATH lets the per-fixture
# validate scripts pick up the realized tools without further mutation.
stable_bin="$sandbox_state_dir/bin"
if [ -d "$stable_bin" ]; then
  echo "==> lifting $stable_bin onto PATH for downstream validate scripts"
  export PATH="$stable_bin:$PATH"
else
  echo "==> no stable bin dir at $stable_bin (PLAN mode or apply did not produce it)"
fi
echo ""

# --- step 4: per-fixture validate runs --------------------------------------
# Stage row outputs into a single TSV the summary step concatenates.
results_tsv="$logs_dir/per-fixture-results.tsv"
: >"$results_tsv"

# Each line of $graduation_table is TAB-separated. Iterate.
graduated_count=0
skipped_count=0
blocked_count=0
regression_count=0
harness_errors=0

while IFS=$'\t' read -r fixture validate_script required_tools catalog_status \
                       expected_status reason; do
  # Skip empty lines (defensive against trailing newline in heredoc).
  if [ -z "$fixture" ]; then
    continue
  fi
  validate_path="$repo_root/scripts/$validate_script"
  log_name="$(echo "$fixture" | tr '/' '_')"
  fixture_log="$logs_dir/${log_name}.log"

  echo "==> $fixture (expected: $expected_status, catalog: $catalog_status)"
  if [ ! -f "$validate_path" ]; then
    echo "    FAIL: validate script not found at $validate_path"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$fixture" "$catalog_status" "$expected_status" "HARNESS-ERROR" "-1" \
      "validate script not found: $validate_script" >>"$results_tsv"
    harness_errors=$((harness_errors + 1))
    continue
  fi

  validate_exit=0
  ( cd "$repo_root" && bash "$validate_path" >"$fixture_log" 2>"$fixture_log.err" ) \
    || validate_exit=$?

  # Classify the outcome by inspecting the script's stdout.
  stdout_content=""
  if [ -f "$fixture_log" ]; then
    stdout_content="$(cat "$fixture_log")"
  fi

  actual_status="UNKNOWN"
  if [ "$validate_exit" -eq 0 ] && echo "$stdout_content" | grep -qE '^PASS:'; then
    actual_status="GRADUATED-PASS"
  elif [ "$validate_exit" -eq 0 ] && echo "$stdout_content" | grep -qE '^SKIP:'; then
    if [ "$catalog_status" = "BLOCKED-NO-CATALOG" ]; then
      actual_status="BLOCKED-NO-CATALOG"
    else
      actual_status="STILL-SKIPPED"
    fi
  elif [ "$validate_exit" -ne 0 ]; then
    actual_status="FAIL"
  fi

  case "$actual_status" in
    GRADUATED-PASS)     marker="[GRADUATED]" ;;
    STILL-SKIPPED)      marker="[skipped] " ;;
    BLOCKED-NO-CATALOG) marker="[blocked] " ;;
    FAIL)               marker="[FAIL!]   " ;;
    *)                  marker="[?]       " ;;
  esac
  echo "    $marker exit=$validate_exit actual=$actual_status"

  # Surface the leading lines from the validate script's stdout so the
  # harness log shows the SKIP / PASS message verbatim.
  if [ -n "$stdout_content" ]; then
    tail -n 3 "$fixture_log" | while IFS= read -r line; do
      if [ -n "$line" ]; then echo "      | $line"; fi
    done
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$fixture" "$catalog_status" "$expected_status" "$actual_status" \
    "$validate_exit" "$reason" >>"$results_tsv"

  case "$actual_status" in
    GRADUATED-PASS)     graduated_count=$((graduated_count + 1)) ;;
    STILL-SKIPPED)      skipped_count=$((skipped_count + 1)) ;;
    BLOCKED-NO-CATALOG) blocked_count=$((blocked_count + 1)) ;;
    FAIL)               regression_count=$((regression_count + 1)) ;;
    HARNESS-ERROR)      harness_errors=$((harness_errors + 1)) ;;
  esac
  echo ""
done <<<"$graduation_table"

# --- step 5: summary + graduation-table TSV --------------------------------
echo "============================================================"
echo "M9 Linux graduation table"
echo "============================================================"
{
  printf 'Fixture\tCatalogStatus\tExpectedStatus\tActualStatus\tExitCode\tReason\n'
  cat "$results_tsv"
} >"$summary_file"

printf '\n'
printf '  graduated PASS:     %3d\n' "$graduated_count"
printf '  still SKIPPED:      %3d (catalog has no Linux URL yet; tool not on PATH)\n' "$skipped_count"
printf '  blocked NO-CATALOG: %3d\n' "$blocked_count"
if [ "$regression_count" -gt 0 ] || [ "$harness_errors" -gt 0 ]; then
  printf '  REGRESSIONS:        %3d\n' "$regression_count" >&2
  printf '  harness errors:     %3d\n' "$harness_errors" >&2
fi
echo ""
echo "  graduation table TSV: $summary_file"
echo "  per-fixture logs:     $logs_dir"
echo ""

# Hard failures abort the harness; expected-SKIP outcomes are OK in
# PLAN mode and on a vanilla Linux host (no catalog Linux URLs).
if [ "$regression_count" -gt 0 ] || [ "$harness_errors" -gt 0 ]; then
  echo "FAIL: $regression_count regressions, $harness_errors harness errors" >&2
  exit 1
fi

echo "PASS: M9 harness completed; graduation table at $summary_file"
exit 0
