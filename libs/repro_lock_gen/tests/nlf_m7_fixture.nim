## Shared scaffolding for the NLF-M7 propagation tests.
##
## Not named `t_*` / `test_*`, so `scripts/generate_test_edges.nim` does not
## register it as a test binary of its own.
##
## ## What this file is
##
## The bridge from a RECIPE — packages, their tagged dependency lists, and the
## artifacts that designate a lock file — to the thing the design says a lock
## file IS: "one complete pinned solved graph" (§3). `propagate` (in
## `repro_lock_files`) answers WHICH packages fall under WHICH lock file;
## `solvePerLockFile` below turns each of those closures into a real
## generation request and runs a real solve. So a test can assert on the
## RESOLVED VERSION rather than on the propagation table alone, which is what
## corpus case NLF-PROP-3 asks for in terms.
##
## ## The one modelling decision worth stating
##
## A dependency edge whose child resolves under a DIFFERENT lock file is
## excluded from the parent's solve. That is not a simplification; it is the
## whole mechanism. §4.6: "`nativeBuildDeps:` resolves under the `hostTools`
## lock file; `buildDeps:` and `runtimeDeps:` resolve under the consuming
## artifact's lock file." If the parent's graph kept the constraint, both
## graphs would carry it and §13.2's limitation would be back — "the solver is
## specified to produce one concrete package instance per solved package node,
## so it cannot currently give `libfoo` two instances no matter which list it
## is written in". Two graphs is the answer; one graph carrying both
## constraints is the bug.
##
## ## Test-double policy — read this before reaching for a mock
##
## There are NO mocks, stubs, fakes or doubles here or in any test that
## imports this file. `nlf_m6_fixture`'s header states the policy in full and
## this file inherits it verbatim: a real TCP listener speaking real HTTP/1.1,
## the real in-process fetch client, real `BuildAction`s executed by the real
## `runBuild`, real clingo solves through the real `{.dynlib.}` FFI, and locks
## written and read back by the real `repro_lock` writer and reader.
##
## What is synthetic is the CONTENT — the recipe and the published version
## lists are written by the test rather than by a real registry — and that
## bounds the conclusions: these tests conclude things about how designation
## partitions a solve, because the partitioning and the solving are real. They
## conclude nothing about any particular upstream registry.

import std/[algorithm, options, sets, tables]

import repro_lock_files
import repro_lock_gen
import repro_solver

import ./nlf_m6_fixture

export nlf_m6_fixture
export repro_lock_files

type
  RecipeDep* = object
    ## One dependency edge as a recipe writes it: a constraint plus WHICH of
    ## the three approved lists it was written in.
    name*: string
    constraint*: string
    platform*: DepPlatform
    gateVariant*: string
    gateValue*: string

  RecipePackage* = object
    name*: string
    versions*: seq[string]
      ## The declared candidate universe. Empty means "ask the registry",
      ## which is the ordinary case for a dependency.
    pinnedLockFile*: string
      ## §4.6's PIN. Non-empty means "always built under this lock file,
      ## whoever pulls it in" — Bazel's `cfg = "exec"`.
    deps*: seq[RecipeDep]
    demands*: seq[tuple[variant, value: string]]
      ## Variant values this package DEMANDS of the graph it lands in. The
      ## model of a feature request: a package in a lock file's closure
      ## contributes its demand to that lock file's solve and to no other.
      ## §4.2 — "The lock file's constraint set is the union of the `uses:` of
      ## everything designated to it, transitively."

  RecipeArtifact* = object
    ## An `executable` / `library` and the lock file designated at it (§4.3).
    ## `lockFile` empty means the artifact designated nothing, which is the
    ## overwhelmingly common case and resolves to `default`.
    name*: string
    package*: string
    lockFile*: string

  Recipe* = object
    packages*: seq[RecipePackage]
    artifacts*: seq[RecipeArtifact]
    boolVariants*: seq[string]
      ## Bool variants declared by the workspace, with `false` as the
      ## `vpDefault` contribution. A package's `demands` add a `vpOverride`
      ## contribution in the lock files that package falls under.

const BoundaryRootPrefix* = "lockfile-root:"
  ## Prefix of the synthetic root a lock file's graph gets when a dependency
  ## CROSSES into it from a consumer in another lock file. See `declsFor`.

