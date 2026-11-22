## Native overrides and binary packages of the Nimble packages a lock pins
## (Nimble-Package-Catalog.md § 11.3, § 11.4).
##
## * ``nativeOverridesFor`` -- NPC-AREQ24. A native override (`[[native]]`
##   of the pinned index's source set) names a package AND a version range;
##   it applies to a locked package only when the locked version is in the
##   range. A name alone matches nothing: the rule for `jester >= 0.5` does
##   not reach `jester` 0.4.
## * ``planNimbleBinaries`` -- NPC-AREQ23. A package with `bin` or
##   `namedBin` is built by the Nim convention's executable path from its
##   store tree: `nim c` (or the record's backend) of each entry, with the
##   closure's `--path:` roots and the applied overrides' defines and
##   `passC` / `passL`. Nimble's install hooks, tasks and `binDir` side
##   effects are never run, so a package whose record has `has_hooks` is
##   refused, naming the hook, unless an applied override supplies how its
##   binaries are built (`binaries`).
## * ``buildNimbleBinaries`` -- runs a plan's compiles as engine edges, so
##   they are cached, monitored and isolated like every Nim edge.
## * ``nimbleCheck`` -- `repro nimble check`: per locked package, the
##   overrides that apply, every `foreignDep` no override maps (reported,
##   never a failure of resolution), the binaries and why one cannot be
##   built, and the modules Nimble's install rules would not install.

import std/[algorithm, options, os, sets, strutils, tables]

import repro_build_engine
import repro_lock
import repro_nimble_index
import repro_nimble_reader
import repro_nimble_generator/source_set
import repro_solver/version_constraints

import ./nimble_lock

type
  NimbleBinary* = object
    name*: string    ## the executable's file name (without the platform suffix)
    source*: string  ## the absolute Nim source it is compiled from

  NimbleBinaryPlan* = object
    package*: string
    version*: string
    backend*: string        ## `c`, `cpp` or `js`
    binaries*: seq[NimbleBinary]
    paths*: seq[string]     ## `--path:` roots: the lock's packages, build order
    defines*, passC*, passL*: seq[string]
    overrides*: seq[NativeOverride] ## the applied ones
    refusal*: string        ## why the package cannot be built as a binary

  NimbleBinaryBuild* = object
    plan*: NimbleBinaryPlan
    outputs*: seq[string]   ## the built executables, in the plan's order
    failures*: seq[string]

proc versionRangeOf(n: NativeOverride): Option[SemverRange] =
  let reading = readRequirements(n.package & " " & n.versions)
  if reading.errors.len == 0 and reading.requirements.len == 1 and
      reading.requirements[0].version.kind == vkRange:
    result = some(reading.requirements[0].version.range)

proc nativeOverridesFor*(name, version: string;
                         natives: openArray[NativeOverride]):
    seq[NativeOverride] =
  ## The native overrides of package ``name`` whose range admits
  ## ``version`` (a solver version, `1.2.0`). A pseudo-version (`#head`)
  ## is in no range, so no override applies to it.
  let parsed = try: some(parseSemver(version))
               except CatchableError: none(SemverVersion)
  if parsed.isNone:
    return
  for n in natives:
    if repro_nimble_reader.nameKey(n.package) !=
        repro_nimble_reader.nameKey(name):
      continue
    let r = versionRangeOf(n)
    if r.isSome and satisfies(parsed.get, r.get):
      result.add n

proc nativeOverridesFor*(p: LockedNimblePackage;
                         natives: openArray[NativeOverride]):
    seq[NativeOverride] =
  nativeOverridesFor(p.row.name, p.version, natives)

proc hooksOf(p: LockedNimblePackage): seq[string] =
  ## The install hooks the package's `.nimble` in its verified tree
  ## declares (`before install`, `after install`). Read statically; the
  ## bodies are never run. Empty when the file cannot be found or read.
  if p.storePath.len == 0 or not dirExists(p.storePath):
    return
  for kind, path in walkDir(p.storePath):
    if kind in {pcFile, pcLinkToFile} and path.endsWith(".nimble"):
      try:
        result = readNimbleSource(readFile(path), extractFilename(path)).hooks
      except CatchableError:
        discard
      return

