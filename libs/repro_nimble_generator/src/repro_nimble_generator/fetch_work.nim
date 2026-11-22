## The work of a fetch edge: vet the origin under the egress policy, run one
## `git` operation against it, and write the answer to the edge's output
## files. Plain data in, plain data out, so the engine can run it on a
## worker thread (``repro_build_engine/builtin_dispatch``).
##
## A ``FetchPlan`` is everything the work needs: the edge, the origin, how
## git runs, the limits, the scratch directory, the output path, and how to
## reach the origin -- either the origin already vetted (an edge run inline,
## on the scheduler's thread) or a resolution table. The egress policy's
## resolver and dialer are closures and never leave the scheduler's thread:
## there it answers them for the origin's own host and puts the answers in
## the table, and the worker vets the origin -- every rule, the discovery
## request and its redirects -- with a policy rebuilt from the table. A host
## the table does not answer (a redirect to another host) is resolved by the
## system resolver when the policy has none; otherwise the work stops and
## asks for the edge to be run inline (``needsScheduler``), where the
## policy's own resolver answers. The plan crosses the thread boundary as
## text (``encodePlan`` / ``decodePlan``). What comes back is an egress
## refusal for the publisher's capture log, or the request to run inline.
##
## The generator runs every fetch edge through this module, inline or on a
## worker, so the bytes an edge writes do not depend on where it ran.

import std/[net, os, strutils, tables]

import ./edge_objects
import ./egress
import ./origin_git
import ./source_tree
import ./submodules

type
  FetchKind* = enum
    fkRefs = "refs"
    fkHistory = "refs-history"
    fkSource = "source"
    fkSubmodule = "submodule"

  FetchPlan* = object
    kind*: FetchKind
    url*: string        ## the origin as the edge names it
    subdir*: string
    commit*: string
    git*: OriginGit
    limits*: EgressLimits
    prevetted*: bool
      ## ``vetted`` holds the origin as the policy vetted it (inline); else
      ## the work vets it from the resolution table
    vetted*: VettedOrigin
    hosts*: seq[(string, seq[IpAddress])]
      ## the policy resolver's answer for each host it was asked about
    dials*: seq[(IpAddress, IpAddress)]
      ## the policy dialer's answer for each address it was asked about
    systemResolver*: bool ## the policy has no resolver of its own
    identityDialer*: bool ## the policy has no dialer of its own
    scratch*: string    ## private, created and removed by the work
    outPath*: string

  FetchWorkResult* = object
    refused*: bool
    refusal*: EgressRefusal
    needsScheduler*: bool
      ## the vetting met a host the table does not answer, under a policy
      ## whose resolver or dialer only the scheduler's thread can call:
      ## nothing was written; vetting resumes on that thread from
      ## ``resume`` (no discovery request is repeated)
    resume*: VetProgress

  NeedsSchedulerError = object of CatchableError

# ---------------------------------------------------------------------------
# Text form (length-prefixed fields)
# ---------------------------------------------------------------------------

proc put(s: var string; x: string) =
  s.add $x.len
  s.add ':'
  s.add x

proc put(s: var string; x: int64) = s.put($x)

proc take(s: string; pos: var int): string =
  let colon = s.find(':', pos)
  if colon < 0:
    raise newException(ValueError, "fetch plan: truncated")
  let n = parseInt(s[pos ..< colon])
  if n < 0 or colon + 1 + n > s.len:
    raise newException(ValueError, "fetch plan: bad field length")
  result = s[colon + 1 ..< colon + 1 + n]
  pos = colon + 1 + n

proc takeInt(s: string; pos: var int): int64 = parseBiggestInt(take(s, pos))

proc putList(s: var string; xs: seq[string]) =
  s.put(int64(xs.len))
  for x in xs: s.put(x)

proc takeList(s: string; pos: var int): seq[string] =
  let n = takeInt(s, pos)
  for _ in 0 ..< n: result.add take(s, pos)

proc encodePlan*(p: FetchPlan): string =
  result.put($p.kind)
  result.put(p.url)
  result.put(p.subdir)
  result.put(p.commit)
  result.put(p.git.gitBin)
  result.put(p.git.caFile)
  result.put(p.limits.maxBytes)
  result.put(int64(p.limits.stallSeconds))
  result.put(int64(p.limits.wallSeconds))
  result.put(int64(p.limits.maxRedirects))
  result.put(int64(p.limits.connectTimeoutMs))
  result.put(int64(ord(p.prevetted)))
  result.put(int64(ord(p.systemResolver)))
  result.put(int64(ord(p.identityDialer)))
  result.put(int64(p.hosts.len))
  for (h, addrs) in p.hosts:
    result.put(h)
    var a: seq[string]
    for x in addrs: a.add $x
    result.putList(a)
  result.put(int64(p.dials.len))
  for (a, b) in p.dials:
    result.put($a)
    result.put($b)
  let v = p.vetted
  result.put(v.requested)
  result.put(v.final.url)
  result.put(v.final.host)
  result.put(int64(v.final.port))
  result.put(v.final.path)
  result.put(int64(ord(v.final.explicitPort)))
  var a, c: seq[string]
  for x in v.addresses: a.add $x
  for x in v.connectTo: c.add $x
  result.putList(a)
  result.putList(c)
  result.putList(v.redirects)
  result.put(p.scratch)
  result.put(p.outPath)

