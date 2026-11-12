## Recording a cargo invocation's live set from `--message-format=json`.
##
## Cargo prints one JSON object per line. Two reasons matter here
## (https://doc.rust-lang.org/cargo/reference/external-tools.html):
##
##   compiler-artifact       a unit was compiled or found fresh; `filenames`
##                           lists its outputs, `fresh` says which
##   build-script-executed   a build script ran (or was replayed); `out_dir`
##                           is its `build/<pkg>-<hash>/out`
##
## The unit hash is read from those paths. `filenames` of a binary names only
## the final artifact cargo hard-links out of `deps/`, so that one is resolved
## by file identity against `deps/`.

import std/[json, os, strutils, tables, times]
import repro_core/file_lock
import ./[types, layout, store]

type
  PendingUnit = object
    ## A unit as the stream reported it, before it is resolved against disk.
    unit: LiveUnit
    paths: seq[string] ## the absolute paths of `filenames` / `out_dir`

  RecordReport* = object
    setFile*: string
    units*: int
    profileDirs*: seq[string]
    skippedLines*: int       ## lines that were not cargo JSON messages
    unresolved*: seq[string] ## artifact paths outside the target directory
    prunedSets*: int

  CargoStreamParser* = object
    ## Feed it lines with `feedLine`; `finish` resolves the units on disk.
    targetDir: string
    pending: seq[PendingUnit]
    skipped: int

proc newCargoStreamParser*(targetDir: string): CargoStreamParser =
  CargoStreamParser(targetDir: absolutePath(targetDir))

proc relativeToTarget(targetReal, targetRaw, path: string): string =
  ## `path` relative to the target directory with `/` separators, or "" when
  ## it is elsewhere. Accepts the target directory as spelled and as resolved
  ## (cargo prints resolved paths; the caller may have passed a symlink).
  for base in [targetRaw, targetReal]:
    if base.len == 0: continue
    let prefix = base & $DirSep
    if path.startsWith(prefix):
      return toSlash(path[prefix.len .. ^1])
  ""

proc tripleOf(profileDir: string): string =
  let parts = profileDir.split('/')
  if parts.len >= 2: parts[0] else: ""

proc profileSummary(node: JsonNode): string =
  if node.isNil or node.kind != JObject: return ""
  proc field(key: string): string =
    if node.hasKey(key): $node[key] else: "?"
  "opt-level=" & field("opt_level").strip(chars = {'"'}) &
    " debuginfo=" & field("debuginfo") & " test=" & field("test")

proc feedLine*(p: var CargoStreamParser; line: string) =
  ## Ignores anything that is not a cargo JSON message (rendered diagnostics,
  ## progress text, blank lines).
  let text = line.strip()
  if text.len == 0 or text[0] != '{':
    if text.len > 0: inc p.skipped
    return
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    inc p.skipped
    return
  if node.kind != JObject or not node.hasKey("reason"):
    inc p.skipped
    return
  case node["reason"].getStr
  of "compiler-artifact":
    var pending = PendingUnit()
    pending.unit.packageId = node{"package_id"}.getStr
    pending.unit.fresh = node{"fresh"}.getBool
    let target = node{"target"}
    if not target.isNil and target.kind == JObject:
      pending.unit.targetName = target{"name"}.getStr
      var kinds: seq[string]
      for k in target{"kind"}: kinds.add k.getStr
      pending.unit.targetKind = kinds.join(",")
      pending.unit.kind =
        if "custom-build" in kinds: ukBuildScript else: ukCompile
    pending.unit.crateName = normalizeCrateName(pending.unit.targetName)
    pending.unit.profile = profileSummary(node{"profile"})
    for f in node{"filenames"}: pending.paths.add f.getStr
    if node{"executable"}.kind == JString:
      let exe = node{"executable"}.getStr
      if exe notin pending.paths: pending.paths.add exe
    p.pending.add pending
  of "build-script-executed":
    var pending = PendingUnit()
    pending.unit.packageId = node{"package_id"}.getStr
    pending.unit.kind = ukBuildScriptRun
    pending.unit.targetName = "build-script"
    pending.unit.targetKind = "custom-build"
    pending.unit.fresh = true
    pending.paths.add node{"out_dir"}.getStr
    p.pending.add pending
  else:
    discard

proc profileDirOfPath(rel: string): string =
  ## The profile directory a target-relative path lies in, from the
  ## `<profile>/{deps,build,...}/...` shape (profile is one component, or
  ## `<triple>/<profile>`). "" when the path has no such shape.
  let parts = rel.split('/')
  for i in 1 .. min(2, parts.len - 2):
    if parts[i] in [DepsDir, BuildDir, FingerprintDir]:
      return parts[0 ..< i].join("/")
  ""

