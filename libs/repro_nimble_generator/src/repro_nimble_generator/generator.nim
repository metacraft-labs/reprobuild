## The Nimble index generator as build-graph edges (NPC-AREQ9).
##
## A generation runs these edges through the build engine, in waves (each
## wave's edges are known only from the previous wave's outputs):
##
## | Edge | Kind | Network | Cache key | Output |
## | --- | --- | --- | --- | --- |
## | `registry <remote>@<commit>` | `bakMetadataFetch` | `netFetch` | remote, commit, git identity | `packages.json` at the commit |
## | `refs <package>` | `bakMetadataFetch` | `netFetch` | none: revalidated every generation | the origin's tags (peeled) and `HEAD` |
## | `refs <package> history` | `bakMetadataFetch` | `netFetch` | origin, the commits it is asked about, generation | the commits of every branch and tag |
## | `source <package>@<commit>` | `bakMetadataFetch` | `netFetch` | origin, subdir, commit, git identity, limits | the source facts, the `.nimble`, the canonical archive |
## | `read <blake3 of .nimble>` | `bakCatalogIndex` | `netDenied` | the `.nimble` bytes' hash, the reader version | the record as the static reader reads it |
## | `shard <bucket>` | `bakCatalogIndex` | `netDenied` | the hashes of every input object, the generation parameters | the shard and its events |
## | `root` | `bakCatalogIndex` | `netDenied` | the hashes of the shards and events, the generation parameters | the root and name map |
##
## The fetch edges are the WORKERS of the threat model: they hold no
## credential (git runs in an environment built from nothing), fetch only
## through the origin egress policy (`egress`), never follow a symbolic link
## or a gitlink, and hand on only content: objects named by what they hold.
## The pure edges are the PUBLISHER's computation: they read only those
## outputs and the previous generation's shards.
##
## Incremental: a `source` or `read` edge is keyed by the commit or the
## `.nimble` bytes it reads, so a warm generation re-runs them only for what
## the origins changed; `refs` alone is revalidated each time, and a shard
## whose inputs did not change is a cache hit (NPC-AREQ10).
##
## Deterministic: the output is a function of the source set, the registry
## commit, the origin answers, the previous generation and the generation
## time, which is an input (`generatedAt`); nothing reads a clock, a path,
## the environment or the host into an output. `repro catalog verify`
## repeats a generation from the same inputs and compares the roots.

import std/[algorithm, options, os, sets, strutils, tables]

import blake3

import repro_build_engine
import repro_lock/identity
import repro_domain_types/nimble_index
import repro_nimble_index
import repro_nimble_reader except nameKey
import git_tool

import repro_nimble_fetch/mirror

import ./assemble
import ./edge_objects
import ./egress
import ./origin_git
import ./registry
import ./source_set
import ./source_tree

const
  GeneratorIdentity* = "reprobuild-nimble-generator/1"
    ## The root's `generator`: the generator's own version, never the host's
    ## tools, so two operators with different git builds agree.
  ReaderIdentity = "repro_nimble_reader/1"
  MaxGenerationIterations = 64

type
  EdgeFamily* = enum
    efRegistry = "registry"
    efRefs = "refs"
    efHistory = "refs-history"
    efSource = "source"
    efRead = "read"
    efShard = "shard"
    efRoot = "root"

  NetworkObserver* = proc(family: EdgeFamily; url: string) {.gcsafe.}
    ## Called with every URL a fetch edge hands to the transport, before the
    ## egress policy runs on it. Tests use it to show what was attempted.

  GeneratorConfig* = object
    sourceSet*: SourceSet
    generatedAt*: uint64
      ## the generation time: every new sighting's `first_seen`, every
      ## event's time and the root's `generatedAt`. An input, so a repeated
      ## run (`repro catalog verify`) uses the original's.
    previousIndex*: string
      ## the previous generation's index directory (`published-index/`), or
      ## "" for the first generation
    stateDir*: string
      ## this host's edge outputs and engine cache; never part of an output
    outputDir*: string
      ## where to write the new index directory; "" writes nothing
    policy*: EgressPolicy
    gitBin*: string ## "" resolves git from `PATH`
    shardBits*: int ## < 0: the previous root's, else the default
    observer*: NetworkObserver
    mirrors*: seq[Mirror]
      ## where the generation's source objects are published; empty: the
      ## source set's `[[mirror]]` tables. Read only when ``outputDir`` is set
    mirrorAccess*: Option[EgressPolicy]
      ## how HTTPS mirrors are reached (resolver, trust anchors, limits);
      ## none: the host's defaults

  Execution* = object
    family*: EdgeFamily
    subject*: string

  CapturedRefusal* = object
    package*: string
    family*: EdgeFamily
    refusal*: EgressRefusal

  GenerationResult* = object
    built*: BuiltIndex
    executed*: seq[Execution]
      ## every edge whose executor ran this generation (a cache hit is not in
      ## it), in execution order
    refusals*: seq[CapturedRefusal]
    diagnostics*: seq[string]
    events*: seq[OriginEvent]
    actions*: seq[BuildAction] ## every edge of the generation

  GeneratorError* = object of CatchableError

  Target = object
    name: string
    origin: PackageOrigin
    listed: bool
    unlisted: bool
    pinnedCommit: string

  Job = object
    family: EdgeFamily
    subject: string
    package: string
    url: string
    subdir: string
    commit: string
    vcs: OriginVcs
    registryCommit: string
    inputs: seq[string]
    shardBucket: uint32
    shardNames: seq[string]
    shardAliases: seq[PackageAlias]

  Run = ref object
    cfg: GeneratorConfig
    git: OriginGit
    gitDigest: string
    jobs: Table[string, Job]
    executed: seq[Execution]
    refusals: seq[CapturedRefusal]
    failures: seq[string]
    # the publisher's view, shared by the shard and root executors
    targets: Table[string, Target]
    previousEnvelopes: Table[string, PackageEnvelope]
    previousObservations: Table[string, PackageObservation]
    refsPath: Table[string, string]     ## name key -> refs output
    historyPath: Table[string, string]
    sourcePath: Table[string, string]   ## origin key & commit -> source output
    readPath: Table[string, string]     ## nimble hash -> read output
    sightings: Table[string, seq[Sighting]]
    expansions: Table[string, Expansion]
    aliasTarget: Table[string, string]  ## alias name key -> canonical name
    carried: HashSet[string]
      ## name keys the previous generation has and this one did not visit
      ## (outside the roots' closure): copied unchanged
    shardBits: int
    shardOutputs: seq[(string, string)] ## (shard file, events file)
    objectHashes: Table[string, string]
      ## worker output file -> the hash the publisher's cache key names; the
      ## publisher reads a worker's output only through ``readObject``
    previousRoot: Option[IndexObjectId]

