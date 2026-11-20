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
## 2. **Copy, verify, then set the source aside — never delete it.** Across
##    filesystems a rename is unavailable, so the fallback copies every entry
##    with its mode, compares the WHOLE tree — `.git` and ignored files
##    included, byte for byte — re-captures git's view at the destination, and
##    only when all of that matches renames the source to
##    `<prior>.relocated-<UTC stamp>` beside itself. A mismatch keeps BOTH
##    copies where they are. Nothing here deletes the source: a verification
##    can only be as complete as the list of things it thought to compare,
##    and a deleted source is the one outcome a missed item cannot be
##    recovered from (reprobuild-pm
##    issues/2026-11-12-cross-filesystem-relocation-deletes-the-source-after-a-verification-that-misses-most-local.md).
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

import std/[algorithm, os, sets, strutils, times]
when defined(posix):
  import std/posix
import git_tool
import repro_core/remedy_words

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

  LinkedWorktree* = object
    ## One entry of `git worktree list --porcelain`.
    path*: string            ## As git records it (symlink-resolved, absolute).
    locked*: bool
    lockReason*: string
    prunable*: bool          ## Git's verdict that the worktree is gone.
    prunableReason*: string

  LinkedWorktreeInventory* = object
    ## The worktree links a move of one checkout would cut. See
    ## `linkedWorktreeInventory`.
    ok*: bool
    diagnostic*: string
    commonDir*: string       ## Absolute Git common directory of the checkout.
    canonicalCheckout*: string
      ## The checkout's symlink-resolved path, taken BEFORE the move. Git
      ## records linked-worktree paths resolved, and after the move the prior
      ## path no longer exists to be resolved, so mapping a worktree inside
      ## the moved checkout to its new location needs this spelling captured
      ## while it still can be.
    linked*: seq[LinkedWorktree]
      ## Linked worktrees sharing the checkout's common directory, when the
      ## checkout OWNS it (is the main worktree). Each `.git` file names the
      ## checkout's location, so each is cut off by the move.
    selfLinked*: bool
      ## The checkout is itself a linked worktree of a common directory that
      ## lives elsewhere (its `.git` is a file). Moving it cuts one link, the
      ## common directory's record of where it lives, which
      ## `repairLinkedWorktrees` restores from the common directory's side.
    selfLocked*: bool
      ## A `selfLinked` checkout that git records as locked. Refused like a
      ## locked linked worktree (`unrepairableLinkedWorktrees`).
    selfLockReason*: string

  RelocationMoveResult* = object
    ## Outcome of the move. `verificationFailed` is distinguished from a plain
    ## failure because the two carry different promises about the disk: a plain
    ## failure moved nothing, a verification failure left BOTH copies.
    ok*: bool
    verificationFailed*: bool
    crossFilesystem*: bool
    retainedSource*: string
      ## Where the source of a successful cross-filesystem move now lives:
      ## renamed aside to `<prior>.relocated-<UTC stamp>`, or left at the prior
      ## path when even that rename failed. Empty for a plain rename, which
      ## leaves nothing behind. Never deleted by this module.
    diagnostic*: string

const
  relocationBlobSampleSize* = 32
    ## How many blob ids the shared-object fallback probes. Bounded because
    ## each is its own `cat-file -e` process; spread evenly across the listing
    ## rather than taken from the front, so the sample is not systematically
    ## confined to one subtree (a rewrite that stripped one directory of
    ## artifacts would otherwise be able to empty the whole sample).

  relocationBlobQuorum* = 3
    ## How many of the sampled DISTINCTIVE blobs must be present in the
    ## candidate (capped at the sample size; see `blobSampleSatisfied`).
    ##
    ## More than one because a single byte-identical file is not lineage: a
    ## vendored file, a copied helper or a generated stub can coincide between
    ## unrelated repositories even after the coincident classes below are
    ## excluded. A small absolute number rather than a fraction because a
    ## legitimate candidate may be far behind the tip it is compared with, and
    ## every file changed since its last fetch is a sampled blob it cannot
    ## have; a fraction would refuse exactly the long-neglected checkout a
    ## rename most often meets.

  relocationMinDistinctiveBlobSize* = 32
    ## Blobs shorter than this many bytes are not sampled. Short contents —
    ## the empty file, a newline, `1.0.0`, `*.pyc`, a one-line `__version__` —
    ## recur across unrelated repositories, so their ids are content
    ## coincidences rather than evidence of shared history.

  emptyBlobSha1* = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"
    ## `git hash-object -t blob /dev/null` in a SHA-1 repository: every empty
    ## `__init__.py`, `.gitkeep` and placeholder file in every repository.
  emptyBlobSha256* =
    "473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813"
    ## The same, in a SHA-256 repository (`git init --object-format=sha256`).

  boilerplateBasenamePrefixes = ["LICENSE", "LICENCE", "COPYING", "UNLICENSE",
    "COPYRIGHT", "NOTICE", "CODE_OF_CONDUCT"]
    ## Upper-cased basename prefixes of files that are, as a rule, copied
    ## verbatim from a template (GitHub's licence and community-file pickers,
    ## the SPDX texts): `LICENSE`, `LICENSE-MIT`, `LICENSE.md`,
    ## `COPYING.LESSER`, `CODE_OF_CONDUCT.md`. A blob found at such a path is
    ## not sampled even when it is long.
  boilerplateBasenames = [".gitignore", ".gitattributes", ".editorconfig",
    ".gitkeep", ".keep", ".dockerignore", ".npmignore", ".prettierignore"]
    ## Exact basenames of configuration files usually taken from a template
    ## (github/gitignore and the like).

