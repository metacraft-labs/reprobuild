## Context management for the Configurable system.
##
## Every Configurable operation targets a `ConfigContext`. Contexts are
## pushed onto a thread-local stack by the `evalConfig:` block; nested
## contexts are supported within the same thread. When the block exits,
## `finalize` is invoked on the top context, which resolves every node
## by walking its dependencies and computing a value.

import std/[tables, options, hashes, sets]

import ./types

var contextStack {.threadvar.}: seq[ConfigContext]

proc newConfigContext*(): ConfigContext =
  ConfigContext(
    nodes: @[],
    byScope: initTable[string, ConstructionId](),
    byExplicitId: initTable[string, ConstructionId](),
    state: ccsOpen,
    parent: nil,
    finalizers: @[],
    persistedEntries: initTable[string, ConfigurableNode](),
    persistedByScope: initTable[string, string]())

proc pushContext*(ctx: ConfigContext) =
  contextStack.add(ctx)

proc popContext*(): ConfigContext {.discardable.} =
  if contextStack.len == 0:
    raise newException(ENoContext, "no Configurable context active")
  result = contextStack[^1]
  contextStack.setLen(contextStack.len - 1)

proc currentContext*(): ConfigContext =
  if contextStack.len == 0:
    raise newException(ENoContext,
      "no `evalConfig` block is currently active; " &
      "Configurable operations require a context")
  contextStack[^1]

proc tryCurrentContext*(): ConfigContext =
  if contextStack.len == 0: nil
  else: contextStack[^1]

proc isStaged*(ctx: ConfigContext): bool =
  ctx != nil and ctx.state == ccsOpen

proc requireOpen*(ctx: ConfigContext) =
  if ctx == nil:
    raise newException(ENoContext, "no Configurable context")
  if ctx.state != ccsOpen:
    raise newException(EAlreadyFinalized,
      "context is already finalized; use `withOverrides` to extend it")

proc requireFinalized*(ctx: ConfigContext) =
  if ctx == nil:
    raise newException(ENoContext, "no Configurable context")
  if ctx.state != ccsFinalized:
    raise newException(ENotFinalized,
      "context is not yet finalized; finalize the `evalConfig` block first")

# ---------------------------------------------------------------------------
# Node allocation
# ---------------------------------------------------------------------------

proc allocNode*(ctx: ConfigContext;
                scopeName: string;
                kind: ConfigurableValueKind;
                merge: CollectionMergeRule = cmrScalarLastWins):
                ConfigurableNode =
  ctx.requireOpen()
  let id = ConstructionId(ctx.nodes.len)
  result = ConfigurableNode(
    id: id,
    scopeDerivedName: scopeName,
    valueKind: kind,
    mergeRule: merge,
    contributions: @[],
    deps: @[],
    resolved: false)
  ctx.nodes.add(result)
  if scopeName.len > 0:
    if ctx.byScope.hasKey(scopeName):
      # Duplicate scope-derived names are not fatal — the spec calls
      # out duplicate `@id` but scope-derived names can collide if
      # the same variable name appears in two structurally-different
      # places that the macro could not disambiguate. We keep the
      # first; subsequent ones get a numeric suffix so the persistent
      # lookup still has a unique key.
      var suffix = 1
      var attempt = scopeName & "#" & $suffix
      while ctx.byScope.hasKey(attempt):
        inc suffix
        attempt = scopeName & "#" & $suffix
      result.scopeDerivedName = attempt
      ctx.byScope[attempt] = id
    else:
      ctx.byScope[scopeName] = id

proc registerExplicitId*(ctx: ConfigContext;
                        node: ConfigurableNode;
                        explicitId: string;
                        site: SourceSite) =
  if explicitId.len == 0: return
  if ctx.byExplicitId.hasKey(explicitId):
    let otherId = ctx.byExplicitId[explicitId]
    let other = ctx.nodes[int(otherId)]
    raise newException(EDuplicateId,
      "duplicate @id '" & explicitId & "' declared at " &
      site.file & ":" & $site.line & ":" & $site.column &
      " (first declared at " & other.scopeDerivedName & ")")
  node.explicitId = explicitId
  ctx.byExplicitId[explicitId] = node.id

# ---------------------------------------------------------------------------
# Contributions
# ---------------------------------------------------------------------------