proc hex(s: string): string = toHexLower(blake3.digest(s))

proc fail(msg: string) {.noreturn.} =
  raise newException(GeneratorError, msg)

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(ord(c))

proc toStr(b: openArray[byte]): string =
  result = newString(b.len)
  for i, x in b: result[i] = char(x)

proc edgePath(run: Run; family: EdgeFamily; key: string; ext = ""): string =
  run.cfg.stateDir / "edges" / $family / key & ext

proc originKey(url, subdir: string): string = url & "?subdir=" & subdir

proc destinationOf(url: string): string =
  ## The tracked destination a fetch edge declares: the origin as named.
  url

# ---------------------------------------------------------------------------
# The fetch executors (workers)
# ---------------------------------------------------------------------------

proc scratchFor(run: Run; key: string): string =
  result = run.cfg.stateDir / "scratch" / key
  if dirExists(result): removeDir(result)
  createDir(result)

proc capture(run: Run; job: Job; e: ref EgressError) =
  run.refusals.add CapturedRefusal(package: job.package, family: job.family,
    refusal: e.refusal)

proc vet(run: Run; job: Job): VettedOrigin =
  if run.cfg.observer != nil:
    {.cast(gcsafe).}: run.cfg.observer(job.family, job.url)
  if job.vcs == ovHg:
    refuse(erScheme, job.url, "Mercurial origins are not fetched by this " &
      "generator")
  vetOrigin(run.cfg.policy, job.url)

proc execRegistry(run: Run; job: Job; outPath: string) =
  let scratch = run.scratchFor(hex(job.subject))
  defer: removeDir(scratch)
  let v = run.vet(job)
  let limits = run.cfg.policy.limits
  let (ok, repo, failure) = fetchCommit(run.git, v, scratch, job.commit, limits)
  if not ok:
    fail("registry " & job.url & " at " & job.commit & " could not be " &
      "fetched: " & failure)
  let r = runBounded(run.git, @["--git-dir=" & repo, "cat-file", "blob",
    job.commit & ":packages.json"], scratch, scratch / "home", limits)
  if r.code != 0:
    fail("registry " & job.url & " has no packages.json at " & job.commit)
  writeFile(outPath, r.stdoutText)

proc execRefs(run: Run; job: Job; outPath: string) =
  var answer: RefsAnswer
  let scratch = run.scratchFor(hex(job.subject))
  defer: removeDir(scratch)
  try:
    let v = run.vet(job)
    let (ok, ls, failure) = lsRemote(run.git, v, scratch, run.cfg.policy.limits)
    if ok:
      answer = RefsAnswer(state: anOk, headRef: ls.headRef, head: ls.head,
        tags: ls.tags)
    else:
      answer = RefsAnswer(state: anFailed, detail: failure)
  except EgressError as e:
    run.capture(job, e)
    answer = RefsAnswer(state: anRefused, refusal: $e.refusal.kind,
      detail: e.refusal.detail)
  writeFile(outPath, encodeRefs(answer))

proc execHistory(run: Run; job: Job; outPath: string) =
  var answer: HistoryAnswer
  let scratch = run.scratchFor(hex(job.subject))
  defer: removeDir(scratch)
  try:
    let v = run.vet(job)
    let h = fetchHistory(run.git, v, scratch, run.cfg.policy.limits)
    if h.ok:
      answer = HistoryAnswer(state: anOk, branchCommits: h.branchCommits,
        allCommits: h.allCommits)
    else:
      answer = HistoryAnswer(state: anFailed, detail: h.failure)
  except EgressError as e:
    run.capture(job, e)
    answer = HistoryAnswer(state: anRefused, refusal: $e.refusal.kind,
      detail: e.refusal.detail)
  writeFile(outPath, encodeHistory(answer))

proc execSource(run: Run; job: Job; outPath: string) =
  var answer = SourceAnswer(commit: job.commit)
  var nimbleBytes = ""
  var archive = ""
  let scratch = run.scratchFor(hex(job.subject))
  defer: removeDir(scratch)
  try:
    let v = run.vet(job)
    let limits = run.cfg.policy.limits
    let (ok, repo, failure) = fetchCommit(run.git, v, scratch, job.commit,
      limits)
    if not ok:
      answer.state = anFailed
      answer.detail = failure
    else:
      let tree = readTree(run.git, repo, job.commit, job.subdir, limits)
      let (facts, arch, nb) = sourceFacts(tree)
      answer.state = anOk
      answer.facts = facts
      archive = arch
      nimbleBytes = nb
  except EgressError as e:
    run.capture(job, e)
    answer.state = anRefused
    answer.refusal = $e.refusal.kind
    answer.detail = e.refusal.detail
  except IOError as e:
    answer.state = anFailed
    answer.detail = e.msg
  writeFile(outPath, encodeSource(answer))
  writeFile(outPath & ".nimble", nimbleBytes)
  writeFile(outPath & ".tar", archive)

# ---------------------------------------------------------------------------
# The pure executors (publisher)
# ---------------------------------------------------------------------------

