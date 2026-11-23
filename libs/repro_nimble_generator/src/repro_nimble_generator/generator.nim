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
## | `source <package>@<commit>` | `bakMetadataFetch` | `netFetch` | origin, subdir, commit, git identity, limits | the source facts, the `.nimble`, the canonical archive; for a tree with gitlinks also its entries and blobs |
## | `submodule <url>@<commit>` | `bakMetadataFetch` | `netFetch` | URL identity, commit, git identity, limits | one submodule commit's whole tree: entries, blobs, its own `.gitmodules` |
## | `source-compose <package>@<commit>` | `bakCatalogIndex` | `netDenied` | the hashes of the `source` output and of every `submodule` output it uses | the composed source object: facts, `.nimble`, canonical archive, the `submodules` list (or the submodule that could not be obtained) |
## | `read <blake3 of .nimble>` | `bakCatalogIndex` | `netDenied` | the `.nimble` bytes' hash, the reader version | the record as the static reader reads it |
## | `shard <bucket>` | `bakCatalogIndex` | `netDenied` | the hashes of every input object, the generation parameters | the shard and its events |
## | `root` | `bakCatalogIndex` | `netDenied` | the hashes of the shards and events, the generation parameters | the root and name map |
##
## The fetch edges are the WORKERS of the threat model: they hold no
## credential (git runs in an environment built from nothing), fetch only
## through the origin egress policy (`egress`), never follow a symbolic link,
## and hand on only content: objects named by what they hold. A gitlink is
## followed only as `submodules` says (spec § 6.1, "Submodule sources"):
## its `.gitmodules` URL, resolved and checked by the policy, at the commit
## it pins, one `submodule` wave per nesting level, and the version's source
## object is then composed from those trees by a pure edge.
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

import std/[algorithm, net, options, os, sets, strutils, tables, times]

import blake3
import nimcrypto/sha2

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
import ./fetch_work
import ./origin_git
import ./registry
import ./source_set
import ./source_tree
import ./submodules

const
  GeneratorIdentity* = "reprobuild-nimble-generator/1"
    ## The root's `generator`: the generator's own version, never the host's
    ## tools, so two operators with different git builds agree.
  ReaderIdentity = "repro_nimble_reader/3"
    ## in the `read` edge's key: the reader's version and its options.
    ## Version 2 reads the Nim-version comparisons and
    ## `defined(posix|unix|bsd)` into the closed condition set (NPC-AREQ7,
    ## A3), so a version-1 reading of a file that uses them (needs-override)
    ## is read again. Version 3 reads a `.nimble` in the old INI format as
    ## data (`admitIniFormat`), as Nimble reads it with `parsecfg` before
    ## trying NimScript, so a version-2 reading of one (needs-probe) is read
    ## again
  GeneratorReaderOptions* = ReaderOptions(admitIniFormat: true)
    ## The static reader's options for the `read` edge (NPC-AREQ8 step 1)
  SourceEdgeVersion = "source/2"
    ## in the `source` edge's key: version 2 also outputs a gitlinked tree's
    ## entries and blobs, which a version-1 output on this host lacks
  SubmoduleEdgeVersion = "submodule/1"
  ComposerIdentity = "source-compose/1"
  MaxGenerationIterations = 64
  DefaultFetchParallelism* = 16
    ## fetch edges a generation runs at once when its configuration does not
    ## say: each is one git process mostly waiting on the network