proc isBoilerplatePath*(path: string): bool =
  ## Whether a tree entry at `path` is a file whose content is commonly copied
  ## verbatim between unrelated repositories (licence texts, template
  ## ignore/attribute files), so that its blob id is no evidence of lineage.
  ## Judged by basename, so `vendor/x/LICENSE` is boilerplate too.
  let base = path.extractFilename
  if base in boilerplateBasenames:
    return true
  let upper = base.toUpperAscii()
  for prefix in boilerplateBasenamePrefixes:
    if upper.startsWith(prefix):
      return true
  false

proc blobSampleSatisfied*(present, sampled: int): bool =
  ## The object-presence verdict of §3.3(b): at least
  ## `min(relocationBlobQuorum, sampled)` of the `sampled` distinctive blobs
  ## are present in the candidate. An empty sample is never satisfied — a tip
  ## with no distinctive blob offers nothing to compare, and "nothing to
  ## compare" must not read as agreement.
  sampled > 0 and present >= min(relocationBlobQuorum, sampled)

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
  ##
  ## A success's ``output`` is git's stdout alone (``queryGit``): the callers
  ## compare refs, stashes and porcelain lines, and a stderr warning counted
  ## as one of them made two identical checkouts compare different. A
  ## failure's ``output`` is git's merged message, which is what the callers
  ## quote, and git's reason is on stderr.
  try:
    let res = queryGit(probe.identity, args)
    (code: res.code,
     output: (if res.code == 0: res.output else: res.diagnostic))
  except CatchableError as err:
    (code: 127, output: "could not run git: " & err.msg)
  except Exception as err:
    (code: 127, output: "could not run git: " & err.msg)

proc isGitCheckout*(probe: RelocationGitProbe; dir: string): bool =
  ## Whether `dir` is a git working tree, asked the way git itself answers it.
  ##
  ## The sync path's cheaper presence test, `hasGitEntry` (a `.git` directory
  ## or file), only says something is there; it does not say git can use it,
  ## which is what a relocation must know before it moves anything. Nor does a
  ## bare `rev-parse` answer it: a directory inside a repo answers yes while
  ## holding no `.git` of its own. `--git-dir` plus the
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

proc resolveGitPath(dir, answer: string): string =
  ## `rev-parse --git-common-dir` answers RELATIVE to the directory it ran in
  ## for a main worktree (`.git`) and absolute for a linked one. Resolved here
  ## rather than with `--path-format=absolute`, which needs git 2.31: nothing
  ## else in this module asks for a git newer than `worktree repair` (2.29).
  let trimmed = answer.strip()
  if trimmed.len == 0:
    return ""
  let joined = if isAbsolute(trimmed): trimmed else: dir / trimmed
  try:
    normalizedPath(absolutePath(joined))
  except CatchableError:
    joined

proc canonicalDir(path: string): string =
  ## The symlink-resolved spelling of `path`, or `path` itself when it cannot
  ## be resolved. Git records a linked worktree's location through
  ## `strbuf_realpath`, so a prefix comparison against a candidate path that
  ## goes through a symlink (macOS `/tmp`, a workspace reached through a
  ## linked home directory) has to compare canonical spellings.
  try:
    expandFilename(path)
  except CatchableError:
    path

proc isAtOrUnder(path, root: string): bool =
  path == root or path.startsWith(root & DirSep) or
    (DirSep != '/' and path.startsWith(root & "/"))

