#!/usr/bin/env bash
#
# Validate .github/ the way GitHub does, before pushing.
#
# Two gates live here:
#
#   1. actionlint over .github/workflows -- a workflow GitHub cannot LOAD.
#   2. sibling-repo pins -- a `.github/sibling-repos` entry naming a branch
#      that does not exist in the repo it names.
#
# WHY GATE 1 EXISTS
#
# Every release run between c46b65f5 and this check failed in the same second
# it started, with ZERO jobs created -- not even the first one. The cause was a
# JavaScript comment inside an `actions/github-script` `script:` block that
# spelled out the literal two-brace expression sequence with nothing between
# the braces. `script` is an Actions *input*, so GitHub scans its entire body,
# comments included, for expression syntax; an empty expression is a workflow
# LOAD error:
#
#   Invalid workflow file: .github/workflows/release.yml
#   (Line: 585, Col: 19): An expression was expected
#
# A rejected workflow never reaches the job graph, so there is no job, no log,
# and no annotation on the run -- only a failure run that exists to carry the
# message. GitHub also cannot read `on:` in a file it cannot load, so it stops
# filtering events: the release workflow, which subscribes only to `v*` tags,
# produced a failure run on every branch push.
#
# None of that was visible locally. The file is valid YAML, and every YAML
# parser we had said so. Actions expression syntax lives *inside* YAML scalars,
# so a YAML parse can never see it. That is the whole lesson, and it is why
# this check uses actionlint -- which models Actions expression grammar, the
# `needs` graph, matrix shapes, and context availability -- rather than a
# parser.
#
# Runs as part of `just lint`, which CI runs on every push (ci.yml).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

# Resolve actionlint ourselves rather than demanding the caller already be in
# the devshell. The managed pre-commit hook runs `just lint` OUTSIDE `nix
# develop`, so a PATH-only lookup made every commit in the repo fail once this
# check was wired in -- a check that blocks honest work is no better than one
# that proves nothing.
#
# Still fatal when no interpreter can be obtained: quietly doing nothing when
# the tool is missing is how a broken workflow reaches the remote.
ACTIONLINT=()
if command -v actionlint >/dev/null 2>&1; then
  ACTIONLINT=(actionlint)
elif command -v nix >/dev/null 2>&1 \
    && nix develop --command actionlint -version >/dev/null 2>&1; then
  ACTIONLINT=(nix develop --command actionlint)