type
  EdgeFamily* = enum
    efRegistry = "registry"
    efRefs = "refs"
    efHistory = "refs-history"
    efSource = "source"
    efSubmodule = "submodule"
    efCompose = "source-compose"
    efRead = "read"
    efShard = "shard"
    efRoot = "root"

  NetworkObserver* = proc(family: EdgeFamily; url: string) {.gcsafe.}
    ## Called with every URL a fetch edge hands to the transport, before the
    ## egress policy runs on it. Tests use it to show what was attempted.

  WorkerOutputTap* = proc(family: EdgeFamily; subject, outPath: string)
    {.gcsafe.}
    ## Called with every fetch edge's output file after its wave, before the
    ## publisher admits it. Tests use it to hand the publisher what a
    ## compromised worker would write; a generation never sets it.

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
    fetchParallelism*: int
      ## the most fetch edges (`refs`, `refs history`, `source`,
      ## `submodule`) run at once, each on a worker thread of the engine's
      ## concurrent dispatch; 1 runs them one at a time, 0 is
      ## ``DefaultFetchParallelism``. Not part of any output: the edges'
      ## outputs and their order of capture are the same at any value
    workerOutputTap*: WorkerOutputTap
    publishHold*: string
      ## a hold file the independent regeneration writes (``regeneration``):
      ## while it names the root this generation builds on, the generation
      ## is not published. "" checks none

  Execution* = object
    family*: EdgeFamily
    subject*: string

  CapturedRefusal* = object
    package*: string
    family*: EdgeFamily
    refusal*: EgressRefusal

  WorkerOutputRefusal* = object
    ## A fetch edge's output the publisher refused (threat model G36,
    ## FLOW-2): an unknown header or record, a field over its limit or of the
    ## wrong shape, a truncated object, or bytes that are not what the
    ## object says. The publisher used none of it: the edge's answer is a
    ## failure naming the refusal.
    package*: string
    family*: EdgeFamily
    subject*: string
    output*: string   ## BLAKE3 (hex) of the refused bytes
    reason*: string

  OutsideLink* = object
    ## A symbolic link of a fetched tree that points outside it (threat
    ## model G4): stored as a link, never followed, and the version is
    ## `unreadable`. Kept for capture.
    package*: string
    commit*: string
    tree*: string    ## the source object's digest
    origin*: string  ## the URL the bytes came from
    path*: string
    target*: string

  WaveTiming* = object
    ## How long one wave of the generation took (wall time), for the
    ## operator; never part of an output.
    family*: EdgeFamily
    edges*: int     ## the wave's edges, cache hits included
    seconds*: float

  SkippedEntry* = object
    ## A registry entry the generation did not index, and why (NPC-AREQ3:
    ## a name `nimble:<name>` cannot spell, a style-insensitive collision,
    ## an entry without a URL, ...).
    registry*: string ## the registry's remote
    entry*: string    ## the entry's name, or its index when it has none
    reason*: string

  GenerationResult* = object
    built*: BuiltIndex
    skipped*: seq[SkippedEntry]
      ## the registry entries not indexed, in registry order
    executed*: seq[Execution]
      ## every edge whose executor ran this generation (a cache hit is not in
      ## it), in execution order
    refusals*: seq[CapturedRefusal]
    workerRefusals*: seq[WorkerOutputRefusal]
      ## the worker outputs the publisher refused, in admission order
    outsideLinks*: seq[OutsideLink]
      ## every link out of its tree in the sources this generation read,
      ## by origin and commit
    diagnostics*: seq[string]
    events*: seq[OriginEvent]
    actions*: seq[BuildAction] ## every edge of the generation
    waves*: seq[WaveTiming]    ## every wave, in order

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
    rawPath: string
      ## a composition's `source` output
    subInputs: seq[(string, string)]
      ## a composition's `submodule` outputs: `<identity>@<commit>` -> path

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
    sourcePath: Table[string, string]
      ## origin key & commit -> the version's source object: the `source`
      ## output, or for a tree with gitlinks the `source-compose` output
    rawSourcePath: Table[string, string]
      ## origin key & commit -> the `source` output a composition read
    sourceJobs: Table[string, Job]      ## origin key & commit -> its job
    subPath: Table[string, string]
      ## `<URL identity>@<commit>` -> the `submodule` output
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
    prepareFailures: Table[string, string]
      ## action id -> why its fetch edge could not be planned
    admitted: Table[string, string]
      ## worker output file -> the failed answer the publisher reads in its
      ## place, for an output it refused (``admitWorkerOutput``)
    workerRefusals: seq[WorkerOutputRefusal]
    preparedRefusals: Table[string, CapturedRefusal]
      ## output path -> the refusal a fetch edge met while it was prepared
      ## for a worker, captured when the edge is settled
    waves: seq[WaveTiming]

proc hex(s: string): string = toHexLower(blake3.digest(s))

const PublishHoldHeader* = "reprobuild.nimble-publish-hold.v1"

proc heldRoot*(path: string): string =
  ## The root a publish-hold file names (`regeneration.holdPublish`), "*"
  ## for one that cannot be read (it holds every root), or "" when there is
  ## no hold.
  if path.len == 0 or not fileExists(path): return ""
  let lines = readFile(path).splitLines()
  if lines.len < 2 or lines[0] != PublishHoldHeader or
      not lines[1].startsWith("root "):
    return "*"
  lines[1][5 .. ^1]

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

proc fetchKindOf(family: EdgeFamily): FetchKind =
  case family
  of efRefs: fkRefs
  of efHistory: fkHistory
  of efSource: fkSource
  of efSubmodule: fkSubmodule
  else: raise newException(GeneratorError, $family & " is not a fetch edge")

