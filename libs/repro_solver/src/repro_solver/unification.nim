## ``repro_solver/unification`` — the diamond, as solver input.
##
## Named-Lock-Files NLF-M8, design §9.1.
##
## ## What this module turns into what
##
## In: the workspace's **demand edges** — who asked for which library, under
## which range, governed by which lock file. Out: a `seq[PackageDecl]` in which
## a library that several edges demand carries one INSTANCE per demanding edge,
## joined by `PackageDecl.instanceOf` so `encodeUnificationObjective` can write
## its `#minimize` over them.
##
## ## Why per demanding EDGE and not per lock file
##
## Per lock file is the obvious reading of "two lock files" and it is not
## enough. §9.4's own worked example puts both demanders inside ONE lock file:
##
## > `build/app` (lock file `targetRuntime`) requires both:
## >   libfoo 2.0.0 — app -> libimaging 3.1.0 -> libfoo >=2.0 <3.0
## >   libfoo 1.4.2 — app -> libreport 0.9.4 -> libfoo >=1.4 <2.0
##
## An instancing rule keyed on the lock file alone would give that workspace
## one `libfoo`, the solve would be UNSAT, and the diagnostic §9.4 requires
## would have nothing to describe — "It MUST NOT report a bare unsat" is
## exactly what such an implementation would do. Keying on the demanding edge
## covers both shapes with one rule, because two edges under two lock files are
## still two edges.
##
## ## Why the instance count is not an explosion
##
## An instance is created per edge, and then the OBJECTIVE collapses them:
## instances that can agree land on the same version and `coalesceInstances`
## folds them back into one. So the encoder's instance count is an upper bound
## on the search, and the ANSWER's instance count is §9.1's "divergence is
## confined to the packages that genuinely could not agree". A library with one
## demander is never instanced at all and its program text does not move —
## which is what keeps NLF-STAT-4's fixture byte-identical.
##
## ## Test-double policy
##
## No doubles. This module is pure data transformation over the real
## `PackageDecl` the real encoder consumes.

import std/[algorithm, sets, tables]

import version_encoder

type
  DemandEdge* = object
    ## One declared demand for a library: who asked, for what range, under
    ## which lock file.
    demander*: string
      ## The package that wrote the dependency. `""` means the request
      ## itself — a root artifact naming the library directly.
    library*: string
    constraint*: string
    lockFile*: string
      ## The GOVERNING lock file of the edge, already resolved by §4.6's
      ## precedence (`repro_lock_files/propagation.childLockFile`). Resolving
      ## it again here would be a second implementation of that precedence.

  UnificationInput* = object
    ## Everything the joint solve needs, with no reference to how the
    ## workspace was written.
    edges*: seq[DemandEdge]
    candidates*: Table[string, seq[string]]
      ## Library → its published candidate universe.
    roots*: seq[tuple[package, lockFile: string]]
      ## The packages the request itself names. They are declared as ordinary
      ## packages so `encodeSelectionRoots` seeds selection from them.

  InstanceBinding* = object
    ## Which solver package one demand edge binds to.
    demander*: string
    library*: string
    lockFile*: string
    instanceName*: string

  InstancedProgram* = object
    packages*: seq[PackageDecl]
    bindings*: seq[InstanceBinding]

  CoalescedInstance* = object
    ## One surviving instance after the objective has done its work.
    library*: string
    version*: string
    lockFiles*: seq[string]
    demanders*: seq[string]
    constraints*: seq[string]

proc initUnificationInput*(): UnificationInput =
  UnificationInput(edges: @[], candidates: initTable[string, seq[string]](),
    roots: @[])

proc instanceNameFor*(library, lockFile, demander: string): string =
  ## The `package_chosen/2` key for one instance.
  ##
  ## The separators are `@` and `#`, neither of which can appear in a package
  ## name, so the encoding is unambiguous and a reader of a dumped ASP program
  ## can see at a glance which edge an atom belongs to. The name never leaves
  ## the solve: `coalesceInstances` reports libraries, not instance keys.
  library & "@" & lockFile & "#" &
    (if demander.len > 0: demander else: "(request)")

proc demandersOf(input: UnificationInput):
    OrderedTable[string, seq[DemandEdge]] =
  result = initOrderedTable[string, seq[DemandEdge]]()
  for e in input.edges:
    if not result.hasKey(e.library):
      result[e.library] = @[]
    result[e.library].add(e)

