#!/usr/bin/env bash
#
# Validate .github/ the way GitHub does, before pushing.
#
# Two gates live here:
#
#   1. actionlint over .github/workflows -- a workflow GitHub cannot LOAD.
#   2. shared-action refs -- a `uses:` that names a metacraft-labs branch
#      which is stale or does not exist at all.
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
# GATE 2 -- every `uses: metacraft-labs/...` names a mainline that exists.
#
# WHY THIS EXISTS
#
# metacraft-labs renamed its mainline from `main` to `dev`. In
# `metacraft-github-actions` there is now NO `main` branch at all, so every
# `@main` reference is an action GitHub cannot resolve: the step dies at
# "Run metacraft-labs/metacraft-github-actions/setup-dev-env@main" before the
# job has done anything, and the run says nothing about the branch rename.
# That is exactly how PR #121's Test and Lint jobs died on 2026-08-28.
#
# 0d5fb357 fixed every such reference -- in the workflows that existed THAT
# DAY. It could not fix the ones written afterwards, and a new workflow
# (.github/workflows/installer.yml) promptly reintroduced `@main`; be6d1b1d
# had to repeat the same fix on that branch. A repo-wide sed is a snapshot of
# a moment; this gate is the rule, so the next new workflow is caught at lint
# time on its own branch instead of after it lands.
#
# `nixos-modules` is the quieter half of the same defect and the reason this
# gate does not check only for "resolvable". That repo kept a `main` branch
# after moving its default to `dev`, so `@main` still resolves -- to a frozen
# snapshot that stopped moving on 2026-08-26 while `dev` carried on. Nothing
# fails; CI simply runs an older action than the one everybody else runs, for
# as long as nobody looks. A ref that resolves is not the same as a ref that
# is current.
#
# ACCEPTED REFS
#
#   dev                 -- the mainline, for every metacraft-labs repo.
#   <40-hex commit sha> -- a deliberate, stronger pin than a branch.
#
# Everything else fails, including a `uses:` with no `@ref` at all. There is
# no exemption list on purpose: an exemption is how `@main` would come back.
# =============================================================================
echo "== shared metacraft-labs action refs =="

# The `uses:` spellings YAML accepts. The quote alternatives are not
# hypothetical tidiness: `uses: "…@main"` is the same defect wearing a
# quote, and a scanner that only understands the bare form is a rule with a
# one-character bypass in it.
shared_action_ref_grep='^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*["'"'"']?metacraft-labs/'

# Emits one `<file>:<line>:<uses-line>` per reference that is not `@dev` and
# not a 40-hex SHA. Takes the directory to scan so the self-test below can run
# it against a synthetic tree.
shared_action_ref_violations() {
  local root="$1"
  grep -rnE "${shared_action_ref_grep}" "${root}" 2>/dev/null |
    sed -E 's/[[:space:]]+#.*$//' |
    awk '
      {
        marker = index($0, "uses:")
        spec = substr($0, marker + 5)
        gsub(/^[ \t]+|[ \t]+$/, "", spec)
        gsub(/^["'"'"']|["'"'"']$/, "", spec)
        at = 0
        for (i = length(spec); i > 0; i--)
          if (substr(spec, i, 1) == "@") { at = i; break }
        if (at == 0) { print; next }        # unpinned `uses:` -- also a defect
        ref = substr(spec, at + 1)
        if (ref == "dev") next
        if (ref ~ /^[0-9a-f]{40}$/) next
        print
      }
    ' || true
}

# Counts `uses:` references to metacraft-labs repos under $1. A second
# argument narrows the count to one repo.
shared_action_ref_count() {
  local root="$1"
  local repo="${2:-}"
  grep -rcE "${shared_action_ref_grep}${repo}" \
    "${root}" 2>/dev/null | awk -F: '{ total += $NF } END { print total + 0 }'
}

