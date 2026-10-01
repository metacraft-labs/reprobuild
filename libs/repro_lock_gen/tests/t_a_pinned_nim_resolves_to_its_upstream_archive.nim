## A store-sourced `nim` pin resolves, at LOCK time, to the official release
## archive for the lock's platform, and the lock records its URL and SHA-256.
##
## Reprobuild-specs Distribution-And-Packaging.milestones.org, M5 "pin the
## provider-compile toolchain": a pinned Nim of any released version is
## provisioned automatically, verified against a digest that is part of the
## pin, not trusted from the network at use time. `repro lock refresh` is
## where the network is consulted, through an ordinary `netFetch` edge of the
## generation wave (`mokUpstreamArchive`), and what it found is committed.
##
## THE PROPERTIES, EACH WITH THE DEFECT IT CATCHES:
##
##   * the archive chosen per platform: the Windows zip (x64 / x32), the
##     darwin archive where upstream publishes one and the source archive
##     where it does not, the source archive on Linux and every other
##     non-Windows platform, and nothing for a Windows CPU upstream does not
##     build for. Catches a route table that sends Linux to the static vendor
##     binary or macOS to a 404;
##   * the version is validated before it is spliced into a URL;
##   * a digest file must parse and must name the archive it is for;
##   * a generation with no registry configured still plans and runs the
##     upstream edge, and the lock entry carries the digest upstream
##     published. Catches the edge being gated on `endpoints`, which would
##     leave every real project (none configures a registry) unpinned;
##   * macOS falls back to the source archive when the darwin `.sha256` is
##     404, and takes the darwin archive once it is published;
##   * an unreleased version FAILS the generation, naming the version. Catches
##     a lock written with a pin no reprobuild can realize;
##   * a bare (definition-sourced) `nim` plans no upstream fetch and records
##     no archive. Catches every existing lock acquiring a network edge.
##
## Test-double policy: no mocks. The release tree is served by the REAL
## loopback HTTP listener the NLF tests use (`loopback_metadata_server`), and
## fetched by the real in-process client; only its CONTENT is fixture data.
## The digests below are therefore synthetic and are not claims about
## nim-lang.org; `tests/integration/t_a_pinned_nim_is_provisioned_from_a_
## cold_store` resolves against nim-lang.org itself.

import std/[os, strutils, tempfiles, unittest]

import repro_lock
import repro_lock_gen
import repro_solver

import ./loopback_metadata_server

const
  App = "app"
  ZipDigest = "1".repeat(64)
  SourceDigest = "2".repeat(64)
  DarwinDigest = "3".repeat(64)

proc workspace(version: string; source = "store"): seq[PackageDecl] =
  var nim = newPackage("nim", @[version])
  nim.source = source
  @[newPackage(App, @["0.1.0"], @[newDependency("nim", "==" & version)]), nim]

type Releases = object
  server: MetadataServer
  scratch: string
  generations: int

proc startReleases(): Releases =
  let scratch = createTempDir("repro-nim-releases-", "")
  Releases(server: startMetadataServer(scratch / "releases"),
    scratch: scratch)

proc stop(r: Releases) =
  r.server.stop()
  r.server.destroyMetadataServer()
  try: removeDir(r.scratch)
  except CatchableError: discard

proc publishDigest(r: Releases; fileName, digest: string;
                   namedFile = "") =
  ## `<fileName>.sha256`, as upstream writes it: `<hex>  <file>`.
  let named = if namedFile.len > 0: namedFile else: fileName
  r.server.publishAt(fileName & ".sha256", digest & "  " & named & "\n")

proc request(r: var Releases; packages: seq[PackageDecl];
             platform: string): LockGenerationRequest =
  inc r.generations
  LockGenerationRequest(
    packages: packages,
    inputsText: "upstream-archive fixture",
    platform: platform,
    strategy: lsDefault,
    endpoints: @[],
    workDir: r.scratch / ("gen-" & $r.generations),
    entryPoint: lgeLockSolve,
    nimReleaseBase: r.server.endpoint())

