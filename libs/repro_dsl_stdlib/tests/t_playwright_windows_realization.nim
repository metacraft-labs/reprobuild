## `playwright`'s Windows realization is playwright-core with the browsers it
## pins, laid out the way playwright-core looks for them.
##
## The gap: the package had only a nixpkgs arm, so a Windows recipe that
## declared `uses: "playwright"` had no realization, and a test suite that
## drives headless Chromium through playwright-core could not run there.
##
## The assertions follow the chain from the declaration to the launch:
##
##   * both Windows arms (x86_64 and, under x64 emulation, aarch64) are pinned
##     to one npm archive and hashed, and each lock identity carries the digest
##     and names its target;
##   * the selected arm's closure manifest resolves from the module that
##     declares it, and lists exactly the four browser builds playwright-core
##     1.56.1 pins for `win64`, each pinned by sha256, at the destination and
##     with the strip count the playwright-core layout requires;
##   * realizing archives with those member layouts through the arm's own
##     declaration yields a prefix that IS the playwright-core package
##     directory and whose `.local-browsers/` holds each browser executable at
##     the path playwright-core computes for it with
##     `PLAYWRIGHT_BROWSERS_PATH=0`.
##
## The realization is the real one (`resolveTarballTool`: the provisioning
## edge, the digest checks, host `tar` and the zip extractor, the store, the
## closure unpack). The archives are local fixtures with the member layouts
## of the pinned ones (listed 2026-11-12), served over `file://`, not the
## pinned URLs: those total 253 MB and need the network, and what is under
## test is the layout the declaration produces, which the members' contents
## do not change. The fixture manifest is the real manifest with each line's
## URL and digest replaced by the fixture's; its destinations, kinds and strip
## counts are read from the real file, so a change to them is what this
## tests.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_project_dsl
import repro_tool_profiles
import repro_dsl_stdlib/packages_schema
# Imported for its REGISTRATION side effect and its constants: `package
# playwright:` is what puts the catalog entry into the DSL registry that
# `playwrightPackage()` reads back.
import repro_dsl_stdlib/packages/playwright

const
  PinnedUrl =
    "https://registry.npmjs.org/playwright-core/-/playwright-core-1.56.1.tgz"
  PinnedSha256 =
    "fa648e5442796d4160c68dcfc3914ed5224f147852264993e6376e29f0228238"
    ## Measured 2026-11-12 by downloading `PinnedUrl`; its sha512 matches the
    ## registry's published `integrity` for 1.56.1.
  CdnRoot = "https://cdn.playwright.dev/dbazure/download/playwright/"
    ## `PLAYWRIGHT_CDN_MIRRORS[0]` in playwright-core 1.56.1.

type Browser = object
  ## One browser build, as playwright-core 1.56.1 names and places it.
  directory: string    ## `.local-browsers/<name, - as _>-<revision>`
  downloadPath: string ## `DOWNLOAD_PATHS[name]["win64"]` at the revision
  sha256: string       ## measured 2026-11-12 over the downloaded archive
  executable: string   ## `EXECUTABLE_PATHS[name].win`, below `directory`
  members: seq[string] ## the archive's members (listed 2026-11-12), trimmed

