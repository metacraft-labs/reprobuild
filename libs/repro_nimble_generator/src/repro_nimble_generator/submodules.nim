## Submodule sources (NPC-AREQ12; spec § 6.1, "Submodule sources"; threat
## model asset 7, T35-T37, G37-G39): how a version whose tree has gitlinks
## becomes ONE source object holding each submodule's tree.
##
## Shared by the generator (`generator.nim`, whose `submodule` edges fetch
## the trees one wave per nesting level) and the client's git fallback
## (`repro_nimble_fetch/fetch.nim`, which fetches them directly), so both
## compose the same tree and reach the same `tree` digest.
##
## * **Which submodules.** Every gitlink of the package's tree (its
##   `?subdir=`, when it has one: the tree was read under it). Its URL is
##   the `.gitmodules` entry of the same commit whose `path` is the
##   gitlink's, read from the top of the repository. `update`, `branch` and
##   `shallow` are ignored: the gitlink's commit is the pin.
## * **URLs.** A relative URL (`./x`, `../x`) is resolved against the URL
##   its superproject was fetched from, as git's `relative_url` resolves it
##   (each `../` removes one component; past the host it removes the host,
##   so `../../../h/x` from `https://a/o/r` names `https://h/x`). The
##   resolved URL then passes rule 1 of the origin egress policy
##   (`parseOriginUrl`: `https` only, no credentials) before anything is
##   fetched; rules 2-5 run when the fetch vets it (`vetOrigin`). Every
##   gitlink of one superproject is checked this way BEFORE any of them is
##   fetched, so a refused URL means no submodule of that level is
##   contacted (G37).
## * **Bounds.** At most ``MaxSubmoduleDepth`` (8) levels and
##   ``MaxSubmodules`` (256) submodules per version; a submodule whose URL
##   identity and commit are those of one of its ancestors is a cycle (G38).
##   A cycle of commits cannot be built with honest hashes; the check guards
##   against an output that claims one.
## * **One tree.** Each submodule's entries are placed under its gitlink's
##   path. The composed tree is then checked as one: an entry that repeats a
##   path, a path that passes through a file or a symbolic link, a
##   placement under one, and a path with an empty, `.`, `..` or `.git`
##   component are refused (G39). Symbolic links are judged later, by
##   `sourceFacts`, against the WHOLE composed tree: a link of a submodule
##   that stays in the package is in-tree, one that leaves it makes the
##   version `unreadable`, as for any link.
##
## A version one of whose submodules fails any of this is not offered; the
## failure names the submodule's path in the source object and the reason as
## a fixed phrase (``SubmoduleFailure``).

import std/[algorithm, strutils, tables, unicode]

from repro_domain_types/nimble_index/types import MaxSubmodules,
  MaxSubmoduleDepth, MaxPathBytes

import ./egress
import ./origin_git
import ./source_tree

export MaxSubmodules, MaxSubmoduleDepth

type
  SubmoduleFailure* = enum
    ## Why a submodule cannot be obtained: the fixed phrase of the version's
    ## `gone` event (spec § 6.1, "What is not offered").
    sfNoEntry = "no .gitmodules entry"
    sfAmbiguousEntry = "more than one .gitmodules entry"
    sfNoUrl = "no url"
    sfEgress = "refused by the egress policy"
    sfNoAnswer = "the origin does not answer"
    sfCommitAbsent = "the origin does not hold the commit"
    sfDepth = "nesting bound exceeded"
    sfCount = "submodule count bound exceeded"
    sfCycle = "cycle"
    sfCollision = "collision"
    sfUnsafePath = "unsafe path"

  SubmoduleLookupState* = enum
    slReady   ## the tree is here
    slPending ## not fetched yet (the generator's next wave fetches it)
    slFailed

  SubmoduleLookup* = object
    ## What fetching one (URL, commit) gave.
    state*: SubmoduleLookupState
    tree*: FetchedTree ## the submodule commit's whole tree, for `slReady`
    failure*: SubmoduleFailure
    refusal*: string   ## the egress refusal kind, for `sfEgress`
    detail*: string

  SubmoduleLookupProc* = proc(url, identity, commit: string): SubmoduleLookup
    ## How a walk obtains a submodule's tree.

  SubmoduleNeed* = object
    ## A submodule tree the walk needs and does not have yet.
    url*, identity*, commit*: string

  Unobtainable* = object
    path*: string ## the submodule's path in the source object
    failure*: SubmoduleFailure
    refusal*: string
    url*: string
      ## the URL the egress policy refused, for a rule-1 `sfEgress`
    detail*: string

  SubmodulePin* = object
    ## One entry of the record's `submodules` list.
    path*, url*, commit*: string

  CompositionState* = enum
    coComposed ## every submodule is in place
    coPending  ## some trees are not fetched yet: ``needs``
    coFailed   ## a submodule cannot be obtained: ``failure``

  Composition* = object
    state*: CompositionState
    needs*: seq[SubmoduleNeed]
    failure*: Unobtainable
    tree*: FetchedTree
      ## the composed tree (no gitlink entry), for `coComposed`
    pins*: seq[SubmodulePin] ## every submodule at any depth, by path
    verdicts*: seq[SubmoduleUrl]
      ## the package's own gitlinks: path, the `.gitmodules` URL as written,
      ## and the policy's verdict (`refused:<kind>`, `fetched`, or
      ## `not-fetched` when the version failed before fetching it; G35)
    looked*: seq[string]
      ## the `<identity>@<commit>` keys the walk asked for, sorted

