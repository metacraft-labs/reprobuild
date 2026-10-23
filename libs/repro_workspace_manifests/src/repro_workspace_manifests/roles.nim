## repro_workspace_manifests/roles.nim
##
## Branch-role resolution (Workspace-Branch-Roles.md §2–§3).
##
## A role names a job a branch does in a repository. For each repo, every
## built-in role (`mainline`, `unstable`, `staging`, `stable`, `production`,
## `lts`) and every custom role the workspace declares under
## `[branch-roles.<name>]` resolves to ONE branch name, by this procedure
## (§3.3):
##
##   1. the first declarer, in the order fragment → the profile the fragment
##      names → the workspace default profile (only when the fragment names
##      none), that declares the role wins;
##   2. if what it declares is a branch name, the role resolves to it;
##   3. if it is `false` (the tier declared ABSENT, §3.1), or nothing declares
##      the role, the role resolves to its FALLBACK role by the same
##      procedure: the built-in edges of §2.2 (`unstable` → `mainline`,
##      `staging` → `mainline`, `stable` → `mainline`, `production` →
##      `stable`, `lts` → `stable`), or a custom role's declared `fallback`.
##
## Every chain ends at `mainline`; a repo whose `mainline` resolves to nothing
## has no roles at all, and for a `repo.v2` fragment that is a manifest load
## error (the resolver raises it, naming the fragment).
##
## **Resolution never consults the remote.** That is a property, not an
## optimisation: falling back when a probe finds no ref would turn a deleted
## or misspelled branch into a silent redirect to a different one (§2.2). This
## module therefore takes declarations only — it has no git, no network, no
## filesystem access — and a declared role whose branch is missing on the
## remote is a refusal for the command that needs it, never a fallback here.
##
## The validation rules of §3.5 that concern the settings file alone (every
## profile it names exists, every custom role a profile or `[workspace]` uses
## is declared, every fallback chain reaches `mainline` without a cycle) are
## `validateRoleSettings`, which the settings reader runs on every
## `settings.v1` file it decodes. The rules that concern a fragment are
## `validateFragmentRoles`, which the resolver runs on every fragment it
## resolves. Branch-name shape is checked where each value is read
## (`branchNameRejection`), so every value this module returns is already a
## legal `git clone --branch` argument.

import std/[options, strutils]

import types
import diagnostics
import reader

const
  builtinRoleOrder* = ["mainline", "unstable", "staging", "stable",
                       "production", "lts"]
    ## The six built-in roles in the order every role set lists them: the
    ## mainline first, then the optional tiers as §2.1's table lists them.

proc builtinFallback*(role: string): string =
  ## The built-in fallback edge of `role` (§2.2), "" for `mainline` (the end
  ## of every chain) and for a name that is not a built-in role.
  case role
  of "unstable", "staging", "stable": "mainline"
  of "production", "lts": "stable"
  else: ""

proc isBuiltinRole*(role: string): bool = role in builtinRoleOrder

type
  RoleDeclarerKind* = enum
    ## Which declaration supplied a resolved role's branch (§3.3, §3.4).
    rdkFragment = "fragment"
      ## the repo's own `repos/<repo>.toml`
    rdkProfile = "profile"
      ## the profile the fragment (or `[workspace] profile`) names
    rdkDefaultProfile = "default profile"
      ## `[workspace] default_profile`, for a fragment that names no profile
    rdkWorkspace = "workspace"
      ## the settings file's `[workspace]` table — the ROOT repo's own
      ## declarations (§3.4)

  ResolvedRole* = object
    ## One role of one repo, resolved.
    role*: string
      ## The role that was asked for.
    branch*: string
      ## The branch it resolves to. Always a branch name, never a commit or a
      ## fully-qualified ref.
    resolvedRole*: string
      ## The role whose declaration supplied `branch`: `role` itself when it
      ## was declared directly, otherwise the role the fallback chain stopped
      ## at (`mainline` for an undeclared `unstable`, `stable` for an
      ## undeclared `production` of a repo that declares `stable`).
    fallbackPath*: seq[string]
      ## Every role the resolution visited, from `role` to `resolvedRole`
      ## inclusive: `@["production", "stable", "mainline"]`. A role declared
      ## directly has a one-element path. This is what §4.4's report prints,
      ## so a sweep that lands a repo on its mainline because nobody declared
      ## the requested tier says so.
    declaredBy*: RoleDeclarerKind
      ## Which declarer supplied `branch`.
    profile*: string
      ## The profile's name when `declaredBy` is a profile; "" otherwise.

  RoleSettings* = object
    ## What role resolution needs from the workspace settings file: the
    ## profiles, the custom roles and the default profile. Empty when the
    ## workspace has no settings file, or only the old `.repro-workspace.toml`
    ## (`bootstrap.v1`), which has no way to declare any of them.
    path*: string
      ## The settings file these came from, for diagnostics; "" when none.
    profiles*: seq[(string, BranchRoleDecls)]
    customRoles*: seq[CustomRoleDecl]
    defaultProfile*: Option[string]

  RoleDeclarer* = object
    ## One declarer consulted by the resolution order of §3.3.
    kind*: RoleDeclarerKind
    profile*: string
    decls*: BranchRoleDecls