elif command -v nix >/dev/null 2>&1 \
    && nix shell nixpkgs#actionlint --command actionlint -version >/dev/null 2>&1; then
  ACTIONLINT=(nix shell nixpkgs#actionlint --command actionlint)
else
  echo "FAIL: actionlint not found, and it could not be obtained via nix." >&2
  echo "      Install it, run inside the Nix devshell (nix develop)," >&2
  echo "      or: nix shell nixpkgs#actionlint" >&2
  exit 1
fi

# Info-level notes from shellcheck are stylistic (SC2016 single-quote expansion,
# SC2012 ls-vs-find, ...) and are not what this check is defending. Warnings and
# errors from shellcheck, and EVERY actionlint finding -- expression syntax,
# unknown `needs` edges, matrix shape, bad contexts, unknown runner labels --
# remain fatal.
ignore_stylistic='shellcheck reported issue in this script: SC[0-9]+:info:'

echo "== actionlint: self-test =="
# Prove the checker still has teeth before trusting a clean result from it.
# A stubbed binary, a too-greedy ignore pattern, or a silently-skipped shellcheck
# would otherwise turn this whole check into a green light that means nothing --
# which is exactly the failure mode being defended against. This fixture is a
# minimal copy of the defect that broke the release pipeline; actionlint MUST
# reject it.
canary_status=0
"${ACTIONLINT[@]}" -no-color -oneline -ignore "${ignore_stylistic}" \
  -stdin-filename '.github/workflows/__canary__.yml' - >/dev/null 2>&1 <<'CANARY' || canary_status=$?
name: canary
on: workflow_dispatch
jobs:
  canary:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/github-script@v7
        with:
          script: |
            // an empty ${{ }} expression -- a workflow LOAD error
            core.info('unreachable');
CANARY

if [ "${canary_status}" -eq 0 ]; then
  echo "FAIL: actionlint accepted a workflow GitHub rejects (empty expression)." >&2
  echo "      This check is not actually validating anything -- fix it before trusting it." >&2
  exit 1
fi
echo "ok: actionlint rejects a known-bad workflow"

echo "== actionlint: .github/workflows =="
"${ACTIONLINT[@]}" -no-color -oneline -ignore "${ignore_stylistic}" .github/workflows/*.yml
echo "ok: all workflow files load"

# =============================================================================
# GATE 2 -- every explicit `.github/sibling-repos` pin names a ref that EXISTS.
#
# WHY THIS EXISTS
#
# `.github/sibling-repos` is the bill of materials for the dev-shell CI jobs:
# the shared `clone-siblings` action clones each named repo adjacent to this
# checkout so Nim's sibling detection can resolve it. An entry is either
# `name` -- resolve the revision from the workspace lock -- or `name=ref`, an
# explicit pin that bypasses the lock.
#
# metacraft-labs renamed its mainline `main` -> `dev`, and this file went on
# pinning `=main` for three days (da6bff51 .. 0d4afc33). That pin failed in TWO
# different regimes, which is why this gate has two checks and not one:
#
#   2026-08-26 .. 08-28   `main` still EXISTED on reprobuild-test-adapters,
#                         frozen at d1ff8317 (2026-07-13) while `dev` moved on.
#                         The clone SUCCEEDED, silently, onto a six-week-old
#                         tree. Seven CI runs failed this way and none of them
#                         said anything about a branch.
#
#   2026-08-28 10:54Z ..  `main` was deleted. The same pin now fails loudly at
#                         clone time:
#                           ##[error]checkout of revision main failed for ...
#
# The quiet regime is the expensive one, and mere existence cannot see it -- so
# a pin naming `main` is additionally checked against the repo's default branch.
#
# This is the third instance of the same rename class in this repo family, and
# the second time a repo-wide fix was outrun by a branch already in flight. A
# sed is a snapshot of a moment; this gate is the rule, so a branch that pins a
# dead or abandoned ref fails lint ON THAT BRANCH instead of after it lands.
#
# WHAT THIS GATE IS *NOT* FOR. It would not have caught the
# `undeclared identifier: 'testExecutionDeclaration'` compile error of the same
# week, and it must not be trusted to. `config.nims` resolves
# `repro_test_adapters` from `REPRO_TEST_ADAPTERS_SRC` -- exported by the dev
# shell from the `reprobuild-test-adapters-src` FLAKE INPUT -- in preference to
# the sibling checkout, so for that module the sibling set is never consulted at
# all. That failure was a stale `flake.lock` pin and was fixed there. Two stale
# pins of the same package, in two different mechanisms, at the same time; do
# not let this gate's green light stand in for the other one.
#
# WHY IT RESOLVES REFS INSTEAD OF DEMANDING `dev`
#
# A static "must say dev" rule would be wrong in both directions. Some siblings
# legitimately do not use `dev`: a 40-hex SHA is a deliberate, stronger pin, and
# `codetracer-trace-format` defaults to `stable` while this file pins it to
# `dev` on purpose. And a static rule cannot see a typo: `=devel` would sail
# past it and fail exactly the way `=main` did. Asking the remote is the check
# that matches the defect.
#
# The `main` rule is narrower than "must equal the default branch" for the same
# reason: pinning a non-default branch is legitimate and done here deliberately.
# Only `main` on a repo that has MOVED OFF `main` is refused. A repo whose
# default still is `main` passes.
#
# ACCEPTED
#
#   name                -- lock-resolved; no explicit ref to verify.
#   name=<40-hex sha>   -- a commit pin, stronger than any branch.
#   name=<ref>          -- must exist as a branch or tag in that repo, now;
#                          and if <ref> is `main`, that repo's default branch
#                          must still be `main`.
# =============================================================================
echo "== .github/sibling-repos pins =="

sibling_repos_file=".github/sibling-repos"
if [ ! -f "${sibling_repos_file}" ]; then
  echo "FAIL: ${sibling_repos_file} does not exist. Either the sibling-clone" >&2
  echo "      contract moved -- in which case this gate needs updating -- or" >&2
  echo "      the file was lost, which silently drops every sibling CI clones." >&2
  exit 1
fi

# Strips comments and blank lines, emitting one `name=ref` or bare `name` per
# line. Takes the file so the self-test below can run it over a fixture.
sibling_repo_entries() {
  sed -E 's/#.*$//; s/[[:space:]]+$//; s/^[[:space:]]+//' "$1" | grep -v '^$' || true
}

# Emits `<name> <ref>` for each entry carrying an explicit non-SHA ref -- the
# ones that have to be resolved against the remote.
#
# `name!=ref` is the same explicit pin, with the `!` acknowledging that it
# overrides a revision the workspace lock pins. The ref still has to exist, so
# the `!` is stripped and the entry checked like any other -- a gate that
# skipped the acknowledged form would exempt exactly the entries someone
# deliberately hand-pinned, which are the ones most likely to name a dead ref.
sibling_repo_branch_pins() {
  sibling_repo_entries "$1" |
    awk '
      {
        eq = index($0, "=")
        if (eq == 0) next                   # lock-resolved -- nothing to check
        name = substr($0, 1, eq - 1)
        ref = substr($0, eq + 1)
        sub(/!$/, "", name)                 # `name!=ref` -- acknowledged override
        if (name == "" || ref == "") next
        if (ref ~ /^[0-9a-f]{40}$/) next    # commit pin -- stronger than a branch
        print name, ref
      }
    '
}

# True when the ref exists as a branch or a tag in the named repo. `ls-remote`
# exits 0 with EMPTY output for a ref that does not exist, so the exit code
# proves nothing and the output is what has to be tested.
sibling_ref_exists() {
  local name="$1" ref="$2" out
  out="$(git ls-remote --heads --tags \
    "https://github.com/metacraft-labs/${name}" \
    "${ref}" "refs/tags/${ref}" 2>/dev/null)" || return 1
  [ -n "${out}" ]
}

# Is github reachable at all? Resolved once: without it, every entry would be
# reported as a missing ref on a laptop that is merely offline.
sibling_probe_repo="reprobuild"
network_ok=0
if git ls-remote --heads "https://github.com/metacraft-labs/${sibling_probe_repo}" \
    dev >/dev/null 2>&1; then
  network_ok=1
fi

# Prove the PARSER handles every entry form the clone action accepts, before
# any network is involved -- this part is free and runs even offline. A parser
# that drops a form silently checks fewer pins than it reports.
sibling_parse_fixture="$(mktemp -d)"
trap 'rm -rf "${sibling_parse_fixture}"' EXIT
cat >"${sibling_parse_fixture}/sibling-repos" <<'PARSEFIX'
# a comment, and a blank line follow

bare-lock-resolved
plain-branch=dev
acknowledged-override!=dev
commit-pinned=0123456789abcdef0123456789abcdef01234567
  indented-branch=main   # trailing comment
PARSEFIX
expected_parse='plain-branch dev
acknowledged-override dev
indented-branch main'
actual_parse="$(sibling_repo_branch_pins "${sibling_parse_fixture}/sibling-repos")"
if [ "${actual_parse}" != "${expected_parse}" ]; then
  echo "FAIL: the sibling-repos parser does not read the format it claims to." >&2
  echo "      expected:" >&2
  printf '%s\n' "${expected_parse}" | sed 's/^/        /' >&2
  echo "      got:" >&2
  printf '%s\n' "${actual_parse}" | sed 's/^/        /' >&2
  echo "      A form it drops is a pin nobody checks. Fix it before trusting" >&2
  echo "      a clean run." >&2
  exit 1
fi
echo "ok: sibling-repos parser handles bare, =ref, !=ref, SHA and comments"

if [ "${network_ok}" -eq 0 ]; then
  # Never silently pass in CI. Offline is a plausible state for the pre-commit
  # hook on a laptop; it is not a plausible state for a CI runner, where it
  # means the check did not run and nobody was told.
  if [ -n "${CI:-}" ]; then
    echo "FAIL: cannot reach github.com to resolve sibling-repo pins, and \$CI is" >&2
    echo "      set. A CI run that cannot check the pins must not report success:" >&2
    echo "      that is how an unresolvable ref reaches the mainline." >&2
    exit 1
  fi
  echo "SKIP: github.com unreachable; sibling-repo pins not resolved (offline)."
  echo "      CI resolves them on every push -- this gate is fatal there."
else
  # Prove the resolver still distinguishes a real ref from a missing one before
  # trusting a clean result from it. A resolver that has quietly started saying
  # "exists" for everything -- a changed ls-remote spelling, a URL typo that
  # makes every lookup fail the same way -- is a green light that means nothing.
  if ! sibling_ref_exists "${sibling_probe_repo}" dev; then
    echo "FAIL: the sibling-ref resolver cannot find \`dev\` in" >&2
    echo "      metacraft-labs/${sibling_probe_repo}, which certainly has it." >&2
    echo "      The resolver is broken; fix it before trusting a clean run." >&2
    exit 1
  fi
  if sibling_ref_exists "${sibling_probe_repo}" __gate_selftest_absent_ref__; then
    echo "FAIL: the sibling-ref resolver reports a ref that cannot exist as" >&2
    echo "      present. It would accept every pin, including the \`=main\`" >&2
    echo "      entries this gate exists to catch." >&2
    exit 1
  fi
  echo "ok: sibling-ref resolver separates a live ref from a missing one"

  # The abandoned-mainline probe needs its own anchor, because the check it
  # guards is invisible to the one above: `nixos-modules` still HAS a `main`,
  # so `sibling_ref_exists` says yes, and only the default-branch lookup can
  # tell that `main` stopped being the mainline. If that lookup silently
  # started returning nothing, the whole check would pass everything.
  probe_default="$(git ls-remote --symref \
    "https://github.com/metacraft-labs/nixos-modules" HEAD 2>/dev/null |
    awk '/^ref:/ { sub(/^refs\/heads\//, "", $2); print $2; exit }')"
  if [ "${probe_default}" = "main" ] || [ -z "${probe_default}" ]; then
    echo "FAIL: the default-branch lookup returned '${probe_default:-<nothing>}'" >&2
    echo "      for metacraft-labs/nixos-modules, which has moved its default" >&2
    echo "      off \`main\` while keeping the branch. The abandoned-mainline" >&2
    echo "      check cannot work if this lookup does not answer; fix it before" >&2
    echo "      trusting a clean run." >&2
    exit 1
  fi
  echo "ok: default-branch lookup detects a mainline that moved (nixos-modules -> ${probe_default})"

  # Non-vacuity: this repo's CI clones siblings on every dev-shell job, so a
  # parse that finds no entries has stopped reading the file it claims to read.
  entry_count="$(sibling_repo_entries "${sibling_repos_file}" | wc -l | tr -d ' ')"
  if [ "${entry_count}" -lt 1 ]; then
    echo "FAIL: parsed 0 entries out of ${sibling_repos_file}, which is not empty." >&2
    echo "      The parser is not reading the format it claims to." >&2
    exit 1
  fi

  sibling_violations=""
  abandoned_violations=""
  checked=0
  while read -r name ref; do
    [ -n "${name}" ] || continue
    checked=$((checked + 1))
    if ! sibling_ref_exists "${name}" "${ref}"; then
      sibling_violations="${sibling_violations}${name}=${ref}"$'\n'
      continue
    fi
    # The ref exists -- but `main` on a repo that has moved its default to
    # something else is the ABANDONED half of the rename, and existence alone
    # cannot see it. This is the regime the original incident ran in: between
    # 2026-08-26 and 2026-08-28 `reprobuild-test-adapters` still HAD a `main`,
    # frozen at d1ff8317 (2026-07-13) while `dev` carried on. The clone
    # succeeded, silently, onto a six-week-old tree, and the build failed
    # fifteen minutes later with `undeclared identifier`. `main` was not
    # deleted until 2026-08-28, and only then did it fail loudly at clone time.
    # A ref that resolves is not the same as a ref that is current.
    #
    # Scoped deliberately to `main`. Pinning a NON-default branch is legitimate
    # and common here -- codetracer-trace-format defaults to `stable` and is
    # pinned to `dev` on purpose -- so a general "must equal the default branch"
    # rule would reject correct entries. `main` on a repo whose default has
    # moved is the specific, recurring defect.
    if [ "${ref}" = "main" ]; then
      default_ref="$(git ls-remote --symref \
        "https://github.com/metacraft-labs/${name}" HEAD 2>/dev/null |
        awk '/^ref:/ { sub(/^refs\/heads\//, "", $2); print $2; exit }')"
      if [ -n "${default_ref}" ] && [ "${default_ref}" != "main" ]; then
        abandoned_violations="${abandoned_violations}${name}=main (default branch is '${default_ref}')"$'\n'
      fi
    fi
  done < <(sibling_repo_branch_pins "${sibling_repos_file}")

  if [ -n "${abandoned_violations}" ]; then
    echo "FAIL: ${sibling_repos_file} pins \`main\` on repo(s) that have moved off it:" >&2
    printf '%s' "${abandoned_violations}" | sed 's/^/      /' >&2
    echo "" >&2
    echo "      These refs still RESOLVE, so the clone succeeds and CI stays" >&2
    echo "      quiet -- onto a branch that stopped moving. That is how the" >&2
    echo "      2026-08-26 failure happened: reprobuild-test-adapters still had" >&2
    echo "      a \`main\`, frozen six weeks earlier, and the build failed with" >&2
    echo "      \`undeclared identifier\` rather than anything naming a branch." >&2
    echo "      Use the repo's current mainline, or a 40-hex SHA." >&2
    exit 1
  fi

  if [ -n "${sibling_violations}" ]; then
    echo "FAIL: ${sibling_repos_file} pins ref(s) that do not exist:" >&2
    printf '%s' "${sibling_violations}" | sed 's/^/      /' >&2
    echo "" >&2
    echo "      metacraft-labs renamed its mainline main -> dev, and several" >&2
    echo "      repos kept no \`main\` branch at all." >&2
    echo "" >&2
    echo "      A ref that does not resolve takes the job down at sibling-clone" >&2
    echo "      time: authenticated-clone.sh removes the destination and exits" >&2
    echo "      non-zero, so the Test job dies minutes in with" >&2
    echo "        ##[error]checkout of revision <ref> failed for <repo>" >&2
    echo "      which names a ref but not this file." >&2
    echo "" >&2
    echo "      Use the repo's real mainline (\`dev\` for most metacraft-labs" >&2
    echo "      repos), or a 40-hex commit SHA for a deliberate pin." >&2
    exit 1
  fi
  echo "ok: all ${checked} explicit sibling-repo pin(s) resolve on the remote"
fi
