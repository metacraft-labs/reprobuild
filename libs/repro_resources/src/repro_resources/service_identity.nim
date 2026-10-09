## Shared-Development-Services L4 (spec §4) — the INSTANCE IDENTITY and
## SCOPE model: which instance of a shared development service a consumer
## resolves to, and where that instance's durable state lives.
##
## § THE PROBLEM, IN THE SPEC'S OWN WORDS
##
## "Several worktrees — of one repository or of several — each contain a
## `repro.nim` declaring the same logical service. Each may build a
## *different* service closure. `repro up` is run in them in an arbitrary
## order. How many instances exist, and which one does each consumer get?"
##
## Two fields answer it and they are ORTHOGONAL (§4): identity answers
## *are these the same instance?*, scope answers *how widely is one
## instance shared?*. This module is where the two become a key, and it
## keeps them apart — `serviceIdentity` never reads a scope and
## `resolveServiceScope` never reads an identity.
##
## § WHY THIS MODULE IS IN `repro_resources`
##
## The same reason `run_edge.nim` is: it bridges the two lanes. It reads
## the DSL-layer `DslServiceDef` that `repro_project_dsl` lowers a
## `service` block to, and it produces the `LeasedDep` address and holder
## id that `lease.nim` reference-counts and that `state_store.nim`
## persists under. `repro_resources` already imports `repro_project_dsl`;
## the reverse dependency does not exist.
##
## IT IS DELIBERATELY NOT RE-EXPORTED FROM THE `repro_resources` UMBRELLA,
## unlike the twelve modules that are. Reading the workspace identity needs
## `repro_workspace_manifests/reader`, which pulls `toml_serialization`,
## and the umbrella is linked into every out-of-tree resource PROVIDER --
## none of which resolves a service instance. Importing
## `repro_resources/service_identity` by name is how the other submodules
## are reachable individually anyway.
##
## § WHAT IS HERE AND WHAT IS A LATER MILESTONE
##
## Here: the identity functions, the scope resolution with its reported
## degradations, the instance key, the identity-addressed state root, and
## the lease address/holder projections.
##
## NOT here, and NOT faked:
##
##   * the ATTACH DECISION (§4.3 — silent attach / attach-and-warn /
##     refuse, on the interface fingerprint) is **L6**. Nothing in this
##     module compares fingerprints or decides to attach.
##   * the DAEMON'S INSTANCE REGISTRY and order-independent convergence
##     (§4.5) are **L7**. This module computes the key a registry would
##     be keyed by; it holds no registry, starts nothing, and talks to no
##     daemon.
##   * the ENVIRONMENT component of the key (§6.5 — the key becomes
##     `(identity, scope, environment)`) is **L5**.
##
## § TEST-DOUBLE POLICY
##
## No mocks are used by this module's tests and none may be added. The
## filesystem leg (`renderedOutputDigests`, `discoverServiceScopeContext`,
## `serviceStateRoot`) is exercised against real directories under a
## throwaway root — never against a live `.repro/` tree, which is the
## guardrail the campaign's working agreement sets.

import std/[algorithm, os, strutils]

import blake3
import repro_core                            # writeString / writeU32Le
import repro_project_dsl                     # DslServiceDef / ServiceScope
import repro_workspace_manifests/lock_paths  # encodeLockPathSegment
import repro_workspace_manifests/reader      # readWorkspaceLocal

const
  ServiceIdentityDigestTag = "reprobuild.service-identity.v1"
    ## Domain-separation tag, first in every derived digest. Two digests
    ## computed by two different schemes must not be able to collide, and
    ## a scheme change is a tag change.

  ServiceStateDirName* = "services"
    ## The one subdirectory of a state store that holds shared-service
    ## state. Named here so the layout has a single definition.

  ServiceScopeKeyDigestChars* = 16
    ## How much of the scope key's digest goes into a path component.
    ## Short enough to keep the path usable on Windows, long enough that
    ## a collision between two project roots on one machine is not a
    ## practical concern. The scope key is NOT reversible from the path;
    ## the identity is (see `serviceStateRoot`).

  SystemScopeKey* = "system"
    ## §4.1: `system` is "one instance per machine", so its scope key is
    ## a constant rather than anything read off the host.

  MissingOutputMarker = "\x00absent"
    ## What an unrendered declared output contributes to a derived
    ## digest. A MARKER and not a skip: skipping would make "the config
    ## has not been rendered yet" and "the config rendered to zero bytes"
    ## the same identity, so a consumer resolving before the build would
    ## attach to the instance of a service it has not built.