proc addContribution*(ctx: ConfigContext;
                      node: ConfigurableNode;
                      pri: ContributionPriority;
                      value: ConfigurableValue;
                      site: SourceSite) =
  ctx.requireOpen()
  if pri == prForce:
    if node.hasForce:
      raise newException(EDuplicateForce,
        "configurable '" & node.scopeDerivedName & "' already has a " &
        "prForce contribution at " & node.forceSite.file & ":" &
        $node.forceSite.line)
    node.hasForce = true
    node.forceSite = site
  node.contributions.add Contribution(priority: pri, value: value, site: site)
  node.resolved = false   # invalidate prior resolution

# ---------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------

proc combineEqualPriority(merge: CollectionMergeRule;
                          existing, incoming: ConfigurableValue):
                          ConfigurableValue =
  case merge
  of cmrScalarLastWins:
    incoming
  of cmrCollectionAppend:
    case existing.kind
    of cvkString:
      var s = existing.strVal
      if s.len > 0 and incoming.strVal.len > 0: s.add('\n')
      s.add(incoming.strVal)
      cvString(s)
    of cvkBytes:
      var b = existing.bytesVal
      b.add(incoming.bytesVal)
      cvBytes(b)
    else: incoming
  of cmrSetUnion, cmrMapUnion:
    # For scalar-shaped value kinds the union degenerates to
    # last-write-wins; the typed-collection layer can refine this.
    incoming

proc resolveNode*(ctx: ConfigContext; node: ConfigurableNode) =
  if node.resolved:
    return
  # Compute deps first.
  for depId in node.deps:
    ctx.resolveNode(ctx.nodes[int(depId)])

  if node.compute != nil:
    var inputs = newSeq[ConfigurableValue](node.deps.len)
    for i, depId in node.deps:
      inputs[i] = ctx.nodes[int(depId)].resolvedVal
    node.resolvedVal = node.compute(inputs)
    node.resolved = true
    return

  if node.contributions.len == 0:
    raise newException(EUnknownConfigurable,
      "configurable '" & node.scopeDerivedName & "' has no contributions")

  # Highest-priority contributions win. Equal-priority contributions
  # are merged according to the configurable's collection rule.
  var bestPri = prDefault
  for c in node.contributions:
    if c.priority > bestPri: bestPri = c.priority
  var combined: Option[ConfigurableValue]
  for c in node.contributions:
    if c.priority < bestPri: continue
    if combined.isNone:
      combined = some(c.value)
    else:
      combined = some(combineEqualPriority(node.mergeRule,
        combined.get(), c.value))
  node.resolvedVal = combined.get()
  node.resolved = true

proc finalize*(ctx: ConfigContext) =
  ctx.requireOpen()
  for n in ctx.nodes:
    ctx.resolveNode(n)
  ctx.state = ccsFinalized
  for fn in ctx.finalizers:
    fn()

proc addFinalizer*(ctx: ConfigContext; fn: proc() {.closure.}) =
  ctx.requireOpen()
  ctx.finalizers.add fn

# ---------------------------------------------------------------------------
# Reading resolved values
# ---------------------------------------------------------------------------

proc nodeOf*(ctx: ConfigContext; id: ConstructionId): ConfigurableNode =
  if int(id) >= ctx.nodes.len:
    raise newException(EUnknownConfigurable,
      "construction id " & $id & " is out of range for this context")
  ctx.nodes[int(id)]

proc resolvedValueOf*(ctx: ConfigContext; id: ConstructionId):
                     ConfigurableValue =
  ctx.requireFinalized()
  let n = ctx.nodeOf(id)
  n.resolvedVal

# ---------------------------------------------------------------------------
# Incremental refinalize
# ---------------------------------------------------------------------------

proc cloneNode(src: ConfigurableNode): ConfigurableNode =
  result = ConfigurableNode(
    id: src.id,
    scopeDerivedName: src.scopeDerivedName,
    explicitId: src.explicitId,
    description: src.description,
    descriptionFile: src.descriptionFile,
    descriptionLine: src.descriptionLine,
    descriptionColumn: src.descriptionColumn,
    valueKind: src.valueKind,
    mergeRule: src.mergeRule,
    contributions: src.contributions,
    deps: src.deps,
    compute: src.compute,
    resolved: src.resolved,
    resolvedVal: src.resolvedVal,
    forceSite: src.forceSite,
    hasForce: src.hasForce)

proc shallowClone*(ctx: ConfigContext): ConfigContext =
  ## Produce a writable child that shares structure with `ctx`.
  ## Nodes are cloned (so contribution lists can be appended without
  ## mutating the parent's lists); resolved values are reused so the
  ## child starts at the parent's last-resolved state.
  if ctx.state != ccsFinalized:
    raise newException(ENotFinalized,
      "shallowClone requires a finalized context")
  result = newConfigContext()
  result.parent = ctx
  result.state = ccsOpen
  result.nodes = newSeq[ConfigurableNode](ctx.nodes.len)
  for i, n in ctx.nodes:
    result.nodes[i] = cloneNode(n)
  result.byScope = ctx.byScope
  result.byExplicitId = ctx.byExplicitId

