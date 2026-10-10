## repro_workspace_manifests/settings.nim
##
## The workspace settings files (Workspace-Settings-Files.md §2–§6):
##
## * `repro-workspace.toml` (`reprobuild.workspace.settings.v1`) — shared,
##   committed workspace policy: the root repo's branch roles, profiles,
##   custom roles, project defaults, the record store, shared extra manifest
##   layers, and the unchanged `[verify]` / `[develop]` / `[locking]` /
##   `[foreign_env]` tables;
## * `repro-workspace.local.toml` (`reprobuild.workspace.settings-local.v1`) —
##   one person's extra manifest layers and the URLs of shared layers that need
##   credentials. `[[manifest]]` entries and nothing else.
##
## **Transition.** Until the old names are retired (§8 step 4) the OLD host
## bootstrap config `.repro-workspace.toml` (`bootstrap.v1`) is still read —
## exactly as before, private companion included — and mapped onto the same
## `WorkspaceSettings` record (see that type for the mapping). Discovery keys
## on either name and prefers `repro-workspace.toml` in the same directory.
##
## **Why a hand-written tree decoder.** Every other workspace file goes
## through the typed strict decoder in `reader.nim`. These two cannot: the
## pinned toml-serialization silently drops a dotted sub-table header
## (`[profiles.product]`, `[profiles.product.branch-roles]`) of a typed record
## and fails with an EMPTY message on several shapes this file uses (measured
## while writing this module). So the file is decoded into the generic TOML
## tree and walked here, with the strict reader's rules re-imposed: an unknown
## key is an error naming its key path, and so is a value of the wrong type.
## TOML reference: https://toml.io/en/v1.0.0.

import std/[algorithm, options, os, strutils]

import types
import diagnostics
import reader

const
  settingsFileName* = "repro-workspace.toml"
    ## The shared settings file (§3). No leading dot: it is policy people read
    ## and review, and the file that makes a directory a workspace root.
  localSettingsFileName* = "repro-workspace.local.toml"
    ## The per-user settings file (§4), read when it sits beside the shared one.
  legacySettingsFileName* = bootstrapConfigFileName
    ## The old host bootstrap config (`.repro-workspace.toml`). Read only when
    ## no `repro-workspace.toml` sits in the same directory.
  workspaceRootLayerName* = "<workspace-root>"
    ## `ManifestLayer.name` of the base layer the root repository contributes
    ## when the settings files declare extra layers (§3: "The root repo is
    ## always the base layer"). Angle brackets make it a name no settings file
    ## can declare.

# ---- discovery -------------------------------------------------------------

proc settingsFileIn*(dir: string): string =
  ## The settings file `dir` itself holds — `repro-workspace.toml`, else the
  ## old `.repro-workspace.toml` — or "" when it holds neither.
  let current = dir / settingsFileName
  if fileExists(current):
    return current
  let legacy = dir / legacySettingsFileName
  if fileExists(legacy):
    return legacy
  ""

proc findWorkspaceSettingsPath*(workspaceRoot: string): string =
  ## Locate the workspace settings file (§6):
  ##
  ##   1. `REPRO_WORKSPACE_CONFIG`, when set, names the file explicitly (either
  ##      schema); a name that does not exist means "no settings file".
  ##   2. Otherwise the nearest of `workspaceRoot` and its ancestors holding
  ##      `repro-workspace.toml` or `.repro-workspace.toml`, the new name
  ##      winning within one directory. The ancestor walk is kept from the
  ##      bootstrap config: a product repo committing the file may be a parent
  ##      of the directory a command runs in.
  ##
  ## Returns "" when there is none.
  let override = getEnv("REPRO_WORKSPACE_CONFIG")
  if override.len > 0:
    return (if fileExists(override): absolutePath(override) else: "")
  if workspaceRoot.len == 0:
    return ""
  var dir = absolutePath(workspaceRoot)
  while true:
    let found = settingsFileIn(dir)
    if found.len > 0:
      return found
    let parent = dir.parentDir
    if parent.len == 0 or parent == dir:
      break
    dir = parent
  ""

