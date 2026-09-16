# reverse_index.nim
#
# Milestone HAX-M0: Relocation Reverse Reference Index and Multi-Generation Reachability
#
# Specifications:
# - reprobuild-specs/HCR/Incremental-Linker-Algorithm.md §5.3, §6
# - reprobuild-specs/HCR-Advanced-Lifecycle-And-Tooling.milestones.org (HAX-M0)

import std/[tables, sets, strutils, sequtils, algorithm]
import repro_hcr_linkgraph

type
  RelocationSite* = object
    symbolName*: string     ## Target symbol referenced by this relocation
    siteAddress*: uint64    ## Virtual address where relocation is applied
    relocationType*: string ## Machine relocation type (e.g. "R_X86_64_PLT32", "ARM64_RELOC_BRANCH26")
    addend*: int64          ## Relocation addend
    regionId*: string       ## Memory region enclosing the relocation site
    generation*: uint64     ## Patch generation that installed this site

  PatchSymbolNode* = object
    name*: string           ## Symbol name
    address*: uint64        ## Allocated virtual address of the symbol
    size*: uint64           ## Size in bytes of the symbol body
    generation*: uint64     ## Patch generation introducing this symbol version
    regionId*: string       ## Memory region ID hosting this symbol
    callees*: seq[string]   ## Target symbol names called/referenced by this symbol
    callers*: seq[string]   ## Calling symbol names referencing this symbol

  RegionState* = enum
    rsActive
    rsRetired
    rsReclaimed

  PatchRegionRecord* = object
    id*: string
    generation*: uint64
    symbolNames*: seq[string]
    retirementEpoch*: uint64
    state*: RegionState

  MultiGenReachabilityGraph* = object
    symbols*: Table[string, PatchSymbolNode]
    referredBy*: Table[string, seq[RelocationSite]]
    activeRoots*: HashSet[string]
    currentGeneration*: uint64
    currentEpoch*: uint64
    quiescedEpoch*: uint64
    generationRegions*: Table[uint64, seq[string]]
    regions*: Table[string, PatchRegionRecord]
    allSites*: seq[RelocationSite]
    symbolHistory*: Table[string, seq[PatchSymbolNode]]

proc initMultiGenReachabilityGraph*(): MultiGenReachabilityGraph =
  result.symbols = initTable[string, PatchSymbolNode]()
  result.referredBy = initTable[string, seq[RelocationSite]]()
  result.activeRoots = initHashSet[string]()
  result.currentGeneration = 0'u64
  result.currentEpoch = 0'u64
  result.quiescedEpoch = 0'u64
  result.generationRegions = initTable[uint64, seq[string]]()
  result.regions = initTable[string, PatchRegionRecord]()
  result.allSites = @[]
  result.symbolHistory = initTable[string, seq[PatchSymbolNode]]()

proc registerRelocationSite*(graph: var MultiGenReachabilityGraph, site: RelocationSite) =
  graph.allSites.add(site)
  graph.referredBy.mgetOrPut(site.symbolName, @[]).add(site)

  # Cross-link caller and callee if siteAddress falls inside a known symbol node
  for name, sym in graph.symbols.mpairs:
    if sym.size > 0 and site.siteAddress >= sym.address and site.siteAddress < sym.address + sym.size:
      if site.symbolName notin sym.callees:
        sym.callees.add(site.symbolName)
      if site.symbolName in graph.symbols:
        if name notin graph.symbols[site.symbolName].callers:
          graph.symbols[site.symbolName].callers.add(name)

proc registerPatchGeneration*(graph: var MultiGenReachabilityGraph,
                              generation: uint64,
                              regionId: string,
                              symbols: openArray[PatchSymbolNode],
                              sites: openArray[RelocationSite]) =
  graph.currentGeneration = max(graph.currentGeneration, generation)
  if graph.currentEpoch < generation:
    graph.currentEpoch = generation

  if regionId.len > 0:
    var symNames: seq[string] = @[]
    for s in symbols:
      symNames.add(s.name)

    if regionId notin graph.regions:
      graph.regions[regionId] = PatchRegionRecord(
        id: regionId,
        generation: generation,
        symbolNames: symNames,
        retirementEpoch: 0'u64,
        state: rsActive
      )
      graph.generationRegions.mgetOrPut(generation, @[]).add(regionId)
    else:
      for name in symNames:
        if name notin graph.regions[regionId].symbolNames:
          graph.regions[regionId].symbolNames.add(name)

  # Register symbols
  for s in symbols:
    var sym = s
    if sym.generation == 0:
      sym.generation = generation
    if sym.regionId.len == 0:
      sym.regionId = regionId
    if sym.name in graph.symbols:
      graph.symbolHistory.mgetOrPut(sym.name, @[]).add(graph.symbols[sym.name])
    graph.symbols[sym.name] = sym

  # Register relocation sites
  for site in sites:
    var st = site
    if st.generation == 0:
      st.generation = generation
    if st.regionId.len == 0:
      st.regionId = regionId
    graph.registerRelocationSite(st)

  # Bidirectional linking of callees/callers for all registered symbols
  for sym in symbols:
    let symName = sym.name
    if symName in graph.symbols:
      for callee in graph.symbols[symName].callees:
        if callee in graph.symbols:
          if symName notin graph.symbols[callee].callers:
            graph.symbols[callee].callers.add(symName)
      # Check reverse references targeting symName
      if symName in graph.referredBy:
        for refSite in graph.referredBy[symName]:
          for callerName, callerSym in graph.symbols.mpairs:
            if callerSym.size > 0 and refSite.siteAddress >= callerSym.address and
               refSite.siteAddress < callerSym.address + callerSym.size:
              if symName notin callerSym.callees:
                callerSym.callees.add(symName)
              if callerName notin graph.symbols[symName].callers:
                graph.symbols[symName].callers.add(callerName)

