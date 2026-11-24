## The files git's checkout left out of a submodule that borrows from a
## blobless shared pool, as ``repro health``, ``repro health --fix``, ``repro
## workspace status`` and ``repro workspace sync`` report and restore them.
##
## Spec: ``reprobuild-specs/spec/Shared-Clone-Pool-Integrity.md`` §3.4
## ("Submodules"), §4.1 ("Files a checkout left out", "The record of left-out
## files") and §4.2; issue
## ``issues/2026-11-24-report-only-pass-installs-the-refetch-chain-and-erases-the-evidence-of-left-out-files.md``.
##
## Design. Real ``git`` and the ``repro`` built from this checkout, against a
## workspace made by ``repro workspace init`` whose one participating repo,
## ``super``, has a submodule ``sub``. ``sub``'s upstream has a pool in the
## workspace's shared-clone cache (``REPRO_WORKSPACE_CLONES``), made by the
## production ``refreshSharedBare`` and then made blobless and promisor, so it
## holds every commit and tree and no blob. The user initializes the
## submodule with ``git submodule update --init --reference <pool>``, which is
## how a submodule comes to borrow from a pool: git reads its commit and trees
## through the alternates, cannot read a single blob, and leaves every file
## out. That symptom is each case's premise. Every case then reads the left-out
## files' blobs once through the refetch chain the first report-only pass
## installed (``git cat-file -p :<file>`` with lazy fetching on, as ``git
## diff`` or an editor integration would), which makes the blobs present and
## leaves only the record under the submodule's git dir as evidence that git,
## not the user, left the files out.
##
## Cases:
##
##   - ``health_counts_left_out_files_and_fix_restores_them_after_a_lazy_read``
##     — ``repro health`` names ``super/sub`` with its lost-file count, writes
##     the record and leaves the files absent; after the lazy read the next
##     ``repro health`` still names it with the same count; ``repro health
##     --fix`` announces and restores every file with its content, ``git
##     status --porcelain`` is clean in the submodule and the superproject,
##     and ``health`` no longer names it.
##   - ``workspace_status_reports_left_out_files_and_fix_restores_them`` —
##     ``repro workspace status --json`` lists the files as an
##     ``lfkWorkTreeFilesLost`` finding of the submodule and changes no file;
##     after the lazy read it still lists every one; ``status --fix`` restores
##     them.
##   - ``sync_repair_pass_restores_left_out_files_after_a_lazy_read`` — after
##     a report-only ``repro health`` and the lazy read, ``repro workspace
##     sync`` (whose detector pass repairs) writes every file back.
##   - ``nested_submodule_left_out_files_are_reported_and_restored`` — a
##     submodule ``inner`` of ``sub``, which borrows from its own blobless
##     pool while ``sub`` borrows from nothing, loses its files: ``health``
##     names ``super/sub/inner`` once with its count, again after the lazy
##     read, and ``health --fix`` restores them. In-process, a shared ``seen``
##     set over ``super`` and then ``super/sub`` (a submodule that is also
##     passed as a checkout of its own, as a participating repo would be)
##     inspects ``inner`` once, while a call on ``super/sub`` alone still
##     reaches it.
##
## Transport. A lazy read in the submodule runs its ``repro-pool`` remote's
## upload-pack, the pool's launcher, which execs ``<selected repro> internal
## shared-pool-upload-pack``. The cases select the built ``repro`` through
## ``REPROBUILD_REPRO`` and, on POSIX, put a decoy ``repro`` that refuses
## every request first on PATH, so a read that fell back to an ambient build
## fails instead of passing on another build's transport.
##
## No mocks: the decoy is never meant to run. Hermetic: one ``createTempDir``
## root, a private ``GIT_CONFIG_GLOBAL``, ``file://`` URLs. Skip rule: ``git``
## missing on PATH. Every case needs the built ``repro``, and a missing one is
## reported, not skipped.

