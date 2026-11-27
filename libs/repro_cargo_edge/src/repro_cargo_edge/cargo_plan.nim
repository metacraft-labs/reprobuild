## Cargo's build plan, derived from a record run's recordings.
##
## A record run (`record_mode`) lets cargo walk its whole schedule while the
## wrapper records every compile unit and the stub records every build-script
## run. This module turns those recordings into the PLAN: one entry per unit
## and per run, with the command line, working directory and environment
## cargo gave it, the links between them, and the paths rewritten so that the
## plan names no file of the record run itself. The plan is the one output of
## the record-only graph-production edge (`plan_run`, `plan_edge`); later
## edges read it.
##
## HOW THE LINKS ARE READ. Only from paths cargo itself wrote into the
## recordings, never by re-deriving cargo's hashes:
##
## - a unit's `--extern <name>=<path>` names the unit whose placeholder is
##   that path (the unit it consumes);
## - a unit's `-L dependency=<dir>` is cargo's search path for the indirect
##   dependencies; it becomes one `-L dependency=` per unit of the transitive
##   closure of the unit's `--extern` links, because every unit gets its own
##   output directory (below);
## - a unit's `OUT_DIR` is the `OUT_DIR` its package's build-script run
##   received;
## - a run's argv[0] lies in the output directory of the build-script compile
##   that wrote the executable (cargo runs its uplifted `build-script-<stem>`
##   link of it);
## - each sentinel (`__repro_slot.<kind>.<run>`) names the run that feeds the
##   slot, by the directory cargo made for the run.
##
## HOW PATHS ARE REWRITTEN. The recordings name paths against logical roots
## (`record_mode.logicalize`): `${project}`, `${store}`, and the record run's
## own `${target}` (its scratch target directory) and `${scratch}`. Every
## `${target}` path is rewritten into a per-unit output directory under the
## `${out}` root, the layout the registry-crate rustc edge already uses (one
## directory per unit, named `<package>-<version>-<hash>`, where `<hash>` is
## cargo's own `-C extra-filename` value, or, for a run, the hash of the
## directory cargo made for it):
##
## - a path under a vendor entry the record run served a crates.io crate
##   from (`${scratch}/vendor/<name>-<version>`): the same path under the
##   store prefix the entry links to (`derivePlan`'s `vendorMap`, which the
##   run builds from the entries it wrote);
## - a unit's `--out-dir` and its outputs: `${out}/<unit>/<file>`;
## - a unit's `-C incremental=` directory: `${out}/<unit>/incremental`;
## - a run's `OUT_DIR`, and every path under it: `${out}/<run>/out/...`;
## - an entry of a path list (the dynamic-library search path cargo sets)
##   that names a `deps` directory, or the profile directory above it that
##   cargo uplifts final artifacts into: the closure's directories (for a
##   run, its build-script compile's closure).
##
## A `${target}` path that none of these rules places, a `${scratch}` path,
## or a sentinel left anywhere fails the derivation (`CargoPlanError`): a plan
## that still named the record run's own files would point the edges that
## read it at files that no longer exist. So does an absolute path under no
## logical root, in an argument, a working directory or an environment
## difference: a plan naming one would hold a file of one host, which no
## other checkout or host can resolve. Only `-L dependency=` directories
## under the target directory are rewritten into the closure; any other is
## left as cargo wrote it (and an absolute one is refused like any path).
##
## SLOTS. Each sentinel cargo placed becomes a SLOT, written
## `${slot:<kind>:<run>}` (with `:<bin>` for `rustc-link-arg-bin`). In an
## argument list one slot stands for the whole group cargo emitted for the
## sentinel (`--cfg <value>` is one slot, not two arguments); in a path list
## it stands for the entry. A root label holds no `:`, so a slot never reads
## as a root token. The `rustc-env` sentinel variable becomes an entry of the
## unit's `envSlots`, and a run's `DEP_<LINKS>___REPRO_PROVIDER` variable an
## entry of its `providers`; both variables are removed. A unit is FED when
## it carries a slot or receives an `OUT_DIR`; one that is not is complete as
## it stands. A build-script RUN can be fed too: cargo puts a
## build-dependency's `rustc-link-search` paths inside its `OUT_DIR` on the
## dynamic-library path of the dependent build script it runs, so those
## entries become slots in the run's environment and the run is fed by the
## build-dependency's run (`PlanRun.fedBy`). Only those two link-search kinds
## may feed a run.
##
## THE ENVIRONMENT. A unit's or run's environment is stored as its DIFFERENCE
## from the record run's own environment (the closed environment the edge was
## launched with): what cargo set or changed for it, plus the names cargo
## removed. The variables cargo documents setting for a crate or a build
## script (`cargoSetsVariable`) are kept even when their value equals the
## record run's own, because the edge that runs the unit is not launched from
## that environment. Dropped from the difference: the record run's own
## variables (`RUSTC_WRAPPER` when it names the record wrapper,
## `CARGO_MAKEFLAGS`, and a `MAKEFLAGS`/`MFLAGS` that carries jobserver
## descriptors), and the variables cargo's own process sets for itself and
## its children inherit (`CargoProcessVariables`: the certificate locations
## its TLS library probes for when the environment names none), and the io
## monitor's own `REPRO_MONITOR_*` variables, which a monitored record run's
## processes carry.
##
## THE FORMAT. A fixed-schema binary record: a length-prefixed magic
## (`CargoPlanMagic`), a `u16` schema version, a `u32` payload length, and the
## SSZ-encoded payload (`encodeCargoPlan`, `decodeCargoPlan`), the envelope
## the repository uses for fixed-schema records it writes and reads back. It
## is not JSON: the recordings are JSON scratch files read once inside the
## edge, and the plan does not inherit their format. Every list is
## bounds-checked before it is encoded, and a decoded plan is checked as the
## derivation checks the one it writes (`validatePlan`): unique ids, every
## reference resolved, every output under its unit's directory, no path of
## the record run left. Schema version 2 added `PlanRun.fedBy`; version 3
## added `CargoPlan.refusal`.

import std/[algorithm, os, sequtils, sets, strutils, tables]
when defined(posix):
  import std/posix

import ssz_serialization
import repro_core/codec

import ./record_mode

const
  CargoPlanMagic* = "reprobuild.cargoPlan.v1"
  CargoPlanSchemaVersion* = 3'u16
  OutRootLabel* = "out"
    ## The root every rewritten target-directory path is under.
  TargetRootLabel* = "target"
    ## The record run's scratch target directory (`plan_run`).
  ScratchRootLabel* = "scratch"
    ## The record run's scratch directory (`plan_run`).
  SlotTokenPrefix* = "${slot:"

  MaxPlanTextBytes = 1 shl 20
  MaxPlanListItems = 1 shl 16

