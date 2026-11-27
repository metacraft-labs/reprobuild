# shellcheck shell=bash
#
# scripts/lib/sibling_verdicts.sh — judge the workspace siblings `config.nims`
# compiles from, for evaluations of it that cannot judge them themselves.
#
# `nim check` and nimsuggest evaluate `config.nims` with `gorgeEx` answering
# ("", 0) for every command, so the file cannot ask git whether a sibling
# checkout is behind the revision this repository pins for it, and keeps the
# sibling. `nim c` in the same shell would have replaced a stale sibling with
# the pinned tree `$<PKG>_SRC` names. So the `nim check` sweep of `just lint`
# compiled a stale `../nim-cli-spec`, failed on `undeclared identifier`, and
# nothing named the sibling (measured 2026-11-26).
#
# `judge_config_siblings` evaluates `config.nims` once where git runs (`nim
# dump`, which runs the configuration stage and compiles nothing), with
# `REPRO_SIBLING_VERDICTS_OUT` asking it to write its verdicts
# (`sibling_source_policy.formatSiblingVerdict`: `<kind>\t<PKG>_SRC\t<message>`
# per line). It then
#
#   * prints every verdict's message once, on stderr;
#   * adds each `pin` verdict's `<PKG>_SRC` to `REPRO_SIBLING_PINNED`, so every
#     later evaluation takes the pinned tree for it, as `nim c` does;
#   * exports `REPRO_SIBLING_JUDGED=1`, so no later evaluation repeats a report
#     or says it could not judge.
#
# Call it from the directory whose `config.nims` the later evaluations load,
# with the environment they will run in (the `$<PKG>_SRC` variables set).
# Returns non-zero, having said why, when the judging evaluation fails: a
# sweep that went on would compile whatever it found, unjudged.

judge_config_siblings() {
  local work verdicts log status=0
  work="$(mktemp -d)" || return 1
  verdicts="${work}/verdicts"
  log="${work}/dump.log"
  # The project file need not exist: `nim dump` never opens it.
  REPRO_SIBLING_VERDICTS_OUT="${verdicts}" \
    REPRO_SIBLING_JUDGED='' \
    nim dump --hints:off ./__sibling_verdicts_probe__.nim >"${log}" 2>&1 ||
    status=$?
  if (( status != 0 )); then
    # shellcheck disable=SC2016 # the backquotes are literal: they quote a command
    printf 'judge_config_siblings: evaluating config.nims with `nim dump` failed (exit %s), so the workspace siblings it compiles from could not be judged against their pins:\n' \
      "${status}" >&2
    sed 's/^/  /' "${log}" >&2
    rm -rf "${work}"
    return 1
  fi
  local pinned="${REPRO_SIBLING_PINNED:-}" kind env_name message
  if [[ -f "${verdicts}" ]]; then
    while IFS=$'\t' read -r kind env_name message; do
      [[ -n "${kind}" ]] || continue
      printf '%s\n' "${message}" >&2
      if [[ "${kind}" == pin ]]; then
        pinned="${pinned:+${pinned},}${env_name}"
      fi
    done <"${verdicts}"
  fi
  rm -rf "${work}"
  export REPRO_SIBLING_PINNED="${pinned}"
  export REPRO_SIBLING_JUDGED=1
}
