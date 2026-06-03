## repro_workspace_manifests/lock_writer.nim
##
## M11 — Workspace lock writer + lock-index updater.
##
## Generates ``locks/<project>/<trigger-repo>-<short-sha>.toml`` from
## the live VCS state of the workspace (the per-repo HEAD SHAs M11's
## CLI dispatcher gathers via the M2 ``headShaQuery`` observation
## surface) plus the project's ``ResolvedRepo`` records (which supply
## the stable identity tuple — ``name`` / ``path`` / ``remoteName`` /
## advisory branch).
##
## The on-disk shape is fixed by
## ``reprobuild-specs/Workspace-Manifests.md`` §"locks/<project>/<sha>.toml":
##
##     schema = "reprobuild.workspace.lock.v1"
##
##     [lock]
##     project = "<project>"
##     created_at = "<RFC-3339 UTC timestamp>"
##     created_by = "repro workspace lock"      # optional
##     workspace_branch = "<branch>"            # optional
##
##     [[repo]]
##     name = "<repo>"
##     path = "<workspace-relative path>"
##     remote = "<remote name>"
##     revision = "<full HEAD SHA>"
##     branch = "<advisory branch>"             # optional
##
## And the index TOML — the parallel ``locks/<project>/index.toml``
## file mapping (trigger_repo, trigger_sha) tuples to lock files:
##
##     schema = "reprobuild.workspace.lock-index.v1"
##
##     [[entry]]
##     trigger_repo = "<trigger>"
##     trigger_sha = "<full SHA>"
##     lock_file = "locks/<project>/<trigger>-<short-sha>.toml"
##     created_at = "<RFC-3339 UTC timestamp>"
##
## Serializer policy: this module hand-rolls the TOML emission rather
## than reflecting through ``nim-toml-serialization``. The lock and
## index TOMLs are small and flat (one header table + an array of
## tables); a hand-rolled writer (a) avoids re-decoding the entire
## composed project to drop fields that the lock shape does not
## carry, (b) keeps full control over key ordering so the round-trip
## emit is byte-stable across runs, and (c) emits the bare-minimum
## set of keys the M5 reader needs (no ``[extensions]`` section, no
## defaulted values for omitted optional keys). The output is then
## fed back through the M5 strict reader (``readLock`` /
## ``readLockIndex``) to prove round-trip parity.

import std/[algorithm, options, os, strutils, tables, times]

import types
import diagnostics
import reader
import resolver

type
  WorkspaceLockEntry* = object
    ## One per locked repo. Mirrors the ``LockedRepo`` schema record
    ## but uses the field names the rest of M11 callers already
    ## carry (``remoteName`` matches ``ResolvedRepo.remoteName``,
    ## ``branch`` is the advisory current branch from the live
    ## observation when known).
    name*: string
    path*: string
    remoteName*: string
    revision*: string
    branch*: string

  WorkspaceLockFile* = object
    ## In-memory model of one lock TOML. The CLI fills this in from
    ## the resolved project plus the per-repo HEAD-SHA observation,
    ## then hands it to ``serializeLockToToml`` / ``writeLockFile``.
    project*: string
    createdAt*: string
    createdBy*: string
    workspaceBranch*: string
    repos*: seq[WorkspaceLockEntry]

  WorkspaceLockIndexEntry* = object
    triggerRepo*: string
    triggerSha*: string
    lockFile*: string
    createdAt*: string

  WorkspaceLockIndexFile* = object
    entries*: seq[WorkspaceLockIndexEntry]

# ---- helpers ---------------------------------------------------------------

proc isoTimestampNow*(): string =
  ## Render ``now()`` in UTC as the RFC-3339 / ISO-8601 form the spec
  ## uses (``YYYY-MM-DDTHH:MM:SSZ``). Centralised so both the lock
  ## writer and the index updater emit identical timestamp strings
  ## when invoked from one CLI run.
  let t = now().utc
  t.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc shortSha*(sha: string; width: int = 8): string =
  ## Truncate a SHA-1 hex to the first ``width`` characters. Used to
  ## build the ``<trigger>-<short>.toml`` filename and to render
  ## human-facing diagnostics. ``width`` defaults to 8 — the length
  ## the spec example uses (``reprobuild-a858633c.toml``).
  if sha.len <= width: sha
  else: sha[0 ..< width]

