## Persisting live sets.
##
## One TOML file per recorded cargo invocation under
## `<target>/.repro-cargo-gc/live-sets/`. TOML, not JSON, because the live
## sets are state this tool reads back (the repository keeps JSON for
## inspection output only). Files are written to a temporary name and renamed,
## so a reader never sees a torn set, and are named by `LiveSet.id`, which
## sorts in recording order.

import std/[algorithm, os, sets, strutils, tables, times]
import toml_serialization
import toml_serialization/types as toml_types
import ./types

const
  LiveSetSchema* = "reprobuild.cargo.live-set.v1"
  LiveSetsSubdir = "live-sets"

proc liveSetsDir*(targetDir: string): string =
  storeDir(targetDir) / LiveSetsSubdir

proc tomlQuote(text: string): string =
  ## A TOML basic string (https://toml.io/en/v1.0.0#string).
  result = "\""
  for c in text:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    elif ord(c) < 0x20 or ord(c) == 0x7f:
      result.add "\\u" & toHex(ord(c), 4)
    else: result.add c
  result.add "\""

proc renderLiveSet*(set: LiveSet): string =
  result = "schema = " & tomlQuote(LiveSetSchema) & "\n"
  result.add "id = " & tomlQuote(set.id) & "\n"
  result.add "recorded_at = " & $set.recordedAt & "\n"
  for u in set.units:
    result.add "\n[[unit]]\n"
    result.add "profile_dir = " & tomlQuote(u.profileDir) & "\n"
    result.add "hash = " & tomlQuote(u.hash) & "\n"
    result.add "kind = " & tomlQuote($u.kind) & "\n"
    result.add "package_id = " & tomlQuote(u.packageId) & "\n"
    result.add "target_name = " & tomlQuote(u.targetName) & "\n"
    result.add "target_kind = " & tomlQuote(u.targetKind) & "\n"
    result.add "crate_name = " & tomlQuote(u.crateName) & "\n"
    result.add "profile = " & tomlQuote(u.profile) & "\n"
    result.add "triple = " & tomlQuote(u.triple) & "\n"
    result.add "rustc = " & tomlQuote(u.rustcFingerprint) & "\n"
    result.add "fresh = " & (if u.fresh: "true" else: "false") & "\n"

proc newLiveSetId*(now: Time = getTime()): string =
  ## Sorts by recording time first; the pid and a counter make two recordings
  ## in the same nanosecond distinct.
  var counter {.global.} = 0
  inc counter
  let nanos = now.toUnix * 1_000_000_000'i64 + int64(now.nanosecond)
  align($nanos, 20, '0') & "-" & align($getCurrentProcessId(), 8, '0') & "-" &
    align($counter, 4, '0')

proc strOf(table: TomlValueRef; key: string): string =
  if table.kind in {TomlKind.Table, TomlKind.InlineTable} and
      table.tableVal[].hasKey(key) and
      table.tableVal[][key].kind == TomlKind.String:
    return table.tableVal[][key].stringVal
  ""

proc parseLiveSet*(text: string): LiveSet =
  ## Raises `ValueError` for text that is not a live set of this schema.
  var root: TomlValueRef
  try:
    root = Toml.decode(text, TomlValueRef)
  except CatchableError as err:
    raise newException(ValueError, "not valid TOML: " & err.msg)
  if root.isNil or root.kind notin {TomlKind.Table, TomlKind.InlineTable}:
    raise newException(ValueError, "not a TOML table")
  if strOf(root, "schema") != LiveSetSchema:
    raise newException(ValueError, "unknown schema '" & strOf(root, "schema") & "'")
  result.id = strOf(root, "id")
  if result.id.len == 0:
    raise newException(ValueError, "a live set needs an id")
  let table = root.tableVal[]
  if table.hasKey("recorded_at") and table["recorded_at"].kind == TomlKind.Int:
    result.recordedAt = table["recorded_at"].intVal
  if table.hasKey("unit"):
    let units = table["unit"]
    var rows: seq[TomlTableRef]
    case units.kind
    of TomlKind.Tables: rows = units.tablesVal
    of TomlKind.Array:
      for item in units.arrayVal: rows.add item.tableVal
    else: discard
    for row in rows:
      let v = TomlValueRef(kind: TomlKind.Table, tableVal: row)
      var u = LiveUnit(
        profileDir: strOf(v, "profile_dir"), hash: strOf(v, "hash"),
        packageId: strOf(v, "package_id"), targetName: strOf(v, "target_name"),
        targetKind: strOf(v, "target_kind"), crateName: strOf(v, "crate_name"),
        profile: strOf(v, "profile"), triple: strOf(v, "triple"),
        rustcFingerprint: strOf(v, "rustc"))
      u.fresh = row[].hasKey("fresh") and row[]["fresh"].kind ==
          TomlKind.Bool and
        row[]["fresh"].boolVal
      case strOf(v, "kind")
      of "build-script": u.kind = ukBuildScript
      of "build-script-run": u.kind = ukBuildScriptRun
      else: u.kind = ukCompile
      if not isUnitHash(u.hash) or u.profileDir.len == 0:
        raise newException(ValueError,
          "a unit needs a profile_dir and a 16-digit hex hash")
      result.units.add u

proc writeLiveSet*(targetDir: string; set: LiveSet): string =
  ## Atomically write `set`; returns the file path.
  let dir = liveSetsDir(targetDir)
  createDir(dir)
  let path = dir / (set.id & ".toml")
  let tmp = dir / ("." & set.id & ".tmp")
  writeFile(tmp, renderLiveSet(set))
  moveFile(tmp, path)
  path

proc loadLiveSets*(targetDir: string; problems: var seq[string]):
    seq[LiveSet] =
  ## Every readable live set, oldest first. An unreadable file is reported in
  ## `problems` and skipped: a damaged record can only make the janitor keep
  ## less protected than it should, so callers treat any problem as a reason
  ## not to delete (see `gc.planGc`).
  let dir = liveSetsDir(targetDir)
  if not dirExists(dir): return
  var names: seq[string]
  for kind, path in walkDir(dir):
    let name = path.extractFilename
    if kind == pcFile and name.endsWith(".toml") and not name.startsWith("."):
      names.add name
  names.sort()
  for name in names:
    try:
      result.add parseLiveSet(readFile(dir / name))
    except CatchableError as err:
      problems.add dir / name & ": " & err.msg
  result.sort(proc (a, b: LiveSet): int = cmp(a.id, b.id))

proc retainedSets*(sets: seq[LiveSet]; profileDir: string; keep: int):
    seq[LiveSet] =
  ## The last `keep` sets (newest last) that used `profileDir`.
  var touching: seq[LiveSet]
  for s in sets:
    for u in s.units:
      if u.profileDir == profileDir:
        touching.add s
        break
  if keep <= 0: return @[]
  if touching.len > keep:
    touching = touching[touching.len - keep .. ^1]
  touching

proc pruneLiveSets*(targetDir: string; keep: int; dryRun = false): int =
  ## Delete set files that are in no profile directory's last `keep`. Returns
  ## how many were (or would be) removed.
  var problems: seq[string]
  let sets = loadLiveSets(targetDir, problems)
  var dirs = initHashSet[string]()
  for s in sets:
    for u in s.units: dirs.incl u.profileDir
  var kept = initHashSet[string]()
  for d in dirs:
    for s in retainedSets(sets, d, keep): kept.incl s.id
  for s in sets:
    if s.id notin kept:
      inc result
      if not dryRun:
        try: removeFile(liveSetsDir(targetDir) / (s.id & ".toml"))
        except OSError: discard
