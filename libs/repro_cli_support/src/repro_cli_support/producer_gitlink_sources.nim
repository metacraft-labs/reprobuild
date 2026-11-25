## Required gitlink source artifacts for a consumed Nim library
## (Cross-Repo-Source-Consumption §4.2a.2a).
##
## A Nim library may declare, in its ``library`` body, gitlinks its exported
## source cannot be compiled without::
##
##   library isonim:
##     sourceGitlinks:
##       "src/isonim/layout/yoga"
##
## A consumer of such a library is not handed the producer's ``src/`` as it
## is: an uninitialized submodule is an empty directory there. Instead this
## module composes an OWNED, read-only source artifact -- the exported Nim
## tree with each required Git tree at its declared place -- and the splice
## projects that artifact's exported root onto ``aux.nimPathDirs``, so a
## ``currentSourcePath``-relative include sees the vendored tree beside the
## Nim file that includes it.
##
## The operations here are FIXED. Nothing a recipe supplies is executed: no
## producer build, default or test collection, no action, script or pool.
## What runs is read-only ``git`` plumbing against the selected source
## (``rev-parse``, ``ls-tree``, ``ls-files``, ``config --blob``,
## ``cat-file``, ``status`` on the engine's own fetched checkout), the
## engine's existing pinned-revision fetch (passed in as ``acquire``), and a
## file copy. No hook runs (no command here triggers one), no branch is
## tracked, no checkout of the producer or of its submodule is created or
## changed, and no Git configuration is written.
##
## Two views of a required gitlink, as the spec's "Develop and dirty source
## semantics" defines them:
##
## * INITIALIZED (its directory holds a ``.git``): a develop view. Its
##   actual working files are snapshotted, dirty edits included, and the
##   descriptor records the submodule's actual HEAD and whether it, the
##   index or ``.gitmodules`` disagree with the committed superproject. That
##   is recorded, never called lock-equivalent.
## * UNINITIALIZED: acquired at exactly the commit the COMMITTED gitlink
##   names, from the URL the COMMITTED ``.gitmodules`` binds to it. An
##   uncommitted change to either authority refuses acquisition with a
##   precise message instead of being ignored, reset or fetched as an
##   unidentified revision.
##
## Nested gitlinks are not followed: one inside a required tree that is not
## already initialized refuses the projection.
##
## Snapshot consistency. The exported tree is digested (``treeContentDigest``)
## before it is copied, its copy is digested under the same label, and the
## source is digested again afterwards together with every Git authority
## that was read. Any disagreement refuses the build: the source changed
## while it was being snapshotted, and mixing generations is never served.

import std/[algorithm, os, strtabs, strutils]
when defined(posix):
  import std/posix

import repro_core/ambient_execution
import repro_core/file_lock
import repro_core/git_separated
import repro_core/link_target
import repro_core/paths
import repro_core/process_env
import repro_project_dsl
import git_tool
import ./producer_channel_content

const
  GitlinkSourceArtifactVersion* = "reprobuild.gitlink-source-artifact.v1"
    ## Leads every descriptor. It names the composition semantics (what is
    ## copied, how the gitlink is resolved), so changing them retires every
    ## artifact composed before.
  GitlinkSourceCompositionChannelTag* = "gitlink-source-composition.v1"
    ## Folded into the producer-channel identity of a selector whose Nim
    ## root is a composed artifact (§4.2a.2a "Identity and invalidation").

