# shellcheck shell=bash
#
# scripts/lib/build_report_attribution.sh — attributing a build report to the
# invocation that actually wrote it.
#
# ``repro build --write-report`` writes its post-mortem to a FIXED path
# under the project's out-dir — ``build-report.json`` on success,
# ``build-failure-report.json`` on failure. The path carries no identity:
# nothing in it names the target, the process or the day. So a report left
# behind by ANY earlier invocation is indistinguishable, by existence alone,
# from one the current invocation just produced.
#
# THE DEFECT THIS EXISTS TO PREVENT, WHICH IS NOT HYPOTHETICAL. A suite run
# whose build phase was KILLED — a timeout, a signal, an out-of-memory — never
# reaches the engine's post-mortem, so it writes no failure report at all. The
# caller then found a file at the expected path, printed it under a
# "Failed actions for <this target>" banner and archived it under this
# target's name. The file was a day old and belonged to a DIFFERENT target
# that had been built by hand in between. The result was a confident,
# well-formatted, entirely fictional account of a failure that did not happen:
# a named action, an exit code, captured stdout — none of it from the run
# being reported. Three readers took it at face value, and the real cause of
# the run's exit code (the timeout, printed two lines earlier) was passed
# over.
#
# The rule that follows: *a report is attributable only if this invocation
# wrote it.* Two independent mechanisms enforce it, because each covers a hole
# the other leaves.
#
#   1. ``repro_build_report_reset`` removes both reports BEFORE the build
#      runs. Anything present afterwards was therefore written afterwards.
#      This is the only mechanism that does not depend on the report's own
#      contents, so it is the one that still holds if a future report drops
#      the fields checked below.
#   2. Each report is additionally required to NAME THIS SELECTOR ITSELF.
#      The two reports spell that differently and both are checked:
#      ``repro_build_report_is_for`` reads the failure report's top-level
#      ``target``; ``repro_build_report_covers`` reads the success report's
#      ``targetResolution[].selector``. This covers what (1) cannot: a
#      concurrent build in the same tree, a ``rm`` that failed, and the case
#      where someone removes the reset and leaves the copy.
#
# Both reports were checked against real artefacts before this was written,
# because the tempting claim — "the success report carries no target to check,
# so existence is all there is" — is FALSE and was believed once already. The
# archived success report from the run that motivated this library names
# ``"selector":"test-fixtures"`` while sitting under a ``test-builds`` file
# name: the field that exposes the misattribution was present in the evidence
# the whole time. The two spellings differ (the failure report records
# ``.#NAME``, ``targetResolution`` records the bare ``NAME``), which is what
# ``repro_build_report_canonical_selector`` exists to reconcile.
#
# And when neither produces an attributable report, the absence is announced
# rather than passed over in silence — because "no post-mortem was written"
# is itself the diagnosis when a build is killed, and a caller that says
# nothing there is the reason the stale file got read in the first place.

# Default out-dir for a ``repro build`` run at a project root.
REPRO_BUILD_REPORT_DIR_DEFAULT=".repro/build/repro"

repro_build_report_reset() {
  ## Remove any report left by an EARLIER invocation. Call this immediately
  ## before the build whose reports you intend to read.
  ##
  ## The postcondition is CHECKED, not assumed. ``rm -f`` reports success for
  ## a file that was never there and failure for one it could not remove, and
  ## an unchecked removal that quietly did nothing is precisely the shape of
  ## the defect this library exists for — the reset would then be a comment
  ## rather than a guarantee. Non-zero, and loud, when a report survives.
  local dir="${1:-${REPRO_BUILD_REPORT_DIR_DEFAULT}}"
  rm -f "${dir}/build-failure-report.json" "${dir}/build-report.json" \
    2>/dev/null || true
  local survivor status=0
  for survivor in "${dir}/build-failure-report.json" \
                  "${dir}/build-report.json"; do
    if [[ -e "${survivor}" ]]; then
      printf '=== Could not clear a previous build report at %s. Anything read from this directory afterwards may belong to an earlier run and will not be trusted. ===\n' \
        "${survivor}" >&2
      status=1
    fi
  done
  return "${status}"
}

