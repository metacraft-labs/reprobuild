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

  # A row that no longer matches a finding is one of two very different
  # things, and conflating them is what made this gate impossible to satisfy.
  #
  # Every finding above begins with "the sibling exists", so the finding set is
  # a function of WHICH REPOSITORIES THIS WORKSPACE HAPPENS TO HAVE CHECKED
  # OUT. The declaration file is one file for all of them. Held to an exact
  # match in both directions, a row for a sibling that CI does not clone fails
  # in CI, and deleting it fails in the workspace that does clone it — the same
  # row, both polarities, no possible content. `nim-stew-src` and
  # `nim-results-src` were deleted on 2026-09-01 to fix the CI half; from that
  # day a CodeTracer-flavoured workspace (which checks both out) failed the
  # other half, and since the pre-commit hook runs `just lint`, this repository
  # accepted NO COMMIT AT ALL in such a workspace.
  #
  # So the arm asks the shape question first: is the sibling this row is about
  # even here? If it is not, the row describes another workspace, which is not
  # evidence of decay — it is reported by name and passed over. If it IS here
  # and the check still does not report it, the row has genuinely stopped
  # describing anything (the input was renamed, removed, or the sibling now
  # resolves) and that is the failure this arm exists for. The detection the
  # arm was built for is untouched: it turns on the sibling being present,
  # which is the same condition every finding turns on.
  inapplicable=()
  while IFS=$'\t' read -r d_input d_kind _d_reason; do
    [[ -n "$d_input" ]] || continue
    # Rows the loop above already rejected have had their say; reporting them
    # again as "stopped describing anything" would only bury the real reason.
    [[ -n "${declared_kind[$d_input]:-}" ]] || continue
    [[ -z "${declared_seen[$d_input]:-}" ]] || continue
    # Decay that is true in EVERY workspace, so it is asked first and is not
    # subject to the shape question at all: the row names an input this flake
    # does not declare with a REPOSITORY url, which is an input no shape can
    # ever produce a finding for.
    if ! dev_shell_flake_declares_input "$REPO_ROOT/flake.nix" "$d_input"; then
      fail "scripts/dev-shell-pinned-siblings.tsv excuses flake input
      '$d_input' as '$d_kind', but flake.nix declares no such input with a
      repository url — it was renamed or removed, it is a pure 'follows', or
      its url is a 'path:'/'file:' that names no repository. Every finding
      starts from a sibling repository checkout, so this row can never match a
      finding in any workspace. Remedy: delete the row, or point it at the
      input's new name."
      continue
    fi
    if ! dev_shell_declared_row_is_applicable \
      "$REPO_ROOT/flake.nix" "$envrc" "$REPO_ROOT" "$d_input"; then
      inapplicable+=("$d_input")
      continue
    fi
    fail "scripts/dev-shell-pinned-siblings.tsv still excuses flake input
      '$d_input' as '$d_kind', but the check no longer reports it while the
      sibling it is about IS checked out beside this repository — its sibling
      now resolves, or the finding changed kind. A declaration that has stopped
      describing anything is how a list of real exceptions turns into a list
      nobody reads. Remedy: delete the row."
  done < <(declared_unreached)

  printf 'dev-shell: %d flake input(s) examined for auto-override reachability; %d unreached (%d declared, %d NOT declared).\n' \
    "${#input_repos[@]}" "${#unreached[@]}" \
    "$(( ${#unreached[@]} - undeclared ))" "$undeclared"
  if [[ ${#inapplicable[@]} -gt 0 ]]; then
    # Named, not dropped. A row can only be passed over because its subject is
    # absent HERE; a reader of this output has to be able to see which rows are
    # describing some other workspace, or a file that has become inapplicable
    # in every shape would decay unobserved — which is the concern the
    # stale-declaration arm was written for in the first place.
    printf 'dev-shell: %d declared row(s) describe siblings not checked out in this workspace (not stale, not applicable here): %s\n' \
      "${#inapplicable[@]}" "${inapplicable[*]}"
  fi
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

# --- 5. one glibc reaches a dev-shell subprocess ---------------------------
#
# Checks 1-4 are all about what the shell is BUILT from. This one is about what
# the shell DOES to the processes started inside it, which is a separate way
# for it to lie: `flake.nix` exports `LD_LIBRARY_PATH`, and automatic
# monitoring `LD_PRELOAD`s `build/lib/librepro_monitor_shim.so`. Both are
# process-global and both apply to binaries the shell neither built nor
# provides — including `git`, which reprobuild shells out to for every remote
# operation it performs.
#
# When the shell's libraries come from a newer glibc than the `git` on PATH,
# the older `libc.so.6` cannot satisfy the newer satellite libraries' symbol
# versions and git dies before `main`. That is not hypothetical: it is what
# made `git fetch` / `git push` / `git clone` over https impossible in this
# shell, and what made `repro build '.#test#<name>'` — the loop for iterating
# on one test at a time — unable to run ANY git-using test, since the
# first `git init` inside a monitored `test_execute` action could not start.
#
# See scripts/lib/dev_shell_overrides.sh for why the comparison is on symbol
# VERSIONS and not on glibc store paths.
case "$(uname -s)" in
  Linux)
    llp_dirs=0
    if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
      llp_dirs="$(awk -F: '{ n = 0; for (i = 1; i <= NF; i++) if ($i != "") n++; print n }' <<<"$LD_LIBRARY_PATH")"
    fi
    shim_present=no
    [[ -f "$REPO_ROOT/build/lib/librepro_monitor_shim.so" ]] && shim_present=yes
    if [[ "$llp_dirs" -eq 0 && "$shim_present" == "no" ]]; then
      # Not a pass dressed up as one: with neither channel present there is no
      # loader state to inject, so there is nothing this check could be wrong
      # about. It is reported so that a reader of a green log can tell "no
      # injection configured" from "injection checked and clean" — those are
      # very different states and a bare "ok" would conflate them.
      printf 'dev-shell: no loader injection in this environment %s\n' \
        '(LD_LIBRARY_PATH empty and no build/lib/librepro_monitor_shim.so); nothing to check.'
    elif ! command -v patchelf >/dev/null 2>&1 ||
      ! command -v readelf >/dev/null 2>&1; then
      # A missing tool is a failure, not a skip. This environment DOES inject
      # loader state (that is the branch we are in), so "we could not look" is
      # exactly the answer that let the defect live: the shell keeps handing
      # its glibc to foreign binaries and the gate says nothing.
      fail "this environment injects loader state into subprocesses
      (LD_LIBRARY_PATH has $llp_dirs directory/ies, monitor shim present:
      $shim_present) but patchelf and/or readelf is not on PATH, so the
      one-glibc invariant cannot be evaluated. Remedy: run this from the dev
      shell (\`direnv exec . just lint\`), which provides both."
    else
      mapfile -t glibc_findings < <(dev_shell_loader_glibc_conflicts "$REPO_ROOT")
      if [[ ${#glibc_findings[@]} -eq 0 ]]; then
        printf 'dev-shell: one glibc reaches a subprocess %s\n' \
          "(LD_LIBRARY_PATH: $llp_dirs dir(s), monitor shim: $shim_present; $(dev_shell_subprocess_tool_binaries | wc -l) tool binar(y/ies) checked)."
      else
        # Two kinds of finding with two different remedies, reported apart.
        # Printing one trailer for both would tell someone whose `readelf`
        # output this script cannot parse to go and change flake.nix.
        conflicts=()
        unreadables=()
        for finding in "${glibc_findings[@]}"; do
          case "$finding" in
            unreadable*) unreadables+=("$finding") ;;
            *) conflicts+=("$finding") ;;
          esac
        done
        if [[ ${#conflicts[@]} -gt 0 ]]; then
          printf 'FAIL: this dev shell injects a second glibc into a program it does not provide:\n' >&2
          for finding in "${conflicts[@]}"; do
            IFS=$'\t' read -r _kind f2 f3 f4 f5 f6 f7 f8 <<<"$finding"
            printf '  %s\n      binary:   %s\n      runs on:  %s\n      %s injects: %s\n      via:      %s\n      missing:  %s\n' \
              "$f2" "$f3" "$f4" "$f5" "$f7" "$f6" "$f8" >&2
          done
          # shellcheck disable=SC2016  # backticks quote command names for a
          # human reader; nothing here is meant to be expanded.
          printf '%s\n' \
            '  Each program above runs on one glibc while this shell forces libraries' \
            '  built against another into its address space, and the older libc.so.6' \
            '  does not define the symbol versions the newer one requires. The program' \
            '  aborts before main; for git that means no fetch, clone or push over' \
            '  https, and no git-using test under `repro build ".#test#<name>"`.' \
            '  Remedy: have the dev shell PROVIDE the program (add it to the devShell'"'"'s' \
            '  `packages` in flake.nix) so it comes from the same nixpkgs as the' \
            '  libraries this shell exports. Widening LD_LIBRARY_PATH, or dropping one' \
            '  entry from it, fixes at most one channel for one library.' >&2
          failures=$((failures + 1))
        fi
        if [[ ${#unreadables[@]} -gt 0 ]]; then
          printf 'FAIL: a glibc on this dev shell'"'"'s loader path could not be read:\n' >&2
          for finding in "${unreadables[@]}"; do
            IFS=$'\t' read -r _kind f2 f3 <<<"$finding"
            printf '  %s\n      could not read: %s\n' "$f2" "$f3" >&2
          done
          # shellcheck disable=SC2016  # as above: quoted names, not expansions.
          printf '%s\n' \
            '  This is reported as a failure and not as a skip because every' \
            '  comparison here is "the host libc does not define X": a libc whose' \
            '  version table cannot be read would otherwise present as a libc that' \
            '  defines NOTHING, i.e. as a conflict against every injected glibc.' \
            '  Remedy: this is a bug in dev_shell_glibc_defined_versions (in' \
            '  scripts/lib/dev_shell_overrides.sh) against the `readelf` on this' \
            '  PATH — most likely its .gnu.version_d section heading. Fix the' \
            '  parser; do not relax the check.' >&2
          failures=$((failures + 1))
        fi
      fi
    fi
    ;;
  *)
    # Stated rather than skipped in silence. dyld ignores DYLD_LIBRARY_PATH for
    # anything in a protected location and this repository's darwin binaries
    # carry LC_RPATHs instead (see flake.nix's `fixup_macho_runtime.sh`), so
    # the injection channels this check is about do not exist here.
    printf 'dev-shell: %s on %s; the loader-injection channels this check is about are linux-only.\n' \
      'one-glibc check not applicable' "$(uname -s)"
    ;;
esac

if [[ "$failures" -gt 0 ]]; then
  printf '\ncheck_dev_shell_env: %d failure(s)\n' "$failures" >&2
  exit 1
fi

printf 'check_dev_shell_env: ok (%d knob(s) declared, all probed)\n' \
  "${#declared[@]}"