type
  GitlinkSourceError* = object of OSError
    ## A required gitlink could not be validated, resolved or composed. It is
    ## raised before any consumer compile runs and is never a fallback.

  GitlinkAcquire* = proc (name, url, commit: string): string {.closure.}
    ## The engine's authenticated pinned-revision Git acquisition: fetch
    ## exactly ``commit`` from ``url`` into a checkout the engine owns and
    ## return its root, raising when the commit cannot be obtained.

  ComposedLibrarySource* = object
    exportedRoot*: string
      ## The composed artifact's exported root: what ``nimPathDirs`` gets.
    artifactDir*: string
      ## The owned artifact directory (mirrors the producer's layout).
    descriptor*: string
      ## The full descriptor text the artifact was composed for.
    reused*: bool
      ## The existing artifact already matched the descriptor.
    notes*: seq[string]
      ## Honest records about a develop view (a submodule HEAD that differs
      ## from the committed gitlink, for one), for the build log.

  GitlinkView = enum
    gvAcquired   ## uninitialized; acquired at the committed gitlink
    gvDevelop    ## initialized local Git source; its working files

  ResolvedGitlink = object
    relativePath: string
    url: string
    committedCommit: string
    view: GitlinkView
    actualHead: string
    tree: string
    sourceDir: string
    authorityNote: string

proc refuse(selector, library, detail: string) {.noreturn.} =
  raise newException(GitlinkSourceError,
    "cross-repo producer \"" & selector & "\" library \"" & library &
    "\" sourceGitlinks: " & detail)

proc gitEnv(): StringTableRef =
  ## The caller's environment minus Git's repository-local bindings and the
  ## loader controls (the same scrub as the pinned-producer fetch), with
  ## optional locks off so no read here refreshes an index.
  result = scrubbedGitRepositoryEnv()
  dropLoaderControls(result)
  result["GIT_OPTIONAL_LOCKS"] = "0"
  result["GIT_TERMINAL_PROMPT"] = "0"

type GitRunner = object
  bin: string
  env: StringTableRef

proc run(git: GitRunner; repo: string; args: openArray[string]):
    tuple[code: int; output: string; diagnostic: string] =
  gitRunSeparated(git.bin, @["-C", repo] & @args, git.env)

proc sameDir(a, b: string): bool =
  try: sameFile(a, b)
  except OSError: false

proc ownsRepository(git: GitRunner; dir: string): bool =
  ## ``dir`` is the top of its own Git work tree. Discovery would otherwise
  ## answer for an enclosing repository (a producer checkout placed inside a
  ## workspace repository, or an empty submodule directory inside its
  ## superproject).
  let top = git.run(dir, ["rev-parse", "--show-toplevel"])
  top.code == 0 and sameDir(top.output.strip(), dir)

proc normalizedExportedRel(exportedPath: string): string =
  ## The library's exported root as a repository-relative path, "" for the
  ## repository root.
  result = exportedPath.replace('\\', '/')
  while result.startsWith("./"):
    result = result[2 .. ^1]
  while result.len > 0 and result[^1] == '/':
    result.setLen(result.len - 1)
  if result == ".":
    result = ""

proc lexicallyInside(path, root: string): bool =
  root.len == 0 or path.startsWith(root & "/")

proc refuseSymlinkComponents(selector, library, producerRoot, rel: string) =
  ## Every component of ``rel`` below the producer root must be a real
  ## directory, never a link: a link would let a declared path resolve
  ## outside the exported root (or outside the repository).
  var current = producerRoot
  for part in rel.split('/'):
    current = current / part
    if symlinkExists(extendedPath(current)):
      refuse(selector, library, "'" & rel & "' resolves through the " &
        "symbolic link " & current & "; a required gitlink and its exported " &
        "root must be real directories (symlink escape refused)")

