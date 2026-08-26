#!/usr/bin/env bash
#
# scripts/check_dev_shell_env.sh — lint gate for the two ways this repository's
# dev shell can lie about what it is built from.
#
# Offline and cheap by construction, because it has to run in `just lint`
# alongside checks that answer before a six-hour build phase. It asserts:
#
#   1. Every `NIX_FLAKE_OVERRIDE_*` knob `.envrc` sets is a knob this
#      repository knows how to verify, and `.envrc` actually runs the guard
#      that verifies it. This is the static half of the silent-plugin defect:
#      a knob added without a probe, or a probe removed from `.envrc`, brings
#      back exactly the state where `NIX_FLAKE_OVERRIDE_AUTO=1` produced no
#      `--override-input` at all and nothing said so.
#
#   2. The cached dev shell on this machine, if there is one, was built from
#      the sources that are on disk now. `.direnv/flake-profile-*.rc` hard-codes
#      a store path per overridden input; nothing in nix-direnv's watch set
#      mentions the sibling working trees those paths were copied from, so the
#      cache can outlive its inputs indefinitely — measured at fifteen days and
#      fifty-nine commits for `RUNQUOTA_SRC`, which is what made `just lint`
#      fail for everyone with a spurious `undeclared identifier`.
#
# Every assertion is positive: each one names something it must FIND, so a
# scan that matches nothing fails rather than passing quietly.

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/lib/dev_shell_overrides.sh
source "$REPO_ROOT/scripts/lib/dev_shell_overrides.sh"

failures=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

envrc="$REPO_ROOT/.envrc"
if [[ ! -f "$envrc" ]]; then
  fail ".envrc is missing; the dev-shell contract has nothing to check"
  exit 1
fi

# --- 1. knobs -------------------------------------------------------------

mapfile -t declared < <(dev_shell_declared_override_knobs "$envrc")