const ConcurrentFamilies = {efRefs, efHistory, efSource, efSubmodule}
  ## the fetch edges the engine may run on worker threads: each vets one
  ## origin and runs one git operation against it (``fetch_work``)

proc planFetch(run: Run; job: Job; outPath: string; concurrent: bool;
               observe = true): Option[FetchPlan] =
  ## The scheduler's half of a fetch edge. Inline (``concurrent`` false) the
  ## egress policy vets the origin here. For a worker, the policy's resolver
  ## and dialer -- closures, which stay on this thread -- answer for the
  ## origin's own host, and the worker vets the origin from those answers
  ## (``fetch_work``). A refusal met here has its answer written, and there
  ## is nothing left to run. Inline it is captured at once; for a worker it
  ## is held until ``finishEdge`` settles the edge, so the captured
  ## refusals come in the order the edges are settled, which is the order
  ## an inline run executes them in, whichever thread met each one.
  let kind = fetchKindOf(job.family)
  var plan = FetchPlan(kind: kind, url: job.url, subdir: job.subdir,
    commit: job.commit, git: run.git, limits: run.cfg.policy.limits,
    scratch: run.cfg.stateDir / "scratch" / hex(job.subject),
    outPath: outPath)
  try:
    if not concurrent:
      plan.vetted = (if observe: run.vet(job)
                     else: vetOrigin(run.cfg.policy, job.url))
      plan.prevetted = true
      return some(plan)
    if observe and run.cfg.observer != nil:
      {.cast(gcsafe).}: run.cfg.observer(job.family, job.url)
    if job.vcs == ovHg:
      refuse(erScheme, job.url, "Mercurial origins are not fetched by this " &
        "generator")
    let u = parseOriginUrl(job.url)
    let policy = run.cfg.policy
    plan.systemResolver = policy.resolver == nil
    plan.identityDialer = policy.dialer == nil
    var addrs: seq[IpAddress]
    if isIpAddress(u.host): addrs = @[parseIpAddress(u.host)]
    elif policy.resolver != nil:
      addrs = policy.resolver(u.host)
      plan.hosts.add (u.host, addrs)
    if policy.dialer != nil:
      for a in addrs: plan.dials.add (a, policy.dialer(a))
    some(plan)
  except EgressError as e:
    if concurrent:
      run.preparedRefusals[outPath] = CapturedRefusal(package: job.package,
        family: job.family, refusal: e.refusal)
    else:
      run.capture(job, e)
    writeRefused(kind, job.url, job.commit, outPath, e.refusal)
    none(FetchPlan)

proc settleFetch(run: Run; job: Job; r: FetchWorkResult) =
  ## The scheduler's half after the work: a refusal the transfer met (a
  ## limit) goes to the capture log.
  if r.refused:
    run.refusals.add CapturedRefusal(package: job.package, family: job.family,
      refusal: r.refusal)

proc execFetch(run: Run; job: Job; outPath: string; observe = true) =
  ## A fetch edge run inline: the origin vetted here, then the same work as
  ## on a worker thread.
  let plan = run.planFetch(job, outPath, concurrent = false, observe)
  if plan.isSome:
    run.settleFetch(job, runFetchPlan(plan.get))

# ---------------------------------------------------------------------------
# The pure executors (publisher)
# ---------------------------------------------------------------------------

const ReadPlaceholderCommit = "0000000000000000000000000000000000000000"

proc readRecordBytes*(nimbleBytes, fileName: string): seq[byte] =
  ## The `read` edge: the record the static reader reads from a `.nimble`,
  ## encoded with the index codec as the one record of a placeholder shard
  ## (its version, commit and digests are the publisher's to fill).
  let f = readNimbleSource(nimbleBytes, fileName, GeneratorReaderOptions)
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

proc workerText(run: Run; path: string): string =
  ## A fetch edge's output as the publisher admitted it: the file, or for
  ## an output it refused the failed answer it reads in its place.
  if path in run.admitted: run.admitted[path] else: readFile(path)

proc readObject(run: Run; path: string): string =
  ## A worker's output, read by the publisher: refused unless it is the
  ## object the shard's cache key names (threat model § 3.2: the publisher
  ## consumes content-addressed outputs).
  result = run.workerText(path)
  if path in run.objectHashes and hex(result) != run.objectHashes[path]:
    raise newException(EdgeObjectError, path & " is not the object the " &
      "shard edge was keyed on")

