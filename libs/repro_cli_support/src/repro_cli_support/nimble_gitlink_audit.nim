## `repro nimble gitlink-audit` (Nimble-Package-Catalog.md NPC-AREQ28): for
## each git submodule of a project, whether its gitlink commit is a catalog
## package and what it becomes when the submodule is removed.
##
## Each gitlink of the revision (`--at`, default `HEAD`) is read with its
## `.gitmodules` entry of that revision: path, URL (a relative URL resolved
## against the project's `origin` remote, as git resolves it) and declared
## branch. The URL's origin identity is compared with every origin of the
## Nimble index the project imports, at the revision its lock pins (or, with
## no pin, at the revision the import's ref names). Then:
##
## 1. **catalog**: the commit is a tag version's commit of that package; it
##    becomes `nimble:<name> == <version>`.
## 2. **catalog, snapshot**: the package has no tag version and the commit is
##    its offered snapshot (NPC-AREQ31 item 5); the bare name pins it.
## 3. **catalog, untagged**: the commit is no version but is reachable from
##    one of the origin's branches or tags; it becomes `nimble:<name>#<commit>`.
## 4. **overlay**: no package has the URL's origin, or the commit is on none
##    of the origin's branches and tags (a fork's or an unpublished commit);
##    it becomes an `[[override]]` or `[[extra]]` of the project's own source
##    set, pinned by commit.
##
## Reachability is a question for the origin, so the audit fetches the
## origin's branch and tag history (no file contents), at the URL the index
## records for it, into a scratch repository; only a commit that is no
## version needs it. When the origin cannot be fetched, or the gitlink has
## no `.gitmodules` URL, the gitlink is **undecided**, naming why: it is not
## reported as an overlay it may not be.
##
## The report is printed one line per gitlink, or as JSON (`--json`) for a
## machine to read; the JSON is an inspection output, never a source of
## truth.

import std/[algorithm, json, options, os, osproc, sequtils, strutils, tables,
            tempfiles]

import repro_lock
import repro_nimble_index
import repro_nimble_generator/submodules
from repro_core/ambient_execution import uncontrolledExecArgvEx

import ./catalog_discovery
import ./nimble_develop

type
  GitlinkClass* = enum
    gcCatalog = "catalog"
    gcCatalogSnapshot = "catalog, snapshot"
    gcCatalogUntagged = "catalog, untagged"
    gcOverlay = "overlay"
    gcUndecided = "undecided"

  Gitlink* = object
    path*: string   ## the gitlink's path in the project
    commit*: string ## the commit it records
    url*: string    ## the `.gitmodules` URL as written ("" when none)
    branch*: string ## the declared tracking branch ("" when none)

  GitlinkVerdict* = object
    link*: Gitlink
    resolvedUrl*: string ## the URL a relative one names
    class*: GitlinkClass
    package*: string     ## the catalog package ("" for an overlay)
    version*: string     ## the version or snapshot the commit is
    requirement*: string ## what the submodule becomes ("" for an overlay)
    reason*: string

  Reachability* = object
    known*: bool     ## the origin answered
    reachable*: bool ## the commit is on one of its branches or tags
    detail*: string  ## why it is not known

  ReachFn* = proc (url, commit: string): Reachability {.closure.}

proc git(args: openArray[string]; mergeErrors = false):
    tuple[code: int; output: string] =
  ## A read-only git command of the audit (the project's own history, or
  ## the scratch repository it fetched an origin into). Run outside the
  ## build graph, as the command's own question. ``mergeErrors`` keeps
  ## git's diagnostics in ``output`` (for a command whose output is only a
  ## message) instead of on the caller's stderr.
  let options = if mergeErrors: {poUsePath, poStdErrToStdOut}
                else: {poUsePath}
  try:
    let r = uncontrolledExecArgvEx(@["git"] & @args, options = options)
    (r.exitCode, r.output)
  except CatchableError as e:
    (-1, e.msg)

