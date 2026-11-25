#!/usr/bin/env bash
# Write the lock that puts a downstream consumer's build siblings at the
# revisions that consumer's OWN CI builds against.
#
# Used by the `native-recorder-hcr-claims` job in
# .github/workflows/downstream-tests.yml, which builds
# codetracer-native-recorder against this checkout. The recorder builds
# against four siblings that must agree with it and with each other, so the
# job puts each at a pinned revision before it builds (with
# scripts/reconcile_locked_siblings.sh, which reads the file written here).
#
# A pin comes from one of two places, and the recorder itself says which.
# Its CI job clones its siblings through setup-dev-env's `siblings:` list,
# and that list has two forms:
#
#   name            the revision the consumer's committed repro.lock records;
#   name=<sha>      that commit, for a sibling the lock does not record.
#
# The lock records only what the consumer's repro.nim declares. The recorder
# deliberately does not model `build-license-ffi`, which builds inside
# ../codetracer-native-backend, so its lock cannot name the backend. Its CI
# therefore pins the backend by commit in that list instead. This script
# reads the list from the named job and resolves each requested sibling the
# same way setup-dev-env does. The downstream job then builds against what
# the consumer's own CI builds against, whichever source holds each pin.
#
# It refuses instead of guessing. It fails when the job does not clone a
# requested sibling, when the list names it by a ref that is not a full
# commit, and when the list leaves a bare name to a lock that records no
# revision for it. An unpinned sibling would build against whatever `dev`
# happens to be, and those tips have been measured not to agree.
#
# Usage:
#   recorder_build_siblings_lock.sh <consumer-checkout> <workflow> <job> \
#       <out-lock> <sibling>...
#
# <workflow> is relative to <consumer-checkout>. The output is in the lock's
# own syntax (a `schema` line, then `[lock]` with `deps` as one array of
# inline tables) and holds exactly one entry per requested sibling.
#
# grep, sed and awk rather than an interpreter: this runs in a workflow step
# where python3 is reachable only through `dev-exec`.
set -euo pipefail

if [ "$#" -lt 5 ]; then
  echo "usage: $0 <consumer-checkout> <workflow> <job> <out-lock> <sibling>..." >&2
  exit 2
fi
consumer="$1"
workflow_rel="$2"
job="$3"
out="$4"
shift 4

lock="$consumer/repro.lock"
workflow="$consumer/$workflow_rel"
consumer_name="$(basename "$consumer")"
[ -f "$lock" ] || { echo "$0: no lock at $lock" >&2; exit 1; }
[ -f "$workflow" ] || { echo "$0: no workflow at $workflow" >&2; exit 1; }
if [ -e "$out" ]; then
  echo "$0: refusing to overwrite $out" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "${work:?}"' EXIT

# The job's `siblings: |` block, one entry per line, comments and blank lines
# dropped. The job runs from its `  <job>:` key to the next two-space key;
# the block runs to the first non-blank line indented no deeper than the
# `siblings:` key itself.
awk -v job="  $job:" '
  $0 == job { in_job = 1; next }
  in_job && /^  [^ ]/ { exit }
  !in_job { next }
  in_block {
    if ($0 ~ /^[ \t]*$/) next
    match($0, /^ */)
    if (RLENGTH <= block_indent) { in_block = 0; done = 1; next }
    line = $0
    sub(/#.*/, "", line)
    gsub(/^[ \t]+|[ \t]+$/, "", line)
    if (line != "") print line
    next
  }
  !done && /^ *siblings: *\| *$/ {
    match($0, /^ */)
    block_indent = RLENGTH
    in_block = 1
  }
' "$workflow" > "$work/siblings"
if [ ! -s "$work/siblings" ]; then
  echo "$0: job \`$job\` in $workflow_rel has no siblings: list" >&2
  exit 1
fi

# The lock's vcs entries, one brace group per line.
grep -o '{[^{}]*}' "$lock" | grep 'coord_kind = "vcs"' > "$work/entries" || true

# A synthesised entry is fetched from where the consumer's CI fetches it:
# setup-dev-env clones every sibling from the consumer's own owner, which the
# lock's `self` entry names.
self_url="$( { grep 'self = "true"' "$work/entries" || true; } \
  | sed -n 's/.*[^_]url = "\([^"]*\)".*/\1/p' | head -n 1)"
owner_base="${self_url%/*}"
if [ -z "$self_url" ] || [ "$owner_base" = "$self_url" ]; then
  echo "$0: $lock has no self entry with a url to take the owner from" >&2
  exit 1
fi

deps=()
for name in "$@"; do
  # `name` or `name=<ref>`, matched on the name exactly.
  spec="$(awk -F= -v n="$name" '$1 == n { print; exit }' "$work/siblings")"
  if [ -z "$spec" ]; then
    echo "$0: job \`$job\` in $consumer_name/$workflow_rel does not clone $name," \
      "so $consumer_name's CI names no revision for it" >&2
    exit 1
  fi
  if [ "$spec" = "$name" ]; then
    entry="$(grep -F "{ name = \"$name\"," "$work/entries" | grep -v 'self = "true"' \
      | head -n 1 || true)"
    revision="$(printf '%s' "$entry" \
      | sed -n 's/.*revision = "\([0-9a-f]\{40\}\)".*/\1/p')"
    if [ -z "$revision" ]; then
      echo "$0: job \`$job\` in $consumer_name/$workflow_rel leaves $name to" \
        "$consumer_name/repro.lock, which records no revision for it" >&2
      exit 1
    fi
    echo "recorder-siblings: $name at $revision (from $consumer_name/repro.lock)" >&2
    deps+=("$entry")
    continue
  fi
  revision="${spec#*=}"
  if ! printf '%s' "$revision" | grep -qx '[0-9a-f]\{40\}'; then
    echo "$0: job \`$job\` in $consumer_name/$workflow_rel names $name at" \
      "\`$revision\`, which is not a full commit; a ref moves, so it pins nothing" >&2
    exit 1
  fi
  echo "recorder-siblings: $name at $revision (pinned in $consumer_name/$workflow_rel)" >&2
  deps+=("{ name = \"$name\", coord_kind = \"vcs\", url = \"$owner_base/$name\", revision = \"$revision\", integrity = \"git-sha1:$revision\" }")
done

{ grep '^schema = ' "$lock" || true
  printf '[lock]\ndeps = ['
  ( IFS=,; printf '%s' "${deps[*]}" )
  printf ']\n'; } > "$work/out.lock"
mv "$work/out.lock" "$out"