proc buildInstancedProgram*(input: UnificationInput): InstancedProgram =
  ## Lower the demand set onto solver packages.
  ##
  ## A library with ONE demanding edge keeps its plain name and carries no
  ## `instanceOf`, so nothing about its encoding changes. A library with two
  ## or more gets one instance per edge, each with the full candidate
  ## universe and the demanding edge's own range constraint.
  result = InstancedProgram(packages: @[], bindings: @[])
  let byLibrary = demandersOf(input)

  # Which solver package does an edge (demander -> library @ lock) bind to?
  var bindingOf = initTable[string, string]()
  for library, edges in byLibrary.pairs:
    let split = edges.len >= 2
    for e in edges:
      let name =
        if split: instanceNameFor(library, e.lockFile, e.demander)
        else: library
      let key = e.demander & "\x1f" & library & "\x1f" & e.lockFile
      bindingOf[key] = name
      result.bindings.add(InstanceBinding(demander: e.demander,
        library: library, lockFile: e.lockFile, instanceName: name))

  # Emit one PackageDecl per solver package. A package that is BOTH a root
  # and a demanded library (the ordinary case for an intermediate library)
  # is emitted once per instance, and its own outgoing edges are rewritten
  # to the instances they bind to under the SAME lock file.
  var emitted = initHashSet[string]()

  proc outgoing(pkg: string): seq[DependencyDecl] =
    ## Every edge `pkg` declared, pointed at the instance it binds to.
    ##
    ## **Stated bound.** When `pkg` is itself split, both of its instances get
    ## the same children. Splitting a library's own closure alongside it is a
    ## recursion this milestone does not implement, and the corpus cases it
    ## would matter for do not exist yet: in every NLF-DIA case the split
    ## library is a leaf. Recorded here rather than left to be discovered,
    ## because an implementation that silently shared a child between two
    ## instances of a split parent would be wrong in the permissive direction.
    result = @[]
    for e in input.edges:
      if e.demander != pkg: continue
      if e.lockFile.len == 0: continue
      let key = e.demander & "\x1f" & e.library & "\x1f" & e.lockFile
      if not bindingOf.hasKey(key): continue
      result.add(newDependency(bindingOf[key], e.constraint))

  for r in input.roots:
    if r.package in emitted: continue
    emitted.incl(r.package)
    result.packages.add(newPackage(r.package,
      input.candidates.getOrDefault(r.package, @[]),
      outgoing(r.package)))

  for library, edges in byLibrary.pairs:
    let split = edges.len >= 2
    for e in edges:
      let name =
        if split: instanceNameFor(library, e.lockFile, e.demander)
        else: library
      if name in emitted: continue
      emitted.incl(name)
      let deps = outgoing(library)
      let universe = input.candidates.getOrDefault(library, @[])
      if split:
        result.packages.add(newInstance(name, library, universe, deps))
      else:
        result.packages.add(newPackage(library, universe, deps))

proc coalesceInstances*(program: InstancedProgram;
                        chosen: Table[string, string]):
    seq[CoalescedInstance] =
  ## Fold the solved instances back into the instances that SURVIVED.
  ##
  ## Two instances that landed on the same version are one instance — that is
  ## what the unification objective achieved, and reporting them as two would
  ## make a successful unification look like a split. Grouping is by
  ## (library, version), which is also the identity a store artifact is keyed
  ## on, so the count reported here is the count of things actually built.
  var groups = initOrderedTable[string, CoalescedInstance]()
  for b in program.bindings:
    if not chosen.hasKey(b.instanceName): continue
    let version = chosen[b.instanceName]
    let key = b.library & "\x1f" & version
    if not groups.hasKey(key):
      groups[key] = CoalescedInstance(library: b.library, version: version,
        lockFiles: @[], demanders: @[], constraints: @[])
    var g = groups[key]
    if b.lockFile notin g.lockFiles: g.lockFiles.add(b.lockFile)
    if b.demander.len > 0 and b.demander notin g.demanders:
      g.demanders.add(b.demander)
    groups[key] = g
  result = @[]
  for _, g in groups.pairs:
    var entry = g
    entry.lockFiles.sort()
    entry.demanders.sort()
    result.add(entry)
  result.sort(proc(a, b: CoalescedInstance): int =
    if a.library != b.library: cmp(a.library, b.library)
    else: cmp(a.version, b.version))

proc instanceCountOf*(coalesced: openArray[CoalescedInstance];
                      library: string): int =
  ## How many instances of `library` the solve actually produced. `1` is
  ## unification having succeeded; `>1` is a split, and NLF-DIA-7 requires
  ## that to be reported rather than left to be noticed.
  for c in coalesced:
    if c.library == library: inc result

proc versionForEdge*(program: InstancedProgram;
                     chosen: Table[string, string];
                     demander, library, lockFile: string): string =
  ## The version the edge `demander -> library`, governed by `lockFile`,
  ## resolved to. This is the `versionOf` callback
  ## `repro_lock_files/diamond.linkClosures` takes.
  for b in program.bindings:
    if b.demander == demander and b.library == library and
       b.lockFile == lockFile:
      return chosen.getOrDefault(b.instanceName, "")
  ""

proc splitConstraints*(program: InstancedProgram;
                       input: UnificationInput;
                       library: string): seq[string] =
  ## The distinct range strings that were demanded of `library`, for the
  ## split report. Sorted so the report is order-independent — §1.3's rule
  ## applied to a diagnostic.
  var seen = initHashSet[string]()
  result = @[]
  for e in input.edges:
    if e.library != library: continue
    if e.constraint.len == 0: continue
    if e.constraint in seen: continue
    seen.incl(e.constraint)
    result.add(e.constraint)
  result.sort()
