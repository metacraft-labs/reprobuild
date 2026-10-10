## Workspace VCS — relocating a checkout that a declared rename stranded.
##
## `reprobuild-pm/spec/Declared-Repository-Renames.md`. A repo fragment may
## declare the identities it was previously known by
## (`[extensions] previously`); when the declared `path` holds nothing and one
## of those prior paths holds a git checkout, `repro sync` MOVES the directory
## instead of orphaning it and cloning a second copy.
##
## This module is the git/filesystem half: the probes the decision reads, the
## identity evidence it rests on, and the move itself. The POLICY — which
## candidate, which refusal, what the report says — lives in the sync driver,
## because only it knows the whole declared repo set. Everything here answers
## one question about one directory and mutates nothing unless its name says
## so.
##
## Three properties are load-bearing and must survive any edit:
##
## 1. **Move the directory; do not reconstruct the checkout.** Everything
##    local about a git checkout lives inside its own `.git` directory and
##    working tree, so a directory rename carries all of it BY CONSTRUCTION:
##    local branches and their reflogs, `refs/stash` and its reflog, the index,
##    uncommitted and untracked files, `.git/config` with its remotes and
##    per-branch upstreams, hooks, `.git/info/exclude`, the `rerere` cache,
##    sparse-checkout settings. An implementation that enumerated state and
##    copied it would be correct only until the first item nobody thought of,
##    and that omission is exactly the data loss this mechanism exists to
##    prevent.
## 2. **Copy, verify, then delete — never reordered.** Across filesystems a
##    rename is unavailable, so the fallback copies, RE-CAPTURES at the
##    destination, requires an exact match, and only then removes the source. A
##    mismatch keeps BOTH copies: two copies of the work is a recoverable
##    state, a deleted source beside an incomplete destination is not.
## 3. **Presence, not reachability.** The shared-object probe asks whether an
##    object id EXISTS in a store, via `git cat-file -e`. `git filter-repo`
##    rewrites commits and trees but carries blobs across, so blob presence
##    survives a rewrite where every commit id does not — and a rewritten
##    repository is the first case this mechanism meets, not an edge case.
##    Asking about reachability instead has already cost this workspace a wrong
##    answer in the other direction: a shared cache checked by reachability
##    reported clean because its refs predated the rewrite while the objects
##    were still there.
##
## `cat-file -e` is the idiom the single-object callers here use —
## `commitReachableLocally` asks `cat-file -e <sha>^{commit}` — and a BOUNDED
## sample (32 ids) is what makes one process per object affordable.
##
## A CORRECTION TO THE SPEC, recorded because the reasoning it offered is no
## longer true of this tree: Declared-Repository-Renames.md §3.3(b) justifies
## `cat-file -e` partly on "`--batch-check` appears nowhere in the tree". It
## does appear — `shared_clones.batchPresence` probes object presence with
## `cat-file --batch-check=%(objectname)`, chunked at 900 ids (48 on Windows)
## with lazy fetching off, and the pool retention hook uses it too. So the
## batched form is not a hypothetical future optimisation: it is a working
## primitive one module over, and the reason not to reach for it here is
## narrower than the spec's. It is PRIVATE to that module, it answers the
## inverse question (which ids are MISSING), and for a bounded 32-id sample
## the batching buys nothing measurable. If this sample ever grows,
## `batchPresence` is what to export rather than what to write.

{.push raises: [].}

import std/[algorithm, os, strutils]
import git_tool

proc cRename(oldname, newname: cstring): cint
  {.importc: "rename", header: "<stdio.h>".}
  ## ISO C `rename`, which is `rename(2)` on POSIX and maps onto `MoveFile`
  ## on Windows. Called DIRECTLY rather than through `os.moveDir`, and that is
  ## not a micro-optimisation: `moveDir` falls back to `copyDir` + `removeDir`
  ## internally when the rename fails, which deletes the source WITHOUT the
  ## verification step between — the one ordering
  ## Declared-Repository-Renames.md §3.4 says must never be reordered. The
  ## fallback has to be ours so the verify can sit inside it.
  ##
  ## Both platforms refuse a cross-volume directory rename (`EXDEV`,
  ## `ERROR_NOT_SAME_DEVICE`) and a non-empty existing destination, which is
  ## what makes "rename first, fall back on any failure" safe here: relocation
  ## never aims at an occupied destination (`destination_occupied` refuses
  ## first), so a failure is a genuine "this rename cannot happen".

