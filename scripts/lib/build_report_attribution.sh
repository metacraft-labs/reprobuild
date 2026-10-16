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
#
# THE SAME RULE, ONE DIRECTORY LATER. Everything above protects the OUT-DIR
# copy. The copy people actually open is the one ``repro_collect_build_reports``
# archives into the log directory as ``build-report-<slug>.json`` /
# ``build-failure-report-<slug>.json`` — and that name carries no date or
# revision either, so it goes stale by exactly the same mechanism if anything
# lets it outlive its build. Something did: the collector used to be called
# only for FAILED builds, so a successful build archived nothing and the
# previous archive kept the current name. Measured (reprobuild-pm
# ``issues/2026-09-24-successful-build-report-never-archived.md``): a
# 3,074,899,124-byte ``build-report-__test_builds.json`` dated 2026-09-12 was
# read on 2026-09-23 as the report of that day's ``.#test-builds`` runs, all of
# which had succeeded. Hence the second rule: *a file in the log directory named
# for a collection never describes an earlier build than the latest one run for
# that collection.* The collector is called on every outcome, removes the
# collection's earlier archives first (checked, like the reset), and leaves the
# name ABSENT rather than stale when this build wrote nothing attributable or a
# copy failed.

# Default out-dir for a ``repro build`` run at a project root.
REPRO_BUILD_REPORT_DIR_DEFAULT=".repro/build/repro"

# The status a caller returns for a FAILED build whose archived failure report
# cannot be trusted to be this build's: the out-dir could not be reset, or the
# collector could not remove an earlier archive (or could not archive this
# one). A consumer of the archive -- ``scripts/drop_failed_test_binaries.py``
# deletes the binaries a failure report names -- must then not read it, and
# must take its "cannot tell which binaries are stale" path instead. Chosen
# outside every status ``repro`` and ``timeout`` are known to return (0-5,
# 124-127, 128+N); should a build ever exit with it, the consumer stops, which
# is the safe direction.
REPRO_BUILD_REPORT_UNTRUSTED_STATUS=86

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
  # Read a bounded TAIL first, and only fall back to the whole document.
  #
  # ``targetResolution`` is emitted near the END of the report — after it come
  # only ``runQuota`` and ``stats``, both small and fixed-shape — so the tail
  # holds it in practice. That matters enormously, because the comment above
  # understates the size: the success report for ``.#test-builds`` was
  # MEASURED at 2,515,919,084 bytes on a single line. ``grep`` must buffer a
  # whole line before it can match, so scanning the document to find a field
  # sitting in its last ~300 bytes cost ~72 minutes and ~1.7 GB of RSS, once
  # per call — and ``repro_collect_build_reports`` calls this again on the
  # mismatch path, per selector. On the run that found this, the suite had
  # spent 50 minutes in that grep, after a 5h31m build, without running a
  # single test.
  #
  # The fallback keeps this a speed change and not a behaviour change: if a
  # future emitter moves the field out of the tail, the whole-document read
  # still answers, at the old cost. Both paths share one filter so they cannot
  # drift apart, and the array is still bounded at the first ``]`` exactly as
  # before.
  found="$(tail -c "${REPRO_BUILD_REPORT_TAIL_BYTES:-65536}" "${file}" \
    | repro_build_report_selector_filter)"
  [[ -n "${found}" ]] ||
    found="$(repro_build_report_selector_filter < "${file}")"
  [[ -n "${found}" ]] || return 1
  printf '%s\n' "${found}"
}

