## repro_workspace_manifests/manifest_source.nim
##
## WHERE workspace metadata is read from, separated from WHAT is read.
##
## The readers (`reader.nim`) validate bytes; the resolvers (`resolver.nim`,
## `project_set.nim`) walk `includes`, `member_sets`, `member_repos`,
## `url-prefixes/` and the `projects/` -> `variants/` -> `repo-sets/` ladder.
## Neither needs a filesystem: every lookup they make is "the text at this
## path relative to the manifest-repo root", "is there a file there", or "the
## `.toml` files of this directory". A `ManifestSource` answers exactly those
## three questions, rooted at the manifest-repo root (the directory holding
## `projects/`, `repos/`, `repo-sets/`, `variants/` and `url-prefixes/`).
##
## Three implementations:
##
##   * `newDirectorySource(root)` — the working tree, as it always was. Its
##     display paths are the absolute filesystem paths the path-based
##     resolvers have always reported (`root / relPath`), so every existing
##     `projectFile` / `fragmentPath` value and diagnostic is unchanged.
##
##   * `openGitRevisionSource(repository, revision)` — a COMMIT of the
##     metadata repository, read through `git ls-tree` and `git cat-file
##     --batch` against its git directory. The working tree and the index are
##     never consulted, so it works on a bare repository and on a non-bare one
##     in any state (dirty, half-deleted). It is READ-ONLY: nothing is added
##     to the repository — no worktree, no index, no refs, no objects, no
##     lazily fetched promisor objects — which is what lets a consumer resolve
##     a project set against a pinned revision of an object store it may not
##     write (reprobuild-pm issue `2026-10-09-workspace-metadata-is-readable-
##     only-from-a-working-tree`). `git worktree add --detach` would have
##     materialized the same tree, but writes `worktrees/<id>` into the git
##     dir, so it is not used. The revision is resolved ONCE, at open, to a
##     full commit id (`resolvedCommit`): a ref that moves while the source
##     is open does not change what it reads.
##
##     Display path: `<git dir>@<first 12 hex of the commit>:<relPath>`, e.g.
##     `/ws/.git@0123456789ab:repos/foo.toml`. It names the revision a
##     diagnostic was raised against, which a filesystem path cannot.
##
##   * `newOverlaySource(base, relPath, content)` — `base` with ONE file
##     replaced (or added) in memory. It is how `resolveProjectFromString` /
##     `resolveVariantFromString` resolve a manifest body supplied as a string
##     against the fragments of a real tree without writing that body into
##     the tree.
##
## Symlinks
## --------
##
## A directory source follows the operating system, exactly as `fileExists` /
## `readFile` always did. A git source reads link BYTES (mode `120000`) and
## resolves them itself, under the rule CLI/workspace.md §"`repro workspace
## restore`" states for metadata at a revision: a link must resolve inside the
## committed tree. An absolute target, a target that climbs above the tree
## root, a target that names the root `.git`, a dangling target and a cycle
## (more than `maxSymlinkHops` links followed for one path, the POSIX
## `SYMLOOP_MAX` floor) are refused with a `WorkspaceManifestParseError`
## rather than reported as "absent": a link that does not resolve is a defect
## of the committed metadata, and treating it as a missing file would let a
## lookup ladder silently fall through to a different manifest. Links are
## resolved component by component, so a symlinked DIRECTORY
## (`repos -> shared/repos`) is followed too. A gitlink (mode `160000`, a
## submodule) and a tree are not files.
##
## Lifetime
## --------
##
## A git source owns one long-lived `git cat-file --batch` child, started on
## the first read. `close` ends it; callers that open a source close it
## (`defer: source.close()`). A source that is never closed leaves the child
## blocked on its stdin until this process exits, when the pipe closes and
## it exits too — wasteful, never incorrect.

import std/[algorithm, options, os, osproc, streams, strtabs, strutils, tables]

import diagnostics
import git_tool
import repro_core/ambient_execution
import repro_core/process_close

const
  maxSymlinkHops* = 40
    ## Links followed while resolving ONE path before it is refused as a
    ## cycle. 40 is Linux's `MAXSYMLINKS` and above POSIX's `_POSIX_SYMLOOP_MAX`
    ## (8), so any chain a filesystem checkout of the same tree would follow is
    ## followed here too.
  shortCommitLen = 12
    ## Hex digits of the commit a git source's display path carries: enough to
    ## be unambiguous in any realistic metadata repository, short enough to
    ## keep a diagnostic readable.
  gitModeSymlink = "120000"
  gitModeGitlink = "160000"