type
  RelocationGitProbe* = object
    ## Keep the CLI's resolved Git execution profile, including its identity
    ## and version evidence, through every relocation query.
    identity*: GitToolIdentity

  CheckoutCapture* = object
    ## The state of a checkout, captured for two readers at once
    ## (Declared-Repository-Renames.md §3.4 step 1): the cross-filesystem
    ## copy's post-copy comparison, and the rewritten-history detection, which
    ## needs the candidate's PRE-FETCH tip. One capture, read twice — a second
    ## capture after the move would answer the first question about a
    ## different moment.
    ok*: bool
    diagnostic*: string
    headSha*: string
    currentBranch*: string
    refs*: seq[string]     ## `<sha> <refname>` for every ref, sorted
    stashes*: seq[string]  ## `git stash list` lines
    porcelain*: seq[string] ## `git status --porcelain` lines, sorted

  CheckoutSubstance* = enum
    ## What is at a path a relocation might take its candidate from.
    ##
    ## `observeRepoForSync` collapses the first two into `exists = false`,
    ## because for ITS purposes both mean "clone". Relocation needs them apart:
    ## one is nothing, the other is something the operator put there — and the
    ## rule the work-loss probes share ("'we could not tell' and 'there is
    ## nothing there' must never collapse into the same answer") binds here
    ## even though relocation never deletes, because the two produce different
    ## NOTICES and only one of them is worth an operator's attention.
    csAbsent          ## No directory at all.
    csNotAGitRepo     ## A directory, but `git rev-parse --git-dir` fails.
    csEmptyGitRepo    ## A git repo with nothing in it worth moving.
    csSubstantial     ## A git repo carrying commits, branches, stashes or
                      ## uncommitted work.

  RelocationMoveResult* = object
    ## Outcome of the move. `verificationFailed` is distinguished from a plain
    ## failure because the two carry different promises about the disk: a plain
    ## failure moved nothing, a verification failure left BOTH copies.
    ok*: bool
    verificationFailed*: bool
    crossFilesystem*: bool
    diagnostic*: string

const
  relocationBlobSampleSize* = 32
    ## How many blob ids the shared-object fallback probes. Bounded because
    ## each is its own `cat-file -e` process; spread evenly across the listing
    ## rather than taken from the front, so the sample is not systematically
    ## confined to one subtree (a rewrite that stripped one directory of
    ## artifacts would otherwise be able to empty the whole sample).

proc runGit(probe: RelocationGitProbe; args: openArray[string]):
    tuple[code: int; output: string] =
  ## One place this module shells out, so a failure to even LAUNCH git is a
  ## non-zero code with a readable message rather than an exception escaping
  ## into a half-finished relocation.
  ##
  ## `scrubbedGitRepositoryEnv` is not optional here. Every call below is
  ## `git -C <some other directory>`, and an inherited `GIT_DIR` /
  ## `GIT_WORK_TREE` / `GIT_OBJECT_DIRECTORY` silently overrides `-C` — so a
  ## sync invoked from inside a git hook would ask its questions of the
  ## INVOKING repository and answer them about the candidate. Every other git
  ## caller in this library scrubs for the same reason.
  try:
    queryGit(probe.identity, args)
  except CatchableError as err:
    (code: 127, output: "could not run git: " & err.msg)
  except Exception as err:
    (code: 127, output: "could not run git: " & err.msg)

