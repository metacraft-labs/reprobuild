## ``closureManifest`` — a package whose entry point needs its dependencies.
##
## Most tarball packages are one archive. Two of the coding agents are not:
## ``@zed-industries/claude-code-acp`` is 174 KB with five runtime
## dependencies, and ``@sourcegraph/amp`` is an 895-byte wrapper whose
## ``bin`` points into ``node_modules/@ampcode/cli/bin/`` — a
## platform-specific native binary npm reaches through optional
## dependencies. Declaring either as a single tarball yields a prefix whose
## command cannot start.
##
## The alternative everybody reaches for first is a build step that runs
## ``npm install`` into the prefix. That is a version-range resolution at
## build time and a network fetch inside a build — the two things this
## whole provisioning system exists to remove. A manifest of PINNED
## archives keeps the fetch content-addressed, cached in the store's own
## download cache, and offline after the first time.
##
## The fixtures here are tarballs and zips built on the spot and served over
## ``file://``, or by this binary re-executed as a loopback HTTP server, so
## nothing touches the network.

import std/[algorithm, net, os, osproc, strutils, tempfiles, unittest]

import repro_attest/measurement
import repro_hash
import repro_interface_artifacts
import repro_tool_profiles

proc fileUrl(path: string): string =
  "file:///" & path.replace('\\', '/').strip(leading = true, chars = {'/'})

proc makeTarball(root, name, innerRelPath, contents: string): string =
  ## An npm-shaped archive: everything under a single ``package/`` root,
  ## which is why the realizer strips one component for closure entries.
  let stage = root / ("stage-" & name)
  let inner = stage / "package" / innerRelPath
  createDir(inner.parentDir)
  writeFile(inner, contents)
  result = root / (name & ".tgz")
  # No `--force-local`: the `tar` on a Windows PATH may be bsdtar, which
  # rejects the flag outright and handles a drive letter natively anyway.
  let res = execCmdEx("tar -czf " & quoteShell(result) &
    " -C " & quoteShell(stage) & " package")
  doAssert res.exitCode == 0, "tar failed: " & res.output

proc closureUse(rootUrl, rootSha, manifestPath: string;
                executablePath = "bin/cli.js"): InterfaceToolUse =
  result = InterfaceToolUse(
    rawConstraint: "closurefixture",
    packageSelector: "closurefixture",
    executableName: "cli",
    location: SourceLocation(file: "fixture", line: 1))
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    packageName: "closurefixture",
    url: rootUrl,
    sha256: "sha256:" & rootSha,
    archiveType: "tar.gz",
    stripComponents: 1,
    executablePath: executablePath,
    closureManifest: manifestPath,
    packageId: "closurefixture@1",
    lockIdentity: "tarball:closurefixture@1:sha256:" & rootSha,
    location: SourceLocation(file: "fixture", line: 2))]

# ---------------------------------------------------------------------------
# A loopback HTTP fixture: this binary, re-executed. It serves the files of
# one directory by name, one request per connection, and appends every
# request line it reads to a log -- so a case can prove a refusal fetched
# nothing at all, the primary archive included.
# ---------------------------------------------------------------------------

const ServeFlag = "--serve-closure-fixture"

proc serveFixture(dir, portFile, logFile: string) =
  let server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(0), "127.0.0.1")
  server.listen()
  let (_, port) = server.getLocalAddr()
  writeFile(portFile & ".tmp", $port.int)
  moveFile(portFile & ".tmp", portFile)
  while true:
    var client: Socket
    server.accept(client)
    try:
      let requestLine = client.recvLine(timeout = 10_000)
      let log = open(logFile, fmAppend)
      log.writeLine(requestLine)
      log.close()
      while true:
        let header = client.recvLine(timeout = 10_000)
        if header.len == 0 or header == "\r\n":
          break
      let parts = requestLine.splitWhitespace()
      let name = if parts.len >= 2: parts[1].strip(chars = {'/'}) else: ""
      if name.len > 0 and '/' notin name and fileExists(dir / name):
        let payload = readFile(dir / name)
        client.send("HTTP/1.1 200 OK\r\nContent-Type: " &
          "application/octet-stream\r\nContent-Length: " & $payload.len &
          "\r\nConnection: close\r\n\r\n" & payload)
      else:
        client.send("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n" &
          "Connection: close\r\n\r\n")
    except CatchableError:
      discard
    finally:
      client.close()

