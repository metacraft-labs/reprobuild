#!/usr/bin/env bash
#
# Validate .github/workflows/ the way GitHub does, before pushing.
#
# WHY THIS EXISTS
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

if ! command -v actionlint >/dev/null 2>&1; then
  # Deliberately fatal rather than skipped. A check that quietly does nothing
  # when its tool is missing is how a broken workflow reaches the remote: it
  # reports success and proves nothing. actionlint ships in this repo's Nix
  # devshell (flake.nix), so run `just lint` inside it.
  echo "FAIL: actionlint not found on PATH." >&2
  echo "      Run inside the Nix devshell (nix develop), or: nix shell nixpkgs#actionlint" >&2
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
actionlint -no-color -oneline -ignore "${ignore_stylistic}" \
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
actionlint -no-color -oneline -ignore "${ignore_stylistic}" .github/workflows/*.yml
echo "ok: all workflow files load"