proc gitmodulesEntryFor(git: GitRunner; selector, library, repo,
                        configSource, path: string;
                        configArgs: seq[string]): tuple[name, url: string] =
  ## The single ``.gitmodules`` entry whose ``path`` is ``path`` in the
  ## configuration ``configArgs`` selects (``--blob=HEAD:.gitmodules``).
  let listed = git.run(repo, @["config"] & configArgs &
    @["-z", "--get-regexp", "^submodule\\..*\\.path$"])
  if listed.code notin [0, 1]:
    refuse(selector, library, "the " & configSource & " cannot be read: " &
      listed.diagnostic)
  var names: seq[string] = @[]
  for record in listed.output.split('\0'):
    if record.len == 0:
      continue
    let nl = record.find('\n')
    if nl < 0:
      continue
    let key = record[0 ..< nl]
    let value = record[nl + 1 .. ^1]
    if value.strip(chars = {'/'}) == path and key.len > "submodule..path".len:
      names.add(key["submodule.".len ..< key.len - ".path".len])
  if names.len == 0:
    refuse(selector, library, "'" & path & "' has no entry in the " &
      configSource & "; a required gitlink must be bound to exactly one " &
      "submodule there")
  if names.len > 1:
    refuse(selector, library, "'" & path & "' is bound by " & $names.len &
      " entries in the " & configSource & " (" & names.join(", ") &
      "); it must be bound by exactly one")
  let url = git.run(repo, @["config"] & configArgs &
    @["--get", "submodule." & names[0] & ".url"])
  if url.code != 0 or url.output.strip().len == 0:
    refuse(selector, library, "the " & configSource & " entry '" &
      names[0] & "' for '" & path & "' names no url")
  (name: names[0], url: url.output.strip())

proc normalizedUrl(url: string): string =
  result = url.strip()
  while result.len > 1 and result[^1] == '/':
    result.setLen(result.len - 1)

proc gitlinkEntry(git: GitRunner; repo, treeish, path: string):
    tuple[found: bool; mode, kind, sha: string] =
  ## The ``ls-tree`` entry of ``path`` in ``treeish``.
  let listed = git.run(repo, ["ls-tree", "-z", treeish, "--", path])
  if listed.code != 0:
    return
  for record in listed.output.split('\0'):
    let tab = record.find('\t')
    if tab < 0 or record[tab + 1 .. ^1] != path:
      continue
    let fields = record[0 ..< tab].splitWhitespace()
    if fields.len == 3:
      return (true, fields[0], fields[1], fields[2])

proc indexEntry(git: GitRunner; repo, path: string):
    tuple[found: bool; mode, sha: string] =
  let listed = git.run(repo, ["ls-files", "-s", "-z", "--", path])
  if listed.code != 0:
    return
  for record in listed.output.split('\0'):
    let tab = record.find('\t')
    if tab < 0 or record[tab + 1 .. ^1] != path:
      continue
    let fields = record[0 ..< tab].splitWhitespace()
    if fields.len >= 2:
      return (true, fields[0], fields[1])

proc nestedGitlinks(git: GitRunner; repo: string; fromIndex: bool):
    seq[string] =
  ## Paths of the gitlinks inside ``repo`` -- its index for a develop view,
  ## its committed tree for an acquired one.
  let listed =
    if fromIndex: git.run(repo, ["ls-files", "-s", "-z"])
    else: git.run(repo, ["ls-tree", "-r", "-z", "HEAD"])
  if listed.code != 0:
    return
  for record in listed.output.split('\0'):
    let tab = record.find('\t')
    if tab < 0:
      continue
    let fields = record[0 ..< tab].splitWhitespace()
    if fields.len >= 1 and fields[0] == "160000":
      result.add(record[tab + 1 .. ^1])

proc dirIsEmpty(dir: string): bool =
  for _ in walkDir(extendedPath(dir)):
    return false
  true

proc headCommit(git: GitRunner; repo: string): string =
  let head = git.run(repo, ["rev-parse", "--verify", "--quiet",
    "--end-of-options", "HEAD^{commit}"])
  if head.code == 0: head.output.strip() else: ""

proc fileBytes(path: string): string =
  try:
    if fileExists(extendedPath(path)): readFile(extendedPath(path))
    else: "\0<absent>"
  except CatchableError as err:
    "\0<unreadable:" & err.msg & ">"

