## `fs.ensureSnippet`, `fs.ensureLine` and `fs.managedBlock` write managed
## files through ONE writer: one sentinel format, one block locator, one
## splice, one atomic write, and one graph-time ownership check.
##
## Issue: reprobuild-pm
## `issues/2026-11-12-fs-ensuresnippet-and-fs-ensureline-fork-the-managed-block-writer-with-a-different-format.md`.
## Governing text: reprobuild-pm `spec/CLI/internal/fs-file-utilities.md`
## §2-§4, `spec/Generated-Configuration-Files.md` §"Caching" and
## §"Sentinel uniqueness", `spec/Core-Invariants.md` §"One Implementation
## Per Concern".
##
## The defect: the engine's `ensureSnippet` took caller-invented sentinel
## strings and the only caller (`nimRepropathsConfig`) invented
## `# >>> repro:project:<pkg>:<blockId>:v1 >>>`, so a file already holding the
## block in the managed-block format received a second copy; it rewrote files
## in place with `writeFile` (a crash leaves a truncated tracked file); two
## actions claiming one block, or racing on one file, were not refused when
## the graph was built; and a duplicated or unterminated block was guessed at
## instead of refused.
##
## Every case drives the engine's real entry points on real files in a
## scratch directory: `executeBuiltinAction` (the built-in dispatch the
## scheduler calls) for the writer, and `runBuild` (which validates the graph
## before anything runs, and owns the local action cache) for the ownership
## and freshness cases. NOTHING IS MOCKED: the properties are about bytes,
## inodes and mtimes on disk and about which graphs the engine accepts.

import std/[os, strutils, tempfiles, times, unittest]

import repro_build_engine
import repro_core
import repro_core/managed_block

const
  Pkg = "demo"
  BlockId = "repro-paths-bootstrap"
  Snippet = "when withDir(thisDir(), system.fileExists(\"repro.paths\")):\n" &
    "  include \"repro.paths\""
  SpecOpen = "# >>> repro:project:demo:repro-paths-bootstrap >>>"
  SpecClose = "# <<< repro:project:demo:repro-paths-bootstrap <<<"
  LegacyOpen = "# >>> repro:project:demo:repro-paths-bootstrap:v1 >>>"
  LegacyClose = "# <<< repro:project:demo:repro-paths-bootstrap:v1 <<<"
  PinnedMtime = 1_000_000

proc snippetEntries(pkg, blockId, snippet: string): seq[string] =
  ## The payload the DSL lowering sends for block `(pkg, blockId)`: the
  ## block's key, encoded by the engine's own encoder.
  ensureSnippetEntries(pkg, blockId, snippet)