proc dep*(name, constraint: string; platform = dpTarget;
          gateVariant = ""; gateValue = ""): RecipeDep =
  RecipeDep(name: name, constraint: constraint, platform: platform,
    gateVariant: gateVariant, gateValue: gateValue)

proc propagationOf*(r: Recipe): PropagationResult =
  ## Run §4.1 propagation over the recipe.
  var packages: seq[PropPackage] = @[]
  for p in r.packages:
    var deps: seq[PropDep] = @[]
    for d in p.deps:
      deps.add(PropDep(name: d.name, platform: d.platform))
    packages.add(PropPackage(name: p.name,
      pinnedLockFile: p.pinnedLockFile, deps: deps))
  var roots: seq[PropRoot] = @[]
  for a in r.artifacts:
    roots.add(PropRoot(artifact: a.name, package: a.package,
      lockFile: a.lockFile))
  propagate(roots, packages)

proc packageByName(r: Recipe; name: string): Option[RecipePackage] =
  for p in r.packages:
    if p.name == name: return some(p)
  none(RecipePackage)

proc declsFor*(r: Recipe; prop: PropagationResult;
               lockFileName: string): seq[PackageDecl] =
  ## The solver input for ONE lock file: every package in its closure, with
  ## only the dependency edges that also resolve under it.
  result = @[]
  if not prop.packagesByLockFile.hasKey(lockFileName):
    return
  let members = prop.packagesByLockFile[lockFileName].toHashSet()
  for name in prop.packagesByLockFile[lockFileName]:
    let found = packageByName(r, name)
    if found.isNone:
      result.add(newPackage(name, @[]))
      continue
    let p = found.get()
    var depends: seq[DependencyDecl] = @[]
    for d in p.deps:
      let childPin =
        if packageByName(r, d.name).isSome:
          packageByName(r, d.name).get().pinnedLockFile
        else:
          ""
      let child = childLockFile(lockFileName,
        PropDep(name: d.name, platform: d.platform), childPin)
      if child != lockFileName: continue
      if d.name notin members: continue
      if d.gateVariant.len > 0:
        depends.add(newConditionalDependency(d.name, d.constraint,
          d.gateVariant, d.gateValue))
      else:
        depends.add(newDependency(d.name, d.constraint))
    result.add(newPackage(name, p.versions, depends))

  # The BOUNDARY constraints: edges whose consumer is in another lock file but
  # whose target is in this one. §4.2 is explicit that they belong here — "The
  # lock file's constraint set is the union of the `uses:` of everything
  # designated to it, transitively. Nothing is enumerated by hand; a
  # declaration names a scope and the graph populates it."
  #
  # Without this, a `nativeBuildDeps: "libz >=1.0 <2.0"` would designate `libz`
  # to `hostTools` and then leave the host graph with NO constraint on it,
  # because the consumer that carried the range stayed behind in the other
  # graph. The dependency would resolve freely, which is a silent wrong answer
  # rather than a loud one — found by NLF-PROP-4 asserting on the version
  # rather than on the instance count.
  #
  # They are attached to an explicit synthetic root rather than folded into
  # the depended-on package, because a constraint is a property of the EDGE
  # and folding it into the node would lose which lock file demanded it. The
  # root is emitted only when there is something to put on it, so a lock file
  # with no incoming boundary edge is byte-unchanged.
  var boundary: seq[DependencyDecl] = @[]
  for p in r.packages:
    if p.name in members: continue
    for lock in prop.lockFilesByPackage.getOrDefault(p.name, @[]):
      for d in p.deps:
        let childPin =
          if packageByName(r, d.name).isSome:
            packageByName(r, d.name).get().pinnedLockFile
          else:
            ""
        let child = childLockFile(lock,
          PropDep(name: d.name, platform: d.platform), childPin)
        if child != lockFileName: continue
        if d.name notin members: continue
        if d.gateVariant.len > 0:
          boundary.add(newConditionalDependency(d.name, d.constraint,
            d.gateVariant, d.gateValue))
        else:
          boundary.add(newDependency(d.name, d.constraint))
  if boundary.len > 0:
    # PINNED: the root is not a real package and has no published universe, so
    # a metadata-fetch edge for it would 404. `pinned` is the existing way a
    # generation says "this node's version is not the solve's to choose",
    # which is exactly true of a synthetic root.
    result.add(newPackage(BoundaryRootPrefix & lockFileName, @["1.0.0"],
      boundary, pinned = true))