type
  CargoPlanError* = object of CatchableError
    ## The recordings cannot be turned into a plan: a link that cannot be
    ## read from cargo's paths, a path no rule places, a malformed record.

  PlanSlot* = object
    kind*: string   ## the sentinel's kind (`rustc-cfg`, `rustc-env`, ...)
    run*: string    ## the plan id of the run that feeds it
    bin*: string    ## `rustc-link-arg-bin` only: the binary it names

  PlanProvider* = object
    links*: string     ## the `<LINKS>` part of `DEP_<LINKS>___REPRO_PROVIDER`
    provider*: string
      ## the providing package, as its own run names it (`PlanRun.provider`)

  PlanUnit* = object
    id*: string           ## `<package>-<version>-<hash>`, its directory
    package*, version*: string
    crateName*: string
    buildScriptCompile*: bool
    cargoOutDir*: string
      ## The `--out-dir` cargo gave, relative to the target directory.
    cargoIncrementalDir*: string
      ## The `-C incremental=` directory, relative to the target directory
      ## ("" when cargo passed none).
    argv*: seq[string]    ## rustc's path and arguments, slots in place
    cwd*: string
    env*: seq[(string, string)]   ## the difference, sorted by name
    envRemoved*: seq[string]
    envSlots*: seq[PlanSlot]
    outputs*: seq[string]  ## `${out}/<id>/<file>`
    consumes*: seq[string] ## the units named by `--extern`, sorted
    closure*: seq[string]  ## `consumes`, transitively, sorted
    fedBy*: seq[string]    ## the runs its slots name, sorted
    outDirRun*: string     ## the run whose `OUT_DIR` it receives, or ""
    executable*: string    ## a build-script compile: the script's output

  PlanRun* = object
    id*: string           ## `<package>-<version>-<hash>`
    package*, version*: string
    compileUnit*: string  ## the build-script compile whose output it runs
    argv*: seq[string]
    cwd*: string
    env*: seq[(string, string)]
    envRemoved*: seq[string]
    outDir*: string       ## `${out}/<id>/out`
    cargoOutDir*: string  ## cargo's `OUT_DIR`, relative to the target dir
    manifest*, manifestFrom*: string
    provider*: string     ## its own `links` provider, or ""
    providers*: seq[PlanProvider]  ## the providers cargo gave it
    fedBy*: seq[string]
      ## the runs whose link-search slots its dynamic-library path carries

  CargoPlan* = object
    units*: seq[PlanUnit]  ## sorted by id
    runs*: seq[PlanRun]    ## sorted by id
    refusal*: string
      ## Why the record run did not plan the workspace, when a condition of
      ## the workspace refused it before cargo ran (`plan_run.PlanRefusal`):
      ## the workspace is then built by cargo as a whole. A refused plan
      ## holds no unit and no run; "" for a plan.

proc fail(msg: string) {.noreturn.} =
  raise newException(CargoPlanError, msg)

proc slotToken*(slot: PlanSlot): string =
  result = SlotTokenPrefix & slot.kind & ":" & slot.run
  if slot.bin.len > 0: result.add ":" & slot.bin
  result.add "}"

const
  TargetToken = "${" & TargetRootLabel & "}"
  ScratchToken = "${" & ScratchRootLabel & "}"
  OutToken = "${" & OutRootLabel & "}"
  SentinelMarker = SentinelPrefix & "."
  SlotKinds = ["rustc-cfg", "rustc-check-cfg", "rustc-env", "rustc-link-lib",
    "rustc-link-search-in-out-dir", "rustc-link-search-outside-out-dir",
    "rustc-link-arg", "rustc-link-arg-bins", "rustc-link-arg-bin",
    "rustc-link-arg-tests", "rustc-link-arg-examples",
    "rustc-link-arg-benches", "rustc-link-arg-cdylib"]
  FlagsTakingAValue = ["--cfg", "--check-cfg", "-l", "-L", "-C", "--codegen"]
  RunSlotKinds = ["rustc-link-search-in-out-dir",
    "rustc-link-search-outside-out-dir"]
    ## The only slots a build-script run can carry: a build-dependency's
    ## link-search paths on its dynamic-library path.
  MonitorVariablePrefix* = "REPRO_MONITOR_"
    ## The io monitor's own variables. When the record run is itself
    ## monitored (as graph production runs it), the monitor sets them in
    ## every process it starts, with values that change from one exec to the
    ## next (`REPRO_MONITOR_EXEC_GEN`), so they would enter each unit's
    ## difference. They are never cargo's, and the engine's monitor sets its
    ## own for the unit's edge.
  CargoProcessVariables* = ["SSL_CERT_FILE", "SSL_CERT_DIR"]
    ## Variables cargo's own process sets when the environment lacks them
    ## (its TLS library's probe for the system's certificate locations), so
    ## every process it starts inherits them; they describe the host cargo
    ## ran on, not the unit.
  CrateVariables = ["CARGO", "CARGO_MANIFEST_DIR", "CARGO_MANIFEST_PATH",
    "CARGO_CRATE_NAME", "CARGO_BIN_NAME", "CARGO_PRIMARY_PACKAGE",
    "CARGO_TARGET_TMPDIR", "CARGO_RUSTC_CURRENT_DIR", "OUT_DIR"]
    ## What cargo sets for a crate's compile (Cargo Book, "Environment
    ## variables Cargo sets for crates"), besides `CARGO_PKG_*` and
    ## `CARGO_BIN_EXE_*`.
  BuildScriptVariables = ["CARGO", "CARGO_MANIFEST_DIR",
    "CARGO_MANIFEST_PATH", "CARGO_MANIFEST_LINKS", "CARGO_ENCODED_RUSTFLAGS",
    "OUT_DIR", "TARGET", "HOST", "NUM_JOBS", "OPT_LEVEL", "DEBUG", "PROFILE",
    "RUSTC", "RUSTDOC", "RUSTC_LINKER", "RUSTC_WORKSPACE_WRAPPER"]
    ## What cargo sets for a build script (Cargo Book, "Environment
    ## variables Cargo sets for build scripts"), besides `CARGO_PKG_*`,
    ## `CARGO_FEATURE_*`, `CARGO_CFG_*` and `DEP_*`.

# ---------------------------------------------------------------------------
# Reading the recordings.

proc targetRel(path: string): string =
  ## `path` relative to the target directory, or "" when it is not under it.
  if path == TargetToken: return "."
  if path.startsWith(TargetToken & "/"): path[TargetToken.len + 1 .. ^1]
  else: ""