type
  ServiceIdentityError* = object of CatchableError
    ## Raised when a key cannot be resolved at all — a `stable` service
    ## with no id, or a path-keyed scope with no path. Never raised for a
    ## scope that merely has to DEGRADE; that is reported, not raised.

  ServiceScopeContext* = object
    ## The host facts scope resolution reads. Supplied explicitly so the
    ## resolution is a pure function of it, and filled from a real
    ## filesystem by `discoverServiceScopeContext`.
    projectRoot*: string
      ## The consuming project's root. Canonicalised on the way in.
    workspaceRoot*: string
      ## The workspace root this project sits under — the directory
      ## carrying `.repro/workspace.toml`. Empty when there is none.
    workspaceId*: string
      ## THE WORKSPACE IDENTITY, which is deliberately not invented here.
      ## `Local-Daemons-And-Control-Plane.md` already keys daemon sessions
      ## partly on "workspace identity when available", and the workspace
      ## manifests already carry exactly one such name: `[workspace]
      ## project` in `.repro/workspace.toml` — the PRIMARY project of the
      ## active set, which `WorkspaceBody.project` is required to be
      ## non-empty for. That is the notion reused.
      ##
      ## Empty when unavailable, and §4.1's `workspace` scope then
      ## DEGRADES rather than guessing; `resolveServiceScope` says to
      ## what and why.
    workspaceIdUnreadable*: string
      ## Why `workspaceId` is empty although `workspaceRoot` is not: the
      ## manifest reader's own message. Carried so the degradation below
      ## can say WHY rather than only that it happened.
      ##
      ## This field exists because of a measured near-miss in this
      ## milestone's own test fixture. A `.repro/workspace.toml` written
      ## with the wrong `schema` value was rejected by
      ## `readWorkspaceLocal`, the rejection was swallowed, and `scope
      ## workspace` quietly narrowed to the checkout -- which is a
      ## correct degradation for a manifest that cannot be read, and an
      ## unhelpful one to debug. A malformed manifest and a manifest that
      ## simply is not there deserve different sentences.
    user*: string
      ## The OS user, for `scope user`. Empty when it cannot be read.

  ServiceScopeResolution* = object
    ## The resolution of one `ServiceScope` against one context.
    scope*: ServiceScope
      ## The scope actually resolved — equal to the declared one unless
      ## `degraded`.
    declaredScope*: ServiceScope
    key*: string
      ## The discriminator: WHICH project / workspace / user / machine.
      ## `scope` says how widely one instance is shared; this says which
      ## one. §4 writes the key as `(identity, scope)`; a resolution needs
      ## both halves of the second element, and conflating them would
      ## make every project-scoped service on a host one instance.
    degraded*: bool
    degradation*: string
      ## One sentence naming what was unavailable, what was used instead,
      ## and the consequence. Empty when `degraded` is false. A caller
      ## that reports nothing turns a narrower-than-declared sharing
      ## boundary into a silent one, which is the defect §4.4 describes
      ## in today's hand-rolled version: "two worktrees reach different
      ## state and different ports while both claim to be the workspace's
      ## single instance".

  ServiceInstanceKey* = object
    ## §4.5: "The daemon holds a registry of running instances keyed by
    ## `(identity, scope)`". This is that key. The registry is L7.
    identityKind*: ServiceIdentityKind
    identity*: string
      ## The author's id for `sikStable`, the definition digest for
      ## `sikDerived`.
    scope*: ServiceScope
    scopeKey*: string
    degradation*: string
      ## Carried through from the scope resolution so a caller holding
      ## only the key can still report it.

