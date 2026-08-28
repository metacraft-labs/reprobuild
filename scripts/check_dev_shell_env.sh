#!/usr/bin/env bash
#
# scripts/check_dev_shell_env.sh — lint gate for the three ways this
# repository's dev shell can lie about what it is built from.
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
#   2. Every input whose repository is checked out beside this one is an input
#      the override arm can actually REACH. The other two assertions both take
#      the overridden set as given — the probes ask whether the plugin acts,
#      the fingerprint reconciles what it acted on — so an input the arm never
#      considered was outside both. `stackable-hooks-src` stripped to
#      `stackable-hooks` while the checkout was `../nim-stackable-hooks`, so
#      it alone kept building from a lock pin 30 commits behind, and this gate
#      passed throughout.
#
#   3. The cached dev shell on this machine, if there is one, was built from
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

# --- 3. the auto arm actually reaches every sibling ------------------------
#
# Checks 1 and 2 both take the set of overridden inputs as given: the knob
# probes ask whether the plugin acts, and the fingerprint below reconciles the
# sources it acted ON. Neither can see an input the plugin never considered, so
# an input that is quietly NOT overridden while its siblings all are was
# invisible to this gate by construction — and that is what happened.
# `stackable-hooks-src` strips to `stackable-hooks`; the checkout is
# `../nim-stackable-hooks`; the auto arm matched nothing; the input stayed on a
# lock pin 30 commits behind the working tree that every other input tracked,
# across the commit that added the `WindowsInjectionResult` fields io-mon's
# Windows arm reads. Nothing failed, because nothing was looking.
#
# This is the check that looks. It needs no plugin, no nix evaluation and no
# network: an input's `url` names its upstream repository, the auto arm looks
# for a directory named after the stripped input, and when those two disagree
# while the repository IS checked out beside us, the arm is reaching for a path
# that does not exist.

# The declared exceptions live beside this script as DATA, not as a here-doc
# inside it: `scripts/dev-shell-pinned-siblings.tsv`, one
# `input<TAB>kind<TAB>reason` row each. Data because the list describes ONE
# flake — this repository's — while the script is copied into synthetic trees
# by tests/integration/t_dev_shell_override_guards.nim, and a list baked into
# the script would there excuse inputs that the tree does not have.
#
# A missing file is not an empty file: with no rows, every finding is
# undeclared and check 3 refuses. See the file's own header for the contract.
pinned_siblings="$REPO_ROOT/scripts/dev-shell-pinned-siblings.tsv"
declared_unreached() {
  [[ -f "$pinned_siblings" ]] || return 0
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$pinned_siblings" || true
}

if [[ ! -f "$REPO_ROOT/flake.nix" ]]; then
  # Announced, not silent — and not a `fail` either, because the assertion
  # "this repository has a flake.nix" already has an owner:
  # `scripts/check_repo_requirements.sh` lists it among the files it refuses to
  # run without, in the same `just lint` invocation. Duplicating it here would
  # only mean that the synthetic trees the regression tests build (which carry
  # the scripts and an `.envrc` and nothing else) could no longer exercise the
  # other two checks.
  printf 'dev-shell: no flake.nix here; %s\n' \
    'the auto-override reachability check has no inputs to resolve (check_repo_requirements.sh owns its existence).'
