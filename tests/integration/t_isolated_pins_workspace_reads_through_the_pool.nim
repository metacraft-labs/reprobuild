## The push gate's isolated pins workspace reads what its source leaf's
## partial pool only promises, and refuses a checkout that is missing files.
##
## Spec: ``reprobuild-specs/spec/Shared-Clone-Pool-Integrity.md`` §3.4 ("A
## repository one level removed"); issue
## ``issues/2026-11-09-isolated-pins-workspace-clone-of-a-partial-pool-leaf-checks-out-with-blobs-missing.md``.
##
## Design. Real ``git`` against real repositories, built as
## ``t_spi_leaf_refetches_through_pool`` builds them: an upstream, a pool made
## by ``refreshSharedBare``, a leaf cloned with ``git clone --reference`` and
## wired with ``wireAlternates`` (the §3.4 chain). The pool is then made
## blobless and marked promisor, so neither leaf nor pool holds a single blob
## and every file the workspace checks out must come through the chain. The
## leaf is the user's checkout of a one-repo workspace, and the production
## ``prepareIsolatedPinsWorkspace`` clones it into a temporary workspace at an
## older commit, exactly as ``repro push`` does for a member whose lock pins
## siblings away from their checkouts.
##
## Cases:
##
##   - ``isolated_checkout_reads_blobs_the_pool_only_promises`` — every file
##     of the commit is in the temporary checkout with its content, and the
##     pool has the blobs afterwards (they came through it). Before the fix
##     the clone had no promisor remote: git printed ``unable to read sha1
##     file`` for each file, exited 0, and the workspace was reported ready
##     with the files deleted.
##   - ``unreadable_blob_fails_the_preparation`` — upstream is gone, so the
##     chain cannot serve the blobs: git's checkout fails on the lazy fetch
##     and the preparation fails with it. Before the fix git exited 0 here
##     too and the workspace was reported ready.
##   - ``checkout_missing_files_without_a_chain_fails_the_preparation`` — the
##     pool no longer looks partial, so no chain is installed and git's
##     checkout exits 0 with every file missing; the work-tree check fails
##     the preparation and names each missing file.
##   - ``crlf_under_a_text_attribute_is_not_a_missing_file`` — a file committed
##     with CRLF before a ``text`` attribute covered it reads as modified to
##     ``git status`` in a fresh checkout, but it is present: the preparation
##     succeeds. A content comparison would refuse a commit the user's own
##     checkout shows clean.
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
import shared_clones
import repro_cli_support

when declared(serveSharedPoolUploadPack):
  if paramCount() == 3 and paramStr(1) == "internal" and
      paramStr(2) == "shared-pool-upload-pack":
    quit serveSharedPoolUploadPack(findExe("git"), paramStr(3))

let originalReproOverride = getEnv("REPROBUILD_REPRO")

proc q(value: string): string = quoteShell(value)