proc parseWorktreeList(porcelain: string): seq[LinkedWorktree] =
  ## The records of `git worktree list --porcelain`, the documented machine
  ## format (https://git-scm.com/docs/git-worktree#_porcelain_format): one
  ## record per worktree, separated by blank lines, the main worktree first.
  var current: LinkedWorktree
  var inRecord = false
  for rawLine in porcelain.splitLines():
    let line = rawLine.strip(leading = false, trailing = true)
    if line.len == 0:
      if inRecord:
        result.add(current)
      current = LinkedWorktree()
      inRecord = false
      continue
    if line.startsWith("worktree "):
      if inRecord:
        result.add(current)
      current = LinkedWorktree(path: line["worktree ".len .. ^1])
      inRecord = true
    elif line == "locked" or line.startsWith("locked "):
      current.locked = true
      if line.len > "locked ".len:
        current.lockReason = line["locked ".len .. ^1]
    elif line == "prunable" or line.startsWith("prunable "):
      current.prunable = true
      if line.len > "prunable ".len:
        current.prunableReason = line["prunable ".len .. ^1]
  if inRecord:
    result.add(current)

proc linkedWorktreeInventory*(probe: RelocationGitProbe;
                              dir: string): LinkedWorktreeInventory =
  ## The linked worktrees a move of `dir` would cut off
  ## (Declared-Repository-Renames.md §3.5 "Linked worktrees", §4
  ## `linked_worktree_unrepairable`).
  ##
  ## A linked worktree's `.git` is a FILE holding `gitdir: <main>/.git/
  ## worktrees/<name>` — an absolute path by default, and a path relative to
  ## the linked worktree under `worktree.useRelativePaths`. Either way it
  ## names the main checkout's location, so renaming the main checkout leaves
  ## every linked worktree answering "not a git repository" until someone runs
  ## `git worktree repair`. Every agent and verifier in a workspace typically
  ## works in linked worktrees, often OUTSIDE the workspace, which is why this
  ## is not an edge case.
  ##
  ## Read from `git worktree list --porcelain`, the documented machine format
  ## (https://git-scm.com/docs/git-worktree#_porcelain_format), not by walking
  ## `<common dir>/worktrees/*`: git decides which entries are `locked` and
  ## `prunable`, and restating its rules here is how they would drift.
  ##
  ## A candidate that is ITSELF a linked worktree of some other common
  ## directory is reported as `selfLinked`, with no `linked` entries: its
  ## sibling worktrees belong to that other common directory, still name it
  ## and need no repair. Its own lock state is recorded, because a lock
  ## forbids the move.
  result.ok = true
  let gitDirRes = runGit(probe, ["-C", dir, "rev-parse", "--absolute-git-dir"])
  let commonRes = runGit(probe, ["-C", dir, "rev-parse", "--git-common-dir"])
  if gitDirRes.code != 0 or commonRes.code != 0:
    result.ok = false
    result.diagnostic = "could not resolve the git directories: " &
      (if gitDirRes.code != 0: gitDirRes.output.strip()
       else: commonRes.output.strip())
    return
  let gitDir = resolveGitPath(dir, gitDirRes.output)
  result.commonDir = resolveGitPath(dir, commonRes.output)
  result.canonicalCheckout = canonicalDir(dir)
  let owns =
    try: sameFile(gitDir, result.commonDir)
    except CatchableError: gitDir == result.commonDir
  result.selfLinked = not owns
  let listing = runGit(probe, ["-C", dir, "worktree", "list", "--porcelain"])
  if listing.code != 0:
    result.ok = false
    result.diagnostic = "could not list worktrees: " & listing.output.strip()
    return
  let records = parseWorktreeList(listing.output)
  let canonicalSelf = result.canonicalCheckout
  for record in records:
    let isSelf =
      try: sameFile(record.path, dir)
      except CatchableError: canonicalDir(record.path) == canonicalSelf
    if isSelf:
      result.selfLocked = record.locked
      result.selfLockReason = record.lockReason
      continue
    # The first record is always the main worktree (or the bare repository).
    # For an owning candidate that IS `dir`, handled above. For a self-linked
    # candidate the other records are not this checkout's to move.
    if owns:
      result.linked.add(record)