proc computeReachability*(graph: MultiGenReachabilityGraph,
                          activeRoots: openArray[string]): HashSet[string] =
  result = initHashSet[string]()
  var queue: seq[string] = @[]

  for root in activeRoots:
    if root.len > 0 and root notin result:
      result.incl(root)
      queue.add(root)

  var head = 0
  while head < queue.len:
    let current = queue[head]
    inc head

    if current in graph.symbols:
      let node = graph.symbols[current]
      for callee in node.callees:
        if callee notin result:
          result.incl(callee)
          queue.add(callee)

      # Follow any relocation sites originating from this node's code span
      for site in graph.allSites:
        if node.size > 0 and site.siteAddress >= node.address and
           site.siteAddress < node.address + node.size:
          if site.symbolName.len > 0 and site.symbolName notin result:
            result.incl(site.symbolName)
            queue.add(site.symbolName)

proc supersedeGeneration*(graph: var MultiGenReachabilityGraph,
                          oldGeneration: uint64,
                          newGeneration: uint64,
                          newRoots: openArray[string]): tuple[reachable: HashSet[string], unreachable: HashSet[string]] =
  graph.activeRoots.clear()
  for root in newRoots:
    graph.activeRoots.incl(root)

  graph.currentGeneration = newGeneration
  graph.currentEpoch = max(graph.currentEpoch, newGeneration)

  let reachable = graph.computeReachability(newRoots)

  var unreachable = initHashSet[string]()
  for name in graph.symbols.keys:
    if name notin reachable:
      unreachable.incl(name)

  # Check all active regions for retirement
  for regId, reg in graph.regions.mpairs:
    if reg.state == rsActive:
      var hasReachableSymbol = false
      for symName in reg.symbolNames:
        if symName in reachable and symName in graph.symbols:
          let currentSym = graph.symbols[symName]
          # The active symbol instance must actually reside in this region
          if currentSym.regionId == reg.id:
            hasReachableSymbol = true
            break
      if not hasReachableSymbol:
        reg.state = rsRetired
        reg.retirementEpoch = graph.currentEpoch

  result = (reachable: reachable, unreachable: unreachable)

proc advanceQuiescedEpoch*(graph: var MultiGenReachabilityGraph, epoch: uint64) =
  graph.quiescedEpoch = max(graph.quiescedEpoch, epoch)

proc reclaimUnreachableRegions*(graph: var MultiGenReachabilityGraph,
                               minQuiescedEpoch: uint64): seq[string] =
  result = @[]
  let effectiveEpoch = min(graph.quiescedEpoch, minQuiescedEpoch)
  if effectiveEpoch == 0:
    return result

  for regId, reg in graph.regions.mpairs:
    if reg.state == rsRetired and reg.retirementEpoch <= effectiveEpoch:
      reg.state = rsReclaimed
      result.add(regId)

  result.sort()

proc isRegionReclaimed*(graph: MultiGenReachabilityGraph, regionId: string): bool =
  if regionId in graph.regions:
    graph.regions[regionId].state == rsReclaimed
  else:
    false

proc isRegionRetired*(graph: MultiGenReachabilityGraph, regionId: string): bool =
  if regionId in graph.regions:
    graph.regions[regionId].state == rsRetired
  else:
    false

proc isRegionActive*(graph: MultiGenReachabilityGraph, regionId: string): bool =
  if regionId in graph.regions:
    graph.regions[regionId].state == rsActive
  else:
    false

proc getRegionRecord*(graph: MultiGenReachabilityGraph, regionId: string): PatchRegionRecord =
  graph.regions[regionId]

proc getReferredBySites*(graph: MultiGenReachabilityGraph, symbolName: string): seq[RelocationSite] =
  graph.referredBy.getOrDefault(symbolName)

proc linkGraphToPatchGeneration*(linkGraph: LinkGraph,
                                 generation: uint64,
                                 regionId: string,
                                 regionBase: uint64 = 0): tuple[symbols: seq[PatchSymbolNode], sites: seq[RelocationSite]] =
  var syms: seq[PatchSymbolNode] = @[]
  var sites: seq[RelocationSite] = @[]

  for s in linkGraph.symbols:
    if s.isDefined and s.kind == sykFunction:
      syms.add(PatchSymbolNode(
        name: s.name,
        address: regionBase + s.address,
        size: s.size,
        generation: generation,
        regionId: regionId,
        callees: @[],
        callers: @[]
      ))

  for r in linkGraph.relocations:
    if r.targetName.len > 0:
      let siteAddr = regionBase + uint64(r.offset)
      sites.add(RelocationSite(
        symbolName: r.targetName,
        siteAddress: siteAddr,
        relocationType: r.kindName,
        addend: r.addend,
        regionId: regionId,
        generation: generation
      ))
      for sym in syms.mitems:
        if sym.size > 0 and siteAddr >= sym.address and siteAddr < sym.address + sym.size:
          if r.targetName notin sym.callees:
            sym.callees.add(r.targetName)

  result = (symbols: syms, sites: sites)

proc registerPatchGenerationFromLinkGraph*(reachGraph: var MultiGenReachabilityGraph,
                                          linkGraph: LinkGraph,
                                          generation: uint64,
                                          regionId: string,
                                          regionBase: uint64 = 0) =
  let (syms, sites) = linkGraphToPatchGeneration(linkGraph, generation, regionId, regionBase)
  reachGraph.registerPatchGeneration(generation, regionId, syms, sites)