# ---- the tree decoder ------------------------------------------------------

type
  TreeCtx = object
    ## Where diagnostics point: the file and the schema it declared.
    path: string
    schema: string

proc fail(c: TreeCtx; keyPath, msg: string) {.noreturn.} =
  raiseManifestError(c.path, keyPath, c.schema, c.schema, msg)

proc join(keyPath, key: string): string =
  if keyPath.len == 0: key else: keyPath & "." & key

proc isTableNode(n: TomlValueRef): bool =
  not n.isNil and n.kind in {TomlKind.Table, TomlKind.InlineTable}

proc requireTable(c: TreeCtx; keyPath: string; n: TomlValueRef) =
  if not isTableNode(n):
    c.fail(keyPath, "`" & keyPath & "` must be a table")

proc child(n: TomlValueRef; key: string): TomlValueRef =
  if isTableNode(n) and key in n.tableVal: n.tableVal[key] else: nil

proc checkKeys(c: TreeCtx; keyPath: string; n: TomlValueRef;
               allowed: openArray[string]) =
  ## The strict reader's unknown-key rule, re-imposed on a tree table.
  if not isTableNode(n):
    return
  for k, _ in n.tableVal[]:
    if k notin allowed:
      c.fail(join(keyPath, k),
        schemaSkewMessage(c.path, join(keyPath, k), ""))

proc optString(c: TreeCtx; keyPath: string; n: TomlValueRef;
               key: string): Option[string] =
  let v = child(n, key)
  if v.isNil:
    return none(string)
  if v.kind != TomlKind.String:
    c.fail(join(keyPath, key), "`" & key & "` must be a string")
  some(v.stringVal)

proc optNonEmptyString(c: TreeCtx; keyPath: string; n: TomlValueRef;
                       key: string): Option[string] =
  result = c.optString(keyPath, n, key)
  if result.isSome and result.get().len == 0:
    c.fail(join(keyPath, key), "`" & key & "` must not be empty")

proc optBool(c: TreeCtx; keyPath: string; n: TomlValueRef;
             key: string): Option[bool] =
  let v = child(n, key)
  if v.isNil:
    return none(bool)
  if v.kind != TomlKind.Bool:
    c.fail(join(keyPath, key), "`" & key & "` must be `true` or `false`")
  some(v.boolVal)

proc stringArray(c: TreeCtx; keyPath: string; n: TomlValueRef;
                 key: string): seq[string] =
  let v = child(n, key)
  if v.isNil:
    return
  if v.kind != TomlKind.Array:
    c.fail(join(keyPath, key), "`" & key & "` must be an array of strings")
  for i, item in v.arrayVal:
    if item.isNil or item.kind != TomlKind.String:
      c.fail(join(keyPath, key) & "[" & $i & "]",
        "`" & key & "` must be an array of strings")
    result.add(item.stringVal)

proc tableRows(c: TreeCtx; keyPath: string; n: TomlValueRef): seq[TomlValueRef] =
  ## The entries of an array of tables in either spelling: `[[key]]` blocks or
  ## an inline-table array `key = [{ … }]`.
  if n.isNil:
    return
  case n.kind
  of TomlKind.Tables:
    for t in n.tablesVal:
      result.add(TomlValueRef(kind: TomlKind.Table, tableVal: t))
  of TomlKind.Array:
    for i, item in n.arrayVal:
      if not isTableNode(item):
        c.fail(keyPath & "[" & $i & "]", "each `" & keyPath &
          "` entry must be a table")
      result.add(item)
  else:
    c.fail(keyPath, "`" & keyPath & "` must be an array of tables")

proc sortedKeys(n: TomlValueRef): seq[string] =
  ## Keys of a tree table in name order. TOML tables are unordered and the
  ## tree does not keep file order, so name order is the stable one.
  if isTableNode(n):
    for k, _ in n.tableVal[]:
      result.add(k)
  result.sort()