# ---------------------------------------------------------------------------
# Small shared helpers.
# ---------------------------------------------------------------------------

proc scopeWord*(scope: ServiceScope): string =
  ## The scope's recipe spelling — `project` / `workspace` / `user` /
  ## `system`. Derived from the enum name, which is the same derivation
  ## the DSL's `identity`/`scope` parser uses, so the two cannot drift.
  ($scope)[3 .. ^1].normalize

proc identityKindWord*(kind: ServiceIdentityKind): string =
  ## `derived` / `stable`.
  ($kind)[3 .. ^1].normalize

proc canonicalRoot*(path: string): string =
  ## A path in the one form a scope key may use it in.
  ##
  ## Symlinks are resolved when the path exists, because a scope key that
  ## distinguishes `/w/ws` from a symlink pointing at it would split one
  ## project into two instances for a reason no author can see. A path
  ## that does not exist cannot be resolved, so it is normalised
  ## lexically instead — the honest best available, and documented rather
  ## than silently different.
  if path.len == 0:
    return ""
  var resolved = path
  try:
    resolved = expandFilename(path)
  except OSError, IOError:
    resolved = absolutePath(path)
  result = resolved.replace('\\', '/')
  while result.len > 1 and result.endsWith("/"):
    result.setLen(result.len - 1)

proc digestHex(payload: seq[byte]): string =
  blake3.digest(payload).toHex()

# ---------------------------------------------------------------------------
# §4.2 — the two identity modes.
# ---------------------------------------------------------------------------

proc serviceDeclaredOutputPaths*(def: DslServiceDef): seq[string] =
  ## Every rendered output this service references, by its DECLARED
  ## (producer-relative) path: the build outputs on argv, plus every
  ## `runtimeFile`, plus every `on change <buildOutput>` watch.
  ##
  ## §4.2 names "the rendered configuration outputs" as part of a derived
  ## identity, and these are the paths they arrive by. Deduplicated and
  ## sorted, so declaring one config twice — on argv AND under a watch,
  ## which L1 already asserts is ONE consumed output — contributes once
  ## and in a fixed order.
  var seen: seq[string] = @[]
  proc claim(path: string) =
    if path.len > 0 and path notin seen:
      seen.add(path)
  for arg in def.typedArgs:
    if arg.kind == svakBuildOutput:
      claim(arg.producerPath)
  for file in def.runtimeFiles:
    claim(file.path)
  for trigger in def.triggers:
    if trigger.kind == stkChangeOutput:
      claim(trigger.subject)
  seen.sort()
  seen

proc renderedOutputDigests*(materialisedRoot: string;
                            def: DslServiceDef):
    seq[tuple[path, digest: string]] =
  ## Digest the CONTENT of every declared output of `def`, reading each
  ## one from `materialisedRoot / <declared path>` on a real filesystem.
  ##
  ## The result is keyed by the DECLARED path, never by the absolute one,
  ## which is what keeps a derived identity path-independent: two
  ## worktrees that render byte-identical configuration produce an
  ## identical table, and §4.2's "Two worktrees that build the same
  ## closure share one instance" follows from that rather than from a
  ## convention.
  ##
  ## An output that is not there yet contributes `MissingOutputMarker`
  ## instead of being skipped — see that constant.
  ##
  ## WHY THE CONTENT IS AN ARGUMENT TO THE DIGEST AND NOT COMPUTED
  ## INSIDE IT. The engine already knows each rendered output's content
  ## digest: it is a cached build output with a producing edge (L1), and
  ## the action cache has its digest without re-reading the file. Having
  ## the identity function TAKE the digests lets the engine pass what it
  ## has, lets a test pass a literal table, and keeps `serviceIdentity`
  ## free of filesystem access. This proc is the filesystem-backed way to
  ## obtain them when nothing else has.
  for path in serviceDeclaredOutputPaths(def):
    let full =
      if materialisedRoot.len == 0: path
      else: materialisedRoot / path
    var digest = MissingOutputMarker
    if fileExists(full):
      try:
        digest = blake3.digest(readFile(full)).toHex()
      except IOError, OSError:
        digest = MissingOutputMarker
    result.add((path: path, digest: digest))