proc authoritySnapshot(git: GitRunner; producerRoot: string;
                       requirements: openArray[GitlinkSourceRequirement]):
    string =
  ## Every Git authority a composition reads, as one comparable string: the
  ## producer HEAD, both ``.gitmodules`` versions, and for each required
  ## gitlink its committed and index entries and its submodule HEAD. Taken
  ## before and after the copy; a difference is a concurrent change.
  result = "head=" & headCommit(git, producerRoot) & "\0"
  let committedModules = git.run(producerRoot,
    ["cat-file", "blob", "HEAD:.gitmodules"])
  result.add("committed-gitmodules=" & $committedModules.code & ":" &
    committedModules.output & "\0")
  result.add("working-gitmodules=" &
    fileBytes(producerRoot / ".gitmodules") & "\0")
  let stagedModules = indexEntry(git, producerRoot, ".gitmodules")
  result.add("staged-gitmodules=" & stagedModules.sha & "\0")
  for req in requirements:
    let committed = gitlinkEntry(git, producerRoot, "HEAD", req.relativePath)
    let staged = indexEntry(git, producerRoot, req.relativePath)
    let subDir = producerRoot / req.relativePath
    let subHead =
      if dirExists(extendedPath(subDir / ".git")) or
          fileExists(extendedPath(subDir / ".git")):
        headCommit(git, subDir)
      else: ""
    result.add(req.relativePath & ":" & committed.mode & ":" &
      committed.sha & ":" & staged.mode & ":" & staged.sha & ":" & subHead &
      "\0")