proc roleSettingsFrom*(s: WorkspaceSettings): RoleSettings =
  ## The role-resolution view of a settings record. A `bootstrap.v1` file
  ## maps to an empty view (keeping its path for diagnostics): it predates
  ## profiles and custom roles.
  result.path = s.path
  if s.isLegacySettings:
    return
  result.profiles = s.profiles
  result.customRoles = s.customRoles
  result.defaultProfile = s.workspace.default_profile

proc findProfile*(rs: RoleSettings; name: string): Option[BranchRoleDecls] =
  for (n, decls) in rs.profiles:
    if n == name:
      return some(decls)
  none(BranchRoleDecls)

proc customRoleFallback*(rs: RoleSettings; name: string): Option[string] =
  ## The declared `fallback` of custom role `name`, or `none` when the
  ## workspace does not declare it.
  for decl in rs.customRoles:
    if decl.name == name:
      return some(decl.fallback)
  none(string)

proc declaredRoleNames*(rs: RoleSettings): seq[string] =
  ## Every role a repo resolves: the six built-ins, then the declared custom
  ## roles in name order (the settings reader keeps them sorted).
  result = @builtinRoleOrder
  for decl in rs.customRoles:
    result.add(decl.name)

proc fallbackOf(rs: RoleSettings; role: string): string =
  if isBuiltinRole(role): builtinFallback(role)
  else: rs.customRoleFallback(role).get("")

proc lookup(decls: BranchRoleDecls; role: string): BranchRoleValue =
  ## What one declarer says about one role.
  case role
  of "mainline":
    # `mainline` is never `false` (§3.1). An empty v1 `branch` has always
    # meant "none declared", so it is read as undeclared here too.
    if decls.mainline.isSome and decls.mainline.get().len > 0:
      roleBranch(decls.mainline.get())
    else:
      BranchRoleValue(kind: brvUndeclared)
  of "unstable": decls.unstable
  of "staging": decls.staging
  of "stable": decls.stable
  of "production": decls.production
  of "lts": decls.lts
  else:
    var found = BranchRoleValue(kind: brvUndeclared)
    for (name, value) in decls.custom:
      if name == role:
        found = value
        break
    found

proc resolveRole*(rs: RoleSettings; declarers: openArray[RoleDeclarer];
                  role: string): Option[ResolvedRole] =
  ## Resolve one role against `declarers` (already in §3.3's order). `none`
  ## when the chain ends without a branch — which can only mean `mainline`
  ## resolved to nothing, since every chain ends there.
  var path: seq[string]
  var current = role
  while true:
    if current in path:
      # Unreachable for a validated settings file (`validateRoleSettings`
      # refuses a cycle); kept so an unvalidated `RoleSettings` built by a
      # caller cannot loop forever.
      return none(ResolvedRole)
    path.add(current)
    for d in declarers:
      let value = lookup(d.decls, current)
      case value.kind
      of brvBranch:
        return some(ResolvedRole(role: role, branch: value.branch,
          resolvedRole: current, fallbackPath: path, declaredBy: d.kind,
          profile: d.profile))
      of brvAbsent:
        # The first declarer that declares the role wins, and `false` IS a
        # declaration: a fragment's `unstable = false` overrides its
        # profile's `unstable = "agents"` and the role falls back (§3.1).
        break
      of brvUndeclared:
        discard
    let next = fallbackOf(rs, current)
    if next.len == 0:
      return none(ResolvedRole)
    current = next

