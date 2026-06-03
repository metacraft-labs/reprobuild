## repro_workspace_manifests/resolver.nim
##
## M6 — Manifest resolver. Reads a `projects/<p>.toml` (M5 surface), walks
## its `includes` list, reads every referenced `repos/<r>.toml` fragment
## (also M5 surface), applies project-level defaults to fragments that omit
## them, and resolves `remote` names against the project's `[[remote]]`
## table.
##
## The output is a `ResolvedProject` value carrying one `ResolvedRepo`
## per fragment, in source order. The engine and CLI consume this typed
## record directly; they never re-walk the includes themselves.
##
## Error policy
## ------------
##
## The resolver reuses M5's `WorkspaceManifestParseError`. The rationale:
##
## - Every resolution failure either originates inside an M5 reader (the
##   included fragment is missing, or has a schema violation), or it is a
##   shape rule on top of the M5 surface (unknown remote, escaping include
##   path, duplicate `(name, path, remote)` triple). In both cases the
##   diagnostic shape M5 already produces — file path, key path,
##   expected/observed schema, inner message — is the right one. Callers
##   that already `except WorkspaceManifestParseError` keep working.
##
## - The alternative (a parallel `ManifestResolutionError`) would force
##   callers to catch two exception types for what is fundamentally one
##   class of failure: "the manifest set is malformed". M6 stays inside
##   M5's diagnostic envelope.
##
## For resolver-specific failures the convention is:
##
## - `keyPath` names the offending structural location
##   (e.g. `includes[2]`, `remote[i].name`).
## - `path` is the project file we were resolving when the failure
##   happened, so the caller always knows which project to look at.
## - `innerMessage` carries the human-readable reason.

import std/[options, os, strutils, tables]
import types
import diagnostics
import reader

type
  ResolvedRepo* = object
    ## Post-resolution facts for a single repo.
    ##
    ## The five load-bearing fields (`name`, `path`, `remoteName`,
    ## `fetchUrl`, `revision`) are exactly the tuple the milestone names
    ## ("(name, path, fetch-url, revision)"); the `vcs` and `stability`
    ## fields carry the fragment's optional values with the documented
    ## defaults applied; `fragmentPath` is the include path the fragment
    ## was loaded from (useful for diagnostics and provenance reporting).
    name*: string
    path*: string
    remoteName*: string
    fetchUrl*: string
    revision*: string
    vcs*: string
    stability*: string
    fragmentPath*: string

  ResolvedProject* = object
    ## A flat view of one `projects/<project>.toml` after include
    ## expansion and default application.
    projectName*: string
    defaultRevision*: string
    trunk*: string
    repos*: seq[ResolvedRepo]
    projectFile*: string

const
  defaultRepoVcs* = "git"
  defaultRepoStability* = "tracked"

# ---- helpers --------------------------------------------------------------

proc normalizeIncludePath(projectFile, raw: string): string =
  ## Validate an include path string and return the absolute filesystem
  ## path of the referenced fragment.
  ##
  ## Include paths in the TOML are written with forward slashes and are
  ## interpreted relative to the manifest-repo root — i.e. the directory
  ## that holds `projects/` (and therefore the parent of the project
  ## file's directory). They must NOT be absolute and must NOT escape
  ## the manifest root via `..`.
  if raw.len == 0:
    raiseManifestError(projectFile, "includes",
      schemaProjectManifestV1, schemaProjectManifestV1,
      "include path is empty")
  if isAbsolute(raw):
    raiseManifestError(projectFile, "includes",
      schemaProjectManifestV1, schemaProjectManifestV1,
      "include path is absolute (must be relative to the manifest root): '" &
        raw & "'")
  # Workspace-Manifests.md §"Common Conventions" — paths use forward
  # slashes regardless of host OS. Reject backslashes outright so a
  # Windows-authored manifest can't accidentally smuggle host-specific
  # separators in.
  if '\\' in raw:
    raiseManifestError(projectFile, "includes",
      schemaProjectManifestV1, schemaProjectManifestV1,
      "include path uses backslash separators (must be forward slashes): '" &
        raw & "'")
  let manifestRoot = parentDir(parentDir(absolutePath(projectFile)))
  # Walk the path components manually so we reject any `..` segment
  # before the OS resolves it. Even if `..` would land back inside the
  # manifest root (e.g. `projects/../repos/foo.toml`), we reject it as
  # a matter of policy: include paths should be the canonical form.
  for component in raw.split('/'):
    if component == "..":
      raiseManifestError(projectFile, "includes",
        schemaProjectManifestV1, schemaProjectManifestV1,
        "include path escapes the manifest root via '..': '" & raw & "'")
  result = manifestRoot / raw.replace('/', DirSep)

# ---- on-disk entry point --------------------------------------------------