proc isGitCheckout*(probe: RelocationGitProbe; dir: string): bool =
  ## Whether `dir` is a git working tree, asked the way git itself answers it.
  ##
  ## `dirExists(dir / ".git")` is the cheaper test the sync path uses and it is
  ## WRONG here: a worktree-based or submodule-absorbed checkout carries a
  ## `.git` FILE, and a directory inside a repo answers yes to `rev-parse`
  ## while holding no `.git` of its own. `--git-dir` plus the
  ## `--is-inside-work-tree` check keeps the answer about THIS directory.
  try:
    if not dirExists(dir):
      return false
  except OSError:
    return false
  let inside = runGit(probe, ["-C", dir, "rev-parse", "--is-inside-work-tree"])
  if inside.code != 0 or inside.output.strip() != "true":
    return false
  let top = runGit(probe, ["-C", dir, "rev-parse", "--show-toplevel"])
  if top.code != 0:
    return false
  let reported = top.output.strip()
  if reported.len == 0:
    return false
  # A directory nested inside another checkout answers `true` above and
  # reports the OUTER toplevel. Relocation must not take such a directory for
  # a checkout of its own. Git resolves filesystem aliases such as macOS
  # /tmp -> /private/tmp; compare the actual directories, not their spellings.
  try:
    sameFile(reported, dir)
  except ValueError, OSError:
    false

proc directoryIsEmpty*(dir: string): bool =
  ## True when `dir` holds no entries at all. Used only to tell "nothing is
  ## there" apart from "something the tool could not identify", which are
  ## different notices.
  try:
    for _ in walkDir(dir):
      return false
  except OSError:
    return false
  true

proc captureCheckoutState*(probe: RelocationGitProbe;
                           dir: string): CheckoutCapture =
  ## Capture everything a move must preserve, as comparable text.
  ##
  ## A FAILED probe sets `ok = false` and is itself a blocker for the
  ## copy-verify path: a capture that could not be taken cannot be compared,
  ## and proceeding to delete the source on an uncomparable verification is
  ## the one ordering this module must never reach.
  result.ok = true
  let head = runGit(probe, ["-C", dir, "rev-parse", "HEAD"])
  if head.code == 0:
    result.headSha = head.output.strip()
  # A repo with no commits has no HEAD, which is not a probe failure.
  let branch = runGit(probe, ["-C", dir, "symbolic-ref", "--short", "-q",
    "HEAD"])
  if branch.code == 0:
    result.currentBranch = branch.output.strip()
  let refs = runGit(probe, ["-C", dir, "for-each-ref",
    "--format=%(objectname) %(refname)"])
  if refs.code != 0:
    result.ok = false
    result.diagnostic = "could not list refs: " & refs.output.strip()
    return
  for line in refs.output.splitLines():
    let trimmed = line.strip()
    if trimmed.len > 0:
      result.refs.add(trimmed)
  let stashes = runGit(probe, ["-C", dir, "stash", "list"])
  if stashes.code != 0:
    result.ok = false
    result.diagnostic = "could not read the stash list: " &
      stashes.output.strip()
    return
  for line in stashes.output.splitLines():
    let trimmed = line.strip()
    if trimmed.len > 0:
      result.stashes.add(trimmed)
  let status = runGit(probe, ["-C", dir, "status", "--porcelain"])
  if status.code != 0:
    result.ok = false
    result.diagnostic = "could not read git status: " & status.output.strip()
    return
  for line in status.output.splitLines():
    if line.strip().len > 0:
      result.porcelain.add(line)
  result.refs.sort()
  result.porcelain.sort()

proc sameState*(a, b: CheckoutCapture): string =
  ## "" when the two captures describe the same checkout, else the FIRST
  ## mismatching capture, named. Naming which one differs is what makes a
  ## verification failure actionable instead of a shrug.
  if a.headSha != b.headSha:
    return "HEAD (" & a.headSha & " vs " & b.headSha & ")"
  if a.currentBranch != b.currentBranch:
    return "current branch (" & a.currentBranch & " vs " & b.currentBranch & ")"
  if a.refs != b.refs:
    return "refs (" & $a.refs.len & " vs " & $b.refs.len & " entries)"
  if a.stashes != b.stashes:
    return "stash entries (" & $a.stashes.len & " vs " & $b.stashes.len & ")"
  if a.porcelain != b.porcelain:
    return "working-tree status (" & $a.porcelain.len & " vs " &
      $b.porcelain.len & " changed path(s))"
  ""

