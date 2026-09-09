import std/[json, os, sequtils, strutils, tempfiles, unittest]
import repro_cli_support
import repro_core
import repro_interface_artifacts
import repro_project_dsl
import repro_provider_runtime
import repro_test_support
import repro_tool_profiles

suite "CMake install mirror generated tools":
  test "selected alias keeps mirror refs and runs with declared tools only":
    when defined(posix):
      let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
      let reproBin = requireBinary(reproBinaryPath(repoRoot), "reprobuild.apps.repro")
      let scratch = createTempDir("cmake-mirror-tools-", "")
      defer: removeDir(scratch)
      let projectRoot = scratch / "recipe"
      copyDir(repoRoot / "tests/fixtures/install-mirror-tools", projectRoot)
      let reportPath = scratch / "report.json"
      let args = @[reproBin, "build", projectRoot & "#mirror",
        "--daemon=off", "--tool-provisioning=path", "--work-root=" & (scratch / "work"),
        "--action-cache-root=" & (scratch / "cache"),
        "--write-report=" & reportPath, "--progress=quiet"]
      discard requireSuccess(shellCommand(args), repoRoot)
      require fileExists(reportPath)
      let report = parseFile(reportPath)
      var ids: seq[string]
      for action in report["actions"]:
        ids.add(action["id"].getStr)
        check action["status"].getStr == "asSucceeded"
        check action["exitCode"].getInt == 0
        check action["launched"].getBool
        check action["runQuotaBackend"].getStr == "posix-fork-exec-poll"
        check action["runQuotaSocket"].getStr.len > 0
        check action["leaseId"].getBiggestInt > 0
      check ids.len == 5
      check "mirror" in ids
      check "cmake-build-sed" in ids
      check "cmake-install-sed" in ids

      let metadataRoot = report["providerSnapshot"].getStr.parentDir.parentDir
      let snapshot = loadProviderGraphSnapshot(metadataRoot / "provider-graph")
      let iface = readInterfaceArtifact(metadataRoot / "project-interface.rbsz")
      let identity = readPathOnlyBuildIdentity(metadataRoot / "path-only-tool-identities.rbtp")
      let raw = lowerProviderSnapshot(snapshot, identity, projectRoot,
        "install-mirror-sed")
      let aliased = lowerProviderSnapshot(snapshot, identity, projectRoot, "mirror")
      let rawMirror = raw.actions.filterIt(it.id == "mirror")
      let aliasMirror = aliased.actions.filterIt(it.id == "mirror")
      require rawMirror.len == 1
      require aliasMirror.len == 1
      check rawMirror[0].toolIdentityRefs == aliasMirror[0].toolIdentityRefs
      let tools = iface.projectInterface.toolUses.mapIt(it.executableName)
      for name in typedInstallMirrorShellTools("sed"):
        check name in tools
        check name in aliasMirror[0].toolIdentityRefs
        check identity.profiles.anyIt(it.executableName == name)
      let pathEntry = actionPathEnvEntry(identity.profiles,
        refs = aliasMirror[0].toolIdentityRefs)
      check pathEntry.len > "PATH=".len
      check aliasMirror[0].env.filterIt(it.startsWith("PATH=")) == @[pathEntry]

      let mirror = projectRoot / ".repro/output/install/usr"
      check fileExists(mirror / "bin/mirror-probe")
      check readFile(mirror / "lib/pkgconfig/mirror-probe.pc").startsWith(
        "prefix=" & mirror)
      check requireSuccess(shellCommand([mirror / "bin/mirror-probe"]),
        projectRoot).strip == "mirror-ok"
    else:
      skip()
