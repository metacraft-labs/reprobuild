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
## M7 — Variant composer. `resolveVariant(variantFile)` reads a
## `variants/<v>.toml`, resolves its `[variant].base` against the
## manifest-repo root using the SAME path-safety rules M6 applies to
## include paths, calls `resolveProject` on the base, then layers the
## variant's extra `includes` and `[[override]]` entries on top. The
## return type is the SAME `ResolvedProject` M6 emits, so downstream
## consumers (engine, CLI) cannot tell variant from non-variant
## resolutions apart — except for the two fields where they LEGITIMATELY
## differ:
##   - `projectName` carries the variant's `[variant].name`, because the
##     active workspace is referred to by the variant name when one is
##     active.
##   - `projectFile` carries the absolute path of the variant file, so
##     `repro workspace status` can say "active variant: …".
## Everything else — `defaultRevision`, `trunk`, the per-fragment
## `ResolvedRepo` records — is inherited from the base unchanged, then
## mutated only where an override explicitly targets it.
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

# ---- M7: variant composer -------------------------------------------------

proc normalizeVariantPath(variantFile, raw, keyPath, label: string): string =
  ## Validate a path string that appears inside a variant manifest
  ## (`[variant].base`, `includes[]`, or `[[override]].fragment`) and
  ## return its absolute on-disk form under the manifest-repo root.
  ##
  ## Mirrors M6's `normalizeIncludePath` rejection rules: empty,
  ## absolute, backslash-bearing, and any `..`-bearing path is rejected
  ## with a structured `WorkspaceManifestParseError` carrying the
  ## variant schema string and the supplied `keyPath`. `label` is a
  ## short noun ("variant base path", "include path", …) used in the
  ## human-readable message.
  ##
  ## The manifest root is computed the same way as for projects:
  ## `parentDir(parentDir(absolutePath(variantFile)))`. That is the
  ## directory holding `projects/`, `repos/`, and `variants/`, because
  ## variants live in a sibling directory at the same depth as projects.
  if raw.len == 0:
    raiseManifestError(variantFile, keyPath,
      schemaVariantManifestV1, schemaVariantManifestV1,
      label & " is empty")
  if isAbsolute(raw):
    raiseManifestError(variantFile, keyPath,
      schemaVariantManifestV1, schemaVariantManifestV1,
      label & " is absolute (must be relative to the manifest root): '" &
        raw & "'")
  if '\\' in raw:
    raiseManifestError(variantFile, keyPath,
      schemaVariantManifestV1, schemaVariantManifestV1,
      label & " uses backslash separators (must be forward slashes): '" &
        raw & "'")
  for component in raw.split('/'):
    if component == "..":
      raiseManifestError(variantFile, keyPath,
        schemaVariantManifestV1, schemaVariantManifestV1,
        label & " escapes the manifest root via '..': '" & raw & "'")
  let manifestRoot = parentDir(parentDir(absolutePath(variantFile)))
  result = manifestRoot / raw.replace('/', DirSep)

