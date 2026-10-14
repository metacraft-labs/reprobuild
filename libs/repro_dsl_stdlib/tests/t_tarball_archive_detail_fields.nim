## GM4b: the archive-realization fields a `tarball` realization carries
## (`TarballArchiveDetail`) survive every route a realization takes —
## the in-package `provisioning:` block, a `provisioningFor` contribution,
## the interface-artifact codec (v21; v22 adds GM4c's macOS application
## fields `appBundle` / `bundleId` / `teamId`) and the thin-interface stub a
## consumer compiles — and the authoring vocabulary matches the schema the
## realizer decodes.
##
## These are the fields that let every retired `<tool>Catalog` record become a
## `tarball` realization of its canonical definition; a field dropped on any
## route would silently reconstruct a DIFFERENT realization than the author
## declared (an installer run as a plain extract, a lost `JAVA_HOME`).
##
## Mutations that fail it: dropping `detail` from `tarballProvisioningLiteral`
## (case 1), from `toInterfaceTarballProvisioning` / the v21 codec (case 3),
## or from `tarballArchiveDetailValueLiteral` (case 4); adding an install
## method to `InstallMethod` without `TarballInstallMethods` (case 2);
## dropping a GM4c field from any of those routes (cases 6 and 7); removing
## the authoring-time application rules from `validateMacosAppRecord`
## (case 8).
##
## No mocks: the macros, the codec and a real `nim c` of the generated stub.