proc submoduleLookupOf(run: Run; paths: Table[string, string]):
    SubmoduleLookupProc =
  ## A lookup over `submodule` outputs: ``paths`` maps
  ## `<identity>@<commit>` to the output; one it lacks, or not yet written,
  ## is pending.
  result = proc(url, identity, commit: string): SubmoduleLookup =
    let k = identity & "@" & commit
    if k notin paths or not fileExists(paths[k]):
      return SubmoduleLookup(state: slPending)
    let a = decodeSubmodule(run.readObject(paths[k]))
    if a.state != anOk:
      return SubmoduleLookup(state: slFailed,
        failure: (if a.failure.len > 0: failureOf(a.failure) else: sfNoAnswer),
        refusal: a.refusal, detail: a.detail)
    var t = FetchedTree(entries: a.entries)
    decodeBlobs(run.readObject(paths[k] & ".blobs"), t)
    SubmoduleLookup(state: slReady, tree: t)

proc rootTreeOf(run: Run; rawPath: string): tuple[src: SourceAnswer;
                                                  tree: FetchedTree] =
  ## A `source` output with gitlinks, as the tree it read.
  result.src = decodeSource(run.readObject(rawPath))
  result.tree = FetchedTree(commitTime: result.src.facts.commitTime,
    entries: result.src.entries)
  decodeBlobs(run.readObject(rawPath & ".blobs"), result.tree)

proc execCompose(run: Run; job: Job; outPath: string) =
  ## The `source-compose` edge (pure): the version's source object as ONE
  ## tree of the superproject's and its submodules' entries (`submodules`),
  ## its digest, `.nimble` and canonical archive; or the submodule that
  ## could not be obtained.
  let (raw, root) = run.rootTreeOf(job.rawPath)
  var paths = initTable[string, string]()
  for (k, p) in job.subInputs: paths[k] = p
  let c = composeSource(root, job.subdir, job.url, job.commit,
    run.submoduleLookupOf(paths))
  var answer = SourceAnswer(commit: job.commit)
  var archive = ""
  var nimbleBytes = ""
  case c.state
  of coComposed:
    let (facts, arch, nb) = sourceFacts(c.tree)
    answer.state = anOk
    answer.facts = facts
    answer.facts.gitlinks = raw.facts.gitlinks
    answer.facts.submodules = c.verdicts
    answer.pins = c.pins
    archive = arch
    nimbleBytes = nb
  of coFailed:
    answer.state = (if c.failure.failure == sfEgress: anRefused else: anFailed)
    answer.refusal = c.failure.refusal
    answer.detail = eventPhrase(c.failure) &
      (if c.failure.detail.len > 0: ": " & c.failure.detail else: "")
    answer.unobtainable = @[c.failure]
    answer.facts.submodules = c.verdicts
  of coPending:
    fail("composition of " & job.subject & " needs submodule trees its " &
      "edge was not given")
  writeFile(outPath, encodeSource(answer))
  writeFile(outPath & ".nimble", nimbleBytes)
  writeFile(outPath & ".tar", archive)
  writeFile(outPath & ".blobs", "")

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

proc skippedReport*(r: GenerationResult): seq[string] =
  ## One line per registry entry the generation did not index, naming it and
  ## the reason: what `repro catalog generate` prints.
  for s in r.skipped:
    result.add "skipped: registry entry " & s.entry.escape() & " of " &
      s.registry & ": " & s.reason

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
    of efRefs, efHistory, efSource, efSubmodule: run.execFetch(job, outPath)
    of efCompose: run.execCompose(job, outPath)
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

proc prepareEdge(run: Run; action: BuildAction): BuiltinWorkItem =
  ## The scheduler's half of a fetch edge under concurrent dispatch: vet the
  ## origin and hand the rest to a worker as a ``FetchPlan``'s text. Any
  ## other edge (the registry) is left whole to ``finishEdge``.
  if action.id notin run.jobs:
    return
  let job = run.jobs[action.id]
  if job.family notin ConcurrentFamilies:
    return
  let outPath = action.outputs[0]
  try:
    createDir(parentDir(outPath))
    run.executed.add Execution(family: job.family, subject: job.subject)
    let plan = run.planFetch(job, outPath, concurrent = true)
    if plan.isSome:
      result = BuiltinWorkItem(work: fetchWork, input: encodePlan(plan.get))
  except CatchableError as e:
    run.prepareFailures[action.id] = $job.family & " " & job.subject & ": " &
      e.msg

