## Resolving Nimble packages with the solver (NPC-AREQ17, NPC-AREQ18): the
## solver input of ``solver_input`` lowered to the solver's declarations,
## the answer read back as the chosen records, and the diagnostics a failed
## or unsafe resolution must print.
##
## * ``lowerToSolver`` -- one ``PackageDecl`` per package the closure
##   reached, named by its `nimble:` identity, offering its offered
##   candidates, each with its OWN dependency list
##   (``PackageDecl.versionDepends``), active only when something chosen
##   requires it (``onDemand``) and newest-first when no strategy is given
##   (``preferNewest``). A record's `nim` range becomes a per-version
##   dependency on the project's `nim` TOOLCHAIN package -- never a
##   `nimble:nim` package. A name the index does not hold is declared with no
##   candidate, so a version requiring it cannot be chosen and nothing else
##   is affected. A candidate with a requirement under a Nim-version
##   condition (NPC-AREQ7) depends on its Nim gate (``nimGateIdentity``), an
##   on-demand package whose versions mirror the `nim` toolchain's, so the
##   requirement binds exactly when the chosen Nim makes the condition true.
## * ``chosenNimblePackages`` -- the records the solution chose.
## * ``moduleCollisions`` -- two chosen packages exporting one top-level
##   module (threat model G16): Nim would take whichever `--path` comes
##   first and say nothing.
## * ``explainNimbleFailure`` -- the index revision used, every name the
##   index does not hold and every pseudo-version requirement it cannot
##   satisfy, with the requirement chain that reached it, and every excluded
##   candidate with the reason (`unreadable`, `platform-limited`, `newer`,
##   `equal-version`, ...).

import std/[algorithm, options, sequtils, sets, strutils, tables]

import repro_domain_types/nimble_index
import repro_solver/version_encoder

import ./solver_input

const NimbleIdentityPrefix* = "nimble:"

proc isNimbleIdentity*(name: string): bool =
  name.startsWith(NimbleIdentityPrefix) and
    name.len > NimbleIdentityPrefix.len

proc nimbleNameOf*(identity: string): string =
  ## `nimble:chronicles` -> `chronicles`.
  if identity.isNimbleIdentity: identity[NimbleIdentityPrefix.len .. ^1]
  else: identity

proc nimblePlatformOf*(platformId: string): NimblePlatform =
  ## A lock's platform (`<cpu>-<os>` in Nim's names, `amd64-linux`) as the
  ## platform pair a Nimble solve evaluates conditions for. Host and target
  ## are the same: the lock is solved for the platform it records.
  let dash = platformId.find('-')
  let cpu = if dash > 0: platformId[0 ..< dash] else: platformId
  let os = if dash > 0: platformId[dash + 1 .. ^1] else: ""
  NimblePlatform(id: os & "-" & cpu, targetOs: os, targetCpu: cpu,
    hostOs: os, hostCpu: cpu)

proc gateDecl(name: string; versions: seq[(string, seq[DependencyDecl])]):
    PackageDecl =
  result = PackageDecl(name: name, onDemand: true)
  for (version, ds) in versions:
    if version in result.versions:
      continue
    result.versions.add version
    var all: seq[DependencyDecl]
    for d in ds:
      all.add newDependency(d.name,
        if d.range.len > 0: d.range else: AnyVersionRange)
    result.versionDepends.add newVersionDependencies(version, all)