repro_build_report_target() {
  ## Print the ``target`` a failure report names for ITSELF. Non-zero exit
  ## when the file is missing or carries no such field; prints nothing then.
  local file="$1"
  [[ -f "${file}" ]] || return 1
  local raw
  raw="$(tr -d '\n' < "${file}")" || return 1
  [[ "${raw}" =~ \"target\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}

repro_build_report_canonical_selector() {
  ## A bare target name and its ``.#``-qualified spelling name the same
  ## target: the CLI records ``repro build NAME`` as ``.#NAME``. Compare the
  ## qualified form on both sides so a caller that passes the short spelling
  ## is not told its own report belongs to someone else. A selector naming a
  ## different PROJECT (``other.#NAME``) is left alone and so still differs.
  local selector="$1"
  case "${selector}" in
    *'#'*) printf '%s' "${selector}" ;;
    *) printf '.#%s' "${selector}" ;;
  esac
}

repro_build_report_is_for() {
  ## True when ``$1`` is a failure report whose own ``target`` is ``$2``.
  local file="$1" selector="$2" got
  got="$(repro_build_report_target "${file}")" || return 1
  [[ "$(repro_build_report_canonical_selector "${got}")" == \
     "$(repro_build_report_canonical_selector "${selector}")" ]]
}

repro_build_report_selectors() {
  ## Print, one per line, the selectors a SUCCESS report names for ITSELF
  ## under ``targetResolution``. Non-zero exit when the file is missing or
  ## names none; prints nothing then.
  ##
  ## The array is bounded at the first ``]`` deliberately. A ``resolved`` row
  ## holds only scalars, but an ``ambiguous`` or ``unknown`` row carries a
  ## nested ``candidates`` / ``suggestions`` array, and stopping early there
  ## can only DROP selectors — never invent one — so a report this cannot
  ## fully read is refused rather than attributed. The report is one long
  ## line of several megabytes, which is why this greps rather than walking
  ## the document.
  local file="$1"
  [[ -f "${file}" ]] || return 1
  local found
  found="$(tr -d '\n' < "${file}" \
    | grep -oE '"targetResolution"[[:space:]]*:[[:space:]]*\[[^]]*\]' \
    | grep -oE '"selector"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed -E 's/^"selector"[[:space:]]*:[[:space:]]*"(.*)"$/\1/')" || return 1
  [[ -n "${found}" ]] || return 1
  printf '%s\n' "${found}"
}

repro_build_report_covers() {
  ## True when ``$1`` is a report whose own ``targetResolution`` names ``$2``.
  local file="$1" selector="$2" want got
  want="$(repro_build_report_canonical_selector "${selector}")"
  while IFS= read -r got; do
    [[ -n "${got}" ]] || continue
    if [[ "$(repro_build_report_canonical_selector "${got}")" == "${want}" ]]
    then
      return 0
    fi
  done < <(repro_build_report_selectors "${file}")
  return 1
}

repro_build_report_slug() {
  local selector="$1"
  printf '%s' "${selector//[^a-zA-Z0-9]/_}"
}

repro_collect_build_reports() {
  ## Print and archive the reports THIS invocation wrote for ``selector``,
  ## and refuse to attribute any other. Arguments: out-dir, selector, log-dir.
  local dir="$1" selector="$2" logdir="$3"
  local slug
  slug="$(repro_build_report_slug "${selector}")"
  local failure="${dir}/build-failure-report.json"
  local report="${dir}/build-report.json"
  local attributed=0
  mkdir -p "${logdir}"

  if repro_build_report_is_for "${failure}" "${selector}"; then
    attributed=1
    printf '\n=== Failed actions for %s (from %s) ===\n' \
      "${selector}" "${failure}" >&2
    if command -v jq >/dev/null 2>&1; then
      jq '{counts, failedActions, blockedActions}' "${failure}" >&2 || true
    else
      cat "${failure}" >&2 || true
    fi
    cp "${failure}" "${logdir}/build-failure-report-${slug}.json" \
      2>/dev/null || true
  elif [[ -f "${failure}" ]]; then
    printf '\n=== Ignoring a failure report that is not this build'\''s: %s names target %s, not %s ===\n' \
      "${failure}" "$(repro_build_report_target "${failure}")" "${selector}" >&2
  fi

  if repro_build_report_covers "${report}" "${selector}"; then
    cp "${report}" "${logdir}/build-report-${slug}.json" 2>/dev/null || true
  elif [[ -f "${report}" ]]; then
    local named
    named="$(repro_build_report_selectors "${report}" | tr '\n' ' ')"
    printf '=== Ignoring a build report that is not this build'\''s: %s names %s, not %s ===\n' \
      "${report}" "${named:-no target it could be read from}" "${selector}" >&2
  fi

  if (( attributed == 0 )); then
    printf '=== No failure report was written for %s: the engine never reached its post-mortem (killed, timed out, or died before planning). The exit status above is the diagnosis; there are no failed actions to list. ===\n' \
      "${selector}" >&2
  fi
}