proc finishEdge(run: Run; action: BuildAction; dispatched: bool;
                outcome: BuiltinWorkOutcome): ActionResult =
  ## The scheduler's half after a worker ran the plan, or the whole edge
  ## when ``prepareEdge`` left it (``dispatched`` false and no plan).
  result = ActionResult(id: action.id, status: asSucceeded, exitCode: 0,
    launched: true)
  let job = run.jobs.getOrDefault(action.id)
  if action.id notin run.jobs or job.family notin ConcurrentFamilies:
    return run.execute(action)
  if action.id in run.prepareFailures:
    result.status = asFailed
    result.exitCode = 1
    result.stderr = run.prepareFailures[action.id]
    return
  if not dispatched:
    # Refused by the egress policy while it was prepared: answered then,
    # captured now.
    var held: CapturedRefusal
    if run.preparedRefusals.pop(action.outputs[0], held):
      run.refusals.add held
    return
  if not outcome.ok:
    result.status = asFailed
    result.exitCode = 1
    result.stderr = $job.family & " " & job.subject & ": " & outcome.error
    return
  try:
    let r = decodeResult(outcome.output)
    if r.needsScheduler:
      # The vetting met a host only the policy's own resolver or dialer can
      # answer (a redirect under a test policy): it resumes here, on this
      # thread, from where the worker stopped, and the edge's git work runs
      # inline. No discovery request is repeated.
      let outPath = action.outputs[0]
      var plan = FetchPlan(kind: fetchKindOf(job.family), url: job.url,
        subdir: job.subdir, commit: job.commit, git: run.git,
        limits: run.cfg.policy.limits, prevetted: true,
        scratch: run.cfg.stateDir / "scratch" / hex(job.subject),
        outPath: outPath)
      var progress = r.resume
      try:
        plan.vetted = vetOriginFrom(run.cfg.policy, job.url, progress)
      except EgressError as e:
        run.capture(job, e)
        writeRefused(plan.kind, job.url, job.commit, outPath, e.refusal)
        return
      run.settleFetch(job, runFetchPlan(plan))
    else:
      run.settleFetch(job, r)
  except CatchableError as e:
    result.status = asFailed
    result.exitCode = 1
    result.stderr = $job.family & " " & job.subject & ": " & e.msg

const MaxRefusalReasonBytes = 1024

proc admitWorkerOutput(run: Run; action: BuildAction) =
  ## The publisher's admission of one fetch edge's output (threat model
  ## G36, FLOW-2): the object is decoded against its kind's closed
  ## vocabulary and field limits (``edge_objects``), a source or submodule
  ## object must answer for the commit it was asked about, and a `source`
  ## edge that ran this generation must have written the archive its
  ## object describes. An output that fails any of it is refused: the
  ## refusal is kept for capture, and the publisher reads a failed answer
  ## in its place, so nothing of it reaches a shard.
  if action.id notin run.jobs: return
  let job = run.jobs[action.id]
  if job.family notin ConcurrentFamilies: return
  let outPath = action.outputs[0]
  if not fileExists(outPath): return
  if run.cfg.workerOutputTap != nil:
    {.cast(gcsafe).}: run.cfg.workerOutputTap(job.family, job.subject, outPath)
  let text = readFile(outPath)
  var reason = ""
  try:
    case job.family
    of efRefs: discard decodeRefs(text)
    of efHistory: discard decodeHistory(text)
    of efSource:
      let a = decodeSource(text)
      if a.commit != job.commit:
        reason = "the object answers for commit " & a.commit.escape() &
          ", not " & job.commit
      var t = FetchedTree()
      if fileExists(outPath & ".blobs"):
        decodeBlobs(readFile(outPath & ".blobs"), t)
      var ran = false
      for e in run.executed:
        if e.family == efSource and e.subject == job.subject: ran = true
      if reason.len == 0 and a.state == anOk and ran:
        let archive = readFile(outPath & ".tar")
        if int64(archive.len) != a.facts.archiveSize or
            toLowerAscii($sha256.digest(archive)) != a.facts.archiveSha256:
          reason = "the archive is not the one the object describes"
    of efSubmodule:
      let a = decodeSubmodule(text)
      if a.commit != job.commit:
        reason = "the object answers for commit " & a.commit.escape() &
          ", not " & job.commit
      var t = FetchedTree()
      if fileExists(outPath & ".blobs"):
        decodeBlobs(readFile(outPath & ".blobs"), t)
    else: discard
  except EdgeObjectError, ValueError, IOError:
    reason = getCurrentExceptionMsg()
  if reason.len == 0: return
  if reason.len > MaxRefusalReasonBytes:
    reason = reason[0 ..< MaxRefusalReasonBytes]
  run.workerRefusals.add WorkerOutputRefusal(package: job.package,
    family: job.family, subject: job.subject, output: hex(text),
    reason: reason)
  let detail = "the publisher refused the worker's output: " & reason
  run.admitted[outPath] =
    case job.family
    of efRefs: encodeRefs(RefsAnswer(state: anFailed, detail: detail))
    of efHistory: encodeHistory(HistoryAnswer(state: anFailed,
      detail: detail))
    of efSource: encodeSource(SourceAnswer(state: anFailed,
      commit: job.commit, detail: detail))
    else: encodeSubmodule(SubmoduleAnswer(state: anFailed, url: job.url,
      commit: job.commit, failure: $sfNoAnswer, detail: detail))