proc readGitlinks*(project, rev: string): seq[Gitlink] =
  ## The gitlinks of ``rev`` in ``project``, sorted by path, with their
  ## `.gitmodules` entries of the same revision. Raises ``ValueError`` when
  ## the revision cannot be read.
  let tree = git(["-C", project, "ls-tree", "-r", "-z", rev])
  if tree.code != 0:
    raise newException(ValueError, "cannot read the tree of " & rev &
      " in " & project & ": " & tree.output.strip())
  for entry in tree.output.split('\0'):
    # `<mode> <type> <object>\t<path>`
    let tab = entry.find('\t')
    if tab < 0: continue
    let head = entry[0 ..< tab].splitWhitespace()
    if head.len == 3 and head[0] == "160000" and head[1] == "commit":
      result.add Gitlink(path: entry[tab + 1 .. ^1], commit: head[2])
  result.sort(proc (a, b: Gitlink): int = cmp(a.path, b.path))
  if result.len == 0:
    return
  let modules = git(["-C", project, "config", "--blob", rev & ":.gitmodules",
    "--list", "-z"], mergeErrors = true)
  if modules.code != 0:
    # No `.gitmodules` leaves every gitlink without a URL (each is then
    # undecided). One that exists and cannot be read is an error: reading
    # it as absent would decide nothing it says.
    if git(["-C", project, "cat-file", "-e", rev & ":.gitmodules"],
        mergeErrors = true).code == 0:
      raise newException(ValueError, "cannot read the .gitmodules of " &
        rev & " in " & project & ": " & modules.output.strip())
    return
  var pathOf = initTable[string, string]() # submodule name -> path
  var urlOf, branchOf = initTable[string, string]()
  for item in modules.output.split('\0'):
    let nl = item.find('\n')
    if nl < 0: continue
    let key = item[0 ..< nl]
    let value = item[nl + 1 .. ^1]
    if not key.startsWith("submodule."): continue
    let dot = key.rfind('.')
    if dot <= "submodule.".len: continue
    let name = key["submodule.".len ..< dot]
    case key[dot + 1 .. ^1]
    of "path": pathOf[name] = value
    of "url": urlOf[name] = value
    of "branch": branchOf[name] = value
    else: discard
  proc clean(p: string): string =
    result = p
    if result.startsWith("./"): result = result[2 .. ^1]
    while result.endsWith("/"): result.setLen(result.len - 1)
  for l in result.mitems:
    for name, p in pathOf:
      if clean(p) == l.path:
        l.url = urlOf.getOrDefault(name)
        l.branch = branchOf.getOrDefault(name)

proc projectRemote*(project: string): string =
  ## The URL a relative `.gitmodules` URL is resolved against: the
  ## project's `origin` remote ("" when it has none).
  let r = git(["-C", project, "config", "--get", "remote.origin.url"])
  if r.code == 0: r.output.strip() else: ""

proc originReachability*(scratch: string): ReachFn =
  ## Reachability by asking the origin: its branches and tags are fetched,
  ## without file contents, into a repository under ``scratch`` (one per
  ## origin, kept for the run).
  var fetched = initTable[string, tuple[dir: string; ok: bool; why: string]]()
  var n = 0
  result = proc (url, commit: string): Reachability =
    if url notin fetched:
      inc n
      let dir = scratch / ("origin-" & $n & ".git")
      var ok = git(["init", "-q", "--bare", dir], mergeErrors = true).code == 0
      var why = ""
      if ok:
        let f = git(["-c", "protocol.ext.allow=never", "-C", dir, "fetch",
          "-q", "--no-tags", "--filter=blob:none", "--end-of-options", url,
          "+refs/heads/*:refs/remotes/o/*", "+refs/tags/*:refs/tags/*"],
          mergeErrors = true)
        if f.code != 0:
          ok = false
          why = "fetching " & url & " failed: " & f.output.strip()
      else:
        why = "cannot create a scratch repository under " & scratch
      fetched[url] = (dir, ok, why)
    let (dir, ok, why) = fetched[url]
    if not ok:
      return Reachability(known: false, detail: why)
    if git(["-C", dir, "cat-file", "-e", commit & "^{commit}"],
        mergeErrors = true).code != 0:
      return Reachability(known: true, reachable: false)
    let c = git(["-C", dir, "for-each-ref", "--contains", commit,
      "--format=%(refname)", "refs/remotes/o", "refs/tags"])
    Reachability(known: true,
      reachable: c.code == 0 and c.output.strip().len > 0)

