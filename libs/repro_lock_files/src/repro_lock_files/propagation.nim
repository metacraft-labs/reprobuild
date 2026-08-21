## Designation propagates down the closure — §4.1 — and the dependency-list
## split decides where it stops — §4.6.
##
## Named-Lock-Files NLF-M7.
##
## §4.1 states the property this module computes: "**Designation propagates
## down the dependency closure.** An edge is built under the lock file of the
## consumer that pulled it in, unless it pins one of its own (§4.6)." And it
## says why it is not optional: "If `codegen` is built under `hostTools` and
## `uses: libfoo`, then a target-architecture `libfoo` cannot be linked into a
## host-architecture tool. The link either fails or, worse, succeeds and
## produces something that cannot run."
##
## ## The canonical case needs no new syntax, and that is what `DepPlatform` is
##
## §4.6's finding is that the approved DSL **already** declares the host/target
## split at dependency-list granularity, quoting
## `From-Source-Build-Recipes.md`: `nativeBuildDeps:` are BUILD-platform tools,
## `buildDeps:` are HOST-platform link libraries, and "a dependency that
## appears in more than one list must be written in each (reprobuild does not
## collapse them — explicit is better)". The rule this module implements is
## §4.6's one-line version:
##
## > **`nativeBuildDeps:` resolves under the `hostTools` lock file;
## > `buildDeps:` and `runtimeDeps:` resolve under the consuming artifact's
## > lock file.**
##
## So for the motivating case the authoring cost is zero, which §4.6 calls "the
## single biggest ergonomic result available here".
##
## ## What this is NOT
##
## It is not `propagates:`. §4.1: that directive "runs the **opposite
## direction** … carries a dependency's feature *up* to its consumers;
## lock-file designation flows *down* from a consumer to its dependencies."
## Nothing here walks upward.

import std/[algorithm, sets, tables]

import ./declarations

type
  DepPlatform* = enum
    ## Which of the three approved dependency lists an edge came from. The
    ## tag exists because the lists were **merged before the solver saw
    ## them** — §4.6: "So the platform distinction the recipe expressed is
    ## **erased before the solver ever sees it**."
    dpTarget    ## `uses:` / `buildDeps:` — HOST-platform, linked into output
    dpNative    ## `nativeBuildDeps:` — BUILD-platform tools and generators
    dpRuntime   ## `runtimeDeps:` — HOST-platform, needed at run time

  PropDep* = object
    name*: string
    platform*: DepPlatform

  PropPackage* = object
    ## One package as the propagation sees it: its dependency edges, tagged,
    ## and whether it PINS a lock file of its own.
    name*: string
    pinnedLockFile*: string
      ## §4.6's table. A build tool that must run on the build machine writes
      ## `lockFile hostTools` and is "**Pinned.** Always built under
      ## `hostTools`, whoever pulls it in." An ordinary library writes nothing
      ## and "**Inherits.**" `""` is inherit.
    deps*: seq[PropDep]

  PropRoot* = object
    ## An artifact and the lock file designated at it (§4.3). `lockFile` may
    ## be `""`, which is the overwhelmingly common case and resolves to
    ## `default`.
    artifact*: string
    package*: string
    lockFile*: string

  PropagationResult* = object
    packagesByLockFile*: OrderedTable[string, seq[string]]
      ## Lock-file name → the packages in its closure, sorted. This is §4.2's
      ## "the lock file's constraint set is the union of the `uses:` of
      ## everything designated to it, transitively. Nothing is enumerated by
      ## hand; a declaration names a scope and the graph populates it."
    lockFilesByPackage*: OrderedTable[string, seq[string]]
      ## Package → the lock files it is instantiated under, sorted. A package
      ## with two entries is built twice, which is §4.3's `libfoo`: "It is
      ## built **twice** … and its recipe never mentions lock files."

proc addTo(t: var OrderedTable[string, seq[string]]; key, value: string) =
  if not t.hasKey(key):
    t[key] = @[]
  if value notin t[key]:
    t[key].add(value)

proc sortValues(t: var OrderedTable[string, seq[string]]) =
  for k in t.keys:
    var v = t[k]
    v.sort()
    t[k] = v

proc childLockFile*(consumerLock: string; dep: PropDep;
                    depPin: string): string =
  ## Which lock file one dependency edge resolves under. The whole rule, in
  ## §4.6's precedence: a pin at the dependency's own declaration wins, then
  ## the dependency-list split, then inheritance from the consumer.
  ##
  ## Exposed rather than kept private because it is the sentence the corpus
  ## cases NLF-PROP-1, -3 and -4 each isolate one clause of, and a test that
  ## could only reach it through a full closure walk would be asserting on
  ## three things at once.
  if depPin.len > 0:
    return depPin
  if dep.platform == dpNative:
    return HostToolsLockFileName
  consumerLock

proc propagate*(roots: openArray[PropRoot];
                packages: openArray[PropPackage]): PropagationResult =
  ## Walk each root's closure under the root's lock file.
  ##
  ## The walk is per (package, lock file) rather than per package: a package
  ## reached under two lock files is visited twice, which is the whole point.
  ## `Configurable-System.md` §"Solver-Phase Resolution" is what makes that
  ## representable rather than a contradiction — the solver picks "a single
  ## value per variant **per resolved package instance**", and one package may
  ## have several instances (§4.1).
  result.packagesByLockFile = initOrderedTable[string, seq[string]]()
  result.lockFilesByPackage = initOrderedTable[string, seq[string]]()

  var byName = initTable[string, PropPackage]()
  for p in packages:
    byName[p.name] = p

  var seen = initHashSet[string]()
  var queue: seq[tuple[pkg, lock: string]] = @[]

  proc enqueue(pkg, lock: string) =
    let key = pkg & "\x1f" & lock
    if key in seen: return
    seen.incl(key)
    queue.add((pkg: pkg, lock: lock))

  for r in roots:
    let rootPin =
      if byName.hasKey(r.package): byName[r.package].pinnedLockFile else: ""
    let rootLock =
      if rootPin.len > 0: rootPin
      elif r.lockFile.len > 0: r.lockFile
      else: DefaultLockFileName
    enqueue(r.package, rootLock)

  var head = 0
  while head < queue.len:
    let (pkg, lock) = queue[head]
    inc head
    result.packagesByLockFile.addTo(lock, pkg)
    result.lockFilesByPackage.addTo(pkg, lock)
    if not byName.hasKey(pkg): continue
    for dep in byName[pkg].deps:
      let depPin =
        if byName.hasKey(dep.name): byName[dep.name].pinnedLockFile else: ""
      enqueue(dep.name, childLockFile(lock, dep, depPin))

  result.packagesByLockFile.sortValues()
  result.lockFilesByPackage.sortValues()

proc instanceCount*(r: PropagationResult; packageName: string): int =
  ## How many coexisting instances of `packageName` the propagation asks for.
  ## One per distinct governing lock file.
  if r.lockFilesByPackage.hasKey(packageName):
    r.lockFilesByPackage[packageName].len
  else:
    0

proc lockFilesInUse*(r: PropagationResult): seq[string] =
  result = @[]
  for k in r.packagesByLockFile.keys:
    result.add(k)
  result.sort()
