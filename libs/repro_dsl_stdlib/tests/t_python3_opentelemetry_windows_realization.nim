## `python3-opentelemetry`'s Windows realization is the embeddable CPython
## whose own search-path file names the six OpenTelemetry wheels unpacked
## beside it.
##
## The gap: a test whose backend traces with the real OpenTelemetry Python SDK
## had a Python only from nixpkgs, so on Windows it could not run at all. The
## arms combine three mechanisms the catalog already has, and this file checks
## each link of that chain rather than assuming the combination works:
##
##   * both Windows arms are pinned to python.org's embeddable CPython 3.12.10
##     and hashed, carry the closure manifest, and carry exactly one
##     `preInstall` `set-content` of `python312._pth`;
##   * the manifest resolves from the module that declares it and pins the six
##     wheels at the destinations the `._pth` names;
##   * the `set-content` text spans several lines, and it survives the
##     interface artifact: the arm lifted into a `ProjectInterface`, encoded
##     and decoded by the real codec, still decodes to the same text (and to
##     the six inlined closure entries) — a published record is all a
##     consumer without the stdlib sources realizes from;
##   * realizing that DECODED record — `preInstall` and the closure manifest
##     in one record — yields a prefix whose `python312._pth` is the rewritten
##     one, with every wheel's tree in the directory it names, and the
##     interpreter at the declared path.
##
## The realization is the real one (`resolveTarballTool`: the provisioning
## edge, the digest checks, the zip extractor, the installation staging that
## replays `preInstall`, the closure unpack, the store). The archives are
## local fixtures with the member layouts of the pinned ones, served over
## `file://`, not the pinned URLs: those need the network, and what is under
## test is the layout the declaration produces, which the members' contents
## do not change. The fixture closure keeps the real destinations, kinds and
## strip counts and replaces each line's URL and digest. That the realized
## search path imports the real SDK is measured outside this suite, with the
## pinned wheels, on Linux and on Windows; it needs both the network and a
## Windows host.

import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_project_dsl
import repro_tool_profiles
import repro_dsl_stdlib/packages_schema
# Imported for its REGISTRATION side effect and its constants: `package
# python3-opentelemetry:` is what puts the catalog entry into the DSL
# registry that `otelPackage()` reads back.
import repro_dsl_stdlib/packages/python3_opentelemetry

const
  PackageName = "python3-opentelemetry"
  PythonOrg = "https://www.python.org/ftp/python/3.12.10/"
  ShippedPth =
    "python312.zip\r\n.\r\n\r\n# Uncomment to run site.main() automatically" &
    "\r\n#import site\r\n"
    ## `python312._pth` exactly as both pinned embeddable zips ship it (read
    ## from the downloaded archives 2026-11-20). The fixture carries it so
    ## the test sees the rewrite REPLACE a file, as it does in the real
    ## archive.

type Wheel = object
  ## One pinned wheel, as the manifest places it.
  directory: string    ## the manifest destination, a `._pth` line
  file: string         ## the wheel's file name on PyPI
  sha256: string       ## PyPI's published digest, checked 2026-11-20
  members: seq[string] ## the wheel's top-level members, trimmed

const Wheels = [
  Wheel(directory: "site/opentelemetry_sdk",
    file: "opentelemetry_sdk-1.34.0-py3-none-any.whl",
    sha256: "7850bcd5b5c95f9aae48603d6592bdad5c7bdef50c03e06393f8f457d891fe32",
    members: @["opentelemetry/sdk/__init__.py",
      "opentelemetry_sdk-1.34.0.dist-info/METADATA"]),
  Wheel(directory: "site/opentelemetry_api",
    file: "opentelemetry_api-1.34.0-py3-none-any.whl",
    sha256: "390b81984affe4453180820ca518de55e3be051111e70cc241bb3b0071ca3a2c",
    members: @["opentelemetry/trace/__init__.py",
      "opentelemetry_api-1.34.0.dist-info/entry_points.txt"]),
  Wheel(directory: "site/opentelemetry_semantic_conventions",
    file: "opentelemetry_semantic_conventions-0.55b0-py3-none-any.whl",
    sha256: "63bb15b67377700e51c422d0d24092ca6ce9f3a4cb6f032375aa8af1fc2aab65",
    members: @["opentelemetry/semconv/__init__.py",
      "opentelemetry_semantic_conventions-0.55b0.dist-info/METADATA"]),
  Wheel(directory: "site/typing_extensions",
    file: "typing_extensions-4.15.0-py3-none-any.whl",
    sha256: "f0fa19c6845758ab08074a0cfa8b7aecb71c999ca73d62883bc25cc018c4e548",
    members: @["typing_extensions.py",
      "typing_extensions-4.15.0.dist-info/METADATA"]),
  Wheel(directory: "site/importlib_metadata",
    file: "importlib_metadata-8.7.0-py3-none-any.whl",
    sha256: "e5dd1551894c77868a30651cef00984d50e1002d06942a7101d34870c5f02afd",
    members: @["importlib_metadata/__init__.py",
      "importlib_metadata-8.7.0.dist-info/METADATA"]),
  Wheel(directory: "site/zipp",
    file: "zipp-3.23.0-py3-none-any.whl",
    sha256: "071652d6115ed432f5ce1d34c336c0adfd6a884660d1e9712a256d3d3bd4b14e",
    members: @["zipp/__init__.py", "zipp-3.23.0.dist-info/METADATA"]),
]