proc checkoutSubstance*(probe: RelocationGitProbe;
                        dir: string): CheckoutSubstance =
  ## Classify what is at `dir` (Declared-Repository-Renames.md §3.2 step 3).
  ##
  ## `csEmptyGitRepo` is the shape a FAILED clone leaves — no commits, no local
  ## branches, no stashes, a clean tree. It is common, and it must not become a
  ## refusal that blocks the rest of the sync, so relocation SKIPS it (with a
  ## note) rather than refusing.
  try:
    if not dirExists(dir):
      return csAbsent
  except OSError:
    return csAbsent
  if not isGitCheckout(probe, dir):
    return csNotAGitRepo
  let capture = captureCheckoutState(probe, dir)
  if not capture.ok:
    # Could not tell. Treat as substantial: the only consequence is that the
    # directory becomes a candidate and is then subjected to the identity
    # check, which refuses on evidence rather than on a failed probe.
    return csSubstantial
  if capture.headSha.len > 0 or capture.refs.len > 0 or
      capture.stashes.len > 0 or capture.porcelain.len > 0:
    return csSubstantial
  csEmptyGitRepo

proc inProgressOperation*(probe: RelocationGitProbe; dir: string): string =
  ## Name the git operation `dir` is in the middle of, or "" when it is idle.
  ##
  ## Moving a checkout mid-rebase leaves the sequencer's state pointing at a
  ## directory that no longer exists, and the operator's `--continue` then
  ## fails in a way that names neither the rename nor the move. Asked by
  ## marker FILE because there is no git command that answers "which operation,
  ## if any" in one call, and the markers are stable, documented git interface
  ## (`git-rebase`, `git-merge`, `git-cherry-pick`, `git-bisect` all
  ## document theirs).
  let gitDirRes = runGit(probe, ["-C", dir, "rev-parse", "--absolute-git-dir"])
  if gitDirRes.code != 0:
    return ""
  let gitDir = gitDirRes.output.strip()
  if gitDir.len == 0:
    return ""
  try:
    if dirExists(gitDir / "rebase-merge") or dirExists(gitDir / "rebase-apply"):
      return "rebase"
    if fileExists(gitDir / "MERGE_HEAD"):
      return "merge"
    if fileExists(gitDir / "CHERRY_PICK_HEAD"):
      return "cherry-pick"
    if fileExists(gitDir / "REVERT_HEAD"):
      return "revert"
    if fileExists(gitDir / "BISECT_LOG"):
      return "bisect"
  except OSError:
    return ""
  ""

proc absoluteSubmoduleGitdirs*(dir: string): seq[string] =
  ## Submodule working trees under `dir` whose `.git` FILE holds an ABSOLUTE
  ## `gitdir:` pointer (Declared-Repository-Renames.md §4
  ## `submodule_absolute_gitdir`).
  ##
  ## There is no submodule detection anywhere else in the workspace code, by
  ## design — a develop-mode sibling checkout IS the submodule replacement in
  ## this model — so this is new probing for a case the model expects to be
  ## rare. It is kept because the failure it prevents is a silently broken
  ## checkout after a move that otherwise reported success, and because the
  ## remedy (`git submodule absorbgitdirs`) is one command. A RELATIVE pointer
  ## survives the move and is not reported.
  var gitmodules = ""
  try:
    if not fileExists(dir / ".gitmodules"):
      return @[]
    gitmodules = readFile(dir / ".gitmodules")
  except CatchableError:
    return @[]
  if gitmodules.len == 0:
    return @[]
  # Walk the declared submodule paths rather than the whole tree: a full walk
  # of a large checkout to find `.git` files is minutes, and `.gitmodules` is
  # the authoritative list.
  for rawLine in gitmodules.splitLines():
    let line = rawLine.strip()
    if not line.startsWith("path"):
      continue
    let eq = line.find('=')
    if eq < 0:
      continue
    let subPath = line[eq + 1 .. ^1].strip()
    if subPath.len == 0:
      continue
    let marker = dir / subPath / ".git"
    try:
      if not fileExists(marker):
        continue
      for pointerLine in readFile(marker).splitLines():
        let trimmed = pointerLine.strip()
        if not trimmed.startsWith("gitdir:"):
          continue
        let target = trimmed["gitdir:".len .. ^1].strip()
        if target.len > 0 and isAbsolute(target):
          result.add(subPath & " -> " & target)
    except CatchableError:
      continue