proc safeFilenameSegment(value: string): string =
  ## Sanitize a repo or project name into a filesystem-safe segment
  ## for the lock filename. Identical policy to M9's
  ## ``safeRepoIdSegment``: alphanumerics + dash / underscore /
  ## period pass through; everything else collapses to ``-``.
  for ch in value:
    if ch in {'A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('-')
  if result.len == 0:
    result = "lock"

proc tomlEscape(value: string): string =
  ## Escape a string for inclusion in a TOML basic string literal.
  ## We deliberately stick to the basic-string subset (backslash +
  ## double-quote escapes, plus the named control escapes the TOML
  ## spec defines for ``\n`` / ``\r`` / ``\t`` / ``\b`` / ``\f``).
  ## Everything else passes through verbatim; the lock TOML never
  ## contains arbitrary user text so we don't need the multi-line
  ## literal-string variants.
  result = newStringOfCap(value.len + 2)
  for ch in value:
    case ch
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    of '\b': result.add("\\b")
    of '\f': result.add("\\f")
    else: result.add(ch)

template emitKv(buf: var string; key, value: string) =
  buf.add(key)
  buf.add(" = \"")
  buf.add(tomlEscape(value))
  buf.add("\"\n")

# ---- lock file path convention --------------------------------------------

proc lockFileName*(triggerRepo, triggerSha: string): string =
  ## Build the basename of the lock file given the trigger repo's
  ## bare name and the full HEAD SHA. The convention matches the
  ## ``locks/reprobuild/reprobuild-a858633c.toml`` example in
  ## ``Workspace-Manifests.md`` §"locks/<project>/<sha>.toml":
  ## ``<safe-trigger>-<8-char-short-sha>.toml``.
  safeFilenameSegment(triggerRepo) & "-" & shortSha(triggerSha) & ".toml"

proc lockFilePath*(manifestLayerRoot, project, triggerRepo,
                   triggerSha: string): string =
  ## Full absolute path of the lock file under the manifest layer
  ## that owns the locks directory. ``manifestLayerRoot`` is the
  ## directory holding ``projects/`` / ``repos/`` (and now
  ## ``locks/``). The path layout matches the spec verbatim:
  ## ``<manifest-layer>/locks/<project>/<file>.toml``.
  manifestLayerRoot / "locks" / project / lockFileName(triggerRepo, triggerSha)

proc lockFileRepoRelativePath*(project, triggerRepo,
                               triggerSha: string): string =
  ## The path the ``[[entry]].lock_file`` index field carries —
  ## always with forward slashes, always relative to the manifest
  ## layer's root (so the file is discoverable irrespective of where
  ## the manifest repo is checked out).
  "locks/" & project & "/" & lockFileName(triggerRepo, triggerSha)

proc lockIndexPath*(manifestLayerRoot, project: string): string =
  ## Full absolute path of the per-project lock index file.
  manifestLayerRoot / "locks" / project / "index.toml"

# ---- builder: live state -> lock model -------------------------------------

proc buildLockFromLiveState*(
    project: string;
    workspaceBranch: string;
    createdAt: string;
    createdBy: string;
    resolved: openArray[ResolvedRepo];
    headShasByPath: Table[string, string];
    currentBranchesByPath: Table[string, string]): WorkspaceLockFile =
  ## Map a project's resolved repo set + the freshly-observed
  ## per-checkout HEAD SHA into a ``WorkspaceLockFile`` ready for
  ## serialization. ``headShasByPath`` is keyed by the resolved
  ## repo's workspace-relative ``path`` field (the same path the
  ## ``[[repo]].path`` key carries) and supplies the FULL 40-char
  ## SHA the M2 ``headShaQuery`` observation returned.
  ##
  ## A missing entry in ``headShasByPath`` is a programmer error:
  ## the CLI dispatcher MUST gather one observation per declared
  ## repo before invoking this proc. The lock writer raises a
  ## structured ``WorkspaceManifestParseError`` carrying the missing
  ## path so the caller can attribute the failure.
  if project.len == 0:
    raiseManifestError("", "lock.project", schemaLockV1, schemaLockV1,
      "buildLockFromLiveState requires a non-empty project name")
  if createdAt.len == 0:
    raiseManifestError("", "lock.created_at", schemaLockV1, schemaLockV1,
      "buildLockFromLiveState requires a non-empty created_at timestamp")
  result.project = project
  result.createdAt = createdAt
  result.createdBy = createdBy
  result.workspaceBranch = workspaceBranch
  for repo in resolved:
    if repo.path notin headShasByPath:
      raiseManifestError("", "repo[].revision", schemaLockV1, schemaLockV1,
        "missing HEAD-SHA observation for repo path '" & repo.path & "'")
    var entry = WorkspaceLockEntry(
      name: repo.name,
      path: repo.path,
      remoteName: repo.remoteName,
      revision: headShasByPath[repo.path])
    if repo.path in currentBranchesByPath:
      entry.branch = currentBranchesByPath[repo.path]
    result.repos.add(entry)

# ---- serializer ------------------------------------------------------------

proc serializeLockToToml*(lock: WorkspaceLockFile): string =
  ## Render a ``WorkspaceLockFile`` to the canonical lock TOML form.
  ## Key order is fixed: ``schema`` at the top, then ``[lock]``
  ## with ``project`` / ``created_at`` / ``created_by`` /
  ## ``workspace_branch``, then one ``[[repo]]`` block per locked
  ## repo with ``name`` / ``path`` / ``remote`` / ``revision`` /
  ## ``branch``. Optional keys are omitted (NOT emitted as empty
  ## strings) so the strict reader treats them as absent.
  if lock.project.len == 0:
    raiseManifestError("", "lock.project", schemaLockV1, schemaLockV1,
      "serializeLockToToml refuses to emit a lock with an empty project name")
  if lock.createdAt.len == 0:
    raiseManifestError("", "lock.created_at", schemaLockV1, schemaLockV1,
      "serializeLockToToml refuses to emit a lock with an empty created_at")

  result = newStringOfCap(256 + lock.repos.len * 192)
  result.add("schema = \"")
  result.add(schemaLockV1)
  result.add("\"\n\n")
  result.add("[lock]\n")
  emitKv(result, "project", lock.project)
  emitKv(result, "created_at", lock.createdAt)
  if lock.createdBy.len > 0:
    emitKv(result, "created_by", lock.createdBy)
  if lock.workspaceBranch.len > 0:
    emitKv(result, "workspace_branch", lock.workspaceBranch)

  for entry in lock.repos:
    if entry.name.len == 0:
      raiseManifestError("", "repo[].name", schemaLockV1, schemaLockV1,
        "serializeLockToToml refuses to emit a repo entry with empty name")
    if entry.path.len == 0:
      raiseManifestError("", "repo[].path", schemaLockV1, schemaLockV1,
        "serializeLockToToml refuses to emit a repo entry with empty path")
    if entry.remoteName.len == 0:
      raiseManifestError("", "repo[].remote", schemaLockV1, schemaLockV1,
        "serializeLockToToml refuses to emit a repo entry with empty remote")
    if entry.revision.len == 0:
      raiseManifestError("", "repo[].revision", schemaLockV1, schemaLockV1,
        "serializeLockToToml refuses to emit a repo entry with empty revision")
    result.add("\n[[repo]]\n")
    emitKv(result, "name", entry.name)
    emitKv(result, "path", entry.path)
    emitKv(result, "remote", entry.remoteName)
    emitKv(result, "revision", entry.revision)
    if entry.branch.len > 0:
      emitKv(result, "branch", entry.branch)

proc writeLockFile*(lock: WorkspaceLockFile; path: string) =
  ## Serialize the lock and write it to ``path``. Creates the parent
  ## directory tree as needed (``locks/<project>/`` may not exist
  ## yet on a first-ever lock). Idempotent: re-running with the
  ## same lock content overwrites the file with identical bytes
  ## (the serializer is deterministic).
  createDir(parentDir(path))
  writeFile(path, serializeLockToToml(lock))

# ---- index updater ---------------------------------------------------------

proc serializeLockIndexToToml*(index: WorkspaceLockIndexFile): string =
  ## Render a ``WorkspaceLockIndexFile`` to the canonical index TOML.
  ## Entries appear in source order; the caller is responsible for
  ## sorting / deduplication policy (see ``updateLockIndex``).
  result = newStringOfCap(128 + index.entries.len * 160)
  result.add("schema = \"")
  result.add(schemaLockIndexV1)
  result.add("\"\n")
  for entry in index.entries:
    if entry.triggerRepo.len == 0:
      raiseManifestError("", "entry[].trigger_repo",
        schemaLockIndexV1, schemaLockIndexV1,
        "serializeLockIndexToToml refuses to emit an entry with empty trigger_repo")
    if entry.triggerSha.len == 0:
      raiseManifestError("", "entry[].trigger_sha",
        schemaLockIndexV1, schemaLockIndexV1,
        "serializeLockIndexToToml refuses to emit an entry with empty trigger_sha")
    if entry.lockFile.len == 0:
      raiseManifestError("", "entry[].lock_file",
        schemaLockIndexV1, schemaLockIndexV1,
        "serializeLockIndexToToml refuses to emit an entry with empty lock_file")
    if entry.createdAt.len == 0:
      raiseManifestError("", "entry[].created_at",
        schemaLockIndexV1, schemaLockIndexV1,
        "serializeLockIndexToToml refuses to emit an entry with empty created_at")
    result.add("\n[[entry]]\n")
    emitKv(result, "trigger_repo", entry.triggerRepo)
    emitKv(result, "trigger_sha", entry.triggerSha)
    emitKv(result, "lock_file", entry.lockFile)
    emitKv(result, "created_at", entry.createdAt)

proc loadLockIndex*(indexPath: string): WorkspaceLockIndexFile =
  ## Load an existing lock index from disk. A missing file yields an
  ## empty index (the post-commit hook's first invocation hits this
  ## arm). A malformed file surfaces as the strict reader's
  ## ``WorkspaceManifestParseError``.
  if not fileExists(indexPath):
    return
  let parsed = readLockIndex(indexPath)
  for raw in parsed.entry:
    result.entries.add(WorkspaceLockIndexEntry(
      triggerRepo: raw.trigger_repo,
      triggerSha: raw.trigger_sha,
      lockFile: raw.lock_file,
      createdAt: raw.created_at))

proc updateLockIndex*(indexPath: string;
                      newEntry: WorkspaceLockIndexEntry):
                     tuple[index: WorkspaceLockIndexFile; replaced: bool] =
  ## Read the index at ``indexPath`` (or start fresh), insert /
  ## replace the entry keyed by ``(triggerRepo, triggerSha)``, and
  ## write the result back. Returns the updated in-memory model and
  ## a flag telling the caller whether the call replaced an existing
  ## entry (true) or appended a new one (false). Replaced entries
  ## keep their position in the entry list so the file's history
  ## stays stable across re-locks at the same SHA.
  result.index = loadLockIndex(indexPath)
  result.replaced = false
  var foundIdx = -1
  for i, existing in result.index.entries:
    if existing.triggerRepo == newEntry.triggerRepo and
        existing.triggerSha == newEntry.triggerSha:
      foundIdx = i
      break
  if foundIdx >= 0:
    result.index.entries[foundIdx] = newEntry
    result.replaced = true
  else:
    result.index.entries.add(newEntry)
  createDir(parentDir(indexPath))
  writeFile(indexPath, serializeLockIndexToToml(result.index))

# ---- M12 helpers: lock-index lookup for `repro workspace status` -----------

proc latestLockIndexEntry*(index: WorkspaceLockIndexFile):
    Option[WorkspaceLockIndexEntry] =
  ## Return the index entry with the lexicographically-largest
  ## ``createdAt`` timestamp (the RFC-3339 ``Z``-suffixed string the
  ## writer emits sorts identically to chronological order, so plain
  ## string ``cmp`` is the right primitive). Empty indices yield
  ## ``none(WorkspaceLockIndexEntry)``. Used by M12's
  ## ``repro workspace status`` to compare each live HEAD against the
  ## most-recently-locked SHA.
  if index.entries.len == 0:
    return none(WorkspaceLockIndexEntry)
  var best = 0
  for i in 1 ..< index.entries.len:
    if cmp(index.entries[i].createdAt,
        index.entries[best].createdAt) > 0:
      best = i
  some(index.entries[best])

proc readLatestLockedShasByPath*(manifestLayerRoot, project: string):
    Table[string, string] =
  ## Return a ``path -> revision`` map for the repos recorded in the
  ## most-recently-written lock file for ``project`` under
  ## ``<manifestLayerRoot>/locks/<project>/``. An empty / missing
  ## index, or a missing lock file on disk, yields an empty table —
  ## the caller's M12 status renderer then reports each repo as
  ## ``no-lock-recorded`` without erroring.
  result = initTable[string, string]()
  let indexPath = lockIndexPath(manifestLayerRoot, project)
  if not fileExists(indexPath):
    return
  let index = loadLockIndex(indexPath)
  let latest = latestLockIndexEntry(index)
  if latest.isNone:
    return
  # The index entry's ``lockFile`` is the manifest-layer-relative path
  # (M11 emits ``"locks/<project>/<file>.toml"`` with forward slashes
  # so it round-trips across hosts). Resolve it relative to the
  # manifest layer root, normalising separators for the host OS.
  let relLockFile = latest.get().lockFile.replace('/', DirSep)
  let lockPath = manifestLayerRoot / relLockFile
  if not fileExists(lockPath):
    return
  let lock = readLock(lockPath)
  for repo in lock.repo:
    result[repo.path] = repo.revision

# ---- convenience: ensure stable ordering of repos --------------------------

proc sortLockReposByPath*(lock: var WorkspaceLockFile) =
  ## Sort the ``repos`` slice in lexicographic order by ``path``.
  ## Useful when the caller has gathered observations in the order
  ## the resolver produced them but wants a stable on-disk shape
  ## across resolver-order changes. The CLI dispatcher does NOT
  ## currently use this — locks emit in resolver order to mirror
  ## what the M6 reader produces — but the helper is exported for
  ## future callers that prefer alphabetical layout (e.g. diff
  ## friendliness across manifests with shuffled `includes`).
  lock.repos.sort do (a, b: WorkspaceLockEntry) -> int:
    cmp(a.path, b.path)