proc hashSuffix(name: string): string =
  ## The hash cargo appends to a directory or file stem: after the last `-`.
  let dash = name.rfind('-')
  if dash < 0 or dash == name.high: "" else: name[dash + 1 .. ^1]

proc lastComponent(path: string): string =
  let slash = path.rfind('/')
  if slash < 0: path else: path[slash + 1 .. ^1]

proc parentOf(path: string): string =
  let slash = path.rfind('/')
  if slash <= 0: "" else: path[0 ..< slash]

proc envValue(env: openArray[(string, string)]; name: string;
              found: var bool): string =
  found = false
  for (key, value) in env:
    if key == name:
      found = true
      return value

proc required(rec: RecordedInvocation; name, what: string): string =
  var found = false
  result = envValue(rec.env, name, found)
  if not found or result.len == 0:
    fail(what & " has no " & name & " in its recorded environment")

type
  RawUnit = object
    rec: RecordedInvocation
    unit: PlanUnit
    cargoOutDirToken: string   ## `${target}/<rel>`
    externs: seq[(int, string)] ## argv index of the value, cargo's path

  Derivation = object
    units: seq[RawUnit]
    runs: seq[PlanRun]
    runRecs: seq[RecordedInvocation]
    unitIndex: Table[string, int]       ## plan id -> units index
    outputIndex: Table[string, (int, string)]
      ## cargo's placeholder path -> (unit, plan path)
    runByCargoDir: Table[string, int]   ## `<pkg>-<hash>` -> runs index
    runOutDirs: seq[(string, int)]      ## `${target}/<OUT_DIR rel>`, run
    deps: HashSet[string]
      ## every `-L dependency=` directory cargo passed (`${target}/...`)
    searchDirs: HashSet[string]
      ## the parent of each: the profile directory cargo uplifts final
      ## artifacts into, which it also puts on a dynamic-library path
    closures: Table[string, seq[string]]

proc unitFlag(args: openArray[string]; flag: string): string =
  ## The value of `flag` (`--flag v` or `--flag=v`) in `args`, or "".
  var i = 0
  while i < args.len:
    if args[i] == flag and i + 1 < args.len: return args[i + 1]
    if args[i].startsWith(flag & "="): return args[i][flag.len + 1 .. ^1]
    inc i

proc codegenValue(args: openArray[string]; key: string): string =
  ## The value of `-C <key>=<value>` in `args`, or "".
  var i = 0
  while i < args.len:
    var value = ""
    if args[i] in ["-C", "--codegen"] and i + 1 < args.len:
      value = args[i + 1]
    elif args[i].startsWith("-C") and args[i].len > 2:
      value = args[i][2 .. ^1]
    if value.startsWith(key & "="):
      return value[key.len + 1 .. ^1]
    inc i

proc readUnit(d: var Derivation; rec: RecordedInvocation) =
  if rec.argv.len < 2:
    fail("a recorded unit has no rustc command line")
  if not rec.argv[1].startsWith("-"):
    # Cargo runs `<wrapper> <rustc> <args>`; a program between the two (a
    # workspace wrapper chained after the record wrapper) shows up here as a
    # second program before the arguments, and would run in place of rustc.
    fail("a recorded unit's command line runs " & rec.argv[0] & " " &
      rec.argv[1] & ": another program stands between the record wrapper " &
      "and rustc's arguments")
  let args = rec.argv[1 .. ^1]
  var u = PlanUnit(buildScriptCompile: rec.buildScriptCompile)
  u.crateName = unitFlag(args, "--crate-name")
  let what = "the unit of crate " & u.crateName
  u.package = required(rec, "CARGO_PKG_NAME", what)
  u.version = required(rec, "CARGO_PKG_VERSION", what)
  let extra = codegenValue(args, "extra-filename")
  if not extra.startsWith("-") or extra.len < 2:
    fail(what & " has no -C extra-filename hash, so its directory cannot " &
      "be named from cargo's own value")
  u.id = u.package & "-" & u.version & "-" & extra[1 .. ^1]
  if u.id in d.unitIndex:
    fail("two units would share the directory " & u.id)
  let outDir = unitFlag(args, "--out-dir")
  u.cargoOutDir = targetRel(outDir)
  if u.cargoOutDir.len == 0:
    fail(what & " writes outside the record run's target directory: " &
      "--out-dir " & outDir)
  let incremental = codegenValue(args, "incremental")
  if incremental.len > 0:
    u.cargoIncrementalDir = targetRel(incremental)
    if u.cargoIncrementalDir.len == 0:
      fail(what & " has an incremental directory outside the target " &
        "directory: " & incremental)
  for placeholder in rec.placeholders:
    if not placeholder.startsWith(outDir & "/"):
      fail(what & " writes " & placeholder & " outside its --out-dir")
    let file = placeholder[outDir.len + 1 .. ^1]
    let planPath = OutToken & "/" & u.id & "/" & file
    u.outputs.add planPath
    d.outputIndex[placeholder] = (d.units.len, planPath)
    if rec.buildScriptCompile and file.startsWith("build_script_") and
        not file.endsWith(".d"):
      u.executable = planPath
  if rec.buildScriptCompile and u.executable.len == 0:
    fail(what & " is a build-script compile with no executable output")
  var raw = RawUnit(rec: rec, unit: u, cargoOutDirToken: outDir)
  var i = 0
  while i < args.len:
    let arg = args[i]
    var value = ""
    var at = -1
    if arg == "--extern" and i + 1 < args.len:
      value = args[i + 1]
      at = i + 1
    elif arg.startsWith("--extern="):
      value = arg["--extern=".len .. ^1]
      at = i
    if at >= 0:
      let eq = value.find('=')
      if eq > 0 and value[eq + 1 .. ^1].startsWith(TargetToken):
        raw.externs.add (at + 1, value[eq + 1 .. ^1])  # +1: argv has rustc
    var dep = ""
    if arg == "-L" and i + 1 < args.len: dep = args[i + 1]
    elif arg.startsWith("-L"): dep = arg[2 .. ^1]
    if dep.startsWith("dependency=" & TargetToken):
      d.deps.incl dep["dependency=".len .. ^1]
    inc i
  d.unitIndex[u.id] = d.units.len
  d.units.add raw