proc unrepairableLinkedWorktrees*(inventory: LinkedWorktreeInventory;
                                  priorPath: string): seq[string] =
  ## The linked worktrees `git worktree repair` could not reconnect after the
  ## move, each named with its remedy (§4 `linked_worktree_unrepairable`).
  ## Empty when every one of them can be repaired.
  ##
  ## MISSING: git marks it `prunable` (its directory or `.git` file is gone).
  ## There is nothing on disk to repoint, and it may be on an unmounted volume
  ## that will come back expecting the old location; either the operator
  ## restores it or discards the administrative entry.
  ##
  ## LOCKED: a lock is git's own "do not touch this worktree's administrative
  ## files" marker (`git worktree move` and `remove` refuse a locked worktree
  ## too), most often set for one on removable media. An unattended sync does
  ## not override it, including when the locked worktree is the checkout
  ## being moved.
  if inventory.selfLinked and inventory.selfLocked:
    result.add("'" & priorPath & "' is itself a LOCKED linked worktree of " &
      inventory.commonDir &
      (if inventory.selfLockReason.len > 0:
         " (" & inventory.selfLockReason & ")"
       else: "") &
      " — `git -C " & remedyPathWord(inventory.commonDir) & " worktree unlock " &
      remedyPathWord(priorPath) & "` once it is safe to move")
  for wt in inventory.linked:
    var missing = wt.prunable
    if not missing:
      try:
        missing = not dirExists(wt.path) or
          not (fileExists(wt.path / ".git") or dirExists(wt.path / ".git"))
      except CatchableError:
        missing = true
    if missing:
      result.add("'" & wt.path & "' is MISSING" &
        (if wt.prunableReason.len > 0: " (" & wt.prunableReason & ")"
         else: "") &
        " — restore it, or discard its entry with `git -C " & remedyPathWord(priorPath) &
        " worktree prune`" &
        (if wt.locked: " after `git -C " & remedyPathWord(priorPath) & " worktree unlock " &
           remedyPathWord(wt.path) & "`"
         else: ""))
    elif wt.locked:
      result.add("'" & wt.path & "' is LOCKED" &
        (if wt.lockReason.len > 0: " (" & wt.lockReason & ")" else: "") &
        " — `git -C " & remedyPathWord(priorPath) & " worktree unlock " & remedyPathWord(wt.path) &
        "` once it is safe to repoint, or `git -C " & remedyPathWord(priorPath) &
        " worktree remove " & remedyPathWord(wt.path) & "`")

proc relocatedWorktreePath*(path, source, destination: string;
                            canonicalSource = ""): string =
  ## Where linked worktree `path` lives after `source` moved to `destination`.
  ## A linked worktree INSIDE the moved checkout travelled with it; one
  ## outside did not move at all. `canonicalSource` is `source`'s
  ## symlink-resolved spelling captured before the move (git records worktree
  ## paths resolved); it cannot be computed here because `source` is gone.
  for root in [source, canonicalSource]:
    if root.len > 0 and isAtOrUnder(path, root):
      return destination & path[root.len .. ^1]
  path

