## Restore a project union at a strict workspace lock or snapshot. Metadata
## and repository checkouts live in a sibling staging directory until every
## pinned commit has been verified; failures never expose a partial workspace.
import std/[os, strutils, tables, tempfiles, uri]
import repro_workspace_manifests
import git_tool
import repro_core/path_identity

when defined(windows):
  import std/winlean
else:
  proc renameDirectory(source, destination: cstring): cint {.
    importc: "rename", header: "<stdio.h>".}

type
  WorkspaceRestoreRequest* = object
    ## Explicit metadata, membership and record inputs; no invoking-workspace
    ## defaults are consulted. URL sources require their revision selectors.
    source*, destination*, metadataRevision*, record*, snapshot*: string
    recordStore*, recordStoreRevision*: string
    projects*: seq[string]
  RestoredWorkspaceRepo* = object
    ## Verified detached checkout identity, reported only after publication.
    name*, path*, revision*: string
  WorkspaceRestoreResult* = object
    ## Published destination and the exact commits used for every input.
    destination*, metadataRevision*, recordStoreRevision*: string
    repos*: seq[RestoredWorkspaceRepo]

proc git(identity: GitToolIdentity; args: openArray[string]): string =
  let response = queryGit(identity, args)
  if response.code != 0:
    raise newException(ValueError, "git " & (@args).join(" ") & ": " &
        response.output.strip)
  response.output.strip

proc fullCommit(value: string): bool =
  value.len in [40, 64] and value.allCharsInSet({'0'..'9', 'a'..'f', 'A'..'F'})

proc emptyDirectory(path: string): bool =
  for unused in walkDir(path): return false
  true

proc checkMetadataSymlinks(root: string) =
  # Git records link bytes, not the external files a link happens to name.
  # A restored metadata commit must never read mutable data outside its tree.
  proc visit(directory: string) =
    for kind, path in walkDir(directory):
      if path == root / ".git": continue
      if kind in {pcLinkToFile, pcLinkToDir}:
        let containment = fsContainment(path, root)
        if (not fileExists(path) and not dirExists(path)) or
            containment.verdict != fcBeneath or
            containment.target == root / ".git" or
            containment.target.startsWith(root / ".git" & DirSep):
          raise newException(ValueError,
              "metadata symlink escapes its committed tree: " & relativePath(
              path, root))
      elif kind == pcDir:
        visit(path)
  visit(root)

proc isRecordKey(selector: string): bool =
  let at = selector.rfind('@')
  let slash = selector.find('/')
  at > slash and slash > 0 and fullCommit(selector[at + 1 .. ^1])

proc cloneAt(identity: GitToolIdentity; source, destination,
    requested: string): string =
  discard git(identity, @["clone", "--no-local", "--no-checkout", "--", source, destination])
  let metadataRef = if requested.len > 0: requested else: "HEAD"
  var revision = queryGit(identity, @["-C", destination, "rev-parse",
      "--verify", "--end-of-options", metadataRef & "^{commit}"])
  if revision.code != 0:
    revision = queryGit(identity, @["-C", destination, "rev-parse", "--verify",
        "--end-of-options", "origin/" & metadataRef & "^{commit}"])
  if revision.code != 0:
    raise newException(ValueError, "cannot resolve repository revision: " & metadataRef)
  result = revision.output.strip
  discard git(identity, @["-C", destination, "checkout", "--detach", result, "--"])
  checkMetadataSymlinks(destination)

proc recordPath(metadataRoot, selector: string): string =
  ## A key has one project separator, with the remaining repo name allowed
  ## to contain slashes. The shared encoder supplies the exact store path.
  let at = selector.rfind('@')
  let slash = selector.find('/')
  if at > slash and slash > 0 and fullCommit(selector[at + 1 .. ^1]):
    return metadataRoot / lockRecordRelPath(selector[0 ..< slash],
      selector[slash + 1 ..< at], selector[at + 1 .. ^1])
  absolutePath(selector)

proc localSourcePath(source: string): string =
  if dirExists(source):
    return expandFilename(source)
  if source.startsWith("file://"):
    let parsed = parseUri(source)
    let path = decodeUrl(parsed.path, decodePlus = false)
    if parsed.hostname in ["", "localhost"] and dirExists(path):
      return expandFilename(path)