else
  mapfile -t input_repos < <(dev_shell_flake_input_repos "$REPO_ROOT/flake.nix")
  url_count="$(dev_shell_flake_input_url_count "$REPO_ROOT/flake.nix")"
  if [[ ${#input_repos[@]} -eq 0 ]]; then
    # Positive assertion, like every other one here: a parser that matched
    # nothing is indistinguishable from a flake with no problems.
    fail "no flake input with an upstream url could be parsed out of
      flake.nix. This check would then pass on any flake at all, including the
      one it exists to catch. Fix dev_shell_flake_input_repos rather than
      accepting the empty result."
  elif [[ "${#input_repos[@]}" -ne "$url_count" ]]; then
    # And a PARTIAL parse is worse than none, because the inputs it stopped
    # matching are exactly the ones it stops examining, which is silent. The
    # count is taken independently of the structural parse for that reason.
    fail "flake.nix's inputs block contains $url_count url assignment(s) but
      dev_shell_flake_input_repos matched ${#input_repos[@]}. The parser keys on
      the block's shape, so an input written differently drops out of this
      check without a word — and dropping out reads exactly like being fine.
      Fix the parser in scripts/lib/dev_shell_overrides.sh; do not adjust the
      count to match it."
  fi

  mapfile -t unreached < <(dev_shell_unreached_siblings \
    "$REPO_ROOT/flake.nix" "$envrc" "$REPO_ROOT")

  # A row is only allowed to excuse an input if it actually SAYS SOMETHING. The
  # third column is the whole point of the file — an entry is a statement with
  # a name on it, not a suppression — but nothing enforced that, so
  # `input<TAB>kind` with the reason left off parsed fine and silenced the
  # finding without a word of justification. Enforced here, in the same spirit
  # as the stale-declaration arm below: the ways this list can decay into a
  # list nobody reads all have to be failures.
  declare -A declared_kind=() declared_seen=()
  while IFS=$'\t' read -r d_input d_kind d_reason; do
    [[ -n "$d_input" ]] || continue
    case "$d_kind" in
      unreachable | unflakeable) ;;
      *)
        fail "scripts/dev-shell-pinned-siblings.tsv row for '$d_input' has kind
      '$d_kind', which is neither 'unreachable' nor 'unflakeable'. A kind the
      check does not recognise matches no finding, so the row excuses nothing
      and the input it names is reported as undeclared — or, if the columns are
      shifted, excuses the wrong thing. Remedy: fix the row; the columns are
      tab-separated <input> <kind> <reason>."
        continue
        ;;
    esac
    if [[ -z "${d_reason//[[:space:]]/}" ]]; then
      fail "scripts/dev-shell-pinned-siblings.tsv excuses flake input
      '$d_input' as '$d_kind' but gives no reason. The reason column is what
      separates a declared exception from a silenced one: without it the row
      turns this gate off for that input and leaves nobody to ask why. Remedy:
      say why the pin is deliberate, or delete the row and fix the input."
      continue
    fi
    declared_kind["$d_input"]="$d_kind"
  done < <(declared_unreached)

  undeclared=0
  for line in "${unreached[@]}"; do
    IFS=$'\t' read -r kind input stripped repo sibling <<<"$line"
    [[ -n "$input" ]] || continue
    if [[ "${declared_kind[$input]:-}" == "$kind" ]]; then
      declared_seen["$input"]=1
      continue
    fi
    undeclared=$((undeclared + 1))
    if [[ "$kind" == "unreachable" ]]; then
      fail "flake input '$input' is pinned, but the repository it names is
      checked out beside this one and every comparable input tracks its
      sibling. .envrc's auto-override arm strips '-src' and looks for
      '$(dirname "$REPO_ROOT")/$stripped', which does not exist; the checkout is
      '$sibling', named after the repository '$repo'. So this input alone stays
      on its flake.lock revision, drifting behind the tree its neighbours
      build from, and no other check here can see it — the fingerprint below
      reconciles overridden inputs, and this one is never overridden.
      Remedy: rename the input to '$repo-src' so the arm reaches it (and
      refresh flake.lock), or add a row to
      scripts/dev-shell-pinned-siblings.tsv saying why the pin is deliberate."
    else
      fail "flake input '$input' has a sibling checkout at '$sibling', but that
      directory has no flake.nix, so the flake-overrides plugin will not emit
      an --override-input for it. The input therefore builds from its
      flake.lock pin while the checkout beside it moves, and nothing else in
      this gate can tell. Remedy: add a flake.nix to that repository, or add
      a row to scripts/dev-shell-pinned-siblings.tsv saying why the pin is
      deliberate."
    fi
  done

  while IFS=$'\t' read -r d_input d_kind _d_reason; do
    [[ -n "$d_input" ]] || continue
    # Rows the loop above already rejected have had their say; reporting them
    # again as "stopped describing anything" would only bury the real reason.
    [[ -n "${declared_kind[$d_input]:-}" ]] || continue
    if [[ -z "${declared_seen[$d_input]:-}" ]]; then
      fail "scripts/dev-shell-pinned-siblings.tsv still excuses flake input
      '$d_input' as '$d_kind', but the check no longer reports it — the input
      was renamed, removed, or its sibling now resolves. A declaration that
      has stopped describing anything is how a list of real exceptions turns
      into a list nobody reads. Remedy: delete the row."
    fi
  done < <(declared_unreached)

  printf 'dev-shell: %d flake input(s) examined for auto-override reachability; %d unreached (%d declared, %d NOT declared).\n' \
    "${#input_repos[@]}" "${#unreached[@]}" \
    "$(( ${#unreached[@]} - undeclared ))" "$undeclared"
fi

# --- 4. cache freshness ---------------------------------------------------

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