const Browsers = [
  # browsers.json: chromium 1194.
  Browser(directory: ".local-browsers/chromium-1194",
    downloadPath: "builds/chromium/1194/chromium-win64.zip",
    sha256: "bc65aed7bded748e267bd4d5d21f19459fa6e47464370a923fb6d87ebb22d7fb",
    executable: "chrome-win/chrome.exe",
    members: @["chrome-win/chrome.exe", "chrome-win/chrome.dll",
      "chrome-win/chrome_proxy.exe", "chrome-win/resources.pak"]),
  # browsers.json: chromium-headless-shell 1194. What `launch({ headless:
  # true })` starts.
  Browser(directory: ".local-browsers/chromium_headless_shell-1194",
    downloadPath: "builds/chromium/1194/chromium-headless-shell-win64.zip",
    sha256: "c745ef87016c69b11f461ca5eced32c69abcf1ae450e37b450585de9f446e103",
    executable: "chrome-win/headless_shell.exe",
    members: @["chrome-win/headless_shell.exe",
      "chrome-win/headless_lib_data.pak"]),
  # browsers.json: ffmpeg 1011.
  Browser(directory: ".local-browsers/ffmpeg-1011",
    downloadPath: "builds/ffmpeg/1011/ffmpeg-win64.zip",
    sha256: "8d08827c019ad36e7b9d49d3648447d884534cb2acf200e71c715f6dd834cc50",
    executable: "ffmpeg-win64.exe",
    members: @["ffmpeg-win64.exe", "COPYING.LGPLv2.1"]),
  # browsers.json: winldd 1007. Run before the first launch on x64 Windows.
  Browser(directory: ".local-browsers/winldd-1007",
    downloadPath: "builds/winldd/1007/winldd-win64.zip",
    sha256: "0069f0d11d4ad6df068a068c003d22fe7dbec192a47bba64b2e115e9c8ce41d8",
    executable: "PrintDeps.exe",
    members: @["PrintDeps.exe"]),
]

proc playwrightPackage(): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == "playwright":
      return pkg
  raise newException(ValueError,
    "the playwright catalog entry did not register a package")

proc windowsArms(): seq[TarballProvisioningDef] =
  for entry in playwrightPackage().tarballProvisioning:
    if entry.os.toLowerAscii == "windows":
      result.add(entry)

proc armRecord(arm: TarballProvisioningDef): InterfaceTarballProvisioning =
  ## The arm as the interface artifact carries it, declaring site included:
  ## the closure manifest resolves against that site's directory.
  InterfaceTarballProvisioning(packageName: "playwright", url: arm.url,
    sha256: arm.sha256, archiveType: arm.archiveType,
    executablePath: arm.executablePath, executableAlias: arm.executableAlias,
    prunePaths: arm.prunePaths, launcher: arm.launcher,
    closureManifest: arm.closureManifest, detail: arm.detail,
    stripComponents: arm.stripComponents, packageId: arm.packageId,
    lockIdentity: arm.lockIdentity, cpu: arm.cpu, os: arm.os,
    location: SourceLocation(file: arm.sourceFile, line: arm.sourceLine))

proc playwrightUse(records: seq[InterfaceTarballProvisioning]):
    InterfaceToolUse =
  InterfaceToolUse(rawConstraint: "playwright", packageSelector: "playwright",
    executableName: "playwright", tarballProvisioning: records)

type ManifestLine = object
  destination, sha256, url, archiveType, strip: string

proc manifestLines(path: string): seq[ManifestLine] =
  ## The five-field lines of a closure manifest:
  ## ``<destination> <sha256> <url> <archiveType> <stripComponents>``. The
  ## engine's own parser accepts the same file in the last case below.
  for raw in readFile(path).splitLines():
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let parts = line.splitWhitespace()
    doAssert parts.len == 5, "not a five-field closure line: " & line
    result.add(ManifestLine(destination: parts[0], sha256: parts[1],
      url: parts[2], archiveType: parts[3], strip: parts[4]))

proc selectedPlan(cpu: PlatformCpu): TarballAcquisitionPlan =
  let target = realizationTargetFor(cpu, poWindows)
  var records: seq[InterfaceTarballProvisioning] = @[]
  for arm in windowsArms():
    records.add(armRecord(arm))
  tarballAcquisitionPlan(playwrightUse(records), target = target)

proc realManifestPath(plan: TarballAcquisitionPlan): string =
  plan.closureManifestRoot / plan.declaredClosureManifest

proc writeFixtureFile(path, content: string) =
  createDir(path.parentDir)
  writeFile(path, content)