proc resolveVariant*(variantFile: string): ResolvedProject =
  ## Resolve a `variants/<v>.toml` into a `ResolvedProject` by composing:
  ##
  ## 1. The base project (read via M5's `readProjectManifest` and
  ##    resolved via M6's `resolveProject`).
  ## 2. Any extra `includes` the variant declares — appended to
  ##    `result.repos` in source order, with remote-name / fetch-URL /
  ##    revision resolved against the BASE project's `[[remote]]` table
  ##    and defaults. Variants do NOT carry their own `[[remote]]`
  ##    declarations.
  ## 3. Each `[[override]]` in source order. An override targets a
  ##    fragment by its `fragment` field (the path string from the
  ##    variant TOML); the resolver matches that against the
  ##    `fragmentPath` of existing `ResolvedRepo` entries after the
  ##    same path-normalization the loader applies. A `revision`,
  ##    `remote`, and/or `path` field on the override mutates the
  ##    matching record in place. If multiple fields are present they
  ##    are all applied.
  ##
  ## The returned `ResolvedProject` is indistinguishable downstream
  ## from a non-variant resolution except for two fields where it
  ## legitimately differs:
  ##   - `projectName` carries the variant's `[variant].name`.
  ##   - `projectFile` carries the absolute path of the variant file.
  ## All other fields (`defaultRevision`, `trunk`, `repos[*]`) are
  ## inherited from the base, mutated only where an override or extra
  ## include explicitly touches them.
  ##
  ## Raises `WorkspaceManifestParseError` on any malformed input —
  ## same diagnostic policy as M6. See the module-level "Error policy"
  ## comment.
  let absVariant = absolutePath(variantFile)
  let variant = readVariantManifest(absVariant)

  # ---- step 1: resolve the base project ---------------------------------
  let baseAbs = normalizeVariantPath(
    absVariant, variant.variant.base, "variant.base", "variant base path")
  if not fileExists(baseAbs):
    raiseManifestError(absVariant, "variant.base",
      schemaVariantManifestV1, schemaVariantManifestV1,
      "variant base project does not exist: '" & variant.variant.base &
        "' (resolved to '" & baseAbs & "')")
  result = resolveProject(baseAbs)

  # Override the two fields the variant legitimately owns. Everything
  # else flows through from the base resolver unchanged.
  result.projectName = variant.variant.name
  result.projectFile = absVariant

  # ---- rebuild the remote lookup table (for extra includes) -------------
  #
  # The base resolver already validated the project's [[remote]] table
  # so duplicate-name rejection has happened upstream. Re-read the
  # project here only to map remote name -> fetch URL for the variant's
  # extra includes and for `[[override]].remote` lookups. We do NOT
  # honour any [[remote]] table the variant might carry — the M5
  # schema doesn't declare one, and the spec explicitly says variants
  # don't declare their own remotes.
  let baseProject = readProjectManifest(baseAbs)
  var remotes = initTable[string, string]()
  for r in baseProject.remote:
    remotes[r.name] = r.fetch
  let defaultRemoteName =
    if baseProject.project.default_remote.isSome:
      baseProject.project.default_remote.get()
    else:
      ""

  # ---- step 2: apply the variant's extra includes ------------------------
  #
  # Build the duplicate-detection set seeded from the base's resolved
  # repos so any extra include that collides with a base repo is
  # rejected with the same `(name, path, remoteName)` rule M6 uses.
  var seen = initTable[string, int]()
  for i, r in result.repos:
    let triple = r.name & "\t" & r.path & "\t" & r.remoteName
    seen[triple] = i

  for incIdx, rawInclude in variant.includes:
    let fragmentAbs = normalizeVariantPath(
      absVariant, rawInclude,
      "includes[" & $incIdx & "]", "include path")
    if not fileExists(fragmentAbs):
      raiseManifestError(absVariant,
        "includes[" & $incIdx & "]",
        schemaVariantManifestV1, schemaVariantManifestV1,
        "include target does not exist: '" & rawInclude &
          "' (resolved to '" & fragmentAbs & "')")
    let fragment = readRepoFragment(fragmentAbs)

    var resolved: ResolvedRepo
    resolved.name = fragment.repo.name
    resolved.path =
      if fragment.repo.path.len > 0: fragment.repo.path
      else: fragment.repo.name
    resolved.fragmentPath = fragmentAbs

    let fragmentRemote =
      if fragment.repo.remote.isSome: fragment.repo.remote.get()
      else: ""
    if fragmentRemote.len > 0:
      resolved.remoteName = fragmentRemote
    elif defaultRemoteName.len > 0:
      resolved.remoteName = defaultRemoteName
    else:
      raiseManifestError(absVariant,
        "includes[" & $incIdx & "]",
        schemaVariantManifestV1, schemaVariantManifestV1,
        "fragment '" & rawInclude &
          "' omits `repo.remote` and the base project has no `default_remote`")

    if resolved.remoteName notin remotes:
      raiseManifestError(absVariant,
        "includes[" & $incIdx & "]",
        schemaVariantManifestV1, schemaVariantManifestV1,
        "fragment '" & rawInclude & "' references unknown remote '" &
          resolved.remoteName &
          "' (not declared in the base project's [[remote]] table)")
    resolved.fetchUrl = remotes[resolved.remoteName]

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

    let triple = resolved.name & "\t" & resolved.path & "\t" & resolved.remoteName
    if triple in seen:
      raiseManifestError(absVariant,
        "includes[" & $incIdx & "]",
        schemaVariantManifestV1, schemaVariantManifestV1,
        "duplicate repo (name='" & resolved.name & "', path='" & resolved.path &
          "', remote='" & resolved.remoteName &
          "') already present from earlier resolution at index " &
          $seen[triple])
    seen[triple] = result.repos.len
    result.repos.add(resolved)

  # ---- step 3: apply each [[override]] in source order ------------------
  #
  # The override targets a fragment by its `fragment` path string,
  # matched against the `fragmentPath` field of existing `ResolvedRepo`
  # entries AFTER the same path-normalization the loader applied.
  for ovIdx, ov in variant.`override`:
    let targetAbs = normalizeVariantPath(
      absVariant, ov.fragment,
      "override[" & $ovIdx & "].fragment", "override fragment path")
    var matchedIdx = -1
    for i in 0 ..< result.repos.len:
      if result.repos[i].fragmentPath == targetAbs:
        matchedIdx = i
        break
    if matchedIdx < 0:
      raiseManifestError(absVariant,
        "override[" & $ovIdx & "].fragment",
        schemaVariantManifestV1, schemaVariantManifestV1,
        "override targets fragment '" & ov.fragment &
          "' which is not part of the resolved variant (neither the base " &
          "project nor the variant's extra `includes` declare it)")

    if ov.revision.isSome:
      result.repos[matchedIdx].revision = ov.revision.get()
    if ov.remote.isSome:
      let newRemote = ov.remote.get()
      if newRemote notin remotes:
        raiseManifestError(absVariant,
          "override[" & $ovIdx & "].remote",
          schemaVariantManifestV1, schemaVariantManifestV1,
          "override sets remote '" & newRemote &
            "' which is not declared in the base project's [[remote]] table")
      result.repos[matchedIdx].remoteName = newRemote
      result.repos[matchedIdx].fetchUrl = remotes[newRemote]
    if ov.path.isSome:
      result.repos[matchedIdx].path = ov.path.get()

  # ---- step 4: post-override duplicate-detection re-run -----------------
  #
  # An override could mutate a repo into a duplicate of another entry
  # (e.g. change its `path` to match a sibling with the same name and
  # remote). Re-scan the final repos list to catch that.
  var finalSeen = initTable[string, int]()
  for i in 0 ..< result.repos.len:
    let r = result.repos[i]
    let triple = r.name & "\t" & r.path & "\t" & r.remoteName
    if triple in finalSeen:
      raiseManifestError(absVariant,
        "override",
        schemaVariantManifestV1, schemaVariantManifestV1,
        "after applying overrides, repos at indices " & $finalSeen[triple] &
          " and " & $i & " share the same (name='" & r.name &
          "', path='" & r.path & "', remote='" & r.remoteName &
          "') triple")
    finalSeen[triple] = i

proc resolveVariantFromString*(content: string;
                               basePath: string): ResolvedProject =
  ## Resolve a variant manifest whose body is supplied as a TOML string.
  ## The string-body analogue of `resolveVariant`, mirroring M6's
  ## `resolveProjectFromString`.
  ##
  ## `basePath` plays the role the on-disk variant file would: the
  ## variant's `[variant].base` and `includes[]` are resolved relative
  ## to `parentDir(parentDir(basePath))`, and any diagnostic carries
  ## `basePath` as the `path` field. The referenced base project and
  ## fragment files MUST exist on disk under that root (this proc does
  ## not provide a virtual filesystem — the M5 readers always read from
  ## the real filesystem).
  if not isAbsolute(basePath):
    raiseManifestError(basePath, "",
      schemaVariantManifestV1, schemaVariantManifestV1,
      "basePath must be an absolute path")
  writeFile(basePath, content)
  result = resolveVariant(basePath)