# ---------------------------------------------------------------------------
# URLs
# ---------------------------------------------------------------------------

proc isRelativeSubmoduleUrl*(url: string): bool =
  url.startsWith("./") or url.startsWith("../")

proc resolveSubmoduleUrl*(base, url: string): string =
  ## ``url`` from a `.gitmodules` whose superproject was fetched from
  ## ``base``, resolved as git's `relative_url` does. An absolute URL is
  ## returned as written. Raises `EgressError` (`erMalformed`) when ``base``
  ## has no component left to remove.
  if not isRelativeSubmoduleUrl(url):
    return url
  var remote = base
  if remote.endsWith("/"):
    remote.setLen(remote.len - 1)
  var rest = url
  var colonSep = false
  while true:
    if rest.startsWith("../"):
      rest = rest[3 .. ^1]
      let slash = remote.rfind('/')
      if slash >= 0:
        remote.setLen(slash)
      else:
        let colon = remote.rfind(':')
        if colon < 0:
          refuse(erMalformed, url, "cannot remove a component from " &
            remote.escape() & " to resolve the relative URL")
        remote.setLen(colon)
        colonSep = true
    elif rest.startsWith("./"):
      rest = rest[2 .. ^1]
    else:
      break
  result = remote & (if colonSep: ":" else: "/") & rest
  if rest.endsWith("/"):
    result.setLen(result.len - 1)

proc submoduleUrlIdentity*(url: string): string =
  ## The identity a submodule fetch is cached and a cycle is detected by:
  ## the host (lower case) and port, and the path without a trailing `/`
  ## or `.git`. A URL rule 1 refuses is its own identity.
  try:
    let u = parseOriginUrl(url)
    var p = u.path
    while p.len > 1 and p.endsWith("/"): p.setLen(p.len - 1)
    if p.endsWith(".git"): p.setLen(p.len - 4)
    u.host & ":" & $u.port & p
  except EgressError:
    url

proc fetchFailureOf*(failure: string): SubmoduleFailure =
  ## The fixed phrase of a git fetch of one commit that failed: the commit
  ## is not there, or the origin did not answer as a repository.
  let f = failure.toLowerAscii()
  for needle in ["not our ref", "couldn't find remote ref",
                 "no such remote ref", "not-a-commit",
                 "unadvertised object", "did not send all necessary objects"]:
    if needle in f: return sfCommitAbsent
  sfNoAnswer

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

proc joinRel(at, path: string): string =
  if at.len == 0: path else: at & "/" & path

proc normModulePath(p: string): string =
  result = p
  while result.startsWith("./"): result = result[2 .. ^1]
  while result.endsWith("/"): result.setLen(result.len - 1)

proc safePath*(p: string): bool =
  ## A path a source object can hold and a record can name: relative,
  ## components neither empty nor `.`, `..` or `.git`, UTF-8 without
  ## control characters, within the record's path bound.
  if p.len == 0 or p.len > MaxPathBytes or validateUtf8(p) != -1:
    return false
  for r in p.runes:
    let v = int32(r)
    if v < 0x20 or v == 0x7f or (v >= 0x80 and v < 0xa0): return false
  for part in p.split('/'):
    if part.len == 0 or part == "." or part == ".." or
        part.toLowerAscii() == ".git":
      return false
  true

proc passesThrough(kinds: Table[string, TreeEntryKind]; path: string): bool =
  ## Whether a proper prefix of ``path`` is an entry (a file or a link):
  ## placing ``path`` would write through it.
  var i = path.find('/')
  while i >= 0:
    if path[0 ..< i] in kinds: return true
    i = path.find('/', i + 1)
  false

