import std/[json, os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_cli_support
import repro_hcr_agent/debug_unwind
import repro_hcr_linkgraph

const
  OldSource = """
int patchable_value(int iteration) {
  int bias = 11;
  int state = iteration + bias;
  return state;
}
"""

  NewSource = """
int patchable_value(int iteration) {
  int bias = 77;
  int state = iteration + bias;
  return state;
}
"""

proc runCommand(argv: openArray[string]; cwd: string) =
  let command = argv.mapIt(quoteShell(it)).join(" ")
  let res = execCmdEx(command, workingDir = cwd)
  if res.exitCode != 0:
    raise newException(ValueError,
      "command failed: " & command & "\n" & res.output)

proc compileObject(projectRoot, sourcePath, objectPath: string) =
  createDir(parentDir(objectPath))
  runCommand([
    "cc", "-c", "-g", "-O0", "-fno-inline",
    sourcePath, "-o", objectPath
  ], projectRoot)

proc writeBuildReport(reportPath, sourcePath, objectPath: string) =
  createDir(parentDir(reportPath))
  writeFile(reportPath, $(%*{
    "actions": [
      {
        "id": "compile-patchable",
        "status": "asSucceeded",
        "evidence": {
          "declaredInputs": [sourcePath],
          "declaredOutputs": [objectPath],
          "depfileInputs": [],
          "monitorReads": []
        }
      }
    ]
  }))

proc bytesOf(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

suite "HCR watch inference":
  test "infers patch metadata from ordinary C object rebuild":
    when defined(macosx) and defined(arm64):
      let tempRoot = createTempDir("repro-hcr-watch-infer", "")
      defer: removeDir(tempRoot)

      let projectRoot = tempRoot / "project"
      let sourcePath = projectRoot / "src" / "patchable.c"
      let objectPath = projectRoot / "build" / "patchable.o"
      let reportPath = projectRoot / ".repro" / "build" / "build-report.json"
      let artifacts = projectRoot / ".repro" / "hcr"
      createDir(parentDir(sourcePath))

      writeFile(sourcePath, OldSource)
      check not OldSource.contains("repro_hcr_agent")
      check not OldSource.contains("section(")
      check not OldSource.contains("REPROBUILD_HCR")
      compileObject(projectRoot, sourcePath, objectPath)
      writeBuildReport(reportPath, sourcePath, objectPath)
      let preparedObjectPath = projectRoot / "build" / "patchable.hcr.o"
      let preparedSections = rewriteMachOArm64CodeSectionSegments(
        objectPath, preparedObjectPath, "__HCR")
      check preparedSections >= 1
      let preparedGraph = parseMachOArm64Object(preparedObjectPath)
      let preparedSymbol = preparedGraph.functionSymbols()[0]
      check preparedGraph.sections[preparedSymbol.sectionId].segmentName == "__HCR"

      let baselines = captureInferredHcrWatchBaseline(
        projectRoot, reportPath, artifacts)
      check baselines.len == 1
      check baselines[0].objectPath == objectPath
      check baselines[0].sourcePath == sourcePath
      check fileExists(baselines[0].generation0Object)

      writeFile(sourcePath, NewSource)
      compileObject(projectRoot, sourcePath, objectPath)
      let inferred = inferHcrWatchPatch(baselines, artifacts, 2)

      check inferred.metadata.functionName == "patchable_value"
      check inferred.metadata.targetSymbol == "patchable_value"
      check inferred.metadata.objectSymbol == "_patchable_value"
      check inferred.metadata.objectPath == objectPath
      check inferred.metadata.sourcePath == sourcePath
      check inferred.oldObject == baselines[0].generation0Object
      check fileExists(inferred.newObject)

      let registration = registerJitDebugObject(
        readFile(inferred.newObject).bytesOf(), 0x100000000'u64,
        inferred.metadata.functionName)
      check registration.success
      check registration.rebasedSectionOrdinal > 0
      check registration.rebasedSectionAddress == 0x100000000'u64
    else:
      skip()