proc recordBinaries(rec: VersionRecord; plat: NimblePlatform;
                    nim: Option[NimVersionValue]; undecided: var string):
    tuple[bin: seq[string]; named: seq[NamedBin]] =
  ## `bin` and `namedBin` on ``plat`` at Nim ``nim``: the plain
  ## assignments, then the conditional ones whose condition holds there (an
  ## append extends, an assignment replaces), in record order. An
  ## assignment whose condition depends on the Nim version when ``nim`` is
  ## none sets ``undecided`` to that condition.
  result.bin = rec.binaries.bin
  result.named = rec.binaries.namedBin
  for c in rec.layout.conditional:
    if c.field notin {rfBin, rfNamedBin}: continue
    let t = decideOn(c.condition, plat, nim)
    if t == tUnknown and undecided.len == 0:
      undecided = renderCondition(c.condition)
    if t != tTrue: continue
    case c.field
    of rfBin:
      if c.append: result.bin.add c.values
      else: result.bin = c.values
    of rfNamedBin:
      if c.append: result.named.add c.pairs
      else: result.named = c.pairs
    else: discard

proc insideTree(root, rel: string): string =
  ## ``root``/``rel`` when ``rel`` stays inside ``root``, else "".
  let r = rel.replace('\\', '/')
  if r.len == 0 or r.isAbsolute or ".." in r.split('/'):
    return ""
  root / r

proc planNimbleBinaries*(report: NimbleSourcesReport;
                         p: LockedNimblePackage): NimbleBinaryPlan =
  ## See the module header. A package with no `bin` or `namedBin` has an
  ## empty plan and no refusal.
  let plat = nimblePlatformOf(report.platform)
  result.package = p.row.name
  result.version = p.version
  result.paths = report.nimPathDirs
  result.overrides = nativeOverridesFor(p, report.natives)
  for o in result.overrides:
    result.defines.add o.defines
    result.passC.add o.passC
    result.passL.add o.passL
  result.backend =
    if p.record.binaries.backend.len > 0: p.record.binaries.backend else: "c"
  if result.backend notin ["c", "cpp", "js"]:
    result.refusal = "nimble:" & p.row.name & " " & p.version &
      ": backend " & result.backend.escape() & " is not one the Nim " &
      "convention builds"
    return
  var supplied: seq[string]
  for o in result.overrides: supplied.add o.binaries
  var undecided = ""
  let (bins, named) = recordBinaries(p.record, plat,
    nimVersionValueOf(report.solvedNim), undecided)
  if undecided.len > 0:
    result.refusal = "nimble:" & p.row.name & " " & p.version & ": its " &
      "binaries depend on the Nim version (`" & undecided & "`), and the " &
      "lock records no Nim: declare `uses: nim` and re-lock"
    return
  if bins.len == 0 and named.len == 0 and supplied.len == 0:
    return
  if flHasHooks in p.record.flags and supplied.len == 0:
    var hooks = hooksOf(p)
    if hooks.len == 0: hooks = @["an install hook"]
    result.refusal = "nimble:" & p.row.name & " " & p.version &
      " is refused as a binary package: its `.nimble` declares " &
      hooks.join(" and ") & ", which Reprobuild never runs, and no " &
      "native override (`[[native]]` with `binaries`) of the pinned " &
      "index for this version says how to build it without"
    return
  if supplied.len > 0:
    # The override says how the binaries are built: paths relative to the
    # package's tree.
    for b in supplied:
      let eq = b.find('=')
      let src = insideTree(p.storePath, b[eq + 1 .. ^1])
      if src.len == 0:
        result.refusal = "nimble:" & p.row.name & ": override binary " &
          b.escape() & " leaves the package's tree"
        return
      result.binaries.add NimbleBinary(name: b[0 ..< eq], source: src)
  else:
    # Nimble's layout: each entry names `<srcDir>/<entry>.nim`; `namedBin`
    # maps a source entry to another executable name.
    for b in bins:
      let src = insideTree(p.srcPath, b & ".nim")
      if src.len == 0:
        result.refusal = "nimble:" & p.row.name & ": bin " & b.escape() &
          " leaves the package's tree"
        return
      result.binaries.add NimbleBinary(name: extractFilename(b), source: src)
    for nb in named:
      let src = insideTree(p.srcPath, nb.key & ".nim")
      if src.len == 0 or nb.value.len == 0 or '/' in nb.value:
        result.refusal = "nimble:" & p.row.name & ": namedBin " &
          (nb.key & "=" & nb.value).escape() & " is not a source inside " &
          "the tree and a file name"
        return
      result.binaries.add NimbleBinary(name: nb.value, source: src)
  for b in result.binaries:
    if not fileExists(b.source):
      result.refusal = "nimble:" & p.row.name & " " & p.version & ": the " &
        "binary " & b.name & " is built from " & b.source & ", which the " &
        "verified tree does not hold"
      return