proc derivedServiceIdentity*(def: DslServiceDef;
    outputDigests: openArray[tuple[path, digest: string]] = []): string =
  ## §4.2 `derived`: "Identity is a digest of the service's materialised
  ## definition: the executable, the rendered configuration outputs, the
  ## arguments."
  ##
  ## WHAT IS IN THE DIGEST, and the rule: everything the SUPERVISOR acts
  ## on. The executable selection, every argv token, every runtime file,
  ## every trigger and its actions, the systemd-unit slice that decides
  ## how and as whom the process runs, and the content digest of every
  ## rendered output.
  ##
  ## Plus the service's OWN NAME and its package's, which §4.2's list of
  ## inputs does not mention. Two services of one package with
  ## byte-identical definitions are two services the author wrote on
  ## purpose, and handing them one instance would be wrong; so is handing
  ## one instance to two packages that happen to declare the same thing,
  ## because neither owns the other's state. Both are asserted, so the
  ## inclusion is a decision rather than an accident.
  ##
  ## WHAT IS DELIBERATELY OUT, each for a reason:
  ##
  ##   * `bodyRepr` — the body's SOURCE TEXT. A reformatted line or an
  ##     added comment would otherwise fork a developer's state, and
  ##     §4.2's complaint is precisely about "a change that changes
  ##     nothing observable".
  ##   * `description` — cosmetic unit metadata. Same reason.
  ##   * every `actionId` and `producerPackage`/`producerActionId` — these
  ##     are the GRAPH's internal handles for the producing edge. The edge
  ##     matters to the digest only through what it produced, which is the
  ##     content digest; folding in an engine-assigned id would couple a
  ##     developer's state to the engine's bookkeeping.
  ##   * `identity` and `scope` themselves. The identity mode SELECTS this
  ##     function, so feeding it back in would be circular, and the scope
  ##     is the key's other, orthogonal axis (§4) — a service reached at a
  ##     wider scope is the same service.
  ##
  ## The legacy untyped `executableRef` / `args` ARE included alongside
  ## the typed fields, which is not redundancy: a record built through the
  ## positional `registerService` has the untyped pair populated and the
  ## typed fields empty, so digesting only the typed half would make such
  ## a service's identity blind to its own arguments.
  var payload: seq[byte] = @[]
  payload.writeString(ServiceIdentityDigestTag)
  payload.writeString(def.packageName)
  payload.writeString(def.serviceName)
  payload.add(byte(ord(def.executableTyped.kind)))
  payload.writeString(def.executableTyped.packageName)
  payload.writeString(def.executableTyped.executableName)
  payload.writeString(def.executableTyped.path)
  payload.writeString(def.executableRef)
  payload.writeU32Le(uint32(def.args.len))
  for arg in def.args:
    payload.writeString(arg)
  payload.writeU32Le(uint32(def.typedArgs.len))
  for arg in def.typedArgs:
    payload.add(byte(ord(arg.kind)))
    payload.writeString(arg.value)
    payload.writeString(arg.producerPath)
  payload.writeU32Le(uint32(def.runtimeFiles.len))
  for file in def.runtimeFiles:
    payload.writeString(file.path)
  payload.writeU32Le(uint32(def.triggers.len))
  for trigger in def.triggers:
    payload.add(byte(ord(trigger.kind)))
    payload.writeString(trigger.subject)
    payload.writeU32Le(uint32(trigger.actions.len))
    for action in trigger.actions:
      payload.add(byte(ord(action.kind)))
      payload.writeString(action.argument)
  payload.writeString(def.serviceType)
  payload.writeString(def.execStart)
  payload.writeString(def.restart)
  payload.writeString(def.user)
  payload.writeString(def.group)
  for list in [def.wantedBy, def.wants, def.requires, def.before,
               def.after]:
    payload.writeU32Le(uint32(list.len))
    for entry in list:
      payload.writeString(entry)
  payload.writeU32Le(uint32(def.env.len))
  for entry in def.env:
    payload.writeString(entry.key)
    payload.writeString(entry.value)
  # The rendered outputs, sorted by declared path so a caller's ordering
  # cannot change the identity.
  var outputs: seq[tuple[path, digest: string]] = @[]
  for entry in outputDigests:
    outputs.add(entry)
  outputs.sort(proc (a, b: tuple[path, digest: string]): int =
    cmp(a.path, b.path))
  payload.writeU32Le(uint32(outputs.len))
  for entry in outputs:
    payload.writeString(entry.path)
    payload.writeString(entry.digest)
  digestHex(payload)