const roleDeclKeys = ["mainline", "unstable", "staging", "stable",
                      "production", "lts", "branch-roles"]

proc roleDeclsFromTree(c: TreeCtx; keyPath: string;
                       n: TomlValueRef): BranchRoleDecls =
  ## The six built-in role keys and a `branch-roles` sub-table of one declarer
  ## (`[workspace]` or `[profiles.<name>]`). The caller checks for unknown keys.
  result.mainline = c.optNonEmptyString(keyPath, n, "mainline")
  for role in builtinOptionalRoleNames:
    let v = child(n, role)
    if v.isNil:
      continue
    let value = branchRoleValueFromToml(v)
    if value.rejected.len > 0:
      c.fail(join(keyPath, role), value.rejected)
    if value.kind == brvBranch and value.branch.len == 0:
      c.fail(join(keyPath, role), "a role's branch name must not be empty; " &
        "write `false` to declare the tier absent")
    case role
    of "unstable": result.unstable = value
    of "staging": result.staging = value
    of "stable": result.stable = value
    of "production": result.production = value
    of "lts": result.lts = value
    else: discard
  result.custom = customRoleTableFromTree(c.path, c.schema,
    join(keyPath, "branch-roles"), child(n, "branch-roles"))

const visibilityTiers = ["public", "org", "team", "private", "personal"]

proc layerFromTree(c: TreeCtx; keyPath: string;
                   n: TomlValueRef): SettingsManifestLayer =
  c.checkKeys(keyPath, n, ["name", "url", "branch", "visibility", "revision",
                           "local_path"])
  result.name = c.optNonEmptyString(keyPath, n, "name")
  result.url = c.optNonEmptyString(keyPath, n, "url")
  result.branch = c.optNonEmptyString(keyPath, n, "branch")
  result.visibility = c.optNonEmptyString(keyPath, n, "visibility")
  result.revision = c.optNonEmptyString(keyPath, n, "revision")
  result.local_path = c.optNonEmptyString(keyPath, n, "local_path")
  if result.visibility.isSome and result.visibility.get() notin visibilityTiers:
    c.fail(join(keyPath, "visibility"), "unknown visibility tier '" &
      result.visibility.get() & "' (expected one of: " &
      visibilityTiers.join(", ") & ")")

proc localPathUnderReproRejection(settingsDir, raw: string): string =
  ## §4: a layer's `local_path` is resolved against the workspace root and
  ## must not lie under `.repro/` — everything there is disposable state, and
  ## a person's own declarations must not live beside caches.
  let resolved = normalizedPath(
    if isAbsolute(raw): raw else: settingsDir / raw)
  let state = normalizedPath(settingsDir / ".repro")
  if resolved == state or resolved.startsWith(state & DirSep):
    return "`local_path` '" & raw & "' lies under `.repro/`, which holds " &
      "only disposable state; keep the layer's directory elsewhere"
  ""

proc checkUnnamedLayer(c: TreeCtx; keyPath, settingsDir: string;
                       layer: SettingsManifestLayer) =
  ## The shape every layer that stands on its own must have: exactly one
  ## source, and a visibility tier.
  let hasUrl = layer.url.isSome
  let hasLocal = layer.local_path.isSome
  if hasUrl and hasLocal:
    c.fail(keyPath, "manifest layer declares BOTH `url` and `local_path`; " &
      "choose one")
  if not hasUrl and not hasLocal:
    c.fail(keyPath, "manifest layer needs either `url` or `local_path`")
  if layer.visibility.isNone:
    c.fail(join(keyPath, "visibility"),
      "required key `visibility` is missing")
  if hasLocal:
    let rejection = localPathUnderReproRejection(settingsDir,
      layer.local_path.get())
    if rejection.len > 0:
      c.fail(join(keyPath, "local_path"), rejection)
    if layer.revision.isSome:
      c.fail(join(keyPath, "revision"), "`revision` pins a fetched layer; " &
        "a `local_path` layer has no remote to pin")