proc otelPackage(): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == PackageName:
      return pkg
  raise newException(ValueError,
    "the python3-opentelemetry catalog entry did not register a package")

proc windowsArms(): seq[TarballProvisioningDef] =
  for entry in otelPackage().tarballProvisioning:
    if entry.os.toLowerAscii == "windows":
      result.add(entry)

proc otelUse(records: seq[InterfaceTarballProvisioning] = @[]):
    InterfaceToolUse =
  InterfaceToolUse(rawConstraint: PackageName, packageSelector: PackageName,
    executableName: "python3", tarballProvisioning: records)

proc publishedWindowsRecords(): seq[InterfaceTarballProvisioning] =
  ## The Windows arms as a consumer reads them from a published interface:
  ## lifted by the real `toProjectInterface`, then through the real
  ## `encodeInterfacePayload` / `decodeInterfacePayload` pair.
  let consumer = PackageDef(packageName: "consumer",
    toolUses: @[PackageUseDef(rawConstraint: PackageName,
      packageSelector: PackageName, executableName: "python3")])
  let decoded = decodeInterfacePayload(encodeInterfacePayload(
    toProjectInterface(consumer, [otelPackage()])))
  doAssert decoded.toolUses.len == 1, "fixture drift: one tool use expected"
  for record in decoded.toolUses[0].tarballProvisioning:
    if record.os.toLowerAscii == "windows":
      result.add(record)

proc manifestFields(text: string): seq[seq[string]] =
  for raw in text.splitLines():
    let line = raw.strip()
    if line.len > 0 and not line.startsWith("#"):
      result.add(line.splitWhitespace())

proc writeFixtureFile(path, content: string) =
  createDir(path.parentDir)
  writeFile(path, content)

proc packZip(source, archive: string) =
  ## Pack every top-level entry of `source` by name, the layout a wheel and
  ## the embeddable zip have (no wrapping directory).
  var tops: seq[string] = @[]
  for kind, path in walkDir(source, relative = true):
    tops.add(quoteShell(path))
  let zip = findExe("zip")
  doAssert zip.len > 0, "zip is required to build the fixture archives"
  let packed = execCmdEx(quoteShell(zip) & " -q -r -X " & quoteShell(archive) &
    " " & tops.join(" "), workingDir = source)
  doAssert packed.exitCode == 0, packed.output

proc fileUrl(path: string): string =
  "file://" & path

suite "python3-opentelemetry declares Windows arms with the pinned wheels":

  test "both arms realize the 3.12.10 embeddable CPython for their CPU":
    let arms = windowsArms()
    check arms.len == 2
    var cpus: seq[string] = @[]
    for arm in arms:
      checkpoint("cpu: " & arm.cpu)
      cpus.add(arm.cpu)
      let (suffix, digest) =
        if arm.cpu == "x86_64": ("amd64", PythonEmbedAmd64Sha256)
        else: ("arm64", PythonEmbedArm64Sha256)
      check arm.url == PythonOrg & "python-3.12.10-embed-" & suffix & ".zip"
      check arm.sha256 == digest
      check arm.archiveType == "zip"
      check arm.stripComponents == 0
      check arm.executablePath == "python.exe"
      check arm.executableAlias == "python3.exe"
      check arm.closureManifest == PythonOpenTelemetryWindowsClosureManifest
      check arm.detail.version == "1.34.0"
      check arm.detail.env.len == 0
      check arm.lockIdentity == "tarball:python3-opentelemetry@1.34.0:" &
        "windows-" & arm.cpu & ":sha256:" & digest
      # Exactly one pre-install step: the search path.
      check arm.detail.preInstall.len == 1
      if arm.detail.preInstall.len == 1:
        let action = decodePreInstallAction(arm.detail.preInstall[0])
        check action.kind == piaSetContent
        check action.target == "$dir/python312._pth"
        check action.literal == pythonOpenTelemetryPth()
    check cpus == @["x86_64", "aarch64"]
    # The x86_64 interpreter is the one `python3` pins.
    check PythonEmbedAmd64Sha256 ==
      "4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3"

  test "the search path names the shipped entries and each wheel directory":
    let lines = pythonOpenTelemetryPth().splitLines().filterIt(it.len > 0)
    check lines == @["python312.zip", "."] &
      PythonOpenTelemetryWheelDirs.toSeq
    check lines.len == 8
    # `site` stays off, as in the shipped file.
    check "import site" notin pythonOpenTelemetryPth()

  test "the manifest resolves beside the module and pins the six wheels":
    let arm = windowsArms()[0]
    let manifest = arm.sourceFile.parentDir / arm.closureManifest
    checkpoint("manifest: " & manifest)
    check fileExists(manifest)
    let lines = manifestFields(readFile(manifest))
    check lines.len == Wheels.len
    for i, wheel in Wheels:
      if i >= lines.len:
        break
      checkpoint("wheel: " & wheel.file)
      check lines[i].len == 5
      check lines[i][0] == wheel.directory
      check lines[i][0] == PythonOpenTelemetryWheelDirs[i]
      check lines[i][1] == wheel.sha256
      check lines[i][2].startsWith("https://files.pythonhosted.org/packages/")
      check lines[i][2].endsWith("/" & wheel.file)
      # A wheel's top level is what a `sys.path` directory needs.
      check lines[i][3] == "zip"
      check lines[i][4] == "0"

