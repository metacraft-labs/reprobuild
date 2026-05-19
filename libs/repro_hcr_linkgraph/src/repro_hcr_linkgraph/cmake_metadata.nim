import std/[json, os, strutils]

type
  CMakeHcrMetadataError* = object of CatchableError

  CMakeHcrObjectRelation* = object
    targetName*: string
    source*: string
    objectPath*: string
    compileAction*: string
    linkAction*: string
    linkOutput*: string
    linkGraphAction*: string
    linkGraph*: string
    language*: string

  CMakeHcrTarget* = object
    name*: string
    profile*: string
    linkAction*: string
    linkOutput*: string
    linkGraphAction*: string
    linkGraph*: string
    objects*: seq[CMakeHcrObjectRelation]

  CMakeHcrMetadata* = object
    schemaId*: string
    binaryDir*: string
    sourceDir*: string
    targets*: seq[CMakeHcrTarget]

proc fail(message: string) =
  raise newException(CMakeHcrMetadataError, message)

proc requiredString(node: JsonNode; key, context: string): string =
  if node.kind != JObject or not node.hasKey(key) or node[key].kind != JString:
    fail(context & " missing string field: " & key)
  node[key].getStr()

proc normalizeForLookup(path: string): string =
  if path.len == 0:
    return ""
  # Windows: Nim's `normalizedPath` converts to the platform-native form
  # (backslashes on Windows). The JSON written by CMake uses POSIX `/`
  # separators, so a backslash-normalized key would never match. Mirror the
  # dyndep fragment's approach: collapse `.`/`..` ourselves and force
  # forward-slash output everywhere, so reprobuild's lookups are
  # platform-agnostic.
  var canonical = path
  try:
    canonical = normalizedPath(path)
  except OSError:
    canonical = path
  result = canonical.replace('\\', '/')

proc readCMakeHcrMetadata*(path: string): CMakeHcrMetadata =
  if not fileExists(path):
    fail("CMake HCR metadata file not found: " & path)
  let root = parseFile(path)
  if root.kind != JObject:
    fail("CMake HCR metadata root must be an object: " & path)
  result.schemaId = requiredString(root, "schemaId", "CMake HCR metadata")
  if result.schemaId != "reprobuild.cmake.hcr.metadata.v1":
    fail("unsupported CMake HCR metadata schema: " & result.schemaId)
  result.binaryDir = requiredString(root, "binaryDir", "CMake HCR metadata")
  result.sourceDir = requiredString(root, "sourceDir", "CMake HCR metadata")
  if not root.hasKey("targets") or root["targets"].kind != JArray:
    fail("CMake HCR metadata missing targets array")

  for targetNode in root["targets"].items:
    if targetNode.kind != JObject:
      fail("CMake HCR target entry must be an object")
    var target = CMakeHcrTarget(
      name: requiredString(targetNode, "name", "CMake HCR target"),
      profile: requiredString(targetNode, "profile", "CMake HCR target"),
      linkAction: requiredString(targetNode, "linkAction", "CMake HCR target"),
      linkOutput: requiredString(targetNode, "linkOutput", "CMake HCR target"),
      linkGraphAction: requiredString(targetNode, "linkGraphAction",
        "CMake HCR target"),
      linkGraph: requiredString(targetNode, "linkGraph", "CMake HCR target"))
    if not targetNode.hasKey("objects") or targetNode["objects"].kind != JArray:
      fail("CMake HCR target missing objects array: " & target.name)
    for objectNode in targetNode["objects"].items:
      if objectNode.kind != JObject:
        fail("CMake HCR object entry must be an object: " & target.name)
      let relation = CMakeHcrObjectRelation(
        targetName: target.name,
        source: requiredString(objectNode, "source", "CMake HCR object"),
        objectPath: requiredString(objectNode, "object", "CMake HCR object"),
        compileAction: requiredString(objectNode, "compileAction",
          "CMake HCR object"),
        linkAction: target.linkAction,
        linkOutput: target.linkOutput,
        linkGraphAction: target.linkGraphAction,
        linkGraph: target.linkGraph,
        language: requiredString(objectNode, "language", "CMake HCR object"))
      target.objects.add(relation)
    result.targets.add(target)

proc readCMakeHcrMetadataForBuildDir*(binaryDir: string): CMakeHcrMetadata =
  readCMakeHcrMetadata(binaryDir / "CMakeFiles" / "reprobuild" /
    "hcr.metadata.json")

proc affectedObjectsForSource*(metadata: CMakeHcrMetadata; source: string):
    seq[CMakeHcrObjectRelation] =
  let wanted = normalizeForLookup(source)
  for target in metadata.targets:
    for relation in target.objects:
      if normalizeForLookup(relation.source) == wanted:
        result.add(relation)

proc requireHcrTargets*(metadata: CMakeHcrMetadata) =
  if metadata.targets.len == 0:
    fail("CMake HCR metadata contains no reloadable targets")
  for target in metadata.targets:
    if target.profile.len == 0:
      fail("CMake HCR target missing support profile: " & target.name)
    if target.linkAction.len == 0 or target.linkGraphAction.len == 0:
      fail("CMake HCR target missing link action metadata: " & target.name)
    if target.objects.len == 0:
      fail("CMake HCR target has no source/object relations: " & target.name)
