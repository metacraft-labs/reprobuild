#!/usr/bin/env bash
# Nothing outside docs/user-guide/ may name a superseded user-guide page as the
# documentation of record: not code, Nix, tests, tools, nor the published docs.
#
# The pages listed below were replaced by the published site under
# docs/users/content/ (reprobuild-pm spec User-Documentation-Structure.md §10)
# and are kept only as unmaintained copies under a "Superseded" banner. A
# pointer that still names one sends a contributor to edit the copy, leaving
# the published page -- the one the `lib-reference` flake check and the
# home-export reference hold to the code -- stale. Links between the old pages
# themselves (inside docs/user-guide/) are not checked.
#
# Only full `docs/user-guide/<page>` paths are matched; a relative link from
# another directory is not. Add a page to SUPERSEDED when its replacement is
# published. ALLOWED lists a pointer that is still correct: a section of an old
# page that has no published replacement yet.
#
# Regression gate for the reprobuild-pm issue "Code comments and the migration
# spec point at the superseded user-guide pages" (2026-11-17).
set -euo pipefail
cd "$(dirname "$0")/.."

SUPERSEDED=(
  # old page                              -> published replacement(s)
  docs/user-guide/home-export.md         # reference/files/home-export.md, guides/machines/export-a-home-profile.md
  docs/user-guide/nix-helper-library.md  # reference/nix-library.md, guides/machines/drive-home-manager-from-a-profile.md, …/install-applications-with-homebrew.md
  docs/user-guide/host-facts.md          # guides/machines/compare-with-home-manager.md (not the document's fields)
)
ALLOWED=(
  # The host-facts document's fields: no reference page under docs/users/content/ yet.
  'docs/user-guide/host-facts.md` §What a host-facts document holds'
)

escape() { sed 's/[][\.*^$]/\\&/g'; }
pattern=$(printf '%s\n' "${SUPERSEDED[@]}" | escape | paste -sd'|')

# TRACKED FILES ONLY. The pointers this gate is about are documentation of
# record: committed code, Nix, tests, tools and published docs. A recursive
# grep of the directory also read every ignored file of a working checkout --
# build/, .nimcache/, .repro/, test-logs/ -- which in a checkout that has run
# the suite is tens of gigabytes, and whose build reports quote these paths,
# so the gate refused commits over files nobody had committed. `git grep`
# searches the index's files in the working tree, which is what a commit
# carries. (reprobuild-pm issue
# 2026-11-19-the-superseded-doc-pointer-gate-greps-untracked-build-output.md)
#
# git grep exits 1 for "no match" and 128 for an error; only 1 is a pass.
set +e
hits=$(git grep -nIE "$pattern" -- . \
  ':(exclude,glob)**/vendor/**' \
  ':(exclude,glob)**/user-guide/**' \
  ":(exclude)scripts/$(basename "$0")")
rc=$?
set -e
if [[ $rc -gt 1 ]]; then
  echo "check_superseded_doc_pointers: grep failed (exit $rc)" >&2
  exit 2
fi
for a in "${ALLOWED[@]}"; do
  hits=$(printf '%s\n' "$hits" | grep -vF -- "$a" || true)
done
hits=$(printf '%s\n' "$hits" | sed '/^$/d')
if [[ -n "$hits" ]]; then
  echo "check_superseded_doc_pointers: these name a superseded user-guide page;" >&2
  echo "point them at the published page under docs/users/content/ instead:" >&2
  echo "$hits" >&2
  exit 1
fi
echo "check_superseded_doc_pointers: OK (${#SUPERSEDED[@]} superseded pages, no pointers outside docs/user-guide/)"