proc packDirectory(source, archive, kind: string) =
  ## Pack every top-level entry of `source`, by name (never `.`, which would
  ## add a component the declared strip count does not expect).
  var tops: seq[string] = @[]
  for kind, path in walkDir(source, relative = true):
    tops.add(quoteShell(path))
  let command =
    if kind == "zip":
      let zip = findExe("zip")
      doAssert zip.len > 0, "zip is required to build the fixture archives"
      quoteShell(zip) & " -q -r -X " & quoteShell(archive) & " " &
        tops.join(" ")
    else:
      let tar = findExe("tar")
      doAssert tar.len > 0, "tar is required to build the fixture archives"
      quoteShell(tar) & " -czf " & quoteShell(archive) & " " & tops.join(" ")
  let packed = execCmdEx(command, workingDir = source)
  doAssert packed.exitCode == 0, packed.output

proc fileUrl(path: string): string =
  "file://" & path

suite "playwright declares Windows arms with the browsers 1.56.1 pins":

  test "both Windows arms realize the playwright-core 1.56.1 npm archive":
    let arms = windowsArms()
    check arms.len == 2
    var cpus: seq[string] = @[]
    for arm in arms:
      checkpoint("cpu: " & arm.cpu)
      cpus.add(arm.cpu)
      check arm.url == PinnedUrl
      check arm.sha256 == PinnedSha256
      check arm.archiveType == "tar.gz"
      # npm's `package/` root goes, so the prefix IS the package directory.
      check arm.stripComponents == 1
      check arm.executablePath == "cli.js"
      check arm.executableAlias == "playwright-core"
      check arm.launcher == "node"
      check arm.closureManifest == PlaywrightWindowsClosureManifest
      check arm.detail.version == "1.56.1"
      # No `env`: projected into a home profile it would redirect every
      # other Playwright on the machine (module doc, "Layout").
      check arm.detail.env.len == 0
      check arm.lockIdentity == "tarball:playwright-core@1.56.1:windows-" &
        arm.cpu & ":sha256:" & PinnedSha256
    check cpus == @["x86_64", "aarch64"]

  test "the selected arm's manifest resolves and pins the four win64 builds":
    for cpu in [pcX86_64, pcAArch64]:
      let plan = selectedPlan(cpu)
      checkpoint("cpu: " & $cpu & ", lock identity: " & plan.lockIdentity)
      check plan.lockIdentity.contains(":windows-" &
        (if cpu == pcX86_64: "x86_64" else: "aarch64") & ":")
      check plan.declaredLauncher == "node"
      # Beside the module that declares it, which an installed reprobuild
      # ships with its sources.
      check plan.closureManifestRoot == windowsArms()[0].sourceFile.parentDir
      let manifest = realManifestPath(plan)
      checkpoint("manifest: " & manifest)
      check fileExists(manifest)
      let lines = manifestLines(manifest)
      check lines.len == Browsers.len
      for i, browser in Browsers:
        if i >= lines.len:
          break
        checkpoint("entry: " & browser.directory)
        check lines[i].destination == browser.directory
        check lines[i].url == CdnRoot & browser.downloadPath
        check lines[i].sha256 == browser.sha256
        # Each archive's members already sit below its directory where
        # playwright-core looks for them, so none strips a component.
        check lines[i].archiveType == "zip"
        check lines[i].strip == "0"