proc lockingFromTree(c: TreeCtx; n: TomlValueRef): BootstrapLockingBody =
  c.requireTable("locking", n)
  c.checkKeys("locking", n, ["route"])
  for i, row in c.tableRows("locking.route", child(n, "route")):
    let kp = "locking.route[" & $i & "]"
    c.checkKeys(kp, row, ["visibility", "backend", "path", "program", "repos"])
    var entry: LockingRouteEntry
    entry.visibility = c.optString(kp, row, "visibility").get("")
    entry.backend = c.optString(kp, row, "backend").get("")
    entry.path = c.optString(kp, row, "path")
    entry.program = c.optString(kp, row, "program")
    entry.repos = c.stringArray(kp, row, "repos")
    result.route.add(entry)

# ---- the shared file --------------------------------------------------------

const settingsTopLevelKeys = ["schema", "workspace", "projects", "records",
  "manifest", "profiles", "branch-roles", "verify", "develop", "locking",
  "foreign_env", "extensions"]

proc decodeSettingsTree(path, content: string): WorkspaceSettings =
  ## A `settings.v1` file, decoded and checked on its own. Cross-file rules
  ## (the local file's names) are `readWorkspaceSettings`'s.
  let c = TreeCtx(path: path, schema: schemaWorkspaceSettingsV1)
  let tree = decodeTree(path, content, schemaWorkspaceSettingsV1)
  c.checkKeys("", tree, settingsTopLevelKeys)
  result.path = path
  result.schema = schemaWorkspaceSettingsV1
  let settingsDir = parentDir(absolutePath(path))

  let ws = child(tree, "workspace")
  if not ws.isNil:
    c.requireTable("workspace", ws)
    c.checkKeys("workspace", ws, @["profile", "default_profile"] & @roleDeclKeys)
    result.workspace.profile = c.optNonEmptyString("workspace", ws, "profile")
    result.workspace.default_profile =
      c.optNonEmptyString("workspace", ws, "default_profile")
    result.workspace.roles = c.roleDeclsFromTree("workspace", ws)

  let projects = child(tree, "projects")
  if not projects.isNil:
    c.requireTable("projects", projects)
    c.checkKeys("projects", projects, ["default", "default_template"])
    result.projects.default = c.stringArray("projects", projects, "default")
    result.projects.default_template =
      c.optString("projects", projects, "default_template")

  let records = child(tree, "records")
  if not records.isNil:
    c.requireTable("records", records)
    c.checkKeys("records", records, ["url", "branch", "publish_locks"])
    result.records.url = c.optNonEmptyString("records", records, "url")
    result.records.branch = c.optNonEmptyString("records", records, "branch")
    result.records.publish_locks =
      c.optBool("records", records, "publish_locks")

  var names: seq[string]
  for i, row in c.tableRows("manifest", child(tree, "manifest")):
    let kp = "manifest[" & $i & "]"
    let layer = c.layerFromTree(kp, row)
    if layer.name.isSome:
      if layer.name.get() == workspaceRootLayerName:
        c.fail(join(kp, "name"), "'" & workspaceRootLayerName &
          "' is reserved for the root repository's own layer")
      if layer.name.get() in names:
        c.fail(join(kp, "name"), "two `[[manifest]]` layers are named '" &
          layer.name.get() & "'")
      names.add(layer.name.get())
    if layer.name.isSome and layer.url.isNone and layer.local_path.isNone:
      # A named layer whose url each person's local file supplies (§3). Its
      # visibility is still the shared file's to declare.
      # A `revision` here pins whatever url the local file supplies.
      if layer.visibility.isNone:
        c.fail(join(kp, "visibility"), "required key `visibility` is missing")
    else:
      c.checkUnnamedLayer(kp, settingsDir, layer)
    result.sharedLayers.add(layer)

  let profiles = child(tree, "profiles")
  if not profiles.isNil:
    c.requireTable("profiles", profiles)
    for name in sortedKeys(profiles):
      let kp = "profiles." & name
      let p = child(profiles, name)
      c.requireTable(kp, p)
      c.checkKeys(kp, p, roleDeclKeys)
      result.profiles.add((name, c.roleDeclsFromTree(kp, p)))

  let roles = child(tree, "branch-roles")
  if not roles.isNil:
    c.requireTable("branch-roles", roles)
    for name in sortedKeys(roles):
      let kp = "branch-roles." & name
      let nameRejection = customRoleNameRejection(name)
      if nameRejection.len > 0:
        c.fail(kp, nameRejection)
      let r = child(roles, name)
      c.requireTable(kp, r)
      c.checkKeys(kp, r, ["fallback"])
      let fallback = c.optNonEmptyString(kp, r, "fallback")
      if fallback.isNone:
        c.fail(join(kp, "fallback"), "required key `fallback` is missing")
      result.customRoles.add(CustomRoleDecl(name: name,
        fallback: fallback.get()))

  let verify = child(tree, "verify")
  if not verify.isNil:
    c.requireTable("verify", verify)
    c.checkKeys("verify", verify, ["require_signature", "allowed_signers",
      "allowed_keys", "signer_identity"])
    result.verify.require_signature =
      c.optBool("verify", verify, "require_signature").get(false)
    result.verify.allowed_signers =
      c.optString("verify", verify, "allowed_signers")
    result.verify.allowed_keys = c.stringArray("verify", verify, "allowed_keys")
    result.verify.signer_identity =
      c.optString("verify", verify, "signer_identity")

  let develop = child(tree, "develop")
  if not develop.isNil:
    c.requireTable("develop", develop)
    c.checkKeys("develop", develop, ["org_urls"])
    result.develop.org_urls = c.stringArray("develop", develop, "org_urls")

  let locking = child(tree, "locking")
  if not locking.isNil:
    result.locking = c.lockingFromTree(locking)

  let foreign = child(tree, "foreign_env")
  if not foreign.isNil:
    c.requireTable("foreign_env", foreign)
    c.checkKeys("foreign_env", foreign, ["auto_load_envrc", "auto_load_flake"])
    result.foreign_env.auto_load_envrc =
      c.optBool("foreign_env", foreign, "auto_load_envrc")
    result.foreign_env.auto_load_flake =
      c.optBool("foreign_env", foreign, "auto_load_flake")

  let ext = child(tree, "extensions")
  if not ext.isNil:
    c.requireTable("extensions", ext)
    result.extensions.raw = TomlTableRef()
    for k, v in ext.tableVal[]:
      result.extensions.raw[k] = v