proc decodePlan*(s: string): FetchPlan =
  var i = 0
  result.kind = parseEnum[FetchKind](take(s, i))
  result.url = take(s, i)
  result.subdir = take(s, i)
  result.commit = take(s, i)
  result.git.gitBin = take(s, i)
  result.git.caFile = take(s, i)
  result.limits.maxBytes = takeInt(s, i)
  result.limits.stallSeconds = int(takeInt(s, i))
  result.limits.wallSeconds = int(takeInt(s, i))
  result.limits.maxRedirects = int(takeInt(s, i))
  result.limits.connectTimeoutMs = int(takeInt(s, i))
  result.prevetted = takeInt(s, i) != 0
  result.systemResolver = takeInt(s, i) != 0
  result.identityDialer = takeInt(s, i) != 0
  for _ in 0 ..< takeInt(s, i):
    let h = take(s, i)
    var addrs: seq[IpAddress]
    for x in takeList(s, i): addrs.add parseIpAddress(x)
    result.hosts.add (h, addrs)
  for _ in 0 ..< takeInt(s, i):
    let a = parseIpAddress(take(s, i))
    let b = parseIpAddress(take(s, i))
    result.dials.add (a, b)
  result.vetted.requested = take(s, i)
  result.vetted.final.url = take(s, i)
  result.vetted.final.host = take(s, i)
  result.vetted.final.port = int(takeInt(s, i))
  result.vetted.final.path = take(s, i)
  result.vetted.final.explicitPort = takeInt(s, i) != 0
  for x in takeList(s, i): result.vetted.addresses.add parseIpAddress(x)
  for x in takeList(s, i): result.vetted.connectTo.add parseIpAddress(x)
  result.vetted.redirects = takeList(s, i)
  result.scratch = take(s, i)
  result.outPath = take(s, i)
  if i != s.len:
    raise newException(ValueError, "fetch plan: trailing bytes")

proc encodeResult*(r: FetchWorkResult): string =
  if r.needsScheduler:
    result = "needs-scheduler:"
    result.put(r.resume.current)
    result.put(int64(r.resume.hops))
    result.putList(r.resume.redirects)
    return
  if not r.refused: return ""
  result.put($r.refusal.kind)
  result.put(r.refusal.url)
  result.put(r.refusal.detail)
  result.put(r.refusal.address)
  result.put($r.refusal.addressClass)

proc decodeResult*(s: string): FetchWorkResult =
  if s.len == 0: return
  if s.startsWith("needs-scheduler:"):
    var j = "needs-scheduler:".len
    result.needsScheduler = true
    result.resume.current = take(s, j)
    result.resume.hops = int(takeInt(s, j))
    result.resume.redirects = takeList(s, j)
    return
  var i = 0
  result.refused = true
  result.refusal.kind = parseEnum[EgressRefusalKind](take(s, i))
  result.refusal.url = take(s, i)
  result.refusal.detail = take(s, i)
  result.refusal.address = take(s, i)
  result.refusal.addressClass = parseEnum[AddressClass](take(s, i))

# ---------------------------------------------------------------------------
# Answers
# ---------------------------------------------------------------------------

proc writeRefused*(kind: FetchKind; url, commit, outPath: string;
                   refusal: EgressRefusal) =
  ## The edge's output when the egress policy refused it: before any
  ## contact (the vetting) or during the transfer (a limit).
  case kind
  of fkRefs:
    writeFile(outPath, encodeRefs(RefsAnswer(state: anRefused,
      refusal: $refusal.kind, detail: refusal.detail)))
  of fkHistory:
    writeFile(outPath, encodeHistory(HistoryAnswer(state: anRefused,
      refusal: $refusal.kind, detail: refusal.detail)))
  of fkSource:
    writeFile(outPath, encodeSource(SourceAnswer(commit: commit,
      state: anRefused, refusal: $refusal.kind, detail: refusal.detail)))
    writeFile(outPath & ".nimble", "")
    writeFile(outPath & ".tar", "")
    writeFile(outPath & ".blobs", "")
  of fkSubmodule:
    writeFile(outPath, encodeSubmodule(SubmoduleAnswer(url: url,
      commit: commit, state: anRefused, refusal: $refusal.kind,
      detail: refusal.detail, failure: $sfEgress)))
    writeFile(outPath & ".blobs", "")

proc runRefs(p: FetchPlan) {.gcsafe.} =
  let (ok, ls, failure) = lsRemote(p.git, p.vetted, p.scratch, p.limits)
  let answer =
    if ok: RefsAnswer(state: anOk, headRef: ls.headRef, head: ls.head,
                      tags: ls.tags)
    else: RefsAnswer(state: anFailed, detail: failure)
  writeFile(p.outPath, encodeRefs(answer))

