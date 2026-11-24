## A submodule that borrows from a blobless shared pool, directly or through
## a leaf, can read what the pool only promises, and the files git's failed
## checkout left out come back.
##
## Spec: ``reprobuild-specs/spec/Shared-Clone-Pool-Integrity.md`` §3.4 ("A
## repository one level removed", "Submodules") and §4.1 (lost work-tree
## files); issue
## ``issues/2026-11-24-submodules-borrowing-from-the-blobless-clones-cache-through-alternates-lose-files.md``.
##
## Design. Real ``git`` against real repositories. A submodule upstream with
## two commits (``c1`` on ``main``, ``c2`` on ``next``), a pool of it made by
## the production ``refreshSharedBare`` and then made blobless and promisor,
## so the pool holds every commit and tree and no blob. A superproject
## upstream whose ``main`` pins ``c1`` and whose ``next`` pins ``c2``. The
## user's checkout of the superproject is a plain clone (not a leaf: in the
## issue the superproject need not borrow at all), and its submodule is
## initialized with ``git submodule update --init --reference`` naming either
## the pool itself or a leaf of it, which is how a submodule comes to borrow
## from a pool. git then reads the submodule's commit and trees through the
## alternates, cannot read a single blob, and leaves every file out: the
## issue's symptom, asserted as each case's premise.
##
## Cases:
##
##   - ``submodule_borrowing_the_pool_directly_gets_its_files_back`` — the
##     report pass names the lost files and changes no file; the repair pass
##     gives the submodule the refetch chain, restores every file with its
##     content, and ``git fsck --connectivity-only`` is clean. A file the user
##     deletes afterwards, whose blob is now present, is never restored.
##   - ``submodule_borrowing_through_a_leaf_gets_its_files_back`` — the same
##     through a sibling leaf of the pool (nested alternates), which is not
##     registered with the pool.
##   - ``report_pass_keeps_left_out_files_restorable_after_a_lazy_read`` —
##     a report-only pass installs the chain; a later lazy read fetches the
##     left-out files' blobs, so their absence no longer meets the
##     blob-absence criterion. The next pass still names them (from the
##     record the first pass wrote under the submodule's git dir) and the
##     repair writes every one back; a file deleted after that stays deleted.
##   - ``file_git_wrote_back_after_the_report_is_the_users`` — after the
##     report pass, the user writes one left-out file back with ``git
##     checkout -- <path>`` (through the chain) and then deletes it. It is
##     still recorded with the same blob, but git has written it since, so
##     its deletion is the user's: the repair restores the other files and
##     leaves that one deleted (SPI-AREQ-4).
##   - ``submodule_is_found_without_a_work_tree_gitmodules`` — with the
##     superproject's ``.gitmodules`` deleted from its work tree, which ``git
##     submodule update`` still populates submodules from (it reads the
##     index), the report pass still finds the submodule and names its files.
##   - ``leaf_pass_of_the_submodule_first_keeps_the_record`` — the submodule
##     is checked as a leaf of its own (as a participating repository that is
##     also a populated submodule of another is) before the superproject's
##     submodule pass. That leaf pass installs the chain; a lazy read then
##     fetches the blobs; the submodule pass still names every left-out file
##     and the repair writes them back.
##   - ``later_submodule_update_checks_out_every_file`` — after the repair,
##     moving the superproject to ``next`` and running a plain ``git
##     submodule update`` checks out ``c2`` with every file: the blobs come
##     through the chain.
##   - ``fast_forward_submodule_update_reads_through_the_pool`` — the sync
##     fast-forward (``git-merge-ff`` action) moves the superproject to a
##     commit pinning ``c2``; its submodule update checks out every file
##     although no repair pass ran first.
##   - ``isolated_pins_workspace_populates_submodule_over_partial_pool`` — the
##     push gate's isolated pins workspace populates the submodule at ``c2``
##     from the user's submodule, which borrows from the pool; every file is
##     there. Before the fix the populated submodule borrowed through nested
##     alternates with no promisor remote and git failed its checkout.
##
## The pool's transport is this test executable (the harness below serves
## ``internal shared-pool-upload-pack`` with the production code), selected by
## ``REPROBUILD_REPRO`` as the pool's launcher selects any engine; it is the
## real transport, not a stand-in.
##
## No mocks. Hermetic: one ``createTempDir`` root, a private
## ``GIT_CONFIG_GLOBAL``, ``file://`` URLs. Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import git_tool
import git_actions
import repro_build_engine
import shared_clones
import repro_cli_support