proc publishRestoredWorkspace*(staging, destination: string) =
  ## Publish an already verified staging directory without ever recursively
  ## deleting the destination. Callers may have checked emptiness earlier,
  ## but another process can populate that directory before publication.
  when defined(windows):
    if symlinkExists(destination) or fileExists(destination):
      raise newException(ValueError, "restore destination is not an empty directory")
    let existed = dirExists(destination)
    if existed and removeDirectoryW(newWideCString(destination)) == 0:
      raiseOSError(osLastError(), destination)
    # No copy fallback and no replace flag: a concurrent new target refuses.
    if moveFileExW(newWideCString(staging), newWideCString(destination), 0) == 0:
      let failure = osLastError()
      if existed and not dirExists(destination) and not fileExists(
          destination) and not symlinkExists(destination):
        createDir(destination)
      raiseOSError(failure, destination)
  else:
    # rename replaces an empty directory atomically and refuses nonempty
    # directories. Staging is a sibling, so cross-filesystem copying is never
    # an acceptable fallback here.
    if renameDirectory(staging.cstring, destination.cstring) != 0:
      raiseOSError(osLastError(), destination)

proc restoreWorkspace*(request: WorkspaceRestoreRequest;
                       identity: GitToolIdentity): WorkspaceRestoreResult =
  ## Materialize without changing the source workspace or its working trees.
  ## Only immutable full commit ids are accepted as repository pins. Metadata
  ## refs may be symbolic but are resolved once and recorded in the result.
  if request.source.len == 0 or request.destination.len == 0 or
      request.projects.len == 0:
    raise newException(ValueError, "restore requires source, destination and --projects=A,B")
  if (request.record.len == 0) == (request.snapshot.len == 0):
    raise newException(ValueError, "restore requires exactly one of --record or --snapshot")
  if (request.recordStore.len > 0 or request.recordStoreRevision.len > 0) and
      not isRecordKey(request.record):
    raise newException(ValueError, "record-store options require a commit-addressed --record key")
  let requestedDestination = absolutePath(request.destination)
  let destination = if dirExists(requestedDestination.parentDir):
      expandFilename(requestedDestination.parentDir) /
          requestedDestination.lastPathPart
    else: requestedDestination
  let metadataSource = if dirExists(request.source):
      manifestsRoot(absolutePath(request.source))
    else: request.source
  for localSource in [localSourcePath(request.source), localSourcePath(metadataSource),
                      localSourcePath(request.recordStore)]:
    if localSource.len > 0 and (destination == localSource or
        destination.startsWith(localSource & DirSep)):
      raise newException(ValueError, "restore destination must be outside its source repositories")
  if not dirExists(request.source) and request.metadataRevision.len == 0:
    raise newException(ValueError, "a metadata URL requires --at=REV")
  if symlinkExists(destination) or fileExists(destination) or
      (dirExists(destination) and not emptyDirectory(destination)):
    raise newException(ValueError, "restore destination must be absent or empty: " & destination)
  if not dirExists(destination.parentDir):
    raise newException(ValueError, "restore destination parent does not exist: " &
        destination.parentDir)
  let staging = createTempDir(".repro-restore-", "", destination.parentDir)
  defer:
    if dirExists(staging): removeDir(staging)
  let metadata = staging / ".repro" / "manifests"
  createDir(metadata.parentDir)
  result.metadataRevision = cloneAt(identity, metadataSource, metadata,
      request.metadataRevision)
  var projects: seq[string]
  for name in request.projects:
    if name.len == 0 or name in projects or
        declaredCheckoutPathRejection(name).len > 0 or
        '/' in name or '\\' in name:
      raise newException(ValueError, "restore project names must be nonempty and unique")
    projects.add(name)
  let primary = resolveWorkspaceProjectByName(staging, projects[0])
  let resolved = unionProjectSet(staging, primary, projects[1 .. ^1])
  var pins: seq[LockedRepo]
  if request.snapshot.len > 0:
    if declaredCheckoutPathRejection(request.snapshot).len > 0 or
        '/' in request.snapshot or '\\' in request.snapshot:
      raise newException(ValueError, "snapshot must be a single name")
    pins = readSnapshot(metadata / "snapshots" / (request.snapshot & ".toml")).repo
  else:
    var storeRoot = ""
    if isRecordKey(request.record):
      if request.recordStore.len == 0:
        raise newException(ValueError, "a commit-addressed record requires --record-store or a local record-store checkout")
      if not dirExists(request.recordStore) and
          request.recordStoreRevision.len == 0:
        raise newException(ValueError, "a record-store URL requires --record-store-at=REV")
      storeRoot = staging / ".repro" / "records"
      result.recordStoreRevision = cloneAt(identity, request.recordStore,
          storeRoot, request.recordStoreRevision)
      for metadataDir in ["projects", "repos", "repo-sets"]:
        if dirExists(storeRoot / metadataDir):
          raise newException(ValueError, "--record-store must name a separate record store, not workspace metadata")
    let selectedPath = recordPath(storeRoot, request.record)
    let record = readLock(selectedPath)
    pins = record.repo
    if storeRoot.len > 0:
      let key = parseLockRecordRelPath(relativePath(selectedPath, storeRoot))
      if key.ok:
        if record.lock.project != key.project:
          raise newException(ValueError, "lock record project differs from its store key")
        var matchesTrigger = false
        for pin in pins:
          if pin.name == key.repo and pin.revision.toLowerAscii ==
              key.sha.toLowerAscii:
            matchesTrigger = true
        if not matchesTrigger:
          raise newException(ValueError, "lock record does not pin its trigger at the store key commit")
  var byPath = initTable[string, LockedRepo]()
  for pin in pins:
    if pin.path in byPath:
      raise newException(ValueError, "duplicate lock pin for " & pin.path)
    byPath[pin.path] = pin
  # Finish the entire preflight before cloning any selected repository. Also
  # reject overlapping paths: a checkout must not replace metadata or another
  # checkout, even if both declarations were individually valid paths.
  var paths: seq[string]
  for repo in resolved.repos:
    if repo.path == ".repro" or repo.path.startsWith(".repro/"):
      raise newException(ValueError, "restore checkout overlaps workspace metadata: " & repo.path)
    for prior in paths:
      if repo.path.startsWith(prior & "/") or prior.startsWith(repo.path & "/"):
        raise newException(ValueError, "restore checkout paths overlap: " &
            prior & " and " & repo.path)
    paths.add(repo.path)
    if repo.path notin byPath:
      raise newException(ValueError, "record does not pin selected repository: " & repo.path)
    let pin = byPath[repo.path]
    if pin.name != repo.name or pin.remote != repo.projectRemote:
      raise newException(ValueError, "record identity differs from metadata for " & repo.path)
    if not fullCommit(pin.revision):
      raise newException(ValueError, "record must pin a full commit id for " & repo.path)
    if repo.vcs notin ["", "git"]:
      raise newException(ValueError, "restore does not support VCS " &
          repo.vcs & " for " & repo.path)
  var checkoutRepos: seq[ResolvedRepo]
  for repo in resolved.repos:
    if repo.path == ".": checkoutRepos.add(repo)
  let hasRoot = checkoutRepos.len > 0
  for repo in resolved.repos:
    if repo.path != ".": checkoutRepos.add(repo)
  let holding = createTempDir(".repro-restore-metadata-", "",
      destination.parentDir)
  defer:
    if dirExists(holding): removeDir(holding)
  if hasRoot:
    # A root member must be cloned into an empty directory. Hold the already
    # resolved metadata beside it until the root checkout has been verified.
    moveDir(staging / ".repro", holding / "metadata")
  for repo in checkoutRepos:
    let target = staging / repo.path
    if repo.path != ".":
      var ancestor = staging
      for segment in repo.path.split('/'):
        ancestor = ancestor / segment
        if symlinkExists(ancestor):
          raise newException(ValueError,
              "restore checkout follows a root-tree symlink: " & repo.path)
    if fileExists(target) or symlinkExists(target) or
        (dirExists(target) and not emptyDirectory(target)):
      raise newException(ValueError, "restore checkout overlaps root-tree content: " & repo.path)
    createDir(target.parentDir)
    # A manifest remote key and a local Git remote name are different
    # namespaces; legacy explicit bindings may already carry a local name.
    var remoteName = repo.projectRemote
    for remote in repo.remotes:
      if remote.projectRemote == repo.projectRemote:
        remoteName = remote.localName
        break
    if remoteName.len == 0: remoteName = "origin"
    discard git(identity, @["clone", "--origin", remoteName, "--no-checkout",
        "--", repo.fetchUrl, target])
    let pin = byPath[repo.path]
    # A commit absent from advertised refs may still be fetchable by object id.
    let present = queryGit(identity, @["-C", target, "cat-file", "-e",
        pin.revision & "^{commit}"])
    if present.code != 0:
      discard git(identity, @["-C", target, "fetch", remoteName, pin.revision])
    discard git(identity, @["-C", target, "checkout", "--detach", pin.revision, "--"])
    let actual = git(identity, @["-C", target, "rev-parse", "HEAD"])
    if actual.toLowerAscii != pin.revision.toLowerAscii:
      raise newException(ValueError, "restore commit mismatch for " & repo.path)
    result.repos.add(RestoredWorkspaceRepo(name: repo.name, path: repo.path,
        revision: actual))
    if repo.path == ".":
      for reserved in ["projects", "repos"]:
        if dirExists(staging / reserved) or symlinkExists(staging / reserved):
          raise newException(ValueError,
              "root checkout shadows selected metadata: " & reserved)
      if dirExists(staging / ".repro") or fileExists(staging / ".repro") or
          symlinkExists(staging / ".repro"):
        raise newException(ValueError, "root checkout overlaps workspace metadata: .repro")
      moveDir(holding / "metadata", staging / ".repro")
  writeWorkspaceProjects(staging, projects)
  # Refuse a destination populated while the potentially long clone ran.
  if symlinkExists(destination) or fileExists(destination) or
      (dirExists(destination) and not emptyDirectory(destination)):
    raise newException(ValueError, "restore destination changed while staging: " & destination)
  publishRestoredWorkspace(staging, destination)
  result.destination = destination