proc resolveRoleSet*(rs: RoleSettings;
                     declarers: openArray[RoleDeclarer]): seq[ResolvedRole] =
  ## Every built-in and every declared custom role, resolved, in
  ## `declaredRoleNames` order. Empty when `mainline` resolves to nothing: no
  ## role can resolve then, because every chain ends at `mainline`.
  if resolveRole(rs, declarers, "mainline").isNone:
    return @[]
  for role in declaredRoleNames(rs):
    let resolved = resolveRole(rs, declarers, role)
    # A validated workspace resolves every role once `mainline` does; a role
    # that still does not is a defect in this module, not in the manifest.
    doAssert resolved.isSome, "role '" & role & "' did not resolve although " &
      "mainline did"
    result.add(resolved.get())

proc findRole*(roles: openArray[ResolvedRole];
               role: string): Option[ResolvedRole] =
  ## The resolved `role` among `roles`, or `none`.
  for r in roles:
    if r.role == role:
      return some(r)
  none(ResolvedRole)

# ---- validation (§3.5) -------------------------------------------------------

proc undeclaredCustomRoleMessage(rs: RoleSettings; name: string): string =
  var declared: seq[string]
  for d in rs.customRoles:
    declared.add(d.name)
  "custom role '" & name & "' is not declared: a custom role is declared " &
    "once for the workspace, as `[branch-roles." & name & "]` with its " &
    "`fallback`, in " &
    (if rs.path.len > 0: rs.path else: "the workspace settings file " &
      "repro-workspace.toml (this workspace has none)") &
    (if declared.len > 0: " (it declares: " & declared.join(", ") & ")"
     else: "")

proc validateDeclarerRoles*(rs: RoleSettings; decls: BranchRoleDecls;
                            file, schema, keyPrefix, mainlineKey: string) =
  ## The §3.5 rules one declarer (a fragment, a profile, `[workspace]`) can
  ## break on its own: a value that is not a branch name, and a custom role
  ## the workspace does not declare. `keyPrefix` is where the declarer's keys
  ## live (`repo`, `profiles.product`, `workspace`); `mainlineKey` is the key
  ## the mainline was spelled with (`mainline`, or a v1 fragment's `branch`).
  if decls.mainline.isSome and decls.mainline.get().len > 0:
    let rejection = branchNameRejection(decls.mainline.get())
    if rejection.len > 0:
      raiseManifestError(file, keyPrefix & "." & mainlineKey, schema, schema,
        rejection)
  for (role, value) in [("unstable", decls.unstable),
                        ("staging", decls.staging),
                        ("stable", decls.stable),
                        ("production", decls.production),
                        ("lts", decls.lts)]:
    let rejection = roleValueRejection(value)
    if rejection.len > 0:
      raiseManifestError(file, keyPrefix & "." & role, schema, schema,
        rejection)
  for (name, value) in decls.custom:
    let key = keyPrefix & ".branch-roles." & name
    if rs.customRoleFallback(name).isNone:
      raiseManifestError(file, key, schema, schema,
        undeclaredCustomRoleMessage(rs, name))
    let rejection = roleValueRejection(value)
    if rejection.len > 0:
      raiseManifestError(file, key, schema, schema, rejection)

