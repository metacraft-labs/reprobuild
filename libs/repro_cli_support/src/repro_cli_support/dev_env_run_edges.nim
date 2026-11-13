## Run-edges receive their package's declared dev environment.
##
## A recipe that declares ``devEnv:`` states the environment its work needs:
## the libraries on the loader path, the tools on ``PATH``. ``repro exec``
## and ``repro shell`` have always applied it. The engine's actions did not:
## they inherit the environment ``repro`` was started from, so a test that
## loads ``libwebp`` passed when ``repro test`` ran inside the dev shell and
## failed with ``could not load: libwebp.so.7`` when CI started it from a
## plain one. A run-edge's verdict then depended on an input nothing
## declared.
##
## This module applies the recipe's dev-environment contribution to the
## package's RUN-EDGES and makes the contribution part of their cache keys.
## It is two pure functions and one graph query; the CLI owns realizing the
## environment (``repro_cli_support.applyRunEdgeDevEnv``).
##
## ## Which edges
##
## The members of the package's ``test`` and ``bench`` collections (and of
## a collection nested in one), in packages whose root fragment carries the
## ``DevEnvDeclaredGraphStableName`` marker. That is the membership the
## Generic Build Exclude Rules already use to tell a run-edge from an
## artifact edge. Compiles and every other edge keep the environment they
## had: changing their keys buys nothing, and the dev shell is not what
## their toolchain resolution is.
##
## ## How the environment merges
##
## The ops are applied in order with ``repro exec``'s own semantics
## (``repro_dev_env_activation.applyShellOp``), over the environment the edge
## would otherwise launch with: its declared entries over the inherited ones.
##
## * A ``setEnv`` / ``setPathList`` / ``unsetEnv`` does not touch a name the
##   edge itself declares. The edge's declaration (``extraEnv``, a hermetic
##   ``PATH``) is the more specific statement.
## * A ``prependPath`` / ``appendPath`` composes onto the edge's declared
##   value when there is one, otherwise onto the inherited value.
## * ``setWorkingDirectory`` is not applied: an edge's working directory is
##   the graph's.
##
## ## How it is keyed
##
## Every value the contribution decides becomes a declared entry of the
## edge, so it reaches the process however the engine launches it. A value
## fully decided by the recipe and the dev environment is keyed by value,
## like any declared entry. A value COMPOSED onto an inherited one (the
## host ``PATH`` under path provisioning) keeps its name passthrough: the
## host part stays exactly as unkeyed as it was before, and a developer's
## login ``PATH`` does not start keying every test. In both cases the
## contribution itself -- every applied op, in order -- is folded into the
## edge's weak fingerprint (``devEnvRunEdgeIdentity``), so a changed flake
## (new store paths) or a changed ``devEnv:`` body re-runs the edge.
##
## An empty contribution changes nothing and folds nothing: a ``devEnv:``
## with no arm for this platform moves no key.

import std/[sets, strtabs, strutils, tables]

import repro_build_engine
import repro_hash
import repro_provider_runtime
import repro_dev_env_activation
import repro_project_dsl
from repro_core/codec import toBytes

const
  RunEdgeCollectionNames* = ["test", "bench"]
    ## The collections whose members are run-edges for this purpose.
    ## ``lint`` is deliberately absent: its members are static checks, and
    ## the decision this implements covers execute edges.

  DevEnvRunEdgeFoldDomain = "dev-env-run-edge.v1"

proc isRunEdgeCollectionName*(name: string): bool =
  ## ``test`` / ``bench``, bare or ``<package>:``-qualified, the spelling
  ## ``lowerProviderSnapshot``'s exclude rule accepts.
  for base in RunEdgeCollectionNames:
    if name == base or name.endsWith(":" & base):
      return true
  false

proc devEnvRunEdgeActionIds*(snapshot: ProviderGraphSnapshot;
                             aliasByAction: Table[string, string]):
    HashSet[string] =
  ## The ids, as the lowered graph spells them, of the run-edges that
  ## receive a dev environment: members of a ``test`` / ``bench`` collection
  ## declared by a fragment that carries the dev-env marker.
  ##
  ## ``aliasByAction`` is the lowering's own rename table
  ## (``DirectTargetAliases.byAction``): an edge a ``target(...)`` renamed is
  ## lowered under that name, and this set must name it the same way.
  var targets = initTable[string, BuildTargetDef]()
  var roots: seq[string] = @[]
  for fragment in snapshot.fragments:
    var marked = false
    var names: seq[string] = @[]
    for node in fragment.nodes:
      if node.kind != gnkMetadata:
        continue
      if node.stableName == DevEnvDeclaredGraphStableName:
        marked = true
      elif node.stableName == "reprobuild.build-target.v1":
        let target = decodeBuildTargetPayload(toBytes(node.payload))
        targets[target.name] = target
        names.add(target.name)
    if marked:
      for name in names:
        if isRunEdgeCollectionName(name):
          roots.add(name)
  var visited = initHashSet[string]()
  var ids = initHashSet[string]()
  var pending = roots
  while pending.len > 0:
    let name = pending.pop()
    if visited.containsOrIncl(name) or not targets.hasKey(name):
      continue
    let target = targets[name]
    for actionId in target.actions:
      ids.incl(aliasByAction.getOrDefault(actionId, actionId))
    for nested in target.targets:
      pending.add(nested)
  ids