proc resolveGitlink(git: GitRunner; selector, library, producerRoot,
                    exportedRel: string; req: GitlinkSourceRequirement;
                    acquire: GitlinkAcquire): ResolvedGitlink =
  let path = req.relativePath
  result.relativePath = path
  let committed = gitlinkEntry(git, producerRoot, "HEAD", path)
  if not committed.found:
    refuse(selector, library, "'" & path & "' names no entry in the " &
      "selected source's committed tree (" & producerRoot & ")")
  if committed.mode != "160000" or committed.kind != "commit":
    refuse(selector, library, "'" & path & "' is a " & committed.kind &
      " (mode " & committed.mode & ") in the selected source's committed " &
      "tree, not a gitlink")
  result.committedCommit = committed.sha
  let committedModules = gitmodulesEntryFor(git, selector, library,
    producerRoot, "committed .gitmodules", path,
    @["--blob=HEAD:.gitmodules"])
  let url = normalizedUrl(committedModules.url)
  if url.startsWith("./") or url.startsWith("../"):
    refuse(selector, library, "'" & path & "' is bound to the relative " &
      "url '" & url & "' in the committed .gitmodules; a relative url names " &
      "no repository without the superproject's remote, and the remote is " &
      "not an authority this resolution may consult")
  result.url = url

  let subDir = producerRoot / path
  let initialized = dirExists(extendedPath(subDir / ".git")) or
    fileExists(extendedPath(subDir / ".git"))
  let staged = indexEntry(git, producerRoot, path)
  let stagedModules = indexEntry(git, producerRoot, ".gitmodules")
  let committedModulesBlob = gitlinkEntry(git, producerRoot, "HEAD",
    ".gitmodules")
  let committedModulesBytes = git.run(producerRoot,
    ["cat-file", "blob", "HEAD:.gitmodules"]).output
  let workingModulesChanged =
    fileBytes(producerRoot / ".gitmodules") != committedModulesBytes
  let stagedModulesChanged = stagedModules.sha != committedModulesBlob.sha
  let stagedLinkChanged = not staged.found or staged.mode != "160000" or
    staged.sha != committed.sha

  if initialized:
    # A develop view: the developer's actual submodule checkout.
    if not ownsRepository(git, subDir):
      refuse(selector, library, "'" & path & "' holds a .git entry but is " &
        "not the top of its own Git work tree")
    result.view = gvDevelop
    result.actualHead = headCommit(git, subDir)
    if result.actualHead.len == 0:
      refuse(selector, library, "the initialized submodule at " & subDir &
        " has no HEAD commit")
    var mismatches: seq[string] = @[]
    if result.actualHead != committed.sha:
      mismatches.add("submodule HEAD " & result.actualHead &
        " differs from the committed gitlink " & committed.sha)
    if stagedLinkChanged:
      mismatches.add("the index records " &
        (if staged.found: staged.sha else: "no entry") &
        " for the gitlink")
    if workingModulesChanged or stagedModulesChanged:
      mismatches.add(".gitmodules has uncommitted changes")
    if mismatches.len > 0:
      result.authorityNote = "develop view of '" & path & "' is not the " &
        "committed source: " & mismatches.join("; ") &
        " (snapshotted as found; not lock-equivalent)"
    for nested in nestedGitlinks(git, subDir, fromIndex = true):
      let nestedDir = subDir / nested
      if not (dirExists(extendedPath(nestedDir / ".git")) or
          fileExists(extendedPath(nestedDir / ".git"))):
        refuse(selector, library, "the nested gitlink '" & path & "/" &
          nested & "' is not initialized; nested gitlinks are not acquired " &
          "implicitly, so the projection is refused")
    result.sourceDir = subDir
    let tree = git.run(subDir, ["rev-parse", "--verify", "--quiet",
      "--end-of-options", "HEAD^{tree}"])
    result.tree = tree.output.strip()
    return

  # Uninitialized: only the committed authority may drive acquisition.
  if workingModulesChanged or stagedModulesChanged:
    refuse(selector, library, "'" & path & "' is not initialized and " &
      ".gitmodules in " & producerRoot & " has uncommitted changes; " &
      "missing-source acquisition uses only the committed .gitmodules. " &
      "Commit or revert the change, or initialize the submodule to supply " &
      "a develop view")
  if stagedLinkChanged:
    refuse(selector, library, "'" & path & "' is not initialized and the " &
      "index of " & producerRoot & " records " &
      (if staged.found: staged.mode & " " & staged.sha else: "no entry") &
      " for it while the committed gitlink is " & committed.sha &
      "; missing-source acquisition uses only the committed gitlink. " &
      "Commit or revert the change, or initialize the submodule to supply " &
      "a develop view")
  if dirExists(extendedPath(subDir)) and not dirIsEmpty(subDir):
    refuse(selector, library, "'" & path & "' is not an initialized Git " &
      "checkout but its directory " & subDir & " is not empty; refusing to " &
      "replace files whose revision cannot be identified")
  result.view = gvAcquired
  let acquiredRoot =
    try:
      acquire(".gitlink-sources/" & url.multiReplace(
        ("://", "_"), ("/", "_"), (":", "_"), ("@", "_")),
        url, committed.sha)
    except CatchableError as err:
      refuse(selector, library, "'" & path & "' could not be acquired at " &
        "commit " & committed.sha & " from " & url & ": " & err.msg)
  if acquiredRoot.len == 0 or not ownsRepository(git, acquiredRoot):
    refuse(selector, library, "'" & path & "' was not acquired into a Git " &
      "checkout of its own (" & url & " at " & committed.sha & ")")
  let acquiredHead = headCommit(git, acquiredRoot)
  if acquiredHead != committed.sha:
    refuse(selector, library, "the acquired source of '" & path & "' is at " &
      acquiredHead & ", not the committed gitlink " & committed.sha)
  # Source-tree integrity: the acquired working files must be exactly the
  # commit's tree (nothing modified, deleted or added since the fetch).
  let status = git.run(acquiredRoot, ["status", "--porcelain=v1", "-z",
    "--untracked-files=all", "--ignore-submodules=none"])
  if status.code != 0:
    refuse(selector, library, "the acquired source of '" & path & "' at " &
      acquiredRoot & " cannot be verified: " & status.diagnostic)
  if status.output.len > 0:
    refuse(selector, library, "the acquired source of '" & path & "' at " &
      acquiredRoot & " does not match commit " & committed.sha &
      " (its working tree differs); remove that directory to re-acquire it")
  let nested = nestedGitlinks(git, acquiredRoot, fromIndex = false)
  if nested.len > 0:
    refuse(selector, library, "'" & path & "' at " & committed.sha &
      " contains the nested gitlink(s) " & nested.join(", ") &
      "; nested gitlinks are not acquired implicitly, so the projection is " &
      "refused")
  result.actualHead = acquiredHead
  result.tree = git.run(acquiredRoot, ["rev-parse", "--verify", "--quiet",
    "--end-of-options", "HEAD^{tree}"]).output.strip()
  result.sourceDir = acquiredRoot