proc variantsFor*(r: Recipe; prop: PropagationResult;
                  lockFileName: string): seq[VariantDecl] =
  ## The variant declarations for ONE lock file: the workspace's bool
  ## variants, each carrying a `vpOverride` contribution for every DEMAND
  ## made by a package in THIS lock file's closure.
  ##
  ## This is where NLF-PROP-5 lives. A demand made by a host tool reaches the
  ## host graph and stops there; under a single lock file it would reach the
  ## one graph everything shares, which is Cargo's resolver-v1 feature
  ## unification.
  result = @[]
  if r.boolVariants.len == 0: return
  let members =
    if prop.packagesByLockFile.hasKey(lockFileName):
      prop.packagesByLockFile[lockFileName].toHashSet()
    else:
      initHashSet[string]()
  for name in r.boolVariants:
    var contributions = @[contribution(vpDefault, "false")]
    for p in r.packages:
      if p.name notin members: continue
      for d in p.demands:
        if d.variant == name:
          contributions.add(contribution(vpOverride, d.value))
    result.add(newBoolVariant(name, contributions))

proc publishRecipe*(reg: Registry; r: Recipe) =
  ## Publish every package's declared universe to the loopback registry, so
  ## the generation's metadata-fetch edges reach a real server over real
  ## HTTP rather than being skipped. Folded into `solvePerLockFile` and
  ## `solveUnified` so no test can forget it and get a 404 that looks like a
  ## propagation failure.
  ##
  ## Idempotent: publishing the same package twice is what happens when a
  ## package appears in two lock files' closures, which is the case these
  ## tests exist to produce.
  for p in r.packages:
    if p.versions.len == 0: continue
    reg.server.publish(p.name, p.versions)

proc solvePerLockFile*(reg: Registry; r: Recipe;
                       strategy = lsDefault):
    Table[string, LockGenerationResult] =
  ## One real solve per lock file in use. The return is keyed by lock-file
  ## NAME purely so a test can address the results; nothing downstream of §6
  ## ever sees the name, and the identity each result carries is derived from
  ## its content alone.
  result = initTable[string, LockGenerationResult]()
  reg.publishRecipe(r)
  let prop = propagationOf(r)
  for name in prop.lockFilesInUse():
    result[name] = runLockSolve(
      reg.request(declsFor(r, prop, name), strategy,
        variants = variantsFor(r, prop, name),
        inputsText = "nlf-m7 " & name), "")

proc solveUnified*(reg: Registry; r: Recipe;
                   strategy = lsDefault): LockGenerationResult =
  ## The CONTROL: the same recipe with every designation ignored, so
  ## everything lands in one graph. Several tests below need it, because a
  ## property like "two instances" is only interesting against an
  ## implementation that cannot produce two.
  reg.publishRecipe(r)
  var flattened = r
  flattened.artifacts = @[]
  for a in r.artifacts:
    flattened.artifacts.add(RecipeArtifact(name: a.name, package: a.package,
      lockFile: ""))
  for i in 0 ..< flattened.packages.len:
    flattened.packages[i].pinnedLockFile = ""
  var deps: seq[PropDep] = @[]
  discard deps
  # Every dependency resolves under the consumer, whatever list it was written
  # in — the pre-NLF-M7 behaviour, in which the platform tag never reached the
  # solver at all.
  for i in 0 ..< flattened.packages.len:
    for j in 0 ..< flattened.packages[i].deps.len:
      flattened.packages[i].deps[j].platform = dpTarget
  let prop = propagationOf(flattened)
  runLockSolve(
    reg.request(declsFor(flattened, prop, DefaultLockFileName), strategy,
      variants = variantsFor(flattened, prop, DefaultLockFileName),
      inputsText = "nlf-m7 unified"), "")

proc solvedVersions*(r: LockGenerationResult): Table[string, string] =
  ## The solved version per package, read back OUT OF THE LOCK DOCUMENT.
  r.resolved()

proc solvedVariant*(r: LockGenerationResult; name: string): string =
  ## The value a solved graph assigned to a variant, read off the lock.
  let sol = lockToSolution(parseSolvedGraphLock(r.lockDocument))
  sol.variants.getOrDefault(name, "")

proc lockFileNames*(t: Table[string, LockGenerationResult]): seq[string] =
  result = @[]
  for k in t.keys: result.add(k)
  result.sort()
