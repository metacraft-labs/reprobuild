## Shared scaffolding for the NLF-M8 diamond tests.
##
## Not named `t_*` / `test_*`, so `scripts/generate_test_edges.nim` does not
## register it as a test binary of its own.
##
## ## What this file is
##
## The bridge from a RECIPE — packages with tagged dependency lists, their
## `multiVersion` declarations, and the artifacts that designate a lock file —
## to the two things §9 is about:
##
##   1. **one joint solve** over instance-qualified packages, carrying the
##      unification objective, so the answer to "how many instances of
##      `libfoo` are there" is the SOLVER's and not a partition computed
##      beside it;
##   2. **the link closures** that answer to, so the co-linking check is asked
##      of one binary at a time.
##
## `nlf_m7_fixture` solves once per lock file, which is the right shape for
## the propagation questions NLF-M7 asks and the wrong one here: two
## independent solves cannot unify, and NLF-DIA-6 exists precisely to catch an
## implementation that "splits per lock file *by construction*". So this
## fixture builds ONE program from ALL lock files' edges and hands it to the
## real solver.
##
## ## Test-double policy — read this before reaching for a mock
##
## There are NO mocks, stubs, fakes or doubles here or in any test that
## imports this file. The solve below is the real `repro_solver.solve` driving
## real `libclingo.so` through the real `{.dynlib.}` FFI; the encoding is the
## real `encodeUnified`; the propagation is the real `propagate`; the
## diagnostic strings are the real ones a build prints.
##
## What is synthetic is the CONTENT — the recipes and the published version
## lists are written by the tests rather than read from a registry — and that
## bounds the conclusions: these tests conclude things about how a diamond is
## solved and diagnosed, because the solving and the diagnosing are real. They
## conclude nothing about any particular upstream registry.
##
## The registry is deliberately NOT started here. `nlf_m7_fixture` needs it
## because a lock GENERATION fetches metadata over real HTTP; nothing in §9
## does, and starting a listener a test never reads from would make every case
## slower and would put a network failure mode in front of a question that has
## none.

import std/[algorithm, sets, tables]

import repro_lock_files
import repro_solver

export repro_lock_files
export repro_solver

type
  M8Dep* = object
    ## One dependency edge as a recipe writes it: the child, the range, and
    ## WHICH of §4.6's three lists it was written in. The list is what decides
    ## whether the edge is a LINK — see `diamond.nim`'s header.
    name*: string
    constraint*: string
    platform*: DepPlatform

  M8Package* = object
    name*: string
    versions*: seq[string]
    pinnedLockFile*: string
    language*: string
      ## The language convention the library inherits from when it declares
      ## no `multiVersion` (Q-11). Defaults to `c` in `m8pkg`, because C is
      ## the case §9.3 argues the default from and the one the corpus's
      ## inherited-default case (NLF-DIA-8) is written against.
    multiVersion*: MultiVersionPolicy
    sourceFile*: string
    sourceLine*: int
    deps*: seq[M8Dep]

  M8Artifact* = object
    name*: string
    package*: string
    lockFile*: string

  M8Recipe* = object
    packages*: seq[M8Package]
    artifacts*: seq[M8Artifact]

  M8Solved* = object
    ## Everything a diamond test asks about, from one real solve.
    program*: InstancedProgram
    input*: UnificationInput
    chosen*: Table[string, string]
    coalesced*: seq[CoalescedInstance]
    closures*: seq[LinkClosure]
    conflicts*: seq[ColinkingConflict]
    splits*: seq[SplitReport]
    programText*: string

proc m8dep*(name, constraint: string; platform = dpTarget): M8Dep =
  M8Dep(name: name, constraint: constraint, platform: platform)

proc m8pkg*(name: string; versions: openArray[string] = @[];
            deps: openArray[M8Dep] = @[]; pinnedLockFile = "";
            language = "c"; multiVersion = mvUnset;
            sourceFile = ""; sourceLine = 0): M8Package =
  M8Package(name: name, versions: @versions, pinnedLockFile: pinnedLockFile,
    language: language, multiVersion: multiVersion, sourceFile: sourceFile,
    sourceLine: sourceLine, deps: @deps)

proc m8artifact*(name, package: string; lockFile = ""): M8Artifact =
  M8Artifact(name: name, package: package, lockFile: lockFile)

proc linkPackagesOf*(r: M8Recipe): seq[LinkPackage] =
  result = @[]
  for p in r.packages:
    var deps: seq[LinkDep] = @[]
    for d in p.deps:
      deps.add(linkDep(d.name, d.constraint, d.platform))
    result.add(linkPackage(p.name, deps, p.pinnedLockFile, p.language,
      p.multiVersion, p.sourceFile, p.sourceLine))

proc rootsOf*(r: M8Recipe): seq[PropRoot] =
  result = @[]
  for a in r.artifacts:
    result.add(PropRoot(artifact: a.name, package: a.package,
      lockFile: a.lockFile))

proc propagationOf*(r: M8Recipe): PropagationResult =
  propagate(rootsOf(r), asPropPackages(linkPackagesOf(r)))