const ReadPlaceholderCommit = "0000000000000000000000000000000000000000"

proc readRecordBytes*(nimbleBytes, fileName: string): seq[byte] =
  ## The `read` edge: the record the static reader reads from a `.nimble`,
  ## encoded with the index codec as the one record of a placeholder shard
  ## (its version, commit and digests are the publisher's to fill).
  let f = readNimbleSource(nimbleBytes, fileName)
  var facts = VersionFacts(tag: "read", commit: ReadPlaceholderCommit,
    nimbleFile: some(IndexObjectId(blake3.digest(nimbleBytes))))
  let rec = recordFromNimbleFile(f, facts)
  let shard = NimbleShard(shardBits: 0, bucket: 0, packages: @[
    PackageEnvelope(name: "read", origins: @[PackageOrigin(
      url: "https://read.invalid/", vcs: ovGit)], versions: @[rec])])
  encodeShard(shard)

proc decodeReadRecord*(bytes: openArray[byte]): VersionRecord =
  let s = decodeShard(bytes)
  if s.packages.len != 1 or s.packages[0].versions.len != 1:
    raise newException(NimbleIndexError, "not a read record")
  s.packages[0].versions[0]

proc recordableOrigin*(o: PackageOrigin): PackageOrigin =
  ## An origin as the index records it: the URL with every byte outside
  ## printable ASCII (and `%`) percent-encoded, so an origin the policy
  ## refused -- `ext::sh -c ...` -- is still recorded exactly, as text.
  proc pct(s: string): string =
    for c in s:
      if ord(c) < 0x21 or ord(c) > 0x7e or c == '%':
        result.add '%' & toHex(ord(c), 2)
      else:
        result.add c
  PackageOrigin(url: pct(o.url), subdir: pct(o.subdir), vcs: o.vcs)

proc readObject(run: Run; path: string): string =
  ## A worker's output, read by the publisher: refused unless it is the
  ## object the shard's cache key names (threat model § 3.2: the publisher
  ## consumes content-addressed outputs).
  result = readFile(path)
  if path in run.objectHashes and hex(result) != run.objectHashes[path]:
    raise newException(EdgeObjectError, path & " is not the object the " &
      "shard edge was keyed on")

proc packageInput(run: Run; t: Target): PackageInput =
  ## A package's publisher input, from the fetch edges' output files only.
  let k = nameKey(t.name)
  result = PackageInput(name: t.name, origin: recordableOrigin(t.origin),
    listed: t.listed, unlisted: t.unlisted)
  if k in run.previousEnvelopes: result.previous = some(run.previousEnvelopes[k])
  if k in run.previousObservations:
    result.previousObservation = some(run.previousObservations[k])
  if k in run.refsPath:
    result.refs = some(decodeRefs(run.readObject(run.refsPath[k])))
  if k in run.historyPath:
    result.history = some(decodeHistory(run.readObject(run.historyPath[k])))
  result.sightings = run.sightings.getOrDefault(k)
  let ok = originKey(t.origin.url, t.origin.subdir)
  for s in result.sightings:
    let sk = ok & "@" & s.commit
    if sk notin run.sourcePath or s.commit in result.builds: continue
    let src = decodeSource(run.readObject(run.sourcePath[sk]))
    var b = VersionBuild(source: src)
    if src.state == anOk and src.facts.nimble == nlFound:
      let nb = readFile(run.sourcePath[sk] & ".nimble")
      let h = hex(nb)
      if h in run.readPath:
        b.read = some(decodeReadRecord(toBytes(
          run.readObject(run.readPath[h]))))
    result.builds[s.commit] = b
  for o in run.cfg.sourceSet.overrides:
    if nameKey(o.package) == k and o.hasRequires:
      result.overrides.add o

proc sortedEvents*(events: seq[OriginEvent]): seq[OriginEvent] =
  result = events
  result.sort(proc (a, b: OriginEvent): int =
    cmp(eventSortKey(a), eventSortKey(b)))

proc resolveName(run: Run; name: string): string =
  let k = nameKey(name)
  if k in run.targets: run.targets[k].name
  else: run.aliasTarget.getOrDefault(k, "")

proc params(run: Run): GenerationParams =
  GenerationParams(generatedAt: run.cfg.generatedAt,
    cooldownSeconds: uint64(run.cfg.sourceSet.policy.cooldownDays) * 86400,
    expansions: run.expansions,
    resolveName: proc(name: string): string {.gcsafe.} =
      {.cast(gcsafe).}: run.resolveName(name))

proc execShard(run: Run; job: Job; outPath: string) =
  var packages: seq[PackageEnvelope]
  var observations: seq[PackageObservation]
  var events: seq[OriginEvent]
  let p = run.params()
  for name in job.shardNames:
    let k = nameKey(name)
    if k in run.carried:
      # Carried unchanged: the previous generation's, untouched.
      if k in run.previousEnvelopes: packages.add run.previousEnvelopes[k]
      if k in run.previousObservations:
        observations.add run.previousObservations[k]
    else:
      let o = assemblePackage(run.packageInput(run.targets[k]), p)
      if o.envelope.isSome: packages.add o.envelope.get
      observations.add o.observation
      events.add o.events
  writeFile(outPath, toStr(buildShard(run.shardBits, job.shardBucket,
    packages, job.shardAliases, observations)))
  writeFile(outPath & ".events", toStr(encodeEvents(NimbleEvents(
    events: sortedEvents(events)))))

proc execRoot(run: Run; job: Job; outPath: string) =
  var shards: seq[seq[byte]]
  var events: seq[OriginEvent]
  for (shardFile, eventsFile) in run.shardOutputs:
    shards.add toBytes(readFile(shardFile))
    events.add decodeEvents(toBytes(readFile(eventsFile))).events
  let built = buildRootFromShards(IndexBuildInput(generator: GeneratorIdentity,
    sourceSet: sourceSetIdentity(run.cfg.sourceSet),
    generatedAt: run.cfg.generatedAt, previousRoot: run.previousRoot,
    events: events), run.shardBits, shards)
  writeFile(outPath, toStr(built.rootBytes))
  writeFile(outPath & ".names", toStr(built.objectTable()[built.root.nameMap.id]))
  writeFile(outPath & ".events", toStr(built.objectTable()[built.root.events.id]))