when declared(serveSharedPoolUploadPack):
  if paramCount() == 3 and paramStr(1) == "internal" and
      paramStr(2) == "shared-pool-upload-pack":
    quit serveSharedPoolUploadPack(findExe("git"), paramStr(3))

let originalReproOverride = getEnv("REPROBUILD_REPRO")
let originalClonesOverride = getEnv("REPRO_WORKSPACE_CLONES")

proc q(value: string): string = quoteShell(value)

proc run(cwd: string; lazy: bool; args: varargs[string]):
    tuple[code: int; output: string] =
  var cmd = (if lazy: "" else: "GIT_NO_LAZY_FETCH=1 ") & "git -C " & q(cwd) &
    " -c protocol.file.allow=always"
  for a in args:
    cmd.add(" " & q(a))
  let res = execCmdEx(cmd)
  (code: res.exitCode, output: res.output.strip())

proc gitIn(cwd: string; args: varargs[string]): tuple[code: int;
                                                      output: string] =
  # Fixture probes never fetch lazily: a probe that healed the fixture would
  # hide the defect.
  run(cwd, false, args)

proc must(cwd: string; args: varargs[string]): string =
  let res = gitIn(cwd, args)
  doAssert res.code == 0, "fixture git " & args.join(" ") & " in " & cwd &
    " failed: " & res.output
  res.output

proc commitFile(work, name, body: string) =
  writeFile(work / name, body)
  discard must(work, "add", name)
  discard must(work, "commit", "-q", "-m", name)

proc has(repo, id: string): bool =
  gitIn(repo, "cat-file", "-e", id).code == 0

proc makePoolBlobless(pool: string) =
  ## Repack the pool without blobs and mark the pack promisor: the state of a
  ## ``--filter=blob:none`` pool that has served no file yet.
  let objects = must(pool, "rev-list", "--objects", "--all",
    "--filter=blob:none", "--no-object-names")
  let packDir = pool / "objects" / "pack"
  let packed = execCmdEx("GIT_NO_LAZY_FETCH=1 git -C " & q(pool) &
    " pack-objects -q " & q(packDir / "blobless"), input = objects & "\n")
  doAssert packed.exitCode == 0, packed.output
  let keep = "blobless-" & packed.output.strip()
  for kind, path in walkDir(packDir):
    if not path.lastPathPart.startsWith(keep): removeFile(path)
  for kind, path in walkDir(pool / "objects"):
    if kind == pcDir and path.lastPathPart.len == 2: removeDir(path)
  writeFile(packDir / (keep & ".promisor"), "")

const GlobalConfig = """
[user]
  name = SPI Tester
  email = tester@example.invalid
[init]
  defaultBranch = main
[protocol "file"]
  allow = always
"""

const C1Files = ["s1", "s2", "s3"]
const C2Files = ["s1", "s2", "s3", "s4"]

proc body(name, commit: string): string = name & " at " & commit & "\n"

type Fixture = object
  root, subUp, superUp, cache, pool, ws, super: string
  c1, c2, p1, p2: string
  identity: GitToolIdentity

proc gitBin(f: Fixture): string = f.identity.binaryPath

