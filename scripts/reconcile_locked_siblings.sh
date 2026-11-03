#!/usr/bin/env bash
# Put sibling checkouts at the revisions ONE consumer's lock names.
#
# `repro develop --all --reset` reconciles the siblings it manages, but it
# SKIPS every sibling a recipe pins ("skipped <name> -- pinned by recipe"),
# and nothing else moves those. The build then refuses an hour or two later
# with `cross-repo producer "<name>" source revision mismatch`.
#
# This job builds TWO consumers from ONE sibling tree -- CodeTracer's `ct`
# against codetracer/repro.lock, and reprobuild's own collections against
# reprobuild/repro.lock -- and those locks name DIFFERENT revisions for every
# sibling they share. One checkout cannot satisfy both, so each consumer is
# given its own revisions immediately before it builds. `--fetch-only` exists
# to bring both revision sets into the clones while credentials are in scope,
# so that a later `--detach` needs no network.
#
# Usage:
#   reconcile_locked_siblings.sh <lock> <siblings-root> <exclude-name> \
#       --fetch-only | --detach
#
# <exclude-name> is skipped by name: the repository under test is itself an
# entry in these locks, at a different revision, and its checkout must stay
# at the revision the run is testing. `self` entries are the consumer itself
# and are skipped for the same reason.
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <lock> <siblings-root> <exclude-name> --fetch-only|--detach" >&2
  exit 2
fi
lock="$1"
siblings_root="$2"
exclude="$3"
mode="$4"

case "$mode" in
  --fetch-only|--detach) ;;
  *) echo "$0: unknown mode $mode" >&2; exit 2 ;;
esac
if [ ! -f "$lock" ]; then
  echo "$0: no lock at $lock" >&2
  exit 1
fi

# The lock keeps its entries as brace groups on very long lines, so match the
# groups first. grep and sed rather than an interpreter: this runs in steps
# where python3 is reachable only through `dev-exec`.
entries="$(mktemp)"
trap 'rm -f "$entries"' EXIT
# `|| true`: under `set -o pipefail` a lock with no vcs entries would
# otherwise abort here, before the count below can report it.
grep -o '{[^{}]*}' "$lock" \
  | grep 'coord_kind' \
  | grep -v 'self = "true"' > "$entries" || true

seen=0
acted=0
while IFS= read -r entry; do
  name="$(printf '%s' "$entry" | sed -n 's/.*[^-]name = "\([^"]*\)".*/\1/p')"
  revision="$(printf '%s' "$entry" \
    | sed -n 's/.*revision = "\([0-9a-f]\{40\}\)".*/\1/p')"
  if [ -z "$name" ] || [ -z "$revision" ]; then continue; fi
  if [ "$name" = "$exclude" ]; then continue; fi
  directory="$siblings_root/$name"
  if [ ! -d "$directory/.git" ]; then continue; fi
  seen=$((seen + 1))
  if [ "$mode" = "--fetch-only" ]; then
    if git -C "$directory" cat-file -e "$revision^{commit}" 2>/dev/null; then
      continue
    fi
    echo "reconcile: fetching $name for $revision"
    git -C "$directory" fetch --quiet origin "$revision" \
      || git -C "$directory" fetch --quiet origin \
           '+refs/heads/*:refs/remotes/origin/*'
    acted=$((acted + 1))
    continue
  fi
  if [ "$(git -C "$directory" rev-parse HEAD)" = "$revision" ]; then
    continue
  fi
  echo "reconcile: $name -> locked $revision"
  if ! git -C "$directory" cat-file -e "$revision^{commit}" 2>/dev/null; then
    # Only reachable when --fetch-only did not run, or ran without the
    # credentials the clone needs; say which rather than failing on `checkout`.
    echo "reconcile: $name has no object $revision locally; a --fetch-only" \
      "pass with credentials in scope has not brought it in" >&2
    exit 1
  fi
  git -C "$directory" checkout --quiet --detach "$revision"
  head="$(git -C "$directory" rev-parse HEAD)"
  if [ "$head" != "$revision" ]; then
    echo "reconcile: $name is at $head, not the locked $revision" >&2
    exit 1
  fi
  echo "reconcile: $name at $head"
  acted=$((acted + 1))
done < "$entries"

echo "reconcile: $(basename "$lock") in $(dirname "$lock" | xargs basename):" \
  "$seen sibling(s) present, $acted acted on ($mode)"