proc execute(run: Run; action: BuildAction): ActionResult =
  result = ActionResult(id: action.id, status: asSucceeded, exitCode: 0,
    launched: true)
  if action.id notin run.jobs:
    result.status = asFailed
    result.exitCode = 1
    result.stderr = "no generator job for " & action.id
    return
  let job = run.jobs[action.id]
  let outPath = action.outputs[0]
  createDir(parentDir(outPath))
  run.executed.add Execution(family: job.family, subject: job.subject)
  try:
    case job.family
    of efRegistry: run.execRegistry(job, outPath)
    of efRefs: run.execRefs(job, outPath)
    of efHistory: run.execHistory(job, outPath)
    of efSource: run.execSource(job, outPath)
    of efRead:
      writeFile(outPath, toStr(readRecordBytes(readFile(job.inputs[0]),
        job.subject)))
    of efShard: run.execShard(job, outPath)
    of efRoot: run.execRoot(job, outPath)
  except CatchableError as e:
    result.status = asFailed
    result.exitCode = 1
    result.stderr = $job.family & " " & job.subject & ": " & e.msg

# ---------------------------------------------------------------------------
# Edges
# ---------------------------------------------------------------------------

proc fetchAction(run: Run; job: Job; key: string; cacheable: bool;
                 extraOutputs: seq[string] = @[]): BuildAction =
  let id = "npc/" & $job.family & "/" & key
  run.jobs[id] = job
  let outPath = run.edgePath(job.family, key)
  var outputs = @[outPath]
  for e in extraOutputs: outputs.add outPath & e
  builtinAction(bakMetadataFetch, id,
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    outputs = outputs, cacheable = cacheable,
    weakFingerprint = weakFingerprintFromText(job.subject & "\n" & key),
    text = $job.family & " " & job.subject,
    networkMode = netFetch, netDestinations = [destinationOf(job.url)])

proc pureAction(run: Run; job: Job; key: string; inputs: seq[string];
                fingerprint: string; extraOutputs: seq[string] = @[]):
                  BuildAction =
  let id = "npc/" & $job.family & "/" & key
  var j = job
  j.inputs = inputs
  run.jobs[id] = j
  let outPath = run.edgePath(job.family, key)
  var outputs = @[outPath]
  for e in extraOutputs: outputs.add outPath & e
  builtinAction(bakCatalogIndex, id,
    governingLockIdentity = lockIdentityOutsideSolvedGraph(),
    inputs = inputs, outputs = outputs, cacheable = true,
    weakFingerprint = weakFingerprintFromText(fingerprint),
    text = $job.family & " " & job.subject)

proc runWave(run: Run; actions: seq[BuildAction]; all: var seq[BuildAction]) =
  if actions.len == 0: return
  all.add actions
  let g = graph(actions)
  let findings = auditNetworkPolicy(g)
  if findings.len > 0:
    fail(formatNetworkPolicyAudit(findings))
  registerMetadataFetchExecutor(proc(action: BuildAction): ActionResult
      {.gcsafe.} =
    {.cast(gcsafe).}: run.execute(action))
  registerCatalogIndexExecutor(proc(action: BuildAction): ActionResult
      {.gcsafe.} =
    {.cast(gcsafe).}: run.execute(action))
  try:
    var cfg = defaultBuildEngineConfig(run.cfg.stateDir / "engine-cache")
    cfg.maxParallelism = 1
    cfg.bypassRunQuota = true
    cfg.deferLocalOutputBlobs = false
    let outcome = runBuild(g, cfg)
    for res in outcome.results:
      if res.status == asFailed:
        fail("generator edge " & res.id & " failed: " & res.stderr)
  finally:
    clearMetadataFetchExecutor()
    clearCatalogIndexExecutor()

proc keyOf(parts: varargs[string]): string =
  var s = ""
  for p in parts: s.add p & "\0"
  hex(s)

proc answeredBefore(sourceOutput: string): bool =
  ## Whether a `source` edge's output from an earlier generation on this
  ## host (absent: none ran) is an answer the origin gave. Only those are
  ## served from the cache.
  if not fileExists(sourceOutput): return true
  try:
    decodeSource(readFile(sourceOutput)).state == anOk
  except CatchableError:
    false

# ---------------------------------------------------------------------------
# The generation
# ---------------------------------------------------------------------------

proc loadPrevious(run: Run) =
  if run.cfg.previousIndex.len == 0: return
  let src = directorySource(run.cfg.previousIndex)
  let rootId = indexDirRootId(run.cfg.previousIndex)
  var idx = openIndex(src, rootId)
  run.previousRoot = some(rootId)
  for r in idx.root.shards:
    let s = idx.loadShard(r.bucket)
    if s.isNone: continue
    for p in s.get.packages: run.previousEnvelopes[nameKey(p.name)] = p
    for o in s.get.observations: run.previousObservations[nameKey(o.name)] = o
  if run.cfg.shardBits < 0:
    run.shardBits = int(idx.root.shardBits)

