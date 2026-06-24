## repro_workspace_manifests/lock_writer.nim
##
## Workspace lock writer (RA-1 — per-repo lock directory, no index).
##
## Generates ``locks/<project>/<trigger-repo>/<full-sha>.toml`` from
## the live VCS state of the workspace (the per-repo HEAD SHAs the
## CLI dispatcher gathers via the M2 ``headShaQuery`` observation
## surface) plus the project's ``ResolvedRepo`` records (which supply
## the stable identity tuple — ``name`` / ``path`` / ``remoteName`` /
## advisory branch).
##
## The on-disk shape is fixed by
## ``reprobuild-specs/Workspace-Manifests.md``
## §"locks/<project>/<repo>/<sha>.toml":
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
## RA-1 aligns the writer with the ``repo-workspaces`` pilot (commit
## ``418f109``): locks live under a **per-repo directory**, keyed by
## the trigger repo whose commit produced the lock, and the filename
## is the **full** commit SHA (``locks/<project>/<repo>/<sha>.toml``).
## There is **no** committed lock index. The "latest published lock
## for repo X" lookup is a Git-history query over the per-repo subtree
## (``git log -1 -- locks/<project>/<repo>/``), implemented by the CLI
## support layer (which owns the git plumbing). Any legacy
## ``index.toml`` left in older manifest history is ignored and is
## never written or updated by this module.
##
## Serializer policy: this module hand-rolls the TOML emission rather
## than reflecting through ``nim-toml-serialization``. The lock TOML
## is small and flat (one header table + an array of tables); a
## hand-rolled writer (a) avoids re-decoding the entire composed
## project to drop fields that the lock shape does not carry, (b)
## keeps full control over key ordering so the round-trip emit is
## byte-stable across runs, and (c) emits the bare-minimum set of
## keys the M5 reader needs (no ``[extensions]`` section, no
## defaulted values for omitted optional keys). The output is then
## fed back through the M5 strict reader (``readLock``) to prove
## round-trip parity.

import std/[algorithm, os, strutils, tables, times]

import types
import diagnostics
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
  ## render human-facing diagnostics. (RA-1 keys lock filenames by the
  ## FULL SHA, so this no longer appears in lock paths — see
  ## ``lockFileName``.) ``width`` defaults to 8.
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

proc lockFileName*(triggerSha: string): string =
  ## Build the basename of the lock file: the **full** trigger commit
  ## SHA plus ``.toml``. RA-1 (pilot ``418f109``) keys the file by the
  ## full SHA inside a per-repo directory, so the repo name is a path
  ## segment (see ``lockFilePath``) rather than a filename prefix.
  safeFilenameSegment(triggerSha) & ".toml"

proc lockFilePath*(manifestLayerRoot, project, triggerRepo,
                   triggerSha: string): string =
  ## Full absolute path of the lock file under the manifest layer
  ## that owns the locks directory. ``manifestLayerRoot`` is the
  ## directory holding ``projects/`` / ``repos/`` (and now
  ## ``locks/``). The path layout matches the RA-1 spec verbatim:
  ## ``<manifest-layer>/locks/<project>/<repo>/<sha>.toml`` — a
  ## **per-repo** subtree keyed by the trigger repo.
  manifestLayerRoot / "locks" / project /
    safeFilenameSegment(triggerRepo) / lockFileName(triggerSha)

proc lockFileRepoRelativePath*(project, triggerRepo,
                               triggerSha: string): string =
  ## The manifest-layer-relative path of the lock file — always with
  ## forward slashes, always relative to the manifest layer's root
  ## (so the file is discoverable irrespective of where the manifest
  ## repo is checked out). RA-1 per-repo layout:
  ## ``locks/<project>/<repo>/<sha>.toml``.
  "locks/" & project & "/" & safeFilenameSegment(triggerRepo) & "/" &
    lockFileName(triggerSha)

proc lockRepoSubtreeRelativePath*(project, triggerRepo: string): string =
  ## The manifest-layer-relative path of a repo's lock **subtree**
  ## (forward slashes, trailing slash). This is the exact pathspec the
  ## "latest published lock for repo X" Git-history query reads:
  ## ``git log -1 -- locks/<project>/<repo>/``. RA-1 made this subtree
  ## load-bearing in place of the dropped shared index.
  "locks/" & project & "/" & safeFilenameSegment(triggerRepo) & "/"

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