proc readRun(d: var Derivation; rec: RecordedInvocation) =
  let what = "a build-script run (" & rec.manifest & ")"
  let outDir = required(rec, "OUT_DIR", what)
  let rel = targetRel(outDir)
  if rel.len == 0 or lastComponent(rel) != "out":
    fail(what & " has an OUT_DIR outside the record run's target " &
      "directory: " & outDir)
  let cargoDir = lastComponent(parentOf(rel))
  let hash = hashSuffix(cargoDir)
  if hash.len == 0:
    fail(what & " has an OUT_DIR whose directory carries no hash: " & outDir)
  var r = PlanRun(package: required(rec, "CARGO_PKG_NAME", what),
    version: required(rec, "CARGO_PKG_VERSION", what), cargoOutDir: rel,
    manifest: rec.manifest, manifestFrom: rec.manifestFrom,
    provider: rec.provider)
  r.id = r.package & "-" & r.version & "-" & hash
  r.outDir = OutToken & "/" & r.id & "/out"
  if cargoDir in d.runByCargoDir:
    fail("two build-script runs share cargo's directory " & cargoDir)
  d.runByCargoDir[cargoDir] = d.runs.len
  d.runOutDirs.add (outDir, d.runs.len)
  d.runs.add r
  d.runRecs.add rec

# ---------------------------------------------------------------------------
# Rewriting.

proc runIdOf(d: Derivation; cargoDir, where: string): string =
  if cargoDir notin d.runByCargoDir:
    fail(where & " names the build-script run " & cargoDir &
      ", which was not recorded")
  d.runs[d.runByCargoDir[cargoDir]].id

proc parseSentinel(d: Derivation; text, where: string): PlanSlot =
  ## The slot of the first sentinel in `text`.
  let at = text.find(SentinelMarker)
  var i = at + SentinelMarker.len
  var fields: seq[string] = @[""]
  while i < text.len and text[i] notin {'"', ')', ' ', ':', '/', '\''}:
    if text[i] == '.': fields.add ""
    else: fields[^1].add text[i]
    inc i
  if fields.len < 2 or fields[0] notin SlotKinds:
    fail(where & " carries a sentinel this plan does not know: " & text)
  result.kind = fields[0]
  result.run = d.runIdOf(fields[1], where)
  if result.kind == "rustc-link-arg-bin":
    if fields.len != 3 or fields[2].len == 0:
      fail(where & " carries a malformed rustc-link-arg-bin sentinel: " &
        text)
    result.bin = fields[2]
  elif fields.len != 2:
    fail(where & " carries a malformed sentinel: " & text)

proc mapTargetPath(d: Derivation; path, where: string): string =
  ## A `${target}` path, as the plan names it.
  if path in d.outputIndex: return d.outputIndex[path][1]
  for (outDir, run) in d.runOutDirs:
    if path == outDir or path.startsWith(outDir & "/"):
      return d.runs[run].outDir & path[outDir.len .. ^1]
  fail(where & " names " & path & " in the record run's target directory, " &
    "which is no unit's output and lies in no OUT_DIR")

proc mapEmbedded(d: Derivation; text, where: string): string =
  ## `text` with its one `${target}` path rewritten: the whole of it, or the
  ## part after `=` (`-Lnative=${target}/...`, `--emit=link=${target}/...`).
  if text.startsWith(TargetToken): return d.mapTargetPath(text, where)
  let at = text.find("=" & TargetToken)
  if at >= 0:
    return text[0 .. at] & d.mapTargetPath(text[at + 1 .. ^1], where)
  fail(where & " names the record run's target directory in a form this " &
    "plan cannot place: " & text)

proc closureDirs(d: Derivation; unitId: string): seq[string] =
  for c in d.closures[unitId]: result.add OutToken & "/" & c

proc mapPathList(d: Derivation; value, ownerId, where: string;
                 isRun: bool; fed: var HashSet[string]): string =
  ## A `:`-separated path list (the dynamic-library search path): each entry
  ## mapped, a `deps` directory expanded into the closure's directories.
  var parts: seq[string]
  for entry in value.split(':'):
    if SentinelMarker in entry:
      let slot = d.parseSentinel(entry, where)
      if isRun and slot.kind notin RunSlotKinds:
        fail(where & " carries a " & slot.kind & " slot; a build-script " &
          "run can be fed only link-search paths")
      fed.incl slot.run
      parts.add slotToken(slot)
    elif entry in d.deps or entry in d.searchDirs:
      for dir in d.closureDirs(ownerId):
        if dir notin parts: parts.add dir
    elif TargetToken in entry:
      parts.add d.mapEmbedded(entry, where)
    else:
      parts.add entry
  parts.join(":")

proc recordRunVariable(name, value: string; wrapper: string): bool =
  ## The record run's own variables, and those cargo's own process sets for
  ## itself, dropped from every difference.
  case name
  of "CARGO_MAKEFLAGS": true
  of "MAKEFLAGS", "MFLAGS": "jobserver" in value
  of "RUSTC_WRAPPER": value == wrapper
  else:
    name in CargoProcessVariables or name.startsWith(MonitorVariablePrefix)

proc cargoSetsVariable*(name: string; isRun: bool): bool =
  ## Whether cargo documents setting `name` for a crate's compile (`isRun`
  ## false) or a build script's run.
  if name.startsWith("CARGO_PKG_"): return true
  if isRun:
    name in BuildScriptVariables or name.startsWith("CARGO_FEATURE_") or
      name.startsWith("CARGO_CFG_") or name.startsWith("DEP_")
  else:
    name in CrateVariables or name.startsWith("CARGO_BIN_EXE_")

proc diffEnv(d: Derivation; rec: RecordedInvocation;
             base: Table[string, string]; wrapper, ownerId, where: string;
             isRun: bool; slots: var seq[PlanSlot];
             providers: var seq[PlanProvider]; outDirRun: var string;
             fed: var HashSet[string]):
    tuple[env: seq[(string, string)], removed: seq[string]] =
  var seen = initHashSet[string]()
  for (name, value) in rec.env:
    seen.incl name
    if recordRunVariable(name, value, wrapper): continue
    if name in base and base[name] == value and
        not cargoSetsVariable(name, isRun):
      continue
    let at = where & " (variable " & name & ")"
    if name == SentinelEnvName:
      let slot = d.parseSentinel(value, at)
      if slot.kind != "rustc-env":
        fail(at & " carries a " & slot.kind & " sentinel")
      slots.add slot
      fed.incl slot.run
      continue
    if isRun and name.startsWith("DEP_") and
        name.endsWith("___REPRO_PROVIDER"):
      # The provider is an identifier, escaped like any recorded value where
      # cargo passed it on; the plan holds it as the providing run records
      # it (`PlanRun.provider`), so the two compare equal.
      providers.add PlanProvider(
        links: name["DEP_".len ..< name.len - "___REPRO_PROVIDER".len],
        provider: value.replace("$$", "$"))
      continue
    if name == "OUT_DIR":
      var found = false
      for (outDir, run) in d.runOutDirs:
        if value == outDir:
          outDirRun = d.runs[run].id
          found = true
      if not found:
        fail(at & " is no recorded build-script run's OUT_DIR: " & value)
      result.env.add (name, OutToken & "/" & outDirRun & "/out")
      continue
    if TargetToken in value or SentinelMarker in value:
      result.env.add (name, d.mapPathList(value, ownerId, at, isRun, fed))
    else:
      result.env.add (name, value)
  for name in base.keys:
    if name notin seen and not recordedEnvSkipped(name):
      result.removed.add name
  result.env.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))
  result.removed.sort()

