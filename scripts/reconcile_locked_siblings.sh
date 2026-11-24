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
#       --fetch-only | --detach [<sibling-repos-file>]
#
# <sibling-repos-file> (normally .github/sibling-repos) names siblings the
# lock does not list, at a revision of their own: its `name=<40-hex>` lines.
# CodeTracer's lock can move such a sibling (nim-shm-gset, say) to an older
# revision for the ct build, and reprobuild's lock, which does not list it,
# would never move it back, so the suite's recipe compile ran against a
# checkout without symbols reprobuild's source uses (`attempting to call
# undeclared routine: 'insertShardIndex'`). Pass it for the reprobuild
# lock's passes. A name the lock does list keeps the lock's revision.
#
# <exclude-name> is skipped by name: the repository under test is itself an
# entry in these locks, at a different revision, and its checkout must stay
# at the revision the run is testing. `self` entries are the consumer itself
# and are skipped for the same reason.
set -euo pipefail

if [ "$#" -ne 4 ] && [ "$#" -ne 5 ]; then
  echo "usage: $0 <lock> <siblings-root> <exclude-name> --fetch-only|--detach [<sibling-repos-file>]" >&2
  exit 2
fi
lock="$1"
siblings_root="$2"
exclude="$3"
mode="$4"
explicit_file="${5:-}"

case "$mode" in
  --fetch-only|--detach) ;;
  *) echo "$0: unknown mode $mode" >&2; exit 2 ;;
esac
if [ ! -f "$lock" ]; then
  echo "$0: no lock at $lock" >&2
  exit 1
fi
if [ -n "$explicit_file" ] && [ ! -f "$explicit_file" ]; then
  echo "$0: no sibling-repos file at $explicit_file" >&2
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
handled=" "

# One sibling at one revision: in --fetch-only bring the object in, in
# --detach put the checkout there. Counts into `seen` and `acted`.
reconcile_one() {
  local name="$1" revision="$2" source="$3" directory head
  directory="$siblings_root/$name"
  if [ ! -d "$directory/.git" ]; then return 0; fi
  seen=$((seen + 1))
  if [ "$mode" = "--fetch-only" ]; then
    if git -C "$directory" cat-file -e "$revision^{commit}" 2>/dev/null; then
      return 0
    fi
    echo "reconcile: fetching $name for $revision"
    git -C "$directory" fetch --quiet origin "$revision" \
      || git -C "$directory" fetch --quiet origin \
           '+refs/heads/*:refs/remotes/origin/*'
    acted=$((acted + 1))
    return 0
  fi
  if [ "$(git -C "$directory" rev-parse HEAD)" = "$revision" ]; then
    return 0
  fi
  echo "reconcile: $name -> $source $revision"
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
    echo "reconcile: $name is at $head, not the $source $revision" >&2
    exit 1
  fi
  echo "reconcile: $name at $head"
  acted=$((acted + 1))
}

while IFS= read -r entry; do
  name="$(printf '%s' "$entry" | sed -n 's/.*[^-]name = "\([^"]*\)".*/\1/p')"
  revision="$(printf '%s' "$entry" \
    | sed -n 's/.*revision = "\([0-9a-f]\{40\}\)".*/\1/p')"
  if [ -z "$name" ] || [ -z "$revision" ]; then continue; fi
  if [ "$name" = "$exclude" ]; then continue; fi
  handled="$handled$name "
  reconcile_one "$name" "$revision" locked
done < "$entries"

# The explicit pins of the sibling-repos file, for names the lock did not
# name. `name=<40-hex>` lines only: a bare name means "the lock's revision",
# and `name=<branch>` is not a revision to detach to.
if [ -n "$explicit_file" ]; then
  while IFS= read -r line; do
    name="$(printf '%s' "$line" | sed -n 's/^\([A-Za-z0-9_.-][A-Za-z0-9_.-]*\)=\([0-9a-f]\{40\}\)[[:space:]]*$/\1/p')"
    revision="$(printf '%s' "$line" | sed -n 's/^\([A-Za-z0-9_.-][A-Za-z0-9_.-]*\)=\([0-9a-f]\{40\}\)[[:space:]]*$/\2/p')"
    if [ -z "$name" ] || [ -z "$revision" ]; then continue; fi
    if [ "$name" = "$exclude" ]; then continue; fi
    case "$handled" in *" $name "*) continue ;; esac
    handled="$handled$name "
    reconcile_one "$name" "$revision" "explicit"
  done < "$explicit_file"
fi

echo "reconcile: $(basename "$lock") in $(dirname "$lock" | xargs basename):" \
  "$seen sibling(s) present, $acted acted on ($mode)"