proc gitIn(cwd: string; args: varargs[string]): tuple[code: int;
                                                      output: string] =
  # Fixture commands never fetch lazily: a probe that healed the fixture would
  # hide the defect.
  var cmd = "GIT_NO_LAZY_FETCH=1 git -C " & q(cwd)
  for a in args:
    cmd.add(" " & q(a))
  let res = execCmdEx(cmd)
  (code: res.exitCode, output: res.output.strip())

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
"""

const Files = ["m1", "m2", "s1", "s2", "s3"]

type Fixture = object
  root, up, pool, ws, leaf, pin: string
  identity: GitToolIdentity

proc setUp(root: string): Fixture =
  result.root = root
  let transport = root / ("pool transport" & ExeExt)
  copyFile(getAppFilename(), transport)
  setFilePermissions(transport, getFilePermissions(getAppFilename()))
  putEnv("REPROBUILD_REPRO", transport)
  writeFile(root / "gitconfig", GlobalConfig)
  putEnv("GIT_CONFIG_GLOBAL", root / "gitconfig")
  putEnv("GIT_CONFIG_NOSYSTEM", "1")
  result.identity = resolveGitTool(tpmPathOnly, getEnv("PATH"))
  let gitBin = result.identity.binaryPath
  result.up = root / "up"
  createDir(result.up)
  discard must(result.up, "init", "-q")
  for name in Files[0 .. 1]:
    commitFile(result.up, name, name & " body\n")
  discard must(result.up, "checkout", "-q", "-b", "side")
  for name in Files[2 .. 4]:
    commitFile(result.up, name, name & " body\n")
  result.pin = must(result.up, "rev-parse", "HEAD")
  discard must(result.up, "checkout", "-q", "main")
  let url = "file://" & result.up
  let created = refreshSharedBare(gitBin, root / "cache", url)
  doAssert created.ok, created.diagnostic
  result.pool = created.sharedBarePath
  result.ws = root / "ws"
  result.leaf = result.ws / "up"
  createDir(result.ws)
  discard must(root, "clone", "-q", "--reference", result.pool, url,
    result.leaf)
  let wired = wireAlternates(result.leaf, result.pool, gitBin)
  doAssert wired.ok and wired.diagnostic.len == 0, wired.diagnostic
  makePoolBlobless(result.pool)
  # Premises: the leaf holds no objects of its own, the pool no blob of the
  # pinned commit, and both have the commit itself.
  doAssert must(result.leaf, "count-objects", "-v").contains("in-pack: 0")
  doAssert has(result.leaf, result.pin) and has(result.pool, result.pin)
  for name in Files:
    let blob = must(result.up, "rev-parse", result.pin & ":" & name)
    doAssert not has(result.pool, blob) and not has(result.leaf, blob)

proc tearDown() =
  if originalReproOverride.len > 0:
    putEnv("REPROBUILD_REPRO", originalReproOverride)
  else:
    delEnv("REPROBUILD_REPRO")
  delEnv("GIT_CONFIG_GLOBAL")
  delEnv("GIT_CONFIG_NOSYSTEM")

proc prepare(f: Fixture): tuple[ok: bool; ws: IsolatedPinsWorkspace;
                                diagnostic: string] =
  prepareIsolatedPinsWorkspace(f.identity, f.ws, "up", f.leaf, f.pin, @[])

suite "the isolated pins workspace reads through its source leaf's pool":
  test "isolated_checkout_reads_blobs_the_pool_only_promises":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-iso-pins-pool-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      let prepared = f.prepare()
      defer: discard removeIsolatedPinsWorkspace(prepared.ws)
      checkpoint(prepared.diagnostic)
      check prepared.ok
      let clone = prepared.ws.root / "up"
      check gitIn(clone, "rev-parse", "HEAD").output == f.pin
      for name in Files:
        check fileExists(clone / name)
        if fileExists(clone / name):
          check readFile(clone / name) == name & " body\n"
      check gitIn(clone, "status", "--porcelain").output == ""
      # The blobs came through the pool, which keeps them for every leaf.
      for name in Files:
        check has(f.pool, must(f.up, "rev-parse", f.pin & ":" & name))

  test "unreadable_blob_fails_the_preparation":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-iso-pins-pool-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      # Nothing can serve the blobs any more: the pool refills from upstream.
      let blob = must(f.up, "rev-parse", f.pin & ":s3")
      removeDir(f.up)
      let prepared = f.prepare()
      defer: discard removeIsolatedPinsWorkspace(prepared.ws)
      check not prepared.ok
      # Through the chain git's own checkout fails on the lazy fetch.
      check ("checkout --quiet --detach " & f.pin) in prepared.diagnostic
      check "could not fetch" in prepared.diagnostic
      check not has(f.pool, blob)

  test "checkout_missing_files_without_a_chain_fails_the_preparation":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-iso-pins-pool-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      # The pool no longer shows itself partial (a foreign or damaged cache),
      # so the clone gets no chain, and git's checkout then reports each
      # unreadable blob on stderr and exits 0: the issue's exact symptom.
      for path in walkFiles(f.pool / "objects/pack/*.promisor"):
        removeFile(path)
      discard gitIn(f.pool, "config", "--unset", "extensions.partialClone")
      discard gitIn(f.pool, "config", "--unset-all", "remote.origin.promisor")
      doAssert not repoIsPartialClone(f.identity.binaryPath, f.pool)
      let prepared = f.prepare()
      defer: discard removeIsolatedPinsWorkspace(prepared.ws)
      check not prepared.ok
      check ("the checkout of " & f.pin) in prepared.diagnostic
      check "is incomplete" in prepared.diagnostic
      for name in Files:
        check ("\n  " & name & "\n") in prepared.diagnostic

  test "crlf_under_a_text_attribute_is_not_a_missing_file":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-iso-pins-pool-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root)
      # A commit on the leaf's main whose file does not round-trip through
      # checkout conversion. Committing in the leaf reads through its chain
      # (lazy fetching on); the case is about the content check, not the pool.
      proc commitLazily(args: varargs[string]) =
        var cmd = "git -C " & q(f.leaf)
        for a in args:
          cmd.add(" " & q(a))
        let res = execCmdEx(cmd)
        doAssert res.exitCode == 0, cmd & ": " & res.output
      writeFile(f.leaf / "crlf.txt", "a\r\nb\r\n")
      commitLazily("add", "crlf.txt")
      commitLazily("commit", "-q", "-m", "crlf")
      writeFile(f.leaf / ".gitattributes", "*.txt text\n")
      commitLazily("add", ".gitattributes")
      commitLazily("commit", "-q", "-m", "attributes")
      let pin = must(f.leaf, "rev-parse", "HEAD")
      let prepared = prepareIsolatedPinsWorkspace(f.identity, f.ws, "up",
        f.leaf, pin, @[])
      defer: discard removeIsolatedPinsWorkspace(prepared.ws)
      checkpoint(prepared.diagnostic)
      let clone = prepared.ws.root / "up"
      # Premise: a content comparison sees the file as modified.
      check gitIn(clone, "status", "--porcelain").output == "M crlf.txt"
      check prepared.ok
      check fileExists(clone / "crlf.txt")