suite "the realized prefix is playwright-core with its browsers beside it":

  setup:
    let savedCache = getEnv("REPRO_CACHE_DISABLE")
    putEnv("REPRO_CACHE_DISABLE", "1")

  teardown:
    if savedCache.len > 0: putEnv("REPRO_CACHE_DISABLE", savedCache)
    else: delEnv("REPRO_CACHE_DISABLE")

  test "the prefix and PLAYWRIGHT_BROWSERS_PATH=0 find every build":
    let plan = selectedPlan(pcX86_64)
    let real = manifestLines(realManifestPath(plan))
    check real.len == Browsers.len
    let root = createTempDir("repro-playwright-windows-", "")
    defer: removeDir(root)

    # The npm archive: one `package/` root (as every npm archive has).
    let coreSource = root / "core-source"
    for name in ["package.json", "cli.js", "index.js", "browsers.json",
                 "lib/server/registry/index.js"]:
      writeFixtureFile(coreSource / "package" / name, "fixture " & name)
    let coreArchive = root / "playwright-core-fixture.tgz"
    packDirectory(coreSource, coreArchive, "tar.gz")

    # The browser archives, each with its pinned archive's member layout, and
    # the real manifest with only each line's URL and digest replaced.
    var manifest = "# fixture of " & plan.declaredClosureManifest & "\n"
    for i, line in real:
      let source = root / ("browser-source-" & $i)
      for member in Browsers[i].members:
        writeFixtureFile(source / member, "fixture " & member)
      let archive = root / ("browser-" & $i & ".zip")
      packDirectory(source, archive, line.archiveType)
      manifest.add(line.destination & " " & fileSha256Hex(archive) & " " &
        fileUrl(archive) & " " & line.archiveType & " " & line.strip & "\n")
    let fixtureManifest = root / "fixture.manifest"
    writeFile(fixtureManifest, manifest)

    # The arm's own layout declaration, on the local archives.
    var record = plan.record
    record.url = fileUrl(coreArchive)
    record.sha256 = fileSha256Hex(coreArchive)
    record.closureManifest = fixtureManifest
    record.cpu = "any"
    record.os = "any"
    record.packageId = "playwright-core-fixture@1.56.1"
    record.lockIdentity = "tarball:playwright-core-fixture@1.56.1:sha256:" &
      record.sha256
    let profile = resolveTarballTool(playwrightUse(@[record]), root / "store")
    let prefix = profile.selectedStorePath
    checkpoint("prefix: " & prefix)

    # `require(<prefix>)` loads the package, because
    # the prefix root is the package directory, not npm's `package/`.
    check fileExists(prefix / "package.json")
    check fileExists(prefix / "index.js")
    check fileExists(prefix / "browsers.json")
    check not dirExists(prefix / "package")
    check profile.resolvedExecutablePath == absolutePath(prefix / "cli.js")
    # The npm `bin`'s name, as a launcher pair running `node` on the script.
    check fileExists(prefix / "playwright-core.cmd")
    check "node \"%~dp0cli.js\"" in readFile(prefix / "playwright-core.cmd")

    # PLAYWRIGHT_BROWSERS_PATH=0: `<package>/.local-browsers/<dir>/<exe>`.
    for browser in Browsers:
      checkpoint("browser: " & browser.directory)
      check fileExists(prefix / browser.directory / browser.executable)
    check toSeq(walkDir(prefix / ".local-browsers", relative = true)).len ==
      Browsers.len

  test "the engine's closure parser accepts the real manifest before any fetch":
    # The realizer validates the whole manifest before it fetches anything
    # (``materializeTarballPrefix``). With the
    # real manifest and a primary archive that does not exist, the refusal
    # must be the missing archive: a manifest the parser refused would fail
    # first, naming the manifest, and nothing would be downloaded either way.
    let plan = selectedPlan(pcX86_64)
    let root = createTempDir("repro-playwright-windows-parse-", "")
    defer: removeDir(root)
    var record = plan.record
    record.url = fileUrl(root / "absent-playwright-core.tgz")
    record.closureManifest = realManifestPath(plan)
    record.cpu = "any"
    record.os = "any"
    var message = ""
    try:
      discard resolveTarballTool(playwrightUse(@[record]), root / "store")
    except CatchableError as err:
      message = err.msg
    checkpoint("refusal: " & message)
    check message.len > 0
    check "does not exist" in message
    check "closure" notin message