# ---------------------------------------------------------------------------
# Copying. Regular files keep their owner-executable bit, directories are
# recreated, ``.git`` entries are skipped (VCS metadata; a submodule's
# ``.git`` FILE names a directory of the developer's superproject), and a
# symbolic link is recreated verbatim only when it is relative and resolves
# inside the tree being copied. An absolute or escaping link is refused:
# copying it would hand the consumer bytes from outside the source.
# ---------------------------------------------------------------------------

proc lexicalJoin(baseRel, target: string): tuple[ok: bool; path: string] =
  var parts: seq[string] = @[]
  if baseRel.len > 0:
    parts = baseRel.split('/')
  for part in target.split('/'):
    case part
    of "", ".": discard
    of "..":
      if parts.len == 0:
        return (false, "")
      parts.setLen(parts.len - 1)
    else: parts.add(part)
  (true, parts.join("/"))

proc copyTree(selector, library, src, dst, treeLabel: string; rel = "") =
  createDir(extendedPath(dst))
  var names: seq[string] = @[]
  for _, name in walkDir(extendedPath(src), relative = true, checkDir = true):
    names.add(name)
  names.sort()
  for name in names:
    if name == ".git":
      continue
    let s = src / name
    let d = dst / name
    let childRel = if rel.len == 0: name else: rel & "/" & name
    if symlinkExists(extendedPath(s)):
      let target = readSymlinkTarget(s)
      if target.len == 0 or target.startsWith("/") or target.contains('\\') or
          (target.len >= 2 and target[1] == ':'):
        refuse(selector, library, "the symbolic link " & s & " -> " & target &
          " in " & treeLabel & " is absolute (symlink escape refused)")
      let joined = lexicalJoin(rel, target)
      if not joined.ok:
        refuse(selector, library, "the symbolic link " & s & " -> " & target &
          " leaves " & treeLabel & " (symlink escape refused)")
      createSymlink(target, d)
    elif dirExists(extendedPath(s)):
      copyTree(selector, library, s, d, treeLabel, childRel)
    elif fileExists(extendedPath(s)):
      copyFileWithPermissions(extendedPath(s), extendedPath(d))
    else:
      refuse(selector, library, s & " in " & treeLabel & " is neither a " &
        "file, a directory nor a symbolic link")

proc setTreeWritable(dir: string; writable: bool) =
  ## Make an owned artifact read-only once composed (and writable again only
  ## to replace or remove it). Links are left alone: their own mode is
  ## meaningless and changing it would follow them.
  if not dirExists(extendedPath(dir)) or symlinkExists(extendedPath(dir)):
    return
  when defined(posix):
    proc apply(path: string; isDir: bool) =
      var st: Stat
      if lstat(path.cstring, st) != 0 or S_ISLNK(st.st_mode):
        return
      var mode = int(st.st_mode) and 0o7777
      if writable:
        mode = mode or 0o200
        if isDir: mode = mode or 0o700
      else:
        mode = mode and not 0o222
      discard chmod(path.cstring, Mode(mode))
    if writable:
      apply(dir, true)
    for kind, path in walkDir(extendedPath(dir)):
      case kind
      of pcDir: setTreeWritable(path, writable)
      of pcFile: apply(path, false)
      else: discard
    if not writable:
      apply(dir, true)
  else:
    discard writable

proc removeOwnedTree(dir: string) =
  if dirExists(extendedPath(dir)) and not symlinkExists(extendedPath(dir)):
    setTreeWritable(dir, true)
    removeDir(extendedPath(dir))