proc setUp(root: string): Fixture =
  result.root = root
  let transport = root / ("pool transport" & ExeExt)
  copyFile(getAppFilename(), transport)
  setFilePermissions(transport, getFilePermissions(getAppFilename()))
  putEnv("REPROBUILD_REPRO", transport)
  writeFile(root / "gitconfig", GlobalConfig)
  putEnv("GIT_CONFIG_GLOBAL", root / "gitconfig")
  putEnv("GIT_CONFIG_NOSYSTEM", "1")
  # The host's shared-clone cache is this test's: the sync fast-forward finds
  # the pools it may configure there.
  putEnv("REPRO_WORKSPACE_CLONES", root / "cache")
  result.identity = resolveGitTool(tpmPathOnly, getEnv("PATH"))
  # The submodule's upstream: c1 on main, c2 (s1 changed, s4 added) on next.
  result.subUp = root / "sub-up"
  createDir(result.subUp)
  discard must(result.subUp, "init", "-q")
  for name in C1Files:
    commitFile(result.subUp, name, body(name, "c1"))
  result.c1 = must(result.subUp, "rev-parse", "HEAD")
  discard must(result.subUp, "checkout", "-q", "-b", "next")
  commitFile(result.subUp, "s1", body("s1", "c2"))
  commitFile(result.subUp, "s4", body("s4", "c2"))
  result.c2 = must(result.subUp, "rev-parse", "HEAD")
  discard must(result.subUp, "checkout", "-q", "main")
  # The superproject's upstream: main pins c1, next pins c2.
  result.superUp = root / "super-up"
  createDir(result.superUp)
  discard must(result.superUp, "init", "-q")
  commitFile(result.superUp, "top", "top\n")
  discard must(result.superUp, "submodule", "add", "-q",
    "file://" & result.subUp, "sub")
  discard must(result.superUp, "commit", "-q", "-m", "sub at c1")
  result.p1 = must(result.superUp, "rev-parse", "HEAD")
  discard must(result.superUp, "checkout", "-q", "-b", "next")
  discard must(result.superUp / "sub", "checkout", "-q", result.c2)
  discard must(result.superUp, "add", "sub")
  discard must(result.superUp, "commit", "-q", "-m", "sub at c2")
  result.p2 = must(result.superUp, "rev-parse", "HEAD")
  discard must(result.superUp, "checkout", "-q", "main")
  discard must(result.superUp, "submodule", "update", "-q")
  # The pool: every commit and tree of the submodule, no blob.
  result.cache = root / "cache"
  let created = refreshSharedBare(result.gitBin, result.cache,
    "file://" & result.subUp)
  doAssert created.ok, created.diagnostic
  result.pool = created.sharedBarePath
  makePoolBlobless(result.pool)
  doAssert repoIsPartialClone(result.gitBin, result.pool)
  doAssert has(result.pool, result.c1) and has(result.pool, result.c2)
  for commit in [result.c1, result.c2]:
    for name in C1Files:
      doAssert not has(result.pool,
        must(result.subUp, "rev-parse", commit & ":" & name))
  # The user's checkout of the superproject: a plain clone.
  result.ws = root / "ws"
  createDir(result.ws)
  result.super = result.ws / "super"
  discard must(root, "clone", "-q", "file://" & result.superUp, result.super)

proc tearDown() =
  if originalReproOverride.len > 0:
    putEnv("REPROBUILD_REPRO", originalReproOverride)
  else:
    delEnv("REPROBUILD_REPRO")
  delEnv("GIT_CONFIG_GLOBAL")
  delEnv("GIT_CONFIG_NOSYSTEM")
  if originalClonesOverride.len > 0:
    putEnv("REPRO_WORKSPACE_CLONES", originalClonesOverride)
  else:
    delEnv("REPRO_WORKSPACE_CLONES")

proc initSubmoduleReferencing(f: Fixture; reference: string) =
  ## ``git submodule update --init --reference <reference>``: how a submodule
  ## comes to borrow. The premise is the issue's symptom: git's checkout of
  ## the submodule cannot read a blob, and every file is left out.
  let res = gitIn(f.super, "submodule", "update", "--init", "--reference",
    reference)
  checkpoint("submodule update: " & res.output)
  doAssert res.code != 0, "premise: the submodule checkout fails"
  let sub = f.super / "sub"
  doAssert fileExists(sub / ".git"), "premise: the submodule exists"
  for name in C1Files:
    doAssert not fileExists(sub / name), "premise: " & name & " is lost"
  doAssert must(sub, "rev-parse", "HEAD") == f.c1