proc lowerToSolver*(input: NimbleSolverInput; toolchainNim = "";
                    nimVersions: seq[string] = @[]): seq[PackageDecl] =
  ## The solver declarations of a Nimble closure (see the module header).
  ## ``toolchainNim`` names the project's `nim` toolchain package when the
  ## solve declares one, and ``nimVersions`` are its candidate versions:
  ## each candidate's `nim` ranges become per-version dependencies on it,
  ## so the chosen Nim satisfies every chosen record, and a candidate whose
  ## requirements or `nim` ranges depend on the Nim version also depends on
  ## its Nim gate, which mirrors ``nimVersions``. Without one the ranges
  ## constrain nothing here (the toolchain is not solved in this lock), and
  ## ``solverInput`` has already excluded every candidate with a Nim-version
  ## condition (`nim-version-unknown`; ``NimbleSolveOptions.nimDeclared``).
  var gates: seq[PackageDecl]
  for pkg in input.packages:
    var decl = PackageDecl(name: pkg.identity, onDemand: true,
      preferNewest: true)
    let deps = perVersionDependencies(input, pkg)
    var nimOf = initTable[string, seq[string]]()
    for c in pkg.candidates:
      if c.offered: nimOf[c.version] = c.nim
    for (version, ds) in deps:
      if version in decl.versions:
        continue
      decl.versions.add version
      var all: seq[DependencyDecl]
      for d in ds:
        # The solver's empty range admits nothing; "any version" is every
        # tag version, and never a pseudo-version.
        all.add newDependency(d.name,
          if d.range.len > 0: d.range else: AnyVersionRange)
      if toolchainNim.len > 0:
        for r in nimOf.getOrDefault(version):
          if r.len > 0:
            all.add newDependency(toolchainNim, r)
        for c in pkg.candidates:
          if c.offered and c.version == version and c.candidateNimGated:
            let gate = nimGateIdentity(pkg.identity, version)
            all.add newDependency(gate, AnyVersionRange)
            var reqs: seq[SolverRequirement]
            for r in c.requires:
              if r.nimGated: reqs.add r
            gates.add gateDecl(gate, nimGateVersionDependencies(input, reqs,
              c.nimGatedNim, toolchainNim, nimVersions))
            break
      if all.len > 0:
        decl.versionDepends.add newVersionDependencies(version, all)
    result.add decl
  # A feature some requirer names: its own on-demand package, active only
  # when a chosen version names it (NPC-AREQ7).
  for pkg in input.packages:
    for f in pkg.features:
      var decl = PackageDecl(name: featureIdentity(pkg.identity, f),
        onDemand: true)
      for (version, ds) in featureVersionDependencies(input, pkg, f):
        if version in decl.versions:
          continue
        decl.versions.add version
        var all: seq[DependencyDecl]
        for d in ds:
          all.add newDependency(d.name,
            if d.range.len > 0: d.range else: AnyVersionRange)
        if toolchainNim.len > 0:
          for c in pkg.candidates:
            if c.offered and c.version == version:
              let g = featureNimGated(c, f)
              if g.len > 0:
                let gate = nimGateIdentity(decl.name, version)
                all.add newDependency(gate, AnyVersionRange)
                gates.add gateDecl(gate, nimGateVersionDependencies(input, g,
                  @[], toolchainNim, nimVersions))
              break
        decl.versionDepends.add newVersionDependencies(version, all)
      result.add decl
  result.add gates
  # Names reached that the index does not hold: declared without a
  # candidate, under the spelling the requirement used (NPC-M6 item e).
  # Every declaration's edges are scanned, a feature package's included: an
  # edge to an undeclared package constrains nothing, so a missing name
  # left undeclared would be silently satisfied.
  var declared = initHashSet[string]()
  for d in result: declared.incl d.name
  var missing: seq[string]
  for decl in result:
    for vd in decl.versionDepends:
      for d in vd.depends:
        if d.name.isNimbleIdentity and d.name notin declared:
          declared.incl d.name
          missing.add d.name
  for name in missing:
    result.add PackageDecl(name: name, onDemand: true)

proc canonicalRequirement*(input: NimbleSolverInput;
                           dep: DependencyDecl): DependencyDecl =
  ## A project's `uses:` dependency on `nimble:<name as written>` renamed to
  ## the canonical identity the closure resolved (NPC-AREQ3: the lock records
  ## the canonical name; `nimble:Chronicles` and an alias both resolve to
  ## `nimble:chronicles`). A name the index does not hold keeps its spelling.
  result = dep
  if dep.name.isNimbleIdentity:
    let k = nameKey(nimbleNameOf(dep.name))
    if k in input.canonical:
      result.name = identityOf(input.canonical[k])
    if dep.range.strip().len == 0:
      # `uses: "nimble:x"` with no range: any version (the solver's empty
      # range admits none).
      result.range = AnyVersionRange

type
  ChosenNimble* = object
    name*: string      ## canonical
    identity*: string  ## `nimble:<canonical>`
    version*: string   ## the solver version chosen
    record*: VersionRecord
    origin*: PackageOrigin
    depends*: seq[string]
      ## the identities of the chosen Nimble packages this version requires

proc chosenNimblePackages*(input: NimbleSolverInput;
                           chosen: Table[string, string]): seq[ChosenNimble] =
  ## The record of every Nimble package ``chosen`` (a solution's
  ## identity -> version table) assigns, sorted by name.
  for pkg in input.packages:
    if pkg.identity notin chosen: continue
    let v = chosen[pkg.identity]
    for c in pkg.candidates:
      if c.offered and c.version == v:
        var origin = PackageOrigin()
        if int(c.record.origin) < pkg.origins.len:
          origin = pkg.origins[int(c.record.origin)]
        var deps: seq[string]
        var edges: seq[(string, seq[DependencyDecl])] =
          perVersionDependencies(input, pkg)
        for f in pkg.features:
          # An active feature's requirements are this version's too.
          if featureIdentity(pkg.identity, f) in chosen:
            edges.add featureVersionDependencies(input, pkg, f)
        # So are the requirements the chosen Nim made true: the Nim gates'
        # chosen versions (the gate's version is the chosen Nim).
        for owner in @[pkg.identity] & pkg.features.mapIt(
            featureIdentity(pkg.identity, it)):
          let gate = nimGateIdentity(owner, v)
          if gate notin chosen: continue
          var reqs: seq[SolverRequirement]
          if owner == pkg.identity:
            for r in c.requires:
              if r.nimGated: reqs.add r
          else:
            reqs = featureNimGated(c, owner[pkg.identity.len + 1 .. ^2])
          let n = chosen[gate]
          let nv = nimVersionValueOf(n)
          if nv.isNone: continue
          var active: seq[SolverRequirement]
          for r in reqs:
            if activeOn(r.entry.condition, input.platform, nv):
              active.add r
          edges.add (v, lowered(input, active))
        for (version, ds) in edges:
          if version != v: continue
          for d in ds:
            if d.name.isNimbleIdentity and not d.name.isFeatureIdentity and
                d.name != pkg.identity and d.name in chosen and
                d.name notin deps:
              deps.add d.name
        deps.sort()
        result.add ChosenNimble(name: pkg.name, identity: pkg.identity,
          version: v, record: c.record, origin: origin, depends: deps)
        break
  result.sort(proc (a, b: ChosenNimble): int = cmp(a.name, b.name))

