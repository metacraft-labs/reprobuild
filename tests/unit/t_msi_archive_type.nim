## ``archiveType = "msi"`` — realizing a Windows Installer database without
## installing it.
##
## An MSI was the one upstream distribution shape reprobuild could not touch.
## The archive tools do not read it, and the obvious way to get the files out
## is to INSTALL it — which registers services, writes the registry, and in
## the motivating case loads a kernel driver. None of that belongs in a
## content-addressed prefix.
##
## ``msiexec /a <msi> /qn TARGETDIR=<dir>`` is the way through: an
## ADMINISTRATIVE install writes files and nothing else, and needs no
## elevation. What these cases pin is that the arm does that and only that.
##
## The fixture is WinFsp's own pinned MSI, served over ``file://`` from a
## local copy, because the realize path under test is the same one the
## ``winfsp`` package uses and a synthetic MSI would need WiX to build. The
## test SKIPS rather than fails when that copy is absent: it is downloaded by
## the case below only if a network is there, and a unit suite must not
## depend on one.

import std/[os, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_test_support
import repro_tool_profiles

const
  WinFspMsiName = "winfsp-2.1.25156.msi"
  WinFspMsiSha256 =
    "073a70e00f77423e34bed98b86e600def93393ba5822204fac57a29324db9f7a"

proc msiUse(url, sha256, executablePath, selector: string): InterfaceToolUse =
  result = InterfaceToolUse(
    rawConstraint: "msifixture",
    packageSelector: selector,
    executableName: "fsptool-x64",
    location: SourceLocation(file: "fixture", line: 1))
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    packageName: "msifixture",
    url: url,
    sha256: "sha256:" & sha256,
    archiveType: "msi",
    executablePath: executablePath,
    stripComponents: 0,
    packageId: selector,
    lockIdentity: "sha256:" & sha256,
    location: SourceLocation(file: "fixture", line: 2))]

proc localMsi(): string =
  ## A copy beside the test's own scratch, if a previous run or an author
  ## put one there. Deliberately not fetched here.
  let candidates = [
    getEnv("REPRO_TEST_WINFSP_MSI"),
    getTempDir() / WinFspMsiName,
  ]
  for candidate in candidates:
    if candidate.len > 0 and fileExists(candidate):
      return candidate
  ""

suite "the msi archive type":
  putEnv("REPRO_CACHE_DISABLE", "1")

  test "an unknown archive type is still refused by name":
    # Guards the new arm's neighbour: adding a case must not turn an
    # unrecognised type into a silent no-op that yields an empty prefix.
    let tempRoot = createTempDir("repro-msi-", "")
    defer:
      try: removeDir(tempRoot) except CatchableError: discard
    let fake = tempRoot / "x.bogus"
    writeFile(fake, "payload")
    var message = ""
    try:
      let use = msiUse("file:///" & fake.replace('\\', '/').strip(
          leading = true, chars = {'/'}), WinFspMsiSha256, "x", "bogus@1")
      var bogus = use
      bogus.tarballProvisioning[0].archiveType = "bogus"
      discard resolveTarballTool(bogus, tempRoot / "store")
    except CatchableError as err:
      message = err.msg
    check message.len > 0
    check message.contains("bogus")

  test "an administrative install yields the payload, not an install":
    when not defined(windows):
      skip()
    else:
      let msi = localMsi()
      if msi.len == 0:
        # No local copy: the arm is still covered for real by the `winfsp`
        # package's own realize. Skipping beats a network dependency here.
        skip()
      else:
        let tempRoot = createTempDir("repro-msi-", "")
        defer:
          try: removeDir(tempRoot) except CatchableError: discard
        let url = "file:///" &
          msi.replace('\\', '/').strip(leading = true, chars = {'/'})
        let profile = resolveTarballTool(
          msiUse(url, WinFspMsiSha256,
            "DYNAMIC/SxS/DYNAMIC/bin/fsptool-x64.exe", "winfsp@2.1.25156"),
          tempRoot / "store")
        let prefix = profile.selectedStorePath
        check dirExists(prefix)
        # The payload at its LOGICAL hierarchy: a declared path deep inside
        # the tree resolves, which is what an administrative install buys
        # over a raw stream extraction.
        check fileExists(profile.resolvedExecutablePath)
        check fileExists(prefix / "DYNAMIC" / "inc" / "winfsp" / "winfsp.h")
        check fileExists(prefix / "DYNAMIC" / "lib" / "winfsp-x64.lib")
        # The .msi an administrative install copies beside the payload is
        # dropped: the prefix holds what a consumer asked for, not a second
        # copy of an archive the store already has.
        check (not fileExists(prefix / WinFspMsiName))
        check profile.installMethod == "tarball"