proc objectPresent*(probe: RelocationGitProbe; dir, oid: string): bool =
  ## Whether `oid` exists in `dir`'s object store.
  ##
  ## THE PROBE READS THROUGH `alternates`, AND THAT IS ACCEPTED ON PURPOSE. A
  ## candidate can satisfy the shared-object check with an object it does not
  ## hold in its own pack. This does not weaken the verdict: a shared bare is
  ## keyed by FETCH URL, so the only bare a candidate can borrow from is one
  ## serving a URL this repository was or is published at, and finding the
  ## object there is evidence of the same lineage — which is the question being
  ## asked. Written down because an implementer who did not expect it would be
  ## tempted to defeat it, and defeating it breaks the renamed-AND-rewritten
  ## case this mechanism exists for.
  if oid.len == 0:
    return false
  runGit(probe, ["-C", dir, "cat-file", "-e", oid]).code == 0

proc resolveRef*(probe: RelocationGitProbe; dir, refName: string): string =
  ## `git rev-parse <ref>` in `dir`, or "" when it does not resolve.
  if refName.len == 0:
    return ""
  let res = runGit(probe, ["-C", dir, "rev-parse", "--verify", "--quiet",
    refName])
  if res.code != 0:
    return ""
  res.output.strip()

proc mergeBase*(probe: RelocationGitProbe;
                dir, a, b: string): tuple[found: bool; sha: string] =
  ## The merge base of `a` and `b` as computed inside `dir`.
  ##
  ## An EMPTY result is not a negative result for identity purposes: a
  ## repository whose history was rewritten shares no commit with its own
  ## remote, and under the history-rewrite campaign that is a live, expected
  ## state for exactly the repositories most likely to be renamed. The caller
  ## falls back to object presence; see `sampleBlobIds`.
  if a.len == 0 or b.len == 0:
    return (false, "")
  let res = runGit(probe, ["-C", dir, "merge-base", a, b])
  if res.code != 0:
    return (false, "")
  let sha = res.output.strip()
  (sha.len > 0, sha)

proc sampleBlobIds*(probe: RelocationGitProbe; dir, treeish: string;
                    limit = relocationBlobSampleSize): seq[string] =
  ## Up to `limit` blob ids from `treeish`'s tree, spread evenly across the
  ## listing. The source of the "objects the repository at the NEW url has"
  ## half of the identity check.
  if treeish.len == 0:
    return @[]
  let res = runGit(probe, ["-C", dir, "ls-tree", "-r", treeish])
  if res.code != 0:
    return @[]
  var blobs: seq[string]
  for line in res.output.splitLines():
    # `<mode> SP <type> SP <oid> TAB <path>`
    let tab = line.find('\t')
    if tab < 0:
      continue
    let fields = line[0 ..< tab].splitWhitespace()
    if fields.len < 3 or fields[1] != "blob":
      continue
    blobs.add(fields[2])
  if blobs.len == 0:
    return @[]
  if blobs.len <= limit:
    return blobs
  let stride = blobs.len div limit
  var picked: seq[string]
  var index = 0
  while index < blobs.len and picked.len < limit:
    picked.add(blobs[index])
    index += stride
  picked

proc copyTreeVerbatim(source, destination: string):
    tuple[ok: bool; diagnostic: string] =
  ## `copyDir`, which copies symlinks AS symlinks on every non-Windows OS
  ## (`cfSymlinkAsIs`) and skips them on Windows. `skipSpecial = false` keeps
  ## FIFOs and device nodes in scope rather than silently dropping them, so a
  ## tree carrying one produces a copy failure — and therefore a refusal with
  ## both copies intact — instead of a destination the verify step would have
  ## to catch.
  try:
    copyDir(source, destination, skipSpecial = false)
    (true, "")
  except OSError as err:
    (false, err.msg)
  except CatchableError as err:
    (false, err.msg)