# ---------------------------------------------------------------------------
# The walk
# ---------------------------------------------------------------------------

type
  Walk = object
    lookup: SubmoduleLookupProc
    count: int
    needs: seq[SubmoduleNeed]
    pins: seq[SubmodulePin]
    placements: seq[(string, FetchedTree)]
    verdicts: seq[SubmoduleUrl]
    looked: seq[string]
    failed: bool
    failure: Unobtainable

  Planned = object
    path, raw, url, identity, commit: string

proc fail(w: var Walk; path: string; f: SubmoduleFailure; refusal = "";
          detail = "") =
  if w.failed: return
  w.failed = true
  w.failure = Unobtainable(path: path, failure: f, refusal: refusal,
    detail: detail)

proc entriesFor(gm: seq[(string, string)]; path: string):
    tuple[count: int; url: string] =
  let want = normModulePath(path)
  for (p, u) in gm:
    if normModulePath(p) == want:
      inc result.count
      result.url = u

proc walk(w: var Walk; tree: FetchedTree; at, modulesPrefix, baseUrl: string;
          ancestors: seq[string]; depth: int; isRoot: bool) =
  var links: seq[TreeEntry]
  for e in tree.entries:
    if e.kind == teGitlink: links.add e
  if links.len == 0: return
  links.sort(proc (a, b: TreeEntry): int = cmp(a.path, b.path))
  let gm = if tree.hasGitmodules: parseGitmodules(tree.gitmodules) else: @[]
  # Phase 1, no contact: every gitlink of this tree has an entry, a URL
  # rule 1 accepts, a recordable path, and stays within the bounds.
  var planned: seq[Planned]
  var first: Unobtainable
  var anyFailure = false
  for g in links:
    let full = joinRel(at, g.path)
    let (n, raw) = entriesFor(gm, modulesPrefix & g.path)
    var problem = false
    var why: Unobtainable
    var verdict = ""
    if n == 0:
      problem = true
      why = Unobtainable(path: full, failure: sfNoEntry)
    elif n > 1:
      problem = true
      why = Unobtainable(path: full, failure: sfAmbiguousEntry)
    elif raw.len == 0:
      problem = true
      why = Unobtainable(path: full, failure: sfNoUrl)
    else:
      var resolved = ""
      try:
        resolved = resolveSubmoduleUrl(baseUrl, raw)
        discard parseOriginUrl(resolved)
        verdict = "not-fetched"
      except EgressError as e:
        problem = true
        verdict = "refused:" & $e.refusal.kind
        why = Unobtainable(path: full, failure: sfEgress,
          refusal: $e.refusal.kind, url: e.refusal.url,
          detail: e.refusal.detail)
      if not problem and not safePath(full):
        problem = true
        why = Unobtainable(path: full, failure: sfUnsafePath,
          detail: "the path " & full.escape() & " cannot be held or recorded")
      if not problem:
        planned.add Planned(path: full, raw: raw, url: resolved,
          identity: submoduleUrlIdentity(resolved), commit: g.oid)
    if isRoot and n >= 1:
      w.verdicts.add SubmoduleUrl(path: full, url: raw, verdict: verdict)
    if problem and not anyFailure:
      anyFailure = true
      first = why
  if anyFailure:
    if not w.failed:
      w.failed = true
      w.failure = first
    return
  for p in planned:
    if depth + 1 > MaxSubmoduleDepth:
      w.fail(p.path, sfDepth, detail = "deeper than " & $MaxSubmoduleDepth &
        " levels")
      return
    inc w.count
    if w.count > MaxSubmodules:
      w.fail(p.path, sfCount, detail = "more than " & $MaxSubmodules &
        " submodules")
      return
    if p.identity & "@" & p.commit in ancestors:
      w.fail(p.path, sfCycle, detail = p.url & " at " & p.commit &
        " is one of its own ancestors")
      return
  # Phase 2: the trees, then each one's own submodules.
  for p in planned:
    let key = p.identity & "@" & p.commit
    if key notin w.looked: w.looked.add key
    let lk = w.lookup(p.url, p.identity, p.commit)
    case lk.state
    of slPending:
      w.needs.add SubmoduleNeed(url: p.url, identity: p.identity,
        commit: p.commit)
    of slFailed:
      w.fail(p.path, lk.failure, lk.refusal, lk.detail)
      return
    of slReady:
      if isRoot:
        for v in w.verdicts.mitems:
          if v.path == p.path: v.verdict = "fetched"
      w.pins.add SubmodulePin(path: p.path, url: p.url, commit: p.commit)
      w.placements.add (p.path, lk.tree)
      var chain = ancestors
      chain.add key
      w.walk(lk.tree, p.path, "", p.url, chain, depth + 1, false)
      if w.failed: return