proc rewriteUnitArgv(d: Derivation; raw: RawUnit;
                     fed: var HashSet[string]): seq[string] =
  let u = raw.unit
  let where = "the unit " & u.id
  let argv = raw.rec.argv
  if TargetToken in argv[0]:
    fail(where & " runs a rustc in the target directory: " & argv[0])
  result.add argv[0]
  var emittedClosure = false
  var i = 1
  while i < argv.len:
    let arg = argv[i]
    let next = if i + 1 < argv.len: argv[i + 1] else: ""
    # A sentinel: one slot for the whole group cargo emitted for it.
    if SentinelMarker in arg or
        (arg in FlagsTakingAValue and SentinelMarker in next):
      let slot = d.parseSentinel(if SentinelMarker in arg: arg else: next,
        where)
      fed.incl slot.run
      result.add slotToken(slot)
      i += (if SentinelMarker in arg: 1 else: 2)
      continue
    if arg == "--out-dir":
      result.add [arg, OutToken & "/" & u.id]
      i += 2
      continue
    if arg.startsWith("--out-dir="):
      result.add "--out-dir=" & OutToken & "/" & u.id
      inc i
      continue
    var dep = ""
    var glued = false
    if arg == "-L" and next.startsWith("dependency=" & TargetToken): dep = next
    elif arg.startsWith("-Ldependency=" & TargetToken):
      dep = arg[2 .. ^1]
      glued = true
    if dep.len > 0:
      if not emittedClosure:
        for dir in d.closureDirs(u.id):
          if glued: result.add "-Ldependency=" & dir
          else: result.add ["-L", "dependency=" & dir]
        emittedClosure = true
      i += (if glued: 1 else: 2)
      continue
    var codegen = ""
    if arg in ["-C", "--codegen"]: codegen = next
    elif arg.startsWith("-C") and arg.len > 2: codegen = arg[2 .. ^1]
    if codegen.startsWith("incremental="):
      let value = "incremental=" & OutToken & "/" & u.id & "/incremental"
      if arg in ["-C", "--codegen"]:
        result.add [arg, value]
        i += 2
      else:
        result.add "-C" & value
        inc i
      continue
    if TargetToken in arg:
      result.add d.mapEmbedded(arg, where)
    else:
      result.add arg
    inc i

proc computeClosures(d: var Derivation) =
  ## Each unit's `--extern` links (`consumes`) and their transitive closure.
  for idx in 0 ..< d.units.len:
    var consumes: seq[string]
    for (_, path) in d.units[idx].externs:
      if path notin d.outputIndex:
        fail("the unit " & d.units[idx].unit.id & " links " & path &
          ", which no recorded unit wrote")
      let dep = d.units[d.outputIndex[path][0]].unit.id
      if dep notin consumes: consumes.add dep
    consumes.sort()
    d.units[idx].unit.consumes = consumes
  proc visit(d: var Derivation; id: string; stack: var HashSet[string]):
      seq[string] =
    if id in d.closures: return d.closures[id]
    if id in stack:
      fail("the units' --extern links form a cycle through " & id)
    stack.incl id
    var all = initHashSet[string]()
    for dep in d.units[d.unitIndex[id]].unit.consumes:
      all.incl dep
      for c in visit(d, dep, stack): all.incl c
    stack.excl id
    result = toSeq(all)
    result.sort()
    d.closures[id] = result
  for idx in 0 ..< d.units.len:
    var stack = initHashSet[string]()
    d.units[idx].unit.closure = visit(d, d.units[idx].unit.id, stack)

proc checkPlaced(text, where: string) =
  for token in [TargetToken, ScratchToken]:
    if token in text:
      fail(where & " still names the record run's own files (" & token &
        "): " & text)
  if SentinelMarker in text:
    fail(where & " still carries a sentinel: " & text)

proc absolutePathStartsAt(text: string; i: int): bool =
  ## Whether the `/` at `text[i]` begins an absolute path: at the start of
  ## `text`; after a separator (`=`, `:`, a space, a comma, a quote, `(`);
  ## or glued to a leading flag or argument-file sign (`-L/x`, `@/x`). Not
  ## inside a relative path (`src/lib.rs`) and not right after a root
  ## token's `}` (`${project}/x` is a logical path).
  if i == 0: return true
  let prev = text[i - 1]
  if prev in {'=', ':', ' ', ',', '"', '\'', '(', ';', '\t'}: return true
  if prev == '}' or prev == '/': return false
  var j = i - 1
  while j > 0 and text[j - 1] notin {'/', '=', ':', ' ', ','}: dec j
  j == 0 and text[0] in {'-', '@'}

proc checkNoPhysicalPath(text, where: string) =
  ## Refuse an absolute path under no logical root anywhere in `text`: a `/`
  ## that begins a path (`absolutePathStartsAt`) and is not a URL's `//`.
  var i = 0
  while i < text.len:
    if text[i] == '/' and absolutePathStartsAt(text, i):
      if i + 1 < text.len and text[i + 1] == '/':
        i += 2
        continue
      fail(where & " names an absolute path under no logical root: " & text)
    inc i

