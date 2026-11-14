#!/usr/bin/env bash
# assert_tag_names_commit.sh <remote> <tag> <built-commit>
#
# Refuse (exit 1) unless the tag <tag> on <remote> still names <built-commit>,
# the commit this release run built its assets from. Exit 2 on a usage error.
#
# WHY. A release is the tagged commit: a commit is tagged `vX.Y.Z` and the tag
# push triggers the real release, so a consumer who checks a fix by ancestry
# against the tag ("ask git, not the binary") is entitled to assume the assets
# were built from the commit the tag names. The release workflow builds from
# `github.sha`, which is fixed when the run starts, but publishes under the tag
# NAME, which resolves to whatever the tag names when the release is read.
# Nothing tied the two together. v0.2.24: run 43218423379 (attempt 2) built
# 7c670d248; 42 seconds after that attempt started the tag was moved to
# 8cd4a5051e, 73 commits later; the run then published its 7c670d248 assets
# under a tag naming 8cd4a5051e, whose fixes the assets did not carry.
#
# So the publish job asks the remote -- not the runner's checkout, whose tag
# ref was written when the run started and so cannot have moved -- what the tag
# names now, and refuses when it is not the built commit or is gone.
#
# WHAT COUNTS AS A MATCH. A lightweight tag names its commit directly. An
# annotated tag names a tag object; `git ls-remote` also reports the peeled
# commit as `refs/tags/<tag>^{}`
# (https://git-scm.com/docs/git-ls-remote, "dereferenced tags"). The tag still
# names the build when the peeled commit is <built-commit>, or, for a caller
# that passes the tag object's id, when the tag object itself is <built-commit>
# (the same object cannot name a different commit).
#
# Only exact ref names are compared. `git ls-remote` matches each pattern
# against the tail of every ref, starting at the beginning or at any `/`, so
# the pattern `refs/tags/<tag>` also lists a tag named
# `x/refs/tags/<tag>` (`refs/tags/x/refs/tags/<tag>`); a tag that merely ends
# in the same name must not vouch for the release.
set -euo pipefail

me="assert_tag_names_commit.sh"

if [ "$#" -ne 3 ]; then
  echo "usage: ${me} <remote> <tag> <built-commit>" >&2
  exit 2
fi

remote="$1"
tag="$2"
built="$3"

if [ -z "${remote}" ] || [ -z "${tag}" ]; then
  echo "${me}: remote and tag must be non-empty" >&2
  exit 2
fi
# A full object id (SHA-1 or SHA-256), never an abbreviation: an abbreviated id
# would compare unequal to every ls-remote line and be reported as a moved tag,
# hiding the real mistake in the caller.
case "${built}" in
  *[!0-9a-fA-F]*) built_ok=0 ;;
  *) if [ "${#built}" -eq 40 ] || [ "${#built}" -eq 64 ]; then built_ok=1; else built_ok=0; fi ;;
esac
if [ "${built_ok}" -ne 1 ]; then
  echo "${me}: <built-commit> must be a full 40- or 64-hex object id, got '${built}'" >&2
  exit 2
fi
built="${built,,}"  # git prints object ids in lower case

ref="refs/tags/${tag}"
# Keep git's stderr: an unreachable remote and an authentication failure need
# different remedies, and both must refuse rather than pass.
# Both patterns: the pattern filter sees the peeled line under its own name,
# `refs/tags/<tag>^{}`, so the plain pattern drops it (git 2.54, both against a
# local repository and against github.com); ask for it by name.
if ! listing="$(git ls-remote --tags "${remote}" "${ref}" "${ref}^{}")"; then
  echo "::error::${me}: could not read ${ref} from ${remote}; refusing to publish a release whose tag cannot be verified" >&2
  exit 1
fi

direct=""
peeled=""
while IFS=$'\t' read -r oid name; do
  [ -n "${oid}" ] || continue
  if [ "${name}" = "${ref}" ]; then
    direct="${oid}"
  elif [ "${name}" = "${ref}^{}" ]; then
    peeled="${oid}"
  fi
done <<<"${listing}"

if [ -z "${direct}" ]; then
  echo "::error::${me}: ${ref} no longer exists on ${remote}. This run built ${built}; refusing to publish it under a tag that was deleted after the run started." >&2
  exit 1
fi

names="${peeled:-${direct}}"
if [ "${names}" = "${built}" ] || [ "${direct}" = "${built}" ]; then
  echo "${me}: ${ref} on ${remote} names ${names}, the commit this run built."
  exit 0
fi

echo "::error::${me}: ${ref} on ${remote} now names ${names}, but this run built ${built}. The tag was moved after the run started, so these assets would be published under a tag naming a different commit. Refusing. Re-run the release from the run the current tag push started, or move the tag back to ${built}." >&2
exit 1