if [[ ${#declared[@]} -eq 0 ]]; then
  # Not "nothing to do". `.envrc` reaching zero knobs means the override
  # mechanism was deleted rather than scoped, and the reason it existed —
  # building against workspace siblings — would then have to be inferred from
  # an absence. A knob declared empty is a statement; a missing knob is not.
  fail ".envrc names no NIX_FLAKE_OVERRIDE_* knob at all. The dev shell's
      relationship to the workspace siblings must be stated in the file, even
      when the answer is 'none by default'; do not leave it to be inferred
      from an absence."
fi

for knob in "${declared[@]}"; do
  known=0
  for candidate in "${DEV_SHELL_KNOWN_OVERRIDE_KNOBS[@]}"; do
    [[ "$knob" == "$candidate" ]] && known=1 && break
  done
  if [[ "$known" -ne 1 ]]; then
    fail ".envrc sets $knob, which scripts/lib/dev_shell_overrides.sh has no
      probe for. An unprobed knob is a knob that can go inert without anyone
      finding out — add it to DEV_SHELL_KNOWN_OVERRIDE_KNOBS with a
      _dev_shell_probe_* function."
  fi
done

if [[ ${#declared[@]} -gt 0 ]]; then
  if ! grep -Fq 'dev_shell_guard_override_knobs' "$envrc"; then
    fail ".envrc sets ${declared[*]} but never calls
      dev_shell_guard_override_knobs. Without it a plugin that ignores those
      knobs loads, emits nothing, and the shell is built from the pinned
      inputs while .envrc says otherwise."
  fi
  if ! grep -Fq 'dev_shell_write_fingerprint' "$envrc" ||
    ! grep -Eq 'watch_file[[:space:]]+"?\$?_?fo_fingerprint|watch_file[[:space:]]+"?\.direnv/flake-override-sources\.fingerprint' "$envrc"; then
    fail ".envrc resolves overrides to local paths but does not write and
      watch_file the override-source fingerprint. direnv watches flake.nix,
      flake.lock and the direnvrc files and nothing else, so without the
      fingerprint a sibling working tree can advance without ever
      invalidating .direnv/flake-profile-*.rc."
  fi
fi

# --- 2. the flake expression's own watch set -------------------------------
#
# nix-direnv adds `flake.nix` / `flake.lock` to the watch set only when the
# flake expression names a DIRECTORY (`[[ -d $flake_dir ]]`). This repo's
# expression carries a query string — `.?submodules=1` — which is not a
# directory, so neither file was watched and an edit to either left the cached
# shell in place. `.envrc` therefore has to watch them itself, and this is the
# check that says so if it ever stops.
flake_expr="$(sed -n "s/.*use flake '\{0,1\}\([^' ]*\).*/\1/p" "$envrc" |
  head -n 1)"
if [[ -n "$flake_expr" ]]; then
  if [[ ! -d "${flake_expr%%\?*}" || "$flake_expr" == *'?'* ]]; then
    for watched in flake.nix flake.lock; do
      if ! grep -Eq "^[[:space:]]*watch_file[[:space:]]+\"?${watched}\"?[[:space:]]*$" \
        "$envrc"; then
        fail ".envrc runs \`use flake $flake_expr\`, whose expression is not a
      bare directory, so nix-direnv does not add $watched to the watch set.
      .envrc must \`watch_file $watched\` itself, or an edit to it leaves the
      cached dev shell in place and the shell keeps serving the previous
      environment."
      fi
    done
  fi
else
  fail "no \`use flake\` invocation found in .envrc; this check cannot tell
      whether the flake's own files are watched, and silence is not a pass."
fi

# --- 3. cache freshness ---------------------------------------------------

shopt -s nullglob
profiles=("$REPO_ROOT"/.direnv/flake-profile-*.rc)
shopt -u nullglob
fingerprint="$REPO_ROOT/.direnv/flake-override-sources.fingerprint"

if [[ ${#profiles[@]} -eq 0 ]]; then
  printf 'dev-shell: no .direnv/flake-profile-*.rc on this machine; %s\n' \
    'cache-freshness check has nothing to compare (fresh checkout / CI).'
else
  # The half of the staleness problem that needs no overrides at all.
  # nix-direnv DOES watch flake.lock — but only compares it against the
  # profile when direnv re-evaluates `.envrc`, which happens on entering the
  # directory. A shell that is already inside it, a `just lint` fired from a
  # git hook, or an editor holding an inherited environment never triggers
  # that comparison, so a profile can sit arbitrarily older than the lock it
  # claims to be built from. Measured across this workspace: caches between
  # six and twenty-seven days behind their own watched files, still in use.
  for watched in flake.lock flake.nix; do
    [[ -f "$REPO_ROOT/$watched" ]] || continue
    if [[ "$REPO_ROOT/$watched" -nt "${profiles[0]}" ]]; then
      fail "$watched is newer than the cached dev shell
      (${profiles[0]#"$REPO_ROOT"/}). direnv only compares them when it
      re-evaluates .envrc, which this process did not do, so every tool run
      from here is built against the inputs the lock named at
      $(date -r "${profiles[0]}" '+%Y-%m-%d %H:%M' 2>/dev/null) and not the
      ones it names now. Remedy: run 'direnv reload', or
      'rm -f .direnv/flake-profile*' and re-enter the directory."
    fi
  done
fi

if [[ ${#profiles[@]} -eq 0 ]]; then
  :
elif [[ ! -f "$fingerprint" ]]; then
  fail "no $(basename "$fingerprint") beside the cached dev shell
      (${profiles[0]#"$REPO_ROOT"/}). That cache was written before the
      override sources were recorded, so nothing can say what it was built
      from — which is precisely the state that let RUNQUOTA_SRC sit fifteen
      days stale. Remedy: rm -f .direnv/flake-profile* and re-enter the
      directory (or run 'direnv reload')."
else
  drift="$(dev_shell_fingerprint_drift "$fingerprint")"
  if [[ -n "$drift" ]]; then
    printf 'FAIL: the cached dev shell was built from sources that have since moved:\n' >&2
    while IFS=$'\t' read -r input dir was now; do
      printf '  %s\n      path:      %s\n      cached at: %s\n      now:       %s\n' \
        "$input" "$dir" "$was" "$now" >&2
    done <<<"$drift"
    printf '%s\n' \
      '  The cached .direnv/flake-profile-*.rc still exports the store path' \
      '  each of those was copied to, so every build in this shell compiles' \
      '  against the old source. Remedy: run "direnv reload", or' \
      '  "rm -f .direnv/flake-profile*" and re-enter the directory.' >&2
    failures=$((failures + 1))
  else
    recorded="$(grep -cve '^#' -e '^$' "$fingerprint")"
    if [[ "$recorded" -eq 0 ]]; then
      printf 'dev-shell: %s\n' \
        'no path: overrides configured; the cached shell is built from the pinned inputs, as .envrc declares.'
    else
      printf 'dev-shell: cached shell matches all %d overridden source(s).\n' \
        "$recorded"
    fi
  fi
fi

if [[ "$failures" -gt 0 ]]; then
  printf '\ncheck_dev_shell_env: %d failure(s)\n' "$failures" >&2
  exit 1
fi

printf 'check_dev_shell_env: ok (%d knob(s) declared, all probed)\n' \
  "${#declared[@]}"
