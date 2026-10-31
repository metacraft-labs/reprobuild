## Failure-atomic fast-forward shared by ordinary and role-targeted sync.
## The runner preserves each caller's bound Git identity and hook context;
## queries must return stdout separately from diagnostics.
import std/[os, strutils]

type
  FastForwardGitResult* = tuple[code: int; output, diagnostic: string]
  FastForwardGitRunner* = proc(args: seq[string]; query: bool):
    FastForwardGitResult {.closure, gcsafe.}
  AtomicFastForwardResult* = object
    ok*: bool
    refused*: bool
    diagnostic*: string

proc atomicFastForward*(repo, target: string;
                        git: FastForwardGitRunner): AtomicFastForwardResult =
  ## Only a proven-clean checkout may enter the rollback boundary. A failed
  ## merge can leave additions untracked even when HEAD and index never moved,
  ## so restoring HEAD alone is insufficient: clean those exact additions too.
  proc safely(args: seq[string]; query: bool): FastForwardGitResult =
    try:
      git(args, query)
    except CatchableError as error:
      (-1, "", error.msg)
  template query(args: varargs[string]): FastForwardGitResult =
    safely(@["-C", repo] & @args, true)
  let before = query("rev-parse", "--verify", "HEAD")
  # Pin the ref once: another fetch may advance it while checkout collision
  # checks run, and cleanup must describe precisely the tree we attempt.
  let targetHead = query("rev-parse", "--verify", target & "^{commit}")
  let clean = query("status", "--porcelain=v1", "--untracked-files=all")
  let flags = query("ls-files", "-v", "-z")
  if before.code != 0 or before.output.strip().len == 0 or
      targetHead.code != 0 or targetHead.output.strip().len == 0 or
      clean.code != 0 or flags.code != 0:
    result.refused = true
    result.diagnostic = "fast-forward refused before mutation: cannot verify " &
      "original HEAD/index/worktree: " & before.diagnostic & clean.diagnostic &
      flags.diagnostic & targetHead.diagnostic
    return
  if clean.output.len > 0:
    result.refused = true
    result.diagnostic = "fast-forward refused before mutation: index or working tree is dirty"
    return
  for entry in flags.output.split('\0'):
    if entry.len > 0 and entry[0] != 'H':
      result.refused = true
      result.diagnostic = "fast-forward refused before mutation: index entries " &
        "with skip-worktree or assume-unchanged flags prevent safe restoration; " &
        "clear those flags and retry"
      return
  let oldHead = before.output.strip()
  let targetSha = targetHead.output.strip()
  let additions = query("diff", "--no-renames", "--name-only", "--diff-filter=A",
    "-z", oldHead, targetSha, "--")
  let ignored = query("ls-files", "--others", "--ignored", "--exclude-standard", "-z")
  if additions.code != 0 or ignored.code != 0:
    result.refused = true
    result.diagnostic = "fast-forward refused before mutation: cannot verify " &
      "checkout collisions: " & additions.diagnostic & ignored.diagnostic
    return
  var created: seq[string]
  for path in additions.output.split('\0'):
    if path.len == 0: continue
    for local in ignored.output.split('\0'):
      if local.len > 0 and (local == path or local.startsWith(path & "/") or
          path.startsWith(local & "/")):
        result.refused = true
        result.diagnostic = "fast-forward refused before mutation: ignored path '" &
          local & "' collides with upstream path '" & path &
          "'; move it aside before retrying"
        return
    var ancestor = path.parentDir
    var oldFileAncestor = false
    while ancestor.len > 0 and ancestor != ".":
      if symlinkExists(repo / ancestor) or fileExists(repo / ancestor):
        let tracked = query("ls-files", "--error-unmatch", "--", ":(literal)" & ancestor)
        if tracked.code != 0:
          result.refused = true
          result.diagnostic = "fast-forward refused before mutation: local ancestor '" &
            ancestor & "' prevents safe restoration; move it aside before retrying"
          return
        oldFileAncestor = true
        break
      ancestor = ancestor.parentDir
    # An ancestor tracked as a file/symlink is replaced by a directory, so
    # paths beneath it did not exist in the original checkout. Do not follow
    # that symlink while inspecting a destination outside the repository.
    if not oldFileAncestor and (fileExists(repo / path) or
        symlinkExists(repo / path) or dirExists(repo / path)):
      let oldEntry = query("ls-tree", "-z", oldHead, "--", ":(literal)" & path)
      if oldEntry.code != 0 or not oldEntry.output.startsWith("040000 tree "):
        result.refused = true
        result.diagnostic = "fast-forward refused before mutation: pre-existing path '" &
          path & "' prevents safe restoration; move it aside before retrying"
        return
    if not oldFileAncestor:
      created.add(":(literal)" & path)
  let merged = safely(@["-C", repo, "-c", "submodule.recurse=false",
    "merge", "--ff-only", targetSha], false)
  if merged.code == 0:
    result.ok = true
    return
  # Clean before reset: the original index may still contain a symlink that
  # the failed checkout replaced with a directory. Never clean through a
  # symlink restored by reset. Literal pathspecs protect names with Git magic.
  var cleanup: FastForwardGitResult
  var first = 0
  while first < created.len:
    # Bounded argv avoids turning a broad upstream change into E2BIG during
    # rollback. Each batch remains scoped to exact, previously absent paths.
    let last = min(first + 32, created.len)
    let batch = safely(@["-C", repo, "clean", "-fdx", "--"] &
      created[first ..< last], false)
    if batch.code != 0: cleanup.code = batch.code
    cleanup.diagnostic.add(batch.diagnostic)
    first = last
  let restored = safely(@["-C", repo, "-c", "submodule.recurse=false",
    "reset", "--hard", oldHead], false)
  let afterHead = query("rev-parse", "--verify", "HEAD")
  let afterStatus = query("status", "--porcelain=v1", "--untracked-files=all")
  result.diagnostic = "git merge --ff-only exited " & $merged.code & ": " &
    merged.diagnostic.strip()
  if cleanup.code == 0 and restored.code == 0 and afterHead.code == 0 and
      afterHead.output.strip() == oldHead and afterStatus.code == 0 and
      afterStatus.output.len == 0:
    result.diagnostic.add("; original HEAD, index and worktree restored")
  else:
    result.diagnostic.add("; restoration FAILED; worktree may be half-applied: " &
      cleanup.diagnostic & restored.diagnostic & afterHead.diagnostic &
      afterStatus.diagnostic & "; after repairing the Git/object or filesystem " &
      "error, restore the pre-sync state with '")
    if created.len > 0:
      result.diagnostic.add((@["git", "-C", repo, "clean", "-fdx", "--"] &
        created).quoteShellCommand() & "' then '")
    result.diagnostic.add(@["git", "-C", repo, "reset", "--hard", oldHead].quoteShellCommand() & "'")