proc validatePlan*(plan: CargoPlan) =
  ## The checks every plan passes, written or read: unique ids, every
  ## reference resolved, outputs under their unit's directory, no path of
  ## the record run and no sentinel left; a refused plan holds nothing but
  ## its reason. Raises `CargoPlanError`.
  if plan.refusal.len > 0 and (plan.units.len > 0 or plan.runs.len > 0):
    fail("a refused cargo plan holds units or runs")
  var units = initHashSet[string]()
  var runs = initHashSet[string]()
  for u in plan.units:
    if u.id.len == 0 or u.id in units:
      fail("a cargo plan with a missing or repeated unit id " & u.id.escape())
    units.incl u.id
  for r in plan.runs:
    if r.id.len == 0 or r.id in runs or r.id in units:
      fail("a cargo plan with a missing or repeated run id " & r.id.escape())
    runs.incl r.id
  proc refs(ids: openArray[string]; known: HashSet[string]; what: string) =
    for id in ids:
      if id notin known:
        fail("a cargo plan whose " & what & " names " & id.escape() &
          ", which it does not hold")
  for u in plan.units:
    let where = "the unit " & u.id
    if u.argv.len == 0: fail(where & " has no command line")
    refs(u.consumes, units, where & "'s consumes")
    refs(u.closure, units, where & "'s closure")
    refs(u.fedBy, runs, where & "'s fedBy")
    if u.outDirRun.len > 0: refs([u.outDirRun], runs, where & "'s OUT_DIR")
    for s in u.envSlots: refs([s.run], runs, where & "'s slots")
    for o in u.outputs:
      if not o.startsWith(OutToken & "/" & u.id & "/"):
        fail(where & " has an output outside its directory: " & o)
    if u.buildScriptCompile and u.executable notin u.outputs:
      fail(where & " is a build-script compile whose executable is not " &
        "one of its outputs")
    for s in u.argv & u.outputs & @[u.cwd, u.executable]:
      checkPlaced(s, where)
    for (_, value) in u.env: checkPlaced(value, where)
  for r in plan.runs:
    let where = "the build-script run " & r.id
    refs([r.compileUnit], units, where & "'s compile unit")
    refs(r.fedBy, runs, where & "'s fedBy")
    if r.outDir != OutToken & "/" & r.id & "/out":
      fail(where & " has an OUT_DIR outside its directory: " & r.outDir)
    for s in r.argv & @[r.cwd, r.manifest, r.provider]: checkPlaced(s, where)
    for (_, value) in r.env: checkPlaced(value, where)
    for p in r.providers: checkPlaced(p.provider, where)

proc mapVendor*(text: string; vendorMap: openArray[(string, string)]): string =
  ## `text` with each vendor entry replaced by its prefix, where the entry
  ## is a whole path: followed by nothing, a `/` or a character that cannot
  ## continue a file name.
  result = text
  for (entry, prefix) in vendorMap:
    var i = 0
    var mapped = ""
    while i < result.len:
      let at = result.find(entry, i)
      if at < 0:
        mapped.add result[i .. ^1]
        break
      let after = at + entry.len
      mapped.add result[i ..< at]
      if after == result.len or result[after] notin {'a'..'z', 'A'..'Z',
          '0'..'9', '_', '-', '.', '+'}:
        mapped.add prefix
      else:
        mapped.add entry
      i = after
    result = mapped

proc withVendorMapped(rec: RecordedInvocation;
                      vendorMap: openArray[(string, string)]):
    RecordedInvocation =
  result = rec
  if vendorMap.len == 0: return
  result.argv = rec.argv.mapIt(mapVendor(it, vendorMap))
  result.cwd = mapVendor(rec.cwd, vendorMap)
  result.env = rec.env.mapIt((it[0], mapVendor(it[1], vendorMap)))
  result.placeholders = rec.placeholders.mapIt(mapVendor(it, vendorMap))
  result.manifest = mapVendor(rec.manifest, vendorMap)
  result.provider = mapVendor(rec.provider, vendorMap)

proc derivePlan*(recordings: openArray[RecordedInvocation];
                 baseEnv: openArray[(string, string)];
                 recordWrapper: string;
                 vendorMap: openArray[(string, string)] = []): CargoPlan =
  ## The plan of a record run. `baseEnv` is the record run's own environment,
  ## logicalized against the same roots as the recordings (`logicalize`);
  ## `recordWrapper` is the record wrapper's path, as `RUSTC_WRAPPER` names it
  ## in a recording. `vendorMap` pairs each vendor entry the record run
  ## served a crates.io crate from (`${scratch}/vendor/<name>-<version>`)
  ## with the store prefix it links to (`${store}/...`), as the run wrote
  ## them: every path under an entry is rewritten to the same path under the
  ## prefix, and an entry left unmapped fails the plan as a scratch path.
  ## Raises `CargoPlanError` (see the module docstring).
  var d = Derivation()
  var base = initTable[string, string]()
  for (name, value) in baseEnv: base[name] = value
  let mapped = recordings.mapIt(withVendorMapped(it, vendorMap))
  for rec in mapped:
    if rec.kind == rkBuildScriptRun: d.readRun(rec)
  for rec in mapped:
    if rec.kind == rkUnit: d.readUnit(rec)
  for dep in d.deps: d.searchDirs.incl parentOf(dep)
  d.computeClosures()
  for idx in 0 ..< d.units.len:
    var fed = initHashSet[string]()
    var u = d.units[idx].unit
    let where = "the unit " & u.id
    u.argv = d.rewriteUnitArgv(d.units[idx], fed)
    if TargetToken in d.units[idx].rec.cwd:
      fail(where & " runs in the target directory: " & d.units[idx].rec.cwd)
    u.cwd = d.units[idx].rec.cwd
    var providers: seq[PlanProvider]
    let diff = d.diffEnv(d.units[idx].rec, base, recordWrapper, u.id, where,
      false, u.envSlots, providers, u.outDirRun, fed)
    u.env = diff.env
    u.envRemoved = diff.removed
    u.fedBy = toSeq(fed)
    u.fedBy.sort()
    result.units.add u
  for idx in 0 ..< d.runs.len:
    var r = d.runs[idx]
    let rec = d.runRecs[idx]
    let where = "the build-script run " & r.id
    if rec.argv.len == 0: fail(where & " has no argv")
    let exeDir = parentOf(rec.argv[0])
    var compile = -1
    for u in 0 ..< d.units.len:
      if d.units[u].unit.buildScriptCompile and
          d.units[u].cargoOutDirToken == exeDir:
        compile = u
    if compile < 0:
      fail(where & " runs " & rec.argv[0] & ", which no recorded " &
        "build-script compile wrote")
    r.compileUnit = d.units[compile].unit.id
    if d.units[compile].unit.package != r.package or
        d.units[compile].unit.version != r.version:
      fail(where & " runs the build script of " &
        d.units[compile].unit.package & "@" & d.units[compile].unit.version &
        ", another package")
    if r.id in d.unitIndex:
      fail(where & " would share its directory with the unit " & r.id)
    r.argv = @[result.units[compile].executable]
    for arg in rec.argv[1 .. ^1]:
      r.argv.add(if TargetToken in arg: d.mapEmbedded(arg, where) else: arg)
    if TargetToken in rec.cwd:
      fail(where & " runs in the target directory: " & rec.cwd)
    r.cwd = rec.cwd
    var slots: seq[PlanSlot]
    var outDirRun = ""
    var fed = initHashSet[string]()
    let diff = d.diffEnv(rec, base, recordWrapper, r.compileUnit, where,
      true, slots, r.providers, outDirRun, fed)
    if slots.len > 0:
      fail(where & " received a rustc-env slot, which cargo gives compiles " &
        "only")
    if r.id in fed:
      fail(where & " would be fed by its own directives")
    r.fedBy = toSeq(fed)
    r.fedBy.sort()
    if outDirRun != r.id:
      fail(where & " received the OUT_DIR of another run")
    r.env = diff.env
    r.envRemoved = diff.removed
    r.providers.sort(proc (a, b: PlanProvider): int = cmp(a.links, b.links))
    result.runs.add r
  result.units.sort(proc (a, b: PlanUnit): int = cmp(a.id, b.id))
  result.runs.sort(proc (a, b: PlanRun): int = cmp(a.id, b.id))
  # Fail closed: nothing of the record run's own may remain.
  if result.units.len == 0:
    fail("the record run recorded no unit: cargo planned nothing to compile")
  for u in result.units:
    let where = "the unit " & u.id
    for s in u.argv & @[u.cwd]: checkNoPhysicalPath(s, where)
    for (_, value) in u.env: checkNoPhysicalPath(value, where)
  for r in result.runs:
    let where = "the build-script run " & r.id
    for s in r.argv & @[r.cwd]: checkNoPhysicalPath(s, where)
    for (_, value) in r.env: checkNoPhysicalPath(value, where)
  validatePlan(result)

