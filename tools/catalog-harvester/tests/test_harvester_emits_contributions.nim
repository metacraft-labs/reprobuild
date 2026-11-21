## GM4b — the harvester's output is valid DSL that means what was harvested.
##
## The harvester no longer emits ``VersionedProvisioning`` literals: it emits
## ``tarball`` realizations inside a ``package`` block (or a
## ``provisioningFor`` contribution with ``--contributor``). Text that merely
## LOOKS right is not enough — the statements must compile through the real
## ``package`` / ``provisioningFor`` macros and register records carrying
## exactly the data the parser produced. This test proves both.
##
## MECHANISM, and why it is not a runtime ``nim c``. The emitted modules are
## produced AT COMPILE TIME (the emitter and the manifest parser are pure
## string/JSON code the Nim VM runs, fed by ``staticRead`` of the fixtures) and
## spliced into THIS module by ``injectEmitted`` (``parseStmt``). So the
## emitted text is compiled by the same compile that builds the test — the
## graph-owned test-binary edge — with no helper compiled in the test body
## (Graph-Owned-Test-Artifacts M3; ``scripts/check_test_body_helper_
## compilation.py``). At run time the test reads the records the real macros
## registered (``registeredPackages()`` /
## ``registeredProvisioningContributions()``) and compares them field by field
## against the same parse, recomputed at run time.
##
## No mocks: real fixture manifests, the real parser, the real emitter, the
## real DSL macros and registries. The one synthetic input (``everyField``)
## is DATA, not a stand-in for a component: no fixture manifest exercises
## sha512, cpu floors, pacman packages, bootstrap argv, MSI admin install,
## nested 7z and launcher emission at once, and the round trip must cover
## every field the emitter writes.
##
## Vacuity guard: the comparison counts the fields it compared and the test
## requires a floor. Negative controls: (1) an emitted module with one byte of
## one statement corrupted compiles but is reported by the comparison; (2) a
## one-field mutation of the expected data is reported the same way.

import std/[algorithm, macros, os, strutils, tables, unittest]

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
import ../src/manifest_parser
import ../src/nim_emit

const FixturesDir = currentSourcePath.parentDir / "fixtures"
const MultitoolJson =
  staticRead(FixturesDir / "bucket-multiarch-extract/bucket/multitool.json")
const InstallerJson =
  staticRead(FixturesDir / "bucket-installer/bucket/myinstaller.json")
const InnoJson =
  staticRead(FixturesDir / "bucket-innosetup/bucket/innofakepascal.json")
const MsiJson = staticRead(FixturesDir / "bucket-msi/bucket/fakemsitool.json")
const BundleJson =
  staticRead(FixturesDir / "bucket-nsis-bundle/bucket/fakebundle.json")

proc parsed(app, raw: string): VersionedProvisioning =
  let p = parseScoopManifest(app, raw)
  doAssert p.ok, "fixture " & app & " did not parse"
  p.entry

proc everyField(): VersionedProvisioning =
  ## Synthetic data touching every emitted field (see the header).
  result = initVersionedProvisioning(
    version = "2.0.0",
    archive_format = afSevenZip,
    install_method = imMsys2Pacman,
    bin_relpath = @["bin\\every.exe", "bin\\every-helper.exe"],
    platforms = @[
      initPlatformBinary(cpu = pcX86_64, os = poWindows,
        url = "https://example.test/every-2.0.0-win.7z",
        sha512 = "ab".repeat(64), extract_path = "every-2.0.0"),
      initPlatformBinary(cpu = pcAArch64, os = poLinux,
        url = "https://example.test/every-2.0.0-linux.tar.zst",
        sha1 = "cd".repeat(20))],
    env = [("ZED", "${prefix}\\z"), ("ALPHA", "${prefix}")])
  result.platforms[0].nested_7z = true
  result.platforms[0].msi_admin_install = true
  result.platforms[0].cpu_level = mlX86_64_v3
  result.platforms[0].cpu_features = {cfAvx512f, cfAvx512vl}
  result.platforms[1].has_archive_format_override = true
  result.platforms[1].archive_format_override = afTarZst
  result.platforms[1].bin_relpath_override = @["bin/every"]
  result.installer_args = @["/S", "/D=$dir"]
  result.pacman_packages = @["mingw-w64-x86_64-every"]
  result.bootstrap_argv = @["sh", "bootstrap.sh"]
  result.pre_install_actions = @[
    PreInstallAction(kind: piaMoveItem, source: "$dir\\a b", target: "$dir\\c",
      recurse: false, literal: ""),
    PreInstallAction(kind: piaSetContent, source: "", target: "$dir\\x.txt",
      recurse: true, literal: "say \"hi\"")]
  result.pre_install_unrecognized = @["Get-ChildItem \"$dir\" | Out-Null"]
  result.launcher_emit = @[LauncherEmitSpec(kind: lekPhar,
    target: "every.phar", interpreter_package_id: "php",
    launcher_name: "every")]

