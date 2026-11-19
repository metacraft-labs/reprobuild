## Test support (not a test): Nimble index fixtures built with the
## production writer, and an object source that records every fetch the
## reader makes -- the I/O the reader performs, observed from outside it.

import std/[options, strutils, tables]

import blake3

import repro_nimble_index

proc digestOf*(text: string): IndexObjectId =
  IndexObjectId(blake3.digest(text))

proc commitOf*(text: string): string =
  ## A deterministic 40-hex commit id for a fixture version.
  toHexLower(digestOf("commit:" & text))[0 ..< 40]

proc req*(name: string; constraint = ""; features: seq[string] = @[];
          condition: seq[ConditionNode] = @[]): RequirementEntry =
  ## A package requirement as the reader would record it.
  result = RequirementEntry(targetKind: rtPackage, target: name,
    features: features, condition: condition)
  if constraint.len == 0:
    result.versionKind = rvAny
    result.source = name
  else:
    result.versionKind = rvRange
    result.constraint = constraint
    result.source = name & " " & constraint

proc record*(package, tag: string; requires: seq[RequirementEntry] = @[];
             nim = ""): VersionRecord =
  ## A plain, statically readable record of ``package`` at ``tag``.
  var comps: seq[uint64]
  let isVersion = parseTagVersion(tag, comps)
  result.version =
    if isVersion: RecordVersion(kind: rvkTag, components: comps, tag: tag)
    else: RecordVersion(kind: rvkLabel, tag: tag)
  result.commit = commitOf(package & "@" & tag)
  result.tree = digestOf("tree:" & package & "@" & tag)
  result.archiveSha256 = digestOf("archive:" & package & "@" & tag)
  result.size = 1000
  result.firstSeen = 1_790_000_000
  result.requires = requires
  if nim.len > 0:
    result.nim = @[req("nim", nim)]
  result.readerClass = rrcPlain
  result.resolutionClass = rrcPlain
  result.nimbleFile = some(digestOf("nimble:" & package & "@" & tag))

proc package*(name: string; versions: seq[VersionRecord]): PackageEnvelope =
  PackageEnvelope(name: name, versions: versions,
    origins: @[PackageOrigin(url: "https://example.invalid/nim/" & name,
      vcs: ovGit)])

proc buildInput*(packages: seq[PackageEnvelope];
                 aliases: seq[PackageAlias] = @[];
                 shardBits = -1): IndexBuildInput =
  IndexBuildInput(generator: "reprobuild-nimble-index fixture",
    sourceSet: digestOf("source set"), generatedAt: 1_790_000_100,
    shardBits: shardBits, packages: packages, aliases: aliases)

proc syntheticPackages*(total: int): seq[PackageEnvelope] =
  ## ``total`` packages: the closure `alpha` -> `beta` -> `gamma`, and
  ## filler packages `filler0000`... that nothing requires.
  var ps = @[
    package("alpha", @[record("alpha", "v1.0.0", @[req("beta", ">= 1.0.0")]),
                       record("alpha", "v1.1.0", @[req("beta", ">= 1.1.0")])]),
    package("beta", @[record("beta", "1.0.0", @[req("gamma")]),
                      record("beta", "1.1.0", @[req("Gamma", ">= 0.1.0")])]),
    package("gamma", @[record("gamma", "0.1.0"), record("gamma", "0.2.0")])]
  var i = 0
  while ps.len < total:
    let name = "filler" & align($i, 4, '0')
    ps.add package(name, @[record(name, "1.0.0", @[req("filler0000")])])
    inc i
  ps

proc syntheticIndex*(total: int): BuiltIndex =
  ## The index of ``syntheticPackages(total)``.
  buildIndex(buildInput(syntheticPackages(total)))

type
  FetchLog* = ref object
    fetches*: seq[(IndexObjectId, string)]
      ## every object fetched, with the kind its frame names ("?" when it
      ## is not an index object frame)

proc countingSource*(inner: IndexObjectSource; log: FetchLog): IndexObjectSource =
  ## ``inner`` with every fetch recorded in ``log``.
  IndexObjectSource(description: inner.description,
    fetch: proc (id: IndexObjectId; maxBytes: int): seq[byte] =
      result = inner.fetch(id, maxBytes)
      var kind = "?"
      try:
        kind = $peekObjectKind(result)
      except NimbleIndexError:
        discard
      log.fetches.add (id, kind))

proc kinds*(log: FetchLog; kind: string): seq[IndexObjectId] =
  for (id, k) in log.fetches:
    if k == kind: result.add id

const LinuxAmd64* = NimblePlatform(id: "linux-amd64", targetOs: "linux",
  targetCpu: "amd64", hostOs: "linux", hostCpu: "amd64")
const WindowsAmd64* = NimblePlatform(id: "windows-amd64", targetOs: "windows",
  targetCpu: "amd64", hostOs: "windows", hostCpu: "amd64")

proc richPackage*(): PackageEnvelope =
  ## One package exercising every record field: conditions, features, the
  ## `dev` feature, layout, conditional layout, binaries, foreign
  ## dependencies, a label, a pseudo-version and flags.
  let onLinux = @[ConditionNode(kind: cnDefinedOs, name: "linux")]
  let notArm = @[ConditionNode(kind: cnAnd),
    ConditionNode(kind: cnDefinedOs, name: "macosx"),
    ConditionNode(kind: cnNot),
    ConditionNode(kind: cnHostCpu, name: "arm64")]
  var v1 = record("rich", "v1.2.3", @[req("chronos", ">= 4.0.0, < 5.0.0"),
    req("bearssl", features = @["tls"], condition = onLinux)], nim = ">= 1.6.0")
  v1.features = @[RecordFeature(name: "async", requires: @[req("asyncstuff")]),
    RecordFeature(name: "dev", rootOnly: true, requires: @[req("unittest2")])]
  v1.layout = RecordLayout(srcDir: "src", skipDirs: @["tests"],
    installExt: @["nim"], modules: @["rich", "rich_util"],
    conditional: @[RecordConditionalField(field: rfBin, append: true,
      values: @["richw"], condition: notArm)])
  v1.binaries = RecordBinaries(bin: @["richcli"],
    namedBin: @[NamedBin(key: "src/x", value: "x")], binDir: "bin",
    backend: "c")
  v1.foreign = @[ForeignDependency(name: "libssl-dev", condition: onLinux)]
  v1.flags = {flHasTasks}
  var label = record("rich", "nightly")
  label.flags = {flUnreadable}
  label.readerClass = rrcNeedsProbe
  label.resolutionClass = rrcNeedsProbe
  var head = record("rich", "main")
  head.version = RecordVersion(kind: rvkHead, tag: "main")
  head.requires = @[RequirementEntry(targetKind: rtUrl,
    target: "https://example.invalid/nim/other", subdir: "pkg",
    versionKind: rvCommit, constraint: "0123abcd",
    source: "https://example.invalid/nim/other?subdir=pkg#0123abcd")]
  result = package("rich", @[v1, label, head])
  result.origins.add PackageOrigin(url: "https://example.invalid/fork/rich",
    vcs: ovGit)
  result.registryOrigin = 1