proc publishSources(run: Run; built: BuiltIndex) =
  ## Publishing (NPC-AREQ13, threat model G12): write this generation's
  ## canonical archives to every directory mirror, then refuse unless EVERY
  ## source object the new index names -- the records carried from earlier
  ## generations included -- is on EVERY required mirror at its recorded
  ## size. Runs before the index directory is written, so an incomplete
  ## revision is never written at all.
  let mirrors =
    if run.cfg.mirrors.len > 0: run.cfg.mirrors
    else: mirrorsOf(run.cfg.sourceSet.mirrors)
  var anyRequired = false
  for m in mirrors:
    if m.required: anyRequired = true
  if not anyRequired:
    fail("the index declares no required mirror: an index repository " &
      "keeps a durable copy of every source it names (NPC-AREQ13), so a " &
      "generation is published only with at least one [[mirror]] in " &
      SourceSetFileName)
  let access =
    if run.cfg.mirrorAccess.isSome: run.cfg.mirrorAccess.get
    else: defaultPolicy()
  var keys: seq[string]
  for k in run.sourcePath.keys: keys.add k
  keys.sort()
  for k in keys:
    let path = run.sourcePath[k]
    let src = decodeSource(readFile(path))
    if src.state != anOk: continue
    let archive = readFile(path & ".tar")
    for m in mirrors:
      if m.kind == mkDirectory:
        m.putObject(sourceObjectPath(src.facts.treeDigest), archive)
  var objects: seq[SourceObjectRef]
  var seen = initHashSet[string]()
  for (id, bytes) in built.objects:
    if id == built.rootId or id == built.root.nameMap.id or
        id == built.root.events.id:
      continue
    let shard = decodeShard(bytes)
    for p in shard.packages:
      for v in p.versions:
        let t = $v.tree
        if t in seen: continue
        seen.incl t
        objects.add SourceObjectRef(tree: t, size: int64(v.size),
          label: p.name & " " & v.version.tag & " (" & v.commit & ")")
  let missing = missingFromMirrors(mirrors, objects, access)
  if missing.len > 0:
    var lines: seq[string]
    for x in missing:
      lines.add x.mirror & ": " & x.obj.label & " tree " & x.obj.tree &
        ": " & x.detail
    fail("the generation is not published: " & $missing.len & " source " &
      "object(s) are not on every required mirror (NPC-AREQ13):\n  " &
      lines.join("\n  "))

proc unlistedName(url, subdir: string): string =
  var u = url.toLowerAscii()
  let sep = u.find("://")
  if sep >= 0: u = u[sep + 3 .. ^1]
  while u.endsWith("/"): u.setLen(u.len - 1)
  if u.endsWith(".git"): u.setLen(u.len - 4)
  u & (if subdir.len > 0: "?subdir=" & subdir else: "")