type
  ManifestSourceKind* = enum
    mskDirectory    ## a directory on disk (the working tree)
    mskGitRevision  ## one commit of a git repository, read from its objects
    mskOverlay      ## another source with one file supplied in memory

  GitTreeEntry = object
    ## One `git ls-tree -r -t` record: `<mode> SP <type> SP <oid> TAB <path>`.
    mode, kind, oid: string

  ManifestSource* = ref object
    ## A read-only view of a manifest-repo root. See the module comment.
    case kind*: ManifestSourceKind
    of mskDirectory:
      root: string
        ## Absolute; `displayPath` joins relative paths onto it verbatim.
    of mskGitRevision:
      gitBin: string
      gitDir: string
        ## Absolute path of the repository's git directory (a bare repository
        ## is its own git directory).
      revision: string
        ## The revision as the caller wrote it, for diagnostics.
      commit: string
        ## `revision` resolved once to a full commit id.
      entries: Table[string, GitTreeEntry]
        ## Every path of the commit's tree (blobs, links, gitlinks AND trees),
        ## loaded once at open: existence and kind checks cost no process.
      blobs: Table[string, string]
        ## oid -> content, so a manifest read twice is fetched once.
      batch: Process
        ## The `cat-file --batch` child; nil until the first blob read.
    of mskOverlay:
      base: ManifestSource
      overlayPath: string
      overlayContent: string

# ---- relative paths ---------------------------------------------------------

proc normalizeRelPath*(relPath: string): string =
  ## `relPath` in the canonical form sources key on: forward slashes, no
  ## empty or `.` components. A `..` component is kept: it is not this
  ## proc's place to resolve it (the resolvers refuse `..` in every manifest
  ## path before a source ever sees it, and a git source refuses a path that
  ## climbs above its root while it resolves).
  var parts: seq[string]
  for part in relPath.replace('\\', '/').split('/'):
    if part.len == 0 or part == ".":
      continue
    parts.add(part)
  parts.join("/")

proc relPathFor*(root, absPath: string): string =
  ## `absPath` relative to `root`, forward-slashed. Used by the path-based
  ## entry points to turn the file they were handed into a source-relative
  ## path; `absPath` is always beneath `root` there by construction (`root`
  ## is derived as its grandparent).
  normalizeRelPath(relativePath(absPath, root))

# ---- git plumbing -----------------------------------------------------------

proc gitEnv(): StringTableRef =
  ## The child environment for every git call a git source makes: the ambient
  ## environment minus git's repository-local bindings (a hook's `GIT_DIR` must
  ## not redirect the read to another repository, `git_tool.nim`), plus the
  ## switches that keep git from writing anything:
  ##
  ##   * `GIT_OPTIONAL_LOCKS=0` — no opportunistic index refresh / lock files;
  ##   * `GIT_NO_LAZY_FETCH=1` — a partial clone must not FETCH a missing blob
  ##     into its object store (git >= 2.44; older git ignores the variable,
  ##     and a missing object is then an error from `cat-file` — still no
  ##     write, because `--batch` reports it as `missing`);
  ##   * `GIT_NO_REPLACE_OBJECTS=1` — read the commit's own objects, not a
  ##     `refs/replace/` substitute, so the content is a function of the
  ##     commit id that is reported;
  ##   * `GIT_TERMINAL_PROMPT=0` — never block on a credential prompt.
  result = scrubbedGitRepositoryEnv()
  result["GIT_OPTIONAL_LOCKS"] = "0"
  result["GIT_NO_LAZY_FETCH"] = "1"
  result["GIT_NO_REPLACE_OBJECTS"] = "1"
  result["GIT_TERMINAL_PROMPT"] = "0"

proc gitArgs(gitDir: string; args: openArray[string]): seq[string] =
  ## `--git-dir` pins the repository (no discovery, no working tree);
  ## `core.fsmonitor=false` keeps a configured fsmonitor daemon from being
  ## spawned. None of the subcommands used here write, and these settings
  ## make sure no side channel does either.
  result = @["--git-dir=" & gitDir, "-c", "core.fsmonitor=false"]
  for a in args:
    result.add(a)