import std/[algorithm, os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_interface_artifacts
import repro_project_dsl
import repro_dsl_stdlib/packages_schema

const DetailSha512 = repeat('c', 128)

package detailFixture:
  provisioning:
    tarball url = "https://example.invalid/detail-fixture-1.2.3.msi",
      sha512 = DetailSha512,
      archiveType = "installer-msi",
      executablePath = "bin\\detail.exe",
      extraExecutable = "bin\\detail-helper.exe",
      version = "1.2.3",
      packageId = "detailFixture@1.2.3",
      installMethod = "installer-msi",
      extractPath = "SourceDir",
      installerArg = "/quiet",
      pacmanPackage = "mingw-w64-x86_64-detail",
      bootstrapArg = "./configure",
      env = "DETAIL_HOME=${prefix}",
      env = "DETAIL_MODE=fixture",
      nested7z = true,
      msiAdminInstall = true,
      preInstall = preInstallAction("move-item", "$dir\\a", "$dir\\b"),
      preInstall = preInstallAction("set-content", "$dir\\c.txt",
        literal = "hello"),
      preInstallUnrecognized = "Remove-Item $dir\\junk",
      launcherEmit = launcherEmitSpec("phar", "detail.phar", "php", "detail"),
      cpuLevel = "x86-64-v2",
      cpuFeatures = "avx2",
      cpu = "x86_64",
      os = "windows"

provisioningFor "detailFixture":
  developInterface
  contributor "github:example/detail-contrib"
  tarball url = "https://example.invalid/contrib/detail-1.2.3.tar.zst",
    sha256 = repeat('d', 64),
    archiveType = "tar.zst",
    executablePath = "bin/detail",
    version = "1.2.3",
    installMethod = "msys2-pacman",
    pacmanPackage = "mingw-w64-x86_64-detail",
    env = "DETAIL_HOME=${prefix}",
    cpu = "x86_64",
    os = "windows"

# GM4c: a macOS application record. Never realized here.
package appDetailFixture:
  provisioning:
    tarball url = "https://example.invalid/AppFixture-2.1.dmg",
      sha256 = repeat('e', 64),
      archiveType = "dmg",
      installMethod = "app-bundle",
      appBundle = "Installer.pkg/Payload/Applications/AppFixture.app",
      bundleId = "dev.reprobuild.appfixture",
      teamId = "ABCDE12345",
      version = "2.1",
      executablePath = "AppFixture.app/Contents/MacOS/AppFixture",
      cpu = "any",
      os = "macos"

provisioningFor "appDetailFixture":
  developInterface
  contributor "github:example/app-contrib"
  tarball url = "https://example.invalid/contrib/AppFixture-2.1-x64.zip",
    sha256 = repeat('a', 64),
    archiveType = "zip",
    installMethod = "app-bundle",
    appBundle = "AppFixture.app",
    bundleId = "dev.reprobuild.appfixture",
    teamId = "ABCDE12345",
    version = "2.1",
    executablePath = "AppFixture.app/Contents/MacOS/AppFixture",
    cpu = "x86_64",
    os = "macos"

package detailConsumer:
  uses:
    "detailFixture"
    "appDetailFixture"

proc findPackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

proc checkFullDetail(detail: TarballArchiveDetail) =
  check detail.version == "1.2.3"
  check detail.sha512 == DetailSha512
  check detail.installMethod == "installer-msi"
  check detail.extractPath == "SourceDir"
  check detail.extraExecutables == @["bin\\detail-helper.exe"]
  check detail.installerArgs == @["/quiet"]
  check detail.pacmanPackages == @["mingw-w64-x86_64-detail"]
  check detail.bootstrapArgv == @["./configure"]
  check detail.env == @["DETAIL_HOME=${prefix}", "DETAIL_MODE=fixture"]
  check detail.nested7z
  check detail.msiAdminInstall
  check detail.preInstallUnrecognized == @["Remove-Item $dir\\junk"]
  check detail.cpuLevel == "x86-64-v2"
  check detail.cpuFeatures == "avx2"
  check detail.preInstall.len == 2
  let move = decodePreInstallAction(detail.preInstall[0])
  check move.kind == piaMoveItem
  check move.source == "$dir\\a"
  check move.target == "$dir\\b"
  let content = decodePreInstallAction(detail.preInstall[1])
  check content.kind == piaSetContent
  check content.literal == "hello"
  check detail.launcherEmit.len == 1
  let launcher = decodeLauncherEmitSpec(detail.launcherEmit[0])
  check launcher.kind == lekPhar
  check launcher.target == "detail.phar"
  check launcher.interpreter_package_id == "php"
  check launcher.launcher_name == "detail"

suite "GM4b: tarball archive detail fields":

  test "the in-package provisioning block carries every detail field":
    let pkg = findPackage("detailFixture")
    check pkg.tarballProvisioning.len == 1
    let record = pkg.tarballProvisioning[0]
    check record.sha256 == ""
    # The derived lock identity names the digest that pins the archive.
    check record.lockIdentity == "sha512:" & DetailSha512
    checkFullDetail(record.detail)

  test "the authoring vocabulary of installMethod is the schema's":
    var schemaTokens: seq[string] = @[]
    for im in InstallMethod:
      schemaTokens.add($im)
    check TarballInstallMethods.toSeq.sorted == schemaTokens.sorted
    for token in TarballInstallMethods:
      check parseInstallMethodToken(token).ok

  test "the projection and the v21 codec keep the detail of both routes":
    let consumer = findPackage("detailConsumer")
    let iface = toProjectInterface(consumer, registeredPackages(),
      registeredProvisioningContributions())
    let use = iface.toolUses.filterIt(it.packageSelector == "detailFixture")[0]
    check use.tarballProvisioning.len == 2
    checkFullDetail(use.tarballProvisioning[0].detail)
    let contributed = use.tarballProvisioning[1]
    check contributed.contributor == "github:example/detail-contrib"
    check contributed.detail.installMethod == "msys2-pacman"
    check contributed.detail.pacmanPackages == @["mingw-w64-x86_64-detail"]
    let artifact = artifactFromRegisteredDsl(currentSourcePath())
    let roundTrip = decodeProjectInterfaceArtifact(
      encodeProjectInterfaceArtifact(artifact))
    var seen = 0
    for u in roundTrip.projectInterface.toolUses:
      if u.packageSelector == "detailFixture":
        checkFullDetail(u.tarballProvisioning[0].detail)
        check u.tarballProvisioning[1].detail ==
          contributed.detail
        inc seen
    check seen == 1
    var contributionsChecked = 0
    for contribution in roundTrip.projectInterface.provisioningContributions:
      if contribution.targetPackage == "detailFixture":
        check contribution.tarballProvisioning[0].detail ==
          contributed.detail
        inc contributionsChecked
      elif contribution.targetPackage == "appDetailFixture":
        check contribution.tarballProvisioning[0].detail.teamId ==
          "ABCDE12345"
        inc contributionsChecked
    check contributionsChecked == 2

  test "the thin-interface stub reconstructs the contributed detail":
    let artifact = artifactFromRegisteredDsl(currentSourcePath())
    let tempRoot = createTempDir("repro-gm4b-detail-stub", "",
      getCurrentDir())
    defer: removeDir(tempRoot)
    writeNimInterfaceStub(tempRoot / "detail_interface.nim", artifact)
    let probe = tempRoot / "detail_probe.nim"
    writeFile(probe,
      "import repro_project_dsl\n" &
      "import detail_interface\n" &
      "let c = registeredProvisioningContributions()\n" &
      "doAssert c.len == 2\n" &
      "var d: TarballArchiveDetail\n" &
      "var a: TarballArchiveDetail\n" &
      "for x in c:\n" &
      "  if x.targetPackage == \"detailFixture\": d = x.tarballProvisioning[0].detail\n" &
      "  else: a = x.tarballProvisioning[0].detail\n" &
      "doAssert a.appBundle == \"AppFixture.app\"\n" &
      "doAssert a.bundleId == \"dev.reprobuild.appfixture\"\n" &
      "doAssert a.teamId == \"ABCDE12345\"\n" &
      "doAssert d.version == \"1.2.3\"\n" &
      "doAssert d.installMethod == \"msys2-pacman\"\n" &
      "doAssert d.pacmanPackages == @[\"mingw-w64-x86_64-detail\"]\n" &
      "doAssert d.env == @[\"DETAIL_HOME=${prefix}\"]\n" &
      "echo \"stub-detail-ok\"\n")
    let (output, exitCode) = execCmdEx(
      "nim c -r --hints:off --warnings:off --path:" &
        quoteShell(getCurrentDir() / "libs" / "repro_project_dsl" / "src") &
        " --out:" & quoteShell(tempRoot / "detail_probe") & " " &
        quoteShell(probe))
    if exitCode != 0:
      checkpoint output
    check exitCode == 0
    check "stub-detail-ok" in output

  test "GM4c: the in-package block carries the application fields":
    let record = findPackage("appDetailFixture").tarballProvisioning[0]
    check record.detail.installMethod == "app-bundle"
    check record.detail.appBundle ==
      "Installer.pkg/Payload/Applications/AppFixture.app"
    check record.detail.bundleId == "dev.reprobuild.appfixture"
    check record.detail.teamId == "ABCDE12345"
    check record.detail.version == "2.1"
    check record.archiveType == "dmg"
    check parseArchiveFormatToken(record.archiveType) == (true, afDmg)
    check parseArchiveFormatToken("pkg") == (true, afPkg)
    check parseInstallMethodToken("app-bundle") == (true, imAppBundle)
    check parseInstallMethodToken("pkg-install") == (true, imPkgInstall)

  test "GM4c: the v22 codec and the projection keep the application fields":
    let artifact = artifactFromRegisteredDsl(currentSourcePath())
    let roundTrip = decodeProjectInterfaceArtifact(
      encodeProjectInterfaceArtifact(artifact))
    var seen = 0
    for u in roundTrip.projectInterface.toolUses:
      if u.packageSelector == "appDetailFixture":
        let d = u.tarballProvisioning[0].detail
        check d.appBundle ==
          "Installer.pkg/Payload/Applications/AppFixture.app"
        check d.bundleId == "dev.reprobuild.appfixture"
        check d.teamId == "ABCDE12345"
        inc seen
    check seen == 1

  test "GM4c: an application record without its team or sha256 is an " &
      "authoring error":
    let tempRoot = createTempDir("repro-gm4c-detail-error", "",
      getCurrentDir())
    defer: removeDir(tempRoot)
    proc compileRecord(fields: string;
                       digest = "sha256 = \"" & repeat('f', 64) & "\""):
        tuple[output: string; exitCode: int] =
      let source = tempRoot / "bad_app_record.nim"
      writeFile(source, "import repro_project_dsl\n" &
        "package badApp:\n  provisioning:\n" &
        "    tarball url = \"https://example.invalid/x.dmg\",\n" &
        "      " & digest & ",\n" &
        "      archiveType = \"dmg\",\n" &
        "      installMethod = \"app-bundle\",\n" &
        "      version = \"1.0\",\n" &
        fields &
        "      cpu = \"any\",\n      os = \"macos\"\n")
      execCmdEx("nim check --hints:off --warnings:off --path:" &
        quoteShell(getCurrentDir() / "libs" / "repro_project_dsl" / "src") &
        " " & quoteShell(source))
    let noTeam = compileRecord(
      "      appBundle = \"X.app\",\n" &
      "      bundleId = \"dev.x\",\n" &
      "      executablePath = \"X.app/Contents/MacOS/X\",\n")
    checkpoint noTeam.output
    check noTeam.exitCode != 0
    check "teamId" in noTeam.output
    let badTeam = compileRecord(
      "      appBundle = \"X.app\",\n" &
      "      bundleId = \"dev.x\",\n" &
      "      teamId = \"not-a-team\",\n" &
      "      executablePath = \"X.app/Contents/MacOS/X\",\n")
    check badTeam.exitCode != 0
    check "10-character Apple team identifier" in badTeam.output
    let outside = compileRecord(
      "      appBundle = \"X.app\",\n" &
      "      bundleId = \"dev.x\",\n" &
      "      teamId = \"ABCDE12345\",\n" &
      "      executablePath = \"bin/x\",\n")
    check outside.exitCode != 0
    check "must start with 'X.app/'" in outside.output
    # The archive is attached or expanded before any signature check, so
    # only a SHA-256 pin is accepted for it.
    let weakDigest = compileRecord(
      "      appBundle = \"X.app\",\n" &
      "      bundleId = \"dev.x\",\n" &
      "      teamId = \"ABCDE12345\",\n" &
      "      executablePath = \"X.app/Contents/MacOS/X\",\n",
      digest = "sha512 = \"" & repeat('f', 128) & "\"")
    checkpoint weakDigest.output
    check weakDigest.exitCode != 0
    check "needs sha256" in weakDigest.output
    let ok = compileRecord(
      "      appBundle = \"X.app\",\n" &
      "      bundleId = \"dev.x\",\n" &
      "      teamId = \"ABCDE12345\",\n" &
      "      executablePath = \"X.app/Contents/MacOS/X\",\n")
    checkpoint ok.output
    check ok.exitCode == 0

  test "encoded pre-install and launcher entries refuse what they cannot " &
      "represent":
    expect ValueError:
      discard preInstallAction("run-arbitrary-powershell", "x")
    expect ValueError:
      discard launcherEmitSpec("exe", "a", "b", "c")
    expect ValueError:
      discard decodePreInstallAction("move-item")
    expect ValueError:
      discard preInstallAction("move-item", "a\x1fb")