repro_build_report_selector_filter() {
  ## stdin (report text) -> one selector per line. Shared by the bounded and
  ## the whole-document reads in ``repro_build_report_selectors`` so the two
  ## can never disagree about what a selector is.
  tr -d '\n' \
    | grep -oE '"targetResolution"[[:space:]]*:[[:space:]]*\[[^]]*\]' \
    | grep -oE '"selector"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed -E 's/^"selector"[[:space:]]*:[[:space:]]*"(.*)"$/\1/'
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

repro_build_report_archive() {
  ## Copy ``$1`` to ``$2``, or leave NOTHING at ``$2``. Non-zero, and loud,
  ## when the copy failed.
  ##
  ## A ``cp`` that fails part-way — a full disk is the realistic cause, and
  ## the success report of ``.#test-builds`` is measured in gigabytes — can
  ## leave a truncated file at the destination. A truncated archive under a
  ## collection's name is a stale one by another route: it is not the report
  ## this build wrote, and nothing in its name says so. So the partial file
  ## is removed, and the removal is itself checked.
  ##
  ## Plain ``cp``, deliberately. ``cp --reflink=auto`` would make the
  ## gigabyte copy free on a CoW filesystem, but it is a GNU option: the BSD
  ## ``cp`` on macOS rejects it, and this library runs there and under
  ## Windows git-bash as well.
  local source="$1" dest="$2"
  if cp "${source}" "${dest}" 2>/dev/null; then
    return 0
  fi
  rm -f "${dest}" 2>/dev/null || true
  if [[ -e "${dest}" ]]; then
    printf '=== Could not archive %s to %s, and a partial copy is left there that could not be removed. It is NOT this build'\''s report; do not read it. ===\n' \
      "${source}" "${dest}" >&2
  else
    printf '=== Could not archive %s to %s; nothing is archived under that name for this build. ===\n' \
      "${source}" "${dest}" >&2
  fi
  return 1
}

repro_build_report_clear_archive() {
  ## Remove the copies an EARLIER invocation archived for this collection,
  ## ``<logdir>/build-report-<slug>.json`` and
  ## ``<logdir>/build-failure-report-<slug>.json``. Arguments: log-dir, slug.
  ##
  ## The log-directory twin of ``repro_build_report_reset``, and checked the
  ## same way for the same reason: ``rm -f`` succeeds on a file that was never
  ## there, so an unchecked removal that did nothing would leave the rule
  ## below resting on a command nobody looked at. Non-zero, and loud, when a
  ## copy survives — and the message names it, because a survivor is exactly
  ## the file a reader would otherwise take for this build's.
  local logdir="$1" slug="$2"
  local archived status=0
  for archived in "${logdir}/build-report-${slug}.json" \
                  "${logdir}/build-failure-report-${slug}.json"; do
    rm -f "${archived}" 2>/dev/null || true
    if [[ -e "${archived}" ]]; then
      printf '=== Could not remove a previously archived build report at %s. It describes an EARLIER build than this one and must not be read as this build'\''s. ===\n' \
        "${archived}" >&2
      status=1
    fi
  done
  return "${status}"
}

repro_collect_build_reports() {
  ## Print and archive the reports THIS invocation wrote for ``selector``,
  ## and refuse to attribute any other. Arguments: out-dir, selector,
  ## log-dir, and — optional — the build's exit status.
  ##
  ## CALL THIS ON EVERY OUTCOME, success included. The rule it keeps for the
  ## log directory is: *a file there named for a collection never describes
  ## an earlier build than the latest one run for that collection.* So the
  ## first thing it does is remove this collection's previously archived
  ## copies; only then does it archive what THIS build wrote. If this build
  ## wrote nothing attributable — killed, a report naming another target, a
  ## copy that failed — the name is then simply absent, which is the truth,
  ## instead of holding an earlier build's file.
  ##
  ## That rule was broken, and measured broken, while this was called only
  ## for FAILED builds (reprobuild-pm
  ## ``issues/2026-09-24-successful-build-report-never-archived.md``): a
  ## successful build archived nothing, and the archive an earlier build had
  ## left kept the current name. In the worktree of the 2026-09-23 suite runs
  ## ``test-logs/build-report-__test_builds.json`` was 3,074,899,124 bytes and
  ## dated 2026-09-12 — eleven days old, read as current, with nothing in its
  ## name to say so — while every ``.#test-builds`` run on 2026-09-23 had
  ## succeeded.
  ##
  ## The exit status decides only what is SAID about an absent failure
  ## report. On a success there is none to find and the "never reached its
  ## post-mortem" diagnosis would be false, so it is not printed. Omitted,
  ## the status is treated as a failure, which is what every caller meant
  ## before the argument existed.
  ##
  ## Non-zero when an earlier archive could not be removed or a copy failed:
  ## either way the log directory does not hold exactly this build's reports,
  ## and both have already been announced on stderr. The attribution
  ## outcome itself — nothing attributable is a legitimate result — does
  ## not make this fail.
  local dir="$1" selector="$2" logdir="$3" build_status="${4:-1}"
  local slug
  slug="$(repro_build_report_slug "${selector}")"
  local failure="${dir}/build-failure-report.json"
  local report="${dir}/build-report.json"
  local attributed=0 status=0
  mkdir -p "${logdir}"
  repro_build_report_clear_archive "${logdir}" "${slug}" || status=1

  if repro_build_report_is_for "${failure}" "${selector}"; then
    attributed=1
    printf '\n=== Failed actions for %s (from %s) ===\n' \
      "${selector}" "${failure}" >&2
    if command -v jq >/dev/null 2>&1; then
      jq '{counts, failedActions, blockedActions}' "${failure}" >&2 || true
    else
      cat "${failure}" >&2 || true
    fi
    repro_build_report_archive "${failure}" \
      "${logdir}/build-failure-report-${slug}.json" || status=1
  elif [[ -f "${failure}" ]]; then
    printf '\n=== Ignoring a failure report that is not this build'\''s: %s names target %s, not %s ===\n' \
      "${failure}" "$(repro_build_report_target "${failure}")" "${selector}" >&2
  fi

  if repro_build_report_covers "${report}" "${selector}"; then
    repro_build_report_archive "${report}" \
      "${logdir}/build-report-${slug}.json" || status=1
  elif [[ -f "${report}" ]]; then
    local named
    named="$(repro_build_report_selectors "${report}" | tr '\n' ' ')"
    printf '=== Ignoring a build report that is not this build'\''s: %s names %s, not %s ===\n' \
      "${report}" "${named:-no target it could be read from}" "${selector}" >&2
  elif (( build_status == 0 )); then
    # ``--write-report`` was asked for and the build succeeded, so a report
    # was owed. Its absence is worth one line, because the archive name is
    # now empty and a reader looking for it should learn why here.
    printf '=== No build report was written for %s although it succeeded; nothing is archived under its name. ===\n' \
      "${selector}" >&2
  fi

  if (( attributed == 0 && build_status != 0 )); then
    printf '=== No failure report was written for %s: the engine never reached its post-mortem (killed, timed out, or died before planning). The exit status above is the diagnosis; there are no failed actions to list. ===\n' \
      "${selector}" >&2
  fi
  return "${status}"
}
