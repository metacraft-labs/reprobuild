#!/usr/bin/env bash
#
# Build and check the user documentation site (docs/users/).
#
#   scripts/build_user_docs.sh fetch   # check out the site's framework repos
#   scripts/build_user_docs.sh build   # check and build docs/users/public/
#
# The site is an isonim-docs consumer (see docs/users/README.md). Its framework
# and the framework's dependencies are separate repositories, checked out next
# to this one, in the directory REPRO_DOCS_SIBLING_ROOT (default: the parent of
# this checkout, as in a reprobuild workspace).
#
# WHICH REVISIONS. `fetch` checks out isonim-docs at the revision named by
# REPRO_DOCS_ISONIM_DOCS_REF (default: its default branch), then every other
# repository at the revision isonim-docs' own committed repro.lock names. The
# framework's lock is therefore the one source of those revisions: nothing here
# pins them a second time. An existing checkout is moved to the locked
# revision, never re-cloned, and a checkout with local changes is refused.
#
# `build` runs in an environment that provides a Nim 2.2 compiler and Python 3;
# CI enters isonim's development shell for that. It runs the reference gate,
# the command-equivalents check, and the static build, in that order, and
# stops at the first failure.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sibling_root="${REPRO_DOCS_SIBLING_ROOT:-$(dirname "${repo_root}")}"
site="${repo_root}/docs/users"
remote_base="${REPRO_DOCS_REMOTE_BASE:-https://github.com/metacraft-labs}"

die() {
  echo "build_user_docs.sh: $*" >&2
  exit 1
}

# Check out <name> at <revision> in the sibling root. A missing checkout is
# cloned shallow; an existing one must be clean and is fetched and detached.
checkout_at() {
  local name=$1 revision=$2
  local dir="${sibling_root}/${name}"
  if [[ ! -d "${dir}/.git" ]]; then
    git init -q "${dir}"
    git -C "${dir}" remote add origin "${remote_base}/${name}.git"
  elif [[ -n "$(git -C "${dir}" status --porcelain)" ]]; then
    die "${dir} has local changes; commit or remove them, or point REPRO_DOCS_SIBLING_ROOT elsewhere"
  fi
  git -C "${dir}" fetch -q --depth 1 origin "${revision}"
  git -C "${dir}" checkout -q --detach FETCH_HEAD
  echo "  ${name} -> $(git -C "${dir}" rev-parse --short=12 HEAD)"
}

fetch() {
  mkdir -p "${sibling_root}"
  echo "build_user_docs.sh: framework checkouts in ${sibling_root}"
  local framework_ref="${REPRO_DOCS_ISONIM_DOCS_REF:-HEAD}"
  checkout_at isonim-docs "${framework_ref}"
  local lock="${sibling_root}/isonim-docs/repro.lock"
  [[ -f "${lock}" ]] || die "${lock} is missing; isonim-docs records its dependencies there"
  # The lock's dependency table: one `name revision` pair per repository,
  # skipping the framework's own entry.
  local pairs
  pairs="$(python3 - "${lock}" <<'EOF'
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    lock = tomllib.load(handle)
for dep in lock["lock"]["deps"]:
    if dep.get("self") != "true":
        print(dep["name"], dep["revision"])
EOF
)"
  [[ -n "${pairs}" ]] || die "${lock} names no dependencies"
  while read -r name revision; do
    checkout_at "${name}" "${revision}"
  done <<< "${pairs}"
}

build() {
  command -v nim >/dev/null 2>&1 || die "nim is not on PATH; run this inside isonim's development shell"
  export REPRO_DOCS_SIBLING_ROOT="${sibling_root}"
  cd "${site}"
  # --skipParentCfg keeps the reprobuild engine's own config.nims, at the
  # repository root, out of the site's compiles (see src/config.nims).
  nim c -r --skipParentCfg --hints:off -o:build/check_links src/check_links.nim
  python3 "${repo_root}/scripts/render_command_equivalents.py" --check
  nim c -r --skipParentCfg --hints:off -o:build/build src/build.nim
  [[ -f public/index.html ]] || die "the build wrote no public/index.html"
}

case "${1:-}" in
  fetch) fetch ;;
  build) build ;;
  *) die "usage: build_user_docs.sh fetch|build" ;;
esac