proc ownerOf(placements: seq[(string, FetchedTree)]; path: string): string =
  ## The submodule whose tree ``path`` lies in (the deepest), else ``path``.
  result = path
  var best = -1
  for (at, _) in placements:
    if (path == at or path.startsWith(at & "/")) and at.len > best:
      best = at.len
      result = at

proc composeTree(root: FetchedTree; placements: seq[(string, FetchedTree)];
                 failure: var Unobtainable): tuple[ok: bool; tree: FetchedTree] =
  ## The source object as ONE tree (G39); see the module docstring.
  var t = FetchedTree(commitTime: root.commitTime, blobs: root.blobs)
  for e in root.entries:
    if e.kind != teGitlink: t.entries.add e
  for (at, sub) in placements:
    for e in sub.entries:
      if e.kind == teGitlink: continue
      t.entries.add TreeEntry(kind: e.kind, mode: e.mode, oid: e.oid,
        path: at & "/" & e.path)
    for oid, bytes in sub.blobs:
      # Blobs are keyed by their object id: the same id is the same bytes.
      t.blobs[oid] = bytes
  var kinds = initTable[string, TreeEntryKind]()
  for e in t.entries:
    if e.path in kinds:
      failure = Unobtainable(path: ownerOf(placements, e.path),
        failure: sfCollision, detail: "two entries at " & e.path.escape())
      return (false, FetchedTree())
    kinds[e.path] = e.kind
  for (at, _) in placements:
    if at in kinds or passesThrough(kinds, at):
      failure = Unobtainable(path: at, failure: sfCollision,
        detail: "the submodule is placed at " & at.escape() &
          ", which is, or passes through, a file or a link")
      return (false, FetchedTree())
  for e in t.entries:
    if not safePath(e.path):
      failure = Unobtainable(path: ownerOf(placements, e.path),
        failure: sfUnsafePath, detail: "entry " & e.path.escape())
      return (false, FetchedTree())
    if passesThrough(kinds, e.path):
      failure = Unobtainable(path: ownerOf(placements, e.path),
        failure: sfCollision, detail: "entry " & e.path.escape() &
          " passes through a file or a link")
      return (false, FetchedTree())
  t.entries.sort(proc (a, b: TreeEntry): int = cmp(a.path, b.path))
  (true, t)

proc composeSource*(root: FetchedTree; subdir, originUrl, commit: string;
                    lookup: SubmoduleLookupProc): Composition =
  ## The source object of a version whose tree ``root`` (read under
  ## ``subdir`` from ``originUrl`` at ``commit``) has gitlinks: composed,
  ## pending on the trees ``lookup`` does not have yet, or failed.
  var w = Walk(lookup: lookup)
  let prefix = if subdir.strip(chars = {'/'}).len > 0:
                 subdir.strip(chars = {'/'}) & "/"
               else: ""
  w.walk(root, "", prefix, originUrl,
    @[submoduleUrlIdentity(originUrl) & "@" & commit], 0, true)
  result.verdicts = w.verdicts
  result.verdicts.sort(proc (a, b: SubmoduleUrl): int = cmp(a.path, b.path))
  result.looked = w.looked
  result.looked.sort()
  if w.failed:
    result.state = coFailed
    result.failure = w.failure
    return
  if w.needs.len > 0:
    result.state = coPending
    result.needs = w.needs
    return
  var failure: Unobtainable
  let (ok, tree) = composeTree(root, w.placements, failure)
  if not ok:
    result.state = coFailed
    result.failure = failure
    return
  result.state = coComposed
  result.tree = tree
  result.pins = w.pins
  result.pins.sort(proc (a, b: SubmodulePin): int = cmp(a.path, b.path))

proc hasGitlinks*(t: FetchedTree): bool =
  for e in t.entries:
    if e.kind == teGitlink: return true
  false

proc eventPhrase*(u: Unobtainable): string =
  ## The `after` text of the version's `gone` event: the submodule's path
  ## (bytes outside printable ASCII percent-encoded) and the fixed phrase.
  var p = ""
  for c in u.path:
    if ord(c) < 0x21 or ord(c) > 0x7e or c == '%':
      p.add '%' & toHex(ord(c), 2)
    else:
      p.add c
  "submodule " & p & ": " & $u.failure