proc fetchParallelism(run: Run): int =
  if run.cfg.fetchParallelism > 0: run.cfg.fetchParallelism
  else: DefaultFetchParallelism

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
  registerConcurrentMetadataFetchExecutor(ConcurrentBuiltinExecutor(
    prepare: proc(action: BuildAction): BuiltinWorkItem {.gcsafe.} =
      {.cast(gcsafe).}: run.prepareEdge(action),
    finish: proc(action: BuildAction; dispatched: bool;
                 outcome: BuiltinWorkOutcome): ActionResult {.gcsafe.} =
      {.cast(gcsafe).}: run.finishEdge(action, dispatched, outcome)))
  registerCatalogIndexExecutor(proc(action: BuildAction): ActionResult
      {.gcsafe.} =
    {.cast(gcsafe).}: run.execute(action))
  let started = epochTime()
  try:
    var cfg = defaultBuildEngineConfig(run.cfg.stateDir / "engine-cache")
    # The fetch edges of a wave are independent and wait on the network:
    # the engine runs up to this many on worker threads. The pure edges
    # have no concurrent executor and still run one at a time.
    cfg.maxParallelism = uint32(run.fetchParallelism)
    cfg.bypassRunQuota = true
    cfg.deferLocalOutputBlobs = false
    let outcome = runBuild(g, cfg)
    for res in outcome.results:
      if res.status == asFailed:
        fail("generator edge " & res.id & " failed: " & res.stderr)
    for a in actions: run.admitWorkerOutput(a)
  finally:
    clearMetadataFetchExecutor()
    clearConcurrentMetadataFetchExecutor()
    clearCatalogIndexExecutor()
    var family = efRoot
    if actions[0].id in run.jobs: family = run.jobs[actions[0].id].family
    run.waves.add WaveTiming(family: family, edges: actions.len,
      seconds: epochTime() - started)

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

proc submoduleAnsweredBefore(output: string): bool =
  ## As ``answeredBefore``, for a `submodule` edge's output.
  if not fileExists(output): return true
  try:
    decodeSubmodule(readFile(output)).state == anOk
  except CatchableError:
    false