macro injectEmitted(text: static string): untyped =
  ## Splice an emitted module into this one, so this compile compiles it.
  parseStmt(text)


# --- The emitted modules, compiled here ------------------------------------
injectEmitted(emitPackageModule("gm4bmultitool", "fixture/multiarch",
  [parsed("multitool", MultitoolJson)]))
injectEmitted(emitPackageModule("gm4binstaller", "fixture/installer",
  [parsed("myinstaller", InstallerJson), parsed("myinstaller", InstallerJson)]))
injectEmitted(emitPackageModule("gm4binno", "fixture/inno",
  [parsed("innofakepascal", InnoJson)]))
injectEmitted(emitPackageModule("gm4bmsi", "fixture/msi",
  [parsed("fakemsitool", MsiJson)]))
injectEmitted(emitPackageModule("gm4bbundle", "fixture/bundle",
  [parsed("fakebundle", BundleJson)]))
injectEmitted(emitPackageModule("gm4bevery", "fixture/every", [everyField()]))
# The --contributor form, with and without a fingerprint.
injectEmitted(emitContributionModule("gm4bmultitool", "fixture/multiarch",
  "github:example/develop-catalog", "", [parsed("multitool", MultitoolJson)]))
injectEmitted(emitContributionModule("gm4bevery", "fixture/every",
  "github:example/pinned-catalog", "0123abcd", [everyField()]))

# --- Negative control 1: a corrupted emitted statement ---------------------
# The same module with one byte of one statement changed (the x64 archive's
# version digit). It still compiles — so the comparison, not the compiler,
# must catch it. (A `compiles(...)` probe cannot stand in here: the
# `package` macro's output is top-level-only, so even the intact module
# "does not compile" inside `compiles`, and a refusal there proves nothing.)
const CorruptedModule = emitPackageModule("gm4bcorrupt", "fixture/x",
  [parsed("multitool", MultitoolJson)]).replace(
    "multitool-3.2.1-x64.zip", "multitool-3.2.2-x64.zip")
static:
  doAssert "multitool-3.2.2-x64.zip" in CorruptedModule
injectEmitted(CorruptedModule)

# --- The comparison --------------------------------------------------------

type Comparison = object
  fields: int
  mismatches: seq[string]

proc field(c: var Comparison; what: string; actual, expected: string) =
  inc c.fields
  if actual != expected:
    c.mismatches.add(what & ": " & actual.escape & " != " & expected.escape)

proc expectSeq(c: var Comparison; what: string;
               actual, expected: seq[string]) =
  c.field(what, actual.join("\n"), expected.join("\n"))