proc classifyGitlinks*(links: seq[Gitlink]; baseRemote: string;
                       packages: seq[PackageEnvelope];
                       platform: NimblePlatform; reach: ReachFn):
    seq[GitlinkVerdict] =
  ## The verdict of each gitlink (see the module header). ``packages`` is
  ## every package of the index.
  for l in links:
    var v = GitlinkVerdict(link: l)
    if l.url.len == 0:
      # Without a URL the origin is not known, so neither is whether the
      # commit is a fork's: an overlay would assert what was not measured.
      v.class = gcUndecided
      v.reason = "no .gitmodules entry names " & l.path & ", so its origin " &
        "is not known"
      result.add v
      continue
    v.resolvedUrl =
      if not isRelativeSubmoduleUrl(l.url): l.url
      elif baseRemote.len == 0: ""
      else:
        try: resolveSubmoduleUrl(baseRemote, l.url)
        except CatchableError: ""
    if v.resolvedUrl.len == 0:
      v.class = gcUndecided
      v.reason = "the relative URL " & l.url & " cannot be resolved: " &
        (if baseRemote.len == 0: "the project has no origin remote"
         else: "too many `../` for " & baseRemote)
      result.add v
      continue
    let want = originIdentity(v.resolvedUrl)
    var owners: seq[PackageEnvelope]
    var ownerUrl = ""
    for p in packages:
      for o in p.origins:
        if o.subdir.len == 0 and originIdentity(o.url) == want:
          owners.add p
          ownerUrl = o.url
          break
    if owners.len == 0:
      v.class = gcOverlay
      v.reason = "no package of the index has the origin " & want
      result.add v
      continue
    if owners.len > 1:
      v.class = gcUndecided
      v.reason = "the packages " & owners.mapIt(it.name).join(", ") &
        " all have the origin " & want
      result.add v
      continue
    let pkg = owners[0]
    v.package = pkg.name
    let candidates = candidatesOf(pkg, platform)
    var tagged = -1
    for i, c in candidates:
      if c.record.version.kind == rvkTag and c.record.commit == l.commit:
        tagged = i
        break
    if tagged >= 0:
      let c = candidates[tagged]
      v.class = gcCatalog
      v.version = c.version
      v.requirement = "nimble:" & pkg.name & " == " & c.version
      v.reason = "the commit is " & pkg.name & " " & c.record.version.tag
      if not c.offered:
        v.reason.add ", which the index does not offer (" &
          c.exclusions.mapIt($it.kind & ": " & it.detail).join("; ") & ")"
      result.add v
      continue
    let snapshot = offeredSnapshot(NimbleSolverPackage(name: pkg.name,
      candidates: candidates))
    if snapshot >= 0 and candidates[snapshot].record.commit == l.commit:
      v.class = gcCatalogSnapshot
      v.version = candidates[snapshot].version
      v.requirement = "nimble:" & pkg.name
      v.reason = pkg.name & " has no tag version, and the commit is its " &
        "offered snapshot " & candidates[snapshot].version
      result.add v
      continue
    # The origin is asked at the URL the index records for it, never at
    # the `.gitmodules` spelling: the identity folds the scheme and
    # userinfo, so that spelling may name another transport (plain
    # `http://`, `git://`) or carry options, and the index's URL is the one
    # its generation fetched under the egress policy.
    let r = reach(ownerUrl, l.commit)
    if not r.known:
      v.class = gcUndecided
      v.reason = "the commit is no version of " & pkg.name & ", and " &
        "whether its origin holds it is not known: " & r.detail
    elif r.reachable:
      v.class = gcCatalogUntagged
      v.requirement = "nimble:" & pkg.name & "#" & l.commit
      v.reason = "the commit is no version of " & pkg.name & ", but a " &
        "branch or tag of its origin " & want & " holds it"
    else:
      v.class = gcOverlay
      v.package = ""
      v.reason = "the commit is on no branch or tag of " & pkg.name &
        "'s origin " & want & " (a fork's or an unpublished commit)"
    result.add v