proc moduleCollisions*(chosen: seq[ChosenNimble]): seq[string] =
  ## One message per top-level module name that two or more chosen packages
  ## export (their records' `layout.modules`), naming every package. Nim
  ## resolves `import <module>` by `--path` order, so without this report
  ## the order would pick one silently (NPC-AREQ18, threat model G16).
  var owners = initOrderedTable[string, seq[string]]()
  var modules: seq[string]
  for c in chosen:
    for m in c.record.layout.modules:
      if m notin owners:
        owners[m] = @[]
        modules.add m
      let who = c.identity & " " & versionText(c.record.version)
      if who notin owners[m]: owners[m].add who
  modules.sort()
  for m in modules:
    if owners[m].len > 1:
      result.add "module `" & m & "` is exported at the top level by " &
        owners[m].join(" and ") & "; a Nim compile would take whichever " &
        "`--path` comes first and say nothing. Remove one of them from the " &
        "closure, or pin versions whose layouts do not collide"

proc requirementChain*(input: NimbleSolverInput; name: string): seq[string] =
  ## How ``name`` (an index name, canonical or as written) was reached, from
  ## the project down: each step `<requirer> requires <requirement>`. Uses
  ## the first way each name was reached; stops at a cycle.
  var steps: seq[string]
  var key = nameKey(name)
  var seen = initHashSet[string]()
  while key notin seen and key in input.reachedBy:
    seen.incl key
    let by = input.reachedBy[key][0]
    steps.add by.requirer & " requires " & by.requirement
    if not by.requirer.isNimbleIdentity:
      break
    let parent = by.requirer[NimbleIdentityPrefix.len .. ^1].split(' ')[0]
    key = nameKey(parent)
  steps.reverse()
  steps

proc renderChain(input: NimbleSolverInput; name: string): string =
  let chain = requirementChain(input, name)
  if chain.len == 0: "" else: "\n      via: " & chain.join("\n           ")

proc explainNimbleFailure*(input: NimbleSolverInput;
                           indexLabel: string): string =
  ## What a Nimble resolution that found no answer must say (NPC-AREQ18):
  ## the index revision used, then every name the index does not hold and
  ## every pseudo-version requirement it cannot satisfy, each with its
  ## requirement chain, then every package of the closure that has excluded
  ## candidates, with each candidate's reason, and the packages no candidate
  ## of which is offered at all.
  var lines = @["Nimble resolution used " & indexLabel & " (platform " &
    input.platform.id & ")"]
  for m in input.missing:
    lines.add "  nimble:" & m & " is not in the index" & renderChain(input, m)
  for pkg in input.packages:
    for c in pkg.candidates:
      if not c.offered: continue
      for r in c.requires:
        if isPseudoRequirement(r.entry):
          let d = dependencyOf(input, r)
          if d.isSome and d.get.range.startsWith(UnresolvedRangePrefix):
            let pi = input.packageOf(requirementTargetName(r.entry))
            let why =
              if pi >= 0: matchPseudo(input.packages[pi], r.entry).why
              else: "the index does not hold " & requirementTargetName(r.entry)
            lines.add "  " & c.identity & " " & versionText(c.record.version) &
              " requires " & r.entry.source & ": " & why
  for pkg in input.packages:
    var excluded: seq[string]
    var offered = 0
    for c in pkg.candidates:
      if c.offered:
        inc offered
        continue
      let real = c.exclusions.filterIt(it.kind != exPseudoVersion)
      if real.len == 0: continue
      var reasons: seq[string]
      for e in real: reasons.add $e.kind & ": " & e.detail
      excluded.add "      " & versionText(c.record.version) & " -- " &
        reasons.join("; ") &
        (if flUnlisted in c.record.flags: " (unlisted source)" else: "")
    if excluded.len == 0 and offered > 0:
      continue
    lines.add "  " & pkg.identity & ": " & $offered & " candidate(s) " &
      "offered" & (if excluded.len > 0: ", excluded:" else: "") &
      renderChain(input, pkg.name)
    lines.add excluded
  lines.join("\n")

proc nimbleRootsOf*(packages: openArray[PackageDecl]):
    seq[RootRequirement] =
  ## The `nimble:` requirements the project's own declarations state (the
  ## roots of the Nimble closure), with the declaring package.
  for p in packages:
    if p.name.isNimbleIdentity: continue
    for d in allDependencies(p):
      if d.name.isNimbleIdentity:
        result.add RootRequirement(requirer: p.name,
          name: nimbleNameOf(d.name), range: d.range)
