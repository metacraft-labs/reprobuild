## A provisioned tool prefix whose bytes come from a build step is cached in
## the shared binary cache like any other tool prefix: realized and published
## on one host, substituted on another with no download and no compile.
##
## The prefix under test is the hardest shape the tarball provisioning edge
## has: a primary archive, a closure entry unpacked into it, and a
## post-extraction step that "compiles" a pinned source file into the prefix
## with a toolchain that is itself a provisioned package (its own tarball
## edge). Cases:
##
##   1. Round trip. Host A holds the publish key: it realizes the toolchain
##      and the prefix (the step runs once) and publishes both. Host B0 reads
##      a cache whose trusted keys do NOT include A's: it realizes everything
##      from upstream (the step runs again) -- the negative control, showing
##      that the substitution below is the trust anchor's doing. Then every
##      upstream archive is deleted, and host B, a read-only consumer that
##      trusts A's key, realizes the same declaration: it substitutes both
##      prefixes, runs no step, downloads nothing, and its prefix is
##      byte-identical to A's. Both hosts record the same complete cache key
##      inside the prefix.
##   2. Pending propagates. The same step, also run with a library whose
##      identity is incomplete (built by a source recipe whose identity is not
##      bound), gives an incomplete composite: the publisher realizes it but
##      publishes nothing, a trusted consumer substitutes nothing and builds
##      it, and both name `binary-cache-identity-incomplete`.
##   3. Leak refusal. A step that writes the staging path into a file fails
##      the edge naming that file, and nothing is sealed; the same step
##      without the write passes.
##   4. Graph outputs. A step declaring an input under the consuming graph's
##      outputs is refused when its edge is declared, before anything runs;
##      the same input outside them is accepted. An unpinned input is refused
##      the same way.
##   5. From source. A tool built from its source archive (the Nim source
##      build edge, over a stand-in archive whose `build.sh` records every
##      run) is published by host A and substituted by host B after the
##      source archive is deleted, with no build.
##
## Hosts are separate processes (this binary re-invoked with `--host`), each
## with its own tool store and its own cache environment, so nothing is shared
## between them except the cache server. No mocks: a real
## `repro_binary_cache` server on 127.0.0.1, real ECDSA producer keys, a real
## `caches.conf`, real tar archives behind `file://` URLs (a local fixture is
## all the mechanism needs; no real upstream is involved), and a real shell
## toolchain whose every run appends to a witness file outside the prefix. The
## step implementation is registered by this test, which is exactly how an
## ecosystem module registers its own; it runs the provisioned toolchain as a
## child process, so "no compile" is observed on the witness, not inferred.

import std/[algorithm, net, os, osproc, random, sequtils, streams, strtabs, strutils,
            tempfiles, unittest]

from repro_core/process_streams import drainStream
import repro_interface_artifacts
import repro_tool_profiles
import repro_peer_cache/auth as peerAuth

const ServerBinary = "build/test-bin" / addFileExt("repro_binary_cache", ExeExt)

const
  CacheEnvVars = [
    "REPRO_CACHES_CONFIG", "REPRO_BINARY_CACHE_URL",
    "REPRO_BINARY_CACHE_KEY_PATH", "REPRO_BINARY_CACHE_CERT_PATH",
    "REPRO_BINARY_CACHE_SCOPE", "REPRO_BINARY_CACHE_AUTO_CRED_DIR",
    "REPRO_CACHE_DISABLE", "REPRO_APPLY_PUBLISH"]
  StepKind = "fx-native-build"

# ---------------------------------------------------------------------------
# Fixture: archives, the step, the declaration
# ---------------------------------------------------------------------------

proc makeExecutable(path, body: string) =
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc tarGz(source, top, archive: string) =
  let packed = execCmdEx(quoteShellCommand(@[findExe("tar"), "-czf", archive,
    "-C", source, top]))
  doAssert packed.exitCode == 0, packed.output