import std/[json, os, osproc, sets, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_test_support
import shared_clones

proc q(value: string): string = quoteShell(value)

proc run(cwd: string; lazy: bool; args: varargs[string]):
    tuple[code: int; output: string] =
  var cmd = (if lazy: "env -u GIT_NO_LAZY_FETCH " else: "GIT_NO_LAZY_FETCH=1 ") &
    "git -C " & q(cwd)
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
  if res.code != 0:
    checkpoint("git " & args.join(" ") & " in " & cwd & " failed: " &
      res.output)
  doAssert res.code == 0, "fixture git command failed: " & args.join(" ")
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

const SubFiles = ["s1", "s2", "s3"]
const InnerFiles = ["i1", "i2"]

proc body(name: string): string = name & " content\n"

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc builtRepro(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

let originalReproOverride = getEnv("REPROBUILD_REPRO")
let originalPath = getEnv("PATH")

proc selectBuiltTransport(root: string) =
  ## Make every lazy read in this process, and in the git and repro processes
  ## it starts, run the transport built from this checkout; a decoy ``repro``
  ## first on PATH turns a fallback to the ambient PATH into a failed read.
  putEnv("REPROBUILD_REPRO", builtRepro())
  when not defined(windows):
    let decoyDir = root / "decoy-bin"
    createDir(decoyDir)
    let decoy = decoyDir / "repro"
    writeFile(decoy, "#!/bin/sh\n" &
      "echo 'decoy repro on PATH: the transport was not selected' >&2\n" &
      "exit 97\n")
    setFilePermissions(decoy, {fpUserRead, fpUserWrite, fpUserExec})
    putEnv("PATH", decoyDir & $PathSep & originalPath)

proc tearDown() =
  if originalReproOverride.len > 0:
    putEnv("REPROBUILD_REPRO", originalReproOverride)
  else:
    delEnv("REPROBUILD_REPRO")
  putEnv("PATH", originalPath)
  delEnv("GIT_CONFIG_GLOBAL")
  delEnv("GIT_CONFIG_NOSYSTEM")

const projectToml = """
schema = "reprobuild.workspace.project.v1"

[project]
name = "spiproj"

[[remote]]
name = "super-origin"
fetch = "$1"

includes = [
  "repos/super.toml",
]
"""

const superFragmentToml = """
schema = "reprobuild.workspace.repo.v2"

[repo]
name = "super"
path = "super"
remote = "super-origin"
mainline = "main"
"""

type Fixture = object
  root, cache, ws, super, sub, reproBin, gitBin: string
  subUp, innerUp: string
  env: seq[tuple[name, value: string]]

proc makeUpstream(dir: string; files: openArray[string]) =
  createDir(dir)
  discard must(dir, "init", "-q")
  for name in files:
    commitFile(dir, name, body(name))

proc bloblessPool(f: Fixture; upstream: string;
                  files: openArray[string]): string =
  ## A pool of ``upstream`` in the workspace's cache holding no blob.
  let created = refreshSharedBare(f.gitBin, f.cache, "file://" & upstream)
  doAssert created.ok, created.diagnostic
  result = created.sharedBarePath
  makePoolBlobless(result)
  doAssert repoIsPartialClone(f.gitBin, result)
  for name in files:
    doAssert not has(result, must(upstream, "rev-parse", "HEAD:" & name))

proc setUp(root: string; nested: bool): Fixture =
  ## ``sub``'s upstream (with a submodule ``inner`` when ``nested``), a
  ## superproject pinning it, pushed to a bare origin, and a workspace whose
  ## one repo is that superproject, made by ``repro workspace init``.
  result.root = root
  result.reproBin = builtRepro()
  result.gitBin = findExe("git")
  selectBuiltTransport(root)
  writeFile(root / "gitconfig", GlobalConfig)
  putEnv("GIT_CONFIG_GLOBAL", root / "gitconfig")
  putEnv("GIT_CONFIG_NOSYSTEM", "1")
  result.cache = root / "cache"
  result.env = @[("REPRO_WORKSPACE_CLONES", result.cache)]
  result.subUp = root / "sub-up"
  makeUpstream(result.subUp, SubFiles)
  if nested:
    result.innerUp = root / "inner-up"
    makeUpstream(result.innerUp, InnerFiles)
    discard must(result.subUp, "submodule", "add", "-q",
      "file://" & result.innerUp, "inner")
    discard must(result.subUp, "commit", "-q", "-m", "inner")
  let origin = root / "super-origin.git"
  discard must(root, "init", "-q", "--bare", origin)
  let seed = root / "super-seed"
  makeUpstream(seed, ["top"])
  discard must(seed, "submodule", "add", "-q", "file://" & result.subUp, "sub")
  discard must(seed, "commit", "-q", "-m", "sub")
  discard must(seed, "remote", "add", "origin", origin)
  discard must(seed, "push", "-q", "origin", "main")
  result.ws = root / "ws"
  createDir(result.ws / "projects")
  createDir(result.ws / "repos")
  writeFile(result.ws / "projects" / "spiproj.toml",
    projectToml % [fileUrl(origin)])
  writeFile(result.ws / "repos" / "super.toml", superFragmentToml)
  let init = runShell(shellCommand(@[result.reproBin, "workspace", "init",
    "spiproj", "--workspace-root=" & result.ws], result.env))
  checkpoint("init: " & init.output)
  doAssert init.code == 0, "premise: workspace init succeeds"
  result.super = result.ws / "super"
  result.sub = result.super / "sub"
  doAssert not fileExists(result.sub / ".git"),
    "premise: init leaves the submodule unpopulated"

proc populateReferencing(checkout, name, pool: string;
                         files: openArray[string]) =
  ## ``git submodule update --init --reference <pool>`` in ``checkout``: the
  ## premise is the issue's symptom, every file of submodule ``name`` left
  ## out because git could not read a blob.
  let res = gitIn(checkout, "submodule", "update", "--init", "--reference",
    pool, "--", name)
  checkpoint("submodule update: " & res.output)
  doAssert res.code != 0, "premise: the submodule checkout fails"
  let sub = checkout / name
  doAssert fileExists(sub / ".git"), "premise: the submodule exists"
  for file in files:
    doAssert not fileExists(sub / file), "premise: " & file & " is left out"

proc repro(f: Fixture; args: varargs[string]): tuple[code: int;
                                                     output: string] =
  var argv = @[f.reproBin]
  for a in args: argv.add(a)
  argv.add("--workspace-root=" & f.ws)
  runShell(shellCommand(argv, f.env))

proc healthRow(output: string): string =
  for line in output.splitLines():
    if line.startsWith("shared-clone-leaves "):
      return line

proc lazyRead(checkout: string; files: openArray[string]) =
  ## Read each file's blob with lazy fetching on, as ``git diff`` or an
  ## editor integration would: through the chain a report pass installed.
  ## Afterwards the blobs are present and the files are still absent.
  for name in files:
    let read = run(checkout, true, "cat-file", "-p", ":" & name)
    checkpoint("lazy read of " & name & ": " & read.output)
    check read.code == 0
    check has(checkout, must(checkout, "rev-parse", ":" & name))
    check not fileExists(checkout / name)

proc checkFilesBack(checkout: string; files: openArray[string]) =
  for name in files:
    check fileExists(checkout / name)
    if fileExists(checkout / name):
      check readFile(checkout / name) == body(name)
  check gitIn(checkout, "status", "--porcelain").output == ""

proc ledger(f: Fixture; modulePath: string): string =
  ## ``<git dir>/repro/left-out-files`` of a submodule absorbed under the
  ## superproject's ``.git/modules`` (§4.1, "The record of left-out files").
  f.super / ".git" / "modules" / modulePath / "repro" / "left-out-files"

proc lostFindings(statusOutput, leaf: string): HashSet[string] =
  ## The paths ``repro workspace status --json`` lists as left out in
  ## ``leaf``.
  result = initHashSet[string]()
  try:
    let js = parseJson(statusOutput[statusOutput.find('{') .. ^1])
    for x in js["sharedCloneFindings"]:
      if x["kind"].getStr() == "lfkWorkTreeFilesLost" and
          x["leaf"].getStr() == leaf:
        for p in x["paths"]:
          result.incl(p.getStr())
  except CatchableError as e:
    checkpoint("status JSON: " & e.msg)

proc toSet(files: openArray[string]): HashSet[string] =
  result = initHashSet[string]()
  for name in files: result.incl(name)

suite "files a submodule's checkout left out, through the repro CLI":
  test "health_counts_left_out_files_and_fix_restores_them_after_a_lazy_read":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi-submodule-cli-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root, nested = false)
      let pool = f.bloblessPool(f.subUp, SubFiles)
      populateReferencing(f.super, "sub", pool, SubFiles)
      let expected = "super/sub (" & $SubFiles.len & ")"
      # Report only: named with its count, recorded, nothing written.
      let first = f.repro("health", "spiproj")
      checkpoint("health: " & first.output)
      check " warn " in healthRow(first.output)
      check expected in healthRow(first.output)
      check "health --fix" in first.output
      check fileExists(f.ledger("sub"))
      for name in SubFiles:
        check not fileExists(f.sub / name)
      lazyRead(f.sub, SubFiles)
      # The blobs are present now; the record still names the files.
      let second = f.repro("health", "spiproj")
      checkpoint("health after the lazy read: " & second.output)
      check expected in healthRow(second.output)
      for name in SubFiles:
        check not fileExists(f.sub / name)
      # Repair: announced, every file back, nothing left to commit.
      let fixed = f.repro("health", "spiproj", "--fix")
      checkpoint("health --fix: " & fixed.output)
      check ("fix: restored " & $SubFiles.len & " file(s) git had left out " &
        "in " & f.sub) in fixed.output
      checkFilesBack(f.sub, SubFiles)
      check gitIn(f.super, "status", "--porcelain").output == ""
      check not fileExists(f.ledger("sub"))
      let after = f.repro("health", "spiproj")
      checkpoint("health after --fix: " & after.output)
      check "super/sub (" notin healthRow(after.output)

  test "workspace_status_reports_left_out_files_and_fix_restores_them":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi-submodule-cli-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root, nested = false)
      let pool = f.bloblessPool(f.subUp, SubFiles)
      populateReferencing(f.super, "sub", pool, SubFiles)
      let first = f.repro("workspace", "status", "spiproj", "--json")
      checkpoint("status: " & first.output)
      check first.code == 0
      check lostFindings(first.output, f.sub) == toSet(SubFiles)
      for name in SubFiles:
        check not fileExists(f.sub / name)
      lazyRead(f.sub, SubFiles)
      let second = f.repro("workspace", "status", "spiproj", "--json")
      checkpoint("status after the lazy read: " & second.output)
      check lostFindings(second.output, f.sub) == toSet(SubFiles)
      let fixed = f.repro("workspace", "status", "spiproj", "--fix")
      checkpoint("status --fix: " & fixed.output)
      checkFilesBack(f.sub, SubFiles)
      check gitIn(f.super, "status", "--porcelain").output == ""
      let after = f.repro("workspace", "status", "spiproj", "--json")
      checkpoint("status after --fix: " & after.output)
      check lostFindings(after.output, f.sub).len == 0

  test "sync_repair_pass_restores_left_out_files_after_a_lazy_read":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi-submodule-cli-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root, nested = false)
      let pool = f.bloblessPool(f.subUp, SubFiles)
      populateReferencing(f.super, "sub", pool, SubFiles)
      let reported = f.repro("health", "spiproj")
      checkpoint("health: " & reported.output)
      check ("super/sub (" & $SubFiles.len & ")") in healthRow(reported.output)
      lazyRead(f.sub, SubFiles)
      let sync = f.repro("workspace", "sync", "spiproj")
      checkpoint("sync: " & sync.output)
      checkFilesBack(f.sub, SubFiles)
      check gitIn(f.super, "status", "--porcelain").output == ""

  test "nested_submodule_left_out_files_are_reported_and_restored":
    if findExe("git").len == 0:
      skip("needs git on PATH")
    else:
      let root = createTempDir("repro-spi-submodule-cli-", "")
      defer:
        tearDown()
        removeDir(root)
      let f = setUp(root, nested = true)
      let innerPool = f.bloblessPool(f.innerUp, InnerFiles)
      # ``sub`` is populated in full from its upstream and borrows nothing;
      # its own submodule ``inner`` borrows from a blobless pool.
      discard must(f.super, "submodule", "update", "--init", "--", "sub")
      for name in SubFiles:
        doAssert fileExists(f.sub / name)
      populateReferencing(f.sub, "inner", innerPool, InnerFiles)
      let inner = f.sub / "inner"
      let expected = "super/sub/inner (" & $InnerFiles.len & ")"
      let first = f.repro("health", "spiproj")
      checkpoint("health: " & first.output)
      let row = healthRow(first.output)
      check expected in row
      # Named once, and its superproject (which borrows nothing) not at all.
      check row.count("super/sub/inner (") == 1
      check "super/sub (" notin row
      lazyRead(inner, InnerFiles)
      let second = f.repro("health", "spiproj")
      checkpoint("health after the lazy read: " & second.output)
      check expected in healthRow(second.output)
      # A shared ``seen`` set: ``super``'s walk reaches ``inner``; the same
      # set then passed with ``super/sub`` as a checkout of its own (a
      # submodule that is also a participating repo) inspects nothing again.
      var seen = initHashSet[string]()
      let viaSuper = checkSubmoduleLeaves(f.gitBin, f.super, lcmReport,
        f.cache, seen)
      check viaSuper.len == 1 and viaSuper[0].leaf == inner
      check checkSubmoduleLeaves(f.gitBin, f.sub, lcmReport, f.cache,
        seen).len == 0
      # On its own ``super/sub`` still reaches it, with the detection.
      let alone = checkSubmoduleLeaves(f.gitBin, f.sub, lcmReport, f.cache)
      check alone.len == 1
      var lost = 0
      for r in alone:
        for x in r.findings:
          if x.kind == lfkWorkTreeFilesLost: lost += x.paths.len
      check lost == InnerFiles.len
      let fixed = f.repro("health", "spiproj", "--fix")
      checkpoint("health --fix: " & fixed.output)
      check ("fix: restored " & $InnerFiles.len & " file(s) git had left " &
        "out in " & inner) in fixed.output
      checkFilesBack(inner, InnerFiles)
      check gitIn(f.sub, "status", "--porcelain").output == ""
      check gitIn(f.super, "status", "--porcelain").output == ""
