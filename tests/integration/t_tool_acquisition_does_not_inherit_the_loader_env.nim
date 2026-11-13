## Tool acquisition must not hand the caller's loader environment to the host
## downloader it spawns, and when that downloader fails, the reason must reach
## the error.
##
## THE INCIDENT. Tool acquisition is the class-2 PATH-only tier: it runs
## BEFORE a store exists, so the `curl` it spawns is the host's own, linked
## against the host's libc and OpenSSL. A nix-built `repro`, and reprobuild's
## devshell, export an `LD_LIBRARY_PATH` full of nix-store libraries.
## Inherited, it forced nix-store `libssl.so.3` / `libcrypto.so.3` onto a
## binary never linked against them, and the loader killed it before `main`:
##
##   /usr/bin/curl: libc.so.6: version `GLIBC_2.38' not found
##     (required by .../openssl-3.6.1/lib/libssl.so.3)
##
## and, because the child ran with `poParentStreams`, that line went to the
## terminal while the exception said only `all tarball archive URLs failed`,
## pointing at a URL that was sha256-pinned and never the problem.
##
## NO MOCKS. The downloader is the REAL host curl that `downloadUrlToFile`
## resolves (`/usr/bin/curl` where present); the server is this binary
## re-executed as a plain HTTP/1.1 fixture on 127.0.0.1; the path under test
## is the real `resolveTarballTool` -> `verifiedDownload` ->
## `downloadUrlToFile`. No network. The archive is `raw`, so no `tar` (which
## would inherit the poisoned environment through a different, unrelated
## spawn) is involved.
##
## THE POISON is real, not a marker string: an `LD_LIBRARY_PATH` directory
## holding a zero-byte `libcurl.so.4`, which the glibc loader picks up ahead
## of the real one and refuses ("file too short") before `main` -- the same
## failure shape as the incident, without depending on the host's glibc
## version. On Linux each case first proves its poison bites the host curl
## when inherited, so a green result cannot come from a poison that was inert.
## On macOS and Windows the loader variables cannot reach the host curl
## anyway (SIP strips `DYLD_*` for `/usr/bin/curl`; Windows has no such
## loader); the cases still run end to end there and pin that acquisition
## succeeds with the poison in place.

import std/[net, os, osproc, streams, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_tool_profiles
import repro_core/paths

const ServeFlag = "--serve-acquisition-fixture"
const PayloadRoute = "/acqtool"

# ---------------------------------------------------------------------------
# The HTTP fixture: this binary, re-executed. Serves one file at
# `PayloadRoute`, 404 for anything else, one request per connection, until it
# is killed.
# ---------------------------------------------------------------------------

proc serveFixture(payloadPath, portFile: string) =
  let payload = readFile(payloadPath)
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
      while true:
        let header = client.recvLine(timeout = 10_000)
        if header.len == 0 or header == "\r\n":
          break
      let parts = requestLine.splitWhitespace()
      if parts.len >= 2 and parts[1] == PayloadRoute:
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

if paramCount() == 3 and paramStr(1) == ServeFlag:
  serveFixture(paramStr(2), paramStr(3))
  quit(0)

type Fixture = object
  root: string
  payload: string
  sha256: string
  server: Process
  baseUrl: string

proc startFixture(prefix: string): Fixture =
  result.root = createTempDir(prefix, "")
  # A nonce in the payload gives every case its own digest, so no case can be
  # satisfied from a download another case left in a shared cache.
  result.payload = result.root / "acqtool-payload"
  writeFile(result.payload, "#!/bin/sh\n# " & prefix & $getCurrentProcessId() &
    "\necho acqtool 1.0.0\n")
  setFilePermissions(result.payload, {fpUserRead, fpUserWrite, fpUserExec})
  result.sha256 = fileSha256Hex(result.payload)
  let portFile = result.root / "port"
  # Started BEFORE any poison is put into this process's environment.
  result.server = startProcess(getAppFilename(),
    args = [ServeFlag, result.payload, portFile], options = {poParentStreams})
  var waited = 0
  while not fileExists(portFile) and waited < 20_000:
    sleep(20)
    waited += 20
  doAssert fileExists(portFile), "acquisition fixture server did not start"
  result.baseUrl = "http://127.0.0.1:" & readFile(portFile).strip()

proc stop(fixture: Fixture) =
  terminate(fixture.server)
  discard waitForExit(fixture.server)
  close(fixture.server)
  let root = extendedPath(fixture.root)
  for path in walkDirRec(root, yieldFilter = {pcFile, pcDir}):
    try:
      setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
    except OSError:
      discard
  removeDir(root)

proc rawUse(url, sha256: string): InterfaceToolUse =
  result = InterfaceToolUse(rawConstraint: "acqtool",
    packageSelector: "acqtool", executableName: "acqtool")
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    url: url, sha256: sha256, archiveType: "raw",
    executablePath: "acqtool" & (when defined(windows): ".exe" else: ""),
    packageId: "acqtool@1.0.0", cpu: "any", os: "any",
    lockIdentity: "fixture:acqtool@1.0.0:" & sha256)]

proc hostCurl(): string =
  ## The same resolution order as `downloadUrlToFile`'s, so the precondition
  ## probe below exercises the binary the code under test spawns.
  for candidate in ["/usr/bin/curl", "/bin/curl"]:
    if fileExists(candidate):
      return candidate
  findExe("curl")