# Prove the scanner still has teeth before trusting a clean result from it. A
# scan that silently matches nothing -- a moved directory, a `uses:` spelling
# the regex stopped recognising -- is a green light that means nothing, which
# is the failure mode this whole file exists to refuse.
selftest_root="$(mktemp -d)"
trap 'rm -rf "${selftest_root}"' EXIT
mkdir -p "${selftest_root}/workflows"
cat >"${selftest_root}/workflows/good.yml" <<'GOOD'
      - uses: metacraft-labs/metacraft-github-actions/setup-dev-env@dev
      - uses: "metacraft-labs/metacraft-github-actions/setup-dev-env@dev"
      - uses: metacraft-labs/metacraft-github-actions/clone-repo@0123456789abcdef0123456789abcdef01234567
      - uses: actions/checkout@v4
GOOD
cat >"${selftest_root}/workflows/bad.yml" <<'BAD'
      - uses: metacraft-labs/nixos-modules/.github/setup-nix@main
      - uses: metacraft-labs/metacraft-github-actions/setup-dev-env@main
      - uses: "metacraft-labs/metacraft-github-actions/setup-dev-env@main"
      - uses: 'metacraft-labs/metacraft-github-actions/setup-dev-env@main'
      - uses: metacraft-labs/metacraft-github-actions/setup-nix
BAD

selftest_hits="$(shared_action_ref_violations "${selftest_root}" | wc -l | tr -d ' ')"
if [ "${selftest_hits}" != "5" ]; then
  echo "FAIL: the shared-action-ref scanner found ${selftest_hits} of 5 planted" >&2
  echo "      violations (@main bare, double-quoted and single-quoted, plus an" >&2
  echo "      unpinned \`uses:\`). It is not scanning what it claims to; fix it" >&2
  echo "      before trusting a clean run." >&2
  shared_action_ref_violations "${selftest_root}" >&2
  exit 1
fi
if shared_action_ref_violations "${selftest_root}/workflows/good.yml" |
    grep -q .; then
  echo "FAIL: the shared-action-ref scanner rejects \`@dev\` or a 40-hex SHA." >&2
  echo "      It would refuse every correct reference in the repo." >&2
  exit 1
fi
echo "ok: shared-action-ref scanner catches @main and an unpinned uses:"

# Non-vacuity: this repo's CI is required to run through `setup-dev-env`
# (scripts/check_repo_requirements.sh asserts that literal), so a scan of
# .github that finds no metacraft-github-actions reference at all has stopped
# looking where the references live.
found_refs="$(shared_action_ref_count .github)"
anchor_refs="$(shared_action_ref_count .github metacraft-github-actions/)"
if [ "${anchor_refs}" -lt 1 ]; then
  echo "FAIL: no \`uses: metacraft-labs/metacraft-github-actions/...\` found under" >&2
  echo "      .github/. Either the shared actions were removed -- in which case" >&2
  echo "      this gate and the setup-dev-env requirement in" >&2
  echo "      scripts/check_repo_requirements.sh both need updating -- or the" >&2
  echo "      scan is looking in the wrong place." >&2
  exit 1
fi

if violations="$(shared_action_ref_violations .github)" && [ -n "${violations}" ]; then
  echo "FAIL: shared metacraft-labs action reference(s) do not name \`@dev\`:" >&2
  printf '%s\n' "${violations}" | sed 's/^/      /' >&2
  echo "" >&2
  echo "      metacraft-labs renamed its mainline main -> dev." >&2
  echo "      metacraft-github-actions has no \`main\` branch at all, so \`@main\`" >&2
  echo "      is a step that cannot start; nixos-modules kept one, so \`@main\`" >&2
  echo "      there silently runs a frozen copy of the action." >&2
  echo "      Use \`@dev\`, or a 40-hex commit SHA for a deliberate pin." >&2
  exit 1
fi
echo "ok: all ${found_refs} shared-action reference(s) resolve at @dev or a SHA"
