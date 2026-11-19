## A version record from what the static `.nimble` reader read at one tag.
##
## The generator's `read` edge yields a ``NimbleFile`` per commit
## (``repro_nimble_reader``); the `source` and `refs` edges yield the facts
## the file cannot know (commit, tree digest, archive, first sighting). This
## module joins them into the record of spec § 4.2, field by field, and
## never looks at any other version: each record holds its own tag's
## requirements (NPC-AREQ31).

import std/[options, strutils]

import repro_domain_types/nimble_index
import repro_nimble_reader
import repro_nimble_reader/[conditions, requirements]

type
  VersionFacts* = object
    ## What the record needs besides the `.nimble`.
    tag*: string
      ## the tag the version was read at; for a pseudo-version, the branch
      ## (``kind`` ``rvkHead`` / ``rvkRef``) or empty (``rvkCommit``)
    pseudo*: Option[RecordVersionKind]
      ## ``rvkHead``, ``rvkRef`` or ``rvkCommit`` for a pseudo-version; none
      ## for a tag (which becomes ``rvkTag`` or ``rvkLabel``)
    commit*: string
    tree*: IndexObjectId
    archiveSha256*: Sha256Digest
    size*: uint64
    firstSeen*: uint64
    origin*: uint16
    nimbleFile*: Option[IndexObjectId]
    modules*: seq[string]
      ## the top-level module names under `srcDir`, from the tree
    flags*: set[RecordFlag]
      ## flags the `.nimble` cannot know: `uses_probe`, `platform_limited`,
      ## `gitlinks`, `override_applied`, or `unreadable` (e.g. a link out
      ## of the tree)
    probePlatform*: string

proc recordVersion*(tag: string): RecordVersion =
  ## A tag as a record version: `rvkTag` when it reads as a version
  ## (``parseTagVersion``), else `rvkLabel`.
  var comps: seq[uint64]
  if parseTagVersion(tag, comps):
    RecordVersion(kind: rvkTag, components: comps, tag: tag)
  else:
    RecordVersion(kind: rvkLabel, tag: tag)

proc conditionNodes*(c: Condition): seq[ConditionNode] =
  ## A reader condition flattened in prefix order; nil is unconditional.
  if c.isNil:
    return
  case c.kind
  of ckDefinedOs: result.add ConditionNode(kind: cnDefinedOs, name: c.name)
  of ckDefinedCpu: result.add ConditionNode(kind: cnDefinedCpu, name: c.name)
  of ckHostOsIs: result.add ConditionNode(kind: cnHostOs, name: c.name)
  of ckHostCpuIs: result.add ConditionNode(kind: cnHostCpu, name: c.name)
  of ckAnd, ckOr:
    result.add ConditionNode(kind: (if c.kind == ckAnd: cnAnd else: cnOr))
    result.add conditionNodes(c.left)
    result.add conditionNodes(c.right)
  of ckNot:
    result.add ConditionNode(kind: cnNot)
    result.add conditionNodes(c.operand)

proc conditionOf*(nodes: seq[ConditionNode]): Condition =
  ## The inverse of ``conditionNodes`` (nil for an empty list). The nodes
  ## must be well formed (``validateCondition``), as every decoded record's
  ## are.
  if nodes.len == 0:
    return nil
  var i = 0
  proc walk(): Condition =
    let n = nodes[i]
    inc i
    case n.kind
    of cnDefinedOs: definedOs(n.name)
    of cnDefinedCpu: definedCpu(n.name)
    of cnHostOs: hostOsIs(n.name)
    of cnHostCpu: hostCpuIs(n.name)
    of cnAnd:
      let a = walk()
      Condition(kind: ckAnd, left: a, right: walk())
    of cnOr:
      let a = walk()
      Condition(kind: ckOr, left: a, right: walk())
    of cnNot: Condition(kind: ckNot, operand: walk())
  walk()

proc requirementEntry*(e: Entry): RequirementEntry =
  ## One reader entry as a record requirement.
  let r = e.requirement
  result.condition = conditionNodes(e.condition)
  case r.target.kind
  of tkPackage:
    result.targetKind = rtPackage
    result.target = r.target.name
  of tkUrl:
    result.targetKind = rtUrl
    result.target = r.target.url
    result.subdir = r.target.subdir
  case r.version.kind
  of vkAny: result.versionKind = rvAny
  of vkHead: result.versionKind = rvHead
  of vkRange:
    result.versionKind = rvRange
    result.constraint = r.version.normalized
  of vkCommit:
    result.versionKind = rvCommit
    result.constraint = r.version.commit
  of vkRef:
    result.versionKind = rvRef
    result.constraint = r.version.refName
  result.features = r.features
  result.source = r.source

proc entries(es: seq[Entry]): seq[RequirementEntry] =
  for e in es: result.add requirementEntry(e)

proc recordField(f: Field): RecordField =
  for rf in RecordField:
    if $rf == $f:
      return rf
  refuse(nrUnknownVocabulary, "field " & $f & " cannot be assigned " &
    "conditionally in a record")

proc readerClassOf(c: ReaderClass): RecordReaderClass =
  for rc in RecordReaderClass:
    if $rc == $c:
      return rc
  refuse(nrUnknownVocabulary, "reader class " & $c)

proc recordFromNimbleFile*(f: NimbleFile; facts: VersionFacts): VersionRecord =
  ## The record of one version: `f` is the `.nimble` read at this version's
  ## own commit.
  result.version =
    if facts.pseudo.isSome:
      RecordVersion(kind: facts.pseudo.get, tag: facts.tag)
    else:
      recordVersion(facts.tag)
  result.commit = facts.commit.toLowerAscii()
  result.tree = facts.tree
  result.archiveSha256 = facts.archiveSha256
  result.size = facts.size
  result.firstSeen = facts.firstSeen
  result.origin = facts.origin
  result.nim = entries(f.nim)
  result.requires = entries(f.requires)
  for feat in f.features:
    result.features.add RecordFeature(name: feat.name, rootOnly: feat.rootOnly,
      requires: entries(feat.requires))
  result.layout = RecordLayout(srcDir: f.srcDir, installDirs: f.installDirs,
    installFiles: f.installFiles, installExt: f.installExt,
    skipDirs: f.skipDirs, skipFiles: f.skipFiles, skipExt: f.skipExt,
    paths: f.paths, modules: facts.modules)
  for c in f.conditionalFields:
    var cf = RecordConditionalField(field: recordField(c.field), append: c.append,
      values: c.values, condition: conditionNodes(c.condition))
    for (k, v) in c.pairs: cf.pairs.add NamedBin(key: k, value: v)
    result.layout.conditional.add cf
  result.binaries = RecordBinaries(bin: f.bin, binDir: f.binDir,
    backend: f.backend)
  for (k, v) in f.namedBin:
    result.binaries.namedBin.add NamedBin(key: k, value: v)
  for d in f.foreignDeps:
    result.foreign.add ForeignDependency(name: d.name,
      condition: conditionNodes(d.condition))
  result.flags = facts.flags
  if Flag.flHasTasks in f.flags: result.flags.incl RecordFlag.flHasTasks
  if Flag.flHasHooks in f.flags: result.flags.incl RecordFlag.flHasHooks
  if Flag.flUnreadable in f.flags and flOverrideApplied notin facts.flags and
      flUsesProbe notin facts.flags:
    result.flags.incl RecordFlag.flUnreadable
  result.readerClass = readerClassOf(f.readerClass)
  result.resolutionClass = readerClassOf(f.resolutionClass)
  result.probePlatform = facts.probePlatform
  result.nimbleFile = facts.nimbleFile