proc runGitCapture(gitBin: string; args: openArray[string];
                   env: StringTableRef; workingDir = ""):
    tuple[code: int; output, errors: string] =
  ## Run git with stdout and stderr captured SEPARATELY: stdout is parsed
  ## (`rev-parse`, `ls-tree -z`), and a warning git prints on stderr must not
  ## be mistaken for data. stdout is drained first; the stderr these calls
  ## produce is a line or two, far below a pipe buffer, so draining it second
  ## cannot wedge the child.
  var child: Process
  try:
    # `gitBin` is the absolute path `ensureGitToolResolvable` resolved (or the
    # caller's explicit choice), not a PATH lookup made here; the
    # `uncontrolled` spelling records that no typed execution profile wraps
    # this read-only control-plane call, exactly as `git_tool.queryGit`.
    child = uncontrolledStartProcess(gitBin, workingDir = workingDir,
      args = @args, env = env, options = {})
  except OSError as e:
    return (code: -1, output: "", errors: e.msg)
  defer: closeProcessOnce(child)
  child.inputStream.close()
  result.output = child.outputStream.readAll()
  result.errors = child.errorStream.readAll()
  result.code = child.waitForExit()

proc sourceError(path, message: string) {.noreturn.} =
  ## A source-level failure, in the package's one diagnostic shape: no key
  ## path and no schema, because nothing was decoded yet.
  raiseManifestError(path, "", "", "", message)

proc firstLine(text: string): string =
  let stripped = text.strip()
  let nl = stripped.find('\n')
  if nl < 0: stripped else: stripped[0 ..< nl]

proc openGitRevisionSource*(repository, revision: string;
                            gitBin = ""): ManifestSource =
  ## A source over the tree of `revision` in the git repository at
  ## `repository` — a bare repository (its git directory) or the top of a
  ## non-bare one. `gitBin` defaults to the `git` on `PATH`, resolved the way
  ## every other workspace git call resolves it (`git_tool.nim`).
  ##
  ## `repository` must itself BE the repository: discovery never climbs to an
  ## enclosing one (`GIT_CEILING_DIRECTORIES`), so a directory that merely
  ## sits inside some other checkout is refused rather than read against the
  ## wrong history.
  ##
  ## Raises `WorkspaceManifestParseError` when git cannot be found, when
  ## `repository` is not a git repository, and when `revision` does not
  ## resolve to a commit (unknown, or naming a tree/blob/tag of a non-commit).
  let display = repository & "@" & revision
  if revision.len == 0:
    sourceError(display, "no revision given to read the metadata at")
  if revision.startsWith("-"):
    # `rev-parse` would read it as an option; no revision name starts so.
    sourceError(display, "revision '" & revision &
      "' is not a revision name (it would be read as a git option)")
  var bin = gitBin
  if bin.len == 0:
    try:
      bin = ensureGitToolResolvable(tpmPathOnly, getEnv("PATH")).binaryPath
    except CatchableError as e:
      sourceError(display, "cannot read metadata at a revision without " &
        "git: " & e.msg)
  if not dirExists(repository):
    sourceError(display, "'" & repository & "' is not a git repository " &
      "(no such directory)")
  let env = gitEnv()
  let anchored = expandFilename(repository)
  # A git directory (a bare repository, or a checkout's `.git`) is named
  # EXPLICITLY first. Discovery would find it too, but discovery of a bare
  # repository is refused under `safe.bareRepository=explicit`
  # (git-config(1) §safe.bareRepository), a hardening setting that permits
  # exactly this: a bare repository named through `--git-dir`. `repository`
  # is the caller's explicit choice, so naming it so is what the setting asks
  # for. `--git-dir` on the top of a non-bare checkout fails ("not a git
  # repository"), and only then is it discovered.
  var found = runGitCapture(bin, gitArgs(anchored, ["rev-parse",
    "--absolute-git-dir"]), env)
  if found.code != 0 or found.output.strip().len == 0:
    var discoverEnv = newStringTable(modeCaseSensitive)
    for key, value in env.pairs:
      discoverEnv[key] = value
    # Refuse to discover upward: the ceiling is the parent, so only
    # `repository` itself (or its `.git`) can be the repository.
    discoverEnv["GIT_CEILING_DIRECTORIES"] = anchored.parentDir
    found = runGitCapture(bin, ["-c", "core.fsmonitor=false", "rev-parse",
      "--absolute-git-dir"], discoverEnv, workingDir = anchored)
  if found.code != 0 or found.output.strip().len == 0:
    sourceError(display, "'" & repository & "' is not a git repository" &
      (if found.errors.len > 0: " (" & firstLine(found.errors) & ")" else: ""))
  let gitDir = found.output.strip()
  let resolved = runGitCapture(bin, gitArgs(gitDir, ["rev-parse", "--verify",
    "--quiet", revision & "^{commit}"]), env)
  let commit = resolved.output.strip()
  if resolved.code != 0 or commit.len == 0:
    # Tell "names nothing" apart from "names something that is not a
    # commit": the second is an operator handing over a tree or blob id.
    let anyObject = runGitCapture(bin, gitArgs(gitDir, ["rev-parse",
      "--verify", "--quiet", revision]), env)
    if anyObject.code == 0:
      sourceError(gitDir & "@" & revision, "revision '" & revision &
        "' does not resolve to a commit in " & gitDir)
    sourceError(gitDir & "@" & revision, "unknown revision '" & revision &
      "' in " & gitDir)
  result = ManifestSource(kind: mskGitRevision, gitBin: bin, gitDir: gitDir,
    revision: revision, commit: commit)
  # The whole tree, once: `-r` recurses, `-t` keeps the tree entries so a
  # directory is known to exist, `-z` leaves paths unquoted, `--full-tree`
  # makes paths root-relative whatever the invocation directory.
  let listing = runGitCapture(bin, gitArgs(gitDir, ["ls-tree", "-r", "-t",
    "-z", "--full-tree", commit]), env)
  if listing.code != 0:
    sourceError(gitDir & "@" & commit, "git ls-tree failed: " &
      firstLine(listing.errors))
  for record in listing.output.split('\0'):
    if record.len == 0:
      continue
    let tab = record.find('\t')
    let fields = (if tab > 0: record[0 ..< tab] else: "").split(' ')
    if tab < 0 or fields.len != 3:
      sourceError(gitDir & "@" & commit,
        "unexpected git ls-tree record: " & record)
    result.entries[record[tab + 1 .. ^1]] =
      GitTreeEntry(mode: fields[0], kind: fields[1], oid: fields[2])