proc digestOf(selector, library, label, dir: string): string =
  let content = treeContentDigest(label, dir)
  if not content.complete:
    refuse(selector, library, "the source tree " & dir & " cannot be read " &
      "completely (" & content.failure & ")")
  content.digest

proc composeGitlinkSourceArtifact*(selector, library, producerRootAbs,
                                   exportedPath: string;
                                   requirements: openArray[GitlinkSourceRequirement];
                                   artifactDir: string;
                                   acquire: GitlinkAcquire):
    ComposedLibrarySource =
  ## Validate ``requirements`` against the producer source at
  ## ``producerRootAbs``, resolve each gitlink (develop view or acquisition
  ## at the committed gitlink), and compose the owned read-only artifact at
  ## ``artifactDir``: the producer's exported tree at ``<artifactDir>/<exported>``
  ## with every required tree at its declared place. Reuses an existing
  ## artifact only when its descriptor and content both still match.
  ## Raises ``GitlinkSourceError`` (before any consumer compile) on every
  ## refusal the spec names; never falls back to the uncomposed tree.
  let gitBin = uncontrolledFindExe("git")
  if gitBin.len == 0:
    refuse(selector, library, "no `git` binary is on PATH, so the required " &
      "gitlinks cannot be resolved")
  let git = GitRunner(bin: gitBin, env: gitEnv())
  let producerRoot = absolutePath(producerRootAbs)
  let exportedRel = normalizedExportedRel(exportedPath)
  if exportedRel.len > 0:
    let problem = gitlinkRequirementPathProblem(exportedRel)
    if problem.len > 0:
      refuse(selector, library, "the exported root '" & exportedPath & "' " &
        problem)
  if not ownsRepository(git, producerRoot):
    refuse(selector, library, "the selected source " & producerRoot &
      " carries no Git metadata of its own, so the gitlink commits and " &
      ".gitmodules cannot be derived from it")

  # Scope rule 1: lexical shape, inside the exported root, no duplicates or
  # portable case collisions, no symlink components.
  var seen: seq[string] = @[]
  for req in requirements:
    let problem = gitlinkRequirementPathProblem(req.relativePath)
    if problem.len > 0:
      refuse(selector, library, "'" & req.relativePath & "' " & problem)
    if not lexicallyInside(req.relativePath, exportedRel):
      refuse(selector, library, "'" & req.relativePath & "' is not inside " &
        "the library's exported root '" &
        (if exportedRel.len == 0: "." else: exportedRel) & "'")
    let key = gitlinkPortableCaseKey(req.relativePath)
    if key in seen:
      refuse(selector, library, "'" & req.relativePath & "' is declared " &
        "twice (compared case-insensitively)")
    for other in seen:
      if key.startsWith(other & "/") or other.startsWith(key & "/"):
        refuse(selector, library, "'" & req.relativePath & "' and another " &
          "declared gitlink are nested in each other")
    seen.add(key)
    if exportedRel.len > 0:
      refuseSymlinkComponents(selector, library, producerRoot, exportedRel)
    refuseSymlinkComponents(selector, library, producerRoot, req.relativePath)

  let exportedSource =
    if exportedRel.len == 0: producerRoot else: producerRoot / exportedRel
  if not dirExists(extendedPath(exportedSource)):
    refuse(selector, library, "the exported root " & exportedSource &
      " does not exist")

  let authorityBefore = authoritySnapshot(git, producerRoot, requirements)
  var resolved: seq[ResolvedGitlink] = @[]
  for req in requirements:
    resolved.add(resolveGitlink(git, selector, library, producerRoot,
      exportedRel, req, acquire))

  let sourceDigest = digestOf(selector, library, "exported", exportedSource)
  var descriptor = GitlinkSourceArtifactVersion & "\n" &
    "selector=" & selector & "\n" & "library=" & library & "\n" &
    "exported=" & exportedRel & "\n" &
    "source-root=" & producerRoot & "\n" &
    "source-head=" & headCommit(git, producerRoot) & "\n" &
    "source-content=" & sourceDigest & "\n"
  for link in resolved:
    descriptor.add("gitlink path=" & link.relativePath & " url=" & link.url &
      " committed=" & link.committedCommit & " view=" &
      (if link.view == gvAcquired: "acquired" else: "develop") &
      " head=" & link.actualHead & " tree=" & link.tree & "\n")
    if link.authorityNote.len > 0:
      result.notes.add(link.authorityNote)
  result.descriptor = descriptor
  result.artifactDir = artifactDir
  result.exportedRoot =
    if exportedRel.len == 0: artifactDir else: artifactDir / exportedRel

  let descriptorPath = artifactDir & ".descriptor"
  var lock = acquireExclusiveFileLock(artifactDir & ".compose.lock")
  defer: releaseExclusiveFileLock(lock)

  # Reuse: same descriptor AND the artifact still holds what was composed.
  if fileExists(extendedPath(descriptorPath)) and
      dirExists(extendedPath(artifactDir)):
    let recorded = readFile(extendedPath(descriptorPath))
    let marker = "\nartifact-content="
    let at = recorded.rfind(marker)
    if at >= 0 and recorded[0 .. at] == descriptor:
      let recordedDigest = recorded[at + marker.len .. ^1].strip()
      let current = treeContentDigest("artifact", artifactDir)
      if current.complete and current.digest == recordedDigest:
        result.reused = true
        return

  let staging = artifactDir & ".staging-" & $getCurrentProcessId()
  removeOwnedTree(staging)
  var published = false
  try:
    let stagedExported =
      if exportedRel.len == 0: staging else: staging / exportedRel
    createDir(extendedPath(parentDir(stagedExported)))
    copyTree(selector, library, exportedSource, stagedExported,
      "the exported root " & exportedSource)
    # The copy must be the tree that was digested, and the source must not
    # have moved underneath it.
    let copiedDigest = digestOf(selector, library, "exported", stagedExported)
    for link in resolved:
      if link.view != gvAcquired:
        continue
      let target = staging / link.relativePath
      if dirExists(extendedPath(target)):
        if not dirIsEmpty(target):
          refuse(selector, library, "the composed location of '" &
            link.relativePath & "' is not empty")
        removeDir(extendedPath(target))
      copyTree(selector, library, link.sourceDir, target,
        "the acquired source of '" & link.relativePath & "'")
    let sourceDigestAfter = digestOf(selector, library, "exported",
      exportedSource)
    let authorityAfter = authoritySnapshot(git, producerRoot, requirements)
    if copiedDigest != sourceDigest or sourceDigestAfter != sourceDigest or
        authorityAfter != authorityBefore:
      refuse(selector, library, "the selected source " & producerRoot &
        " changed while it was being snapshotted; nothing was composed. " &
        "Run the build again once the source is stable")
    let artifactDigest = digestOf(selector, library, "artifact", staging)
    setTreeWritable(staging, false)
    # Replace the previous artifact, if any, with the staged one.
    let retired = artifactDir & ".retired-" & $getCurrentProcessId()
    removeOwnedTree(retired)
    if dirExists(extendedPath(artifactDir)) or
        symlinkExists(extendedPath(artifactDir)):
      if symlinkExists(extendedPath(artifactDir)):
        removeFile(extendedPath(artifactDir))
      else:
        setTreeWritable(artifactDir, true)
        moveDir(extendedPath(artifactDir), extendedPath(retired))
    if fileExists(extendedPath(descriptorPath)):
      removeFile(extendedPath(descriptorPath))
    moveDir(extendedPath(staging), extendedPath(artifactDir))
    published = true
    writeFile(extendedPath(descriptorPath),
      descriptor & "artifact-content=" & artifactDigest & "\n")
    removeOwnedTree(retired)
  finally:
    if not published:
      try: removeOwnedTree(staging)
      except CatchableError: discard