proc repairLinkedWorktrees*(probe: RelocationGitProbe;
                            source, destination: string;
                            inventory: LinkedWorktreeInventory):
    tuple[repaired: seq[string]; failures: seq[string]] =
  ## MUTATING. After `source` moved to `destination`, reconnect every link the
  ## move cut: run `git worktree repair` from the moved checkout with each
  ## linked worktree's (post-move) path, then VERIFY each one from its own
  ## side — `git -C <linked> rev-parse --git-common-dir` must resolve and name
  ## the moved checkout's common directory. Repair reporting success is not
  ## taken as the proof, because the failure being prevented is a worktree
  ## that silently stops being a checkout.
  ##
  ## `git worktree repair` is git's own remedy for exactly this case: "if the
  ## main worktree is moved, linked worktrees will be unable to locate it.
  ## Running repair in the main worktree will reestablish the connection"
  ## (https://git-scm.com/docs/git-worktree#Documentation/git-worktree.txt-repair).
  ## It rewrites only the `.git` file of a linked worktree and the matching
  ## `gitdir` file under the common directory; it touches no working-tree
  ## content, index or ref.
  ##
  ## ONE `git worktree repair` PER WORKTREE, not one invocation naming them
  ## all: git dies on the first path it cannot use ("Invalid path"), which
  ## would leave every worktree after it unrepaired, and the per-worktree
  ## failure text would then blame the wrong one.
  ##
  ## A `selfLinked` checkout is the other direction of the same cut: the
  ## common directory, which did not move, still records the prior path, so
  ## git lists the moved checkout as `prunable` and a `git worktree prune`
  ## would discard its administrative entry (index, HEAD) out from under it.
  ## The repair runs from the common directory's side, naming the new path,
  ## because that works whether the checkout's `.git` file is absolute or
  ## relative ("running repair in the main worktree and specifying the new
  ## <path> of each linked worktree will reestablish all connections in both
  ## directions"). It is verified from both sides: the moved checkout must
  ## resolve to the common directory, and the common directory must list the
  ## moved checkout as a live worktree.
  if inventory.selfLinked:
    let repair = runGit(probe,
      ["-C", inventory.commonDir, "worktree", "repair", destination])
    let repairNote =
      if repair.code != 0: " (`git worktree repair` exited " & $repair.code &
        ": " & repair.output.strip() & ")"
      else: ""
    let answer = runGit(probe,
      ["-C", destination, "rev-parse", "--git-common-dir"])
    let resolved =
      if answer.code == 0: resolveGitPath(destination, answer.output) else: ""
    let resolves =
      if resolved.len == 0: false
      else:
        try: sameFile(resolved, inventory.commonDir)
        except CatchableError: false
    var listed = false
    let listing = runGit(probe,
      ["-C", inventory.commonDir, "worktree", "list", "--porcelain"])
    if listing.code == 0:
      for record in parseWorktreeList(listing.output):
        let isDestination =
          try: sameFile(record.path, destination)
          except CatchableError: false
        if isDestination and not record.prunable:
          listed = true
    if resolves and listed:
      result.repaired.add("linked worktree '" & destination &
        "' re-registered with " & inventory.commonDir)
    else:
      result.failures.add("'" & destination & "' is not registered with " &
        inventory.commonDir & " as a live worktree" &
        (if answer.code != 0: " (" & answer.output.strip() & ")" else: "") &
        repairNote & "; run `git -C " & remedyPathWord(inventory.commonDir) &
        " worktree repair " & remedyPathWord(destination) & "`")
    return
  if inventory.linked.len == 0:
    return
  var expected: seq[tuple[path, note: string]]
  for wt in inventory.linked:
    let moved = relocatedWorktreePath(wt.path, source, destination,
      inventory.canonicalCheckout)
    let repair = runGit(probe,
      ["-C", destination, "worktree", "repair", moved])
    expected.add((moved,
      if repair.code != 0: " (`git worktree repair` exited " & $repair.code &
        ": " & repair.output.strip() & ")"
      else: ""))
  let newCommon = runGit(probe,
    ["-C", destination, "rev-parse", "--git-common-dir"])
  let commonDir =
    if newCommon.code == 0: resolveGitPath(destination, newCommon.output)
    else: ""
  for (moved, repairNote) in expected:
    let answer = runGit(probe, ["-C", moved, "rev-parse", "--git-common-dir"])
    let resolved =
      if answer.code == 0: resolveGitPath(moved, answer.output) else: ""
    let same =
      if resolved.len == 0 or commonDir.len == 0: false
      else:
        try: sameFile(resolved, commonDir)
        except CatchableError: false
    if same:
      result.repaired.add("linked worktree '" & moved &
        "' repointed at " & commonDir)
    else:
      result.failures.add("'" & moved & "' does not resolve to " &
        (if commonDir.len > 0: commonDir else: destination / ".git") &
        (if answer.code != 0: " (" & answer.output.strip() & ")" else: "") &
        repairNote & "; run `git -C " & remedyPathWord(destination) & " worktree repair " &
        remedyPathWord(moved) & "`")

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
  ## Up to `limit` DISTINCTIVE blob ids from `treeish`'s tree, spread evenly
  ## across the listing. The source of the "objects the repository at the NEW
  ## url has" half of the identity check (§3.3b).
  ##
  ## Distinctive means: not the empty blob, not shorter than
  ## `relocationMinDistinctiveBlobSize`, not at a boilerplate path
  ## (`isBoilerplatePath`), and not already picked — a blob reachable at
  ## several paths is one object and is sampled once, so it cannot count
  ## towards `relocationBlobQuorum` more than once. Every exclusion removes a
  ## class of blob that unrelated repositories share by content alone; a
  ## sample containing one would let an unrelated directory pass the check
  ## that authorises moving it.
  if treeish.len == 0:
    return @[]
  # `-l` adds the object size; `-z` NUL-terminates records and stops git from
  # C-quoting unusual paths, so the basename test sees the real name.
  let res = runGit(probe, ["-C", dir, "ls-tree", "-r", "-l", "-z", treeish])
  if res.code != 0:
    return @[]
  var blobs: seq[string]
  var seen = initHashSet[string]()
  for record in res.output.split('\0'):
    # `<mode> SP <type> SP <oid> SP+ <size> TAB <path>`
    # (https://git-scm.com/docs/git-ls-tree#_output_format)
    let tab = record.find('\t')
    if tab < 0:
      continue
    let fields = record[0 ..< tab].splitWhitespace()
    if fields.len < 4 or fields[1] != "blob":
      continue
    let oid = fields[2]
    let size =
      try: parseInt(fields[3])
      except ValueError: -1
    if size < relocationMinDistinctiveBlobSize:
      continue
    if oid == emptyBlobSha1 or oid == emptyBlobSha256:
      continue
    if isBoilerplatePath(record[tab + 1 .. ^1]):
      continue
    if oid in seen:
      continue
    seen.incl(oid)
    blobs.add(oid)
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