proc generate*(config: GeneratorConfig): GenerationResult =
  ## One generation (see the module docstring).
  let ss = config.sourceSet
  if ss.policy.probe == ppSandboxed:
    fail("probe = \"sandboxed\" is refused: the probe runs `nimble dump` on " &
      "package code and needs a confinement this build cannot provide yet " &
      "(no network, an empty NIMBLE_DIR, writes to scratch only, under the " &
      "monitor). It refuses rather than run unconfined; milestone NPC-M10 " &
      "completes the confinement. Use probe = \"off\" and [[override]] " &
      "records for the versions the static reader cannot read.")
  if config.stateDir.len == 0:
    fail("a generation needs a state directory")
  let run = Run(cfg: config, shardBits: config.shardBits)
  createDir(config.stateDir)
  if run.cfg.policy.limits.maxBytes == 0:
    run.cfg.policy.limits = DefaultLimits
  let gitBin =
    if config.gitBin.len > 0: config.gitBin
    else:
      let id = resolveGitTool(tpmPathOnly, getEnv("PATH"))
      run.gitDigest = id.digestHex()
      id.binaryPath
  run.git = OriginGit(gitBin: gitBin, caFile: run.cfg.policy.caFile)
  if run.gitDigest.len == 0: run.gitDigest = hex(gitBin)
  run.loadPrevious()
  let limitsKey = $run.cfg.policy.limits.maxBytes & "/" &
    $run.cfg.policy.limits.stallSeconds & "/" & $run.cfg.policy.limits.wallSeconds
  var all: seq[BuildAction]

  # ---- registry ---------------------------------------------------------
  var regActions: seq[BuildAction]
  var regFiles: seq[string]
  for r in ss.registries:
    let key = keyOf("registry", r.remote, r.commit, run.gitDigest)
    let job = Job(family: efRegistry, subject: r.remote & "@" & r.commit,
      package: "", url: r.remote, commit: r.commit, vcs: ovGit)
    regActions.add run.fetchAction(job, key, cacheable = true)
    regFiles.add run.edgePath(efRegistry, key)
  run.runWave(regActions, all)

  var aliases: seq[RegistryAlias]
  var aliasTarget = initTable[string, string]()
  for f in regFiles:
    let reg = parseRegistry(readFile(f))
    for (n, why) in reg.skipped:
      result.diagnostics.add "registry entry " & n.escape() & " skipped: " & why
    for p in reg.packages:
      let k = nameKey(p.name)
      if k in run.targets:
        fail("package " & p.name & " is listed by two registries")
      run.targets[k] = Target(name: p.name, listed: true,
        origin: PackageOrigin(url: p.url, subdir: p.subdir, vcs: p.vcs))
    aliases.add reg.aliases
  for x in ss.extras:
    let k = nameKey(x.name)
    if k in run.targets:
      fail("[[extra]] " & x.name & " is also a registry package; repoint " &
        "a registry package with [[override]]")
    run.targets[k] = Target(name: x.name, listed: true,
      origin: PackageOrigin(url: x.origin, subdir: x.subdir, vcs: ovGit))
  for o in ss.overrides:
    let k = nameKey(o.package)
    if o.origin.len > 0:
      if k notin run.targets:
        run.targets[k] = Target(name: o.package, listed: true)
      run.targets[k].origin = PackageOrigin(url: o.origin, subdir: o.subdir,
        vcs: ovGit)
      run.targets[k].pinnedCommit = o.commit
  for a in aliases:
    if nameKey(a.target) in run.targets:
      aliasTarget[nameKey(a.alias)] = run.targets[nameKey(a.target)].name
  run.aliasTarget = aliasTarget
  let resolve = proc(name: string): string = run.resolveName(name)
  for k, env in run.previousEnvelopes:
    if k notin run.targets:
      # No longer listed: processed, so its observation says `gone`.
      run.targets[k] = Target(name: env.name, listed: false,
        origin: env.origins[env.registryOrigin])
  if run.shardBits < 0:
    run.shardBits = defaultShardBits(run.targets.len)

  # ---- the closure: refs, history, source, read -------------------------
  var trackKeys = initHashSet[string]()
  for h in ss.policy.trackHead: trackKeys.incl nameKey(h)
  var frontier: seq[string]
  if ss.roots.len > 0:
    for r in ss.roots:
      let n = resolve(r)
      if n.len == 0: fail("root " & r & " is not a package of the source set")
      frontier.add n
  else:
    for k, t in run.targets: frontier.add t.name
  var inClosure = initHashSet[string]()
  var abbrRequests = initTable[string, HashSet[string]]()
  var commitRequests = initTable[string, HashSet[string]]()
  var historyAsked = initTable[string, string]()
  var scannedReads = initHashSet[string]()
  var iteration = 0
  while true:
    inc iteration
    if iteration > MaxGenerationIterations:
      fail("the generation did not reach a closed set of packages in " &
        $MaxGenerationIterations & " waves")
    var changed = false
    frontier.sort()
    var refsWave: seq[BuildAction]
    for n in frontier:
      let k = nameKey(n)
      if k in inClosure: continue
      inClosure.incl k
      changed = true
      let t = run.targets[k]
      if not t.listed: continue
      let key = keyOf("refs", t.name, t.origin.url, t.origin.subdir,
        $config.generatedAt)
      let job = Job(family: efRefs, subject: t.name, package: t.name,
        url: t.origin.url, subdir: t.origin.subdir, vcs: t.origin.vcs)
      refsWave.add run.fetchAction(job, key, cacheable = false)
      run.refsPath[k] = run.edgePath(efRefs, key)
    frontier = @[]
    run.runWave(refsWave, all)

    # History: abbreviation targets, and origins whose HEAD moved.
    var historyWave: seq[BuildAction]
    var keysSorted: seq[string]
    for k in inClosure: keysSorted.add k
    keysSorted.sort()
    for k in keysSorted:
      let t = run.targets[k]
      if not t.listed or k notin run.refsPath: continue
      var reason = ""
      var abbrs: seq[string]
      for a in abbrRequests.getOrDefault(k): abbrs.add a
      abbrs.sort()
      if abbrs.len > 0: reason = "expand " & abbrs.join(",")
      if k in run.previousObservations:
        let prev = run.previousObservations[k]
        let refs = decodeRefs(readFile(run.refsPath[k]))
        if refs.state == anOk and prev.state == osAnswering and
            prev.head.len > 0 and refs.head != prev.head and
            sameOrigin(prev.origin, recordableOrigin(t.origin)):
          reason.add " head " & prev.head
      if reason.len == 0 or historyAsked.getOrDefault(k) == reason: continue
      historyAsked[k] = reason
      changed = true
      let key = keyOf("history", t.name, t.origin.url, t.origin.subdir,
        reason, $config.generatedAt)
      let job = Job(family: efHistory, subject: t.name & " " & reason.strip(),
        package: t.name, url: t.origin.url, subdir: t.origin.subdir,
        vcs: t.origin.vcs)
      historyWave.add run.fetchAction(job, key, cacheable = false)
      run.historyPath[k] = run.edgePath(efHistory, key)
    run.runWave(historyWave, all)
    for k, abbrs in abbrRequests:
      for a in abbrs:
        let xk = expansionKey(run.targets[k].name, a)
        if xk in run.expansions: continue
        var x = Expansion(kind: exUnavailable)
        if k in run.historyPath:
          let h = decodeHistory(readFile(run.historyPath[k]))
          if h.state == anOk:
            var matches: seq[string]
            for c in h.allCommits:
              if c.startsWith(a): matches.add c
            x = case matches.len
              of 0: Expansion(kind: exNone)
              of 1: Expansion(kind: exFull, full: matches[0])
              else: Expansion(kind: exAmbiguous, candidates: matches)
            if x.kind == exFull:
              commitRequests.mgetOrPut(k, initHashSet[string]()).incl x.full
        run.expansions[xk] = x

    # Sightings and their sources.
    var sourceWave: seq[BuildAction]
    for k in keysSorted:
      let t = run.targets[k]
      if not t.listed or k notin run.refsPath: continue
      let refs = decodeRefs(readFile(run.refsPath[k]))
      var requested: seq[string]
      for c in commitRequests.getOrDefault(k): requested.add c
      requested.sort()
      let sightings = sightingsOf(t.name, refs, k in trackKeys,
        t.pinnedCommit, requested)
      run.sightings[k] = sightings
      var recorded = initHashSet[string]()
      if k in run.previousEnvelopes:
        for r in run.previousEnvelopes[k].versions:
          recorded.incl sightingKey(r.version, r.commit)
      let ok = originKey(t.origin.url, t.origin.subdir)
      for s in sightings:
        if sightingKey(s.version, s.commit) in recorded: continue
        let sk = ok & "@" & s.commit
        if sk in run.sourcePath: continue
        changed = true
        var key = keyOf("source", t.origin.url, t.origin.subdir, s.commit,
          run.gitDigest, limitsKey)
        # A source that failed or was refused is not a fact about the
        # commit, so its answer is not reused from the cache: the edge runs
        # again at this generation, as a host without that cache would.
        if not answeredBefore(run.edgePath(efSource, key)):
          key = keyOf("source", t.origin.url, t.origin.subdir, s.commit,
            run.gitDigest, limitsKey, "retry", $config.generatedAt)
        let job = Job(family: efSource, subject: t.name & "@" & s.commit,
          package: t.name, url: t.origin.url, subdir: t.origin.subdir,
          commit: s.commit, vcs: t.origin.vcs)
        sourceWave.add run.fetchAction(job, key, cacheable = true,
          extraOutputs = @[".nimble", ".tar"])
        run.sourcePath[sk] = run.edgePath(efSource, key)
    run.runWave(sourceWave, all)

    # Reads.
    var readWave: seq[BuildAction]
    var sourceKeys: seq[string]
    for sk in run.sourcePath.keys: sourceKeys.add sk
    sourceKeys.sort()
    for sk in sourceKeys:
      let path = run.sourcePath[sk]
      let src = decodeSource(readFile(path))
      if src.state != anOk or src.facts.nimble != nlFound: continue
      let nb = readFile(path & ".nimble")
      let h = hex(nb)
      if h in run.readPath: continue
      changed = true
      let key = keyOf("read", h, ReaderIdentity)
      let job = Job(family: efRead, subject: src.facts.nimblePath)
      readWave.add run.pureAction(job, key, @[path & ".nimble"],
        "read\0" & h & "\0" & ReaderIdentity)
      run.readPath[h] = run.edgePath(efRead, key)
    run.runWave(readWave, all)

    # What the reads require: the closure under roots, unlisted sources,
    # commits to expand and to index.
    var readKeys: seq[string]
    for h in run.readPath.keys: readKeys.add h
    readKeys.sort()
    for h in readKeys:
      if h in scannedReads: continue
      scannedReads.incl h
      let rec = decodeReadRecord(toBytes(readFile(run.readPath[h])))
      var entries = rec.requires
      for f in rec.features:
        if not f.rootOnly: entries.add f.requires
      for e in entries:
        case e.targetKind
        of rtPackage:
          let n = resolve(e.target)
          if n.len == 0:
            continue
          let tk = nameKey(n)
          if ss.roots.len > 0 and tk notin inClosure:
            frontier.add n
          if e.versionKind == rvCommit:
            if e.constraint.len in [40, 64]:
              if e.constraint notin commitRequests.getOrDefault(tk):
                commitRequests.mgetOrPut(tk, initHashSet[string]()).incl(
                  e.constraint)
                changed = true
            elif e.constraint notin abbrRequests.getOrDefault(tk):
              abbrRequests.mgetOrPut(tk, initHashSet[string]()).incl(
                e.constraint)
              changed = true
        of rtUrl:
          if ss.policy.unlisted == upAllow:
            let n = unlistedName(e.target, e.subdir)
            let tk = nameKey(n)
            if tk notin run.targets:
              run.targets[tk] = Target(name: n, listed: true, unlisted: true,
                origin: PackageOrigin(url: e.target, subdir: e.subdir,
                  vcs: ovGit))
              frontier.add n
          else:
            result.diagnostics.add "unlisted source " & e.target.escape() &
              " (a URL requirement) is not indexed: the source set says " &
              "unlisted = \"refuse\""
    if not changed and frontier.len == 0:
      break

  # ---- the publisher: shards and the root -------------------------------
  var indexed = initHashSet[string]()
  var buckets = initTable[uint32, seq[string]]()
  var names: seq[string]
  for k in inClosure: names.add k
  for k in run.previousEnvelopes.keys:
    if k notin inClosure: names.add k
  for k in run.previousObservations.keys:
    if k notin inClosure and k notin run.previousEnvelopes: names.add k
  names.sort()
  let p = run.params()
  var timeSensitive = initHashSet[uint32]()
  for k in names:
    var display = ""
    if k in inClosure:
      let o = assemblePackage(run.packageInput(run.targets[k]), p)
      if o.envelope.isSome: indexed.incl k
      # A shard depends on the generation time only through what this
      # generation adds: new records (their `first_seen`), events (their
      # time) and held versions (whose admission is a comparison with it).
      # A shard with none of those is the same at any time, so its cache
      # key leaves the time out and an unchanged shard is a cache hit.
      var sensitive = o.events.len > 0 or o.observation.held.len > 0
      if o.envelope.isSome:
        for v in o.envelope.get.versions:
          if v.firstSeen == config.generatedAt: sensitive = true
      if sensitive:
        timeSensitive.incl shardBucket(k, run.shardBits)
      result.events.add o.events
      result.diagnostics.add o.diagnostics
      display = run.targets[k].name
    else:
      run.carried.incl k
      if k in run.previousEnvelopes:
        indexed.incl k
        display = run.previousEnvelopes[k].name
      else:
        display = run.previousObservations[k].name
    buckets.mgetOrPut(shardBucket(k, run.shardBits), @[]).add display
  var bucketAliases = initTable[uint32, seq[PackageAlias]]()
  for a in aliases:
    let tk = nameKey(a.target)
    if tk notin indexed or nameKey(a.alias) in indexed: continue
    let target = if tk in run.previousEnvelopes and tk in run.carried:
                   run.previousEnvelopes[tk].name
                 else: run.targets[tk].name
    bucketAliases.mgetOrPut(shardBucket(nameKey(a.alias), run.shardBits),
      @[]).add PackageAlias(alias: a.alias, target: target)
  for b in bucketAliases.keys:
    if b notin buckets: buckets[b] = @[]
  var bucketList: seq[uint32]
  for b in buckets.keys: bucketList.add b
  bucketList.sort()
  var shardWave: seq[BuildAction]
  var expansionsText: seq[string]
  for k, x in run.expansions:
    expansionsText.add k & "=" & $x.kind & ":" & x.full & ":" &
      x.candidates.join(",")
  expansionsText.sort()
  for b in bucketList:
    var inputs: seq[string]
    var fp = @["shard", $b, $run.shardBits,
      (if b in timeSensitive: $config.generatedAt else: "-"),
      $ss.policy.cooldownDays, expansionsText.join(";"), canonicalText(ss)]
    var members = buckets[b]
    members.sort(proc (x, y: string): int = cmp(nameKey(x), nameKey(y)))
    for n in members:
      let k = nameKey(n)
      fp.add "package " & n
      if k in run.previousEnvelopes:
        fp.add "previous " & hex(toStr(encodeShard(NimbleShard(
          shardBits: 0, bucket: 0, packages: @[run.previousEnvelopes[k]]))))
      if k in run.previousObservations:
        fp.add "observed " & hex(toStr(encodeShard(NimbleShard(
          shardBits: 0, bucket: 0,
          observations: @[run.previousObservations[k]]))))
      if k notin run.carried:
        let t = run.targets[k]
        fp.add "target " & t.origin.url & " " & t.origin.subdir & " " &
          $t.listed & " " & $t.unlisted & " " & t.pinnedCommit
        for path in [run.refsPath.getOrDefault(k), run.historyPath.getOrDefault(k)]:
          if path.len > 0:
            inputs.add path
            run.objectHashes[path] = hex(readFile(path))
            fp.add run.objectHashes[path]
        let ok = originKey(t.origin.url, t.origin.subdir)
        for s in run.sightings.getOrDefault(k):
          let sk = ok & "@" & s.commit
          fp.add "sighting " & sightingKey(s.version, s.commit)
          if sk in run.sourcePath:
            let sp = run.sourcePath[sk]
            inputs.add sp
            run.objectHashes[sp] = hex(readFile(sp))
            fp.add run.objectHashes[sp]
            let nb = readFile(sp & ".nimble")
            if nb.len > 0 and hex(nb) in run.readPath:
              let rp = run.readPath[hex(nb)]
              inputs.add rp
              run.objectHashes[rp] = hex(readFile(rp))
              fp.add run.objectHashes[rp]
    var al = bucketAliases.getOrDefault(b)
    al.sort(proc (x, y: PackageAlias): int = cmp(nameKey(x.alias),
      nameKey(y.alias)))
    for a in al: fp.add "alias " & a.alias & " " & a.target
    var uniq: seq[string]
    for i in inputs:
      if i notin uniq: uniq.add i
    let key = keyOf(fp.join("\n"))
    let job = Job(family: efShard, subject: $b, shardBucket: b,
      shardNames: members, shardAliases: al)
    shardWave.add run.pureAction(job, key, uniq, fp.join("\n"),
      extraOutputs = @[".events"])
    run.shardOutputs.add (run.edgePath(efShard, key),
      run.edgePath(efShard, key, ".events"))
  run.runWave(shardWave, all)

  var rootInputs: seq[string]
  var rootFp = @["root", $run.shardBits, $config.generatedAt, GeneratorIdentity,
    $sourceSetIdentity(ss),
    (if run.previousRoot.isSome: $run.previousRoot.get else: "-")]
  for (s, e) in run.shardOutputs:
    rootInputs.add s
    rootInputs.add e
    rootFp.add hex(readFile(s)) & " " & hex(readFile(e))
  if bucketList.len == 0:
    fail("the generation indexed nothing")
  let rootKey = keyOf(rootFp.join("\n"))
  run.runWave(@[run.pureAction(Job(family: efRoot, subject: "root"), rootKey,
    rootInputs, rootFp.join("\n"), extraOutputs = @[".names", ".events"])], all)
  let rootPath = run.edgePath(efRoot, rootKey)
  var objects: seq[(IndexObjectId, seq[byte])]
  for f in [rootPath, rootPath & ".names", rootPath & ".events"]:
    let b = toBytes(readFile(f))
    objects.add (indexObjectId(b), b)
  for (sf, _) in run.shardOutputs:
    let b = toBytes(readFile(sf))
    objects.add (indexObjectId(b), b)
  objects.sort(proc (a, b: (IndexObjectId, seq[byte])): int = cmp($a[0], $b[0]))
  let rootBytes = toBytes(readFile(rootPath))
  result.built = BuiltIndex(rootId: indexObjectId(rootBytes),
    root: decodeRoot(rootBytes), rootBytes: rootBytes, objects: objects)
  if config.outputDir.len > 0:
    run.publishSources(result.built)
    writeIndexDir(result.built, config.outputDir)
  result.executed = run.executed
  result.refusals = run.refusals
  result.actions = all
  result.events = sortedEvents(result.events)

