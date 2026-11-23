## `repro catalog generate` and `repro catalog verify`: the Nimble index
## generator as verbs (`repro_nimble_generator`).
##
## `generate` regenerates an index repository's `published-index/` from its
## `nimble-sources.toml`, with the current `published-index/` as the previous
## generation. `verify` is the second operator's check: it repeats the
## generation of an index from the inputs the index names and compares the
## roots, printing every difference by package and field.

import std/[os, strutils, times]

import blake3

import repro_domain_types/nimble_index
import repro_nimble_generator
import repro_nimble_index

proc defaultState(anchor: string): string =
  ## This host's generator state for one index: edge outputs and the engine
  ## cache. Outside the index repository, so nothing of it is committed.
  getCacheDir("reprobuild") / "nimble-generator" /
    toHexLower(blake3.digest(absolutePath(anchor)))[0 ..< 16]

proc indexRootOf(path: string): tuple[repo, indexDir: string] =
  ## ``path`` names an index repository or its `published-index/`.
  let p = absolutePath(path)
  if fileExists(p / "published-index" / IndexRootFile):
    (p, p / "published-index")
  elif fileExists(p / IndexRootFile):
    (parentDir(p), p)
  else:
    raise newException(ValueError, path & " holds no index (neither " &
      "published-index/root nor root)")

proc loadSourceSet(path: string): SourceSet =
  if not fileExists(path):
    raise newException(ValueError, "no source set at " & path)
  parseSourceSet(readFile(path), path)

proc printResult(r: GenerationResult) =
  for line in skippedReport(r): echo line
  for d in r.diagnostics: stderr.writeLine("  note: " & d)
  for e in r.refusals:
    stderr.writeLine("  refused: " & e.package & " (" & $e.family & "): " &
      $e.refusal.kind & ": " & e.refusal.url & ": " & e.refusal.detail)
  for e in r.events:
    echo "event " & $e.kind & " " & e.package &
      (if e.version.len > 0: " " & e.version else: "") &
      " before=" & e.before.escape() & " after=" & e.after.escape()

proc generateIndex(rootFlag, sourceSetFlag, stateFlag, generatedAtFlag: string;
                   policy: EgressPolicy) =
  let root = absolutePath(if rootFlag.len > 0: rootFlag else: getCurrentDir())
  let ssPath = if sourceSetFlag.len > 0: absolutePath(sourceSetFlag)
               else: root / SourceSetFileName
  let ss = loadSourceSet(ssPath)
  let indexDir = root / "published-index"
  var generatedAt = uint64(epochTime())
  if generatedAtFlag.len > 0:
    generatedAt = uint64(parseBiggestUInt(generatedAtFlag))
  let cfg = GeneratorConfig(sourceSet: ss, generatedAt: generatedAt,
    previousIndex: (if fileExists(indexDir / IndexRootFile): indexDir else: ""),
    stateDir: (if stateFlag.len > 0: absolutePath(stateFlag)
               else: defaultState(root)),
    outputDir: indexDir, policy: policy, shardBits: -1)
  let r = generate(cfg)
  printResult(r)
  # Every refusal and origin event of the generation, kept (threat model
  # § 9): appended to this host's capture log.
  let captures = capturesOfGeneration(r, generatedAt)
  let captureLog = cfg.stateDir / "captures.log"
  appendCaptures(captureLog, captures)
  if captures.len > 0:
    echo "captured " & $captures.len & " record(s) in " & captureLog
  echo "root blake3:" & $r.built.rootId & " packages=" &
    $r.built.root.packageCount & " versions=" & $r.built.root.versionCount &
    " events=" & $r.built.root.eventCount
  echo "wrote " & indexDir

proc runCatalogGenerateCommand*(rootFlag, sourceSetFlag, stateFlag,
                                generatedAtFlag: string;
                                policy = defaultPolicy()): int =
  ## The verb: 0 when the index was written, 1 when the generation failed.
  ## ``policy`` is the origin egress policy; the command line always uses
  ## the default one, and only a test that serves its origins locally names
  ## another resolver and dialer.
  try:
    generateIndex(rootFlag, sourceSetFlag, stateFlag, generatedAtFlag, policy)
    0
  except CatchableError as err:
    stderr.writeLine("repro catalog generate: error: " & err.msg)
    1

proc verifyIndexDir(index, sourceSetFlag, previousFlag, stateFlag: string;
                    policy: EgressPolicy): int =
  let (repo, indexDir) = indexRootOf(index)
  let ssPath = if sourceSetFlag.len > 0: absolutePath(sourceSetFlag)
               else: repo / SourceSetFileName
  let ss = loadSourceSet(ssPath)
  let previous =
    if previousFlag.len > 0: indexRootOf(previousFlag).indexDir else: ""
  let state = if stateFlag.len > 0: absolutePath(stateFlag)
              else: defaultState(indexDir) & "-verify"
  let v = verifyIndex(indexDir, ss, previous, state,
    GeneratorConfig(policy: policy, shardBits: -1))
  printResult(v.generation)
  if v.verified:
    echo "verified: root blake3:" & $v.publishedRoot
    return 0
  echo "differs: published blake3:" & $v.publishedRoot & ", repeated blake3:" &
    $v.repeatedRoot
  for d in v.differences:
    echo "  " & (if d.package.len > 0: d.package & " " else: "") & d.field &
      ": published " & d.published.escape() & ", repeated " &
      d.repeated.escape()
  1

proc runCatalogVerifyCommand*(index, sourceSetFlag, previousFlag,
                              stateFlag: string;
                              policy = defaultPolicy()): int =
  ## The verb: 0 when the roots are equal, 1 when they differ, 2 when the
  ## generation could not be repeated (another source set or previous
  ## index than the root names, an index that fails its own hash checks, a
  ## generation that failed). ``policy`` as for `generate`.
  try:
    verifyIndexDir(index, sourceSetFlag, previousFlag, stateFlag, policy)
  except CatchableError as err:
    stderr.writeLine("repro catalog verify: error: " & err.msg)
    2