proc nimDep(r: LockGenerationResult): LockedDep =
  for d in parseLockedDependencies(r.lockDocument).deps:
    if d.name == "nim":
      return d
  raise newException(KeyError, "the lock has no nim dep:\n" & r.lockDocument)

suite "which archive upstream publishes for a version and platform":

  test "the candidates per platform":
    let base = "https://example.invalid/download"
    proc names(platform: string): seq[string] =
      for c in nimReleaseCandidates("2.2.8", platform, base):
        result.add(c.fileName & ":" & c.build)
    check names("amd64-windows") == @["nim-2.2.8_x64.zip:binary"]
    check names("i386-windows") == @["nim-2.2.8_x32.zip:binary"]
    check names("arm64-macosx") ==
      @["nim-2.2.8-macosx_arm64.tar.xz:binary", "nim-2.2.8.tar.xz:source"]
    check names("amd64-macosx") ==
      @["nim-2.2.8-macosx_x64.tar.xz:binary", "nim-2.2.8.tar.xz:source"]
    check names("amd64-linux") == @["nim-2.2.8.tar.xz:source"]
    check names("arm64-linux") == @["nim-2.2.8.tar.xz:source"]
    check names("amd64-freebsd") == @["nim-2.2.8.tar.xz:source"]
    check names("arm64-windows").len == 0
    let zip = nimReleaseCandidates("2.2.8", "amd64-windows", base)[0]
    check zip.url == base & "/nim-2.2.8_x64.zip"
    check zip.sha256Url == base & "/nim-2.2.8_x64.zip.sha256"
    check zip.archiveType == "zip"
    # The default base is the official one.
    check nimReleaseCandidates("2.0.16", "amd64-linux")[0].url ==
      "https://nim-lang.org/download/nim-2.0.16.tar.xz"

  test "a version is digits and dots before it reaches a URL":
    for bad in ["", "2.2.8/../../x", "2.2", ".2.2", "latest", "2.2.8 "]:
      if bad == "2.2":
        # Well-formed: whether upstream has it is the edge's question.
        check nimReleaseCandidates(bad, "amd64-linux").len == 1
        continue
      expect UpstreamArchiveError:
        discard nimReleaseCandidates(bad, "amd64-linux")
    expect UpstreamArchiveError:
      discard nimReleaseCandidates("2.2.8", "amd64")

  test "a digest file must parse and must name its own archive":
    check parseSha256File(ZipDigest & "  nim-2.2.8_x64.zip\n",
      "nim-2.2.8_x64.zip") == ZipDigest
    check parseSha256File(ZipDigest.toUpperAscii & " *nim-2.2.8_x64.zip",
      "nim-2.2.8_x64.zip") == ZipDigest
    check parseSha256File(ZipDigest, "nim-2.2.8_x64.zip") == ZipDigest
    expect UpstreamArchiveError:
      discard parseSha256File(ZipDigest & "  nim-2.2.6_x64.zip",
        "nim-2.2.8_x64.zip")
    expect UpstreamArchiveError:
      discard parseSha256File("not-a-digest  nim-2.2.8_x64.zip",
        "nim-2.2.8_x64.zip")
    expect UpstreamArchiveError:
      discard parseSha256File("", "nim-2.2.8_x64.zip")

