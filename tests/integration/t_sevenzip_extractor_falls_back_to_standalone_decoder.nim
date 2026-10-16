## When the 7-Zip MSI cannot be administratively installed, the 7-Zip
## extractor edge realizes its second pinned alternative -- the upstream
## standalone decoder `7zr.exe` -- and 7z-archived tools still extract.
##
## reprobuild-specs issues/2026-09-28-windows-bootstrap-extractor-requires-
## installer-service.md, and Dependency-Provisioning-In-Build-Graph.md 4.1:
## the Windows 7-Zip is the stdlib catalog's MSI, extracted by `msiexec /a`,
## "with the pinned upstream `7zr.exe` (`raw`, no extractor at all) as a
## second pinned alternative for hosts whose Windows Installer service refuses
## an administrative install". On a service-account CI runner `msiexec /a`
## exits 1601, and before the alternative existed every `.7z` / `.7z.exe`
## tool -- git for Windows, the bootstrap gcc -- failed to provision there.
## Nothing exercised the alternative until this test.
##
## What is real: the production 7-Zip extractor edge and its plan list
## (`extractorToolUses`), the production edge executor and its alternatives
## loop (`executeTarballProvisionEdge`), the pinned upstream `7zr.exe`
## (downloaded and SHA-256-verified), `msiexec.exe` from System32, the stdlib's
## git for Windows pin (a `.7z.exe` SFX), and a plain `.7z` the decoder
## itself writes. Nothing is mocked.
##
## What is substituted, and why: the FIRST plan's coordinates (URL and
## SHA-256) are pointed at a local file that is not an MSI, so `msiexec /a`
## really runs and really fails (exit 1620, "package could not be opened").
## That is the only way to make the MSI alternative fail on demand without
## stopping or reconfiguring the host's Windows Installer service, which a
## test must not touch. The failure takes the same branch a 1601 takes -- a
## non-zero `msiexec /a` exit raised from the `msi` arm -- and a separate case
## below proves the substituted plan fails exactly there, not at download or
## verification.
##
## Windows x86_64 only (the only host whose 7-Zip edge has alternatives); it
## says so elsewhere instead of passing on another code path. A network test:
## it downloads 7zr.exe and PortableGit once into a fresh temporary store.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_build_engine
import repro_project_dsl
import repro_interface_artifacts
import repro_tool_profiles
import repro_dsl_stdlib/packages/git

const HostHasAlternatives = defined(windows) and defined(amd64)

proc stdlibToolUse(packageName, executableName: string): InterfaceToolUse =
  ## The tool use a consumer declaring `uses: "<packageName>"` gets, built
  ## from the registered stdlib package so the pin under test is the
  ## catalog's own.
  let iface = toProjectInterface(PackageDef(
    packageName: "sevenZipFallbackConsumer",
    nativeBuildDeps: @[PackageUseDef(
      rawConstraint: packageName, packageSelector: packageName,
      executableName: executableName, depKind: "native")]),
    registeredPackages())
  doAssert iface.toolUses.len == 1, "expected one tool use for " & packageName
  iface.toolUses[0]

proc sevenZipEdgeIndex(edges: ProvisioningEdges): int =
  for i, action in edges.actions:
    if action.argv == @[TarballProvisionerName, "7zip@26.01"]:
      return i
  -1

proc failTheMsiPlan(edges: var ProvisioningEdges; notAnMsi: string) =
  ## Point the 7-Zip edge's MSI plan at `notAnMsi`, keeping every other plan
  ## -- the standalone decoder -- exactly as production pins it.
  let index = sevenZipEdgeIndex(edges)
  doAssert index >= 0, "the graph has no 7-Zip extractor edge"
  var spec = parseJson(edges.actions[index].builtinText)
  doAssert spec["plans"][0]["archiveType"].getStr() == "msi"
  spec["plans"][0]["url"] = %("file://" & notAnMsi)
  spec["plans"][0]["mirrors"] = newJArray()
  spec["plans"][0]["sha256"] = %fileSha256Hex(notAnMsi)
  edges.actions[index].builtinText = $spec