proc pinOf(root, name: string): string =
  ## The SHA-256 the declaration pins for fixture file `name`, recorded when
  ## the fixture was made: a host that later finds the archive gone still
  ## declares the same digest, as a real recipe does.
  let recorded = root / "pins" / name
  if fileExists(recorded):
    return readFile(recorded)
  result = fileSha256Hex(root / name)
  createDir(root / "pins")
  writeFile(recorded, result)

proc createFixture(root: string) =
  ## The toolchain archive (`fxcc`, a shell "compiler" that records every
  ## run in `$FIXTURE_WITNESS`), the SDK archive, one closure archive and the
  ## pinned source file the step compiles.
  createDir(root / "src-cc" / "fx-cc" / "bin")
  makeExecutable(root / "src-cc" / "fx-cc" / "bin" / "fxcc",
    "#!/bin/sh\necho run >> \"$FIXTURE_WITNESS\"\n" &
    "{ cat \"$1\"; echo compiled-by-fxcc; } > \"$2\"\n")
  tarGz(root / "src-cc", "fx-cc", root / "fx-cc.tar.gz")
  createDir(root / "src-sdk" / "fx-sdk" / "bin")
  makeExecutable(root / "src-sdk" / "fx-sdk" / "bin" / "sdk",
    "#!/bin/sh\necho fx-sdk\n")
  tarGz(root / "src-sdk", "fx-sdk", root / "fx-sdk.tar.gz")
  createDir(root / "src-extra" / "extra")
  writeFile(root / "src-extra" / "extra" / "data.txt", "closure entry\n")
  tarGz(root / "src-extra", "extra", root / "extra.tar.gz")
  writeFile(root / "ext.src", "extension source\n")
  createDir(root / "graph-out")
  writeFile(root / "graph-out" / "libwriter.so", "a graph output\n")
  createDir(root / "srclib")
  for name in ["fx-cc.tar.gz", "fx-sdk.tar.gz", "extra.tar.gz"]:
    discard pinOf(root, name)

proc ccUse(root: string): InterfaceToolUse =
  var record = InterfaceTarballProvisioning(url: "file://" & root /
    "fx-cc.tar.gz", sha256: pinOf(root, "fx-cc.tar.gz"),
    archiveType: "tar.gz", executablePath: "bin/fxcc", stripComponents: 1,
    cpu: "any", os: "any", packageId: "fx-cc@1")
  record.detail.version = "1"
  InterfaceToolUse(rawConstraint: "fx-cc", packageSelector: "fx-cc",
    executableName: "fxcc", tarballProvisioning: @[record])

proc sdkUse(root, selector: string): InterfaceToolUse =
  var record = InterfaceTarballProvisioning(url: "file://" & root /
    "fx-sdk.tar.gz", sha256: pinOf(root, "fx-sdk.tar.gz"),
    archiveType: "tar.gz", executablePath: "bin/sdk", stripComponents: 1,
    cpu: "any", os: "any", packageId: selector & "@1")
  record.detail.version = "1"
  record.closureEntries = @[ClosureEntry(path: "share/extra",
    sha256: pinOf(root, "extra.tar.gz"),
    url: "file://" & root / "extra.tar.gz", archiveType: "tar.gz",
    stripComponents: 1)]
  InterfaceToolUse(rawConstraint: selector, packageSelector: selector,
    executableName: "sdk", tarballProvisioning: @[record])

var fixtureRoot = ""
  ## Read by the declaration provider: where this process's fixture lives.

