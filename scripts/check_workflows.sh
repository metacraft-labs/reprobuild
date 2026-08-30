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
# metacraft-labs renamed its mainline `main` -> `dev`. `reprobuild-test-adapters`
# and `reprobuild-ct-test-runner` have NO `main` branch any more, but this file
# went on pinning `=main` for three days (da6bff51 .. 0d4afc33). The result was
# not a clean "ref does not exist" failure. `clone-siblings` runs on persistent
# self-hosted runners, so the sibling directory left behind by an earlier job
# survived; the clone for a ref that no longer exists left that stale tree in
# place, and the Nim compile resolved `repro_test_adapters` to a revision from
# before af0749a. What CI printed was:
#
#   libs/repro_generic_test_recorder/src/repro_generic_test_recorder.nim(144, 21)
#     Error: undeclared identifier: 'testExecutionDeclaration'
#
# "undeclared identifier" rather than "cannot open file" -- the module resolved,
# just to the wrong revision. Nothing in that message names a branch rename, a
# sibling repo, or this file. It cost hours across three PRs, and it was read as
# a source defect in reprobuild when reprobuild had not changed at all.
#
# This is the third instance of the same rename class in this repo family, and
# the second time a repo-wide fix was outrun by a branch already in flight. A
# sed is a snapshot of a moment; this gate is the rule, so a branch that pins a
# ref which does not exist fails lint ON THAT BRANCH instead of after it lands.
#
# WHY IT RESOLVES REFS INSTEAD OF DEMANDING `dev`
#
# A static "must say dev" rule would be wrong in both directions. Some siblings
# legitimately do not use `dev` -- a 40-hex SHA is a deliberate, stronger pin,
# and other metacraft-labs repos kept `main` as their mainline. And a static
# rule cannot see a typo: `=devel` would sail past it and fail exactly the way
# `=main` did. Asking the remote is the check that matches the defect.
#
# ACCEPTED
#
#   name                -- lock-resolved; no explicit ref to verify.
#   name=<40-hex sha>   -- a commit pin, stronger than any branch.
#   name=<ref>          -- must exist as a branch or tag in that repo, now.
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
sibling_repo_branch_pins() {
  sibling_repo_entries "$1" |
    awk -F= '
      NF < 2 { next }                       # lock-resolved -- nothing to check
      { ref = $2 }
      ref ~ /^[0-9a-f]{40}$/ { next }       # commit pin -- stronger than a branch
      { print $1, ref }
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

  # Non-vacuity: this repo's CI clones siblings on every dev-shell job, so a
  # parse that finds no entries has stopped reading the file it claims to read.
  entry_count="$(sibling_repo_entries "${sibling_repos_file}" | wc -l | tr -d ' ')"
  if [ "${entry_count}" -lt 1 ]; then
    echo "FAIL: parsed 0 entries out of ${sibling_repos_file}, which is not empty." >&2
    echo "      The parser is not reading the format it claims to." >&2
    exit 1
  fi

  sibling_violations=""
  checked=0
  while read -r name ref; do
    [ -n "${name}" ] || continue
    checked=$((checked + 1))
    if ! sibling_ref_exists "${name}" "${ref}"; then
      sibling_violations="${sibling_violations}${name}=${ref}"$'\n'
    fi
  done < <(sibling_repo_branch_pins "${sibling_repos_file}")

  if [ -n "${sibling_violations}" ]; then
    echo "FAIL: ${sibling_repos_file} pins ref(s) that do not exist:" >&2
    printf '%s' "${sibling_violations}" | sed 's/^/      /' >&2
    echo "" >&2
    echo "      metacraft-labs renamed its mainline main -> dev, and several" >&2
    echo "      repos kept no \`main\` branch at all." >&2
    echo "" >&2
    echo "      This does NOT fail loudly in CI. clone-siblings runs on" >&2
    echo "      persistent self-hosted runners: a clone for a ref that does not" >&2
    echo "      exist leaves the previous job's checkout in place, and the build" >&2
    echo "      compiles against a stale revision. The symptom is an" >&2
    echo "      \"undeclared identifier\" deep in an unrelated file." >&2
    echo "" >&2
    echo "      Use the repo's real mainline (\`dev\` for most metacraft-labs" >&2
    echo "      repos), or a 40-hex commit SHA for a deliberate pin." >&2
    exit 1
  fi
  echo "ok: all ${checked} explicit sibling-repo pin(s) resolve on the remote"
fi