proc serviceIdentity*(def: DslServiceDef;
    outputDigests: openArray[tuple[path, digest: string]] = []): string =
  ## The service's identity under the mode it DECLARED (§4.2).
  ##
  ## For `sikStable` the author's id is returned verbatim — "The author
  ## assigns a stable identifier, independent of the build", so it is not
  ## digested, not qualified with the package name and not touched at all.
  ## Hashing it would destroy the one property that makes it useful: the
  ## id a developer reads in a recipe is the id they find in the state
  ## path and in a daemon's registry.
  case def.identity.kind
  of sikStable:
    if def.identity.stableId.strip().len == 0:
      raise newException(ServiceIdentityError,
        "service `" & def.packageName & ":" & def.serviceName &
        "` declares `identity stable` with an empty identifier; " &
        "Shared-Development-Services.md §4.2 requires an id that is " &
        "\"globally unique by construction\"")
    def.identity.stableId
  of sikDerived:
    derivedServiceIdentity(def, outputDigests)

# ---------------------------------------------------------------------------
# §4.1 — scope, and what it degrades to.
# ---------------------------------------------------------------------------

proc currentOsUser*(): string =
  ## The OS user name, for `scope user`. Read from the environment the
  ## platform populates; empty when none of them is set, which
  ## `resolveServiceScope` reports as a degradation rather than
  ## substituting a guess.
  for name in ["USER", "LOGNAME", "USERNAME"]:
    let value = getEnv(name, "")
    if value.strip().len > 0:
      return value.strip()
  ""

proc discoverServiceScopeContext*(projectRoot: string): ServiceScopeContext =
  ## Fill a `ServiceScopeContext` from a real filesystem.
  ##
  ## The workspace is found by walking UP from the project root for a
  ## directory carrying `.repro/workspace.toml` — the same file, and the
  ## same "declares a workspace" test, that `repro hooks ensure --vcs`
  ## uses to tell a workspace root from a checkout that merely holds
  ## manifest-shaped data. Its `[workspace] project` is the workspace
  ## identity (see `ServiceScopeContext.workspaceId`).
  ##
  ## A `workspace.toml` that cannot be read is treated as a workspace
  ## with NO identity rather than as no workspace: the root is real, so
  ## `workspace` scope degrades by one step instead of two, and the
  ## degradation message says which.
  result.projectRoot = canonicalRoot(projectRoot)
  result.user = currentOsUser()
  if result.projectRoot.len == 0:
    return
  var dir = result.projectRoot
  while true:
    let candidate = dir / ".repro" / "workspace.toml"
    if fileExists(candidate):
      result.workspaceRoot = dir
      try:
        result.workspaceId = readWorkspaceLocal(candidate).workspace.project
      except CatchableError as err:
        result.workspaceId = ""
        result.workspaceIdUnreadable = err.msg
      return
    let parent = parentDir(dir)
    if parent.len == 0 or parent == dir:
      return
    dir = parent