proc unitById*(plan: CargoPlan; id: string): PlanUnit =
  for u in plan.units:
    if u.id == id: return u
  raise newException(KeyError, "the plan has no unit " & id)

proc runById*(plan: CargoPlan; id: string): PlanRun =
  for r in plan.runs:
    if r.id == id: return r
  raise newException(KeyError, "the plan has no run " & id)

proc isFed*(u: PlanUnit): bool =
  ## Whether the unit takes part of its command line or environment from a
  ## build-script run (a slot, or its `OUT_DIR`), so the plan alone does not
  ## complete it.
  u.fedBy.len > 0 or u.envSlots.len > 0 or u.outDirRun.len > 0

proc isFed*(r: PlanRun): bool =
  ## Whether the run's environment carries another run's link-search slot.
  r.fedBy.len > 0

# ---------------------------------------------------------------------------
# The binary record.

type
  SszText = List[byte, MaxPlanTextBytes]
  SszTextList = List[SszText, MaxPlanListItems]

  EnvPairSsz = object
    name, value: SszText

  SlotSsz = object
    kind, run, bin: SszText

  ProviderSsz = object
    links, provider: SszText

  PlanUnitSsz = object
    id, package, version, crateName: SszText
    buildScriptCompile: uint8
    cargoOutDir, cargoIncrementalDir: SszText
    argv: SszTextList
    cwd: SszText
    env: List[EnvPairSsz, MaxPlanListItems]
    envRemoved: SszTextList
    envSlots: List[SlotSsz, MaxPlanListItems]
    outputs, consumes, closure, fedBy: SszTextList
    outDirRun, executable: SszText

  PlanRunSsz = object
    id, package, version, compileUnit: SszText
    argv: SszTextList
    cwd: SszText
    env: List[EnvPairSsz, MaxPlanListItems]
    envRemoved: SszTextList
    outDir, cargoOutDir, manifest, manifestFrom, provider: SszText
    providers: List[ProviderSsz, MaxPlanListItems]
    fedBy: SszTextList

  CargoPlanSsz = object
    units: List[PlanUnitSsz, MaxPlanListItems]
    runs: List[PlanRunSsz, MaxPlanListItems]
    refusal: SszText

proc toText(s: string): SszText =
  if s.len > MaxPlanTextBytes:
    fail("a plan string exceeds " & $MaxPlanTextBytes & " bytes")
  SszText.init(toBytes(s))

proc fromText(t: SszText): string = fromBytes(t.asSeq())

proc checkCount(n: int; what: string) =
  if n > MaxPlanListItems:
    fail("a cargo plan's " & what & " exceeds " & $MaxPlanListItems &
      " items")

proc toTextList(items: openArray[string]): SszTextList =
  if items.len > MaxPlanListItems:
    fail("a plan list exceeds " & $MaxPlanListItems & " items")
  var parts: seq[SszText]
  for item in items: parts.add toText(item)
  SszTextList.init(parts)

proc fromTextList(list: SszTextList): seq[string] =
  for item in list.asSeq(): result.add fromText(item)

proc toEnv(env: openArray[(string, string)]): List[EnvPairSsz,
    MaxPlanListItems] =
  checkCount(env.len, "environment")
  var parts: seq[EnvPairSsz]
  for (name, value) in env:
    parts.add EnvPairSsz(name: toText(name), value: toText(value))
  List[EnvPairSsz, MaxPlanListItems].init(parts)

proc fromEnv(list: List[EnvPairSsz, MaxPlanListItems]):
    seq[(string, string)] =
  for pair in list.asSeq(): result.add (fromText(pair.name),
    fromText(pair.value))

proc toWire(u: PlanUnit): PlanUnitSsz =
  checkCount(u.envSlots.len, "environment slots")
  var slots: seq[SlotSsz]
  for s in u.envSlots:
    slots.add SlotSsz(kind: toText(s.kind), run: toText(s.run),
      bin: toText(s.bin))
  PlanUnitSsz(id: toText(u.id), package: toText(u.package),
    version: toText(u.version), crateName: toText(u.crateName),
    buildScriptCompile: (if u.buildScriptCompile: 1'u8 else: 0'u8),
    cargoOutDir: toText(u.cargoOutDir),
    cargoIncrementalDir: toText(u.cargoIncrementalDir),
    argv: toTextList(u.argv), cwd: toText(u.cwd), env: toEnv(u.env),
    envRemoved: toTextList(u.envRemoved),
    envSlots: List[SlotSsz, MaxPlanListItems].init(slots),
    outputs: toTextList(u.outputs), consumes: toTextList(u.consumes),
    closure: toTextList(u.closure), fedBy: toTextList(u.fedBy),
    outDirRun: toText(u.outDirRun), executable: toText(u.executable))

