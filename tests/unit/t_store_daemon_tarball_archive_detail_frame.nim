## The store daemon's tarball realize frame carries the selected record's
## whole archive detail (``TarballArchiveDetail``).
##
## The daemon rebuilds the tarball record from the frame alone and runs the
## same selection and realization on it that the client would run
## in-process. A field of the record that does not cross the socket does not
## fail: it realizes a DIFFERENT record. A record pinned only by SHA-512
## arrives with no digest at all, and a record with an installer feature
## (``extractPath``, ``installMethod`` ...) arrives as a plain archive and is
## extracted into a different prefix. The end-to-end consequence is asserted
## by ``tests/integration/t_integration_daemon_nix_and_tarball_realize.nim``;
## this file pins the frame itself, which needs no daemon.
##
## No mocks: the frame codec and the client's request builder are the real
## ones.

import std/[os, strutils, unittest]

import repro_interface_artifacts
import repro_store_daemon/client as daemonClient
import repro_store_daemon/protocol as daemonProtocol

proc everyFieldDetail(): TarballArchiveDetail =
  ## A detail with every field set to a value distinct from its neighbours,
  ## so a field read into the wrong slot cannot go unnoticed.
  TarballArchiveDetail(
    version: "21.0.5",
    sha512: "sha512:" & repeat("5", 128),
    sha1: "sha1:" & repeat("1", 40),
    installMethod: "installer-silent",
    extractPath: "inner/dir",
    extraExecutables: @["bin/extra-a", "bin/extra-b"],
    installerArgs: @["/S", "/D=${prefix}"],
    pacmanPackages: @["mingw-w64-x86_64-gcc"],
    bootstrapArgv: @["./bootstrap.sh", "--prefix=${prefix}"],
    env: @["JAVA_HOME=${prefix}"],
    nested7z: true,
    msiAdminInstall: true,
    preInstall: @["pre-install-action"],
    preInstallUnrecognized: @["unknown-action"],
    launcherEmit: @["launcher-spec"],
    cpuLevel: "x86-64-v2",
    cpuFeatures: "avx2,bmi2",
    appBundle: "Tool.app",
    bundleId: "org.example.tool",
    teamId: "ABCDE12345",
    installerApp: "Tool Installer.app")

proc requestCarrying(detail: TarballArchiveDetail):
    StoreDaemonExternalRealizeRequest =
  StoreDaemonExternalRealizeRequest(
    storeRoot: "/store",
    tarballUrl: "https://example.invalid/tool.tar.gz",
    archiveType: "tar.gz",
    declaredExecutablePath: "bin/tool",
    closureManifest: "closure.txt",
    archiveDetail: detail,
    stripComponents: 3)

proc toolUse(record: InterfaceTarballProvisioning): InterfaceToolUse =
  result = InterfaceToolUse(
    rawConstraint: "tool",
    packageSelector: "tool",
    executableName: "tool",
    location: SourceLocation(file: "fixture", line: 1))
  result.tarballProvisioning = @[record]

proc plainRecord(): InterfaceTarballProvisioning =
  InterfaceTarballProvisioning(
    packageName: "tool",
    url: "https://example.invalid/tool.tar.gz",
    sha256: "sha256:" & repeat("ab", 32),
    archiveType: "tar.gz",
    executablePath: "bin/tool",
    location: SourceLocation(file: "fixture", line: 2))

suite "the store daemon tarball frame carries the archive detail":
  test "every detail field survives the frame round trip":
    let detail = everyFieldDetail()
    let restored = parseExternalRealizeBody(
      externalRealizeBody(requestCarrying(detail)))
    check restored.archiveDetail == detail

  test "the fields around the detail still land where they belong":
    # The frame is positional: a width mistake in the detail corrupts the
    # field AFTER it, so that is the one to read back.
    let restored = parseExternalRealizeBody(
      externalRealizeBody(requestCarrying(everyFieldDetail())))
    check restored.stripComponents == 3
    check restored.closureManifest == "closure.txt"
    check restored.declaredExecutablePath == "bin/tool"

  test "an all-empty detail round-trips as the plain archive it is":
    let restored = parseExternalRealizeBody(
      externalRealizeBody(requestCarrying(TarballArchiveDetail())))
    check restored.archiveDetail == TarballArchiveDetail()
    check restored.stripComponents == 3

  test "a detail newer than this build is refused, not misread":
    # The detail's codec is versioned with the interface artifact, not with
    # the daemon frame, so it carries its own tag. A tag above what this
    # build reads must stop the parse rather than shift every later field.
    var body = externalRealizeBody(requestCarrying(everyFieldDetail()))
    var tagged: seq[byte] = @[]
    tagged.writeTaggedTarballArchiveDetail(everyFieldDetail())
    let tagOffset = body.len - 4 - tagged.len
    let newer = interfaceEnvelopeVersion() + 1
    body[tagOffset] = byte(newer and 0xff)
    body[tagOffset + 1] = byte(newer shr 8)
    expect ValueError:
      discard parseExternalRealizeBody(body)

  test "the client sends the selected record's SHA-512 pin":
    # The client's plan keeps ``sha256`` only for a SHA-256 pin; a record
    # pinned only by SHA-512 reaches the daemon through the detail.
    var record = plainRecord()
    record.sha256 = ""
    record.detail.sha512 = "sha512:" & repeat("cd", 64)
    let request = requestFromTarballUse(toolUse(record), "/store", "holder",
      "root")
    check request.tarballSha256 == ""
    check request.archiveDetail.sha512 == record.detail.sha512
    let restored = parseExternalRealizeBody(externalRealizeBody(request))
    check restored.archiveDetail.sha512 == record.detail.sha512

  test "the client sends the selected record's installer fields":
    var record = plainRecord()
    record.detail.version = "1.0.0"
    record.detail.extractPath = "tool-1.0.0"
    record.detail.extraExecutables = @["bin/tool-helper"]
    let request = requestFromTarballUse(toolUse(record), "/store", "holder",
      "root")
    check request.archiveDetail == record.detail

  test "the client sends a relative closure manifest resolved":
    # The daemon rebuilds the record without its declaring file and runs in a
    # working directory of its own, so a manifest declared relative to that
    # file must cross the socket already resolved against it.
    var record = plainRecord()
    record.closureManifest = "closure.manifest"
    record.location = SourceLocation(file: "/work/pkg/repro.nim", line: 2)
    let request = requestFromTarballUse(toolUse(record), "/store", "holder",
      "root")
    check request.closureManifest == "/work/pkg" / "closure.manifest"
    let restored = parseExternalRealizeBody(externalRealizeBody(request))
    check restored.closureManifest == request.closureManifest

  test "with no declaring file it resolves against the client's directory":
    # As the in-process realize opens it: relative to this process's
    # working directory, never the daemon's.
    var record = plainRecord()
    record.closureManifest = "closure.manifest"
    record.location = SourceLocation()
    let request = requestFromTarballUse(toolUse(record), "/store", "holder",
      "root")
    check request.closureManifest == getCurrentDir() / "closure.manifest"

  test "an absolute closure manifest and an absent one cross unchanged":
    var record = plainRecord()
    record.closureManifest = "/elsewhere/closure.manifest"
    check requestFromTarballUse(toolUse(record), "/store", "holder",
      "root").closureManifest == "/elsewhere/closure.manifest"
    check requestFromTarballUse(toolUse(plainRecord()), "/store", "holder",
      "root").closureManifest == ""