type
  TreeEntryKind = enum
    ## What one directory entry is, asked WITHOUT following a symlink. The
    ## copy and the comparison both need the entry itself: following a link
    ## would copy (and compare) whatever it points at, possibly outside the
    ## tree, and lose the link.
    tekDirectory, tekFile, tekSymlink, tekSpecial

proc treeEntryKind(path: string): TreeEntryKind {.raises: [OSError].} =
  when defined(posix):
    var st: Stat
    if lstat(path.cstring, st) != 0'i32:
      raiseOSError(osLastError(), path)
    if S_ISLNK(st.st_mode): tekSymlink
    elif S_ISDIR(st.st_mode): tekDirectory
    elif S_ISREG(st.st_mode): tekFile
    else: tekSpecial
  else:
    let info = getFileInfo(path, followSymlink = false)
    case info.kind
    of pcDir: tekDirectory
    of pcFile: tekFile
    of pcLinkToFile, pcLinkToDir: tekSymlink

proc entryMode(path: string): int {.raises: [OSError].} =
  ## The full permission word of an entry that is not a symlink, setuid,
  ## setgid and sticky bits included (`getFilePermissions` drops those three).
  ## Windows has no mode word worth carrying: `copyFile` carries the
  ## attributes there, so the comparison has nothing to compare.
  when defined(posix):
    var st: Stat
    if lstat(path.cstring, st) != 0'i32:
      raiseOSError(osLastError(), path)
    int(st.st_mode) and 0o7777
  else:
    0

proc setEntryMode(path: string; mode: int) {.raises: [OSError].} =
  when defined(posix):
    if chmod(path.cstring, Mode(mode)) != 0'i32:
      raiseOSError(osLastError(), path)
  else:
    discard

proc copyTreeInto(source, destination: string)
    {.raises: [OSError, IOError, ValueError].} =
  ## Copy one directory, recursively, carrying each entry as what it is: a
  ## directory as a directory, a regular file with its content AND its mode, a
  ## symlink as the same link. A FIFO, socket or device node cannot be carried
  ## by a copy, so it is a copy failure (and therefore a refusal with the
  ## source untouched) rather than something silently dropped or, worse,
  ## opened: reading a FIFO blocks until a writer appears.
  ##
  ## `std/os.copyDir` is not used because it drops every permission bit on
  ## POSIX — an executable hook arrives as an inert file and git skips it
  ## with a hint nobody reads — and `copyDirWithPermissions` drops setuid,
  ## setgid and sticky bits and, by default, ignores a mode it failed to set.
  ## A directory's own mode is applied AFTER its contents, so a read-only
  ## directory can still be filled.
  createDir(destination)
  for _, path in walkDir(source, skipSpecial = false):
    let target = destination / path.extractFilename
    case treeEntryKind(path)
    of tekDirectory:
      copyTreeInto(path, target)
    of tekSymlink:
      when defined(posix):
        createSymlink(expandSymlink(path), target)
      else:
        # `expandSymlink` cannot read a link's target on Windows (it returns
        # the link's own path), so a "copy" would be a link back into the
        # source. Refused as a copy failure, like a FIFO, rather than made
        # wrong and left for the verification to trip over.
        raise newException(OSError, "'" & path & "' is a symbolic link, " &
          "whose target cannot be read on this platform, so a copy cannot " &
          "carry it")
    of tekFile:
      copyFile(path, target, {cfSymlinkAsIs})
      when defined(posix):
        setEntryMode(target, entryMode(path))
    of tekSpecial:
      raise newException(OSError, "'" & path & "' is a FIFO, socket or " &
        "device node, which a copy cannot carry")
  when defined(posix):
    setEntryMode(destination, entryMode(source))

proc copyTreeVerbatim(source, destination: string):
    tuple[ok: bool; diagnostic: string] =
  try:
    copyTreeInto(source, destination)
    (true, "")
  except CatchableError as err:
    (false, err.msg)

proc grantOwnerAccessToDirectories(dir: string) =
  ## Best effort, for removing a copy that failed part-way: give every
  ## directory under `dir` (and `dir` itself) owner read, write and search
  ## permission, without following symlinks. `copyTreeInto` applies a
  ## directory's own mode only after its contents, so a read-only directory it
  ## completed before failing would otherwise stop `removeDir` half-way and
  ## leave a partial checkout at the declared path. Only ever called on the
  ## destination this module just created, never on the source.
  when defined(posix):
    try:
      if treeEntryKind(dir) != tekDirectory:
        return
      let mode = entryMode(dir)
      if (mode and 0o700) != 0o700:
        setEntryMode(dir, mode or 0o700)
      for _, path in walkDir(dir, skipSpecial = false):
        if treeEntryKind(path) == tekDirectory:
          grantOwnerAccessToDirectories(path)
    except CatchableError:
      discard
  else:
    discard