proc resolveProject*(projectFile: string): ResolvedProject =
  ## Resolve `projectFile` (a `projects/<project>.toml`) into a
  ## `ResolvedProject`. Raises `WorkspaceManifestParseError` on any
  ## malformed input — see the module-level "Error policy" comment.
  let absProject = absolutePath(projectFile)
  let project = readProjectManifest(absProject)

  result.projectFile = absProject
  result.projectName = project.project.name
  if project.project.default_revision.isSome:
    result.defaultRevision = project.project.default_revision.get()
  if project.project.trunk.isSome:
    result.trunk = project.project.trunk.get()

  # Build remote name -> fetch URL lookup. The M5 reader already enforces
  # non-empty `name` and `fetch` on each remote entry, so we can index
  # by name directly. A duplicate remote name is a structural error: we
  # reject it here rather than silently letting the second entry shadow
  # the first.
  var remotes = initTable[string, string]()
  for i, r in project.remote:
    if r.name in remotes:
      raiseManifestError(absProject, "remote[" & $i & "].name",
        schemaProjectManifestV1, schemaProjectManifestV1,
        "duplicate remote name '" & r.name & "' in project")
    remotes[r.name] = r.fetch

  let defaultRemoteName =
    if project.project.default_remote.isSome:
      project.project.default_remote.get()
    else:
      ""

  # Track `(name, path, remoteName)` triples to detect genuine duplicates.
  # Two distinct fragments with the same `repo.name` but different `path`
  # and/or `remote` (the accounting / accounting-blocksense pattern) MUST
  # be allowed through; only an identical triple is a duplicate.
  var seen = initTable[string, int]()

  for incIdx, rawInclude in project.includes:
    let fragmentAbs = normalizeIncludePath(absProject, rawInclude)
    if not fileExists(fragmentAbs):
      raiseManifestError(absProject,
        "includes[" & $incIdx & "]",
        schemaProjectManifestV1, schemaProjectManifestV1,
        "include target does not exist: '" & rawInclude &
          "' (resolved to '" & fragmentAbs & "')")
    let fragment = readRepoFragment(fragmentAbs)

    var resolved: ResolvedRepo
    resolved.name = fragment.repo.name
    resolved.path =
      if fragment.repo.path.len > 0: fragment.repo.path
      else: fragment.repo.name
    resolved.fragmentPath = fragmentAbs

    # Resolve remote name: fragment's explicit value wins; otherwise the
    # project's `default_remote`. If the fragment omits `remote` and the
    # project declares no `default_remote`, that's a structural error.
    let fragmentRemote =
      if fragment.repo.remote.isSome: fragment.repo.remote.get()
      else: ""
    if fragmentRemote.len > 0:
      resolved.remoteName = fragmentRemote
    elif defaultRemoteName.len > 0:
      resolved.remoteName = defaultRemoteName
    else:
      raiseManifestError(absProject,
        "includes[" & $incIdx & "]",
        schemaProjectManifestV1, schemaProjectManifestV1,
        "fragment '" & rawInclude &
          "' omits `repo.remote` and the project has no `default_remote`")

    if resolved.remoteName notin remotes:
      raiseManifestError(absProject,
        "includes[" & $incIdx & "]",
        schemaProjectManifestV1, schemaProjectManifestV1,
        "fragment '" & rawInclude & "' references unknown remote '" &
          resolved.remoteName & "' (not declared in the project's [[remote]] table)")
    resolved.fetchUrl = remotes[resolved.remoteName]

    # Resolve revision: fragment's explicit value wins; otherwise the
    # project's `default_revision`. If neither is set we leave the field
    # empty — the caller's downstream policy (e.g. M9's `workspace init`)
    # decides what an empty revision means. We do NOT inject a hardcoded
    # branch name here.
    let fragmentRevision =
      if fragment.repo.revision.isSome: fragment.repo.revision.get()
      else: ""
    if fragmentRevision.len > 0:
      resolved.revision = fragmentRevision
    else:
      resolved.revision = result.defaultRevision

    resolved.vcs =
      if fragment.repo.vcs.isSome and fragment.repo.vcs.get().len > 0:
        fragment.repo.vcs.get()
      else:
        defaultRepoVcs
    resolved.stability =
      if fragment.repo.stability.isSome and fragment.repo.stability.get().len > 0:
        fragment.repo.stability.get()
      else:
        defaultRepoStability

    # Duplicate check on the `(name, path, remoteName)` triple. We use
    # a tab-joined key because none of the three components legally
    # contains a tab character (repo names are file-system-safe; paths
    # use forward slashes; remote names are TOML identifiers).
    let triple = resolved.name & "\t" & resolved.path & "\t" & resolved.remoteName
    if triple in seen:
      raiseManifestError(absProject,
        "includes[" & $incIdx & "]",
        schemaProjectManifestV1, schemaProjectManifestV1,
        "duplicate repo (name='" & resolved.name & "', path='" & resolved.path &
          "', remote='" & resolved.remoteName & "') first declared at includes[" &
          $seen[triple] & "]")
    seen[triple] = incIdx

    result.repos.add(resolved)

# ---- string-based entry point --------------------------------------------

proc resolveProjectFromString*(content: string;
                               basePath: string): ResolvedProject =
  ## Resolve a project manifest whose body is supplied as a TOML string.
  ##
  ## `basePath` plays the role the on-disk project file would: include
  ## paths are resolved relative to `parentDir(parentDir(basePath))`,
  ## and any diagnostic carries `basePath` as the `path` field. The
  ## referenced fragment files MUST exist on disk under that root
  ## (this proc does not provide a virtual filesystem for fragments —
  ## fragments are always read by `readRepoFragment`).
  ##
  ## This is the seam tests use to build inline-TOML project fixtures
  ## without rewriting `resolveProject` itself. Production code uses
  ## `resolveProject(projectFile)` directly.
  if not isAbsolute(basePath):
    raiseManifestError(basePath, "",
      schemaProjectManifestV1, schemaProjectManifestV1,
      "basePath must be an absolute path")

  # Round-trip through a temp project file so we exercise the same M5
  # reader the on-disk path uses. This keeps the validation contract
  # uniform across the two entry points.
  writeFile(basePath, content)
  result = resolveProject(basePath)