proc close*(source: ManifestSource) =
  ## End the `cat-file --batch` child of a git source (and of a git source an
  ## overlay wraps). Idempotent; a no-op for a directory source.
  if source.isNil:
    return
  case source.kind
  of mskGitRevision:
    if not source.batch.isNil:
      try:
        # EOF on stdin is how `cat-file --batch` is told to exit.
        source.batch.inputStream.close()
        discard source.batch.waitForExit()
      except CatchableError:
        discard
      closeProcessOnce(source.batch)
      source.batch = nil
  of mskOverlay:
    close(source.base)
  of mskDirectory:
    discard

proc resolvedCommit*(source: ManifestSource): string =
  ## The full commit id a git source reads (the revision resolved once at
  ## open), or "" for a source that is not a revision.
  case source.kind
  of mskGitRevision: source.commit
  of mskOverlay: resolvedCommit(source.base)
  of mskDirectory: ""

proc displayRoot*(source: ManifestSource): string =
  ## How a diagnostic names the source as a whole: the root directory, or
  ## `<git dir>@<short commit>`.
  case source.kind
  of mskDirectory: source.root
  of mskGitRevision: source.gitDir & "@" & source.commit[0 ..< min(
    shortCommitLen, source.commit.len)]
  of mskOverlay: displayRoot(source.base)

proc displayPath*(source: ManifestSource; relPath: string): string =
  ## How a diagnostic (and `ResolvedProject.projectFile` /
  ## `ResolvedRepo.fragmentPath`) names `relPath`. A directory source returns
  ## the absolute filesystem path, exactly as the path-based resolvers always
  ## have; a git source returns `<git dir>@<short commit>:<relPath>`.
  case source.kind
  of mskDirectory:
    source.root / relPath.replace('/', DirSep)
  of mskGitRevision:
    displayRoot(source) & ":" & normalizeRelPath(relPath)
  of mskOverlay:
    displayPath(source.base, relPath)