proc checkAllFiles(dir, commit: string; names: openArray[string]) =
  for name in names:
    check fileExists(dir / name)
    if fileExists(dir / name):
      check readFile(dir / name) == body(name, commit)

proc lostFindingCount(reports: seq[LeafCheckReport]): int =
  when declared(lfkWorkTreeFilesLost):
    for r in reports:
      for f in r.findings:
        if f.kind == lfkWorkTreeFilesLost:
          result += f.paths.len

proc repairsSubmoduleFiles(f: Fixture; registered: bool) =
  let sub = f.super / "sub"
  when declared(checkSubmoduleLeaves):
    # Report only: the files are named, none is written.
    let reported = checkSubmoduleLeaves(f.gitBin, f.super, lcmReport, f.cache)
    check reported.len == 1
    check lostFindingCount(reported) == C1Files.len
    var text = ""
    for r in reported:
      for x in r.findings:
        text.add(x.message & "\n")
    checkpoint(text)
    for name in C1Files:
      check ("  " & name & "\n") in text
      check not fileExists(sub / name)
    check "repro health --fix" in text
    # Repair: every file back, with its content, and the repository whole.
    let repaired = checkSubmoduleLeaves(f.gitBin, f.super, lcmRepair, f.cache)
    check repaired.len == 1
    for r in repaired:
      checkpoint(r.diagnostic)
      check r.diagnostic.len == 0
    checkAllFiles(sub, "c1", C1Files)
    check gitIn(sub, "status", "--porcelain").output == ""
    check gitIn(f.super, "status", "--porcelain").output == ""
    let fsck = gitIn(sub, "fsck", "--connectivity-only")
    checkpoint(fsck.output)
    check fsck.code == 0
    check (sub in readBorrowers(f.pool)) == registered
    # A file the user deletes now was written by the checkout: its blob is
    # present, so its absence is the user's, and it stays deleted.
    removeFile(sub / "s2")
    let again = checkSubmoduleLeaves(f.gitBin, f.super, lcmRepair, f.cache)
    check lostFindingCount(again) == 0
    check not fileExists(sub / "s2")
    check gitIn(sub, "status", "--porcelain").output == "D s2"
  else:
    checkpoint("no pass gives a submodule borrowing from a partial pool " &
      "its refetch chain or restores the files git left out")
    fail()

