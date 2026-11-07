## A real unittest build retains its declared native C backend.
## Uses the normal engine, provider snapshot, identity resolver and compiler;
## no mocks or substitute compiler executables. A successful ambient build alone
## is insufficient: the selected profile and lowered edge PATH are asserted too.
## Removing the helper's backend attachment must fail the identity assertion,
## even on a host whose inherited PATH happens to contain a compiler.
import std/[json, os, sequtils, strtabs, strutils, tempfiles, unittest]
import lints/ambient_execution
import repro_cli_support
import repro_core
import repro_interface_artifacts
import repro_provider_runtime
import repro_test_support
import repro_tool_profiles

suite "unittest edges retain the real native C backend":
  test "selected backend is materialized, projected and executes the generated C":
    let backend = when defined(macosx): "clang" else: "gcc"
    require findExe("nim").len > 0
    require findExe(backend).len > 0
    let repoRoot = currentSourcePath().parentDir.parentDir.parentDir
    let reproBin = requireBinary(reproBinaryPath(repoRoot), "reprobuild.apps.repro")
    discard requireBinary(monitorShimPath(repoRoot),
      "reprobuild.test_fixtures.monitor_shim")
    let scratch = createTempDir("nim-unittest-backend-", "")
    defer: removeDir(scratch)
    let projectRoot = scratch / "project"
    createDir(projectRoot)
    writeFile(projectRoot / "repro.nim", """
import repro_project_dsl
import ct_test_nim_unittest
package unittest_backend_fixture:
  defaultToolProvisioning "path"
  uses:
    "nim"
    "__NATIVE_BACKEND__"
  build:
    let edge = buildNimUnittest.build(source = "test.nim", binary = "build/backend",
      actionId = "unittest-backend.compile")
    discard collect("default", @[edge.action])
""".replace("__NATIVE_BACKEND__", backend))
    writeFile(projectRoot / "test.nim", """
import std/unittest
suite "real C-backend execution":
  test "compiled code runs":
    check 6 * 7 == 42
    echo "unittest-backend-ok"
""")
    let reportPath = scratch / "report.json"
    let args = @[reproBin, "build", projectRoot,
      "--daemon=off", "--tool-provisioning=path",
      "--work-root=" & (scratch / "work"),
      "--action-cache-root=" & (scratch / "cache"),
      "--write-report=" & reportPath, "--progress=quiet"]
    # A checkout test must compile its provider against THIS checkout's DSL
    # and shared adapter, even if an installed image supplies the executor.
    # These supported source-selection inputs cross the isolated launch and
    # participate in normal provider identity; no PATH or profile is forced.
    let env = newStringTable(modeCaseSensitive)
    for key, value in envPairs(): env[key] = value
    env["REPROBUILD_REPO_ROOT"] = repoRoot
    env["REPROBUILD_LIBS_DIR"] = repoRoot / "libs"
    let built = uncontrolledExecCmdEx(quoteShellCommand(args),
      workingDir = repoRoot, env = env)
    checkpoint(built.output)
    require built.exitCode == 0
    let report = parseFile(reportPath)
    let metadataRoot = report["providerSnapshot"].getStr.parentDir.parentDir
    let snapshot = loadProviderGraphSnapshot(metadataRoot / "provider-graph")
    let identity = readPathOnlyBuildIdentity(
      metadataRoot / "path-only-tool-identities.rbtp")
    var compilerDir = ""
    for profile in identity.profiles:
      if profile.executableName == backend or profile.packageSelector == backend:
        compilerDir = parentDir(profile.resolvedExecutablePath)
        check profile.resolvedExecutableDigest.len > 0
    require compilerDir.len > 0
    let lowered = lowerProviderSnapshot(snapshot, identity, projectRoot,
      "unittest-backend.compile")
    let edges = lowered.actions.filterIt(it.id == "unittest-backend.compile")
    require edges.len == 1
    let paths = edges[0].env.filterIt(it.startsWith("PATH="))
    require paths.len == 1
    check compilerDir in paths[0]["PATH=".len .. ^1].split(PathSep)
    let produced = projectRoot / "build" / addFileExt("backend", ExeExt)
    require fileExists(produced)
    check requireSuccess(shellCommand([produced]), projectRoot).contains(
      "unittest-backend-ok")