proc validateRoleSettings*(s: WorkspaceSettings) =
  ## The §3.5 rules a `settings.v1` file can break on its own, each refused
  ## naming the file and the key:
  ##
  ## * every custom role's `fallback` names a built-in or a declared custom
  ##   role, and following `fallback` links reaches `mainline` without a
  ##   cycle (§2.4) — a dangling name or a cycle names the whole chain;
  ## * every profile `[workspace] profile` / `default_profile` names exists;
  ## * every value `[workspace]` and each `[profiles.<name>]` declares is a
  ##   branch name, and every custom role they use is declared.
  ##
  ## `bootstrap.v1` files carry none of these and are not checked.
  if s.isLegacySettings:
    return
  let rs = roleSettingsFrom(s)
  let schema = schemaWorkspaceSettingsV1
  for decl in s.customRoles:
    var chain = @[decl.name]
    var current = decl.fallback
    while true:
      if current in chain:
        raiseManifestError(s.path, "branch-roles." & decl.name & ".fallback",
          schema, schema, "custom role fallback cycle: " &
            (chain & @[current]).join(" -> ") &
            "; every fallback chain must reach `mainline`")
      chain.add(current)
      if isBuiltinRole(current):
        # Every built-in chain ends at `mainline` (§2.2).
        break
      let next = rs.customRoleFallback(current)
      if next.isNone:
        raiseManifestError(s.path, "branch-roles." & decl.name & ".fallback",
          schema, schema, "custom role fallback names '" & current &
            "', which is neither a built-in role (" &
            builtinRoleOrder.join(", ") & ") nor a declared " &
            "`[branch-roles.<name>]` (chain: " & chain.join(" -> ") & ")")
      current = next.get()
  for (key, name) in [("profile", s.workspace.profile),
                      ("default_profile", s.workspace.default_profile)]:
    if name.isSome and rs.findProfile(name.get()).isNone:
      raiseManifestError(s.path, "workspace." & key, schema, schema,
        "profile '" & name.get() & "' is not declared: there is no " &
          "`[profiles." & name.get() & "]` in this file")
  validateDeclarerRoles(rs, s.workspace.roles, s.path, schema, "workspace",
    "mainline")
  for (name, decls) in s.profiles:
    validateDeclarerRoles(rs, decls, s.path, schema, "profiles." & name,
      "mainline")

proc fragmentDeclarers*(rs: RoleSettings; fragmentDecls: BranchRoleDecls;
                        profile: Option[string];
                        fragmentFile, fragmentSchema: string):
    seq[RoleDeclarer] =
  ## §3.3's declarers for a repo: its fragment, then the profile it names, or
  ## — only when it names none — the workspace default profile. A profile the
  ## fragment names that the settings file does not declare is refused,
  ## naming the fragment and `repo.profile`.
  result.add(RoleDeclarer(kind: rdkFragment, decls: fragmentDecls))
  if profile.isSome:
    let name = profile.get()
    let decls = rs.findProfile(name)
    if decls.isNone:
      raiseManifestError(fragmentFile, "repo.profile", fragmentSchema,
        fragmentSchema, "profile '" & name & "' is not declared: " &
          (if rs.path.len > 0:
            rs.path & " has no `[profiles." & name & "]`"
           else:
            "the workspace has no settings file (repro-workspace.toml) " &
              "to declare profiles in"))
    result.add(RoleDeclarer(kind: rdkProfile, profile: name,
      decls: decls.get()))
  elif rs.defaultProfile.isSome:
    let name = rs.defaultProfile.get()
    # `validateRoleSettings` already refused a default profile that does not
    # exist; an unvalidated view simply has no default to apply.
    let decls = rs.findProfile(name)
    if decls.isSome:
      result.add(RoleDeclarer(kind: rdkDefaultProfile, profile: name,
        decls: decls.get()))

proc noMainlineMessage*(rs: RoleSettings;
                        declarers: openArray[RoleDeclarer];
                        who: string): string =
  ## Why `who` resolves no mainline, naming what was consulted.
  var consulted: seq[string]
  for d in declarers:
    case d.kind
    of rdkFragment: consulted.add("its fragment")
    of rdkWorkspace: consulted.add("`[workspace]`")
    of rdkProfile: consulted.add("profile '" & d.profile & "'")
    of rdkDefaultProfile: consulted.add("default profile '" & d.profile & "'")
  let declaresNone =
    if consulted.len == 1: consulted[0] & " declares no `mainline`"
    else: "neither " & consulted[0 ..< ^1].join(", ") & " nor " &
      consulted[^1] & " declares `mainline`"
  who & " has no mainline: " & declaresNone &
    ", and every role falls back to it. Declare " &
    "`mainline`, or name a profile that does" &
    (if rs.defaultProfile.isNone and rs.path.len > 0:
      " (or set `[workspace] default_profile` in " & rs.path & ")"
     else: "")

# ---- the workspace root repository (§3.4) ---------------------------------

proc rootDeclarers*(s: WorkspaceSettings): seq[RoleDeclarer] =
  ## §3.4: the root repo declares its roles in the settings file's
  ## `[workspace]` table, in a fragment's shape — its own keys first, then the
  ## profile `[workspace] profile` names, or else the default profile.
  let rs = roleSettingsFrom(s)
  result.add(RoleDeclarer(kind: rdkWorkspace, decls: s.workspace.roles))
  let profile =
    if s.workspace.profile.isSome: s.workspace.profile
    else: s.workspace.default_profile
  if profile.isSome:
    let decls = rs.findProfile(profile.get())
    if decls.isSome:
      result.add(RoleDeclarer(
        kind: (if s.workspace.profile.isSome: rdkProfile
               else: rdkDefaultProfile),
        profile: profile.get(), decls: decls.get()))