suite "a submodule borrowing from a blobless pool keeps its files":
  test "submodule_borrowing_the_pool_directly_gets_its_files_back":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi-submodule-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      f.initSubmoduleReferencing(f.pool)
      f.repairsSubmoduleFiles(registered = true)

  test "submodule_borrowing_through_a_leaf_gets_its_files_back":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi-submodule-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      # A sibling leaf of the pool, as a workspace checkout of the submodule's
      # repository is.
      let leaf = f.ws / "sub-leaf"
      discard must(f.root, "clone", "-q", "--no-checkout", "--reference",
        f.pool, "file://" & f.subUp, leaf)
      let wired = wireAlternates(leaf, f.pool, f.gitBin)
      doAssert wired.ok and wired.diagnostic.len == 0, wired.diagnostic
      f.initSubmoduleReferencing(leaf)
      f.repairsSubmoduleFiles(registered = false)

  test "report_pass_keeps_left_out_files_restorable_after_a_lazy_read":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi-submodule-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      f.initSubmoduleReferencing(f.pool)
      let sub = f.super / "sub"
      when declared(checkSubmoduleLeaves):
        # A report-only pass (``repro health``, ``repro workspace status``,
        # the sync fast-forward) names the files and installs the chain.
        let reported = checkSubmoduleLeaves(f.gitBin, f.super, lcmReport,
          f.cache)
        check lostFindingCount(reported) == C1Files.len
        # Any later git command that reads the blobs, as ``git diff`` or an
        # editor integration does, now fetches them through that chain.
        for name in C1Files:
          let read = run(sub, true, "cat-file", "-p", ":" & name)
          checkpoint(read.output)
          check read.code == 0
          check has(sub, must(sub, "rev-parse", ":" & name))
        for name in C1Files:
          check not fileExists(sub / name)
        # The evidence survives the fetch: the next pass still names every
        # file git left out, and the repair writes each one back.
        let again = checkSubmoduleLeaves(f.gitBin, f.super, lcmReport,
          f.cache)
        check lostFindingCount(again) == C1Files.len
        let repaired = checkSubmoduleLeaves(f.gitBin, f.super, lcmRepair,
          f.cache)
        for r in repaired:
          checkpoint(r.diagnostic)
          check r.diagnostic.len == 0
        checkAllFiles(sub, "c1", C1Files)
        check gitIn(sub, "status", "--porcelain").output == ""
        # Once written back the files are the user's: one deleted now stays
        # deleted.
        removeFile(sub / "s2")
        let after = checkSubmoduleLeaves(f.gitBin, f.super, lcmRepair, f.cache)
        check lostFindingCount(after) == 0
        check not fileExists(sub / "s2")
      else:
        fail()

  test "file_git_wrote_back_after_the_report_is_the_users":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi-submodule-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      f.initSubmoduleReferencing(f.pool)
      let sub = f.super / "sub"
      when declared(checkSubmoduleLeaves):
        let reported = checkSubmoduleLeaves(f.gitBin, f.super, lcmReport,
          f.cache)
        check lostFindingCount(reported) == C1Files.len
        # The user writes s2 back with git, through the chain the report pass
        # installed, and then deletes it: a deletion of the user's own.
        let restored = run(sub, true, "checkout", "--", "s2")
        checkpoint(restored.output)
        check restored.code == 0
        check readFile(sub / "s2") == body("s2", "c1")
        removeFile(sub / "s2")
        let again = checkSubmoduleLeaves(f.gitBin, f.super, lcmReport,
          f.cache)
        check lostFindingCount(again) == C1Files.len - 1
        let repaired = checkSubmoduleLeaves(f.gitBin, f.super, lcmRepair,
          f.cache)
        for r in repaired:
          checkpoint(r.diagnostic)
          check r.diagnostic.len == 0
        checkAllFiles(sub, "c1", ["s1", "s3"])
        check not fileExists(sub / "s2")
        check gitIn(sub, "status", "--porcelain").output == "D s2"
      else:
        fail()

  test "submodule_is_found_without_a_work_tree_gitmodules":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi-submodule-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      f.initSubmoduleReferencing(f.pool)
      let sub = f.super / "sub"
      removeFile(f.super / ".gitmodules")
      when declared(checkSubmoduleLeaves):
        check submoduleCheckouts(f.gitBin, f.super) == @[sub]
        let reported = checkSubmoduleLeaves(f.gitBin, f.super, lcmReport,
          f.cache)
        check reported.len == 1
        check lostFindingCount(reported) == C1Files.len
        let repaired = checkSubmoduleLeaves(f.gitBin, f.super, lcmRepair,
          f.cache)
        for r in repaired:
          checkpoint(r.diagnostic)
          check r.diagnostic.len == 0
        checkAllFiles(sub, "c1", C1Files)
      else:
        fail()

  test "leaf_pass_of_the_submodule_first_keeps_the_record":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi-submodule-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      f.initSubmoduleReferencing(f.pool)
      let sub = f.super / "sub"
      when declared(checkSubmoduleLeaves):
        # The submodule's own leaf pass, report-only, installs the chain.
        let leafReport = checkLeaf(f.gitBin, sub, lcmReport, f.cache)
        checkpoint(leafReport.diagnostic)
        check leafReport.pool == f.pool
        check leafReport.configured
        for name in C1Files:
          let read = run(sub, true, "cat-file", "-p", ":" & name)
          checkpoint(read.output)
          check read.code == 0
          check has(sub, must(sub, "rev-parse", ":" & name))
        let reported = checkSubmoduleLeaves(f.gitBin, f.super, lcmReport,
          f.cache)
        check lostFindingCount(reported) == C1Files.len
        let repaired = checkSubmoduleLeaves(f.gitBin, f.super, lcmRepair,
          f.cache)
        for r in repaired:
          checkpoint(r.diagnostic)
          check r.diagnostic.len == 0
        checkAllFiles(sub, "c1", C1Files)
        check gitIn(sub, "status", "--porcelain").output == ""
      else:
        fail()

  test "later_submodule_update_checks_out_every_file":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi-submodule-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      f.initSubmoduleReferencing(f.pool)
      when declared(checkSubmoduleLeaves):
        discard checkSubmoduleLeaves(f.gitBin, f.super, lcmRepair, f.cache)
      discard must(f.super, "checkout", "-q", "next")
      # Lazy fetching on: this is the user's own update, which must read what
      # the pool only promises.
      let res = run(f.super, true, "submodule", "update")
      checkpoint(res.output)
      check res.code == 0
      check must(f.super / "sub", "rev-parse", "HEAD") == f.c2
      checkAllFiles(f.super / "sub", "c2", ["s1", "s4"])
      checkAllFiles(f.super / "sub", "c1", ["s2", "s3"])

  test "fast_forward_submodule_update_reads_through_the_pool":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi-submodule-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      # The submodule borrows from the pool and is whole, the way a repaired
      # one, or one whose blobs were read before, is. Only c1's blobs are
      # present: c2's must come through the pool.
      f.initSubmoduleReferencing(f.pool)
      let sub = f.super / "sub"
      discard execCmdEx("git -C " & q(sub) & " -c remote.x.url=" &
        q("file://" & f.subUp) & " -c remote.x.promisor=true" &
        " -c remote.x.partialclonefilter=blob:none checkout -q -f " & f.c1)
      doAssert gitIn(sub, "status", "--porcelain").output == ""
      doAssert gitIn(sub, "config", "--get", "remote.repro-pool.url").code != 0
      # The superproject's main moves to next's commit upstream; the sync
      # fast-forward brings it and updates the submodule.
      discard must(f.superUp, "update-ref", "refs/heads/main", f.p2)
      discard must(f.super, "fetch", "-q", "origin")
      var ff = gitMergeFfAction("spi-submodule-ff", f.identity,
        remoteName = "origin", branchName = "main", repoPath = f.super,
        receiptPath = "merge-ff-receipt")
      let work = f.root / "ff-work"
      createDir(work)
      ff.cwd = work
      var config = defaultBuildEngineConfig(f.root / "engine-cache")
      config.suppressTrace = true
      let built = runBuild(graph([ff]), config)
      check built.results.len == 1
      if built.results.len == 1:
        checkpoint(built.results[0].reason & ": " & built.results[0].stderr)
        check built.results[0].status == asSucceeded
      check must(f.super, "rev-parse", "HEAD") == f.p2
      check must(sub, "rev-parse", "HEAD") == f.c2
      checkAllFiles(sub, "c2", ["s1", "s4"])
      checkAllFiles(sub, "c1", ["s2", "s3"])

  test "isolated_pins_workspace_populates_submodule_over_partial_pool":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi-submodule-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      # The user's submodule borrows from the pool and is whole at c1 (its
      # blobs were read through a promisor once); c2's blobs are nowhere
      # local, only promised by the pool.
      f.initSubmoduleReferencing(f.pool)
      let sub = f.super / "sub"
      discard execCmdEx("git -C " & q(sub) & " -c remote.x.url=" &
        q("file://" & f.subUp) & " -c remote.x.promisor=true" &
        " -c remote.x.partialclonefilter=blob:none checkout -q -f " & f.c1)
      doAssert gitIn(sub, "status", "--porcelain").output == ""
      discard must(f.super, "fetch", "-q", "origin")
      doAssert has(f.super, f.p2)
      let prepared = prepareIsolatedPinsWorkspace(f.identity, f.ws, "super",
        f.super, f.p2, @[])
      defer: discard removeIsolatedPinsWorkspace(prepared.ws)
      checkpoint(prepared.diagnostic)
      check prepared.ok
      let clone = prepared.ws.root / "super"
      check gitIn(clone / "sub", "rev-parse", "HEAD").output == f.c2
      checkAllFiles(clone / "sub", "c2", ["s1", "s4"])
      checkAllFiles(clone / "sub", "c1", ["s2", "s3"])
      check gitIn(clone, "status", "--porcelain").output == ""
