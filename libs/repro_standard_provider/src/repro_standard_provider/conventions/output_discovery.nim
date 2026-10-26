## Tool-authored target metadata is the authority for delegated build outputs.
## The configure edge writes a dynamic-output fragment before any target runs,
## so the engine applies its ordinary output obligation and cache handling to
## the actual artifacts, including custom names and subdirectory targets.
import std/[algorithm, json, os, osproc, streams, strutils]
from repro_core/paths import extendedPath
from repro_core/ambient_execution import uncontrolledStartProcess

type DiscoveredOutputs = object
  outputs: seq[string]
  optionalOutputs: seq[string]

proc writeOutputFragment*(path, actionId: string; outputs: seq[string];
    optionalOutputs: seq[string] = @[]) =
  var text = "repro-dynamic-graph-v1\n"
  proc appendOutput(kind, output: string) =
    if '\t' in output or '\n' in output or '\r' in output:
      raise newException(ValueError, "output cannot be represented in a dynamic graph: " & output)
    text.add(kind & "\t" & actionId & "\t" & output.replace('\\', '/') & "\n")
  for output in outputs: appendOutput("output", output)
  for output in optionalOutputs: appendOutput("optional-output", output)
  createDir(extendedPath(path.parentDir))
  writeFile(extendedPath(path), text)

proc cmakeTargetArtifacts(buildDir, target: string): DiscoveredOutputs =
  let replyDir = buildDir / ".cmake/api/v1/reply"
  var indexes: seq[string]
  for path in walkFiles(replyDir / "index-*.json"): indexes.add(path)
  indexes.sort()
  if indexes.len == 0:
    raise newException(ValueError, "CMake file-API index missing: " & replyDir)
  let index = parseFile(indexes[^1])
  let model = parseFile(replyDir / index["reply"]["codemodel-v2"]["jsonFile"].getStr())
  for config in model["configurations"]:
    # This convention configures and builds Release. An artifact from another
    # configuration must never fulfill this edge's obligation or cache record.
    if config["name"].getStr() != "Release": continue
    for entry in config["targets"]:
      if entry["name"].getStr() != target: continue
      let detail = parseFile(replyDir / entry["jsonFile"].getStr())
      let objectsOnly = detail["type"].getStr() == "OBJECT_LIBRARY"
      let primaryName = detail.getOrDefault("nameOnDisk").getStr()
      for artifact in detail["artifacts"]:
        let path = artifact["path"].getStr().replace('\\', '/')
        let output = if path.isAbsolute: path else: buildDir / path
        if objectsOnly or extractFilename(path) == primaryName:
          result.outputs.add(output)
        else:
          # nameOnDisk identifies the primary linked/archived artifact. CMake
          # also lists linker byproducts (notably import libraries and PDBs)
          # which it predicts even when a successful link will not emit them.
          # Keep them restorable when present without weakening the primary.
          result.optionalOutputs.add(output)
      if result.outputs.len == 0:
        raise newException(ValueError, "CMake target has no primary artifact: " & target)
      return
  raise newException(ValueError, "CMake Release target absent from codemodel: " & target)

proc cmakeTargetOutputs*(buildDir, target: string): seq[string] =
  ## Primary mandatory artifacts, excluding conditionally emitted byproducts.
  cmakeTargetArtifacts(buildDir, target).outputs

proc mesonTargetOutputs*(buildDir, target: string): seq[string] =
  let metadata = parseFile(buildDir / "meson-info/intro-targets.json")
  for entry in metadata:
    if entry["name"].getStr() != target: continue
    for artifact in entry["filename"]:
      let path = artifact.getStr()
      result.add(if path.isAbsolute: path else: buildDir / path)
    if result.len == 0:
      raise newException(ValueError, "Meson target has no artifacts: " & target)
    return
  raise newException(ValueError, "Meson target absent from introspection: " & target)

proc swiftOutputDirectory*(swiftExe, projectRoot: string): string =
  ## SwiftPM owns the build triple and directory layout. This query plans no
  ## compilation and lets a single delegated build own its complete release
  ## tree, including automatic-library modules and dynamic/static products.
  let process = uncontrolledStartProcess(swiftExe, workingDir = projectRoot,
    args = @["build", "-c", "release", "--show-bin-path"],
    options = {poUsePath, poStdErrToStdOut})
  defer: process.close()
  let output = process.outputStream.readAll()
  if process.waitForExit() != 0:
    raise newException(ValueError, "SwiftPM output directory query failed: " & output)
  for line in output.splitLines():
    if line.strip().len > 0: result = line.strip()
  if not result.isAbsolute:
    raise newException(ValueError, "SwiftPM did not report an absolute output directory: " & output)

proc runOutputDiscoveryCommand*(args: seq[string]): bool =
  ## Internal standard-provider operation, invoked by the configure action.
  if args.len > 0 and args[0] == "--swift-output-directory":
    if args.len != 4:
      raise newException(ValueError, "invalid Swift output discovery arguments")
    let output = swiftOutputDirectory(args[1], args[2])
    let alias = args[2] / ".build/release"
    writeOutputFragment(args[3], "swift-swiftpm-build", @[output],
      if alias != output: @[alias] else: @[])
    return true
  if args.len == 0 or args[0] != "--convention-outputs": return false
  if args.len < 3 or (args.len - 3) mod 3 != 0:
    raise newException(ValueError, "invalid convention output discovery arguments")
  let kind = args[1]
  let buildDir = args[2]
  var i = 3
  while i < args.len:
    let artifacts = case kind
      of "cmake": cmakeTargetArtifacts(buildDir, args[i + 1])
      of "meson": DiscoveredOutputs(outputs: mesonTargetOutputs(buildDir, args[i + 1]))
      else: raise newException(ValueError, "unknown convention: " & kind)
    writeOutputFragment(args[i + 2], args[i], artifacts.outputs, artifacts.optionalOutputs)
    inc i, 3
  true

proc outputDiscoveryCommand*(kind, buildDir: string;
    targets: seq[tuple[id, name, fragment: string]]): string =
  var argv = @[getAppFilename(), "--convention-outputs", kind, buildDir]
  for target in targets:
    argv.add(@[target.id, target.name, target.fragment])
  argv.quoteShellCommand()