proc resolveRootRoles*(s: WorkspaceSettings): seq[ResolvedRole] =
  ## The workspace ROOT repository's roles, resolved by the same procedure as
  ## any repo's (§3.4). For a `settings.v1` file whose `[workspace]` (and the
  ## profile it names, or the default profile) declares no `mainline`, this
  ## RAISES naming the file and `workspace.mainline`: the root's mainline is a
  ## declaration, and inferring it from the root repo's `origin/HEAD` is the
  ## inference §3.4 forbids.
  ##
  ## Only for `settings.v1`. A `bootstrap.v1` file has no `[workspace]`; its
  ## callers keep reading `[manifest] branch` (`rootMainline`).
  doAssert not s.isLegacySettings,
    "resolveRootRoles reads settings.v1 `[workspace]`; bootstrap.v1 has none"
  let rs = roleSettingsFrom(s)
  let declarers = rootDeclarers(s)
  result = resolveRoleSet(rs, declarers)
  if result.len == 0:
    raiseManifestError(s.path, "workspace.mainline",
      schemaWorkspaceSettingsV1, schemaWorkspaceSettingsV1,
      noMainlineMessage(rs, declarers, "the workspace root repository") &
        ". The root's mainline is never inferred from its `origin/HEAD` " &
        "(Workspace-Branch-Roles.md §3.4)")

# ---- reporting (§4.4) -------------------------------------------------------

proc reportedFallbackPath*(r: ResolvedRole): seq[string] =
  ## The `fallbackPath` a report carries (Workspace-Branch-Roles.md §4.4): the
  ## chain followed, `@["unstable", "mainline"]`, and EMPTY when the requested
  ## role was declared directly. `ResolvedRole.fallbackPath` always holds at
  ## least the requested role itself; the report's empty form is what lets a
  ## consumer test "did this fall back?" without comparing two fields.
  if r.fallbackPath.len <= 1: @[] else: r.fallbackPath

proc roleChainText*(r: ResolvedRole): string =
  ## The parenthesised role annotation of §4.4's text form: `unstable` when
  ## the role was declared directly, `unstable → mainline` when it fell back
  ## (every role visited, in order). A report prints it after the branch —
  ## `agents (unstable)`, `latest (unstable → mainline)` — so a fallback is
  ## never invisible in text either.
  if r.fallbackPath.len <= 1: r.role
  else: r.fallbackPath.join(" → ")

proc roleDeclarerText*(r: ResolvedRole): string =
  ## Where the declaration that supplied `r.branch` lives, worded for a
  ## remedy: "its fragment's `unstable`", "profile 'product''s `unstable`".
  ## A refusal over a declared branch that is missing on the remote names this
  ## (§2.2), because the fix is to that declaration.
  let key = "`" & r.resolvedRole & "`"
  case r.declaredBy
  of rdkFragment: "its fragment's " & key
  of rdkProfile: "profile '" & r.profile & "''s " & key
  of rdkDefaultProfile: "default profile '" & r.profile & "''s " & key
  of rdkWorkspace: "the settings file's `[workspace]` " & key

proc resolveRoleFromMainline*(rs: RoleSettings; mainline,
                              role: string): Option[ResolvedRole] =
  ## Resolve `role` for a repo whose ONLY declaration is a mainline that the
  ## roles model did not produce: a legacy `repo.v1` fragment whose mainline
  ## `repro branch` reads from a branch-shaped `revision` or the project's
  ## `trunk`, or a root repo whose mainline comes from the old
  ## `.repro-workspace.toml`. Every other role then falls back to that
  ## mainline by the ordinary procedure (§2.2), through the same resolver —
  ## a custom role through its declared `fallback` chain. `none` when
  ## `mainline` is empty (nothing to fall back to).
  if mainline.len == 0:
    return none(ResolvedRole)
  var decls: BranchRoleDecls
  decls.mainline = some(mainline)
  resolveRole(rs, [RoleDeclarer(kind: rdkFragment, decls: decls)], role)