suite "the 7-Zip extractor falls back to the standalone decoder":
  putEnv("REPRO_CACHE_DISABLE", "1")
  let tempRoot = createTempDir("repro-7z-fallback-", "")
  let storeRoot = tempRoot / "store"
  let notAnMsi = tempRoot / "not-an-installer.msi"
  writeFile(notAnMsi, "this is not a Windows Installer database\n")

  when HostHasAlternatives:
    let systemRoot = getEnv("SystemRoot", r"C:\Windows")
    putEnv("PATH", [systemRoot / "System32", systemRoot,
      systemRoot / "System32" / "Wbem",
      systemRoot / "System32" / "WindowsPowerShell" / "v1.0"].join($PathSep))

  test "the reduced PATH has no extractor (positive control)":
    when not HostHasAlternatives:
      skip("the 7-Zip extractor has a single realization on " & hostOS &
        "/" & hostCPU & "; there is no alternative to fall back to")
    else:
      for name in ["7z", "7zz", "7zr"]:
        check findExe(name).len == 0

  test "production pins the MSI first and the standalone decoder second":
    when not HostHasAlternatives:
      skip("no 7-Zip alternatives on " & hostOS & "/" & hostCPU)
    else:
      let uses = extractorToolUses(ExtractorRoleSevenZip)
      check uses.len == 2
      if uses.len == 2:
        check uses[0].tarballProvisioning[0].archiveType == "msi"
        check uses[1].packageSelector == "7zr@26.01"
        check uses[1].tarballProvisioning[0].archiveType == "raw"
      let edges = tarballProvisioningEdges(stdlibToolUse("git", "git"),
        storeRoot)
      let index = sevenZipEdgeIndex(edges)
      require index >= 0
      let plans = parseJson(edges.actions[index].builtinText)["plans"]
      check plans.len == 2
      if plans.len == 2:
        check plans[0]["archiveType"].getStr() == "msi"
        check plans[1]["packageId"].getStr() == "7zr@26.01"

  test "the substituted MSI plan fails at msiexec, not before it":
    when not HostHasAlternatives:
      skip("no 7-Zip alternatives on " & hostOS & "/" & hostCPU)
    else:
      var edges = tarballProvisioningEdges(stdlibToolUse("git", "git"),
        storeRoot / "msi-only")
      failTheMsiPlan(edges, notAnMsi)
      let index = sevenZipEdgeIndex(edges)
      var spec = parseJson(edges.actions[index].builtinText)
      spec["plans"] = %*[spec["plans"][0]]
      var msiOnly = edges.actions[index]
      msiOnly.builtinText = $spec
      let outcome = executeTarballProvisionEdge(msiOnly)
      checkpoint(outcome.stderr)
      check outcome.status == asFailed
      check "msiexec /a exited" in outcome.stderr

  test "git (a .7z.exe) realizes through the standalone decoder when the MSI fails":
    when not HostHasAlternatives:
      skip("no 7-Zip alternatives on " & hostOS & "/" & hostCPU)
    else:
      var edges = tarballProvisioningEdges(stdlibToolUse("git", "git"),
        storeRoot)
      failTheMsiPlan(edges, notAnMsi)
      let run = runProvisioningEdges(edges, storeRoot)
      for item in run.results:
        checkpoint(item.id & ": " & $item.status & " " & item.stderr)
        check item.status == asSucceeded
      let index = sevenZipEdgeIndex(edges)
      let sevenZip = readTarballProvisionReceipt(edges.actions[index].outputs[0])
      check sevenZip.planIndex == 1
      check sevenZip.packageSelector == "7zr@26.01"
      check sevenZip.executable.startsWith(storeRoot)
      check sevenZip.executable.toLowerAscii().endsWith("7zr.exe")
      let git = readTarballProvisionReceipt(edges.rootReceipt)
      check git.executable.startsWith(storeRoot)
      let version = execProcess(git.executable, args = ["--version"],
        options = {})
      check version.startsWith("git version ")

  test "a plain .7z realizes through the standalone decoder when the MSI fails":
    when not HostHasAlternatives:
      skip("no 7-Zip alternatives on " & hostOS & "/" & hostCPU)
    else:
      # The decoder the previous case realized writes the archive, so the
      # payload is a genuine 7z and the case needs no other archiver.
      var probe = tarballProvisioningEdges(stdlibToolUse("git", "git"),
        storeRoot)
      let sevenZr = readTarballProvisionReceipt(
        probe.actions[sevenZipEdgeIndex(probe)].outputs[0]).executable
      require fileExists(sevenZr)
      let payload = tempRoot / "payload"
      createDir(payload / "bin")
      copyFile(sevenZr, payload / "bin" / "payload-tool.exe")
      let archive = tempRoot / "payload.7z"
      let pack = execCmdEx(quoteShell(sevenZr) & " a -bso0 -bsp0 " &
        quoteShell(archive) & " " & quoteShell(payload / "bin"),
        workingDir = payload)
      checkpoint(pack.output)
      require pack.exitCode == 0
      let useDef = InterfaceToolUse(
        rawConstraint: "payload-tool",
        packageSelector: "payload-tool@1",
        executableName: "payload-tool",
        tarballProvisioning: @[InterfaceTarballProvisioning(
          packageName: "payload-tool",
          url: "file://" & archive,
          sha256: fileSha256Hex(archive),
          archiveType: "7z",
          executablePath: "bin/payload-tool.exe",
          packageId: "payload-tool@1",
          lockIdentity: "tarball:payload-tool@1:sha256:" &
            fileSha256Hex(archive),
          cpu: "x86_64",
          os: "windows")])
      let freshStore = tempRoot / "store-7z"
      var edges = tarballProvisioningEdges(useDef, freshStore)
      require sevenZipEdgeIndex(edges) >= 0
      failTheMsiPlan(edges, notAnMsi)
      let run = runProvisioningEdges(edges, freshStore)
      for item in run.results:
        checkpoint(item.id & ": " & $item.status & " " & item.stderr)
        check item.status == asSucceeded
      let realized = readTarballProvisionReceipt(edges.rootReceipt)
      check realized.executable.startsWith(freshStore)
      check fileExists(realized.executable)
      let sevenZip = readTarballProvisionReceipt(
        edges.actions[sevenZipEdgeIndex(edges)].outputs[0])
      check sevenZip.planIndex == 1

  removeDir(tempRoot)
