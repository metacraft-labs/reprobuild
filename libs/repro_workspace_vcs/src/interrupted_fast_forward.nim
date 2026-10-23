## Conservative evidence for an interrupted fast-forward. This never mutates
## a checkout: compatible upstream content receives manual recovery advice,
## and any missing evidence keeps the ordinary dirty refusal.
import std/[os, sets, strutils, tables]
import git_tool
when defined(windows):
  import winlean
else:
  import posix

type TreeEntry = object
  mode, oid: string

type InspectionError = object of CatchableError

proc inspect(identity: GitToolIdentity; repo: string;
             args: openArray[string]): string =
  let res = queryGit(identity, @["--no-optional-locks", "-C", repo,
    "-c", "core.fsmonitor=false"] & @args)
  if res.code != 0:
    raise newException(InspectionError, "Git inspection failed")
  res.output

proc records(value: string): seq[string] =
  if value.len == 0: return
  if value[^1] != '\0':
    raise newException(InspectionError, "incomplete Git path stream")
  result = value[0 ..< value.len - 1].split('\0')

proc tree(identity: GitToolIdentity; repo, revision: string): Table[string, TreeEntry] =
  for record in records(inspect(identity, repo, ["ls-tree", "-rz", revision])):
    let tab = record.find('\t')
    if tab <= 0: raise newException(InspectionError, "invalid tree entry")
    let fields = record[0 ..< tab].split(' ')
    if fields.len != 3: raise newException(InspectionError, "invalid tree metadata")
    result[record[tab + 1 .. ^1]] = TreeEntry(mode: fields[0], oid: fields[2])

proc pathInfo(path: string): tuple[exists: bool, info: FileInfo] =
  # fileExists/symlinkExists suppress permission and I/O errors. Such an
  # error is not proof of a target deletion, so distinguish only ENOENT and
  # ENOTDIR from failures that must stop the recovery recommendation.
  try:
    result.info = getFileInfo(path, followSymlink = false)
    result.exists = true
  except OSError as error:
    when defined(windows):
      if error.errorCode notin [ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND]: raise
    else:
      if error.errorCode notin [ENOENT, ENOTDIR]: raise

proc worktreeMatches(identity: GitToolIdentity; repo, path: string;
                     entry: TreeEntry): bool =
  # Never follow a replaced directory symlink out of the checkout. A directory
  # at a deleted file's path is absence only if its descendants pass the same
  # independent untracked/ignored collision checks as all other additions.
  var parent = path.parentDir
  while parent.len > 0 and parent != ".":
    let info = pathInfo(repo / parent)
    if info.exists and info.info.kind in {pcLinkToFile, pcLinkToDir}: return false
    parent = parent.parentDir
  let absolute = repo / path
  let info = pathInfo(absolute)
  if not info.exists: return entry.mode.len == 0
  if entry.mode.len == 0:
    return info.info.kind == pcDir
  if entry.mode notin ["100644", "100755", "120000"]:
    return false # Submodule state is not a blob proof.
  var content: string
  if entry.mode == "120000":
    if info.info.kind notin {pcLinkToFile, pcLinkToDir}: return false
    content = expandSymlink(absolute)
  else:
    if info.info.kind != pcFile or info.info.isSpecial: return false
    when not defined(windows):
      let mode = if fpUserExec in info.info.permissions: "100755" else: "100644"
      if mode != entry.mode: return false
    # Windows has no filesystem executable bit. Nim's permissions synthesize
    # fpUserExec for every file, so only the independently checked Git index
    # carries executable mode there. Content and physical type still must match.
    content = readFile(absolute)
  # Raw bytes intentionally reject checkouts transformed by filters when they
  # cannot be proved identical. A false negative retains local work; a false
  # positive would recommend a destructive reset.
  content == inspect(identity, repo, ["cat-file", "blob", entry.oid])

proc isInterruptedFastForward*(identity: GitToolIdentity; repo, head,
                               target: string): bool =
  ## True only for a strictly behind checkout whose differing index and
  ## worktree paths each already carry the target's content, type and mode.
  ## Ignored collisions and all inspection errors fail closed. The caller
  ## must leave this state untouched and name a manual reset to `target`.
  if head.len == 0 or target.len == 0 or head == target: return false
  try:
    if inspect(identity, repo,
        ["rev-parse", "--verify", target & "^{commit}"]).strip() != target:
      return false # Recovery advice must name an immutable, fully resolved SHA.
    if inspect(identity, repo, ["rev-parse", "--verify", "HEAD"]).strip() != head:
      return false
    discard inspect(identity, repo, ["merge-base", "--is-ancestor", head, target])
    let before = tree(identity, repo, head)
    let after = tree(identity, repo, target)
    var index: Table[string, TreeEntry]
    for record in records(inspect(identity, repo, ["ls-files", "--stage", "-z"])):
      let tab = record.find('\t')
      if tab <= 0: return false
      let fields = record[0 ..< tab].split(' ')
      if fields.len != 3 or fields[2] != "0": return false
      index[record[tab + 1 .. ^1]] = TreeEntry(mode: fields[0], oid: fields[1])
    # Diff cannot supply complete evidence when these flags hide changes.
    for record in records(inspect(identity, repo, ["ls-files", "-v", "-z"])):
      if not record.startsWith("H "): return false

    var paths = initHashSet[string]()
    for path, entry in before:
      if index.getOrDefault(path) != entry: paths.incl(path)
    for path, entry in index:
      if before.getOrDefault(path) != entry: paths.incl(path)
    for path in records(inspect(identity, repo, ["-c", "core.filemode=true",
        "diff", "--no-ext-diff", "--no-renames", "--ignore-submodules=none",
        "--name-only", "-z", head, "--"])):
      paths.incl(path)
    let untracked = records(inspect(identity, repo,
      ["ls-files", "--others", "--exclude-standard", "-z"]))
    for path in untracked: paths.incl(path)
    if paths.len == 0: return false

    # reset --hard may delete ignored files or directories that obstruct a
    # target path, even though status and the ordinary untracked query omit
    # them. Refuse both ancestor and descendant collisions.
    var targetDirectories = initHashSet[string]()
    for path in after.keys:
      var parent = path.parentDir
      while parent.len > 0 and parent != ".":
        targetDirectories.incl(parent)
        parent = parent.parentDir
    for ignored in records(inspect(identity, repo,
        ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"])):
      if ignored in targetDirectories: return false
      var path = ignored
      while path.len > 0 and path != ".":
        if after.hasKey(path): return false
        path = path.parentDir

    var changed = false
    for path in paths:
      let oldEntry = before.getOrDefault(path)
      let newEntry = after.getOrDefault(path)
      let indexEntry = index.getOrDefault(path)
      if oldEntry == newEntry: return false
      if indexEntry != oldEntry and indexEntry != newEntry: return false
      let atOld = worktreeMatches(identity, repo, path, oldEntry)
      let atNew = worktreeMatches(identity, repo, path, newEntry)
      if not atOld and not atNew: return false
      # An untracked addition is not a HEAD-relative absence: a staged
      # deletion followed by recreating the old file must also match target.
      if path in untracked and not atNew: return false
      if indexEntry != oldEntry or not atOld: changed = true
    return changed and
      inspect(identity, repo, ["rev-parse", "--verify", "HEAD"]).strip() == head
  except CatchableError:
    return false