proc relocateCheckout*(probe: RelocationGitProbe;
                       source, destination: string;
                       before: CheckoutCapture): RelocationMoveResult =
  ## Move the checkout at `source` to `destination`
  ## (Declared-Repository-Renames.md §3.4).
  ##
  ## A single `moveDir` first, which is `rename(2)` within a filesystem and
  ## therefore atomic. Only when that fails with a cross-device error does the
  ## copy-verify-delete fallback run, and it runs in that order with no
  ## shortcut: a mismatch at the verify step keeps both copies and refuses.
  ##
  ## `before` is the pre-move capture. It is REQUIRED rather than taken here,
  ## because the same capture feeds the rewritten-history detection downstream
  ## and taking a second one would answer a question about a different moment.
  ## A capture that failed means the copy path cannot verify, so the fallback
  ## refuses rather than proceeding to the delete.
  try:
    let parent = destination.parentDir
    if parent.len > 0 and not dirExists(parent):
      createDir(parent)
  except OSError as err:
    return RelocationMoveResult(ok: false,
      diagnostic: "could not create the destination's parent directory: " &
        err.msg)
  except CatchableError as err:
    return RelocationMoveResult(ok: false,
      diagnostic: "could not create the destination's parent directory: " &
        err.msg)

  # A single `rename(2)` of the directory, which is atomic within a
  # filesystem. Nothing is enumerated and nothing is reconstructed.
  if cRename(source.cstring, destination.cstring) == 0'i32:
    return RelocationMoveResult(ok: true)
  let renameDiagnostic = osErrorMsg(osLastError())

  # The rename failed. It may be a cross-filesystem move (a nested path under a
  # different mount), or it may be a held-open file — on Windows a directory
  # rename fails while ANY file under it is open, and an editor or a language
  # server is enough. The two are not distinguishable from the message
  # portably, so the fallback is attempted and a failure there reports both
  # diagnostics: guessing which one it was is how a clean "re-runnable once the
  # handle is released" refusal turns into a copy nobody asked for.
  if not before.ok:
    return RelocationMoveResult(ok: false,
      diagnostic: "rename failed (" & renameDiagnostic &
        ") and the cross-filesystem copy cannot be used here because the " &
        "pre-move state capture failed (" & before.diagnostic &
        "): a copy that cannot be VERIFIED must not be followed by deleting " &
        "the source")

  let copied = copyTreeVerbatim(source, destination)
  if not copied.ok:
    # Nothing is half-moved: the source is untouched, and whatever the copy
    # managed to write is removed so a re-run does not find a partial
    # destination and mistake it for an occupied one.
    try:
      if dirExists(destination):
        removeDir(destination)
    except CatchableError:
      discard
    return RelocationMoveResult(ok: false,
      diagnostic: "rename failed (" & renameDiagnostic &
        ") and the copy fallback failed too (" & copied.diagnostic & ")")

  let after = captureCheckoutState(probe, destination)
  if not after.ok:
    return RelocationMoveResult(ok: false, verificationFailed: true,
      crossFilesystem: true,
      diagnostic: "copied '" & source & "' to '" & destination &
        "' but could not re-capture its state to verify the copy (" &
        after.diagnostic & "); BOTH copies were kept and the source was NOT " &
        "deleted")
  let mismatch = sameState(before, after)
  if mismatch.len > 0:
    return RelocationMoveResult(ok: false, verificationFailed: true,
      crossFilesystem: true,
      diagnostic: "copied '" & source & "' to '" & destination &
        "' but the post-copy comparison does not match on " & mismatch &
        "; BOTH copies were kept and the source was NOT deleted")
  try:
    removeDir(source)
  except CatchableError as err:
    return RelocationMoveResult(ok: true, crossFilesystem: true,
      diagnostic: "copied and verified, but the source '" & source &
        "' could not be removed (" & err.msg &
        "); the checkout at '" & destination &
        "' is complete and the leftover source is safe to delete by hand")
  RelocationMoveResult(ok: true, crossFilesystem: true)

{.pop.}