const LoaderVars = ["LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT", "LD_DEBUG",
  "LD_DEBUG_OUTPUT", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH",
  "DYLD_INSERT_LIBRARIES", "REPRO_CACHE_DISABLE", "NO_PROXY", "no_proxy"]

template withEnv(vars: openArray[(string, string)]; body: untyped) =
  var saved: seq[(string, bool, string)] = @[]
  for name in LoaderVars:
    saved.add((name, existsEnv(name), getEnv(name)))
  # No shared cache, and no proxy between curl and the loopback fixture.
  putEnv("REPRO_CACHE_DISABLE", "1")
  putEnv("NO_PROXY", "127.0.0.1")
  putEnv("no_proxy", "127.0.0.1")
  for (name, value) in vars:
    putEnv(name, value)
  try:
    body
  finally:
    for (name, present, value) in saved:
      if present: putEnv(name, value)
      else: delEnv(name)

proc poisonedLibDir(root: string): string =
  ## A directory whose `libcurl.so.4` (and macOS `libcurl.4.dylib`) is a
  ## zero-byte file: any curl that searches it dies in the loader.
  result = root / "poison-lib"
  createDir(result)
  writeFile(result / "libcurl.so.4", "")
  writeFile(result / "libcurl.4.dylib", "")

proc runInheriting(exe: string; args: openArray[string]):
    tuple[output: string; exitCode: int] =
  ## Spawn with this process's environment intact -- what the downloader got
  ## before the fix.
  let process = startProcess(exe, args = args,
    options = {poStdErrToStdOut})
  result.output = process.outputStream().readAll()
  result.exitCode = waitForExit(process)
  close(process)

suite "tool acquisition does not inherit the caller's loader environment":

  test "the host downloader runs with its own libraries, not the caller's":
    let fixture = startFixture("acq-loader-path-")
    defer: stop(fixture)
    let poison = poisonedLibDir(fixture.root)
    let curl = hostCurl()
    check curl.len > 0
    withEnv({"LD_LIBRARY_PATH": poison, "DYLD_LIBRARY_PATH": poison,
             "DYLD_FALLBACK_LIBRARY_PATH": poison,
             "LD_PRELOAD": poison / "libcurl.so.4"}):
      when defined(linux):
        # Precondition: inherited, this poison kills the host curl in the
        # loader. Without it the assertion below would prove nothing.
        let inherited = runInheriting(curl, ["--version"])
        check inherited.exitCode != 0
        check "libcurl.so.4" in inherited.output
      let profile = resolveTarballTool(
        rawUse(fixture.baseUrl & PayloadRoute, fixture.sha256),
        fixture.root / "store")
      check profile.installMethod == "tarball"
      check fileExists(profile.resolvedExecutablePath)
      check readFile(profile.resolvedExecutablePath) ==
        readFile(fixture.payload)

  test "the loader's tracing variables do not reach the host downloader":
    ## `LD_DEBUG` + `LD_DEBUG_OUTPUT` make the glibc loader of any child that
    ## inherits them write a trace to `<LD_DEBUG_OUTPUT>.<pid>`. That trace is
    ## the observation: after a real acquisition, no trace may name libcurl.
    ## `LD_AUDIT` rides along as the injected-object sibling of `LD_PRELOAD`.
    let fixture = startFixture("acq-loader-trace-")
    defer: stop(fixture)
    let traceDir = fixture.root / "ld-trace"
    createDir(traceDir)
    let tracePrefix = traceDir / "trace"
    let curl = hostCurl()
    check curl.len > 0

    proc tracesNamingLibcurl(): int =
      for kind, path in walkDir(traceDir):
        if kind == pcFile and "libcurl" in readFile(path):
          inc result

    withEnv({"LD_DEBUG": "libs", "LD_DEBUG_OUTPUT": tracePrefix,
             "LD_AUDIT": fixture.root / "no-such-audit.so"}):
      when defined(linux):
        # Precondition: inherited, these variables DO make the host curl
        # write a trace naming libcurl.
        discard runInheriting(curl, ["--version"])
        check tracesNamingLibcurl() > 0
        removeDir(traceDir)
        createDir(traceDir)
      let profile = resolveTarballTool(
        rawUse(fixture.baseUrl & PayloadRoute, fixture.sha256),
        fixture.root / "store")
      check profile.installMethod == "tarball"
    check tracesNamingLibcurl() == 0

  test "a failing downloader's own diagnostic and exit status reach the error":
    ## The second half of the incident: with `poParentStreams` the child's
    ## diagnostic went to the terminal and the exception named only the URL.
    ## A 404 from the fixture makes the real curl fail with `--fail
    ## --show-error`; its stderr line and its exit status must both be in
    ## what `resolveTarballTool` raises.
    let fixture = startFixture("acq-diagnostic-")
    defer: stop(fixture)
    let missingUrl = fixture.baseUrl & "/no-such-archive"
    var raised = ""
    withEnv(newSeq[(string, string)]()):
      try:
        discard resolveTarballTool(rawUse(missingUrl, fixture.sha256),
          fixture.root / "store")
      except CatchableError as err:
        raised = err.msg
    # Still names the aggregate failure and the URL...
    check "all tarball archive URLs failed" in raised
    check missingUrl in raised
    # ...and now the cause: curl's exit status (22 is `--fail` on an HTTP
    # error) and its own words, which name the status it was given.
    check "exit 22" in raised
    check "404" in raised
