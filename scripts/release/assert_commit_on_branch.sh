#!/usr/bin/env bash
# assert_commit_on_branch.sh <remote> <branch> <commit>
#
# Refuse (exit 1) unless <commit> is reachable from <branch> on <remote>, i.e.
# is the branch tip or one of its ancestors. Exit 2 on a usage error.
#
# WHY. A producer workflow that publishes toolchain binaries (for example
# .github/workflows/clingo-windows-arm64.yml) is started by a tag push, and a
# tag can name any commit, including one on a throwaway branch that never went
# through review. Requiring the commit to be on the branch that changes land
# on means a published binary was always built from reviewed source.
#
# HOW. The remote is asked, not the runner's checkout: the job's checkout is
# shallow and holds neither the branch nor its history. The branch is fetched
# into a private temporary bare repository with `--filter=tree:0`, which
# transfers the commit graph but no trees or blobs
# (https://git-scm.com/docs/git-rev-list#Documentation/git-rev-list.txt---filterltfilter-specgt)
# -- enough for `git merge-base --is-ancestor`. A remote that ignores the
# filter (a local path) sends everything, which changes only the cost. A commit
# the fetch did not bring is not reachable from the branch by construction.
#
# <commit> must be a commit id: a tag object id is not peeled (tags are not
# fetched), so it is refused rather than passed.
set -euo pipefail

me="assert_commit_on_branch.sh"

if [ "$#" -ne 3 ]; then
  echo "usage: ${me} <remote> <branch> <commit>" >&2
  exit 2
fi

remote="$1"
branch="$2"
commit="$3"

if [ -z "${remote}" ] || [ -z "${branch}" ]; then
  echo "${me}: remote and branch must be non-empty" >&2
  exit 2
fi
case "${commit}" in
  *[!0-9a-fA-F]*) commit_ok=0 ;;
  *) if [ "${#commit}" -eq 40 ] || [ "${#commit}" -eq 64 ]; then commit_ok=1; else commit_ok=0; fi ;;
esac
if [ "${commit_ok}" -ne 1 ]; then
  echo "${me}: <commit> must be a full 40- or 64-hex object id, got '${commit}'" >&2
  exit 2
fi
commit="${commit,,}"

# A commit missing from the probe must read as missing, never be fetched on
# demand from a promisor remote (git 2.45+ honours this; older git ignores it,
# and the ancestry test below still refuses a lazily fetched stranger).
export GIT_NO_LAZY_FETCH=1

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

git init -q --bare "${scratch}/probe.git"
# Keep git's stderr: an unreachable remote and a missing branch need different
# remedies, and both must refuse rather than pass.
if ! git -C "${scratch}/probe.git" fetch -q --no-tags --filter=tree:0 \
    "${remote}" "+refs/heads/${branch}:refs/heads/probe"; then
  echo "::error::${me}: could not fetch ${branch} from ${remote}; refusing to publish from a commit whose branch cannot be verified" >&2
  exit 1
fi

if ! git -C "${scratch}/probe.git" cat-file -e "${commit}^{commit}" 2>/dev/null; then
  echo "::error::${me}: ${commit} is not on ${branch} at ${remote}. Producer tags must name a commit that has landed on ${branch}." >&2
  exit 1
fi

status=0
git -C "${scratch}/probe.git" merge-base --is-ancestor "${commit}" refs/heads/probe || status=$?
case "${status}" in
  0)
    echo "${me}: ${commit} is on ${branch} at ${remote}."
    exit 0
    ;;
  1)
    echo "::error::${me}: ${commit} is not on ${branch} at ${remote}. Producer tags must name a commit that has landed on ${branch}." >&2
    exit 1
    ;;
  *)
    echo "::error::${me}: git merge-base failed (exit ${status}) checking ${commit} against ${branch}; refusing" >&2
    exit 1
    ;;
esac