proc settingsFromBootstrap(cfg: WorkspaceBootstrap;
                           path: string): WorkspaceSettings =
  ## Map an old `bootstrap.v1` file onto the settings record, preserving what
  ## every consumer read from it before (see `WorkspaceSettings`).
  result.path = path
  result.schema = schemaWorkspaceBootstrapV1
  result.projects = cfg.projects
  if cfg.manifest.url.len > 0:
    result.records.url = some(cfg.manifest.url)
  result.records.branch = cfg.manifest.branch
  result.records.publish_locks = cfg.manifest.publish_locks
  result.privateManifestUrl = cfg.manifest.private_url
  result.manifestRevision = cfg.manifest.revision
  result.verify = cfg.verify
  result.develop = cfg.develop
  result.locking = cfg.locking
  result.foreign_env = cfg.foreign_env
  result.extensions = cfg.extensions

# ---- the local file ---------------------------------------------------------

proc readLocalSettingsLayers*(localPath, sharedPath: string;
                              shared: seq[SettingsManifestLayer]):
    seq[SettingsManifestLayer] =
  ## Read `repro-workspace.local.toml` (§4). It may carry `[[manifest]]`
  ## entries and NOTHING else: profiles, custom roles, project defaults,
  ## verification and routing are shared policy, and a local override of one
  ## would make one command mean different things on two machines.
  ##
  ## A named entry supplies the url (and may set the branch) of the shared
  ## layer of that name and adds no layer of its own; a name the shared file
  ## does not declare is an error naming both files. An unnamed entry is a
  ## layer of its own and needs a source and a visibility like any other.
  let content = readFile(localPath)
  let c = TreeCtx(path: localPath, schema: schemaWorkspaceSettingsLocalV1)
  let tree = decodeTree(localPath, content, schemaWorkspaceSettingsLocalV1)
  let observed = block:
    let s = child(tree, "schema")
    if s.isNil or s.kind != TomlKind.String or s.stringVal.len == 0:
      c.fail("schema", "top-level `schema` key is missing or empty")
    s.stringVal
  if observed != schemaWorkspaceSettingsLocalV1:
    raiseManifestError(localPath, "schema", schemaWorkspaceSettingsLocalV1,
      observed, "schema version mismatch")
  for k in sortedKeys(tree):
    if k notin ["schema", "manifest"]:
      c.fail(k, "`" & k & "` cannot be declared in " & localSettingsFileName &
        ": the local file may carry `[[manifest]]` layers only. Profiles, " &
        "custom roles, project defaults, verification and routing are shared " &
        "policy and belong in " & settingsFileName &
        " (Workspace-Settings-Files.md §4)")
  let settingsDir = parentDir(absolutePath(localPath))
  var sharedNames: seq[string]
  for layer in shared:
    if layer.name.isSome:
      sharedNames.add(layer.name.get())
  var supplied: seq[string]
  for i, row in c.tableRows("manifest", child(tree, "manifest")):
    let kp = "manifest[" & $i & "]"
    let layer = c.layerFromTree(kp, row)
    if layer.name.isSome:
      let name = layer.name.get()
      if name notin sharedNames:
        c.fail(join(kp, "name"), "this entry supplies the url of manifest " &
          "layer '" & name & "', but " & sharedPath & " declares no " &
          "`[[manifest]]` layer of that name" &
          (if sharedNames.len > 0: " (it declares: " & sharedNames.join(", ") &
            ")" else: " (it declares no named layer)"))
      if name in supplied:
        c.fail(join(kp, "name"), "two entries supply layer '" & name & "'")
      supplied.add(name)
      for (key, present) in [("visibility", layer.visibility.isSome),
                           ("revision", layer.revision.isSome),
                           ("local_path", layer.local_path.isSome)]:
        if present:
          c.fail(join(kp, key), "an entry naming shared layer '" & name &
            "' supplies its `url` and may set `branch`; `" & key &
            "` is the shared file's to declare")
    else:
      c.checkUnnamedLayer(kp, settingsDir, layer)
    result.add(layer)