proc resolveUnits(p: CargoStreamParser; targetReal: string;
                  unresolved: var seq[string]): seq[LiveUnit] =
  ## Turn the stream's paths into (profile dir, hash) units. A message can
  ## name several outputs; each distinct (profile dir, hash) becomes one unit.
  var deps = initTable[string, Table[(int64, int64), string]]()
  var seen = initTable[string, bool]()
  proc add(res: var seq[LiveUnit]; base: LiveUnit; dir, hash: string) =
    let key = dir & "|" & hash
    if key in seen: return
    seen[key] = true
    var u = base
    u.profileDir = dir
    u.hash = hash
    u.triple = tripleOf(dir)
    res.add u
  for pend in p.pending:
    for raw in pend.paths:
      if raw.len == 0: continue
      let rel = relativeToTarget(targetReal, p.targetDir, raw)
      if rel.len == 0:
        unresolved.add raw
        continue
      let dir = profileDirOfPath(rel)
      if dir.len > 0:
        # `<profile>/deps/<file>` or `<profile>/build/<pkg>-<hash>/...`
        let parts = rel.split('/')
        let at = dir.split('/').len # index of deps/build
        let name =
          if parts.len > at + 1: parts[at + 1] else: ""
        let hash = embeddedUnitHash(name)
        if hash.len > 0:
          result.add(pend.unit, dir, hash)
        continue
      # An uplifted final artifact (`<profile>/<file>`): find its `deps/`
      # twin by file identity.
      let parts = rel.split('/')
      if parts.len in {2, 3}:
        let candidate = parts[0 ..< parts.len - 1].join("/")
        let abs = profileAbs(p.targetDir, candidate)
        if isProfileDir(abs):
          if candidate notin deps:
            deps[candidate] = inodeIndexOfDeps(abs)
          let id = fileIdOfPath(profileAbs(p.targetDir, rel))
          if id in deps[candidate]:
            result.add(pend.unit, candidate, deps[candidate][id])
            continue
          # No hard link (the file system copied it): protect every unit
          # whose deps/ file carries this artifact's name. Over-retaining is
          # the safe error.
          let stem = parts[^1].changeFileExt("")
          for kind, f in walkDir(abs / DepsDir):
            discard kind
            let fname = f.extractFilename
            let h = embeddedUnitHash(fname)
            if h.len > 0 and fname.startsWith(stem & "-") and
                fname[stem.len + 1 .. ^1].startsWith(h):
              result.add(pend.unit, candidate, h)

proc finish*(p: CargoStreamParser; report: var RecordReport): LiveSet =
  ## Resolve every reported path against the target directory and read each
  ## unit's toolchain fingerprint. Call after cargo has finished, so that
  ## `.fingerprint/` is complete.
  let targetReal =
    if dirExists(p.targetDir): expandFilename(p.targetDir) else: p.targetDir
  var unresolved: seq[string]
  result.units = resolveUnits(p, targetReal, unresolved)
  report.unresolved = unresolved
  report.skippedLines = p.skipped
  var indexes = initTable[string, OrderedTable[string, UnitEntries]]()
  for u in result.units.mitems:
    let abs = profileAbs(p.targetDir, u.profileDir)
    if u.profileDir notin indexes:
      indexes[u.profileDir] = indexProfileDir(abs)
    u.rustcFingerprint = fingerprintRustcOf(abs, u.hash, indexes[u.profileDir])
  let now = getTime()
  result.id = newLiveSetId(now)
  result.recordedAt = now.toUnix

proc recordFromParser*(parser: CargoStreamParser; targetDir: string;
                       keepSets = DefaultKeepSets): RecordReport =
  ## Store the live set `parser` collected and prune sets no profile directory
  ## needs any more. A stream naming no unit under `targetDir` stores nothing:
  ## an empty set would only evict real ones.
  let set = parser.finish(result)
  result.units = set.units.len
  var dirs: seq[string]
  for u in set.units:
    if u.profileDir notin dirs: dirs.add u.profileDir
  result.profileDirs = dirs
  if set.units.len == 0:
    return
  createDir(storeDir(targetDir))
  # Serialise with the janitor, which reads and deletes sets.
  var lock: ReproFileLock
  lock = acquireExclusiveFileLock(storeDir(targetDir) / "lock")
  try:
    result.setFile = writeLiveSet(targetDir, set)
    result.prunedSets = pruneLiveSets(targetDir, keepSets)
  finally:
    releaseExclusiveFileLock(lock)

proc recordLiveSet*(targetDir: string; jsonLines: openArray[string];
                    keepSets = DefaultKeepSets): RecordReport =
  ## Library entry point for callers that already hold the stream (a cargo
  ## wrapper, a build edge): parse `jsonLines` and store the live set.
  var parser = newCargoStreamParser(targetDir)
  for line in jsonLines: parser.feedLine(line)
  recordFromParser(parser, targetDir, keepSets)

proc recordLiveSetFromStream*(targetDir: string; input: File;
                              passthrough: File = nil;
                              keepSets = DefaultKeepSets): RecordReport =
  ## Read cargo's JSON stream from `input` to its end, optionally echoing each
  ## line to `passthrough` so the recorder can sit in a pipe
  ## (`cargo build --message-format=json | repro cargo record-live --tee`),
  ## then store the live set. The set is resolved only at the end of the
  ## stream, when cargo has finished writing `.fingerprint/`.
  var parser = newCargoStreamParser(targetDir)
  var line: string
  while input.readLine(line):
    parser.feedLine(line)
    if not passthrough.isNil:
      passthrough.writeLine(line)
      passthrough.flushFile()
  recordFromParser(parser, targetDir, keepSets)
