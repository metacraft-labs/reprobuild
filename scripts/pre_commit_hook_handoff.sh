#!/usr/bin/env bash
# Hand the git hooks directory back and forth between pre-commit's installer
# and Reprobuild's dispatcher, so a dev-shell entry cannot leave the pre-push
# publication gate uninstalled.
#
# THE PROBLEM. Both tools want `.git/hooks/<hook>`. Reprobuild's answer is to
# own that path with a dispatcher and chain whatever was there first as
# `<hook>.repro-local`; pre-commit's answer is to take the path and, if it
# finds something foreign, move it to `<hook>.legacy` and announce "Running in
# migration mode". Those two answers compose badly on the SECOND run: the
# dev-shell's shellHook runs pre-commit's installer, which writes a fresh shim
# over the dispatcher while `<hook>.repro-local` still holds the shim chained
# the previous time. `repro hooks ensure` then meets two foreign files at once.
#
# THE HANDOFF. Rather than let that state arise and be repaired, the shim is
# lent back to its owner for the duration of the installer:
#
#   before   the preserved `<hook>.repro-local` is set aside as
#            `<hook>.repro-local.handoff`, so pre-commit's installer sees a
#            hooks directory with no stale copy of its own output in it.
#   <the installer runs, then `repro hooks ensure --vcs` runs>
#   after    if `ensure` chained a fresh shim, the set-aside copy is stale and
#            is dropped; if the installer did not run at all (pre-commit's
#            config was already current, the common case) nothing chained
#            anything, and the set-aside copy is put back.
#
# THE CANONICAL HOOK PATH IS NEVER TOUCHED BY THIS SCRIPT. That is the point:
# whatever `.git/hooks/pre-push` was before `before` runs, it still is after —
# so the publication gate is not off for one instant on our account, in either
# branch. Only pre-commit's own installer moves it, for as long as it takes
# `repro hooks ensure` to run in the same shell entry.
#
# RECOVERY IS `after`'s JOB, NOT `before`'s. A shell entry that dies between
# the two halves leaves the copy set aside and nothing chained, and the NEXT
# entry converges from there without a resume step in `before`:
#
#   * if the installer never ran, the dispatcher is still at the canonical
#     path, `before` declines to lend a second time (a copy is already out on
#     loan), and `after` restores it from the dispatcher branch;
#   * if the installer DID run before the crash, the canonical path now holds
#     the installer's newer shim and nothing is chained, so `repro hooks
#     ensure` chains that newer shim directly — one foreign file, the ordinary
#     path — and `after` then drops the superseded copy.
#
# A resume step in `before` would take the second case and put the STALE copy
# back first, manufacturing the two-foreign-files state this whole script
# exists to prevent, and handing it to `ensure` to reconcile. `ensure` can
# usually do that, but only when the two shims are recognisably one
# installer's output; when they are not — a pre-commit template revision bump
# changes the shim's `# ID:` line — it correctly refuses, and the dev shell
# gets an error for a state nothing needed to create. So `before` does not
# resume.
#
# Nothing here ever fails the caller: a dev shell that refuses to open because
# a hook file could not be moved is worse than the drift, and `repro health`
# reports the drift with its own remedy.
set -uo pipefail

usage() {
  echo "usage: pre_commit_hook_handoff.sh (before|after) [--hooks-dir DIR] [--hook NAME]..." >&2
}

mode="${1-}"
shift || true
case "$mode" in
  before | after) ;;
  *)
    usage
    exit 2
    ;;
esac

hooks_dir=""
hooks=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --hooks-dir)
      hooks_dir="${2-}"
      shift 2 || exit 2
      ;;
    --hooks-dir=*)
      hooks_dir="${1#--hooks-dir=}"
      shift
      ;;
    --hook)
      hooks+=("${2-}")
      shift 2 || exit 2
      ;;
    --hook=*)
      hooks+=("${1#--hook=}")
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

# The hooks that Reprobuild manages AND pre-commit can be configured to write.
# `post-commit`, `post-merge` and `post-checkout` are managed too, but
# pre-commit leaves a hook it did not generate alone at uninstall time, so they
# have never been shadowed. Listing only what is at risk keeps the handoff from
# moving files no installer is about to compete for.
if [ "${#hooks[@]}" -eq 0 ]; then
  hooks=(pre-push)
fi

if [ -z "$hooks_dir" ]; then
  hooks_dir="$(git rev-parse --path-format=absolute --git-path hooks 2>/dev/null || true)"
fi
if [ -z "$hooks_dir" ]; then
  # Compatibility fallback for Git versions predating --path-format.
  raw="$(git rev-parse --git-path hooks 2>/dev/null || true)"
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  case "$raw" in
    "") ;;
    /*) hooks_dir="$raw" ;;
    *) [ -n "$top" ] && hooks_dir="$top/$raw" ;;
  esac
fi
if [ -z "$hooks_dir" ] || [ ! -d "$hooks_dir" ]; then
  # No git repository, or no hooks directory yet. Nothing to hand over.
  exit 0
fi

is_dispatcher() {
  [ -f "$1" ] && grep -q 'reprobuild hook dispatcher' "$1" 2>/dev/null
}

is_pre_commit_shim() {
  [ -f "$1" ] && grep -q 'File generated by pre-commit' "$1" 2>/dev/null
}

for hook in "${hooks[@]}"; do
  standard="$hooks_dir/$hook"
  chained="$standard.repro-local"
  aside="$chained.handoff"

  case "$mode" in
    before)
      # NO RESUME STEP HERE, deliberately — see "Recovery" in the header.
      # Lend the shim back only when the dispatcher is actually in place and
      # the chained file is pre-commit's own output. A chained hook somebody
      # WROTE is not the installer's to regenerate and is left alone.
      if is_dispatcher "$standard" && is_pre_commit_shim "$chained" &&
        [ ! -e "$aside" ]; then
        mv -f "$chained" "$aside" || true
      fi
      ;;
    after)
      if [ -f "$aside" ]; then
        if [ -e "$chained" ]; then
          # `repro hooks ensure` chained the freshly written shim; the copy
          # set aside is the superseded one.
          rm -f "$aside" || true
        elif is_dispatcher "$standard"; then
          # The installer never ran — pre-commit's config was already current,
          # which is every entry after the first. Put the shim back.
          mv -f "$aside" "$chained" || true
        else
          # The installer ran and `ensure` did not finish. Restoring here would
          # rebuild the two-foreign-files state the handoff exists to avoid,
          # and the copy is superseded anyway: an equivalent, freshly generated
          # shim is sitting at the canonical path for `ensure` to chain.
          rm -f "$aside" || true
        fi
      fi
      ;;
  esac
done

exit 0