if paramCount() == 4 and paramStr(1) == ServeFlag:
  serveFixture(paramStr(2), paramStr(3), paramStr(4))
  quit(0)

type HttpFixture = object
  server: Process
  baseUrl: string
  logFile: string

proc startHttpFixture(dir: string): HttpFixture =
  let portFile = dir / "port"
  result.logFile = dir / "requests.log"
  writeFile(result.logFile, "")
  result.server = startProcess(getAppFilename(),
    args = [ServeFlag, dir, portFile, result.logFile],
    options = {poParentStreams})
  var waited = 0
  while not fileExists(portFile) and waited < 20_000:
    sleep(20)
    waited += 20
  doAssert fileExists(portFile), "closure fixture server did not start"
  result.baseUrl = "http://127.0.0.1:" & readFile(portFile).strip()

proc requestCount(fixture: HttpFixture): int =
  for line in readFile(fixture.logFile).splitLines():
    if line.strip().len > 0:
      inc result

proc stop(fixture: HttpFixture) =
  terminate(fixture.server)
  discard waitForExit(fixture.server)
  close(fixture.server)

# ---------------------------------------------------------------------------
# Typed closure entries: archives of a declared kind and strip count.
# ---------------------------------------------------------------------------

proc makeArchive(root, name, kind: string;
                 files: openArray[(string, string)]): string =
  ## A real archive of `kind` whose members are exactly `files`
  ## (stage-relative path, contents), each executable so a member can be a
  ## declared executable. Members are named from their top-level entries,
  ## never ``.``, so a strip count means what it says.
  let stage = root / ("stage-" & name)
  var tops: seq[string] = @[]
  for (rel, contents) in files:
    let path = stage / rel
    createDir(path.parentDir)
    writeFile(path, contents)
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
    let top = rel.split('/')[0]
    if top notin tops:
      tops.add(top)
  var quoted: seq[string] = @[]
  for top in tops:
    quoted.add(quoteShell(top))
  case kind
  of "zip":
    result = root / (name & ".zip")
    let res = execCmdEx("zip -q -r -X " & quoteShell(result) & " " &
      quoted.join(" "), workingDir = stage)
    doAssert res.exitCode == 0, "zip failed: " & res.output
  of "tar.gz", "tar.xz":
    result = root / (name & (if kind == "tar.gz": ".tgz" else: ".txz"))
    let flag = if kind == "tar.gz": "-czf " else: "-cJf "
    let res = execCmdEx("tar " & flag & quoteShell(result) & " -C " &
      quoteShell(stage) & " " & quoted.join(" "))
    doAssert res.exitCode == 0, "tar failed: " & res.output
  else:
    doAssert false, "unsupported fixture kind " & kind

proc entryLine(destination, archive, url: string; tail = ""): string =
  destination & " " & sha256Hex(readFile(archive)) & " " & url &
    (if tail.len > 0: " " & tail else: "") & "\n"

proc treeOf(dir: string): seq[string] =
  ## Every file under `dir`, as a sorted `/`-separated relative path.
  for path in walkDirRec(dir, relative = true):
    result.add(path.replace('\\', '/'))
  result.sort()

