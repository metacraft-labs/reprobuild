## Declared-Repository-Renames.md §3.4 — the ORDER of the move, pinned at the
## module boundary.
##
## "Copy, verify, then delete, in that order, never reordered." The reason this
## is a unit test rather than only an integration one: the ordering is the
## single property whose violation is unrecoverable, and the integration path
## cannot force the interesting branches — a same-filesystem rename succeeds, so
## the copy fallback never runs, and a failure that makes the copy run also
## makes it fail. So the branches are driven directly.
##
## Two invariants and one anti-invariant:
##
##   1. A plain rename is what a same-filesystem move uses, and it carries the
##      `.git` directory verbatim — local branches, the stash, the index and
##      untracked files all arrive because the DIRECTORY moved, not because
##      anything enumerated them.
##   2. A cross-filesystem move copies, RE-CAPTURES, compares, and only then
##      deletes the source.
##   3. A pre-move capture that FAILED must stop the fallback, not proceed to
##      the delete: a copy that cannot be verified is a copy whose source must
##      survive. ("We could not tell" and "it matched" must never collapse.)
##
## Nothing is mocked: real git repositories, and for the cross-filesystem case
## a real second filesystem (`/dev/shm`, skipped when absent).
## Query controls retain a resolved Git profile while clearing PATH and
## supplying a different real repository through Git's hook environment. They
## require the requested checkout, literal argv and original exit statuses.

import repro_test_support/reasoned_skip
import std/[os, osproc, sequtils, strutils, tempfiles, unittest]
import repo_relocation, git_tool

proc q(value: string): string = quoteShell(value)

proc git(gitBin: string; args: string; cwd = ""): string =
  let res = execCmdEx(q(gitBin) & " " & args, workingDir = cwd)
  if res.exitCode != 0:
    checkpoint("git " & args & " failed: " & res.output)
    fail()
  res.output

proc seedCheckout(gitBin, path: string) =
  ## A checkout with everything a move has to carry: a second local branch, a
  ## stash entry, an untracked file and a modified tracked file.
  discard git(gitBin, "init --quiet -b main " & q(path))
  discard git(gitBin, "-C " & q(path) &
    " config user.email t@example.invalid")
  discard git(gitBin, "-C " & q(path) & " config user.name t")
  writeFile(path / "tracked.txt", "one\n")
  discard git(gitBin, "-C " & q(path) & " add tracked.txt")
  discard git(gitBin, "-C " & q(path) & " commit --quiet -m one")
  discard git(gitBin, "-C " & q(path) & " branch second")
  writeFile(path / "stashed.txt", "to stash\n")
  discard git(gitBin, "-C " & q(path) & " add stashed.txt")
  discard git(gitBin, "-C " & q(path) & " stash push --quiet -m keepme")
  writeFile(path / "tracked.txt", "one modified\n")
  writeFile(path / "untracked.txt", "never committed\n")