proc composeSources(run: Run; all: var seq[BuildAction]; limitsKey: string;
                    generatedAt: uint64) =
  ## The versions fetched this wave whose trees have gitlinks: their
  ## submodules, one `submodule` wave per nesting level (each level's URLs
  ## are known only from the level above), then one `source-compose` edge
  ## per version, whose output becomes the version's source object.
  var pending: seq[string]
  var keys: seq[string]
  for sk in run.sourcePath.keys: keys.add sk
  keys.sort()
  for sk in keys:
    if sk in run.rawSourcePath: continue
    let src = decodeSource(run.workerText(run.sourcePath[sk]))
    if src.state == anOk and src.facts.gitlinks.len > 0:
      pending.add sk
  if pending.len == 0: return
  var levels = 0
  while true:
    inc levels
    if levels > MaxSubmoduleDepth + 2:
      fail("the submodule waves did not end within " &
        $(MaxSubmoduleDepth + 2) & " levels")
    var needs = initTable[string, SubmoduleNeed]()
    var needer = initTable[string, string]()
    for sk in pending:
      let job = run.sourceJobs[sk]
      let (_, root) = run.rootTreeOf(run.sourcePath[sk])
      let c = composeSource(root, job.subdir, job.url, job.commit,
        run.submoduleLookupOf(run.subPath))
      if c.state != coPending: continue
      for n in c.needs:
        let k = n.identity & "@" & n.commit
        if k notin needs or n.url < needs[k].url:
          needs[k] = n
        if k notin needer: needer[k] = job.package
    var needKeys: seq[string]
    for k in needs.keys:
      if k notin run.subPath: needKeys.add k
    needKeys.sort()
    if needKeys.len == 0: break
    var wave: seq[BuildAction]
    for k in needKeys:
      let n = needs[k]
      var key = keyOf("submodule", n.identity, n.commit, run.gitDigest,
        limitsKey, SubmoduleEdgeVersion)
      # As for `source`: only an answer is reused from this host's cache.
      if not submoduleAnsweredBefore(run.edgePath(efSubmodule, key)):
        key = keyOf("submodule", n.identity, n.commit, run.gitDigest,
          limitsKey, SubmoduleEdgeVersion, "retry", $generatedAt)
      let job = Job(family: efSubmodule, subject: n.url & "@" & n.commit,
        package: needer[k], url: n.url, commit: n.commit, vcs: ovGit)
      wave.add run.fetchAction(job, key, cacheable = true,
        extraOutputs = @[".blobs"])
      run.subPath[k] = run.edgePath(efSubmodule, key)
    run.runWave(wave, all)
  var composeWave: seq[BuildAction]
  for sk in pending:
    let job = run.sourceJobs[sk]
    let raw = run.sourcePath[sk]
    let (_, root) = run.rootTreeOf(raw)
    let c = composeSource(root, job.subdir, job.url, job.commit,
      run.submoduleLookupOf(run.subPath))
    if c.state == coFailed and c.failure.failure == sfEgress and
        c.failure.url.len > 0:
      # A URL rule 1 refused before any edge ran: captured like an edge's.
      # (A refusal by a `submodule` edge was captured when the edge ran.)
      var kind = erScheme
      for k in EgressRefusalKind:
        if $k == c.failure.refusal: kind = k
      run.refusals.add CapturedRefusal(package: job.package,
        family: efSubmodule, refusal: EgressRefusal(kind: kind,
          url: c.failure.url, detail: c.failure.detail))
    var inputs = @[raw, raw & ".blobs"]
    var fp = @["source-compose", ComposerIdentity, job.url, job.subdir,
      job.commit]
    var subs: seq[(string, string)]
    for k in c.looked:
      if k in run.subPath:
        let p = run.subPath[k]
        inputs.add p
        inputs.add p & ".blobs"
        subs.add (k, p)
    for path in inputs:
      run.objectHashes[path] = hex(run.workerText(path))
      fp.add path.extractFilename() & " " & run.objectHashes[path]
    for (k, _) in subs: fp.add "uses " & k
    let key = keyOf(fp.join("\n"))
    var cj = job
    cj.family = efCompose
    cj.rawPath = raw
    cj.subInputs = subs
    composeWave.add run.pureAction(cj, key, inputs, fp.join("\n"),
      extraOutputs = @[".nimble", ".tar", ".blobs"])
    run.rawSourcePath[sk] = raw
    run.sourcePath[sk] = run.edgePath(efCompose, key)
  run.runWave(composeWave, all)

# ---------------------------------------------------------------------------
# The generation
# ---------------------------------------------------------------------------