proc binaryArgv*(plan: NimbleBinaryPlan; b: NimbleBinary;
                 nimExe, outDir, nimcacheRoot: string): seq[string] =
  ## The compile of one binary: the Nim convention's executable path, with
  ## the isolation every Nim edge has (`--noNimblePath`, no user or parent
  ## configuration) and only the lock's roots on the search path.
  result = @[nimExe, plan.backend, "--skipUserCfg", "--skipParentCfg",
    "--noNimblePath", "--hints:off"]
  for d in plan.paths: result.add "--path:" & d
  for d in plan.defines: result.add "-d:" & d
  for c in plan.passC: result.add "--passC:" & c
  for l in plan.passL: result.add "--passL:" & l
  result.add "--nimcache:" & (nimcacheRoot / (plan.package & "-" & b.name))
  result.add "--out:" & (outDir / addFileExt(b.name, ExeExt))
  result.add b.source

proc buildNimbleBinaries*(plan: NimbleBinaryPlan;
                          nimExe, outDir, stateDir: string):
    NimbleBinaryBuild =
  ## Build every binary of ``plan`` as engine edges under ``stateDir``
  ## (the engine's cache and the nimcache), into ``outDir``. A refused plan
  ## builds nothing and reports its refusal.
  result.plan = plan
  if plan.refusal.len > 0:
    result.failures.add plan.refusal
    return
  if plan.binaries.len == 0:
    return
  createDir(outDir)
  createDir(stateDir)
  var actions: seq[BuildAction]
  for b in plan.binaries:
    let output = outDir / addFileExt(b.name, ExeExt)
    let argv = binaryArgv(plan, b, nimExe, outDir, stateDir / "nimcache")
    actions.add action("nimble.bin/" & plan.package & "/" & b.name, argv,
      cwd = outDir, inputs = [b.source], outputs = [output],
      cacheable = false,
      weakFingerprint = weakFingerprintFromText(argv.join("\n")),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    result.outputs.add output
  var cfg = defaultBuildEngineConfig(stateDir / "engine-cache")
  cfg.maxParallelism = 1
  cfg.bypassRunQuota = true
  cfg.deferLocalOutputBlobs = false
  let run = runBuild(graph(actions), cfg)
  for res in run.results:
    if res.status == asFailed:
      result.failures.add res.id & ": " & (res.stderr & res.stdout).strip()

proc uninstalledModules(p: LockedNimblePackage): seq[string] =
  ## The top-level modules of the package's source directory that Nimble's
  ## install rules (`installDirs`/`installFiles`/`installExt`, else
  ## `skipDirs`/`skipFiles`/`skipExt`) would not install (NPC-AREQ21). The
  ## whole tree is stored, so they compile here; a build that relies on one
  ## would not build with Nimble.
  let l = p.record.layout
  for m in l.modules:
    let file = m & ".nim"
    var installed = true
    if l.installDirs.len + l.installFiles.len + l.installExt.len > 0:
      installed = file in l.installFiles or m in l.installDirs or
        "nim" in l.installExt
    else:
      installed = file notin l.skipFiles and m notin l.skipDirs and
        "nim" notin l.skipExt
    if not installed:
      result.add m

proc nimbleCheck*(report: NimbleSourcesReport): tuple[lines: seq[string];
                                                       refused: int] =
  ## `repro nimble check` over a prepared lock (see the module header). One
  ## block per locked package; ``refused`` counts the packages whose
  ## binaries cannot be built. An unmapped `foreignDep` is reported and is
  ## not a refusal (NPC-AREQ24: it never fails resolution by itself).
  let plat = nimblePlatformOf(report.platform)
  for p in report.packages:
    result.lines.add "nimble:" & p.row.name & " " & p.version
    let applied = nativeOverridesFor(p, report.natives)
    for o in applied:
      var parts: seq[string]
      if o.nativeBuildDeps.len > 0:
        parts.add "native build deps " & o.nativeBuildDeps.join(", ")
      if o.runtimeDeps.len > 0:
        parts.add "runtime deps " & o.runtimeDeps.join(", ")
      if o.defines.len > 0: parts.add "defines " & o.defines.join(", ")
      if o.passC.len > 0: parts.add "passC " & o.passC.join(" ")
      if o.passL.len > 0: parts.add "passL " & o.passL.join(" ")
      if o.binaries.len > 0: parts.add "binaries " & o.binaries.join(", ")
      result.lines.add "  override applied (" & o.package & " " &
        o.versions & "): " & parts.join("; ")
    var mapped = initHashSet[string]()
    for o in applied:
      if o.nativeBuildDeps.len + o.runtimeDeps.len + o.passL.len > 0:
        mapped.incl "*"
    for f in p.record.foreign:
      let t = decideOn(f.condition, plat, nimVersionValueOf(report.solvedNim))
      if t == tUnknown:
        result.lines.add "  native dependency " & f.name & " depends on " &
          "the Nim version (`" & renderCondition(f.condition) & "`), and " &
          "the lock records no Nim to decide it"
        continue
      if t != tTrue: continue
      if "*" notin mapped:
        result.lines.add "  unmapped native dependency: " & f.name &
          " (foreignDep; no native override of this version supplies it)"
    let plan = planNimbleBinaries(report, p)
    if plan.refusal.len > 0:
      inc result.refused
      result.lines.add "  binary refused: " & plan.refusal
    for b in plan.binaries:
      result.lines.add "  binary " & b.name & " from " & b.source
    for m in uninstalledModules(p):
      result.lines.add "  module " & m & " is not one Nimble would install"

proc runNimbleCheckCommand*(lockFlag, storeFlag: string): int =
  ## `repro nimble check`: 0 when every locked package that has binaries can
  ## be built (reports are printed either way), 1 when a binary package is
  ## refused, 2 when the lock cannot be prepared (unreadable, a row the
  ## pinned index does not hold, a tree the store lacks). Offline: it opens
  ## no connection and runs no `nimble`.
  let lockPath = absolutePath(if lockFlag.len > 0: lockFlag
                              else: getCurrentDir() / "repro.lock")
  try:
    if not fileExists(lockPath):
      raise newException(ValueError, "no lock at " & lockPath)
    let report = prepareLockedNimbleSources(parentDir(lockPath), lockPath,
      NimbleSourcesOptions(offline: true,
        storeRoot: (if storeFlag.len > 0: absolutePath(storeFlag) else: "")))
    if not report.active:
      echo "no nimble: packages in " & lockPath
      return 0
    let checked = nimbleCheck(report)
    for line in checked.lines: echo line
    if checked.refused == 0:
      echo "checked: " & $report.packages.len & " package(s) of " & lockPath
      0
    else:
      echo "not buildable: " & $checked.refused & " of " &
        $report.packages.len & " package(s) of " & lockPath &
        " cannot be built as binary packages"
      1
  except CatchableError as err:
    stderr.writeLine("repro nimble check: error: " & err.msg)
    2