proc completedPrefixes(store: string): seq[string] =
  ## Realized prefixes of the fixture package, and the provisioning receipts
  ## that would claim one: a refused realization must leave neither.
  let prefixes = store / "prefixes" / "closurefixture"
  if dirExists(prefixes):
    for entry in walkDir(prefixes):
      result.add(entry.path)
  if dirExists(store):
    for path in walkDirRec(store):
      if path.endsWith(".receipt") and "tarball-provision" in path:
        result.add(path)

proc refusal(use: InterfaceToolUse; store: string): string =
  try:
    discard resolveTarballTool(use, store)
  except CatchableError as err:
    return err.msg
  ""

proc rootFingerprint(use: InterfaceToolUse; store: string): ContentDigest =
  ## The weak fingerprint of the package's own provisioning action -- the
  ## identity a closure's content has to move.
  let edges = tarballProvisioningEdges(use, store)
  for action in edges.actions:
    if action.id == edges.rootId:
      return action.weakFingerprint
  doAssert false, "no root provisioning action"

suite "a declared closure lands beside the entry point":
  putEnv("REPRO_CACHE_DISABLE", "1")

  test "each manifest entry is unpacked at its declared path":
    let root = createTempDir("repro-closure-", "")
    defer:
      try: removeDir(root) except CatchableError: discard
    let rootTgz = makeTarball(root, "root", "bin/cli.js",
      "require('dep');\n")
    let depTgz = makeTarball(root, "dep", "index.js", "module.exports=1;\n")
    let manifest = root / "closure.manifest"
    writeFile(manifest,
      "# generated from package-lock.json\n" &
      "node_modules/dep " & sha256Hex(readFile(depTgz)) & " " &
      fileUrl(depTgz) & "\n")

    let profile = resolveTarballTool(
      closureUse(fileUrl(rootTgz), sha256Hex(readFile(rootTgz)), manifest),
      root / "store")
    let prefix = profile.selectedStorePath
    # The entry point, and the dependency it resolves against — the whole
    # point being that the second is present without a build step.
    check fileExists(prefix / "bin" / "cli.js")
    check fileExists(prefix / "node_modules" / "dep" / "index.js")
    check readFile(prefix / "node_modules" / "dep" / "index.js") ==
      "module.exports=1;\n"

  test "a manifest entry that escapes the prefix is refused":
    # The one input here that is a path from a file, so the one that can
    # try to write outside the store.
    let root = createTempDir("repro-closure-", "")
    defer:
      try: removeDir(root) except CatchableError: discard
    let rootTgz = makeTarball(root, "root", "bin/cli.js", "x\n")
    let depTgz = makeTarball(root, "dep", "index.js", "y\n")
    let manifest = root / "escape.manifest"
    writeFile(manifest,
      "../outside " & sha256Hex(readFile(depTgz)) & " " & fileUrl(depTgz) &
      "\n")
    var message = ""
    try:
      discard resolveTarballTool(
        closureUse(fileUrl(rootTgz), sha256Hex(readFile(rootTgz)), manifest),
        root / "store")
    except CatchableError as err:
      message = err.msg
    check message.contains("inside the prefix")

  test "a malformed manifest line names the file and the line":
    let root = createTempDir("repro-closure-", "")
    defer:
      try: removeDir(root) except CatchableError: discard
    let rootTgz = makeTarball(root, "root", "bin/cli.js", "x\n")
    let manifest = root / "bad.manifest"
    writeFile(manifest, "node_modules/dep only-two-fields\n")
    var message = ""
    try:
      discard resolveTarballTool(
        closureUse(fileUrl(rootTgz), sha256Hex(readFile(rootTgz)), manifest),
        root / "store")
    except CatchableError as err:
      message = err.msg
    check message.contains("bad.manifest")
    check message.contains("only-two-fields")

  test "a missing manifest is an error, not an empty closure":
    # Silently realizing a prefix without its dependencies would produce a
    # command that fails at RUN time on a consumer's machine, which is the
    # failure this whole field exists to move earlier.
    let root = createTempDir("repro-closure-", "")
    defer:
      try: removeDir(root) except CatchableError: discard
    let rootTgz = makeTarball(root, "root", "bin/cli.js", "x\n")
    var message = ""
    try:
      discard resolveTarballTool(
        closureUse(fileUrl(rootTgz), sha256Hex(readFile(rootTgz)),
          root / "absent.manifest"),
        root / "store")
    except CatchableError as err:
      message = err.msg
    check message.contains("closure manifest not found")