proc devEnvRunEdgeIdentity*(ops: openArray[DevEnvShellOp]): ContentDigest =
  ## The identity of a dev-environment contribution: every op, in order,
  ## length-framed so no two distinct op lists render alike. Order is part
  ## of it because order decides the result (two prepends).
  const US = "\x1f"
  const RS = "\x1e"
  var text = DevEnvRunEdgeFoldDomain & RS
  for op in ops:
    text.add($ord(op.kind) & US)
    for field in [op.name, op.value, op.separator]:
      text.add($field.len & US & field & US)
    text.add(RS)
  var bytes = newSeq[byte](text.len)
  for i, ch in text:
    bytes[i] = byte(ord(ch))
  blake3DomainDigest(bytes, hdActionFingerprint)

proc digestText(digest: ContentDigest): string =
  for b in digest.bytes:
    result.add(toHex(int(b), 2).toLowerAscii())

proc sameEnvName(a, b: string): bool =
  ## Windows environment names are case-insensitive; POSIX ones are not.
  when defined(windows): cmpIgnoreCase(a, b) == 0
  else: a == b

proc applyDevEnvToRunEdge*(action: var BuildAction;
                           ops: openArray[DevEnvShellOp];
                           identity: ContentDigest;
                           inheritedValue: proc (name: string): string):
    seq[string] =
  ## Apply the contribution ``ops`` to ``action`` and fold ``identity``
  ## (``devEnvRunEdgeIdentity(ops)``) into its weak fingerprint. See the
  ## module header for the merge and keying rules.
  ##
  ## ``inheritedValue`` answers what a name would hold if the action
  ## inherited it: the engine process's environment, read now (empty means
  ## unset). It is a parameter so the rules can be tested without touching
  ## the process environment.
  ##
  ## Returns the names an ``unsetEnv`` op could not remove: the launch
  ## layers the action's environment over the inherited one, so an inherited
  ## value has no removal channel. The caller reports them.
  if ops.len == 0:
    return
  var declared = initTable[string, string]()
  for entry in action.env:
    let eq = entry.find('=')
    if eq > 0:
      declared[entry[0 ..< eq]] = entry[eq + 1 .. ^1]
  proc declaredName(name: string): string =
    for key in declared.keys:
      if sameEnvName(key, name):
        return key
    ""
  var passthrough = initHashSet[string]()
  for name in action.envPassthrough:
    passthrough.incl(name)
  proc isPassthrough(name: string): bool =
    for item in passthrough:
      if sameEnvName(item, name):
        return true
    false

  let env =
    when defined(windows): newStringTable(modeCaseInsensitive)
    else: newStringTable(modeCaseSensitive)
  var touched: seq[string] = @[]
  var composedOnInherited = initHashSet[string]()
  var ignoredCwd = ""
  for op in ops:
    if op.kind == deskSetWorkingDirectory:
      continue
    let edgeName = declaredName(op.name)
    let edgeDeclares = edgeName.len > 0
    var seen = false
    for name in touched:
      if sameEnvName(name, op.name):
        seen = true
        break
    if not seen:
      touched.add(op.name)
      # Seed the base value the first time a name is touched: the edge's
      # declaration when it has one, otherwise what it would inherit.
      if edgeDeclares:
        env[op.name] = declared[edgeName]
      else:
        let inherited = inheritedValue(op.name)
        if inherited.len > 0:
          env[op.name] = inherited
          composedOnInherited.incl(op.name)
    case op.kind
    of deskSetEnv, deskSetPathList, deskUnsetEnv:
      if edgeDeclares:
        continue
      env.applyShellOp(op, ignoredCwd)
      composedOnInherited.excl(op.name)
    of deskPrependPath, deskAppendPath:
      env.applyShellOp(op, ignoredCwd)
    of deskSetWorkingDirectory:
      discard

  for name in touched:
    var kept: seq[string] = @[]
    for entry in action.env:
      let eq = entry.find('=')
      if eq > 0 and sameEnvName(entry[0 ..< eq], name):
        continue
      kept.add(entry)
    action.env = kept
    if not env.hasKey(name):
      if inheritedValue(name).len > 0:
        result.add(name)
      continue
    action.env.add(name & "=" & env[name])
    if name in composedOnInherited and not isPassthrough(name):
      action.envPassthrough.add(name)

  var payload = DevEnvRunEdgeFoldDomain & "\x00" &
    digestText(action.weakFingerprint) & "\x00" & digestText(identity) & "\x00"
  var bytes = newSeq[byte](payload.len)
  for i, ch in payload:
    bytes[i] = byte(ord(ch))
  action.weakFingerprint = blake3DomainDigest(bytes, hdActionFingerprint)