proc declFor(selector: string): PostExtractStepDecl =
  ## The step each test package declares. `fx-sdk*` packages run the
  ## provisioned `fx-cc` over the pinned `ext.src`; the suffix picks the
  ## variant under test.
  if not selector.startsWith("fx-sdk"):
    return
  result = PostExtractStepDecl(kind: StepKind,
    contractVersion: StepKind & "-v1",
    manifestDigest: "fixture-manifest",
    buildConfig: @["ext --fixture"],
    prunePaths: @["lib/ext.o"],
    inputFiles: @[PostExtractStepInputFile(path: fixtureRoot / "ext.src",
      sha256: fileSha256Hex(fixtureRoot / "ext.src"))],
    dependencies: @[ccUse(fixtureRoot)])
  if selector == "fx-sdk-pending":
    result.externalInputs = @[PostExtractStepExternalInput(
      role: "fx-srclib", prefix: fixtureRoot / "srclib",
      incomplete: "built by a source recipe whose identity is not bound")]
  elif selector == "fx-sdk-graph":
    result.inputFiles = @[PostExtractStepInputFile(
      path: fixtureRoot / "graph-out" / "libwriter.so",
      sha256: fileSha256Hex(fixtureRoot / "graph-out" / "libwriter.so"))]
  elif selector == "fx-sdk-unpinned":
    result.inputFiles[0].sha256 = ""

proc fixtureStep(ctx: PostExtractStepContext) {.gcsafe.} =
  ## "Compile" the pinned source with the provisioned toolchain, leave an
  ## intermediate the declaration prunes, and -- for the leak variant --
  ## write the staging path into a configuration file.
  var toolchain = ""
  for tool in ctx.tools:
    if tool.role == "fx-cc":
      toolchain = tool.executable
  if toolchain.len == 0:
    raise newException(OSError, "fixture step: no fx-cc tool was provided")
  createDir(ctx.stagingPrefix / "lib")
  # The provisioned fixture toolchain: a shell script that copies its input
  # and records the run. No real compiler is involved.
  let built = execCmdEx(quoteShellCommand(@[toolchain, ctx.inputFiles[0],
    ctx.stagingPrefix / "lib" / "ext.so"]))
  if built.exitCode != 0:
    raise newException(OSError, "fixture step: compile failed: " & built.output)
  writeFile(ctx.stagingPrefix / "lib" / "ext.o", "intermediate\n")
  if ctx.packageSelector == "fx-sdk-leak":
    writeFile(ctx.stagingPrefix / "lib" / "config.txt",
      "prefix=" & ctx.stagingPrefix & "\n")
  else:
    writeFile(ctx.stagingPrefix / "lib" / "config.txt", "prefix=.\n")

registerPostExtractStep(StepKind, fixtureStep)
registerPostExtractDeclProvider("fixture-step-test",
  proc(use: InterfaceToolUse; record: InterfaceTarballProvisioning):
      PostExtractStepDecl {.gcsafe.} =
    {.cast(gcsafe).}:
      result = declFor(use.packageSelector))

# ---------------------------------------------------------------------------
# Host mode: one realization in this process's own environment
# ---------------------------------------------------------------------------

if paramCount() >= 4 and paramStr(1) == "--host":
  # --host <storeRoot> <fixtureRoot> <selector>
  fixtureRoot = paramStr(3)
  try:
    let profile = resolveTarballTool(sdkUse(fixtureRoot, paramStr(4)),
      paramStr(2))
    echo "PREFIX " & profile.selectedStorePath
    quit(0)
  except CatchableError as err:
    echo "ERROR " & $err.name & ": " & err.msg.replace("\n", " | ")
    quit(1)

const FakeNimVersion = "9.9.9"

proc createNimSourceFixture(root: string) =
  ## A stand-in for a Nim source archive with the layout the source build
  ## reads (``build.sh``, ``c_code/``, ``lib/``, ``config/``). Its ``build.sh``
  ## records every run in ``$FIXTURE_WITNESS`` and writes ``bin/nim``; the build
  ## edge runs it exactly as it runs upstream's.
  let tree = root / "src-nim" / ("nim-" & FakeNimVersion)
  for dir in ["c_code", "lib", "config"]:
    createDir(tree / dir)
  writeFile(tree / "c_code" / "nim.c", "/* compiler sources */\n")
  writeFile(tree / "lib" / "system.nim", "# stdlib\n")
  writeFile(tree / "config" / "nim.cfg", "# config\n")
  makeExecutable(tree / "build.sh",
    "#!/bin/sh\necho run >> \"$FIXTURE_WITNESS\"\n" &
    "printf '#!/bin/sh\\necho fake-nim\\n' > bin/nim\nchmod +x bin/nim\n")
  let packed = execCmdEx(quoteShellCommand(@[findExe("tar"), "-cJf",
    root / "nim-src.tar.xz", "-C", root / "src-nim", "nim-" & FakeNimVersion]))
  doAssert packed.exitCode == 0, packed.output
  discard pinOf(root, "nim-src.tar.xz")