proc resolveServiceScope*(scope: ServiceScope;
                          ctx: ServiceScopeContext): ServiceScopeResolution =
  ## Resolve `scope` against `ctx` into the key half of §4's instance
  ## key, reporting any degradation.
  result.declaredScope = scope
  result.scope = scope
  result.degraded = false
  case scope
  of sscProject:
    if ctx.projectRoot.len == 0:
      raise newException(ServiceIdentityError,
        "`scope project` needs a project root and the context carries " &
        "none; §4.1 defines it as \"one instance per project root\"")
    result.key = ctx.projectRoot
  of sscWorkspace:
    if ctx.workspaceId.len > 0:
      result.key = ctx.workspaceId
      return
    if ctx.workspaceRoot.len > 0:
      # One step: a real workspace with no readable identity. Sharing
      # still spans every project under THIS checkout, which is what
      # `workspace` scope means inside one checkout; it no longer spans
      # two checkouts of the same workspace, which is the D-SS3 property
      # the identity exists for.
      result.key = ctx.workspaceRoot
      result.degraded = true
      result.degradation =
        "`scope workspace` fell back to the workspace ROOT PATH `" &
        ctx.workspaceRoot & "`: its `.repro/workspace.toml` declares no " &
        "readable `[workspace] project`, which is the workspace identity " &
        "this scope keys on" &
        (if ctx.workspaceIdUnreadable.len > 0:
           " (" & ctx.workspaceIdUnreadable & ")"
         else: "") &
        ". Sharing still spans the projects under this checkout; it no " &
        "longer spans a SECOND checkout of the same workspace at another " &
        "path (D-SS3)."
      return
    # Two steps: no workspace at all. This is `project` scope, and saying
    # so is the point -- a service declared `scope workspace` outside a
    # workspace is NOT shared, and a consumer told nothing would read the
    # declaration and believe it was.
    if ctx.projectRoot.len == 0:
      raise newException(ServiceIdentityError,
        "`scope workspace` has neither a workspace nor a project root " &
        "to fall back to")
    result.scope = sscProject
    result.key = ctx.projectRoot
    result.degraded = true
    result.degradation =
      "`scope workspace` DEGRADED TO `scope project` (`" &
      ctx.projectRoot & "`): no ancestor of the project root carries " &
      "`.repro/workspace.toml`, so there is no workspace to be one " &
      "instance per. The service is not shared beyond this project."
  of sscUser:
    if ctx.user.len > 0:
      result.key = ctx.user
      return
    if ctx.projectRoot.len == 0:
      raise newException(ServiceIdentityError,
        "`scope user` has neither a user name nor a project root to " &
        "fall back to")
    result.scope = sscProject
    result.key = ctx.projectRoot
    result.degraded = true
    result.degradation =
      "`scope user` DEGRADED TO `scope project` (`" & ctx.projectRoot &
      "`): no `USER`, `LOGNAME` or `USERNAME` is set, so the OS user " &
      "this scope is one instance per cannot be named. Narrowing is the " &
      "safe direction -- a guessed user name would share one instance, " &
      "and one state directory, between accounts."
  of sscSystem:
    result.key = SystemScopeKey

proc routesToSystemDaemon*(scope: ServiceScope): bool =
  ## §4.1: `system` routes to the system daemon; `project`, `workspace`
  ## and `user` are all narrower than the OS user and route to the USER
  ## daemon. `Ephemeral-State-Leases.md` §4.1 already resolved that split
  ## for `user` vs `system` and this does not re-decide it — it says where
  ## the two NEW scopes land on the existing answer.
  ##
  ## Wiring this to a daemon is L7. The predicate is here because the
  ## routing is a property of the scope, not of the daemon.
  scope == sscSystem

# ---------------------------------------------------------------------------
# The key, the state root, and the lease projections.
# ---------------------------------------------------------------------------

proc serviceInstanceKey*(def: DslServiceDef; ctx: ServiceScopeContext;
    outputDigests: openArray[tuple[path, digest: string]] = []):
    ServiceInstanceKey =
  ## §4: the instance key `(identity, scope)`, resolved.
  let resolved = resolveServiceScope(def.scope, ctx)
  ServiceInstanceKey(
    identityKind: def.identity.kind,
    identity: serviceIdentity(def, outputDigests),
    scope: resolved.scope,
    scopeKey: resolved.key,
    degradation: resolved.degradation)