suite "the published record carries the search path and the closure":

  test "the multi-line set-content survives the interface codec":
    let records = publishedWindowsRecords()
    check records.len == 2
    for record in records:
      checkpoint("cpu: " & record.cpu)
      check record.detail.preInstall.len == 1
      if record.detail.preInstall.len == 1:
        let action = decodePreInstallAction(record.detail.preInstall[0])
        check action.kind == piaSetContent
        check action.target == "$dir/python312._pth"
        # Byte for byte, newlines included.
        check action.literal == pythonOpenTelemetryPth()
        check action.literal.count('\n') == 8
      # The closure travels inlined, so the consumer needs no manifest file.
      check record.closureEntries.len == Wheels.len
      for i, entry in record.closureEntries:
        if i < Wheels.len:
          check entry.path == Wheels[i].directory
          check entry.sha256 == Wheels[i].sha256
          check entry.archiveType == "zip"
          check entry.stripComponents == 0

suite "the realized prefix is the interpreter with its search path rewritten":

  setup:
    let savedCache = getEnv("REPRO_CACHE_DISABLE")
    putEnv("REPRO_CACHE_DISABLE", "1")

  teardown:
    if savedCache.len > 0: putEnv("REPRO_CACHE_DISABLE", savedCache)
    else: delEnv("REPRO_CACHE_DISABLE")

  test "preInstall and the closure apply together to the decoded record":
    let root = createTempDir("repro-python3-otel-windows-", "")
    defer: removeDir(root)

    # The embeddable zip: the interpreter, the standard library archive and
    # the shipped `._pth`, at the archive's top level.
    let embedSource = root / "embed-source"
    writeFixtureFile(embedSource / "python.exe", "fixture python.exe")
    setFilePermissions(embedSource / "python.exe",
      {fpUserRead, fpUserWrite, fpUserExec})
    writeFixtureFile(embedSource / "python312.zip", "fixture stdlib")
    writeFixtureFile(embedSource / "python312.dll", "fixture dll")
    writeFixtureFile(embedSource / "python312._pth", ShippedPth)
    let embedArchive = root / "python-embed-fixture.zip"
    packZip(embedSource, embedArchive)

    # The wheels, each with its pinned wheel's top-level layout, and the
    # published record's closure with only each line's URL and digest
    # replaced.
    var record = publishedWindowsRecords()[0]
    check record.closureEntries.len == Wheels.len
    for i, wheel in Wheels:
      if i >= record.closureEntries.len:
        break
      let source = root / ("wheel-source-" & $i)
      for member in wheel.members:
        writeFixtureFile(source / member, "fixture " & member)
      let archive = root / ("wheel-" & $i & ".whl")
      packZip(source, archive)
      record.closureEntries[i].sha256 = fileSha256Hex(archive)
      record.closureEntries[i].url = fileUrl(archive)
    record.closureManifest = ""
    record.url = fileUrl(embedArchive)
    record.sha256 = fileSha256Hex(embedArchive)
    record.cpu = "any"
    record.os = "any"
    record.packageId = "python3-opentelemetry-fixture@1.34.0"
    record.lockIdentity = "tarball:python3-opentelemetry-fixture@1.34.0:" &
      "sha256:" & record.sha256

    let profile = resolveTarballTool(otelUse(@[record]), root / "store")
    let prefix = profile.selectedStorePath
    checkpoint("prefix: " & prefix)

    check profile.resolvedExecutablePath ==
      absolutePath(prefix / "python.exe")
    check fileExists(prefix / "python312.zip")
    # The preInstall step replaced the shipped search path...
    check readFile(prefix / "python312._pth") == pythonOpenTelemetryPth()
    # ...and every directory it names holds that wheel's tree, unpacked by
    # the closure into the same prefix.
    for i, wheel in Wheels:
      checkpoint("wheel: " & wheel.directory)
      check dirExists(prefix / wheel.directory)
      for member in wheel.members:
        check fileExists(prefix / wheel.directory / member)
    check toSeq(walkDir(prefix / "site", relative = true)).len == Wheels.len
    for line in pythonOpenTelemetryPth().splitLines():
      if line.len > 0 and line != ".":
        checkpoint("._pth entry: " & line)
        check fileExists(prefix / line) or dirExists(prefix / line)