if paramCount() >= 4 and paramStr(1) == "--nim-host":
  # --nim-host <storeRoot> <fixtureRoot> <compiler path the build is keyed on>
  fixtureRoot = paramStr(3)
  try:
    let nim = buildNimFromSourceThroughEdges(FakeNimVersion,
      "file://" & fixtureRoot / "nim-src.tar.xz",
      pinOf(fixtureRoot, "nim-src.tar.xz"), paramStr(2), paramStr(4), "")
    echo "PREFIX " & nim.parentDir.parentDir
    quit(0)
  except CatchableError as err:
    echo "ERROR " & $err.name & ": " & err.msg.replace("\n", " | ")
    quit(1)

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

type
  Keypair = object
    keyPath, certPath, pubHex: string
  HostRun = object
    exitCode: int
    stdout: string
    stderr: string
    prefix: string

proc makeKeypair(dir: string): Keypair =
  createDir(dir)
  result.keyPath = dir / "producer.key"
  result.certPath = dir / "producer.cert"
  discard peerAuth.loadOrGenerateKeypair(result.certPath, result.keyPath)
  result.pubHex = readFile(result.certPath).strip()

proc writeCachesConf(path, url: string; trusted: seq[string]) =
  var text = "[fleet]\nurl = \"" & url & "\"\n"
  if trusted.len > 0:
    text.add("trusted-public-keys = \"" & trusted.join(", ") & "\"\n")
  text.add("priority = 20\n")
  writeFile(path, text)

proc pickPort(): int =
  randomize()
  25_000 + rand(6_999)

proc waitForListener(port: int): bool =
  for _ in 0 ..< 300:
    try:
      let sock = newSocket()
      sock.connect("127.0.0.1", Port(port))
      sock.close()
      return true
    except CatchableError:
      sleep(50)
  false

proc runHost(storeRoot, selector, witness, confPath: string;
             publisher: Keypair = Keypair(); mode = "--host"): HostRun =
  ## Realize `selector` in a child process: a host whose tool store is
  ## `storeRoot`, whose cache configuration is `confPath` alone, and which
  ## holds the publish key only when `publisher` names one.
  let env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key notin CacheEnvVars:
      env[key] = value
  env["REPRO_CACHES_CONFIG"] = confPath
  env["FIXTURE_WITNESS"] = witness
  if publisher.keyPath.len > 0:
    env["REPRO_BINARY_CACHE_KEY_PATH"] = publisher.keyPath
    env["REPRO_BINARY_CACHE_CERT_PATH"] = publisher.certPath
  createDir(parentDir(storeRoot))
  # One stream: the realizer's diagnostics go to stderr and the prefix to
  # stdout, and reading them as one avoids a pipe filling while the other is
  # read.
  let process = startProcess(getAppFilename(),
    args = @[mode, storeRoot, fixtureRoot, selector], env = env,
    options = {poStdErrToStdOut})
  let output = drainStream(process.outputStream)
  result.exitCode = process.waitForExit()
  process.close()
  writeFile(storeRoot & ".log", output)
  result.stdout = output
  result.stderr = output
  for line in output.splitLines():
    if line.startsWith("PREFIX "):
      result.prefix = line["PREFIX ".len .. ^1]

proc witnessCount(path: string): int =
  if not fileExists(path): 0
  else: readFile(path).splitLines().countIt(it.len > 0)