proc runHistory(p: FetchPlan) {.gcsafe.} =
  let h = fetchHistory(p.git, p.vetted, p.scratch, p.limits)
  let answer =
    if h.ok: HistoryAnswer(state: anOk, branchCommits: h.branchCommits,
                           allCommits: h.allCommits)
    else: HistoryAnswer(state: anFailed, detail: h.failure)
  writeFile(p.outPath, encodeHistory(answer))

proc runSource(p: FetchPlan) {.gcsafe.} =
  var answer = SourceAnswer(commit: p.commit)
  var nimbleBytes = ""
  var archive = ""
  var blobs = ""
  try:
    let (ok, repo, failure) = fetchCommit(p.git, p.vetted, p.scratch,
      p.commit, p.limits)
    if not ok:
      answer.state = anFailed
      answer.detail = failure
    else:
      let tree = readTree(p.git, repo, p.commit, p.subdir, p.limits)
      let (facts, arch, nb) = sourceFacts(tree)
      answer.state = anOk
      answer.facts = facts
      archive = arch
      nimbleBytes = nb
      if tree.hasGitlinks:
        # The source object is composed from this tree and its submodules'
        # (`source-compose`), so the tree itself is handed on.
        answer.entries = tree.entries
        answer.hasGitmodules = tree.hasGitmodules
        blobs = encodeBlobs(tree.blobs, tree.gitmodules, tree.hasGitmodules)
  except IOError as e:
    answer.state = anFailed
    answer.detail = e.msg
  writeFile(p.outPath, encodeSource(answer))
  writeFile(p.outPath & ".nimble", nimbleBytes)
  writeFile(p.outPath & ".tar", archive)
  writeFile(p.outPath & ".blobs", blobs)

proc runSubmodule(p: FetchPlan) {.gcsafe.} =
  ## Exactly that commit, depth 1, into private scratch; the whole tree read
  ## from objects.
  var answer = SubmoduleAnswer(url: p.url, commit: p.commit)
  var blobs = ""
  try:
    let (ok, repo, failure) = fetchCommit(p.git, p.vetted, p.scratch,
      p.commit, p.limits)
    if not ok:
      answer.state = anFailed
      answer.detail = failure
      answer.failure = $fetchFailureOf(failure)
    else:
      let tree = readTree(p.git, repo, p.commit, "", p.limits)
      answer.state = anOk
      answer.entries = tree.entries
      answer.hasGitmodules = tree.hasGitmodules
      blobs = encodeBlobs(tree.blobs, tree.gitmodules, tree.hasGitmodules)
  except IOError as e:
    answer.state = anFailed
    answer.detail = e.msg
    answer.failure = $sfNoAnswer
  writeFile(p.outPath, encodeSubmodule(answer))
  writeFile(p.outPath & ".blobs", blobs)

proc tablePolicy(p: FetchPlan): EgressPolicy =
  ## The egress policy rebuilt on this thread from the plan's table: the
  ## same rules, limits and trust anchors, with a resolver and a dialer that
  ## answer what the scheduler's thread answered. Its closures are made and
  ## dropped on this thread.
  let hosts = p.hosts
  let dials = p.dials
  let system = p.systemResolver
  let identity = p.identityDialer
  result = EgressPolicy(limits: p.limits, caFile: p.git.caFile)
  if not system:
    result.resolver = proc(host: string): seq[IpAddress] {.gcsafe.} =
      for (h, a) in hosts:
        if h == host: return a
      raise newException(NeedsSchedulerError, "host " & host &
        " is not in the resolution table")
  if not identity:
    result.dialer = proc(address: IpAddress): IpAddress {.gcsafe.} =
      for (a, b) in dials:
        if a == address: return b
      raise newException(NeedsSchedulerError, "address " & $address &
        " is not in the dialing table")

proc runFetchPlan*(p: FetchPlan): FetchWorkResult =
  ## Run one fetch edge and write its output files. An egress refusal --
  ## by the vetting, or a limit the transfer exceeds -- writes its answer
  ## and is returned for capture.
  var plan = p
  if not plan.prevetted:
    var progress = VetProgress(current: plan.url)
    try:
      plan.vetted = vetOriginFrom(tablePolicy(plan), plan.url, progress)
    except NeedsSchedulerError:
      return FetchWorkResult(needsScheduler: true, resume: progress)
    except EgressError as e:
      writeRefused(plan.kind, plan.url, plan.commit, plan.outPath, e.refusal)
      return FetchWorkResult(refused: true, refusal: e.refusal)
  let p = plan
  if dirExists(p.scratch): removeDir(p.scratch)
  createDir(p.scratch)
  defer: removeDir(p.scratch)
  try:
    case p.kind
    of fkRefs: runRefs(p)
    of fkHistory: runHistory(p)
    of fkSource: runSource(p)
    of fkSubmodule: runSubmodule(p)
  except EgressError as e:
    writeRefused(p.kind, p.url, p.commit, p.outPath, e.refusal)
    result = FetchWorkResult(refused: true, refusal: e.refusal)

proc fetchWork*(input: string): string {.nimcall, gcsafe.} =
  ## The engine's worker-thread entry (``BuiltinWork``): a plan's text in,
  ## the encoded ``FetchWorkResult`` out.
  encodeResult(runFetchPlan(decodePlan(input)))