proc fromWire(w: PlanUnitSsz): PlanUnit =
  if w.buildScriptCompile > 1'u8:
    fail("malformed cargo plan: buildScriptCompile is " &
      $w.buildScriptCompile)
  result = PlanUnit(id: fromText(w.id), package: fromText(w.package),
    version: fromText(w.version), crateName: fromText(w.crateName),
    buildScriptCompile: w.buildScriptCompile == 1'u8,
    cargoOutDir: fromText(w.cargoOutDir),
    cargoIncrementalDir: fromText(w.cargoIncrementalDir),
    argv: fromTextList(w.argv), cwd: fromText(w.cwd), env: fromEnv(w.env),
    envRemoved: fromTextList(w.envRemoved),
    outputs: fromTextList(w.outputs), consumes: fromTextList(w.consumes),
    closure: fromTextList(w.closure), fedBy: fromTextList(w.fedBy),
    outDirRun: fromText(w.outDirRun), executable: fromText(w.executable))
  for s in w.envSlots.asSeq():
    result.envSlots.add PlanSlot(kind: fromText(s.kind), run: fromText(s.run),
      bin: fromText(s.bin))

proc toWire(r: PlanRun): PlanRunSsz =
  checkCount(r.providers.len, "providers")
  var providers: seq[ProviderSsz]
  for p in r.providers:
    providers.add ProviderSsz(links: toText(p.links),
      provider: toText(p.provider))
  PlanRunSsz(id: toText(r.id), package: toText(r.package),
    version: toText(r.version), compileUnit: toText(r.compileUnit),
    argv: toTextList(r.argv), cwd: toText(r.cwd), env: toEnv(r.env),
    envRemoved: toTextList(r.envRemoved), outDir: toText(r.outDir),
    cargoOutDir: toText(r.cargoOutDir), manifest: toText(r.manifest),
    manifestFrom: toText(r.manifestFrom), provider: toText(r.provider),
    providers: List[ProviderSsz, MaxPlanListItems].init(providers),
    fedBy: toTextList(r.fedBy))

proc fromWire(w: PlanRunSsz): PlanRun =
  result = PlanRun(id: fromText(w.id), package: fromText(w.package),
    version: fromText(w.version), compileUnit: fromText(w.compileUnit),
    argv: fromTextList(w.argv), cwd: fromText(w.cwd), env: fromEnv(w.env),
    envRemoved: fromTextList(w.envRemoved), outDir: fromText(w.outDir),
    cargoOutDir: fromText(w.cargoOutDir), manifest: fromText(w.manifest),
    manifestFrom: fromText(w.manifestFrom), provider: fromText(w.provider),
    fedBy: fromTextList(w.fedBy))
  for p in w.providers.asSeq():
    result.providers.add PlanProvider(links: fromText(p.links),
      provider: fromText(p.provider))

proc encodeCargoPlan*(plan: CargoPlan): seq[byte] =
  ## The plan as its binary record (see the module docstring).
  if plan.units.len > MaxPlanListItems or plan.runs.len > MaxPlanListItems:
    fail("a cargo plan exceeds " & $MaxPlanListItems & " units or runs")
  var units: seq[PlanUnitSsz]
  for u in plan.units: units.add toWire(u)
  var runs: seq[PlanRunSsz]
  for r in plan.runs: runs.add toWire(r)
  let wire = CargoPlanSsz(
    units: List[PlanUnitSsz, MaxPlanListItems].init(units),
    runs: List[PlanRunSsz, MaxPlanListItems].init(runs),
    refusal: toText(plan.refusal))
  var payload: seq[byte]
  try:
    payload = SSZ.encode(wire)
  except SszError as err:
    fail("could not encode the cargo plan: " & err.msg)
  except IOError as err:
    fail("could not encode the cargo plan: " & err.msg)
  if payload.len.uint64 > high(uint32).uint64:
    fail("a cargo plan's payload exceeds the record's 32-bit length")
  result.writeString(CargoPlanMagic)
  result.writeU16Le(CargoPlanSchemaVersion)
  result.writeU32Le(uint32(payload.len))
  result.add payload

proc decodeCargoPlan*(bytes: openArray[byte]): CargoPlan =
  ## The inverse of `encodeCargoPlan`. Raises `CargoPlanError` on a wrong
  ## magic, an unknown schema version, a length that does not match, or a
  ## payload that is not a valid SSZ plan.
  var pos = 0
  var magic: string
  var version: uint16
  var length: uint32
  try:
    magic = readString(bytes, pos)
    if magic != CargoPlanMagic:
      fail("not a cargo plan: the record's magic is " & magic.escape())
    version = readU16Le(bytes, pos)
    length = readU32Le(bytes, pos)
  except EnvelopeError as err:
    fail("a truncated cargo plan: " & err.msg)
  if version != CargoPlanSchemaVersion:
    fail("unsupported cargo plan schema version " & $version)
  if uint64(pos) + uint64(length) != uint64(bytes.len):
    fail("a cargo plan whose length does not match: " & $length &
      " payload bytes declared, " & $(bytes.len - pos) & " present")
  var wire: CargoPlanSsz
  try:
    wire = SSZ.decode(bytes.toOpenArray(pos, bytes.high), CargoPlanSsz)
  except SszError as err:
    fail("an invalid cargo plan payload: " & err.msg)
  except IOError as err:
    fail("an unreadable cargo plan payload: " & err.msg)
  for u in wire.units.asSeq(): result.units.add fromWire(u)
  for r in wire.runs.asSeq(): result.runs.add fromWire(r)
  result.refusal = fromText(wire.refusal)
  validatePlan(result)

proc writeCargoPlan*(path: string; plan: CargoPlan) =
  ## Write the plan's record to `path` through a temporary file, flushed to
  ## disk before it is renamed into place, so a reader never sees half a
  ## plan, and a crash never leaves a renamed but unwritten one. A failed
  ## write removes the temporary file.
  let bytes = encodeCargoPlan(plan)
  let partial = path & ".partial"
  try:
    var f = open(partial, fmWrite)
    try:
      if bytes.len > 0 and
          f.writeBuffer(unsafeAddr bytes[0], bytes.len) != bytes.len:
        raise newException(IOError, "short write to " & partial)
      f.flushFile()
      when defined(posix):
        if posix.fsync(f.getOsFileHandle()) != 0:
          raise newException(IOError, "fsync failed for " & partial)
    finally:
      f.close()
    moveFile(partial, path)
    when defined(posix):
      let dirFd = posix.open(parentDir(absolutePath(path)).cstring, O_RDONLY)
      if dirFd >= 0:
        discard posix.fsync(dirFd)
        discard posix.close(dirFd)
  except CatchableError as err:
    if fileExists(partial): removeFile(partial)
    if err of CargoPlanError: raise
    fail("could not write the cargo plan " & path & ": " & err.msg)

proc readCargoPlan*(path: string): CargoPlan =
  decodeCargoPlan(toBytes(readFile(path)))