proc indexPackages*(idx: var NimbleIndex): seq[PackageEnvelope] =
  ## Every package of the index, shard by shard.
  for r in idx.root.shards:
    let shard = loadShard(idx, r.bucket)
    if shard.isSome:
      result.add shard.get.packages

proc verdictJson*(v: GitlinkVerdict): JsonNode =
  %*{"path": v.link.path, "commit": v.link.commit, "url": v.link.url,
     "resolved_url": v.resolvedUrl, "branch": v.link.branch,
     "class": $v.class, "package": v.package, "version": v.version,
     "requirement": v.requirement, "reason": v.reason}

proc runGitlinkAuditCommand*(projectArg, atArg, lockArg, platformArg: string;
                             asJson: bool): int =
  ## The verb: 0 when every gitlink is decided, 1 when one is undecided, 2
  ## when the project, its revision or its Nimble index cannot be read.
  const verb = "repro nimble gitlink-audit"
  let project = absolutePath(if projectArg.len > 0: projectArg
                             else: getCurrentDir())
  let rev = if atArg.len > 0: atArg else: "HEAD"
  var links: seq[Gitlink]
  var packages: seq[PackageEnvelope]
  var indexLabel = ""
  var platform: NimblePlatform
  try:
    links = readGitlinks(project, rev)
    let lockPath = if lockArg.len > 0: absolutePath(lockArg)
                   else: project / "repro.lock"
    var pins: seq[LockedCatalogImport]
    var lockPlatform = ""
    if fileExists(lockPath):
      let ld = parseLockedDependencies(readFile(lockPath))
      for p in ld.lockedCatalogImportPins():
        if p.kind == cikNimbleIndex: pins.add p
      lockPlatform = ld.platform
    var notes: seq[string]
    let indexes = nimbleIndexesForSolve(project, pins, pins.len == 0, @[],
      notes)
    if indexes.len != 1:
      raise newException(ValueError, project & " imports " & $indexes.len &
        " Nimble indexes; the audit reads exactly one")
    var idx = openNimbleIndex(indexes[0])
    packages = indexPackages(idx)
    indexLabel = indexes[0].repo & " at " & indexes[0].revision
    let pid =
      if platformArg.len > 0: platformArg
      elif lockPlatform.len > 0: lockPlatform
      else: currentPlatformId()
    platform = nimblePlatformOf(pid)
  except CatchableError as e:
    stderr.writeLine(verb & ": error: " & e.msg)
    return 2
  let scratch = createTempDir("repro-gitlink-audit-", "")
  var verdicts: seq[GitlinkVerdict]
  try:
    verdicts = classifyGitlinks(links, projectRemote(project), packages,
      platform, originReachability(scratch))
  finally:
    try: removeDir(scratch)
    except OSError: discard
  let undecided = verdicts.countIt(it.class == gcUndecided)
  if asJson:
    var rows = newJArray()
    for v in verdicts: rows.add verdictJson(v)
    echo pretty(%*{"schema": "reprobuild.nimble.gitlink-audit.v1",
      "project": project, "revision": rev, "index": indexLabel,
      "gitlinks": rows})
  else:
    for v in verdicts:
      echo v.link.path & ": " & $v.class &
        (if v.requirement.len > 0: " -> " & v.requirement else: "") &
        " (" & v.reason & ")"
    var counts: seq[string]
    for c in GitlinkClass:
      let k = verdicts.countIt(it.class == c)
      if k > 0: counts.add $k & " " & $c
    echo "audited: " & $verdicts.len & " gitlink(s) of " & rev & " against " &
      indexLabel & (if counts.len > 0: ": " & counts.join("; ") else: "")
  if undecided > 0: 1 else: 0