proc sortedEntryNames(dir: string): seq[string] {.raises: [OSError].} =
  for _, path in walkDir(dir, relative = true, skipSpecial = false):
    result.add(path)
  result.sort()

proc sameFileContent(a, b: string): bool {.raises: [IOError].} =
  ## Byte-for-byte. Not a size check and not a hash of one side: a copy cut
  ## short by ENOSPC can be the right size (a sparse or pre-allocated file) and
  ## a hash would read both files in full anyway.
  const chunk = 65536
  var fa, fb: File
  if not open(fa, a, fmRead):
    raise newException(IOError, "cannot open '" & a & "'")
  defer: close(fa)
  if not open(fb, b, fmRead):
    raise newException(IOError, "cannot open '" & b & "'")
  defer: close(fb)
  var bufA = newString(chunk)
  var bufB = newString(chunk)
  while true:
    let readA = readBuffer(fa, addr bufA[0], chunk)
    let readB = readBuffer(fb, addr bufB[0], chunk)
    if readA != readB:
      return false
    if readA == 0:
      return true
    if not equalMem(addr bufA[0], addr bufB[0], readA):
      return false

proc compareTrees(source, destination, rel: string): string
    {.raises: [OSError, IOError].} =
  let here = if rel.len == 0: "." else: rel
  let namesA = sortedEntryNames(source)
  let namesB = sortedEntryNames(destination)
  if namesA != namesB:
    let setB = namesB.toHashSet()
    for name in namesA:
      if name notin setB:
        return "'" & (if rel.len == 0: name else: rel / name) &
          "' is missing from the copy"
    let setA = namesA.toHashSet()
    for name in namesB:
      if name notin setA:
        return "'" & (if rel.len == 0: name else: rel / name) &
          "' is in the copy but not in the source"
  for name in namesA:
    let a = source / name
    let b = destination / name
    let relName = if rel.len == 0: name else: rel / name
    let kindA = treeEntryKind(a)
    let kindB = treeEntryKind(b)
    if kindA != kindB:
      return "'" & relName & "' is a " & $kindA & " in the source but a " &
        $kindB & " in the copy"
    case kindA
    of tekSymlink:
      let targetA = expandSymlink(a)
      let targetB = expandSymlink(b)
      if targetA != targetB:
        return "'" & relName & "' differs in its symlink target ('" &
          targetA & "' vs '" & targetB & "')"
    of tekDirectory, tekFile, tekSpecial:
      let modeA = entryMode(a)
      let modeB = entryMode(b)
      if modeA != modeB:
        return "'" & relName & "' differs in permissions (" &
          modeA.toOct(4) & " vs " & modeB.toOct(4) & ")"
      if kindA == tekDirectory:
        let inner = compareTrees(a, b, relName)
        if inner.len > 0:
          return inner
      elif kindA == tekFile:
        let sizeA = getFileSize(a)
        let sizeB = getFileSize(b)
        if sizeA != sizeB:
          return "'" & relName & "' differs in size (" & $sizeA & " vs " &
            $sizeB & " bytes)"
        if not sameFileContent(a, b):
          return "'" & relName & "' differs in content"
  ""

proc treeDifference*(source, destination: string): string =
  ## "" when `destination` holds exactly the entries of `source` — every
  ## path, `.git` and ignored files included, each of the same kind, with the
  ## same mode, the same symlink target and the same bytes — else the FIRST
  ## difference, named by its path relative to the tree. Modification times,
  ## ownership and extended attributes are not compared: a copy by an
  ## unprivileged user cannot carry ownership, and a changed mtime costs git
  ## only an index refresh.
  ##
  ## A comparison that could not be completed is a difference, not a match:
  ## "we could not tell" must never read as "it matched" on the path that
  ## ends with the source being set aside.
  try:
    for root in [source, destination]:
      if treeEntryKind(root) != tekDirectory:
        return "'" & root & "' is not a directory"
    compareTrees(source, destination, "")
  except CatchableError as err:
    "the comparison could not be completed (" & err.msg & ")"