proc readBlob(source: ManifestSource; oid, relPath: string): string =
  ## The content of blob `oid`, through the persistent `cat-file --batch`
  ## child. Protocol (git-cat-file(1) §BATCH OUTPUT): request `<oid> LF`;
  ## answer `<oid> SP <type> SP <size> LF <content> LF`, or
  ## `<oid> SP missing LF`.
  if oid in source.blobs:
    return source.blobs[oid]
  if source.batch.isNil:
    try:
      source.batch = uncontrolledStartProcess(source.gitBin,
        args = gitArgs(source.gitDir, ["cat-file", "--batch"]),
        env = gitEnv(), options = {})
    except OSError as e:
      sourceError(source.displayPath(relPath),
        "cannot start git cat-file: " & e.msg)
  # Any failure below leaves the request/answer framing in an unknown state,
  # so the child is dropped (`close`) before raising: the next read starts a
  # fresh one instead of parsing the tail of this answer as its header.
  var failure = ""
  try:
    source.batch.inputStream.write(oid & "\n")
    source.batch.inputStream.flush()
    let header = source.batch.outputStream.readLine()
    let fields = header.split(' ')
    if fields.len != 3 or fields[0] != oid or fields[1] != "blob":
      failure = "git cat-file did not return blob " & oid & " (answered '" &
        header & "')"
    else:
      let size = parseInt(fields[2])
      result = source.batch.outputStream.readStr(size)
      if result.len != size:
        failure = "git cat-file returned " & $result.len & " of " & $size &
          " bytes of blob " & oid
      else:
        discard source.batch.outputStream.readChar()  # the trailing LF
  except IOError, OSError, ValueError:
    failure = "reading blob " & oid & " through git cat-file failed: " &
      getCurrentExceptionMsg()
  if failure.len > 0:
    source.close()
    sourceError(source.displayPath(relPath), failure)
  source.blobs[oid] = result

proc resolveTreePath(source: ManifestSource; relPath: string):
    Option[tuple[path: string; entry: GitTreeEntry]] =
  ## Resolve `relPath` in a git source's tree, following symlinks component by
  ## component under the containment rule in the module comment. `none` when
  ## the path does not exist and no link was followed to get there; a path
  ## that only fails to exist BECAUSE a link pointed at nothing is a dangling
  ## link and raises.
  var pending: seq[string]
  for part in relPath.replace('\\', '/').split('/'):
    pending.add(part)
  var done: seq[string]
  var hops = 0
  var followedLink = ""
  var index = 0
  while index < pending.len:
    let part = pending[index]
    inc index
    if part.len == 0 or part == ".":
      continue
    if part == "..":
      if done.len == 0:
        sourceError(source.displayPath(relPath),
          "metadata symlink escapes the committed tree: '" & relPath &
            "' climbs above the tree root" &
            (if followedLink.len > 0: " (via the link '" & followedLink & "')"
             else: ""))
      discard done.pop()
      continue
    if done.len == 0 and part == ".git":
      sourceError(source.displayPath(relPath),
        "metadata path '" & relPath & "' names the repository's .git " &
          "directory, which is not part of the committed tree")
    let candidate = (done & @[part]).join("/")
    if candidate notin source.entries:
      if followedLink.len > 0:
        sourceError(source.displayPath(relPath),
          "dangling metadata symlink '" & followedLink & "': '" & relPath &
            "' resolves to '" & candidate & "', which the commit does " &
            "not contain")
      return none(tuple[path: string; entry: GitTreeEntry])
    let entry = source.entries[candidate]
    if entry.mode == gitModeSymlink:
      inc hops
      if hops > maxSymlinkHops:
        sourceError(source.displayPath(relPath),
          "cyclic metadata symlink: resolving '" & relPath & "' followed " &
            "more than " & $maxSymlinkHops & " links (last '" & candidate &
            "')")
      let target = source.readBlob(entry.oid, candidate)
      if target.len == 0 or isAbsolute(target) or target.startsWith("/") or
          target.startsWith("\\") or (target.len >= 2 and target[1] == ':'):
        sourceError(source.displayPath(relPath),
          "metadata symlink escapes the committed tree: '" & candidate &
            "' points at the absolute path '" & target & "'")
      followedLink = candidate
      # The target replaces the link component and is read relative to the
      # link's directory (`done`); the components after it still follow.
      var rest = target.split('/')
      for remaining in pending[index .. ^1]:
        rest.add(remaining)
      pending = rest
      index = 0
      continue
    done.add(part)
  if done.len == 0:
    return none(tuple[path: string; entry: GitTreeEntry])
  let path = done.join("/")
  some((path: path, entry: source.entries[path]))

proc isFileEntry(entry: GitTreeEntry): bool =
  entry.kind == "blob" and entry.mode != gitModeSymlink and
    entry.mode != gitModeGitlink