# ---------------------------------------------------------------------------
# The on-demand extension proposal (NPC-AREQ10)
# ---------------------------------------------------------------------------

proc proposeExtension*(config: GeneratorConfig; sourceSetText: string;
                       names: seq[string]; proposalDir: string):
                         tuple[result: GenerationResult; sourceSet: string] =
  ## A name the pinned index lacks, asked for by `repro add`: the generator
  ## extends a PROPOSAL -- the closure of the named packages added as roots,
  ## generated with the current index as the previous generation -- and
  ## writes it as a candidate change to the index repository under
  ## ``proposalDir``: `nimble-sources.toml` with the new roots and the
  ## `published-index/` it generates. Nothing in ``config.outputDir`` or the
  ## index repository changes; a project uses the extension only once the
  ## change is committed and its lock pins the new revision. An index that
  ## follows the whole registry has no roots to add: a name it lacks is not
  ## in the registry, and the proposal refuses.
  if config.sourceSet.roots.len == 0:
    fail("the index follows the whole registry; " & names.join(", ") &
      " can be added only as an [[extra]] or an [[override]] of its " &
      "source set")
  var text = sourceSetText
  if not text.endsWith("\n"): text.add "\n"
  var cfg = config
  for n in names:
    var present = false
    for r in cfg.sourceSet.roots:
      if nameKey(r) == nameKey(n): present = true
    if present: continue
    text.add "\n[[root]]\npackage = " & n.escape() & "\n"
  cfg.sourceSet = parseSourceSet(text, SourceSetFileName)
  cfg.outputDir = proposalDir / "published-index"
  createDir(proposalDir)
  writeFile(proposalDir / SourceSetFileName, text)
  (generate(cfg), text)