proc snippetAction(id, output: string; pkg = Pkg; blockId = BlockId;
                   snippet = Snippet; cwd = ""; deps: openArray[string] = [];
                   cacheable = false): BuildAction =
  builtinAction(bakEnsureSnippet, id, cwd = cwd, deps = deps,
    outputs = [output], cacheable = cacheable,
    entries = snippetEntries(pkg, blockId, snippet),
    weakFingerprint = weakFingerprintFromText("t-managed-file." & id),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc lineAction(id, output, line: string; cwd = "";
                deps: openArray[string] = []): BuildAction =
  builtinAction(bakEnsureLine, id, cwd = cwd, deps = deps,
    outputs = [output], cacheable = false, text = line,
    weakFingerprint = weakFingerprintFromText("t-managed-file." & id),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc wantedBlock(eol = "\n"): string =
  (SpecOpen & "\n" & Snippet & "\n" & SpecClose).replace("\n", eol)

proc scratch(): string =
  createTempDir("repro-managed-file-writer-", "")

proc inode(path: string): int64 =
  int64(getFileInfo(path, followSymlink = false).id.file)

proc occurrences(text, needle: string): int = text.count(needle)

proc run(action: BuildAction): ActionResult =
  result = executeBuiltinAction(action)
  checkpoint("status=" & $result.status & " stderr=" & result.stderr)

proc buildConfig(root: string): BuildEngineConfig =
  ## The settings `repro build` itself uses for the local cache (see
  ## `repro_cli_support`'s build engine config): missing outputs re-run the
  ## action, output blobs are not kept in the local CAS.
  result = defaultBuildEngineConfig(root / "cache")
  result.bypassRunQuota = true
  result.maxParallelism = 1'u32
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true

proc refusal(root: string; actions: openArray[BuildAction]): string =
  ## The graph-construction refusal `runBuild` raises for `actions`, or ""
  ## when the graph is accepted (it is then built).
  try:
    discard runBuild(graph(actions), buildConfig(root))
  except BuildEngineError as e:
    return e.msg
  ""

suite "one sentinel format: ensureSnippet speaks the managed-block format":

  test "a spec-format project block is updated in place, not duplicated":
    let dir = scratch()
    defer: removeDir(dir)
    let file = dir / "config.nims"
    let before = "switch(\"a\")\n\n" & SpecOpen & "\ninclude \"old.paths\"\n" &
      SpecClose & "\n\nswitch(\"b\")\n"
    writeFile(file, before)
    check run(snippetAction("snippet", file)).status == asSucceeded
    let after = readFile(file)
    checkpoint(after)
    check after.occurrences("# >>> repro:project:demo:repro-paths-bootstrap") == 1
    check after == "switch(\"a\")\n\n" & wantedBlock() & "\n\nswitch(\"b\")\n"

  test "the written block is in the managed-block sentinel format":
    let dir = scratch()
    defer: removeDir(dir)
    let file = dir / "config.nims"
    writeFile(file, "switch(\"a\")\n")
    check run(snippetAction("snippet", file)).status == asSucceeded
    let after = readFile(file)
    checkpoint(after)
    check (SpecOpen & "\n") in after
    check (SpecClose & "\n") in after
    check after == "switch(\"a\")\n\n" & wantedBlock() & "\n"
    # The locator `fs.managedBlock` uses finds it, holding exactly the
    # snippet.
    let span = locateManagedBlock(after,
      managedBlockKey(ProjectBlockScope, Pkg, BlockId), file)
    check span.found
    check not span.legacy
    check after[span.contentStart ..< span.contentEnd] == Snippet & "\n"

  test "a block fs.managedBlock's writer put in a file is the one ensureSnippet updates":
    let dir = scratch()
    defer: removeDir(dir)
    let file = dir / "config.nims"
    let key = managedBlockKey(ProjectBlockScope, Pkg, BlockId)
    let seeded = spliceManagedBlock("switch(\"a\")\n", key, "old\n",
      alDirectlyAfter, file)
    writeFile(file, seeded)
    check run(snippetAction("snippet", file)).status == asSucceeded
    let after = readFile(file)
    checkpoint(after)
    check after == "switch(\"a\")\n" & wantedBlock() & "\n"

  test "a legacy :v1 block is replaced in place by the current form":
    let dir = scratch()
    defer: removeDir(dir)
    let file = dir / "config.nims"
    writeFile(file, "switch(\"a\")\n\n" & LegacyOpen & "\ninclude \"old\"\n" &
      LegacyClose & "\nswitch(\"b\")\n")
    check run(snippetAction("snippet", file)).status == asSucceeded
    let after = readFile(file)
    checkpoint(after)
    check ":v1" notin after
    check after == "switch(\"a\")\n\n" & wantedBlock() & "\nswitch(\"b\")\n"

suite "the managed-file writer refuses a file it cannot read unambiguously":

  test "the same block twice fails, naming the file and the block":
    let dir = scratch()
    defer: removeDir(dir)
    let file = dir / "config.nims"
    let before = wantedBlock() & "\n\n" & wantedBlock() & "\n"
    writeFile(file, before)
    let res = run(snippetAction("snippet", file))
    check res.status == asFailed
    check file in res.stderr
    check BlockId in res.stderr
    check readFile(file) == before

  test "an opening sentinel without its closing sentinel fails":
    let dir = scratch()
    defer: removeDir(dir)
    let file = dir / "config.nims"
    let before = "switch(\"a\")\n" & SpecOpen & "\nswitch(\"b\")\n"
    writeFile(file, before)
    let res = run(snippetAction("snippet", file))
    check res.status == asFailed
    check file in res.stderr
    check BlockId in res.stderr
    check readFile(file) == before

suite "a changing write replaces the file atomically; an unchanged one is untouched":

  type ReplaceFacts = object
    ## What a write did to `file`, observed through a hard link to its
    ## previous inode.
    status: ActionStatus
    inodeChanged: bool      ## a new inode is at the path
    oldInodeBytes: string   ## the previous inode's bytes after the write
    newBytes: string        ## the path's bytes after the write
    leftovers: seq[string]  ## other names left in the directory

  proc writeThroughWitness(action: BuildAction; file, before: string):
      ReplaceFacts =
    writeFile(file, before)
    let witness = file & ".old-link"
    createHardlink(file, witness)
    let oldInode = inode(file)
    result.status = run(action).status
    result.inodeChanged = inode(file) != oldInode
    result.oldInodeBytes = readFile(witness)
    result.newBytes = readFile(file)
    for kind, path in walkDir(file.parentDir):
      let name = path.extractFilename
      if name notin [file.extractFilename, witness.extractFilename]:
        result.leftovers.add(name)

  # A rename installs a NEW inode at the path; the old inode -- still
  # reachable through the hard link -- keeps the old bytes. An in-place write
  # would change both. No temporary file may be left beside the target.

  test "ensureSnippet replaces the file by rename":
    let dir = scratch()
    defer: removeDir(dir)
    let file = dir / "config.nims"
    let before = "switch(\"a\")\n"
    let facts = writeThroughWitness(snippetAction("snippet", file), file,
      before)
    check facts.status == asSucceeded
    check facts.inodeChanged
    check facts.oldInodeBytes == before
    check facts.newBytes != before
    check facts.leftovers.len == 0

  test "ensureLine replaces the file by rename":
    let dir = scratch()
    defer: removeDir(dir)
    let file = dir / ".gitignore"
    let before = "build/\n"
    let facts = writeThroughWitness(lineAction("line", file, "repro.paths"),
      file, before)
    check facts.status == asSucceeded
    check facts.inodeChanged
    check facts.oldInodeBytes == before
    check facts.newBytes != before
    check facts.leftovers.len == 0

  test "an up-to-date file keeps its bytes, inode and mtime":
    let dir = scratch()
    defer: removeDir(dir)
    let snippetFile = dir / "config.nims"
    let lineFile = dir / ".gitignore"
    let snippetBytes = "switch(\"a\")\r\n\r\n" & wantedBlock("\r\n") & "\r\n"
    writeFile(snippetFile, snippetBytes)
    writeFile(lineFile, "build/\nrepro.paths\n")
    for path in [snippetFile, lineFile]:
      setLastModificationTime(path, fromUnix(PinnedMtime))
    let snippetInode = inode(snippetFile)
    let lineInode = inode(lineFile)
    check run(snippetAction("snippet", snippetFile)).status == asSucceeded
    check run(lineAction("line", lineFile, "repro.paths")).status ==
      asSucceeded
    check readFile(snippetFile) == snippetBytes
    check readFile(lineFile) == "build/\nrepro.paths\n"
    check inode(snippetFile) == snippetInode
    check inode(lineFile) == lineInode
    check getLastModificationTime(snippetFile) == fromUnix(PinnedMtime)
    check getLastModificationTime(lineFile) == fromUnix(PinnedMtime)

  test "ensureLine terminates the line as the file does":
    # The shared writer's line-terminator rule (fs-file-utilities.md §3)
    # holds for a line too: a CRLF file stays CRLF.
    let dir = scratch()
    defer: removeDir(dir)
    let file = dir / ".gitignore"
    writeFile(file, "build/\r\nnimcache/")
    check run(lineAction("line", file, "repro.paths")).status == asSucceeded
    check readFile(file) == "build/\r\nnimcache/\r\nrepro.paths\r\n"

suite "ownership is checked when the graph is constructed":

  test "two actions declaring the same block are refused, even when ordered":
    let dir = scratch()
    defer: removeDir(dir)
    let first = snippetAction("owner/first", "config.nims", cwd = dir)
    let second = snippetAction("owner/second", "config.nims", cwd = dir,
      deps = ["owner/first"], snippet = "discard")
    let msg = refusal(dir, [first, second])
    checkpoint(msg)
    check "owner/first" in msg
    check "owner/second" in msg
    check not fileExists(dir / "config.nims")

  test "two writers of one file with no dependency chain are refused":
    let dir = scratch()
    defer: removeDir(dir)
    # The file is spelled differently by the two actions: ownership is about
    # the file, not about the string that names it.
    let snippet = snippetAction("race/snippet", "config.nims", cwd = dir)
    let line = lineAction("race/line", "./config.nims", "--hints:off",
      cwd = dir)
    let msg = refusal(dir, [snippet, line])
    checkpoint(msg)
    check "race/snippet" in msg
    check "race/line" in msg
    check not fileExists(dir / "config.nims")

  test "the same block spelled through two paths is refused":
    let dir = scratch()
    defer: removeDir(dir)
    let first = snippetAction("alias/first", "config.nims", cwd = dir)
    let second = snippetAction("alias/second", dir / "config.nims", cwd = dir,
      deps = ["alias/first"])
    let msg = refusal(dir, [first, second])
    checkpoint(msg)
    check "alias/first" in msg
    check "alias/second" in msg

  test "writers of one file ordered by a dependency chain are accepted":
    let dir = scratch()
    defer: removeDir(dir)
    let first = snippetAction("chain/first", "config.nims", cwd = dir)
    let second = snippetAction("chain/second", "config.nims", cwd = dir,
      blockId = "other-block", snippet = "discard",
      deps = ["chain/first"])
    let third = lineAction("chain/line", "config.nims", "--hints:off",
      cwd = dir, deps = ["chain/second"])
    check refusal(dir, [first, second, third]) == ""
    let after = readFile(dir / "config.nims")
    # A second build leaves the shared file exactly as it is.
    check refusal(dir, [first, second, third]) == ""
    check readFile(dir / "config.nims") == after
    checkpoint(after)
    check after.occurrences(SpecOpen) == 1
    check after.occurrences(
      "# >>> repro:project:demo:other-block >>>") == 1
    check after.occurrences("--hints:off") == 1

suite "local freshness":

  test "a block removed by hand comes back on the next build":
    let dir = scratch()
    defer: removeDir(dir)
    let file = dir / "config.nims"
    writeFile(file, "switch(\"a\")\n")
    # Cacheable, as the DSL lowers it.
    let action = snippetAction("fresh/snippet", "config.nims", cwd = dir,
      cacheable = true)
    for build in 1 .. 2:
      let res = runBuild(graph([action]), buildConfig(dir))
      checkpoint("build " & $build & ": " & $res.results[0].status & " " &
        res.results[0].stderr)
      check res.results[0].status in {asSucceeded, asCacheHit, asUpToDate}
    let written = readFile(file)
    check BlockId in written
    # The user deletes the block.
    writeFile(file, "switch(\"a\")\n")
    let res = runBuild(graph([action]), buildConfig(dir))
    checkpoint("after removal: " & $res.results[0].status & " " &
      res.results[0].stderr)
    check res.results[0].status in {asSucceeded, asCacheHit, asUpToDate}
    check readFile(file) == written

  # `repro build` keeps output blobs in the local store when a peer cache
  # publisher is configured (`deferLocalOutputBlobs = false`). A cache hit
  # may then restore a recorded output over a modified one -- which, for a
  # managed-file writer, would put back the WHOLE file as it was and revert
  # bytes the action does not own. fs-file-utilities.md §4: the action runs
  # again instead.

  test "a user edit outside the block survives a build that keeps blobs":
    let dir = scratch()
    defer: removeDir(dir)
    let file = dir / "config.nims"
    writeFile(file, "switch(\"a\")\n")
    var config = buildConfig(dir)
    config.deferLocalOutputBlobs = false
    let action = snippetAction("keep/snippet", "config.nims", cwd = dir,
      cacheable = true)
    for build in 1 .. 2:
      discard runBuild(graph([action]), config)
    let edited = readFile(file) & "switch(\"user\")\n"
    writeFile(file, edited)
    let res = runBuild(graph([action]), config)
    checkpoint("after edit: " & $res.results[0].status & " " &
      res.results[0].stderr)
    check res.results[0].status in {asSucceeded, asCacheHit, asUpToDate}
    check res.results[0].outputOverwrites.len == 0
    check readFile(file) == edited

  test "ordered writers of one file leave it untouched once it converged":
    let dir = scratch()
    defer: removeDir(dir)
    let file = dir / "config.nims"
    writeFile(file, "switch(\"a\")\n")
    var config = buildConfig(dir)
    config.deferLocalOutputBlobs = false
    let first = snippetAction("conv/first", "config.nims", cwd = dir,
      cacheable = true)
    let second = snippetAction("conv/second", "config.nims", cwd = dir,
      blockId = "other-block", snippet = "discard", cacheable = true,
      deps = ["conv/first"])
    for build in 1 .. 2:
      discard runBuild(graph([first, second]), config)
    let converged = readFile(file)
    setLastModificationTime(file, fromUnix(PinnedMtime))
    let res = runBuild(graph([first, second]), config)
    for r in res.results:
      checkpoint(r.id & ": " & $r.status & " " & r.stderr)
      check r.outputOverwrites.len == 0
    check readFile(file) == converged
    check getLastModificationTime(file) == fromUnix(PinnedMtime)