proc treeContents(root: string; skip: openArray[string]): seq[string] =
  ## Every regular file under `root`, relative, with its content, sorted.
  for path in walkDirRec(root, relative = true):
    if path.extractFilename in skip:
      continue
    result.add(path & "\0" & readFile(root / path))
  result.sort()

proc downloadsUnder(storeRoot: string): int =
  let downloads = storeRoot / "downloads"
  if not dirExists(downloads): 0
  else: toSeq(walkDirRec(downloads)).len

proc cleanup(root: string) =
  for p in walkDirRec(root, yieldFilter = {pcFile, pcDir}):
    try: setFilePermissions(p, {fpUserRead, fpUserWrite, fpUserExec})
    except OSError: discard
  removeDir(root)

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

suite "binary-cache coverage of a post-extraction-modified tool prefix":

  test "published on one host, substituted on another with no download and no compile":
    if not fileExists(ServerBinary):
      fail()
      echo "missing " & ServerBinary & "; build the test helpers first"
    else:
      let root = createTempDir("repro-fx-roundtrip-", "")
      defer: cleanup(root)
      fixtureRoot = root / "fixture"
      createFixture(fixtureRoot)
      let port = pickPort()
      let url = "http://127.0.0.1:" & $port
      createDir(root / "server")
      let server = startProcess(absolutePath(ServerBinary),
        args = @["--root=" & root / "server",
                 "--listen=127.0.0.1:" & $port],
        options = {poStdErrToStdOut, poParentStreams})
      defer:
        server.terminate()
        discard server.waitForExit()
        server.close()
      check waitForListener(port)
      let keyA = makeKeypair(root / "keys-a")
      let keyOther = makeKeypair(root / "keys-other")
      writeCachesConf(root / "trusted.conf", url, @[keyA.pubHex])
      writeCachesConf(root / "untrusted.conf", url, @[keyOther.pubHex])
      let witness = root / "witness"

      # Host A: realizes the toolchain and the SDK, runs the step once,
      # publishes both prefixes.
      let a = runHost(root / "host-a" / "store", "fx-sdk", witness,
        root / "trusted.conf", keyA)
      checkpoint a.stdout & a.stderr
      check a.exitCode == 0
      check witnessCount(witness) == 1
      check "repro cache: published fx-cc@1" in a.stderr
      check "repro cache: published fx-sdk@1" in a.stderr
      check "binary-cache-identity-incomplete" notin a.stderr
      let sealedA = readPrefixIdentityFile(a.prefix)
      check sealedA.found
      check sealedA.keyHex.len == 64
      check sealedA.incomplete.len == 0
      check fileExists(a.prefix / "lib" / "ext.so")
      check readFile(a.prefix / "lib" / "ext.so").contains("compiled-by-fxcc")
      check not fileExists(a.prefix / "lib" / "ext.o")  # declared prune
      check fileExists(a.prefix / "share" / "extra" / "data.txt")  # closure

      # Host B0: does not trust A's key. It realizes from upstream, so the
      # step runs again: the substitution below is the trust anchor's doing.
      let b0 = runHost(root / "host-b0" / "store", "fx-sdk", witness,
        root / "untrusted.conf")
      checkpoint b0.stdout & b0.stderr
      check b0.exitCode == 0
      check witnessCount(witness) == 2
      check "substituted" notin b0.stderr
      check readPrefixIdentityFile(b0.prefix).keyHex == sealedA.keyHex

      # Upstream disappears entirely.
      for archive in ["fx-cc.tar.gz", "fx-sdk.tar.gz", "extra.tar.gz"]:
        removeFile(fixtureRoot / archive)

      # Host B: a read-only consumer trusting A. Substitutes both prefixes;
      # no step, no download, the same bytes.
      let b = runHost(root / "host-b" / "store", "fx-sdk", witness,
        root / "trusted.conf")
      checkpoint b.stdout & b.stderr
      check b.exitCode == 0
      check witnessCount(witness) == 2
      check "repro cache: substituted fx-cc@1 from the shared cache" in
        b.stderr
      check "repro cache: substituted fx-sdk@1 from the shared cache" in
        b.stderr
      check "published" notin b.stderr
      check downloadsUnder(root / "host-b" / "store") == 0
      check readPrefixIdentityFile(b.prefix).keyHex == sealedA.keyHex
      check treeContents(b.prefix, [".repro-receipt"]) ==
        treeContents(a.prefix, [".repro-receipt"])

  test "an input with an incomplete identity makes the prefix neither publish nor substitute":
    if not fileExists(ServerBinary):
      fail()
    else:
      let root = createTempDir("repro-fx-pending-", "")
      defer: cleanup(root)
      fixtureRoot = root / "fixture"
      createFixture(fixtureRoot)
      let port = pickPort()
      let url = "http://127.0.0.1:" & $port
      createDir(root / "server")
      let server = startProcess(absolutePath(ServerBinary),
        args = @["--root=" & root / "server",
                 "--listen=127.0.0.1:" & $port],
        options = {poStdErrToStdOut, poParentStreams})
      defer:
        server.terminate()
        discard server.waitForExit()
        server.close()
      check waitForListener(port)
      let keyA = makeKeypair(root / "keys-a")
      writeCachesConf(root / "trusted.conf", url, @[keyA.pubHex])
      let witness = root / "witness"
      let a = runHost(root / "host-a" / "store", "fx-sdk-pending", witness,
        root / "trusted.conf", keyA)
      checkpoint a.stdout & a.stderr
      check a.exitCode == 0
      check witnessCount(witness) == 1
      check "binary-cache-identity-incomplete: fx-sdk-pending@1 is not " &
        "published" in a.stderr
      check "built by a source recipe whose identity is not bound" in a.stderr
      check "repro cache: published fx-sdk-pending@1" notin a.stderr
      # The toolchain has a complete identity of its own and still publishes.
      check "repro cache: published fx-cc@1" in a.stderr
      let sealed = readPrefixIdentityFile(a.prefix)
      check sealed.found
      check sealed.keyHex.len == 0
      check "fx-srclib" in sealed.incomplete
      let b = runHost(root / "host-b" / "store", "fx-sdk-pending", witness,
        root / "trusted.conf")
      checkpoint b.stdout & b.stderr
      check b.exitCode == 0
      check witnessCount(witness) == 2
      check "binary-cache-identity-incomplete: fx-sdk-pending@1 is not " &
        "substituted" in b.stderr
      check "substituted fx-sdk-pending" notin b.stderr

  test "a step that writes the staging path fails the edge naming the file":
    let root = createTempDir("repro-fx-leak-", "")
    defer: cleanup(root)
    fixtureRoot = root / "fixture"
    createFixture(fixtureRoot)
    let saved = getEnv("REPRO_CACHE_DISABLE")
    putEnv("REPRO_CACHE_DISABLE", "1")
    putEnv("FIXTURE_WITNESS", root / "witness")
    defer:
      if saved.len > 0: putEnv("REPRO_CACHE_DISABLE", saved)
      else: delEnv("REPRO_CACHE_DISABLE")
    var refused = false
    try:
      discard resolveTarballTool(sdkUse(fixtureRoot, "fx-sdk-leak"),
        root / "store")
    except StagingPathLeakError as err:
      refused = true
      check err.leaks.len == 1
      check err.leaks[0].file == "lib/config.txt"
      check "lib/config.txt" in err.msg
    check refused
    # Nothing was sealed for the leaking package.
    if dirExists(root / "store" / "prefixes"):
      for dir in walkDirs(root / "store" / "prefixes" / "fx-sdk-leak*" / "*"):
        checkpoint dir
        check false
    # The same step without the write passes (positive control).
    let profile = resolveTarballTool(sdkUse(fixtureRoot, "fx-sdk"),
      root / "store")
    check readFile(profile.selectedStorePath / "lib" / "config.txt") ==
      "prefix=.\n"

  test "a graph output or an unpinned file is refused as a step input when the edge is declared":
    let root = createTempDir("repro-fx-graph-", "")
    defer: cleanup(root)
    fixtureRoot = root / "fixture"
    createFixture(fixtureRoot)
    let graphOutputs = @[fixtureRoot / "graph-out"]
    var refused = ""
    try:
      discard tarballProvisioningEdges(sdkUse(fixtureRoot, "fx-sdk-graph"),
        root / "store", graphOutputs = graphOutputs)
    except ToolPrefixDeclarationError as err:
      refused = err.msg
    check "output of the build graph" in refused
    check "libwriter.so" in refused
    check not dirExists(root / "store")
    # Positive control: an input outside the graph's outputs is accepted.
    let edges = tarballProvisioningEdges(sdkUse(fixtureRoot, "fx-sdk"),
      root / "store", graphOutputs = graphOutputs)
    check edges.actions.len >= 2
    refused = ""
    try:
      discard tarballProvisioningEdges(
        sdkUse(fixtureRoot, "fx-sdk-unpinned"), root / "store")
    except ToolPrefixDeclarationError as err:
      refused = err.msg
    check "without a SHA-256 pin" in refused

  test "a tool built from source is substituted, not rebuilt, on a second host":
    # The from-source shape: the Nim source build edge. The stand-in
    # archive's build.sh never runs the compiler it is given, so no compiler
    # is needed; what matters is that the compiler path the edge is keyed on
    # lies in the Nix store and so has a complete identity. The dev shell's
    # `sh` is such a path. Host B, with the source archive gone, substitutes
    # the built tree.
    let compilerStandIn = findExe("sh")
    let inNixStore = compilerStandIn.startsWith("/nix/store/") or
      (symlinkExists(compilerStandIn) and
       expandSymlink(compilerStandIn).startsWith("/nix/store/"))
    if not fileExists(ServerBinary) or not inNixStore:
      checkpoint "needs " & ServerBinary & " and a `sh` from the Nix store"
      fail()
    else:
      let root = createTempDir("repro-fx-nim-", "")
      defer: cleanup(root)
      fixtureRoot = root / "fixture"
      createDir(fixtureRoot)
      createNimSourceFixture(fixtureRoot)
      let port = pickPort()
      let url = "http://127.0.0.1:" & $port
      createDir(root / "server")
      let server = startProcess(absolutePath(ServerBinary),
        args = @["--root=" & root / "server",
                 "--listen=127.0.0.1:" & $port],
        options = {poStdErrToStdOut, poParentStreams})
      defer:
        server.terminate()
        discard server.waitForExit()
        server.close()
      check waitForListener(port)
      let keyA = makeKeypair(root / "keys-a")
      writeCachesConf(root / "trusted.conf", url, @[keyA.pubHex])
      let witness = root / "witness"
      let a = runHost(root / "host-a" / "store", compilerStandIn, witness,
        root / "trusted.conf", keyA, mode = "--nim-host")
      checkpoint a.stdout
      check a.exitCode == 0
      check witnessCount(witness) == 1
      check "repro cache: published nim@" & FakeNimVersion & " (source build)" in
        a.stdout
      check readPrefixIdentityFile(a.prefix).keyHex.len == 64
      removeFile(fixtureRoot / "nim-src.tar.xz")
      let b = runHost(root / "host-b" / "store", compilerStandIn, witness,
        root / "trusted.conf", mode = "--nim-host")
      checkpoint b.stdout
      check b.exitCode == 0
      check witnessCount(witness) == 1
      check "repro cache: substituted nim@" & FakeNimVersion &
        " (source build) from the shared cache" in b.stdout
      check downloadsUnder(root / "host-b" / "store") == 0
      check treeContents(b.prefix, []) == treeContents(a.prefix, [])