proc compareRecord(c: var Comparison; tool: string;
                   vp: VersionedProvisioning; pb: PlatformBinary;
                   r: TarballProvisioningDef) =
  let at = tool & " " & vp.version & " " & pb.url & " "
  c.field(at & "url", r.url, pb.url)
  c.field(at & "sha256", r.sha256, pb.sha256)
  c.field(at & "sha512", r.detail.sha512,
    if pb.sha256.len > 0: "" else: pb.sha512)
  c.field(at & "sha1", r.detail.sha1,
    if pb.sha256.len > 0 or pb.sha512.len > 0: "" else: pb.sha1)
  let format =
    if pb.has_archive_format_override: pb.archive_format_override
    else: vp.archive_format
  c.field(at & "archiveType", r.archiveType, $format)
  let bins =
    if pb.bin_relpath_override.len > 0: pb.bin_relpath_override
    else: vp.bin_relpath
  c.expectSeq(at & "executables", @[r.executablePath] & r.detail.extraExecutables,
    bins)
  c.field(at & "version", r.detail.version, vp.version)
  c.field(at & "packageId", r.packageId, tool & "@" & vp.version)
  c.field(at & "installMethod",
    $parseInstallMethodToken(r.detail.installMethod).installMethod,
    $vp.install_method)
  c.field(at & "extractPath", r.detail.extractPath, pb.extract_path)
  c.expectSeq(at & "installerArgs", r.detail.installerArgs, vp.installer_args)
  c.expectSeq(at & "pacmanPackages", r.detail.pacmanPackages,
    vp.pacman_packages)
  c.expectSeq(at & "bootstrapArgv", r.detail.bootstrapArgv, vp.bootstrap_argv)
  var env: seq[string] = @[]
  for k, v in vp.env: env.add(k & "=" & v)
  var actualEnv = r.detail.env
  # The emitter sorts by name; compare as sets in the same order.
  env.sort(system.cmp[string])
  c.expectSeq(at & "env", actualEnv, env)
  c.field(at & "nested7z", $r.detail.nested7z, $pb.nested_7z)
  c.field(at & "msiAdminInstall", $r.detail.msiAdminInstall,
    $pb.msi_admin_install)
  var pre: seq[string] = @[]
  for encoded in r.detail.preInstall:
    pre.add($decodePreInstallAction(encoded))
  var preExpected: seq[string] = @[]
  for a in vp.pre_install_actions: preExpected.add($a)
  c.expectSeq(at & "preInstall", pre, preExpected)
  c.expectSeq(at & "preInstallUnrecognized", r.detail.preInstallUnrecognized,
    vp.pre_install_unrecognized)
  var launchers: seq[string] = @[]
  for encoded in r.detail.launcherEmit:
    launchers.add($decodeLauncherEmitSpec(encoded))
  var launchersExpected: seq[string] = @[]
  for l in vp.launcher_emit: launchersExpected.add($l)
  c.expectSeq(at & "launcherEmit", launchers, launchersExpected)
  c.field(at & "cpu", $parsePlatformCpuToken(r.cpu).cpu, $pb.cpu)
  c.field(at & "os", $parsePlatformOsToken(r.os).os, $pb.os)
  c.field(at & "cpuLevel", $parseMicroarchLevelToken(r.detail.cpuLevel).level,
    $pb.cpu_level)
  c.field(at & "cpuFeatures",
    renderCpuFeatureTokens(parseCpuFeatureSet(r.detail.cpuFeatures).features),
    renderCpuFeatureTokens(pb.cpu_features))
  # No lockIdentity is emitted: the macro derives it from the digest.
  let digest =
    if pb.sha256.len > 0: "sha256:" & pb.sha256
    elif pb.sha512.len > 0: "sha512:" & pb.sha512
    else: "sha1:" & pb.sha1
  c.field(at & "lockIdentity", r.lockIdentity, digest)

proc compareAll(c: var Comparison; tool: string;
                catalog: openArray[VersionedProvisioning];
                records: seq[TarballProvisioningDef]) =
  var expected = 0
  for vp in catalog: expected += vp.platforms.len
  c.field(tool & " record count", $records.len, $expected)
  var i = 0
  for vp in catalog:
    for pb in vp.platforms:
      if i < records.len:
        compareRecord(c, tool, vp, pb, records[i])
      inc i

proc packageRecords(name: string): seq[TarballProvisioningDef] =
  var found = 0
  for pkg in registeredPackages():
    if pkg.packageName == name:
      inc found
      result = pkg.tarballProvisioning
  doAssert found == 1, "expected one registered package " & name &
    ", found " & $found

proc contribution(contributor: string): ProvisioningContributionDef =
  for c in registeredProvisioningContributions():
    if c.contributor == contributor:
      return c
  raise newException(KeyError, "no contribution from " & contributor)