proc readTextExpecting(source: ManifestSource;
                       relPath, expectedSchema: string): Option[string] =
  ## `readText`, with `expectedSchema` framing the diagnostic for a file that
  ## exists but cannot be read — the shape `reader.slurpManifest` has always
  ## given that failure, so a directory source words it exactly as before.
  case source.kind
  of mskDirectory:
    let path = source.displayPath(relPath)
    if not fileExists(path):
      return none(string)
    try:
      some(readFile(path))
    except IOError, OSError:
      raiseManifestError(path, "", expectedSchema, "",
        getCurrentExceptionMsg())
  of mskGitRevision:
    let found = source.resolveTreePath(relPath)
    if found.isNone or not isFileEntry(found.get().entry):
      return none(string)
    some(source.readBlob(found.get().entry.oid, relPath))
  of mskOverlay:
    if normalizeRelPath(relPath) == source.overlayPath:
      some(source.overlayContent)
    else:
      readTextExpecting(source.base, relPath, expectedSchema)

proc readText*(source: ManifestSource; relPath: string): Option[string] =
  ## The content of the FILE at `relPath`; `none` when there is no file there
  ## (absent, or a directory / submodule). A git source raises
  ## `WorkspaceManifestParseError` for a symlink that breaks the containment
  ## rule; a directory source raises it for a file that exists but cannot be
  ## read.
  readTextExpecting(source, relPath, "")

proc hasFile*(source: ManifestSource; relPath: string): bool =
  ## Whether `readText(relPath)` would return a file, without reading it.
  case source.kind
  of mskDirectory:
    fileExists(source.displayPath(relPath))
  of mskGitRevision:
    let found = source.resolveTreePath(relPath)
    found.isSome and isFileEntry(found.get().entry)
  of mskOverlay:
    normalizeRelPath(relPath) == source.overlayPath or
      hasFile(source.base, relPath)

proc listTomlFiles*(source: ManifestSource; relDir: string): seq[string] =
  ## The `.toml` entries directly inside `relDir`, as source-relative paths
  ## (`relDir/<name>.toml`), sorted. An absent directory lists nothing: an
  ## unconverted manifest repo simply has no `url-prefixes/`.
  ##
  ## Entries are listed as the directory holds them — a link is listed under
  ## its own name and resolved when it is read — so the order is the order of
  ## the names a reader sees, for every source alike.
  let dir = normalizeRelPath(relDir)
  case source.kind
  of mskDirectory:
    let abs = source.displayPath(dir)
    if not dirExists(abs):
      return
    for kind, path in walkDir(abs):
      if kind in {pcFile, pcLinkToFile} and path.splitFile.ext == ".toml":
        result.add(dir & "/" & path.extractFilename)
  of mskGitRevision:
    let found = source.resolveTreePath(dir)
    if found.isNone or found.get().entry.kind != "tree":
      return
    let prefix = found.get().path & "/"
    for path, entry in source.entries.pairs:
      if path.startsWith(prefix) and '/' notin path[prefix.len .. ^1] and
          path.endsWith(".toml") and entry.kind == "blob" and
          entry.mode != gitModeGitlink:
        result.add(dir & "/" & path[prefix.len .. ^1])
  of mskOverlay:
    result = listTomlFiles(source.base, dir)
    let parent = source.overlayPath.rsplit('/', maxsplit = 1)
    if parent.len == 2 and parent[0] == dir and
        source.overlayPath.endsWith(".toml") and
        source.overlayPath notin result:
      result.add(source.overlayPath)
  result.sort()

proc newDirectorySource*(root: string): ManifestSource =
  ## A source over the directory `root` (made absolute) — the working tree.
  ManifestSource(kind: mskDirectory, root: absolutePath(root))

proc newOverlaySource*(base: ManifestSource;
                       relPath, content: string): ManifestSource =
  ## `base` with the file at `relPath` reading as `content`, held in memory
  ## and never written anywhere. `close` on the overlay closes `base`.
  ManifestSource(kind: mskOverlay, base: base,
    overlayPath: normalizeRelPath(relPath), overlayContent: content)

proc readManifestText*(source: ManifestSource;
                       relPath, expectedSchema: string): string =
  ## The text of the manifest at `relPath`, or the file-level diagnostic
  ## every reader raises for a missing manifest (`missingManifestMessage`,
  ## empty key path and observed schema) — the source-generic `slurpManifest`.
  let content = source.readTextExpecting(relPath, expectedSchema)
  if content.isNone:
    raiseManifestError(source.displayPath(relPath), "", expectedSchema, "",
      missingManifestMessage)
  content.get()