proc loadPrevious(run: Run) =
  if run.cfg.previousIndex.len == 0: return
  let src = directorySource(run.cfg.previousIndex)
  let rootId = indexDirRootId(run.cfg.previousIndex)
  var idx = openIndex(src, rootId)
  run.previousRoot = some(rootId)
  var stale: seq[string]
  for r in idx.root.shards:
    let s = idx.loadShard(r.bucket)
    if s.isNone: continue
    for p in s.get.packages:
      run.previousEnvelopes[nameKey(p.name)] = p
      for v in p.versions:
        if flGitlinks in v.flags and v.submodules.len == 0:
          stale.add p.name & " " &
            (if v.version.tag.len > 0: v.version.tag else: $v.version.kind) &
            " (" & v.commit & ")"
    for o in s.get.observations: run.previousObservations[nameKey(o.name)] = o
  if stale.len > 0:
    # Spec § 6.1, "Submodule sources": such a record's tree lacks its
    # submodules, records are never edited, so the index is regenerated
    # rather than carried forward.
    fail("the previous generation " & run.cfg.previousIndex & " holds " &
      $stale.len & " `gitlinks` record(s) without a submodules list, " &
      "written by a generator before submodule sources: " &
      stale.join(", ") & ". Their trees lack the submodules, and a record " &
      "is never edited, so this generation cannot extend that index; " &
      "generate it again without a previous generation")
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
    let src = decodeSource(run.workerText(path))
    if src.state != anOk: continue
    let archive = readFile(path & ".tar")
    # Each archive is checked against the object that describes it before
    # it is stored: one a worker altered after its object was admitted (a
    # cache hit of an earlier generation is not re-admitted) is refused,
    # and nothing is published. What was stored before it is only archives
    # that are what their objects say.
    if int64(archive.len) != src.facts.archiveSize or
        toLowerAscii($sha256.digest(archive)) != src.facts.archiveSha256:
      fail("the generation is not published: the archive of " &
        $efSource & " " & k & " is not the one its object describes " &
        "(size " & $archive.len & ", the object's " &
        $src.facts.archiveSize & ")")
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
  ## The name an unlisted source is indexed under; resolution looks it up
  ## by the same function (``repro_nimble_index.unlistedSourceName``).
  unlistedSourceName(url, subdir)

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
  for ri, f in regFiles:
    let reg = parseRegistry(readFile(f))
    for (n, why) in reg.skipped:
      result.skipped.add SkippedEntry(registry: ss.registries[ri].remote,
        entry: n, reason: why)
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
        let refs = decodeRefs(run.workerText(run.refsPath[k]))
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
          let h = decodeHistory(run.workerText(run.historyPath[k]))
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
      let refs = decodeRefs(run.workerText(run.refsPath[k]))
      var requested: seq[string]
      for c in commitRequests.getOrDefault(k): requested.add c
      requested.sort()
      let tagged = k in run.previousEnvelopes and
        hasTagRecord(run.previousEnvelopes[k].versions)
      let sightings = sightingsOf(t.name, refs, k in trackKeys,
        t.pinnedCommit, requested, tagged)
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
          run.gitDigest, limitsKey, SourceEdgeVersion)
        # A source that failed or was refused is not a fact about the
        # commit, so its answer is not reused from the cache: the edge runs
        # again at this generation, as a host without that cache would.
        if not answeredBefore(run.edgePath(efSource, key)):
          key = keyOf("source", t.origin.url, t.origin.subdir, s.commit,
            run.gitDigest, limitsKey, SourceEdgeVersion, "retry",
            $config.generatedAt)
        let job = Job(family: efSource, subject: t.name & "@" & s.commit,
          package: t.name, url: t.origin.url, subdir: t.origin.subdir,
          commit: s.commit, vcs: t.origin.vcs)
        sourceWave.add run.fetchAction(job, key, cacheable = true,
          extraOutputs = @[".nimble", ".tar", ".blobs"])
        run.sourcePath[sk] = run.edgePath(efSource, key)
        run.sourceJobs[sk] = job
    run.runWave(sourceWave, all)
    # Versions with gitlinks: their submodules, then their composition.
    run.composeSources(all, limitsKey, config.generatedAt)

    # Reads.
    var readWave: seq[BuildAction]
    var sourceKeys: seq[string]
    for sk in run.sourcePath.keys: sourceKeys.add sk
    sourceKeys.sort()
    for sk in sourceKeys:
      let path = run.sourcePath[sk]
      let src = decodeSource(run.workerText(path))
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
            run.objectHashes[path] = hex(run.workerText(path))
            fp.add run.objectHashes[path]
        let ok = originKey(t.origin.url, t.origin.subdir)
        for s in run.sightings.getOrDefault(k):
          let sk = ok & "@" & s.commit
          fp.add "sighting " & sightingKey(s.version, s.commit)
          if sk in run.sourcePath:
            let sp = run.sourcePath[sk]
            inputs.add sp
            run.objectHashes[sp] = hex(run.workerText(sp))
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
    let held = heldRoot(config.publishHold)
    if held.len > 0 and (held == "*" or (run.previousRoot.isSome and
        held == $run.previousRoot.get)):
      fail("the generation is not published: the independent regeneration " &
        "holds publishing on top of root " & held & " (" &
        config.publishHold & "); an operator investigates and removes the " &
        "hold")
    run.publishSources(result.built)
    writeIndexDir(result.built, config.outputDir)
  result.executed = run.executed
  result.refusals = run.refusals
  result.workerRefusals = run.workerRefusals
  var sourceKeys: seq[string]
  for sk in run.sourcePath.keys: sourceKeys.add sk
  sourceKeys.sort()
  for sk in sourceKeys:
    if sk notin run.sourceJobs: continue
    let job = run.sourceJobs[sk]
    let src = decodeSource(run.workerText(run.sourcePath[sk]))
    if src.state != anOk: continue
    for l in src.facts.links:
      if l.verdict == lvOutside:
        result.outsideLinks.add OutsideLink(package: job.package,
          commit: job.commit, tree: src.facts.treeDigest, origin: job.url,
          path: l.path, target: l.target)
  result.actions = all
  result.waves = run.waves
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
