import std/[json, os, strtabs, strutils, tempfiles, unittest]

import lints/ambient_execution
import repro_test_support

const Recipe = """
import std/[os, strutils]
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

const payload = staticRead("payload.nim").strip()

package bakedPayload:
  defaultToolProvisioning "path"
  uses:
    "sh"
  build:
    let written = shell(
      command = "printf '%s\\n' " & quoteShell(payload) & " > result.txt",
      actionId = "baked-payload.write",
      extraOutputs = @["result.txt"], cacheable = false)
    discard target("write", written)
"""

suite "provider graph follows the compiled binary":
  when isIoMonitorSupported:
    test "full build refreshes after a non-imported compile-time input changes":
      let repoRoot = getCurrentDir()
      let repro = requireBinary(repoRoot / "build" / "bin" /
        addFileExt("repro", ExeExt), "reprobuild.apps.repro")
      let root = createTempDir("repro-provider-graph-binary", "")
      defer: removeDir(root)
      let project = root / "project"
      createDir(project)
      writeFile(project / "repro.nim", Recipe)
      let env = newStringTable(modeCaseSensitive)
      for key, value in envPairs(): env[key] = value
      env["REPRO_CACHE_DISABLE"] = "1"
      env["REPROBUILD_WORK_ROOT"] = root / "work"
      env["REPROBUILD_ACTION_CACHE_ROOT"] = root / "action-cache"
      for key in ["REPROBUILD_STORE_ROOT", "REPRO_STORE_ROOT", "REPRO_LOCAL_STORE"]:
        env[key] = root / "store"

      var firstIdentity = ""
      for index, payload in ["alpha", "bravo", "bravo"]:
        if index < 2:
          writeFile(project / "payload.nim", payload & "\n")
        let reportPath = root / ("report-" & $index & ".json")
        let built = uncontrolledExecCmdEx(quoteShellCommand(@[
          repro, "build", "write", "--daemon=off", "--tool-provisioning=path",
          "--write-report=" & reportPath, "--progress=quiet", "--log=actions"]),
          workingDir = project, env = env)
        checkpoint(built.output)
        require built.exitCode == 0
        var identity = ""
        for line in built.output.splitLines():
          if line.startsWith("providerArtifact: "):
            identity = line
          if line.startsWith("providerArtifact: ") or
              line.startsWith("providerInvocations: ") or
              line.startsWith("loweredGraphCache: "):
            echo "run ", index, ": ", line
        require identity.len > 0
        if index == 0: firstIdentity = identity
        else: check identity == firstIdentity
        check readFile(project / "result.txt").strip() == payload
        let report = parseFile(reportPath)
        require report["actions"].len == 1
        check report["actions"][0]["launched"].getBool()
        check report["actions"][0]["exitCode"].getInt() == 0
        if index == 2:
          check built.output.contains("providerInvocations: 0")
          check built.output.contains("loweredGraphCache: hit")