suite "GM4b — emitted contributions compile and round-trip":

  test "every emitted package module registers exactly the parsed data":
    var c: Comparison
    c.compareAll("gm4bmultitool", [parsed("multitool", MultitoolJson)],
      packageRecords("gm4bmultitool"))
    c.compareAll("gm4binstaller", [parsed("myinstaller", InstallerJson),
      parsed("myinstaller", InstallerJson)], packageRecords("gm4binstaller"))
    c.compareAll("gm4binno", [parsed("innofakepascal", InnoJson)],
      packageRecords("gm4binno"))
    c.compareAll("gm4bmsi", [parsed("fakemsitool", MsiJson)],
      packageRecords("gm4bmsi"))
    c.compareAll("gm4bbundle", [parsed("fakebundle", BundleJson)],
      packageRecords("gm4bbundle"))
    c.compareAll("gm4bevery", [everyField()], packageRecords("gm4bevery"))
    for m in c.mismatches: checkpoint m
    check c.mismatches.len == 0
    # Vacuity guard: 6 packages, 9 records, ~27 fields each.
    checkpoint "fields compared: " & $c.fields
    check c.fields >= 200

  test "the fixtures actually exercise the structured fields":
    # Guards the guard: a round trip over records that never carry an
    # installer, an env binding or a pre-install step would pass trivially.
    let every = packageRecords("gm4bevery")
    check every[0].detail.preInstall.len == 2
    check every[0].detail.launcherEmit.len == 1
    check every[0].detail.env.len == 2
    check every[0].detail.cpuLevel == "x86-64-v3"
    check every[1].detail.sha1.len == 40
    check packageRecords("gm4bmultitool")[0].detail.env.len > 0
    check packageRecords("gm4binstaller")[0].detail.installMethod.len > 0

  test "the --contributor form registers fingerprint-bound contributions":
    let develop = contribution("github:example/develop-catalog")
    check develop.targetPackage == "gm4bmultitool"
    check develop.developInterface
    check develop.targetInterfaceFingerprint == ""
    let pinned = contribution("github:example/pinned-catalog")
    check pinned.targetPackage == "gm4bevery"
    check not pinned.developInterface
    check pinned.targetInterfaceFingerprint == "0123abcd"
    var c: Comparison
    c.compareAll("gm4bmultitool", [parsed("multitool", MultitoolJson)],
      develop.tarballProvisioning)
    c.compareAll("gm4bevery", [everyField()], pinned.tarballProvisioning)
    for m in c.mismatches: checkpoint m
    check c.mismatches.len == 0
    check c.fields >= 50

  test "negative control: a corrupted emitted statement is reported":
    var c: Comparison
    c.compareAll("gm4bcorrupt", [parsed("multitool", MultitoolJson)],
      packageRecords("gm4bcorrupt"))
    for m in c.mismatches: checkpoint m
    check c.mismatches.len == 1
    check c.mismatches.len == 1 and "url" in c.mismatches[0]

  test "negative control: a one-field mutation is reported":
    var mutated = everyField()
    mutated.platforms[1].url = "https://example.test/every-2.0.1-linux.tar.zst"
    var c: Comparison
    c.compareAll("gm4bevery", [mutated], packageRecords("gm4bevery"))
    check c.mismatches.len == 1
    check "url" in c.mismatches[0]

  test "default order: the first version emitted is the first declared":
    var older = everyField()
    older.version = "1.9.0"
    let src = emitPackageModule("gm4border", "fixture/order",
      [everyField(), older])
    check "## Versions (default first): 2.0.0, 1.9.0\n" in src
    let first = src.find("version = \"2.0.0\"")
    check first > 0
    check first < src.find("version = \"1.9.0\"")
    check src.startsWith("## Auto-generated by tools/catalog-harvester.")
    check "\nimport repro_project_dsl\nimport repro_dsl_stdlib/packages_schema\n" in src
    check "VersionedProvisioning" notin src

  test "an armv7 arm is emitted with the cpu token the schema reads back":
    # `PlatformCpu` gained `pcArmv7` with the 32-bit ARM cross-build; the
    # emitter's exhaustive `case` had no arm for it and the harvester (and
    # with it the `.#apps` collection) stopped compiling. The token must be
    # the schema's own spelling, so a harvested module parses back to the
    # same CPU.
    let vp = everyField()
    let pb = initPlatformBinary(cpu = pcArmv7, os = poLinux,
      url = "https://example.test/every-2.0.0-armv7.tar.zst",
      sha1 = "ef".repeat(20))
    let stmt = tarballStatement("every", vp, pb)
    check "cpu = \"armv7\"" in stmt
    check parsePlatformCpuToken("armv7") == (true, pcArmv7)

  test "a 32-bit x86 arm is refused, not emitted":
    var vp = parsed("multitool", MultitoolJson)
    vp.platforms[0].cpu = pcX86
    expect EmitError:
      discard emitPackageModule("gm4bx86", "fixture/x86", [vp])