suite "lock generation records the archive of the solved version":

  test "Windows: the x64 zip and its digest, with no registry configured":
    var r = startReleases()
    defer: r.stop()
    r.publishDigest("nim-2.2.8_x64.zip", ZipDigest)
    let req = r.request(workspace("2.2.8"), "amd64-windows")
    var upstream = 0
    for entry in req.fetchPlan():
      check entry.kind == mokUpstreamArchive
      check entry.subject == "nim@2.2.8"
      inc upstream
    check upstream == 1
    let served = r.server.requestsServed()
    let gen = runLockSolve(req, "")
    check r.server.requestsServed() > served
    check gen.fetchWaves.len == 1
    let dep = gen.nimDep()
    check dep.coordinates.kind == ckStore
    check dep.version == "2.2.8"
    check dep.archive.url == r.server.endpoint() & "/nim-2.2.8_x64.zip"
    check dep.archive.sha256 == ZipDigest
    check dep.archive.archiveType == "zip"
    check dep.archive.build == LockedArchiveBinary
    # Written where `repro lock refresh` would write it, and read back.
    let lockPath = r.scratch / "repro.lock"
    let written = runLockRefresh(r.request(workspace("2.2.8"),
      "amd64-windows"), lockPath)
    check readFile(lockPath) == written.lockDocument
    check readFile(lockPath).contains("archive_sha256 = \"" & ZipDigest & "\"")

  test "Linux: the source archive":
    var r = startReleases()
    defer: r.stop()
    r.publishDigest("nim-2.0.16.tar.xz", SourceDigest)
    # The static vendor binary is published too, and must not be chosen.
    r.publishDigest("nim-2.0.16-linux_x64.tar.xz", ZipDigest)
    let dep = runLockSolve(r.request(workspace("2.0.16"), "amd64-linux"),
      "").nimDep()
    check dep.archive.url == r.server.endpoint() & "/nim-2.0.16.tar.xz"
    check dep.archive.sha256 == SourceDigest
    check dep.archive.build == LockedArchiveSource
    check dep.archive.archiveType == "tar.xz"

  test "macOS: the source archive until a darwin archive is published":
    var r = startReleases()
    defer: r.stop()
    r.publishDigest("nim-2.2.6.tar.xz", SourceDigest)
    let before = runLockSolve(r.request(workspace("2.2.6"), "arm64-macosx"),
      "").nimDep()
    check before.archive.build == LockedArchiveSource
    check before.archive.sha256 == SourceDigest
    r.publishDigest("nim-2.2.6-macosx_arm64.tar.xz", DarwinDigest)
    let after = runLockSolve(r.request(workspace("2.2.6"), "arm64-macosx"),
      "").nimDep()
    check after.archive.build == LockedArchiveBinary
    check after.archive.sha256 == DarwinDigest
    check after.archive.url.endsWith("/nim-2.2.6-macosx_arm64.tar.xz")

  test "an unreleased version fails the generation, naming it":
    var r = startReleases()
    defer: r.stop()
    r.publishDigest("nim-2.2.8_x64.zip", ZipDigest)
    var message = ""
    try:
      discard runLockSolve(r.request(workspace("2.2.9"), "amd64-windows"), "")
    except CatchableError as err:
      message = err.msg
    checkpoint(message)
    check message.contains("nim 2.2.9 has no release archive for " &
      "amd64-windows")
    check message.contains("Is 2.2.9 a released Nim version?")

  test "a digest file naming another archive fails the generation":
    var r = startReleases()
    defer: r.stop()
    r.publishDigest("nim-2.2.8_x64.zip", ZipDigest, "nim-2.2.6_x64.zip")
    var message = ""
    try:
      discard runLockSolve(r.request(workspace("2.2.8"), "amd64-windows"), "")
    except CatchableError as err:
      message = err.msg
    checkpoint(message)
    check message.contains("names nim-2.2.6_x64.zip")

  test "a platform upstream does not build for gets no archive, and no edge":
    var r = startReleases()
    defer: r.stop()
    let req = r.request(workspace("2.2.8"), "arm64-windows")
    check req.fetchPlan().len == 0
    let dep = runLockSolve(req, "").nimDep()
    check dep.coordinates.kind == ckStore
    check not dep.archive.isPinned

suite "only a store pin consults upstream":

  test "a bare nim entry plans no upstream fetch and records no archive":
    var r = startReleases()
    defer: r.stop()
    r.publishDigest("nim-2.2.8_x64.zip", ZipDigest)
    let req = r.request(workspace("2.2.8", source = "nim"), "amd64-windows")
    check req.fetchPlan().len == 0
    let served = r.server.requestsServed()
    let gen = runLockSolve(req, "")
    check r.server.requestsServed() == served
    check not gen.lockDocument.contains("archive_")