# ---- reading ----------------------------------------------------------------

proc readWorkspaceSettings*(path: string): WorkspaceSettings =
  ## Read the workspace settings at `path`, in either schema, together with
  ## the `repro-workspace.local.toml` beside it when there is one.
  ##
  ## * `settings.v1` (`repro-workspace.toml`, or whatever
  ##   `REPRO_WORKSPACE_CONFIG` names) is decoded strictly from the tree.
  ## * `bootstrap.v1` (`.repro-workspace.toml`) is read by the unchanged
  ##   `readWorkspaceBootstrap` — its `[manifest] url` requirement and its
  ##   `.repro-workspace-private.toml` companion included — and mapped.
  let content =
    try: readFile(path)
    except IOError, OSError:
      raiseManifestError(path, "", schemaWorkspaceSettingsV1, "",
        "settings file does not exist or cannot be read")
  let schema = block:
    let tree = decodeTree(path, content, schemaWorkspaceSettingsV1)
    let s = child(tree, "schema")
    if s.isNil or s.kind != TomlKind.String or s.stringVal.len == 0:
      raiseManifestError(path, "schema", schemaWorkspaceSettingsV1, "",
        "top-level `schema` key is missing or empty")
    s.stringVal
  if schema == schemaWorkspaceBootstrapV1:
    result = settingsFromBootstrap(readWorkspaceBootstrap(path), path)
  elif schema == schemaWorkspaceSettingsV1:
    result = decodeSettingsTree(path, content)
  else:
    raiseManifestError(path, "schema", schemaWorkspaceSettingsV1, schema,
      "schema version mismatch (this repro reads " &
        schemaWorkspaceSettingsV1 & ", " & schemaWorkspaceBootstrapV1 & ")")
  let localPath = parentDir(path) / localSettingsFileName
  if fileExists(localPath):
    result.localPath = localPath
    result.localLayers = readLocalSettingsLayers(localPath, path,
      result.sharedLayers)