proc runWorkspaceRestoreCommand*(args: openArray[string];
    localRecordStore: proc(source: string): string = nil): int =
  ## Parse a deliberately explicit input tuple; no invoking workspace state
  ## or enabled-project defaults influence a restoration. The optional store
  ## callback supplies conventional local discovery without coupling this
  ## reusable materializer to the command dispatcher.
  var request: WorkspaceRestoreRequest
  var positional: seq[string]
  for arg in args:
    if arg in ["--help", "-h"]:
      echo "usage: repro ws restore <source> <destination> --projects=A,B [--at=REV] (--record=PATH|PROJECT/REPO@SHA | --snapshot=NAME) [--record-store=SOURCE] [--record-store-at=REV]"
      return 0
    elif arg.startsWith("--projects="): request.projects = arg[11 .. ^1].split(',')
    elif arg.startsWith("--at="): request.metadataRevision = arg[5 .. ^1]
    elif arg.startsWith("--record="): request.record = arg[9 .. ^1]
    elif arg.startsWith("--snapshot="): request.snapshot = arg[11 .. ^1]
    elif arg.startsWith("--record-store="): request.recordStore = arg[15 .. ^1]
    elif arg.startsWith("--record-store-at="): request.recordStoreRevision = arg[
        18 .. ^1]
    elif arg.startsWith("-"):
      raise newException(ValueError, "unknown restore flag: " & arg)
    else: positional.add(arg)
  if positional.len != 2:
    raise newException(ValueError, "restore requires <source> <destination>")
  request.source = positional[0]
  request.destination = positional[1]
  if request.recordStore.len == 0 and dirExists(request.source) and
      isRecordKey(request.record) and not localRecordStore.isNil:
    request.recordStore = localRecordStore(absolutePath(request.source))
  let outcome = restoreWorkspace(request, ensureGitToolResolvable(tpmPathOnly,
      getEnv("PATH")))
  echo "workspace restore: metadata " & outcome.metadataRevision & " at " &
      outcome.destination
  if outcome.recordStoreRevision.len > 0:
    echo "workspace restore: record store " & outcome.recordStoreRevision
  for repo in outcome.repos:
    echo "workspace restore: " & repo.path & " " & repo.revision
  0