suite "a typed closure entry is an archive of its declared kind and strip":
  putEnv("REPRO_CACHE_DISABLE", "1")

  test "zip, tar.gz and tar.xz entries land with their own strip counts":
    # The shape an SDK prefix needs: the declared executable comes from a
    # zip entry, not from the root archive, beside npm-style and tar.xz
    # members. Every resulting tree is checked file by file, so a strip
    # count that was ignored (or applied to the wrong entry) shows up as a
    # wrong path rather than passing on one present file.
    let root = createTempDir("repro-closure-", "")
    defer:
      try: removeDir(root) except CatchableError: discard
    let rootTgz = makeTarball(root, "root", "bin/cli.js", "x\n")
    let npmDep = makeTarball(root, "dep", "index.js", "module.exports=1;\n")
    let sdkZip = makeArchive(root, "sdk", "zip", [
      ("emsdk-top/bin/emcc", "#!/bin/sh\necho emcc\n"),
      ("emsdk-top/share/config", "cfg\n")])
    let flatZip = makeArchive(root, "flat", "zip", [
      ("data/a.txt", "a\n")])
    let deepTxz = makeArchive(root, "deep", "tar.xz", [
      ("outer/inner/lib/x.so", "so\n"),
      ("outer/inner/lib/y.so", "so2\n")])
    let plainTgz = makeArchive(root, "plain", "tar.gz", [
      ("pkg/readme", "r\n")])
    let manifest = root / "typed.manifest"
    writeFile(manifest,
      entryLine("node_modules/dep", npmDep, fileUrl(npmDep)) &
      entryLine("sdk", sdkZip, fileUrl(sdkZip), "zip 1") &
      entryLine("flat", flatZip, fileUrl(flatZip), "zip 0") &
      entryLine("deep", deepTxz, fileUrl(deepTxz), "tar.xz 2") &
      entryLine("plain", plainTgz, fileUrl(plainTgz), "tar.gz 0"))

    let profile = resolveTarballTool(closureUse(fileUrl(rootTgz),
      sha256Hex(readFile(rootTgz)), manifest, "sdk/bin/emcc"), root / "store")
    let prefix = profile.selectedStorePath
    check treeOf(prefix / "node_modules" / "dep") == @["index.js"]
    check treeOf(prefix / "sdk") == @["bin/emcc", "share/config"]
    check readFile(prefix / "sdk" / "bin" / "emcc") ==
      "#!/bin/sh\necho emcc\n"
    check treeOf(prefix / "flat") == @["data/a.txt"]
    check treeOf(prefix / "deep") == @["lib/x.so", "lib/y.so"]
    check treeOf(prefix / "plain") == @["pkg/readme"]

  test "the three-field form keeps its identity; a kind or count moves it":
    let root = createTempDir("repro-closure-", "")
    defer:
      try: removeDir(root) except CatchableError: discard
    let rootTgz = makeTarball(root, "root", "bin/cli.js", "x\n")
    let rootSha = sha256Hex(readFile(rootTgz))
    let dep = makeTarball(root, "dep", "index.js", "y\n")
    let other = makeTarball(root, "other", "index.js", "z\n")
    let store = root / "store"
    # One manifest PATH throughout: the plan records the path, so only the
    # content may differ between the identities compared here.
    proc fingerprintOf(name, body: string): ContentDigest =
      checkpoint(name)
      let manifest = root / "closure.manifest"
      writeFile(manifest, body)
      rootFingerprint(closureUse(fileUrl(rootTgz), rootSha, manifest), store)

    let legacy = fingerprintOf("legacy",
      entryLine("node_modules/dep", dep, fileUrl(dep)) &
      entryLine("node_modules/other", other, fileUrl(other)))
    # The npm defaults written out are the npm entry, and a comment or a
    # reordering is not content.
    check fingerprintOf("explicit",
      entryLine("node_modules/dep", dep, fileUrl(dep), "tar.gz 1") &
      entryLine("node_modules/other", other, fileUrl(other))) == legacy
    check fingerprintOf("reordered",
      "# regenerated\n" &
      entryLine("node_modules/other", other, fileUrl(other)) &
      entryLine("node_modules/dep", dep, fileUrl(dep), "tar.gz 1")) == legacy
    var seen = @[legacy]
    for tail in ["tar.gz 0", "tar.gz 2", "tar.xz 1", "zip 1", "zip 0"]:
      let moved = fingerprintOf("mutated-" & tail.replace(' ', '-'),
        entryLine("node_modules/dep", dep, fileUrl(dep), tail) &
        entryLine("node_modules/other", other, fileUrl(other)))
      check moved notin seen
      seen.add(moved)

  test "a malformed manifest is refused before anything is fetched":
    # Root and entries are served over loopback HTTP, so the root archive's
    # own download would be counted too. Each manifest's FIRST line is
    # valid: the refusal has to come from validating the whole manifest,
    # not from reaching the bad line after fetching the good one.
    let root = createTempDir("repro-closure-", "")
    let served = root / "served"
    createDir(served)
    let rootTgz = makeTarball(served, "root", "bin/cli.js", "x\n")
    let dep = makeTarball(served, "dep", "index.js", "y\n")
    let fixture = startHttpFixture(served)
    defer:
      fixture.stop()
      try: removeDir(root) except CatchableError: discard
    let rootUrl = fixture.baseUrl & "/root.tgz"
    let depUrl = fixture.baseUrl & "/dep.tgz"
    let good = entryLine("node_modules/good", dep, depUrl)
    let depSha = sha256Hex(readFile(dep))
    let cases = [
      ("four fields", "node_modules/dep " & depSha & " " & depUrl & " zip\n",
        "must be"),
      ("six fields", "node_modules/dep " & depSha & " " & depUrl &
        " zip 1 x\n", "must be"),
      ("unsupported kind", entryLine("node_modules/dep", dep, depUrl,
        "7z 1"), "archiveType must be one of"),
      ("bzip2 kind", entryLine("node_modules/dep", dep, depUrl, "tar.bz2 1"),
        "archiveType must be one of"),
      ("short digest", "node_modules/dep abc123 " & depUrl & "\n",
        "not a SHA-256"),
      ("non-hex digest", "node_modules/dep " & "g".repeat(64) & " " & depUrl &
        "\n", "not a SHA-256"),
      ("negative strip", entryLine("node_modules/dep", dep, depUrl,
        "tar.gz -1"), "nonnegative decimal"),
      ("signed strip", entryLine("node_modules/dep", dep, depUrl,
        "tar.gz +1"), "nonnegative decimal"),
      ("non-decimal strip", entryLine("node_modules/dep", dep, depUrl,
        "tar.gz 0x1"), "nonnegative decimal"),
      ("overflowing strip", entryLine("node_modules/dep", dep, depUrl,
        "tar.gz 99999999999999999999999"), "nonnegative decimal"),
      ("deep zip strip", entryLine("node_modules/dep", dep, depUrl, "zip 2"),
        "0 or 1 for a zip"),
      ("absolute path", entryLine("/abs/dep", dep, depUrl),
        "inside the prefix"),
      ("drive path", entryLine("C:/dep", dep, depUrl), "inside the prefix"),
      ("UNC path", entryLine("\\\\server\\share\\dep", dep, depUrl),
        "inside the prefix"),
      ("parent component", entryLine("node_modules/../../dep", dep, depUrl),
        "inside the prefix"),
      ("prefix root", entryLine("./", dep, depUrl), "inside the prefix"),
      ("duplicate destination", entryLine(".//node_modules\\good/", dep,
        depUrl), "two closure entries unpack to node_modules/good")]
    for (label, bad, expected) in cases:
      let manifest = root / (label.replace(' ', '-') & ".manifest")
      writeFile(manifest, good & bad)
      let store = root / ("store-" & label.replace(' ', '-'))
      let message = refusal(closureUse(rootUrl, sha256Hex(readFile(rootTgz)),
        manifest), store)
      checkpoint(label & ": " & message)
      check message.contains(expected)
      check message.contains(manifest)
      check fixture.requestCount() == 0
      check completedPrefixes(store).len == 0
    # The fixture is live: the same root with a valid closure fetches both.
    let valid = root / "valid.manifest"
    writeFile(valid, good)
    discard resolveTarballTool(closureUse(rootUrl,
      sha256Hex(readFile(rootTgz)), valid), root / "store-valid")
    check fixture.requestCount() == 2

  test "a wrong digest, a traversing member or a missing output publishes nothing":
    let root = createTempDir("repro-closure-", "")
    defer:
      try: removeDir(root) except CatchableError: discard
    let rootTgz = makeTarball(root, "root", "bin/cli.js", "x\n")
    let rootSha = sha256Hex(readFile(rootTgz))
    let sdkZip = makeArchive(root, "sdk", "zip", [
      ("emsdk-top/bin/emcc", "#!/bin/sh\n")])
    let decoy = makeArchive(root, "decoy", "zip", [("other/file", "d\n")])
    # A member named `../escaped`: GNU tar keeps the `..` only with -P.
    let stage = root / "stage-evil" / "inner"
    createDir(stage)
    writeFile(root / "stage-evil" / "escaped", "e\n")
    let evil = root / "evil.tgz"
    let made = execCmdEx("tar -czPf " & quoteShell(evil) & " -C " &
      quoteShell(stage) & " ../escaped")
    doAssert made.exitCode == 0, "tar failed: " & made.output
    doAssert execCmdEx("tar -tzf " & quoteShell(evil)).output.contains(
      "../escaped")

    # Each case is refused for its OWN reason, after acquisition started and
    # with the declared executable `sdk/bin/emcc` otherwise satisfiable.
    let cases = [
      ("wrong digest", "sdk " & sha256Hex(readFile(decoy)) & " " &
        fileUrl(sdkZip) & " zip 1\n", "sha256 mismatch"),
      ("traversing member", entryLine("sdk", sdkZip, fileUrl(sdkZip),
        "zip 1") & entryLine("data/evil", evil, fileUrl(evil), "tar.gz 0"),
        "unsafe archive entry: ../escaped"),
      ("missing output", entryLine("sdk", decoy, fileUrl(decoy), "zip 1"),
        "sdk/bin/emcc")]
    for (label, body, expected) in cases:
      let manifest = root / (label.replace(' ', '-') & ".manifest")
      writeFile(manifest, body)
      let store = root / ("store-" & label.replace(' ', '-'))
      let message = refusal(closureUse(fileUrl(rootTgz), rootSha, manifest,
        "sdk/bin/emcc"), store)
      checkpoint(label & ": " & message)
      check message.contains(expected)
      check completedPrefixes(store).len == 0
    # The controls are meaningful: the same declaration with the right
    # archive and digest realizes.
    let fine = root / "fine.manifest"
    writeFile(fine, entryLine("sdk", sdkZip, fileUrl(sdkZip), "zip 1"))
    let profile = resolveTarballTool(closureUse(fileUrl(rootTgz), rootSha,
      fine, "sdk/bin/emcc"), root / "store-fine")
    check fileExists(profile.selectedStorePath / "sdk" / "bin" / "emcc")