proc scopeKeyDigest*(key: ServiceInstanceKey): string =
  ## The scope key as a path component. Digested rather than encoded
  ## because a project root is an absolute path: encoding it reversibly
  ## produces one very long component, and the scope key is not something
  ## a reader needs to recover from the path. The IDENTITY is.
  blake3.digest(scopeWord(key.scope) & "\x00" & key.scopeKey)
    .toHex()[0 ..< ServiceScopeKeyDigestChars]

proc serviceStateRoot*(storeRoot: string; key: ServiceInstanceKey): string =
  ## §4.4: "A `stable` service's state directory is addressed by its
  ## identity." This is that address.
  ##
  ##   <storeRoot>/services/<scope>/<scopeKeyDigest>/<encoded identity>
  ##
  ## The IDENTITY component is `encodeLockPathSegment`d rather than
  ## digested, and that is the §4.4 claim made legible: a stable id of
  ## `io.metacraft.sso` is filename-shaped already and encodes to itself,
  ## so the directory a developer finds on disk is named after the
  ## identity they wrote in the recipe, and `decodeLockPathSegment`
  ## recovers it for an id that is not. The encoder is reused rather than
  ## written again — it is already the repository's injective,
  ## invertible, Windows-safe name→component map.
  ##
  ## WHERE A PATH DOES AND DOES NOT APPEAR. At `scope project` the scope
  ## key IS a project root, so its digest is in the path — correctly, and
  ## that is the definition of the scope rather than the defect §4.4
  ## names. At `workspace` scope with a workspace identity, and at `user`
  ## and `system` scope, NO component is derived from any consumer's
  ## path: two worktrees resolve to one directory. That is the property
  ## the gate's two-worktree clause measures, and it is asserted
  ## positively (the two roots agree) and negatively (neither root's text
  ## occurs in the result).
  ##
  ## `storeRoot` is explicit, never defaulted. It is the per-scope state
  ## store (`$HOME/.cache/repro/state` for the user daemon,
  ## `leaseStoreRootForScope`'s system root for the system one), and a
  ## test passes a throwaway directory. Defaulting it would make a test
  ## that forgot to override it write into the developer's live state.
  if storeRoot.len == 0:
    raise newException(ServiceIdentityError,
      "serviceStateRoot needs an explicit state-store root; see the " &
      "`storeRoot` note on this proc")
  storeRoot / ServiceStateDirName / scopeWord(key.scope) /
    scopeKeyDigest(key) / encodeLockPathSegment(key.identity)

proc serviceInstanceAddress*(key: ServiceInstanceKey): string =
  ## The key as the resource ADDRESS a lease is taken on. `lease.nim`'s
  ## `leased(address, consumerId, policy)` reference-counts holders per
  ## address, so this is what makes "one lease per holder on one
  ## instance" (§4.5) the existing lease lane's behaviour rather than new
  ## machinery.
  "service:" & scopeWord(key.scope) & ":" & scopeKeyDigest(key) & ":" &
    identityKindWord(key.identityKind) & ":" & key.identity

proc serviceLeaseHolderId*(consumingProjectRoot: string): string =
  ## §4.5: "one holder per consuming project". The holder id is the
  ## consuming project's canonical root, which is the one thing that is
  ## per-consumer and stable across its runs — `repro down` in one
  ## project must drop that project's reference and no other's.
  ##
  ## This is a PATH, and it is not a counter-example to §4.4: §4.4 is
  ## about where the shared instance's STATE lives, and this never
  ## reaches a state path. It is the name of a holder, and the holders
  ## are exactly the distinct consumers.
  let root = canonicalRoot(consumingProjectRoot)
  if root.len == 0:
    raise newException(ServiceIdentityError,
      "a lease holder id needs the consuming project's root")
  "project:" & root

proc degradationReport*(key: ServiceInstanceKey): string =
  ## The key's degradation sentence, or `""`. A one-line accessor so a
  ## caller has no excuse to drop it.
  key.degradation