proc findWorkspaceSettings*(workspaceRoot: string): Option[WorkspaceSettings] =
  ## `findWorkspaceSettingsPath` + `readWorkspaceSettings`; `none` when the
  ## workspace has no settings file. A malformed file raises.
  let path = findWorkspaceSettingsPath(workspaceRoot)
  if path.len == 0:
    return none(WorkspaceSettings)
  some(readWorkspaceSettings(path))

# ---- layer resolution ---------------------------------------------------------

type
  SkippedSettingsLayer* = object
    ## A shared named layer neither settings file supplies a url for. Reported,
    ## not an error (§4): a contributor without access to a partner's
    ## manifests still has a working workspace.
    name*: string
    visibility*: string
    message*: string

  SettingsLayerComposition* = object
    layers*: seq[ManifestLayer]
    skipped*: seq[SkippedSettingsLayer]

proc composeSettingsLayers*(s: WorkspaceSettings): SettingsLayerComposition =
  ## §4 "Layer resolution": the shared file's `[[manifest]]` entries in order,
  ## each named one taking its url (and optionally branch) from the local
  ## entry of that name; then the local file's unnamed entries in order. The
  ## root repository — always the base layer — is NOT included; the caller
  ## puts it first (`effectiveWorkspaceLocal`).
  for shared in s.sharedLayers:
    var url = shared.url
    var branch = shared.branch
    if shared.name.isSome:
      for local in s.localLayers:
        if local.name == shared.name:
          if local.url.isSome: url = local.url
          if local.branch.isSome: branch = local.branch
    if url.isNone and shared.local_path.isNone:
      let name = shared.name.get("")
      result.skipped.add(SkippedSettingsLayer(name: name,
        visibility: shared.visibility.get(""),
        message: "manifest layer '" & name & "' (visibility " &
          shared.visibility.get("") & ") is declared in " & s.path &
          " without a url, and " &
          (if s.localPath.len > 0: s.localPath else: localSettingsFileName) &
          " supplies none; the layer is skipped"))
      continue
    result.layers.add(ManifestLayer(url: url, local_path: shared.local_path,
      visibility: shared.visibility.get(""), branch: branch,
      name: shared.name, revision: shared.revision))
  for local in s.localLayers:
    if local.name.isSome:
      continue
    result.layers.add(ManifestLayer(url: local.url,
      local_path: local.local_path, visibility: local.visibility.get(""),
      branch: local.branch, revision: local.revision))

proc profileRoles*(s: WorkspaceSettings; name: string): Option[BranchRoleDecls] =
  ## The `[profiles.<name>]` declarations, or `none`.
  for (n, decls) in s.profiles:
    if n == name:
      return some(decls)
  none(BranchRoleDecls)

proc rootMainline*(s: WorkspaceSettings): Option[string] =
  ## The workspace ROOT repository's declared mainline (Branch-Roles §3.4).
  ##
  ## `settings.v1`: `[workspace] mainline`, else the mainline of the profile
  ## `[workspace] profile` names, else of `default_profile` (§3.3's order,
  ## applied to the root). `bootstrap.v1`: `[manifest] branch`, which is what
  ## the root's mainline was read from before the settings file existed.
  if s.isLegacySettings:
    return s.records.branch
  if s.workspace.roles.mainline.isSome:
    return s.workspace.roles.mainline
  let profile =
    if s.workspace.profile.isSome: s.workspace.profile
    else: s.workspace.default_profile
  if profile.isSome:
    let decls = s.profileRoles(profile.get())
    if decls.isSome:
      return decls.get().mainline
  none(string)