proc markDirtyRecursive(ctx: ConfigContext; id: ConstructionId;
                        dirty: var HashSet[ConstructionId];
                        reverseDeps: Table[ConstructionId,
                                           seq[ConstructionId]]) =
  if id in dirty: return
  dirty.incl id
  ctx.nodes[int(id)].resolved = false
  if reverseDeps.hasKey(id):
    for downstream in reverseDeps[id]:
      markDirtyRecursive(ctx, downstream, dirty, reverseDeps)

proc buildReverseDeps(ctx: ConfigContext):
                     Table[ConstructionId, seq[ConstructionId]] =
  result = initTable[ConstructionId, seq[ConstructionId]]()
  for n in ctx.nodes:
    for dep in n.deps:
      if not result.hasKey(dep):
        result[dep] = @[]
      result[dep].add n.id

proc resolveWithEarlyCutoff(ctx: ConfigContext;
                            seeds: HashSet[ConstructionId]) =
  ## Resolve only the dirty closure starting from `seeds`. A node is
  ## recomputed iff one of its inputs changed; if the recomputed
  ## value is byte-identical to the previous value, the change does
  ## NOT propagate further.
  let reverseDeps = ctx.buildReverseDeps()
  # BFS in topological order. For simplicity we iterate nodes in
  # construction-id order; since dependencies are recorded as ids
  # smaller than the dependent (cells are constructed before the
  # expressions that consume them), this order is a valid topo sort.
  ctx.refinalizeStats = RefinalizeStats(visited: 0, recomputed: 0,
    cutoffs: 0)
  var changed = seeds
  for n in ctx.nodes:
    var needsRecompute = false
    if n.id in changed: needsRecompute = true
    if not needsRecompute:
      for dep in n.deps:
        if dep in changed:
          needsRecompute = true
          break
    if not needsRecompute: continue
    inc ctx.refinalizeStats.visited
    let prior = n.resolvedVal
    let priorResolved = n.resolved
    n.resolved = false
    ctx.resolveNode(n)
    inc ctx.refinalizeStats.recomputed
    if priorResolved and n.resolvedVal == prior:
      # Early cutoff: this node's downstream nodes do not need to
      # recompute, since its visible value is unchanged.
      inc ctx.refinalizeStats.cutoffs
    else:
      changed.incl n.id

proc finalizeIncremental*(ctx: ConfigContext;
                          dirtySeeds: openArray[ConstructionId]) =
  var seeds = initHashSet[ConstructionId]()
  for s in dirtySeeds: seeds.incl s
  ctx.resolveWithEarlyCutoff(seeds)
  ctx.state = ccsFinalized
  for fn in ctx.finalizers:
    fn()

# ---------------------------------------------------------------------------
# Persistent lookup
# ---------------------------------------------------------------------------

proc adoptFromPersisted*(ctx: ConfigContext;
                        node: ConfigurableNode;
                        explicitId, scopeName: string):
                        bool {.discardable.} =
  ## If a persisted entry matches the configurable's identity,
  ## seed its `prDefault` contribution from the persisted value and
  ## (when applicable) overwrite contribution history. Returns true
  ## when an entry was adopted. Raises `EAmbiguousLookup` if more
  ## than one current declaration would resolve to the same
  ## persisted entry.
  if ctx.persistedEntries.len == 0: return false
  var key = ""
  if explicitId.len > 0 and ctx.persistedEntries.hasKey(explicitId):
    key = explicitId
  elif ctx.persistedByScope.hasKey(scopeName):
    key = ctx.persistedByScope[scopeName]
  if key.len == 0:
    return false
  let entry = ctx.persistedEntries[key]
  if entry == nil:
    raise newException(EAmbiguousLookup,
      "persisted entry for '" & key & "' has already been claimed by " &
      "another declaration in this context")
  node.contributions = entry.contributions
  node.resolvedVal = entry.resolvedVal
  node.resolved = false  # re-resolve under current context
  if entry.description.len > 0 and node.description.len == 0:
    node.description = entry.description
    node.descriptionFile = entry.descriptionFile
    node.descriptionLine = entry.descriptionLine
    node.descriptionColumn = entry.descriptionColumn
  # Mark consumed.
  ctx.persistedEntries[key] = nil
  return true