proc verifyRelocatedCopy*(probe: RelocationGitProbe;
                          source, destination: string;
                          before: CheckoutCapture): string =
  ## Declared-Repository-Renames.md §3.4 step 3. "" when the copy at
  ## `destination` is the checkout at `source`, else the first mismatch,
  ## named.
  ##
  ## Two comparisons, in this order. The WHOLE-TREE comparison first, because
  ## it is the one that sees what git's own view omits — ignored files (an
  ## `.env`, local data), every object and pack under `.git`, `.git/config`,
  ## hooks and their executable bits, the `rerere` cache — and because it must
  ## run before any git command touches the destination (`git status` may
  ## rewrite the index with the copy's own stat data). Then git's view, the
  ## pre-move `before` capture against a fresh one, which proves git reads
  ## the copy as the same checkout.
  ##
  ## `git fsck --connectivity-only` is deliberately not part of it. The tree
  ## comparison already proves every object file arrived byte for byte, and
  ## fsck answers a different question — whether the SOURCE was complete — on
  ## which a workspace checkout borrowing from a partial shared clone answers
  ## "missing" by design, so it would refuse moves that lose nothing.
  let tree = treeDifference(source, destination)
  if tree.len > 0:
    return tree
  let after = captureCheckoutState(probe, destination)
  if not after.ok:
    return "git could not read the copy (" & after.diagnostic & ")"
  sameState(before, after)

proc retainedSourcePath*(source: string; stamp: DateTime): string =
  ## `<source>.relocated-<UTC stamp>`, beside the source and therefore on the
  ## SAME filesystem, so setting the source aside is one atomic `rename(2)`.
  ## The stamp names when it was set aside; a numeric suffix keeps a second
  ## relocation within the same second from colliding with the first.
  var stampText = ""
  try:
    stampText = stamp.utc.format("yyyyMMdd'T'HHmmss'Z'")
  except CatchableError:
    stampText = "unknown-time"
  let base = source & ".relocated-" & stampText
  result = base
  var counter = 2
  while true:
    var taken = true
    try:
      taken = fileExists(result) or dirExists(result) or symlinkExists(result)
    except CatchableError:
      taken = true
    if not taken:
      return
    result = base & "-" & $counter
    inc counter

proc relocateCheckout*(probe: RelocationGitProbe;
                       source, destination: string;
                       before: CheckoutCapture): RelocationMoveResult =
  ## Move the checkout at `source` to `destination`
  ## (Declared-Repository-Renames.md §3.4).
  ##
  ## A single `rename(2)` first, atomic within a filesystem. Only when that
  ## fails does the copy-verify-set-aside fallback run, in that order with no
  ## shortcut: a mismatch at the verify step keeps both copies and refuses,
  ## and a match renames the source aside (`retainedSource`) — it is never
  ## deleted here.
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
    # destination and mistake it for an occupied one. The copy's read-only
    # directories are made writable first, or the removal stops at the first
    # one. If the removal still fails, the report says a partial copy is
    # there rather than letting it pass as nothing.
    var leftover = ""
    try:
      if dirExists(destination):
        grantOwnerAccessToDirectories(destination)
        removeDir(destination)
    except CatchableError as err:
      leftover = "; the partial copy at '" & destination &
        "' could not be removed (" & err.msg & ") — delete it before re-running"
    return RelocationMoveResult(ok: false,
      diagnostic: "rename failed (" & renameDiagnostic &
        ") and the copy fallback failed too (" & copied.diagnostic & ")" &
        leftover)

  let mismatch = verifyRelocatedCopy(probe, source, destination, before)
  if mismatch.len > 0:
    return RelocationMoveResult(ok: false, verificationFailed: true,
      crossFilesystem: true,
      diagnostic: "copied '" & source & "' to '" & destination &
        "' but the post-copy verification does not match: " & mismatch &
        "; BOTH copies were kept and the source was NOT touched")

  # Verified. The source is SET ASIDE, not deleted: a rename beside itself
  # (same filesystem, so atomic) takes it off the prior path, which is all
  # the relocation needs, and leaves the decision to delete it with the
  # operator, who can see both copies.
  let retained = retainedSourcePath(source, now())
  if cRename(source.cstring, retained.cstring) == 0'i32:
    return RelocationMoveResult(ok: true, crossFilesystem: true,
      retainedSource: retained,
      diagnostic: "moved across filesystems by copying and verifying; the " &
        "source was NOT deleted and is kept at '" & retained &
        "' — delete it once the checkout at '" & destination &
        "' is confirmed")
  RelocationMoveResult(ok: true, crossFilesystem: true,
    retainedSource: source,
    diagnostic: "moved across filesystems by copying and verifying, but the " &
      "source could not be set aside (" & osErrorMsg(osLastError()) &
      "); it is still at '" & source & "' — delete it once the checkout at '" &
      destination & "' is confirmed")

{.pop.}