suite "repo_relocation — the move, and the order of it":

  test "resolved Git queries ignore ambient search and foreign hook bindings":
    let identity = resolveGitTool(tpmPathOnly, getEnv("PATH"))
    let scratch = createTempDir("repro-reloc-profile-", "")
    defer: removeDir(scratch)
    let target = scratch / "requested repo"
    let foreign = scratch / "foreign repo"
    seedCheckout(identity.binaryPath, target)
    seedCheckout(identity.binaryPath, foreign)
    let probe = RelocationGitProbe(identity: identity)
    var saved: seq[tuple[key: string, present: bool, value: string]] = @[]
    for key in ["PATH", "GIT_DIR", "GIT_WORK_TREE"]:
      saved.add((key, existsEnv(key), getEnv(key)))
    defer:
      for entry in saved:
        if entry.present: putEnv(entry.key, entry.value)
        else: delEnv(entry.key)
    putEnv("PATH", "")
    putEnv("GIT_DIR", foreign / ".git")
    putEnv("GIT_WORK_TREE", foreign)
    let queried = queryGit(identity, ["-C", target, "rev-parse", "--show-toplevel"])
    check queried.code == 0
    check sameFile(queried.output.strip(), target)
    check isGitCheckout(probe, target)
    let captured = captureCheckoutState(probe, target)
    check captured.ok
    check captured.stashes.len == 1
    check captured.porcelain.len == 2

  test "typed Git queries preserve literal arguments and failure status":
    let identity = resolveGitTool(tpmPathOnly, getEnv("PATH"))
    let scratch = createTempDir("repro-reloc-argv-", "")
    defer: removeDir(scratch)
    seedCheckout(identity.binaryPath, scratch / "repo")
    let target = scratch / "repo"
    let literal = "literal $HOME; `whoami` and spaces"
    let written = queryGit(identity, ["-C", target, "config", "probe.literal", literal])
    check written.code == 0
    let readBack = queryGit(identity, ["-C", target, "config", "--get", "probe.literal"])
    check readBack.code == 0
    check readBack.output.strip() == literal
    let missing = queryGit(identity, ["-C", target, "config", "--get", "probe.missing"])
    check missing.code == 1
    check missing.output == ""
    var unresolved = identity
    unresolved.binaryPath = "git"
    expect EGitToolUnresolved:
      discard queryGit(unresolved, ["--version"])

  when defined(posix):
    test "a checkout directory alias is accepted but its nested directory is not":
      let identity = resolveGitTool(tpmPathOnly, getEnv("PATH"))
      let scratch = createTempDir("repro-reloc-alias-", "")
      defer: removeDir(scratch)
      let target = scratch / "physical checkout"
      seedCheckout(identity.binaryPath, target)
      let alias = scratch / "alias"
      createSymlink(target, alias)
      let nested = alias / "nested"
      createDir(nested)
      let probe = RelocationGitProbe(identity: identity)
      check isGitCheckout(probe, target)
      check isGitCheckout(probe, alias)
      check checkoutSubstance(probe, alias) == csSubstantial
      check not isGitCheckout(probe, nested)

  test "t_relocate_renames_within_a_filesystem_and_carries_everything":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let scratch = createTempDir("repro-reloc-rename-", "")
      defer: removeDir(scratch)
      let probe = RelocationGitProbe(identity: resolveGitTool(tpmPathOnly, getEnv("PATH")))
      let source = scratch / "old-name"
      let destination = scratch / "new-name"
      seedCheckout(gitBin, source)

      let before = captureCheckoutState(probe, source)
      check before.ok
      check before.stashes.len == 1
      check before.porcelain.len == 2       # modified + untracked
      check before.refs.len >= 3            # main, second, refs/stash

      let moved = relocateCheckout(probe, source, destination, before)
      check moved.ok
      check moved.diagnostic == ""
      # A same-filesystem move is a rename, not a copy — so the fallback's
      # bookkeeping must be absent.
      check not moved.crossFilesystem
      check not dirExists(source)

      let after = captureCheckoutState(probe, destination)
      check after.ok
      check sameState(before, after) == ""
      check fileExists(destination / "untracked.txt")
      check readFile(destination / "tracked.txt") == "one modified\n"
      check "keepme" in git(gitBin, "-C " & q(destination) & " stash list")

  test "t_relocate_across_filesystems_copies_verifies_then_deletes":
    let gitBin = findExe("git")
    if gitBin.len == 0 or not dirExists("/dev/shm"):
      skip("requires Git and a second filesystem at /dev/shm")
    else:
      # Two real filesystems: the temp dir and `/dev/shm` (tmpfs). A rename
      # between them fails with EXDEV, which is the only way to reach the
      # fallback without faking anything.
      let scratch = createTempDir("repro-reloc-xdev-", "")
      let otherFs = createTempDir("repro-reloc-xdev-", "", "/dev/shm")
      defer:
        removeDir(scratch)
        removeDir(otherFs)
      let probe = RelocationGitProbe(identity: resolveGitTool(tpmPathOnly, getEnv("PATH")))
      let source = scratch / "old-name"
      let destination = otherFs / "new-name"
      seedCheckout(gitBin, source)
      # The premise, asserted: the two really are different filesystems, so
      # this case is testing the fallback and not the rename again.
      when defined(linux) or defined(macosx):
        let srcDev = execCmdEx("stat -c %d " & q(scratch)).output.strip()
        let dstDev = execCmdEx("stat -c %d " & q(otherFs)).output.strip()
        if srcDev == dstDev:
          skip("temporary directory and /dev/shm are on the same filesystem")
          return

      let before = captureCheckoutState(probe, source)
      check before.ok
      let moved = relocateCheckout(probe, source, destination, before)
      checkpoint("diagnostic: " & moved.diagnostic)
      check moved.ok
      check moved.crossFilesystem
      # Delete came LAST, and it came at all.
      check not dirExists(source)
      let after = captureCheckoutState(probe, destination)
      check after.ok
      check sameState(before, after) == ""
      check fileExists(destination / "untracked.txt")
      check "keepme" in git(gitBin, "-C " & q(destination) & " stash list")

  test "t_relocate_refuses_the_copy_fallback_when_the_capture_failed":
    ## INVARIANT 3. A capture that could not be taken cannot be compared, and
    ## proceeding to delete the source on an unverifiable copy is the one
    ## ordering this module must never reach. Driven by handing
    ## `relocateCheckout` a failed capture and a rename that cannot succeed.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let scratch = createTempDir("repro-reloc-nocapture-", "")
      defer:
        # Restore write permission so the temp tree can be removed.
        try: setFilePermissions(scratch / "nest",
          {fpUserRead, fpUserWrite, fpUserExec})
        except CatchableError: discard
        removeDir(scratch)
      let probe = RelocationGitProbe(identity: resolveGitTool(tpmPathOnly, getEnv("PATH")))
      let source = scratch / "old-name"
      seedCheckout(gitBin, source)
      createDir(scratch / "nest")
      let destination = scratch / "nest" / "new-name"
      # A read-only parent makes both the rename and the copy impossible,
      # which is the shape of the real failure (a held-open file on Windows,
      # a permission problem anywhere).
      setFilePermissions(scratch / "nest", {fpUserRead, fpUserExec})
      when defined(posix):
        if execCmdEx("id -u").output.strip() == "0":
          # root ignores the permission bits, so the case cannot be staged.
          skip("root bypasses the permission obstruction required by this case")
          return

      let failedCapture = CheckoutCapture(ok: false,
        diagnostic: "staged: the probe did not run")
      let moved = relocateCheckout(probe, source, destination, failedCapture)
      checkpoint("diagnostic: " & moved.diagnostic)
      check not moved.ok
      check "must not be followed by deleting the source" in moved.diagnostic
      # THE POINT: the source survives.
      check dirExists(source / ".git")
      check fileExists(source / "untracked.txt")
      check not dirExists(destination)

  test "t_relocate_sameState_names_the_mismatching_capture":
    ## The verification's own contract. Naming WHICH capture differs is what
    ## makes `relocation_verification_failed` actionable instead of a shrug,
    ## and the report quotes this string verbatim.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let scratch = createTempDir("repro-reloc-samestate-", "")
      defer: removeDir(scratch)
      let probe = RelocationGitProbe(identity: resolveGitTool(tpmPathOnly, getEnv("PATH")))
      let a = scratch / "a"
      let b = scratch / "b"
      seedCheckout(gitBin, a)
      seedCheckout(gitBin, b)

      let capA = captureCheckoutState(probe, a)
      let capB = captureCheckoutState(probe, b)
      check capA.ok and capB.ok
      # Two independently seeded repos have different commit ids, so HEAD is
      # the first thing that differs — and it is named.
      check sameState(capA, capB).startsWith("HEAD")
      check sameState(capA, capA) == ""

      # A difference further down the list is named as itself rather than
      # swallowed by the HEAD compare.
      var capC = capA
      capC.stashes = @[]
      check sameState(capA, capC).startsWith("stash entries")
      var capD = capA
      capD.porcelain = @[]
      check sameState(capA, capD).startsWith("working-tree status")

  test "t_relocate_substance_separates_nothing_from_something":
    ## §3.2 step 3 — `observeRepoForSync` returns the same `exists = false` for
    ## "no directory" and "a directory with no `.git`", because for ITS
    ## purposes both mean clone. Relocation needs them apart: one is nothing,
    ## the other is something the operator put there.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let scratch = createTempDir("repro-reloc-substance-", "")
      defer: removeDir(scratch)
      let probe = RelocationGitProbe(identity: resolveGitTool(tpmPathOnly, getEnv("PATH")))

      check checkoutSubstance(probe, scratch / "absent") == csAbsent

      createDir(scratch / "plain")
      writeFile(scratch / "plain" / "notes.txt", "someone's notes\n")
      check checkoutSubstance(probe, scratch / "plain") == csNotAGitRepo

      createDir(scratch / "empty-dir")
      check checkoutSubstance(probe, scratch / "empty-dir") == csNotAGitRepo
      check directoryIsEmpty(scratch / "empty-dir")
      check not directoryIsEmpty(scratch / "plain")

      # The shape a FAILED CLONE leaves: a git repo with no commits, no
      # branches, no stashes and a clean tree. Skipped, never refused.
      discard git(gitBin, "init --quiet -b main " & q(scratch / "halfclone"))
      check checkoutSubstance(probe, scratch / "halfclone") == csEmptyGitRepo

      seedCheckout(gitBin, scratch / "real")
      check checkoutSubstance(probe, scratch / "real") == csSubstantial

  test "t_relocate_in_progress_operation_is_named":
    ## §4 `candidate_in_progress_operation` at the probe level. Asked by
    ## marker file because no single git command answers "which operation, if
    ## any", and the markers are stable documented git interface.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let scratch = createTempDir("repro-reloc-inprogress-", "")
      defer: removeDir(scratch)
      let probe = RelocationGitProbe(identity: resolveGitTool(tpmPathOnly, getEnv("PATH")))
      let repoPath = scratch / "repo"
      seedCheckout(gitBin, repoPath)
      check inProgressOperation(probe, repoPath) == ""

      # A real conflicting rebase, stopped mid-flight.
      discard git(gitBin, "-C " & q(repoPath) & " checkout --quiet -- .")
      removeFile(repoPath / "untracked.txt")
      writeFile(repoPath / "tracked.txt", "theirs\n")
      discard git(gitBin, "-C " & q(repoPath) & " commit --quiet -am theirs")
      discard git(gitBin, "-C " & q(repoPath) &
        " switch --quiet -c mine HEAD~1")
      writeFile(repoPath / "tracked.txt", "mine\n")
      discard git(gitBin, "-C " & q(repoPath) & " commit --quiet -am mine")
      let rebase = execCmdEx(q(gitBin) & " -C " & q(repoPath) & " rebase main")
      check rebase.exitCode != 0          # the premise: it really stopped
      check inProgressOperation(probe, repoPath) == "rebase"
      discard execCmdEx(q(gitBin) & " -C " & q(repoPath) & " rebase --abort")
      check inProgressOperation(probe, repoPath) == ""

  test "t_relocate_blob_sample_is_bounded_and_spread":
    ## §3.3(b) — the sample is BOUNDED because each probe is its own
    ## `cat-file -e` process, and SPREAD across the listing rather than taken
    ## from the front, so a rewrite that stripped one subtree of artifacts
    ## cannot empty the whole sample.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; this case uses real Git repositories")
    else:
      let scratch = createTempDir("repro-reloc-sample-", "")
      defer: removeDir(scratch)
      let probe = RelocationGitProbe(identity: resolveGitTool(tpmPathOnly, getEnv("PATH")))
      let repoPath = scratch / "many"
      discard git(gitBin, "init --quiet -b main " & q(repoPath))
      discard git(gitBin, "-C " & q(repoPath) &
        " config user.email t@example.invalid")
      discard git(gitBin, "-C " & q(repoPath) & " config user.name t")
      # Two subtrees, so "spread" is observable: `ls-tree -r` lists `a/`
      # entirely before `z/`, and a front-loaded sample would never touch `z`.
      createDir(repoPath / "a")
      createDir(repoPath / "z")
      for i in 0 ..< 60:
        writeFile(repoPath / "a" / ("f" & $i & ".txt"), "a" & $i & "\n")
        writeFile(repoPath / "z" / ("f" & $i & ".txt"), "z" & $i & "\n")
      discard git(gitBin, "-C " & q(repoPath) & " add -A")
      discard git(gitBin, "-C " & q(repoPath) & " commit --quiet -m many")

      let sample = sampleBlobIds(probe, repoPath, "HEAD")
      check sample.len == relocationBlobSampleSize
      check sample.len == sample.deduplicate().len
      for oid in sample:
        check objectPresent(probe, repoPath, oid)
      # Spread: at least one sampled blob comes from the SECOND subtree.
      var fromZ = 0
      for oid in sample:
        let content = execCmdEx(q(gitBin) & " -C " & q(repoPath) &
          " cat-file -p " & q(oid)).output
        if content.startsWith("z"):
          inc fromZ
      check fromZ > 0
      # And an absent object is absent — the probe is not answering yes to
      # everything.
      check not objectPresent(probe, repoPath,
        "0123456789012345678901234567890123456789")