proc unificationInputOf*(r: M8Recipe): UnificationInput =
  ## Every demand edge in the workspace, with §4.6's precedence already
  ## applied to decide the governing lock file of each.
  ##
  ## The walk is per (package, lock file) — the same pairs `propagate`
  ## enumerates — because a package reached under two lock files declares its
  ## `uses:` twice, once into each graph. That is §4.2's "the lock file's
  ## constraint set is the union of the `uses:` of everything designated to
  ## it, transitively".
  result = initUnificationInput()
  var byName = initTable[string, M8Package]()
  for p in r.packages:
    byName[p.name] = p
    if p.versions.len > 0:
      result.candidates[p.name] = p.versions

  let prop = propagationOf(r)
  var seenEdge = initHashSet[string]()
  for package, lockFiles in prop.lockFilesByPackage.pairs:
    if not byName.hasKey(package): continue
    for lock in lockFiles:
      for d in byName[package].deps:
        let depPin =
          if byName.hasKey(d.name): byName[d.name].pinnedLockFile else: ""
        let childLock = childLockFile(lock,
          PropDep(name: d.name, platform: d.platform), depPin)
        let key = package & "\x1f" & d.name & "\x1f" & childLock
        if key in seenEdge: continue
        seenEdge.incl(key)
        result.edges.add(DemandEdge(demander: package, library: d.name,
          constraint: d.constraint, lockFile: childLock))

  for a in r.artifacts:
    let pin =
      if byName.hasKey(a.package): byName[a.package].pinnedLockFile else: ""
    let lock =
      if pin.len > 0: pin
      elif a.lockFile.len > 0: a.lockFile
      else: DefaultLockFileName
    result.roots.add((package: a.package, lockFile: lock))

proc solvedInstancesOf(input: UnificationInput;
                       coalesced: seq[CoalescedInstance]):
    seq[SolvedInstance] =
  ## Project the solver's answer onto the flat record `findSplits` reads.
  ##
  ## The split RULE — how many versions is too many, and what a report says —
  ## lives in `repro_lock_files/diamond.findSplits`, not here. A fixture that
  ## computed it would let the product ship without it and still show green,
  ## which is the shape this campaign exists to catch.
  result = @[]
  for c in coalesced:
    for lock in c.lockFiles:
      var matched = false
      for e in input.edges:
        if e.library != c.library or e.lockFile != lock: continue
        if e.demander.len > 0 and e.demander notin c.demanders: continue
        matched = true
        result.add(SolvedInstance(library: c.library, version: c.version,
          lockFile: lock, constraint: e.constraint))
      if not matched:
        result.add(SolvedInstance(library: c.library, version: c.version,
          lockFile: lock, constraint: ""))

proc solveDiamond*(r: M8Recipe): M8Solved =
  ## One real joint solve, then the link closures and the check.
  ##
  ## Raises whatever `repro_solver.solve` raises. A diamond that reaches this
  ## proc and comes back UNSAT is a genuine finding, not a fixture failure:
  ## §9.1's objective exists so that irreconcilable constraints SPLIT rather
  ## than fail, and a test that saw an `EUnsatisfiable` here would be seeing
  ## the objective not fire.
  let input = unificationInputOf(r)
  let program = buildInstancedProgram(input)
  let solution = solve(@[], program.packages)
  let coalesced = coalesceInstances(program, solution.packages)
  let packages = linkPackagesOf(r)
  let closures = linkClosures(rootsOf(r), packages,
    proc(demander, library, lockFile: string): string =
      versionForEdge(program, solution.packages, demander, library, lockFile))
  M8Solved(
    program: program, input: input, chosen: solution.packages,
    coalesced: coalesced, closures: closures,
    conflicts: findColinkingConflicts(closures, packages),
    splits: findSplits(solvedInstancesOf(input, coalesced)),
    programText: encodeUnified(@[], program.packages))

proc closureFor*(s: M8Solved; binary: string): LinkClosure =
  for c in s.closures:
    if c.binary == binary: return c
  LinkClosure(binary: binary, reached: @[])

proc versionsReached*(s: M8Solved; binary, library: string): seq[string] =
  ## The distinct versions of `library` that `binary`'s LINK closure reaches.
  ## Sorted, so an assertion on it is order-independent (§1.3).
  var seen = initHashSet[string]()
  result = @[]
  for reached in s.closureFor(binary).reached:
    if reached.library != library: continue
    if reached.version.len == 0 or reached.version in seen: continue
    seen.incl(reached.version)
    result.add(reached.version)
  result.sort()

proc conflictFor*(s: M8Solved; binary, library: string): ColinkingConflict =
  for c in s.conflicts:
    if c.binary == binary and c.library == library: return c
  ColinkingConflict(binary: "", library: "")

proc hasConflict*(s: M8Solved; binary, library: string): bool =
  s.conflictFor(binary, library).binary.len > 0

proc splitFor*(s: M8Solved; library: string): SplitReport =
  for r in s.splits:
    if r.library == library: return r
  SplitReport(library: "")

proc solvedVersionsOf*(s: M8Solved; library: string): seq[string] =
  ## Every version of `library` the WORKSPACE built, across all lock files.
  ## Distinct from `versionsReached`, which is per binary — and the distinction
  ## is the whole of the corpus's scope rule.
  result = @[]
  for c in s.coalesced:
    if c.library == library and c.version notin result:
      result.add(c.version)
  result.sort()
