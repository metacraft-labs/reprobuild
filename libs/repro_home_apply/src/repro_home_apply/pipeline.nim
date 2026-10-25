## Apply pipeline orchestrator. Owns the 11-step sequence from
## [Home-Profile-Generations-And-State.md] "Apply Pipeline":
##
##   Step  1.  Acquire `apply.lock`
##   Step  2.  Load intent layer (M60)
##   Step  3.  Finalize configurables (M58, Phase A no-op)
##   Step  4.  Compute generation id
##   Step  5.  Plan diff against current generation
##   Step  6.  No-op short-circuit
##   Step  7.  Realize packages (M55/M56)
##   Step  8.  Stage generated files + managed blocks (M59)
##   Step  9.  Materialize launch plans (M57)
##   Step 10.  Atomic switch of `current`
##   Step 11.  Commit manifest + register store roots + eager GC
##
## Test injection: setting `REPRO_TEST_APPLY_KILL_AFTER_STEP=<N>`
## causes the pipeline to write the partial-apply marker and raise
## `EApplyKilledByTestHook` after completing step N. The marker is
## intentionally left in place so the next apply's recovery sweep
## can quarantine the partial generation.

import std/[algorithm, options, os, sequtils, sets, strutils, tables, times]
from repro_core/paths import extendedPath

import blake3
import repro_home_generations
import repro_home_intent
import repro_home_resources
import repro_homebrew_adapter
import repro_local_store

import ./app_activation
from ./builtin_adapter import appPlacedItem, isMacosInstallerApp
import ./dep_graph
import ./env_binding
import ./errors
import ./plan
import ./realize
import ./home_lock
import ./package_catalog
import ./materialize_files
import ./materialize_managed_blocks
import ./materialize_launchers
import ./current_rotation
import ./partial_recovery
import ./stow
import ./suppression
import ./file_facts

const
  KillStepEnvVar* = "REPRO_TEST_APPLY_KILL_AFTER_STEP"
  PackageGeneratesEnvVar* = "REPRO_TEST_PACKAGE_GENERATES"
    ## Phase B test hook: semicolon-separated
    ## `<pkg>=<home-rel-path>:<content>` entries. Each entry asks the
    ## planner to synthesize a package-output `GeneratedFile` for the
    ## named package. The gate 6 fixture uses this hook to stage a
    ## `git-config` package that would write `~/.gitconfig` so the
    ## stow-suppression code path is exercised end-to-end without
    ## requiring the full M59 stdlib.
  PackageManagedBlocksEnvVar* = "REPRO_TEST_PACKAGE_MANAGED_BLOCKS"
    ## M64 test hook: semicolon-separated
    ## `<pkg>=<home-rel-host>#<block-id>:<content>` entries. Each entry
    ## asks the pipeline to materialize a managed block in the named
    ## host file with the named id and content. Used by the M64
    ## rollback gates to populate managed blocks in `~/.bashrc` without
    ## requiring the full M59 `fs.managedBlock` stdlib hook.
  ResourcesEnvVar* = "REPRO_TEST_RESOURCES"
    ## M68 test hook: pipe-separated resource declarations. Each
    ## entry is `<kind>:<address>:<resource-specific-payload>`.
    ## Supported in Phase A:
    ##   - `registry:<address>:<HKCU-subkey>;<name>;<valuekind>;<value>[;broadcast]`
    ##       e.g. `registry:test:r:Software\Reprobuild-Tests\T1;Hello;string;world`
    ##   - `envvar:<address>:<name>;<valuekind>;<value>`
    ##       e.g. `envvar:test:e:MY_VAR;expandString;%USERPROFILE%\bin`
    ##   - `userpath:<address>:<entry>[,<entry>...]`
    ##       e.g. `userpath:test:p:C:\foo,C:\bar`
    ##   - `startup:<address>:<name>;<command>`
    ##   - `shellint:<address>:<host-file>;<block-id>;<content>`
    ##   - `managedblock:<address>:<host-file>;<block-id>;<content>`
    ## Multiple entries are separated by `|`. The gate uses this seam
    ## to drive the resource lifecycle without a full M59 stdlib
    ## resource emitter.
  ReconcileDriftEnvVar* = "REPRO_HOME_APPLY_RECONCILE_DRIFT"
    ## M68: when set to `1`, the apply pipeline uses
    ## `rpReconcileDrift` for the lifecycle decision; equivalent
    ## to the CLI's `--reconcile-drift` flag.
  AcceptOverwriteEnvVar* = "REPRO_HOME_APPLY_ACCEPT_OVERWRITE"
    ## M68: when set to `1`, the apply pipeline uses
    ## `rpAcceptOverwrite`; equivalent to `--accept-overwrite`.
  NoOpLogPrefix* = "no-op: generation matches; verified "
    ## Stable rendering used by gate 2's assertion.

type
  ApplyOutcomeKind* = enum
    aokFreshApplied = "fresh-applied"
    aokNoOpVerified = "noop-verified"

  PlanItemAction* = enum
    ## M72 Deliverable 2: the per-item verdict in a `--plan` preview.
    piaRealize = "realize"            ## package: genuine fresh realize
    piaCacheHit = "cache-hit"         ## package/stow: already satisfied
    piaMissing = "missing"            ## package: unknown to all catalogs
    piaLink = "link"                  ## stow file: would create a link
    piaConflictDrift = "conflict-drift" ## stow file / resource: drift
    piaWrite = "write"                ## generated file / block / launcher
    piaCreate = "create"              ## resource: would be created
    piaUpdate = "update"              ## resource: would be updated
    piaDestroy = "destroy"            ## resource: would be destroyed
    piaNoOp = "no-op"                 ## resource / item: nothing to do
    piaSkip = "skip"                  ## stow: loose file, not materialized
    piaRelease = "release"            ## a record of a concern the host no
                                      ## longer applies: left in place, no
                                      ## longer recorded (never destroyed)

  PlanItem* = object
    ## One previewed operation in a `repro home apply --plan` run.
    category*: string                 ## "package" | "app-bundle" | "stow"
                                       ## | "generated-file"
                                       ## | "managed-block" | "launcher"
                                       ## | "resource"
    name*: string                     ## package id / target path / address
    action*: PlanItemAction
    detail*: string                   ## human-readable extra context
    concern*: HomeConcern             ## the concern the operation belongs
                                      ## to (Gradual-Nix-To-Reprobuild-
                                      ## Migration.md §Concern-scoped apply)
    notApplied*: bool                 ## the host does not apply `concern`:
                                      ## planned and shown, never executed,
                                      ## never drift

  PlanPreview* = object
    ## M72 Deliverable 2: the result of `repro home apply --plan`.
    ## A non-mutating preview of the full apply.
    items*: seq[PlanItem]
    driftCount*: int                   ## items whose action is a drift
    generationIdHex*: string           ## the generation id this plan
                                       ## would produce
    isNoOp*: bool                      ## true when the plan matches the
                                       ## active generation exactly
    host*: string                      ## the host the plan is for
    applied*: AppliedConcerns          ## the concerns the apply would
                                       ## execute on `host`
    notAppliedCount*: int              ## items of other concerns (shown,
                                       ## not executed)
    releasedCount*: int                ## records of concerns no longer
                                       ## applied (`piaRelease` items)

  ApplyMode* = enum
    ## Hint to step 3 (configurable refinalize) describing what kind
    ## of change the caller knows about. `amFull` is the default —
    ## the pipeline performs a full refinalize over every
    ## configurable in the profile. `amSet` is used by the M65
    ## `repro home set` command, which knows exactly one
    ## `<pkg>.<key>` pair changed; step 3 calls into the M58
    ## `withOverrides` incremental refinalize seeded with that key
    ## and only configurables whose dependency closure includes it
    ## are re-derived. Generated files whose new content digest
    ## matches the previous generation's digest cache-hit and are
    ## not re-staged.
    amFull = "full"
    amSet = "set"

  ApplyOutcome* = object
    kind*: ApplyOutcomeKind
    generationIdHex*: string
    activationManifestDigestHex*: string
    diagnostics*: seq[StowDiagnostic]
    abortedRecovered*: seq[AbortedGenerationRecord]
    verifiedDigestCount*: int
    gcResult*: GcReport
      ## Step 11 eager-GC report. `gcResult.ranAt == 0` iff the
      ## pipeline took the no-op short-circuit (eager GC only runs on
      ## the fresh-applied branch). On `aokFreshApplied`, `ranAt` is
      ## non-zero and the per-record sequences (`quarantined`,
      ## `quarantinedPaths`, `reclaimed`) are authoritative.
    cacheHitCount*: int
      ## M65: number of generated files whose new content digest
      ## matched the previous generation's recorded post-write
      ## digest for the same absolute path. Such files are NOT
      ## re-staged — the on-disk bytes are already correct and the
      ## new manifest records reuse the digest.
    rebuiltCount*: int
      ## M65: number of generated files whose digest changed (or
      ## whose path is new in this generation). These are written
      ## through the staging-then-rename protocol.
    applied*: AppliedConcerns
      ## GM7: the concerns this apply executed (the host's
      ## `hosts.<host>.applies`, or every concern).
    notAppliedCount*: int
      ## GM7: planned operations of concerns the host does not apply —
      ## package references, stow entries, generated files, resources —
      ## that were not executed.
    released*: seq[string]
      ## GM7: what the previous generation recorded in a concern this
      ## apply does not own, released rather than removed: left in place
      ## and not recorded by the new generation. One `<kind> <name>` line
      ## each.
    deferred*: seq[string]
      ## Resources whose update, replace or destroy was deferred because
      ## the live object is in use -- a placed application that is running
      ## (Store-And-Installation-Layout.md § macOS Application Bundles,
      ## "Running applications"). One `<address> <why>` line each; the
      ## next apply does them.
    keptVendorUpdates*: seq[string]
      ## Placed applications that updated themselves to a newer build of
      ## their vendor than the profile declares, kept rather than
      ## downgraded ("Vendor updates"). One `<address> <version>` line each.

  ApplyOptions* = object
    profileDir*: string                ## "" → resolveProfileDir()
    profilePath*: string               ## "" → resolveProfilePath()
    host*: string                      ## "" → currentHost()
    targetContext*: HostContext        ## M71 Phase B: explicit
                                        ## target facts for local
                                        ## cross-host evaluation.
    hasTargetContext*: bool             ## false → use current-host
                                        ## platform/arch facts.
    stateDir*: string                  ## "" → resolveStateDir()
    storeRoot*: string                 ## "" → resolveStoreRoot()
    homeDir*: string                   ## "" → getHomeDir()
    activationTimestamp*: int64        ## 0 → getTime().toUnix
    applyMode*: ApplyMode               ## default amFull
    setOverrideKey*: string             ## `<pkg>.<key>` when applyMode
                                        ## is amSet; otherwise empty.
                                        ## The pipeline emits a log line
                                        ## acknowledging the focused
                                        ## refinalize so callers (and
                                        ## gates) can observe which seam
                                        ## was used.
    adoptAddresses*: seq[string]        ## M68 Phase B: resource
                                        ## addresses `repro home adopt`
                                        ## asked the apply pipeline to
                                        ## CLAIM rather than create /
                                        ## update. For an adopt address
                                        ## the resource step skips the
                                        ## driver write and records the
                                        ## live observed bytes as both
                                        ## the pre- and post-write
                                        ## digest. The address MUST be
                                        ## in the desired set or the
                                        ## pipeline raises
                                        ## `EAdoptUndeclared`.
    reconcileStowDrift*: bool           ## M72: when true, the stow
                                        ## materializer replaces a
                                        ## conflicting target instead
                                        ## of raising `EStowConflict`
                                        ## (the `--reconcile-drift` /
                                        ## `--accept-overwrite` gate).
    preLoadedProfile*: Profile          ## M83 Phase D: when non-nil,
                                        ## the apply pipeline uses
                                        ## this `Profile` (typically
                                        ## produced by the
                                        ## `compileProfileToRbpi ->
                                        ## profileIntentToHomeProfile`
                                        ## adapter chain) instead of
                                        ## calling `loadProfile` on
                                        ## the source text. The
                                        ## profile's `path` field must
                                        ## still match `profilePath`
                                        ## so downstream snapshot
                                        ## hashing reads the source
                                        ## file as intent input.
    relock*: bool                       ## GM4b: ignore the home-profile
                                        ## lock's pins and re-select every
                                        ## package under the current
                                        ## policy (`--relock`); the lock
                                        ## is rewritten from the result.
    appTrust*: AppTrustPolicy           ## GM4c: relaxations of the macOS
                                        ## application trust checks
                                        ## (Developer ID chain,
                                        ## notarization). ``{}`` — the
                                        ## zero value — is strict, and
                                        ## no CLI path sets anything
                                        ## else; only a test whose
                                        ## fixture bundles are built at
                                        ## test time (and so cannot be
                                        ## Apple-signed or notarized)
                                        ## does. Signature integrity,
                                        ## bundle id, version and team
                                        ## are never relaxed.
    recordOnlyGeneratedFiles*: bool     ## M71 Phase E: source-side
                                        ## remote-bundle evaluation.
                                        ## Package-owned generated files
                                        ## are recorded in the manifest
                                        ## and CAS without writing the
                                        ## target home path locally.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc digestOf(content: openArray[byte]): Digest256 =
  let raw = blake3.digest(content)
  for i in 0 ..< 32:
    result[i] = raw[i]

proc digestFromKey(key: PrefixIdBytes): Digest256 =
  for i in 0 ..< 32:
    result[i] = key[i]

proc resolveOptions(opts: ApplyOptions): ApplyOptions =
  result = opts
  if result.profileDir.len == 0:
    result.profileDir = resolveProfileDir()
  if result.profilePath.len == 0:
    result.profilePath = result.profileDir / HomeProfileAnchor
  var ctx =
    if result.hasTargetContext:
      result.targetContext
    else:
      currentHostContext()
  if result.host.len == 0:
    if ctx.host.len == 0:
      ctx.host = currentHost()
    result.host = ctx.host
  else:
    ctx.host = result.host
  if ctx.platform.len == 0:
    ctx.platform = currentHostContext().platform
  if ctx.arch.len == 0:
    ctx.arch = currentHostContext().arch
  result.targetContext = ctx
  result.hasTargetContext = true
  if result.stateDir.len == 0:
    result.stateDir = resolveStateDir()
  if result.storeRoot.len == 0:
    result.storeRoot = resolveStoreRoot()
  if result.homeDir.len == 0:
    result.homeDir = getHomeDir()
  if result.activationTimestamp == 0:
    result.activationTimestamp = getTime().toUnix

proc shouldKillAfter(step: int): bool =
  let raw = getEnv(KillStepEnvVar)
  if raw.len == 0:
    return false
  try:
    parseInt(raw.strip()) == step
  except ValueError:
    false

proc unquoteValueSource(raw: string): string =
  ## `configValueSource` stores the raw RHS bytes including the
  ## surrounding double quotes that `setConfigurable` emits for
  ## string literals. The configurable resolver returns the
  ## logical value, so we strip a single pair of surrounding double
  ## quotes when present and unescape the two backslash escapes
  ## `setConfigurable` emits (`\"` and `\\`). Numeric / boolean
  ## literals pass through unchanged.
  if raw.len >= 2 and raw[0] == '"' and raw[^1] == '"':
    var s = raw[1 ..< raw.len - 1]
    s = s.replace("\\\"", "\"").replace("\\\\", "\\")
    return s
  raw

proc resolveConfigurablePlaceholders(content: string;
                                     overrides: seq[ConfigContribution]):
    string =
  ## Substitute every `{{configurable:<pkg>.<key>}}` token in `content`
  ## with the resolved string value from the harvested `config:`
  ## contributions. Tokens whose `<pkg>.<key>` is not declared by
  ## `config:` are left in place — the rest of the pipeline (apply,
  ## digest) treats them as literal text, which would surface as a
  ## test failure rather than silently swallow the typo. This is the
  ## fixture-level seam that lets gates exercise configurable-driven
  ## file content without a full M59 stdlib renderer.
  result = content
  const Open = "{{configurable:"
  const Close = "}}"
  var i = 0
  var rewritten = ""
  while i < result.len:
    let openIdx = result.find(Open, i)
    if openIdx < 0:
      rewritten.add(result[i .. ^1])
      break
    rewritten.add(result[i ..< openIdx])
    let keyStart = openIdx + Open.len
    let closeIdx = result.find(Close, keyStart)
    if closeIdx < 0:
      rewritten.add(result[openIdx .. ^1])
      break
    let key = result[keyStart ..< closeIdx]
    let dot = key.find('.')
    var resolved = ""
    var found = false
    if dot > 0:
      let pkg = key[0 ..< dot]
      let cfgKey = key[dot + 1 .. ^1]
      # Last write wins, as in `effectiveConfigAssignments`: `overrides`
      # are in declaration order, so the last match is the effective one.
      for c in overrides:
        if c.packageName == pkg and c.configKey == cfgKey:
          resolved = unquoteValueSource(c.configValue)
          found = true
    if found:
      rewritten.add(resolved)
    else:
      rewritten.add(result[openIdx ..< closeIdx + Close.len])
    i = closeIdx + Close.len
  result = rewritten

proc parseSyntheticPackageGenerates(homeDir: string;
                                    declaredPackages: seq[string];
                                    overrides: seq[ConfigContribution]):
    seq[PlannedGeneratedFile] =
  ## Read `REPRO_TEST_PACKAGE_GENERATES` and synthesize one
  ## `PlannedGeneratedFile` per declared `<pkg>=<rel>:<content>` entry
  ## whose package is in `declaredPackages`. Packages not in the plan
  ## (because no activity references them) are silently dropped — the
  ## suppression layer cannot suppress what wasn't going to happen.
  ##
  ## M65: the `<content>` may contain `{{configurable:<pkg>.<key>}}`
  ## placeholders. These are resolved against the harvested
  ## `config:` contributions so the fixture's generated file content
  ## naturally depends on a configurable. A `repro home set` that
  ## changes the configurable then changes the content bytes and the
  ## post-write digest, which the step-8 cache-hit-vs-rebuilt logic
  ## observes.
  let raw = getEnv(PackageGeneratesEnvVar)
  if raw.len == 0:
    return
  for piece in raw.split(';'):
    let trimmed = piece.strip()
    if trimmed.len == 0:
      continue
    let eq = trimmed.find('=')
    if eq <= 0:
      continue
    let pkg = trimmed[0 ..< eq].strip()
    if pkg notin declaredPackages:
      continue
    let rest = trimmed[eq + 1 .. ^1]
    let colon = rest.find(':')
    if colon <= 0:
      continue
    let relPath = rest[0 ..< colon].strip()
    let rawContent = rest[colon + 1 .. ^1]
    let content = resolveConfigurablePlaceholders(rawContent, overrides)
    var contentBytes = newSeq[byte](content.len)
    for i, ch in content:
      contentBytes[i] = byte(ord(ch))
    result.add(PlannedGeneratedFile(
      absoluteOutputPath: homeDir / relPath,
      relativeHomePath: relPath.replace('\\', '/'),
      sourceKind: pgfsPackageOutput,
      contributingPackage: pkg,
      stowSourcePath: "",
      contentBytes: contentBytes))

proc parseSyntheticResources*(homeDir: string): DesiredSet =
  ## Parse `REPRO_TEST_RESOURCES` into a `DesiredSet`. This is the
  ## fixture-level seam used by the M68 gates to drive the resource
  ## lifecycle without a full M59 stdlib emitter. Entries are
  ## pipe-separated.
  result = initDesiredSet()
  let raw = getEnv(ResourcesEnvVar)
  if raw.len == 0:
    return
  for piece in raw.split('|'):
    if piece.len == 0:
      continue
    let firstColon = piece.find(':')
    if firstColon <= 0:
      continue
    # Strip only the kind tag, not the payload — managed-block /
    # shell-integration content can legitimately include trailing
    # newlines that are byte-significant for drift comparison.
    let kindStr = piece[0 ..< firstColon].strip()
    let restAfterKind = piece[firstColon + 1 .. ^1]
    let addrColon = restAfterKind.find(':')
    if addrColon <= 0:
      continue
    var address = restAfterKind[0 ..< addrColon].strip()
    let payload = restAfterKind[addrColon + 1 .. ^1]
    # M68 Phase B: an optional `@<policy>` suffix on the address
    # carries the per-resource `lifecyclePolicy`. The production
    # M59 stdlib emitter will route the resource constructor's
    # `lifecyclePolicy = preventDestroy` attribute through here once
    # the typed `home.nim` resource constructors land; until then
    # this seam lets the gates exercise `preventDestroy` enforcement.
    var resourcePolicy = lpDefault
    let atIdx = address.rfind('@')
    if atIdx > 0:
      let policyTag = address[atIdx + 1 .. ^1].strip()
      try:
        resourcePolicy = lifecyclePolicyFromString(policyTag)
        address = address[0 ..< atIdx].strip()
      except ValueError:
        # Not a recognized policy tag — leave the `@` in the address.
        discard
    case kindStr
    of "registry":
      let parts = payload.split(';')
      if parts.len < 4:
        continue
      let subkey = parts[0]
      let name = parts[1]
      let valKind = parts[2]
      let value = parts[3]
      let broadcast = parts.len > 4 and parts[4] == "broadcast"
      var r = Resource(kind: rkWindowsRegistryValue, address: address,
        lifecyclePolicy: resourcePolicy,
        registryKey: subkey,
        registryName: name,
        registryBroadcastChange: broadcast)
      try:
        let rvk = registryValueKindFromString(valKind)
        r.registryPayload.kind = rvk
        case rvk
        of rvkString:
          r.registryPayload.bytes = encodeString(value)
        of rvkExpandString:
          r.registryPayload.bytes = encodeString(value)
        of rvkDword:
          r.registryPayload.bytes = encodeDword(uint32(parseBiggestUInt(value)))
        of rvkQword:
          r.registryPayload.bytes = encodeQword(uint64(parseBiggestUInt(value)))
        of rvkBinary:
          var hexClean = value
          if hexClean.startsWith("0x"): hexClean = hexClean[2 .. ^1]
          var bytes: seq[byte] = @[]
          var i = 0
          while i + 1 < hexClean.len:
            try:
              bytes.add(byte(parseHexInt(hexClean[i ..< i + 2])))
            except ValueError:
              break
            i += 2
          r.registryPayload.bytes = bytes
        of rvkMultiString:
          let items = value.split(',')
          r.registryPayload.bytes = encodeMultiString(items)
        result.add(r)
      except ValueError:
        discard
    of "envvar":
      let parts = payload.split(';')
      if parts.len < 3:
        continue
      var r = Resource(kind: rkEnvUserVariable, address: address,
        lifecyclePolicy: resourcePolicy,
        envVarName: parts[0],
        envVarHostFilePath: defaultUserPathHostFile(homeDir))
      try:
        let rvk = registryValueKindFromString(parts[1])
        r.envVarPayload.kind = rvk
        case rvk
        of rvkString, rvkExpandString:
          r.envVarPayload.bytes = encodeString(parts[2])
        else: continue
        result.add(r)
      except ValueError:
        discard
    of "userpath":
      let entries = payload.split(',')
      var clean: seq[string] = @[]
      for e in entries:
        let t = e.strip()
        if t.len > 0: clean.add(t)
      let r = Resource(kind: rkEnvUserPath, address: address,
        lifecyclePolicy: resourcePolicy,
        pathEntries: clean,
        pathHostFilePath: defaultUserPathHostFile(homeDir))
      result.add(r)
    of "startup":
      let parts = payload.split(';')
      if parts.len < 2: continue
      let r = Resource(kind: rkWindowsStartup, address: address,
        lifecyclePolicy: resourcePolicy,
        startupName: parts[0],
        startupCommand: parts[1])
      result.add(r)
    of "shellint":
      let parts = payload.split(';')
      if parts.len < 3: continue
      var hostFile = parts[0]
      # Resolve $PROFILE-relative hints.
      if hostFile.startsWith("~"):
        hostFile = homeDir & hostFile[1 .. ^1]
      let r = Resource(kind: rkShellIntegration, address: address,
        lifecyclePolicy: resourcePolicy,
        shellHostFilePath: hostFile,
        shellBlockId: parts[1],
        shellBlockContent: parts[2])
      result.add(r)
    of "managedblock":
      let parts = payload.split(';')
      if parts.len < 3: continue
      var hostFile = parts[0]
      if hostFile.startsWith("~"):
        hostFile = homeDir & hostFile[1 .. ^1]
      let r = Resource(kind: rkFsManagedBlock, address: address,
        lifecyclePolicy: resourcePolicy,
        hostFilePath: hostFile,
        managedBlockId: parts[1],
        managedBlockContent: parts[2])
      result.add(r)
    of "gsettings":
      # gsettings:<address>:<schema>;<path>;<key>;<gvariant-literal>
      # `<path>` is empty for non-relocatable schemas. The Phase B
      # driver only runs on Linux; off-Linux the apply step raises
      # ENotImplementedPlatform when this resource is reconciled.
      let parts = payload.split(';')
      if parts.len < 4: continue
      let r = Resource(kind: rkLinuxGsettings, address: address,
        lifecyclePolicy: resourcePolicy,
        gsettingsSchema: parts[0],
        gsettingsPath: parts[1],
        gsettingsKey: parts[2],
        gsettingsValueLiteral: parts[3])
      result.add(r)
    of "userdefault":
      # userdefault:<address>:<domain>;<key>;<value-literal>;<restartTarget>
      # `<restartTarget>` is empty when no killall is wanted. The
      # Phase B driver only runs on macOS.
      let parts = payload.split(';')
      if parts.len < 3: continue
      let restartTarget = if parts.len > 3: parts[3] else: ""
      let r = Resource(kind: rkMacosUserDefault, address: address,
        lifecyclePolicy: resourcePolicy,
        defaultsDomain: parts[0],
        defaultsKey: parts[1],
        defaultsValueLiteral: parts[2],
        defaultsRestartTarget: restartTarget)
      result.add(r)
    of "systemdunit":
      # systemdunit:<address>:<name>;<enabled 0|1>;<unit-content>
      let parts = payload.split(';')
      if parts.len < 3: continue
      let r = Resource(kind: rkSystemdUserUnit, address: address,
        lifecyclePolicy: resourcePolicy,
        unitName: parts[0],
        unitEnabled: parts[1] == "1",
        unitContent: parts[2])
      result.add(r)
    of "launchagent":
      # launchagent:<address>:<label>;<runAtLoad 0|1>;<plist-content>
      let parts = payload.split(';')
      if parts.len < 3: continue
      let r = Resource(kind: rkLaunchdUserAgent, address: address,
        lifecyclePolicy: resourcePolicy,
        launchdLabel: parts[0],
        launchdRunAtLoad: parts[1] == "1",
        launchdPlistContent: parts[2])
      result.add(r)
    of "dconfkey":
      # dconfkey:<address>:<key>;<value>
      # M83 step 7 Driver A test-seam form. The Linux-only driver
      # raises ENotImplementedPlatform off-Linux when reconciled.
      let parts = payload.split(';')
      if parts.len < 2: continue
      let r = Resource(kind: rkLinuxDconfKey, address: address,
        lifecyclePolicy: resourcePolicy,
        dconfKey: parts[0],
        dconfValue: parts[1])
      result.add(r)
    of "kdeconfigkey":
      # kdeconfigkey:<address>:<file>;<group>;<key>;<value>;<version>
      # M83 step 7 Driver B test-seam form. `<version>` is `5` or
      # `6`; an empty / missing component defaults to `6` per spec.
      let parts = payload.split(';')
      if parts.len < 4: continue
      var kdeVer = 6
      if parts.len > 4 and parts[4].len > 0:
        try: kdeVer = parseInt(parts[4])
        except ValueError: kdeVer = 6
      let r = Resource(kind: rkLinuxKdeConfigKey, address: address,
        lifecyclePolicy: resourcePolicy,
        kdeFile: parts[0],
        kdeGroup: parts[1],
        kdeKey: parts[2],
        kdeValue: parts[3],
        kdeVersion: kdeVer)
      result.add(r)
    of "homebrewformula":
      # homebrewformula:<address>:<name>;<version>;<arg1>,<arg2>,...
      # M83 step 9 Driver A test-seam form. `<version>` empty means
      # "track the tap's latest" (cache-hits on any installed
      # version). The args list uses comma separators so a single
      # `;` can keep the three top-level components ordered.
      let parts = payload.split(';')
      if parts.len < 1 or parts[0].len == 0: continue
      let formulaVer = if parts.len > 1: parts[1] else: ""
      var formulaArgs: seq[string] = @[]
      if parts.len > 2 and parts[2].len > 0:
        for a in parts[2].split(','):
          let t = a.strip()
          if t.len > 0: formulaArgs.add(t)
      let r = Resource(kind: rkHomebrewFormula, address: address,
        lifecyclePolicy: resourcePolicy,
        formulaName: parts[0],
        formulaVersion: formulaVer,
        formulaArgs: formulaArgs)
      result.add(r)
    of "homebrewcask":
      # homebrewcask:<address>:<name>;<version>;<arg1>,<arg2>,...
      # M83 step 9 Driver B test-seam form. Identical shape to
      # `homebrewformula` — only the resource kind differs.
      let parts = payload.split(';')
      if parts.len < 1 or parts[0].len == 0: continue
      let caskVer = if parts.len > 1: parts[1] else: ""
      var caskArgs: seq[string] = @[]
      if parts.len > 2 and parts[2].len > 0:
        for a in parts[2].split(','):
          let t = a.strip()
          if t.len > 0: caskArgs.add(t)
      let r = Resource(kind: rkHomebrewCask, address: address,
        lifecyclePolicy: resourcePolicy,
        caskName: parts[0],
        caskVersion: caskVer,
        caskArgs: caskArgs)
      result.add(r)
    else: discard

# ---------------------------------------------------------------------------
# M78: profile-declared resources.
# ---------------------------------------------------------------------------
#
# The `home.nim` `resources:` block (parsed by the M60 intent layer
# into `nkResourcesBlock` / `nkResourceEntry` / `nkResourceAttr`
# nodes) is materialized into the SAME `DesiredSet` / `Resource`
# objects that `parseSyntheticResources` produces, so profile-declared
# and `REPRO_TEST_RESOURCES` test-seam resources are interchangeable
# downstream through `composePlan`.

proc resourceAttrValue(raw: string): string =
  ## Decode a resource-attribute RHS into its logical string value.
  ## Handles `"..."` and `r"..."` Nim literals; bare tokens pass
  ## through. Mirrors `unquoteValueSource` plus raw-string support
  ## (registry keys read naturally as `r"HKCU\\..."`).
  if raw.len >= 3 and (raw[0] == 'r' or raw[0] == 'R') and
     raw[1] == '"' and raw[^1] == '"':
    # Raw string: backslashes are literal, no escape processing.
    return raw[2 ..< raw.len - 1]
  unquoteValueSource(raw)

proc resourceProfileError(profilePath: string; line: int;
                          msg: string) {.noreturn.} =
  ## A malformed `resources:` entry surfaces as `EUnstructured` with
  ## file/line, exactly as the intent parser's other rejections do.
  raiseUnstructured(profilePath, line, 1, msg,
    "a well-formed `resources:` entry")

proc attrOf(entry: IntentNode; key: string): string =
  for a in entry.resourceAttrs:
    if a.kind == nkResourceAttr and a.resourceAttrKey == key:
      return resourceAttrValue(a.resourceAttrValueSource)
  ""

proc hasAttr(entry: IntentNode; key: string): bool =
  for a in entry.resourceAttrs:
    if a.kind == nkResourceAttr and a.resourceAttrKey == key:
      return true
  false

proc requireAttr(profilePath: string; entry: IntentNode;
                 key: string): string =
  if not hasAttr(entry, key):
    resourceProfileError(profilePath, entry.resourceHeaderLine,
      "resource `" & entry.resourceKind & " " & entry.resourceAddress &
      "` is missing the required `" & key & "` attribute")
  attrOf(entry, key)

proc resourceFromEntry(profilePath, homeDir: string;
                       entry: IntentNode): Resource =
  ## Build one `Resource` from a parsed `nkResourceEntry`. The payload
  ## shapes match `parseSyntheticResources` exactly. A `host-file`
  ## path starting with `~` is resolved against `homeDir`.
  let address = entry.resourceAddress
  case entry.resourceKind
  of "env.userPath":
    let raw = requireAttr(profilePath, entry, "entries")
    var clean: seq[string] = @[]
    for e in raw.split(','):
      let t = e.strip()
      if t.len > 0: clean.add(t)
    result = Resource(kind: rkEnvUserPath, address: address,
      lifecyclePolicy: lpDefault, pathEntries: clean,
      pathHostFilePath: defaultUserPathHostFile(homeDir))
  of "fs.managedBlock":
    var hostFile = requireAttr(profilePath, entry, "hostFile")
    if hostFile.startsWith("~"):
      hostFile = homeDir & hostFile[1 .. ^1]
    result = Resource(kind: rkFsManagedBlock, address: address,
      lifecyclePolicy: lpDefault,
      hostFilePath: hostFile,
      managedBlockId: requireAttr(profilePath, entry, "blockId"),
      managedBlockContent: requireAttr(profilePath, entry, "content"))
  of "shell.integration":
    var hostFile = requireAttr(profilePath, entry, "hostFile")
    if hostFile.startsWith("~"):
      hostFile = homeDir & hostFile[1 .. ^1]
    result = Resource(kind: rkShellIntegration, address: address,
      lifecyclePolicy: lpDefault,
      shellHostFilePath: hostFile,
      shellBlockId: requireAttr(profilePath, entry, "blockId"),
      shellBlockContent: requireAttr(profilePath, entry, "content"))
  of "env.userVariable":
    let valueKindStr =
      if hasAttr(entry, "valueKind"): attrOf(entry, "valueKind")
      else: "string"
    var r = Resource(kind: rkEnvUserVariable, address: address,
      lifecyclePolicy: lpDefault,
      envVarName: requireAttr(profilePath, entry, "name"),
      envVarHostFilePath: defaultUserPathHostFile(homeDir))
    var rvk: RegistryValueKind
    try:
      rvk = registryValueKindFromString(valueKindStr)
    except ValueError:
      resourceProfileError(profilePath, entry.resourceHeaderLine,
        "resource `env.userVariable " & address &
        "` has an unknown valueKind `" & valueKindStr & "`")
    if rvk notin {rvkString, rvkExpandString}:
      resourceProfileError(profilePath, entry.resourceHeaderLine,
        "resource `env.userVariable " & address &
        "` valueKind must be `string` or `expandString`")
    r.envVarPayload.kind = rvk
    r.envVarPayload.bytes = encodeString(
      requireAttr(profilePath, entry, "value"))
    result = r
  of "windows.registryValue":
    let valueKindStr = requireAttr(profilePath, entry, "valueKind")
    var r = Resource(kind: rkWindowsRegistryValue, address: address,
      lifecyclePolicy: lpDefault,
      registryKey: requireAttr(profilePath, entry, "key"),
      registryName: requireAttr(profilePath, entry, "name"),
      registryBroadcastChange:
        hasAttr(entry, "broadcastChange") and
        attrOf(entry, "broadcastChange") == "true")
    let value = requireAttr(profilePath, entry, "value")
    var rvk: RegistryValueKind
    try:
      rvk = registryValueKindFromString(valueKindStr)
    except ValueError:
      resourceProfileError(profilePath, entry.resourceHeaderLine,
        "resource `windows.registryValue " & address &
        "` has an unknown valueKind `" & valueKindStr & "`")
    r.registryPayload.kind = rvk
    try:
      case rvk
      of rvkString, rvkExpandString:
        r.registryPayload.bytes = encodeString(value)
      of rvkDword:
        r.registryPayload.bytes = encodeDword(
          uint32(parseBiggestUInt(value)))
      of rvkQword:
        r.registryPayload.bytes = encodeQword(
          uint64(parseBiggestUInt(value)))
      of rvkMultiString:
        r.registryPayload.bytes = encodeMultiString(value.split(','))
      of rvkBinary:
        var hexClean = value
        if hexClean.startsWith("0x"): hexClean = hexClean[2 .. ^1]
        var bytes: seq[byte] = @[]
        var i = 0
        while i + 1 < hexClean.len:
          bytes.add(byte(parseHexInt(hexClean[i ..< i + 2])))
          i += 2
        r.registryPayload.bytes = bytes
    except ValueError:
      resourceProfileError(profilePath, entry.resourceHeaderLine,
        "resource `windows.registryValue " & address &
        "` has a value that is not valid for valueKind `" &
        valueKindStr & "`")
    result = r
  of "windows.startup":
    result = Resource(kind: rkWindowsStartup, address: address,
      lifecyclePolicy: lpDefault,
      startupName: requireAttr(profilePath, entry, "name"),
      startupCommand: requireAttr(profilePath, entry, "command"))
  of "fs.userFile":
    # Closed-set attribute validation: `fs.userFile` accepts exactly
    # `hostFile`, `content`, `contentFromCommand`, `mode`,
    # `executable`, `cacheKey`, plus the cross-kind `depends_on`. An
    # unknown key is refused so a typo ("modee", "execable") never
    # silently degrades to its default — it surfaces as
    # `EUnstructured` naming the offending key.
    const userFileAllowedKeys = ["hostFile", "content",
      "contentFromCommand", "mode", "executable", "cacheKey",
      "depends_on"]
    for a in entry.resourceAttrs:
      if a.kind == nkResourceAttr and a.resourceAttrKey notin userFileAllowedKeys:
        resourceProfileError(profilePath, a.resourceAttrLine,
          "resource `fs.userFile " & address &
          "` has unknown attribute `" & a.resourceAttrKey &
          "`; expected one of: " & userFileAllowedKeys.join(", "))
    # `~`-relative path expansion against the per-run home dir. Also
    # honor `${HOME}` / `${USERPROFILE}` so the same `home.nim` text
    # works under POSIX (`$HOME`) and Windows (`$USERPROFILE`)
    # without per-OS conditionals on the operator's side.
    var hostFile = requireAttr(profilePath, entry, "hostFile")
    if hostFile.startsWith("~"):
      hostFile = homeDir & hostFile[1 .. ^1]
    elif hostFile.startsWith("${HOME}"):
      hostFile = homeDir & hostFile["${HOME}".len .. ^1]
    elif hostFile.startsWith("${USERPROFILE}"):
      hostFile = homeDir & hostFile["${USERPROFILE}".len .. ^1]
    # M83 step 10: `content` + `contentFromCommand` are mutually
    # exclusive; exactly one MUST be set. Both empty is rejected
    # (a literal-empty file is expressible by setting `content =
    # ""` explicitly — that's the only attr-present case). Both
    # set is rejected because the apply path could only honor one
    # of them — silently picking either would mask an operator
    # error.
    let hasContent = hasAttr(entry, "content")
    let hasCmd = hasAttr(entry, "contentFromCommand")
    if hasContent and hasCmd:
      resourceProfileError(profilePath, entry.resourceHeaderLine,
        "resource `fs.userFile " & address &
        "` has both `content` and `contentFromCommand` set; the two " &
        "are mutually exclusive (set exactly one)")
    if not hasContent and not hasCmd:
      resourceProfileError(profilePath, entry.resourceHeaderLine,
        "resource `fs.userFile " & address &
        "` has neither `content` nor `contentFromCommand` set; one of " &
        "the two is required")
    var content = ""
    var cmdArgv: seq[string] = @[]
    if hasContent:
      content = attrOf(entry, "content")
    if hasCmd:
      # The adapter renders `seq[string]` as a comma-joined bare
      # text (mirroring `env.userPath`); the parser splits back on
      # `,`. An argv entry containing a comma is therefore not
      # representable — documented limitation; for the secrets use
      # case (`age -d -i <id> <src>`) commas do not appear in
      # paths/keys in practice.
      let raw = attrOf(entry, "contentFromCommand")
      for e in raw.split(','):
        let s = e.strip()
        if s.len > 0:
          cmdArgv.add(s)
      if cmdArgv.len == 0 or cmdArgv[0].len == 0:
        resourceProfileError(profilePath, entry.resourceHeaderLine,
          "resource `fs.userFile " & address &
          "` has an empty `contentFromCommand` (the first element " &
          "must be the program name and must be non-empty)")
    let cacheKey =
      if hasAttr(entry, "cacheKey"): attrOf(entry, "cacheKey")
      else: ""
    let executable =
      hasAttr(entry, "executable") and
      attrOf(entry, "executable") == "true"
    var mode = ""
    if hasAttr(entry, "mode"):
      mode = attrOf(entry, "mode")
    elif executable:
      mode = "0755"
    else:
      mode = "0644"
    # Closed-set mode validation: parse-test the octal here so an
    # invalid `mode` ("rwx", "0999", "12345") is rejected at parse
    # time rather than mid-apply when the driver tries to use it.
    # The empty string is permitted (defence in depth — the default
    # path above always sets a non-empty value).
    if mode.len > 0:
      try:
        discard parseModeOctal(mode)
      except ValueError as e:
        resourceProfileError(profilePath, entry.resourceHeaderLine,
          "resource `fs.userFile " & address &
          "` has invalid mode `" & mode & "`: " & e.msg)
    result = Resource(kind: rkFsUserFile, address: address,
      lifecyclePolicy: lpDefault,
      userFileHostPath: hostFile,
      userFileContent: content,
      userFileContentFromCommand: cmdArgv,
      userFileMode: mode,
      userFileExecutable: executable,
      userFileCacheKey: cacheKey)
  of "systemd.userUnit":
    # M83 step 4b — Linux home-scope user-service driver. Closed-set
    # attribute validation: a typo like `enableed` or `stat` is
    # rejected at parse time rather than silently degrading to the
    # default. The `address` attribute is not in this list — the
    # parser stores `address` on the entry header, not as an attr.
    const systemdUserUnitAllowedKeys = ["name", "content", "enabled",
      "state", "depends_on"]
    for a in entry.resourceAttrs:
      if a.kind == nkResourceAttr and
         a.resourceAttrKey notin systemdUserUnitAllowedKeys:
        resourceProfileError(profilePath, a.resourceAttrLine,
          "resource `systemd.userUnit " & address &
          "` has unknown attribute `" & a.resourceAttrKey &
          "`; expected one of: " & systemdUserUnitAllowedKeys.join(", "))
    let enabled =
      if hasAttr(entry, "enabled"): attrOf(entry, "enabled") == "true"
      else: true  # spec default
    let stateStr =
      if hasAttr(entry, "state"): attrOf(entry, "state")
      else: ""  # empty -> susRunning via systemdUnitStateFromString
    var state: SystemdUnitState
    try:
      state = systemdUnitStateFromString(stateStr)
    except ValueError as e:
      resourceProfileError(profilePath, entry.resourceHeaderLine,
        "resource `systemd.userUnit " & address & "` " & e.msg)
    result = Resource(kind: rkSystemdUserUnit, address: address,
      lifecyclePolicy: lpDefault,
      unitName: requireAttr(profilePath, entry, "name"),
      unitContent: requireAttr(profilePath, entry, "content"),
      unitEnabled: enabled,
      unitState: state)
  of "launchd.userAgent":
    # M83 step 4b — macOS home-scope user-service driver. Closed-set
    # attribute validation: `label`, `programArgs`, `runAtLoad`,
    # `keepAlive`, plus the cross-kind `depends_on`. An unknown key
    # surfaces as `EUnstructured`.
    const launchdUserAgentAllowedKeys = ["label", "programArgs",
      "runAtLoad", "keepAlive", "depends_on"]
    for a in entry.resourceAttrs:
      if a.kind == nkResourceAttr and
         a.resourceAttrKey notin launchdUserAgentAllowedKeys:
        resourceProfileError(profilePath, a.resourceAttrLine,
          "resource `launchd.userAgent " & address &
          "` has unknown attribute `" & a.resourceAttrKey &
          "`; expected one of: " & launchdUserAgentAllowedKeys.join(", "))
    let label = requireAttr(profilePath, entry, "label")
    # `programArgs` is rendered by the adapter as comma-joined bare
    # text (the legacy convention used by `env.userPath.entries` and
    # `vscode.extension.extensions`). Split it back into a typed
    # `seq[string]`; empty entries are dropped (so a trailing comma
    # or whitespace-only segment is tolerated).
    let progRaw = requireAttr(profilePath, entry, "programArgs")
    var programArgs: seq[string] = @[]
    for p in progRaw.split(','):
      let t = p.strip()
      if t.len > 0:
        programArgs.add(t)
    let runAtLoad =
      if hasAttr(entry, "runAtLoad"): attrOf(entry, "runAtLoad") == "true"
      else: true  # spec default
    let keepAlive =
      hasAttr(entry, "keepAlive") and attrOf(entry, "keepAlive") == "true"
    result = Resource(kind: rkLaunchdUserAgent, address: address,
      lifecyclePolicy: lpDefault,
      launchdLabel: label,
      launchdPlistContent: "",  # rendered on-demand by launchAgentPlistFor
      launchdRunAtLoad: runAtLoad,
      launchdProgramArgs: programArgs,
      launchdKeepAlive: keepAlive)
  of "vscode.extension":
    # Closed-set attribute validation.
    const vscodeAllowedKeys = ["extensions", "removeUnknown", "depends_on"]
    for a in entry.resourceAttrs:
      if a.kind == nkResourceAttr and a.resourceAttrKey notin vscodeAllowedKeys:
        resourceProfileError(profilePath, a.resourceAttrLine,
          "resource `vscode.extension " & address &
          "` has unknown attribute `" & a.resourceAttrKey &
          "`; expected one of: " & vscodeAllowedKeys.join(", "))
    let raw = requireAttr(profilePath, entry, "extensions")
    var exts: seq[string] = @[]
    for e in raw.split(','):
      let t = e.strip()
      if t.len > 0:
        if not isSafeExtensionId(t):
          resourceProfileError(profilePath, entry.resourceHeaderLine,
            "resource `vscode.extension " & address &
            "` has an unsafe extension ID `" & t &
            "` (charset: letters, digits, `.`, `-`, `_`, single `@`)")
        exts.add(t)
    let removeUnknown =
      hasAttr(entry, "removeUnknown") and
      attrOf(entry, "removeUnknown") == "true"
    result = Resource(kind: rkVscodeExtension, address: address,
      lifecyclePolicy: lpDefault,
      vscodeExtensions: exts,
      vscodeRemoveUnknown: removeUnknown)
  of "linux.dconfKey":
    # M83 step 7 Driver A — GNOME-stack settings via the `dconf` CLI.
    # Closed-set attribute validation: `key`, `value`, plus the
    # cross-kind `depends_on`. An unknown key surfaces as
    # `EUnstructured`.
    const dconfKeyAllowedKeys = ["key", "value", "depends_on"]
    for a in entry.resourceAttrs:
      if a.kind == nkResourceAttr and
         a.resourceAttrKey notin dconfKeyAllowedKeys:
        resourceProfileError(profilePath, a.resourceAttrLine,
          "resource `linux.dconfKey " & address &
          "` has unknown attribute `" & a.resourceAttrKey &
          "`; expected one of: " & dconfKeyAllowedKeys.join(", "))
    let key = requireAttr(profilePath, entry, "key")
    if not key.startsWith("/"):
      resourceProfileError(profilePath, entry.resourceHeaderLine,
        "resource `linux.dconfKey " & address &
        "` key `" & key &
        "` must be slash-prefixed (e.g. `/org/gnome/...`)")
    let value = requireAttr(profilePath, entry, "value")
    result = Resource(kind: rkLinuxDconfKey, address: address,
      lifecyclePolicy: lpDefault,
      dconfKey: key,
      dconfValue: value)
  of "linux.kdeConfigKey":
    # M83 step 7 Driver B — KDE Plasma settings via the
    # `kwriteconfig5` / `kwriteconfig6` CLI. Closed-set attribute
    # validation: `file`, `group`, `key`, `value`, `kdeVersion`,
    # plus the cross-kind `depends_on`.
    const kdeKeyAllowedKeys = ["file", "group", "key", "value",
      "kdeVersion", "depends_on"]
    for a in entry.resourceAttrs:
      if a.kind == nkResourceAttr and
         a.resourceAttrKey notin kdeKeyAllowedKeys:
        resourceProfileError(profilePath, a.resourceAttrLine,
          "resource `linux.kdeConfigKey " & address &
          "` has unknown attribute `" & a.resourceAttrKey &
          "`; expected one of: " & kdeKeyAllowedKeys.join(", "))
    let file = requireAttr(profilePath, entry, "file")
    let group = requireAttr(profilePath, entry, "group")
    let key = requireAttr(profilePath, entry, "key")
    let value = requireAttr(profilePath, entry, "value")
    var kdeVer = 6  # spec default
    if hasAttr(entry, "kdeVersion"):
      let vs = attrOf(entry, "kdeVersion")
      try:
        kdeVer = parseInt(vs)
      except ValueError:
        resourceProfileError(profilePath, entry.resourceHeaderLine,
          "resource `linux.kdeConfigKey " & address &
          "` has non-integer kdeVersion `" & vs & "`")
      if kdeVer != 5 and kdeVer != 6:
        resourceProfileError(profilePath, entry.resourceHeaderLine,
          "resource `linux.kdeConfigKey " & address &
          "` has invalid kdeVersion `" & vs &
          "` (must be 5 or 6)")
    result = Resource(kind: rkLinuxKdeConfigKey, address: address,
      lifecyclePolicy: lpDefault,
      kdeFile: file,
      kdeGroup: group,
      kdeKey: key,
      kdeValue: value,
      kdeVersion: kdeVer)
  of "pkg.homebrewFormula":
    # M83 step 9 Driver A — macOS Homebrew CLI formula via
    # `brew install`. Closed-set attribute validation: `name`,
    # `version`, `args`, plus the cross-kind `depends_on`.
    const homebrewFormulaAllowedKeys = ["name", "version", "args",
      "depends_on"]
    for a in entry.resourceAttrs:
      if a.kind == nkResourceAttr and
         a.resourceAttrKey notin homebrewFormulaAllowedKeys:
        resourceProfileError(profilePath, a.resourceAttrLine,
          "resource `pkg.homebrewFormula " & address &
          "` has unknown attribute `" & a.resourceAttrKey &
          "`; expected one of: " &
          homebrewFormulaAllowedKeys.join(", "))
    let name = requireAttr(profilePath, entry, "name")
    let version =
      if hasAttr(entry, "version"): attrOf(entry, "version")
      else: ""
    var args: seq[string] = @[]
    if hasAttr(entry, "args"):
      # The adapter renders a seq[string] FieldValue as a
      # comma-joined bare text (`renderFieldValueAsAttrSource` of
      # `fvkList`). Each entry passes through unchanged so we can
      # split it back here.
      for a in attrOf(entry, "args").split(','):
        let t = a.strip()
        if t.len > 0: args.add(t)
    result = Resource(kind: rkHomebrewFormula, address: address,
      lifecyclePolicy: lpDefault,
      formulaName: name,
      formulaVersion: version,
      formulaArgs: args)
  of "pkg.homebrewCask":
    # M83 step 9 Driver B — macOS Homebrew Cask via `brew install
    # --cask`. Closed-set attribute validation: `name`, `version`,
    # `args`, plus the cross-kind `depends_on`. Same shape as the
    # formula parser branch above.
    const homebrewCaskAllowedKeys = ["name", "version", "args",
      "depends_on"]
    for a in entry.resourceAttrs:
      if a.kind == nkResourceAttr and
         a.resourceAttrKey notin homebrewCaskAllowedKeys:
        resourceProfileError(profilePath, a.resourceAttrLine,
          "resource `pkg.homebrewCask " & address &
          "` has unknown attribute `" & a.resourceAttrKey &
          "`; expected one of: " &
          homebrewCaskAllowedKeys.join(", "))
    let name = requireAttr(profilePath, entry, "name")
    let version =
      if hasAttr(entry, "version"): attrOf(entry, "version")
      else: ""
    var args: seq[string] = @[]
    if hasAttr(entry, "args"):
      # See the formula branch: `seq[string]` FieldValue renders as
      # a comma-joined bare-text RHS that we split back here.
      for a in attrOf(entry, "args").split(','):
        let t = a.strip()
        if t.len > 0: args.add(t)
    result = Resource(kind: rkHomebrewCask, address: address,
      lifecyclePolicy: lpDefault,
      caskName: name,
      caskVersion: version,
      caskArgs: args)
  else:
    # The parser already rejects unknown kinds; this is a defensive
    # guard for any kind added to the model but not wired here.
    resourceProfileError(profilePath, entry.resourceHeaderLine,
      "resource kind `" & entry.resourceKind &
      "` is not materializable by the apply pipeline")
  # M82 home-scope follow-up: extract the optional
  # `depends_on = ["kind:name", ...]` attribute. Absent / empty is the
  # common case (most home resources have no declared dependencies).
  # The parser validates shape; the planner later resolves each
  # `(kind, name)` to a node in the dependency graph and adds an
  # explicit edge. Applies uniformly to ALL SIX home-scope kind
  # branches above.
  for a in entry.resourceAttrs:
    if a.kind == nkResourceAttr and a.resourceAttrKey == "depends_on":
      let parsed = parseDependsOnAttr(profilePath, entry, a)
      var deps: seq[ResourceDependency] = @[]
      for p in parsed:
        deps.add((kind: p.kind, name: p.name))
      result.dependsOn = deps
      break

proc collectProfileResources(profilePath, homeDir: string; ctx: HostContext;
                             activities: HashSet[string];
                             nodes: seq[IntentNode];
                             into: var DesiredSet) =
  ## Walk a `resources:` block body, emitting one `Resource` per
  ## reachable `nkResourceEntry`. A `nkCondBlock` is recursed into
  ## only when its predicate evaluates true against the host
  ## (`applicableResourceEntries`, the one guard walker), so a
  ## `when windows:`-guarded resource is materialized on Windows and
  ## absent under a non-matching predicate; an activity-scoped resource
  ## (GM9) only when `activities` enables its activity. Two resources may
  ## share an address as long as no host gets both.
  ##
  ## Likewise two resources a host gets may not write one real-world
  ## object -- one file, one variable, one block, one unit -- under two
  ## addresses (`file_facts.sharesTargetWith`). Each address is bound to
  ## what it writes, so the apply would write the object twice (the last
  ## declaration winning, and the next apply reporting the first
  ## resource's drift against the second's write), and removing either
  ## resource later would destroy what the other still declares. The pair
  ## is refused here, at plan time and before anything is written, naming
  ## both addresses and whatever they disagree on; `repro home facts` runs
  ## this same planner, so facts and apply refuse the same profiles
  ## (reprobuild-pm issue
  ## 2026-10-18-home-apply-applies-two-resources-for-one-path-or-variable;
  ## Home-Profile-Resource-Lifecycle.md §One Real-World Object, One
  ## Resource). Unlike a
  ## stow file on a resource's path (`resolveStowResourceOverlap`), an
  ## agreeing pair is refused too: a stow file has no binding to release,
  ## a second resource does.
  var lineOf = initTable[string, int]()
  for node in applicableResourceEntries(nodes, ctx, activities):
    let r = resourceFromEntry(profilePath, homeDir, node)
    if r.address in into.resources:
      resourceProfileError(profilePath, node.resourceHeaderLine,
        "duplicate resource address `" & r.address &
        "` in the profile's `resources:` block")
    for _, earlier in into.resources:
      if earlier.sharesTargetWith(r):
        let differing = differingTargetFields(earlier, r)
        let both = "resources `" & earlier.address & "` (line " &
          $lineOf.getOrDefault(earlier.address) & ") and `" & r.address &
          "` both write `" & resourceTargetLabel(r, homeDir) & "` (" &
          $r.kind & ")"
        resourceProfileError(profilePath, node.resourceHeaderLine,
          if differing.len > 0:
            both & " and disagree on " & differing.join(" and ") &
              "; one object has one writer: remove one of them"
          else:
            both & "; they agree, but each resource owns what it " &
              "writes, so removing either would destroy the other's: " &
              "declare it once")
    lineOf[r.address] = node.resourceHeaderLine
    into.add(r)

proc parseProfileResources*(profile: Profile; homeDir: string;
                            ctx: HostContext):
    DesiredSet =
  ## M78: build a `DesiredSet` from the parsed profile's `resources:`
  ## block. Predicates are resolved against `ctx`. Raises
  ## `EUnstructured` on a malformed entry.
  ##
  ## GM9: an activity-scoped resource is planned only when the host's
  ## selection -- `enabledActivitiesFor(profile, ctx.host)`, the planner's
  ## one host-selection rule, which `buildPlan` applies to packages too --
  ## enables its activity. The selection is computed only for a profile
  ## that has such a resource, so a profile without one plans resources
  ## exactly as before.
  result = initDesiredSet()
  let blkOpt = findResourcesBlock(profile)
  if blkOpt.isNone:
    return
  var activities = initHashSet[string]()
  if hasActivityScopedResource(blkOpt.get.resourcesEntries):
    activities = enabledActivitiesFor(profile, ctx.host)
  collectProfileResources(profile.path, homeDir, ctx, activities,
    blkOpt.get.resourcesEntries, result)

proc parseProfileResources*(profile: Profile; homeDir, host: string):
    DesiredSet =
  var ctx = currentHostContext()
  ctx.host = host
  parseProfileResources(profile, homeDir, ctx)

proc resourceSeedString*(desired: DesiredSet): string =
  ## A deterministic textual rendering of a `DesiredSet`, fed into the
  ## generation-id BLAKE3 derivation. Two applies whose composed
  ## resource sets differ (whether the difference came from the
  ## profile's `resources:` block or from `REPRO_TEST_RESOURCES`)
  ## produce different generation ids and therefore do not take the
  ## no-op short-circuit. `OrderedTable` preserves insertion order, so
  ## the rendering is stable for a fixed input.
  for address, r in desired.resources:
    result.add(address)
    result.add('\x1f')
    result.add($r.kind)
    result.add('\x1f')
    result.add(realWorldIdentity(r))
    result.add('\x1f')
    case r.kind
    of rkFsManagedBlock:
      result.add(r.managedBlockId & "\x1e" & r.managedBlockContent)
    of rkShellIntegration:
      result.add(r.shellBlockId & "\x1e" & r.shellBlockContent)
    of rkEnvUserPath:
      result.add(r.pathEntries.join(","))
    of rkEnvUserVariable:
      result.add($r.envVarPayload.kind & "\x1e")
      for b in r.envVarPayload.bytes: result.add(char(b))
    of rkWindowsRegistryValue:
      result.add($r.registryPayload.kind & "\x1e")
      for b in r.registryPayload.bytes: result.add(char(b))
      result.add('\x1e')
      result.add(if r.registryBroadcastChange: "1" else: "0")
    of rkWindowsStartup:
      result.add(r.startupName & "\x1e" & r.startupCommand)
    of rkLinuxGsettings:
      result.add(r.gsettingsValueLiteral)
    of rkSystemdUserUnit:
      result.add(r.unitContent)
    of rkMacosUserDefault:
      result.add(r.defaultsValueLiteral)
    of rkLaunchdUserAgent:
      result.add(r.launchdPlistContent)
    of rkFsUserFile:
      # Composite seed: host path + mode + content (or argv +
      # cacheKey when `contentFromCommand` is set). The seed is fed
      # into the generation-id derivation, so a mode-only or path-only
      # change ALSO bumps the id (the lifecycle's per-resource digest
      # is content-only — mode-only changes are intentionally not
      # treated as drift — but the generation id is content-addressed
      # over the FULL declared shape, including bookkeeping fields,
      # so the no-op short-circuit fires only when the inputs are
      # bytewise identical). For the `contentFromCommand` branch the
      # actual stdout bytes are not statically knowable; the seed
      # covers the `(argv, cacheKey)` pair so a change to either
      # bumps the generation id and forces re-planning.
      if r.userFileContentFromCommand.len > 0:
        result.add(r.userFileHostPath & "\x1e" & r.userFileMode &
          "\x1e" & "cmd:" & r.userFileCacheKey & "\x1e" &
          r.userFileContentFromCommand.join("\x1f"))
      else:
        result.add(r.userFileHostPath & "\x1e" & r.userFileMode &
          "\x1e" & r.userFileContent)
    of rkVscodeExtension:
      # The seed covers the declared extension list (sorted +
      # joined) and the removeUnknown flag so any change in EITHER
      # bumps the generation id.
      var sortedExts = r.vscodeExtensions
      sortedExts.sort()
      result.add(sortedExts.join(",") & "\x1e" &
        (if r.vscodeRemoveUnknown: "1" else: "0"))
    of rkLinuxDconfKey:
      # M83 step 7 Driver A. The dconf key + value uniquely
      # identifies the desired state; both go into the seed so a
      # change in either bumps the generation id.
      result.add(r.dconfKey & "\x1e" & r.dconfValue)
    of rkLinuxKdeConfigKey:
      # M83 step 7 Driver B. The KDE 4-tuple (file, group, key,
      # value) plus the major version go into the seed.
      result.add(r.kdeFile & "\x1e" & r.kdeGroup & "\x1e" &
        r.kdeKey & "\x1e" & r.kdeValue & "\x1e" & $r.kdeVersion)
    of rkHomebrewFormula:
      # M83 step 9 Driver A. The (name, version, args) triple
      # determines the desired state; all three contribute to the
      # seed so a version-pin tweak or args change bumps the
      # generation id. Args are joined with `,` (no entry contains
      # `,` — `isSafeHomebrewArg` rejects it as a metacharacter).
      result.add(r.formulaName & "\x1e" & r.formulaVersion &
        "\x1e" & r.formulaArgs.join(","))
    of rkHomebrewCask:
      # M83 step 9 Driver B. Same shape as the formula seed —
      # the (name, version, args) triple drives the generation id.
      result.add(r.caskName & "\x1e" & r.caskVersion &
        "\x1e" & r.caskArgs.join(","))
    of rkMacosAppBundle:
      # GM4c: synthesized from realized packages, whose selections are
      # already in the generation id; a profile cannot declare one. Seeded
      # anyway so the case stays exhaustive and meaningful.
      result.add(r.appBundleTargetDir & "\x1e" & r.appBundleName)
    result.add('\x1d')

proc composeDesiredResources*(profile: Profile; homeDir: string;
                              ctx: HostContext):
    DesiredSet =
  ## M78: the resource step's source of truth. The profile's
  ## `resources:` block is the production source; `REPRO_TEST_RESOURCES`
  ## remains a TEST-ONLY override — when set, its entries merge OVER /
  ## replace the profile-declared entries by address, so existing
  ## M68/M70 gates that drive the test seam keep working. When the
  ## env var is unset, the profile is the sole source.
  ##
  ## M82 home-scope follow-up: the resulting `DesiredSet`'s OrderedTable
  ## iteration order is TOPOLOGICALLY sorted — every producer appears
  ## before every consumer, with declaration index as the stable
  ## secondary key. The downstream `composePlan` iterates the set's
  ## `resources` table in insertion order, so this single reorder is
  ## enough to give the apply executor a dependency-correct action
  ## sequence. Cycles raise `EHomePlanCyclicDependency` here, before
  ## any observation or write. Independent resources keep their
  ## declaration order, so the emitted action stream is byte-comparable
  ## across runs of the same profile text.
  let profileSet = parseProfileResources(profile, homeDir, ctx)
  let seam = parseSyntheticResources(homeDir)
  # Linearize the merged set (profile + seam override) into a seq so
  # `dep_graph` can index into it; profile entries first in
  # declaration order, then seam entries; a seam entry sharing an
  # address with a profile entry REPLACES the profile entry in place
  # (preserving declaration order at the position the profile
  # declared the address). This matches the prior merge semantics.
  var ordered: seq[Resource]
  var indexByAddress: Table[string, int]
  for addr0, r in profileSet.resources:
    indexByAddress[addr0] = ordered.len
    ordered.add(r)
  for addr0, r in seam.resources:
    if addr0 in indexByAddress:
      ordered[indexByAddress[addr0]] = r
    else:
      indexByAddress[addr0] = ordered.len
      ordered.add(r)
  let sorted = orderResourcesTopologically(ordered)
  result = initDesiredSet()
  for r in sorted:
    result.resources[r.address] = r

proc composeDesiredResources*(profile: Profile; homeDir, host: string):
    DesiredSet =
  var ctx = currentHostContext()
  ctx.host = host
  composeDesiredResources(profile, homeDir, ctx)

proc parseSyntheticPackageManagedBlocks(homeDir: string;
                                        declaredPackages: seq[string]):
    seq[PlannedManagedBlock] =
  ## Read `REPRO_TEST_PACKAGE_MANAGED_BLOCKS` and synthesize one
  ## `PlannedManagedBlock` per declared
  ## `<pkg>=<rel-host>#<block-id>:<content>` entry whose package is
  ## in `declaredPackages`. The M64 rollback gates use this to stage
  ## a managed block in `~/.bashrc` without needing the full M59
  ## `fs.managedBlock` stdlib hook wired in.
  let raw = getEnv(PackageManagedBlocksEnvVar)
  if raw.len == 0:
    return
  for piece in raw.split(';'):
    let trimmed = piece.strip()
    if trimmed.len == 0:
      continue
    let eq = trimmed.find('=')
    if eq <= 0:
      continue
    let pkg = trimmed[0 ..< eq].strip()
    if pkg notin declaredPackages:
      continue
    let rest = trimmed[eq + 1 .. ^1]
    let hash = rest.find('#')
    if hash <= 0:
      continue
    let relHost = rest[0 ..< hash].strip()
    let afterHash = rest[hash + 1 .. ^1]
    let colon = afterHash.find(':')
    if colon <= 0:
      continue
    let blockId = afterHash[0 ..< colon].strip()
    let content = afterHash[colon + 1 .. ^1]
    result.add(PlannedManagedBlock(
      hostFilePath: homeDir / relHost,
      blockId: blockId,
      blockBytes: content))

# ---------------------------------------------------------------------------
# Plan derivation
# ---------------------------------------------------------------------------

proc loadProfileOrRaise(profilePath: string): Profile =
  try:
    return loadProfile(profilePath)
  except CatchableError as err:
    raiseIntentLoad(profilePath, err.msg)

proc resolveProfileFromOpts(opts: ApplyOptions): Profile =
  ## M83 Phase D: when the caller has already produced a `Profile`
  ## (typically via the compile-then-adapt path), reuse it instead of
  ## re-parsing the source. The pre-loaded profile's `path` is
  ## reconciled with the resolved options' `profilePath` so downstream
  ## snapshot-hashing reads the same file the pipeline thinks it
  ## loaded.
  if opts.preLoadedProfile != nil:
    let p = opts.preLoadedProfile
    if p.path.len == 0:
      p.path = opts.profilePath
    return p
  result = loadProfileOrRaise(opts.profilePath)
  # GM4: this fallback reads `home.nim` as TEXT; it does not run the
  # compile-then-adapt step that reads and expands plan-time data files
  # (`expandedHomeProfile`). Planning without the rows would apply a
  # profile with part of its declaration silently missing, so refuse
  # (Core-Invariants.md §Unrecognised Input Is Rejected, Not Skipped).
  if result.dataFileRefs.len > 0:
    raiseIntentLoad(opts.profilePath, "the profile declares plan-time data " &
      "files (" & result.dataFileRefs.join(", ") & "), which this apply " &
      "path cannot expand: it reads home.nim as text instead of compiling " &
      "it. Use `repro home apply` on the host itself")

proc profileIntentSnapshot*(profileDir: string; profile: Profile):
    IntentSnapshot =
  ## The generation's intent snapshot: the profile's source files plus
  ## (GM4) the plan-time data files the planner expanded for `profile`, with
  ## the exact bytes it read (`Profile.loadedDataFiles`). Recording the data
  ## here puts it in the generation id and keeps it with the generation, so
  ## rollback and `repro home history` never consult the live file. The
  ## one constructor for both the plan preview and the apply.
  ##
  ## The source files are the top-level `*.nim` files plus everything under
  ## the profile directory the compile was observed reading
  ## (`profileSourceFiles` over `Profile.compiledFrom`), so helper modules
  ## imported from subdirectories are recorded too. A data file is recorded
  ## once, with its data role.
  var dataPaths = initHashSet[string]()
  for f in profile.loadedDataFiles:
    dataPaths.incl f.path.replace('\\', '/')
  for e in profileSourceFiles(profileDir, profile.compiledFrom):
    if e.path notin dataPaths:
      result.files.add e
  for f in profile.loadedDataFiles:
    var bytes = newSeq[byte](f.content.len)
    for i, ch in f.content:
      bytes[i] = byte(ord(ch))
    result.files.add IntentFileEntry(path: f.path, content: bytes,
      role: ifrData)
  result.schemaVersion = encodedVersion(result)

proc deriveGenerationId(plan: ApplyPlan;
                        intentSnapshotDigest: Digest256;
                        resourcesSeed: string = "";
                        selectionSeed: string = ""): GenerationId =
  ## Per the spec ("Generation Identity") the generation id is
  ## content-addressed over the resolved plan + intent snapshot +
  ## host identity. It explicitly does NOT include the activation
  ## timestamp, the holder pid, the OS clock, or any other run-
  ## environment fact: two identical applies (back to back on the
  ## same machine, hours apart, on two machines) produce the same
  ## id. This is what makes the no-op short-circuit possible.
  ##
  ## M68: the resources emitter contributes its content bytes to
  ## the generation id so two applies whose resources differ
  ## produce different generation ids (and therefore don't take
  ## the no-op short-circuit). At Phase A the contribution is the
  ## raw `REPRO_TEST_RESOURCES` env-var string; production wiring
  ## will route the M59 stdlib resource emitter's structural
  ## bytes through this seam.
  var buf = canonicalPlanBytes(plan)
  for b in intentSnapshotDigest: buf.add(b)
  for ch in plan.hostIdentity: buf.add(byte(ord(ch)))
  for ch in resourcesSeed: buf.add(byte(ord(ch)))
  # GM4b: what each package reference SELECTED (kind + lock identity) is
  # part of the resolved plan. Without it a generation whose profile text is
  # unchanged would be a no-op even when the selection moved — a new
  # realization offered, a PATH executable replaced, a lock re-derived —
  # and the moved selection would never be realized. Appended only when
  # non-empty, so a package-less profile keeps the id it had.
  if selectionSeed.len > 0:
    for ch in "\x00selections:": buf.add(byte(ord(ch)))
    for ch in selectionSeed: buf.add(byte(ord(ch)))
  let full = blake3.digest(buf)
  for i in 0 ..< GenerationIdSize:
    result[i] = full[i]

proc userPathHostFromIdentity(resourceId: string): string =
  when defined(windows):
    ""
  else:
    let hash = resourceId.rfind('#')
    if hash > 0:
      resourceId[0 ..< hash]
    else:
      ""

proc userPathBlockIdFromIdentity(resourceId: string): string =
  ## Recover the per-resource block id from a POSIX `env.userPath`
  ## identity (`<hostFile>#<blockId>`). Empty on Windows.
  when defined(windows):
    ""
  else:
    let hash = resourceId.rfind('#')
    if hash > 0 and hash + 1 < resourceId.len:
      resourceId[hash + 1 .. ^1]
    else:
      ""

proc parseGsettingsIdentity(resourceId: string): tuple[schema, path, key: string] =
  const prefix = "gsettings:"
  if not resourceId.startsWith(prefix):
    return ("", "", "")
  let body = resourceId[prefix.len .. ^1]
  if '|' in body:
    let parts = body.split('|')
    if parts.len >= 3:
      return (parts[0], parts[1], parts[2])
  let colon = body.rfind(':')
  if colon > 0:
    return (body[0 ..< colon], "", body[colon + 1 .. ^1])
  ("", "", "")

proc parseTwoPartIdentity(resourceId, prefix: string): tuple[a, b: string] =
  if not resourceId.startsWith(prefix):
    return ("", "")
  let body = resourceId[prefix.len .. ^1]
  let colon = body.rfind(':')
  if colon > 0:
    (body[0 ..< colon], body[colon + 1 .. ^1])
  else:
    ("", "")

# ---------------------------------------------------------------------------
# No-op verification
# ---------------------------------------------------------------------------

const DeferredPayloadMark = "+deferred"
  ## Appended to a recorded binding's `payloadKind` when the apply deferred
  ## a change to it because the live object was in use (a running
  ## application). The bytes and digests are the live object's, as for any
  ## no-op; the mark only stops the next apply's no-op short-circuit, which
  ## would otherwise find the record matching the live object and never
  ## make the change the profile asks for.

proc isDeferredMarked(payloadKind: string): bool =
  payloadKind.endsWith(DeferredPayloadMark)

proc withoutDeferredMark(payloadKind: string): string =
  if isDeferredMarked(payloadKind):
    payloadKind[0 ..< payloadKind.len - DeferredPayloadMark.len]
  else:
    payloadKind

proc withDeferredMark(payloadKind: string): string =
  withoutDeferredMark(payloadKind) & DeferredPayloadMark

proc verifyManifestDigests(stateDir: string; store: var Store;
                           activeGenIdHex, homeDir: string;
                           outVerified: var int): bool =
  ## Apply pipeline step 6: load the active generation's pointer +
  ## manifest, then verify every recorded post-write digest against
  ## the live filesystem. Returns true when everything matches.
  let pointerFile = pointerPath(stateDir, activeGenIdHex)
  if not fileExists(extendedPath(pointerFile)):
    return false
  let env = readPointerFile(pointerFile)
  var manifestKey: PrefixIdBytes
  for i in 0 ..< 32:
    manifestKey[i] = env.activationManifestDigest[i]
  let manifestBytes = readCasBlob(store, manifestKey)
  let manifest = decodeManifestBytes(manifestBytes)
  outVerified = 0
  # Generated files: postWriteDigest matches live content (for owned/
  # merged) or stow source still resolves (for stow-symlink / stow-
  # junction; phase A treats both as "live link exists").
  for gf in manifest.generatedFiles:
    case gf.ownershipPolicy
    of gfoStowSymlink, gfoStowJunction:
      # The link itself must exist; phase B can extend to verify the
      # link target.
      if not symlinkExists(extendedPath(gf.absoluteOutputPath)) and
         not fileExists(extendedPath(gf.absoluteOutputPath)):
        return false
    of gfoOwned, gfoMerged, gfoExistingPreserved, gfoStowCopy:
      if not fileExists(extendedPath(gf.absoluteOutputPath)):
        return false
      let raw = readFile(extendedPath(gf.absoluteOutputPath))
      var buf = newSeq[byte](raw.len)
      for i, ch in raw:
        buf[i] = byte(ord(ch))
      if digestOf(buf) != gf.postWriteDigest:
        return false
    inc outVerified
  for ec in manifest.exportedCommands:
    when defined(windows):
      let binDir = stableBinDir(stateDir)
      let cmdExe = binDir / (ec.commandName & ".exe")
      let cmdShim = binDir / (ec.commandName & ".cmd")
      if not fileExists(extendedPath(cmdExe)) and not fileExists(extendedPath(cmdShim)):
        return false
    else:
      let binDir = generationBinDir(stateDir, activeGenIdHex)
      let cmdScript = binDir / ec.commandName
      if not fileExists(extendedPath(cmdScript)):
        return false
    inc outVerified
  # M68: verify recorded resource bindings still match the live
  # state. Drift on any resource breaks the no-op short-circuit so
  # the apply re-enters the full pipeline and decides per the
  # lifecycle algorithm (which raises EDrift unless
  # --reconcile-drift was passed).
  for rb in manifest.resourceBindings:
    if rb.resourceKind.len == 0:
      continue
    let recordedDigest = rb.postWriteDigest
    var live: ObservedState
    try:
      let kindEnum = resourceKindFromString(rb.resourceKind)
      case kindEnum
      of rkWindowsRegistryValue:
        let bs = rb.realWorldIdentity.rfind('\\')
        if bs > 0:
          live = observeRegistryValue(
            rb.realWorldIdentity[0 ..< bs],
            rb.realWorldIdentity[bs + 1 .. ^1])
      of rkEnvUserVariable:
        let name = userVariableNameFromIdentity(rb.realWorldIdentity)
        if name.len > 0:
          live = observeUserVariable(name,
            userVariableHostFromIdentity(rb.realWorldIdentity))
      of rkEnvUserPath:
        let entries = parseRecordedPathEntries(rb.payloadBytes)
        live = observeUserPath(entries,
          userPathHostFromIdentity(rb.realWorldIdentity),
          userPathBlockIdFromIdentity(rb.realWorldIdentity))
      of rkWindowsStartup:
        let bs = rb.realWorldIdentity.rfind('\\')
        if bs > 0:
          live = observeStartup(rb.realWorldIdentity[bs + 1 .. ^1])
      of rkShellIntegration, rkFsManagedBlock:
        let hash = rb.realWorldIdentity.rfind('#')
        if hash > 0:
          live = observeManagedBlock(
            rb.realWorldIdentity[0 ..< hash],
            rb.realWorldIdentity[hash + 1 .. ^1])
      of rkLinuxGsettings:
        let parsed = parseGsettingsIdentity(rb.realWorldIdentity)
        if parsed.schema.len > 0 and parsed.key.len > 0:
          live = observeGsettings(parsed.schema, parsed.path, parsed.key)
      of rkSystemdUserUnit:
        const sysPrefix = "systemd:user:"
        if rb.realWorldIdentity.startsWith(sysPrefix):
          live = observeUserUnit(homeDir,
            rb.realWorldIdentity[sysPrefix.len .. ^1])
      of rkMacosUserDefault:
        let parsed = parseTwoPartIdentity(rb.realWorldIdentity, "defaults:")
        if parsed.a.len > 0 and parsed.b.len > 0:
          live = observeUserDefault(parsed.a, parsed.b)
      of rkLaunchdUserAgent:
        const lcPrefix = "launchd:user:"
        if rb.realWorldIdentity.startsWith(lcPrefix):
          live = observeLaunchAgent(homeDir,
            rb.realWorldIdentity[lcPrefix.len .. ^1])
      of rkFsUserFile:
        # `realWorldIdentity` for `fs.userFile` IS the resolved host
        # path — no suffix to strip. Probe the file directly.
        live = observeUserFile(rb.realWorldIdentity)
      of rkVscodeExtension:
        # The vscode.extension resource is a singleton with the
        # fixed identity `vscode:extensions`. The verify pass reads
        # the recorded declared extension list from the binding's
        # payload bytes (one ID per line — the canonical apply-time
        # rendering) and re-observes against it.
        var declared: seq[string]
        var line = ""
        for b in rb.payloadBytes:
          if char(b) == '\n':
            if line.len > 0:
              declared.add(line)
            line = ""
          else:
            line.add(char(b))
        if line.len > 0:
          declared.add(line)
        live = observeVscodeExtensions(declared, false)
      of rkLinuxDconfKey:
        # `realWorldIdentity` for `linux.dconfKey` is `dconf:<key>`.
        const dcPrefix = "dconf:"
        if rb.realWorldIdentity.startsWith(dcPrefix):
          live = observeDconfKey(
            rb.realWorldIdentity[dcPrefix.len .. ^1])
      of rkLinuxKdeConfigKey:
        # `realWorldIdentity` for `linux.kdeConfigKey` is
        # `kde:<file>:<group>:<key>`. The recorded binding does not
        # carry `kdeVersion`; default to 6.
        const kdePrefix = "kde:"
        if rb.realWorldIdentity.startsWith(kdePrefix):
          let body = rb.realWorldIdentity[kdePrefix.len .. ^1]
          let parts = body.split(':')
          if parts.len >= 3:
            let kdeFile = parts[0]
            let kdeGroup = parts[1]
            let kdeKey = parts[2 .. ^1].join(":")
            live = observeKdeConfigKey(kdeFile, kdeGroup, kdeKey, 6)
      of rkHomebrewFormula:
        # `realWorldIdentity` for `pkg.homebrewFormula` is
        # `homebrew:formula:<name>`. The recorded `payloadBytes` is
        # `name + 0x1e + <encoded-version>`; the encoded-version
        # (empty for track-latest, literal for pinned) doubles as
        # the `desiredVersion` we pass to `observeHomebrewFormula`
        # so the re-encoding matches what was recorded.
        const formulaPrefix = "homebrew:formula:"
        if rb.realWorldIdentity.startsWith(formulaPrefix):
          let formulaName = rb.realWorldIdentity[formulaPrefix.len .. ^1]
          var encodedVersion = ""
          for i, b in rb.payloadBytes:
            if char(b) == '\x1e':
              if i + 1 < rb.payloadBytes.len:
                for j in i + 1 ..< rb.payloadBytes.len:
                  encodedVersion.add(char(rb.payloadBytes[j]))
              break
          live = observeHomebrewFormula(formulaName, encodedVersion)
      of rkHomebrewCask:
        # Parallel to the formula branch: identity is
        # `homebrew:cask:<name>`; payloadBytes is
        # `name + 0x1e + <encoded-version>`.
        const caskPrefix = "homebrew:cask:"
        if rb.realWorldIdentity.startsWith(caskPrefix):
          let caskName = rb.realWorldIdentity[caskPrefix.len .. ^1]
          var encodedVersion = ""
          for i, b in rb.payloadBytes:
            if char(b) == '\x1e':
              if i + 1 < rb.payloadBytes.len:
                for j in i + 1 ..< rb.payloadBytes.len:
                  encodedVersion.add(char(rb.payloadBytes[j]))
              break
          live = observeHomebrewCask(caskName, encodedVersion)
      of rkMacosAppBundle:
        # GM4c: the placed bundle still carries the recorded identity --
        # or its vendor's own update of it, which is not drift
        # (Store-And-Installation-Layout.md § macOS Application Bundles,
        # "Vendor updates"). A record whose change was deferred (the
        # application was running) is owed a change: never a no-op.
        if isDeferredMarked(rb.payloadKind):
          return false
        live = observeAppBundleAt(rb.realWorldIdentity)
        if live.present and live.digest != recordedDigest and
            isAcceptedVendorUpdate(rb.payloadBytes, live.rawBytes,
              rb.realWorldIdentity):
          inc outVerified
          continue
    except CatchableError:
      return false
    if not live.present:
      return false
    if live.digest != recordedDigest:
      return false
    inc outVerified
  true

# ---------------------------------------------------------------------------
# M72 Deliverable 2: `repro home apply --plan` dry-run
# ---------------------------------------------------------------------------

proc bindingOfLiveObject(address: string; desired: Resource;
                         observed: ObservedState): ResourceBinding =
  ## The binding that records a live object as it is, without a driver
  ## write: pre- == post-write == the observation. Used by `repro home
  ## adopt` (an existing object claimed) and by a first apply whose object
  ## already holds the declared state.
  let payloadKind =
    case desired.kind
    of rkWindowsRegistryValue: $desired.registryPayload.kind
    of rkEnvUserVariable: $desired.envVarPayload.kind
    of rkEnvUserPath: "joined-entries"
    of rkWindowsStartup: "string"
    of rkShellIntegration: "shell-block"
    of rkFsManagedBlock: "managed-block"
    of rkLinuxGsettings: "gvariant-literal"
    of rkSystemdUserUnit: "unit-content"
    of rkMacosUserDefault: "defaults-literal"
    of rkLaunchdUserAgent: "plist-content"
    of rkFsUserFile: "user-file"
    of rkVscodeExtension: "vscode-extensions"
    of rkLinuxDconfKey: "gvariant-literal"
    of rkLinuxKdeConfigKey: "kde-config-value"
    of rkHomebrewFormula: "homebrew-formula-version"
    of rkHomebrewCask: "homebrew-cask-version"
    of rkMacosAppBundle: "app-bundle-identity"
  toResourceBinding(address, desired.kind, realWorldIdentity(desired),
    observed, observed.rawBytes, payloadKind, desired.lifecyclePolicy)

proc previewStowItem(profileDir, homeDir: string;
                     entry: StowEntry;
                     recordedStow: Table[string, GeneratedFile]): PlanItem =
  ## Read-only classification of one stow entry: would it create a
  ## link, cache-hit (target already correct), or hit a conflict
  ## (target exists as a regular file / wrong link)? Performs ONLY
  ## reads — never touches the filesystem. `recordedStow` is the current
  ## generation's stow records by target path: a target that is still the
  ## link (or copy) recorded there from another source is replaced, as the
  ## apply does (`stow.isRecordedStowTarget`).
  result.category = "stow"
  result.name = entry.targetAbsolutePath
  let target = entry.targetAbsolutePath
  let source = entry.sourceAbsolutePath
  if target in recordedStow and
      isRecordedStowTarget(target, source, recordedStow[target]):
    result.action = piaLink
    result.detail = "would replace what the current generation " &
      "recorded (-> " & recordedStow[target].stowSource & ") with -> " & source
    return
  if not fileExists(extendedPath(target)) and not symlinkExists(extendedPath(target)) and
     not dirExists(extendedPath(target)):
    result.action = piaLink
    result.detail = "would link -> " & source
    return
  if symlinkExists(extendedPath(target)):
    # Compare by file identity (robust across Windows reparse-point
    # resolution quirks) — the same check the materializer uses.
    var pointsAtSource = false
    try:
      pointsAtSource = fileExists(extendedPath(source)) and sameFile(target, source)
    except OSError, IOError:
      pointsAtSource = false
    if pointsAtSource:
      result.action = piaCacheHit
      result.detail = "already correct link"
    elif stowTargetMatchesSource(target, source):
      # M76: a symlink/junction to a DIFFERENT source whose resolved
      # content is nonetheless byte-identical to the desired source is
      # a cache-hit — the apply path agrees (`tryCreateSymlink` /
      # copy fallback use the same `stowTargetMatchesSource` predicate).
      result.action = piaCacheHit
      result.detail = "existing link's resolved content is byte-identical " &
        "to the stow source"
    else:
      var resolved = ""
      try: resolved = expandSymlink(extendedPath(target))
      except OSError: resolved = ""
      result.action = piaConflictDrift
      result.detail = "existing symlink points at a different source (" &
        resolved & ")"
    return
  # A regular file (or directory) at the target path.
  if fileExists(extendedPath(target)):
    # M76: the ONE byte-identical predicate, shared with the apply
    # path (`tryCreateSymlink` and the stow copy fallback) — so a
    # plan that previews a cache-hit never fails at apply.
    if stowTargetMatchesSource(target, source):
      result.action = piaCacheHit
      result.detail = "regular file already byte-identical to source"
    else:
      result.action = piaConflictDrift
      result.detail = "existing regular file differs from the stow source"
  else:
    result.action = piaConflictDrift
    result.detail = "a directory occupies the stow file's target path"

# ---------------------------------------------------------------------------
# GM4b: package resolution context, selection seed, home-profile lock
# ---------------------------------------------------------------------------

proc targetIsThisHost(opts: ApplyOptions): bool =
  ## Whether the apply's target is the machine running it — the condition
  ## for consulting the host inventory (PATH, Scoop). A profile evaluated
  ## for another host (``--host`` remote apply, a bundle built for a
  ## different platform) must not resolve against this machine's PATH.
  let here = currentHostContext()
  opts.host == currentHost() and
    opts.targetContext.platform == here.platform and
    opts.targetContext.arch == here.arch

proc packageResolutionCatalog(opts: ApplyOptions; plan: ApplyPlan):
    ProfileCatalog =
  ## The catalog definitions the plan's references resolve against.
  # Provisioning-Contributions.md §"Profile Package References": a name the
  # `reprobuild-packages` catalog defines is projected the way a recipe
  # beside the profile would project its `uses:` (`catalog_projection`).
  var names: seq[string] = @[]
  for p in plan.packages:
    names.add(p.packageId)
  # A profile's `catalogs:` section imports contribution catalogs into the
  # same projection, as a recipe's `import` does.
  projectCatalogPackages(names, opts.profilePath,
    opts.stateDir / "catalog-projection", plan.catalogImports)

proc packageResolutionContext(opts: ApplyOptions; plan: ApplyPlan;
                              catalog: ProfileCatalog):
    ProfileResolutionContext =
  ## The one resolution context of an apply: target and policy from the
  ## options and the profile, the lock from beside the profile. ``--plan``
  ## and apply build it the same way, so they select the same realizations.
  let lock = readHomeProfileLock(homeProfileLockPath(opts.profileDir))
  profileResolutionContext(plan.adapterPreference,
    opts.targetContext.platform, opts.targetContext.arch,
    targetIsThisHost(opts), lock, opts.relock, catalog)

proc ownedAppBundleAddresses(stateDir: string; store: var Store;
                             activeGenIdHex: string): HashSet[string] =
  ## GM4c: the `macos.appBundle` addresses the active generation placed and
  ## still owns (a binding with a non-zero post-write digest). Empty when
  ## there is no active generation or its manifest cannot be read, which
  ## errs towards refusing to replace anything.
  if activeGenIdHex.len == 0:
    return
  let pointerFile = pointerPath(stateDir, activeGenIdHex)
  if not fileExists(extendedPath(pointerFile)):
    return
  try:
    let envelope = readPointerFile(pointerFile)
    var key: PrefixIdBytes
    for i in 0 ..< 32:
      key[i] = envelope.activationManifestDigest[i]
    let manifest = decodeManifestBytes(readCasBlob(store, key))
    for rb in manifest.resourceBindings:
      if rb.resourceKind == $rkMacosAppBundle and
          not isZeroDigest(rb.postWriteDigest):
        result.incl(rb.resourceAddress)
  except CatchableError:
    discard

# ---------------------------------------------------------------------------
# GM7: concern-scoped apply (Gradual-Nix-To-Reprobuild-Migration.md
# §Concern-scoped apply)
# ---------------------------------------------------------------------------

proc placesApplication*(pp: PackagePreview): bool =
  ## Whether the realization selected for a package reference places an
  ## application: an `app-bundle` record, or a macOS installer application
  ## (Store-And-Installation-Layout.md § macOS Application Bundles,
  ## § Installer applications). The ONE test for the `applications` concern
  ## of a package: the plan's app-bundle section, the apply's realization
  ## filter and its activation all derive from it.
  ##
  ## The install shape alone decides it, not ``archiveRoute``: every tarball
  ## record is realized by the shared provisioning edge (``arExtract``), so
  ## the route no longer distinguishes an application from a plain archive.
  pp.resolved and pp.resolution.selection.kind == rkTarball and
    (pp.resolution.archive.installMethod == imAppBundle or
     isMacosInstallerApp(pp.resolution.archive))

proc addApplicationCommands*(plan: var ApplyPlan;
                             previews: seq[PackagePreview]) =
  ## Add a launcher for every command an application package's selected
  ## record declares (``extraExecutable``), and refuse what the plan cannot
  ## honour, before anything is realized (Store-And-Installation-Layout.md
  ## § macOS Application Bundles, "Command line"):
  ##
  ## * a declared command path that is not inside the placed bundle
  ##   (reason ``command-path``);
  ## * a ``binaries`` name the profile gives an application reference that
  ##   its record does not provide (reason ``undeclared-binary``) -- the
  ##   name used to be read only as a PATH probe and silently dropped once
  ##   an application was selected (Core-Invariants.md §Unrecognised Input
  ##   Is Rejected, Not Skipped);
  ## * two packages exporting the same command (``command-collision``).
  ##
  ## Called by ``--plan`` and by the apply, after resolution and before the
  ## generation id is derived, so the commands are part of the plan bytes
  ## and the preview lists what the apply writes.
  var planned = initTable[string, PlannedPackage]()
  for p in plan.packages:
    planned[p.packageId] = p
  for pp in previews:
    if not placesApplication(pp):
      continue
    let archive = pp.resolution.archive
    let realization =
      if pp.resolution.selection.lockIdentity.len > 0:
        pp.resolution.selection.lockIdentity
      else: archive.urlUsed
    var provided = @[pp.packageId]
    for rel in applicationCommandPaths(archive):
      let problem = applicationCommandPathError(archive, rel)
      let name = commandNameOf(rel)
      if problem.len > 0:
        raisePackageCommandRefused(pp.packageId, name, realization,
          "command-path", "", "the realization " & realization &
          " declares the command " & rel.escape & "; " & problem)
      provided.add(name)
      if name == pp.packageId:
        # The declared command and the package launcher share a name: the
        # declared command is what that name runs.
        for l in plan.launchers.mitems:
          if l.fromPackageId == pp.packageId and l.commandName == name:
            l.executableRelPath = rel
        continue
      plan.launchers.add(PlannedLauncher(commandName: name,
        fromPackageId: pp.packageId, executableRelPath: rel))
    if pp.packageId in planned:
      for binary in planned[pp.packageId].binaries:
        if binary notin provided:
          raisePackageCommandRefused(pp.packageId, binary, realization,
            "undeclared-binary", "", "the profile declares binaries " &
            "containing '" & binary & "', but the selected realization " &
            realization & " places an application that provides only " &
            provided.join(", ") & ". Declare the command on the " &
            "application record (extraExecutable = \"<Name>.app/...\") " &
            "or remove it from binaries")
  var owner = initTable[string, string]()
  for l in plan.launchers:
    if l.commandName in owner and owner[l.commandName] != l.fromPackageId:
      raisePackageCommandRefused(l.fromPackageId, l.commandName, "",
        "command-collision", owner[l.commandName], "the command '" &
        l.commandName & "' is exported by package " & owner[l.commandName] &
        " and by package " & l.fromPackageId & "; a home profile bin " &
        "directory can hold only one")
    owner[l.commandName] = l.fromPackageId
  plan.launchers.sort(proc(a, b: PlannedLauncher): int =
    cmp(a.commandName, b.commandName))

proc packageConcern*(pp: PackagePreview): HomeConcern =
  ## A package reference's concern: `applications` when its selected
  ## realization places an application, `packages` otherwise — including a
  ## reference with no realization, which has no install shape to call an
  ## application.
  if placesApplication(pp): hcApplications else: hcPackages

proc packageClassificationKey*(name, version: string): string =
  ## The key a package reference is classified under (`concerns.packages` of
  ## `repro home export`, and the evaluation's `name` / `version`): the name,
  ## or `name@version` for a reference that pins a version, since a pinned
  ## version may select a different realization.
  if version.len == 0: name else: name & "@" & version

type
  PackageClassification* = object
    ## Reprobuild's package classification for ONE target platform, as
    ## `repro home export` publishes it (`concerns.packages.<system>`;
    ## Gradual-Nix-To-Reprobuild-Migration.md §Concern-scoped apply, "The
    ## per-package split comes from Reprobuild"). Keys are
    ## `packageClassificationKey`s. A reference in neither set selects a
    ## realization that places no application.
    applications*: HashSet[string]
      ## References whose selection places an application (`applications`).
    unresolved*: HashSet[string]
      ## References that resolve to nothing for the target (`packages`, as
      ## a reference with no realization always is).
    unknownDefinitions*: HashSet[string]
      ## The subset of `unresolved` no package definition this repro can
      ## see names at all: a catalog it could not reach might define them,
      ## possibly as applications.

proc concernOf*(classification: PackageClassification; key: string):
    HomeConcern =
  if key in classification.applications: hcApplications else: hcPackages

proc profilePackageReferences*(profile: Profile): seq[PlannedPackage] =
  ## Every package reference of every activity of `profile`, whichever host
  ## enables the activity and whichever platform its guard selects -- once
  ## per `packageClassificationKey`, with the first occurrence's binaries.
  ## The classification an export publishes covers all of them, so a
  ## consumer evaluating any host for any platform finds its packages there.
  var seen = initHashSet[string]()
  proc add(outp: var seq[PlannedPackage]; node: IntentNode;
           activity: string) =
    let key = packageClassificationKey(node.packageName, node.packageVersion)
    if key notin seen:
      seen.incl key
      outp.add PlannedPackage(packageId: node.packageName,
        fromActivity: activity, requestedVersion: node.packageVersion,
        binaries: node.packageBinaries)
  proc walk(outp: var seq[PlannedPackage]; body: seq[IntentNode];
            activity: string) =
    # Guards nest (the planner conjoins them, `plan.packageOriginsFromBody`),
    # so a reference at any depth is one some host and platform may plan.
    for node in body:
      case node.kind
      of nkPackageRef:
        outp.add(node, activity)
      of nkCondBlock:
        outp.walk(node.condChildren, activity)
      else:
        discard
  for child in profile.root.children:
    if child.kind != nkActivity:
      continue
    result.walk(child.activityChildren, child.activityName)

proc classifyPackages*(references: seq[PlannedPackage];
                       adapterPreference: OrderedTable[string, seq[string]];
                       platform, arch: string;
                       catalog: ProfileCatalog): PackageClassification =
  ## THE package classification `repro home export` publishes for one
  ## target: each reference resolved as the planner resolves it for a target
  ## that is not the host, without its local lock -- the profile's policy
  ## and catalog only. A shared document cannot depend on the host-local
  ## `home.lock`, `PATH` or Scoop inventory. The selection is classified by
  ## `packageConcern`. `repro home apply` on a host that splits `packages`
  ## from `applications` computes it too and refuses when its own selection
  ## disagrees (`refuseClassificationDisagreement`).
  let ctx = profileResolutionContext(adapterPreference, platform, arch,
    false, catalog = catalog)
  let previews = previewPackageResolutions(references, ctx)
  for i, pp in previews:
    let key = packageClassificationKey(references[i].packageId,
      references[i].requestedVersion)
    if packageConcern(pp) == hcApplications:
      result.applications.incl key
    elif pp.kind == ppkMissing:
      result.unresolved.incl key
      if pp.unknownDefinition:
        result.unknownDefinitions.incl key

proc refuseClassificationDisagreement(opts: ApplyOptions; plan: ApplyPlan;
                                      previews: seq[PackagePreview];
                                      applied: AppliedConcerns;
                                      catalog: ProfileCatalog) =
  ## On a host whose declaration gives `packages` and `applications` to
  ## different sides, the Nix side reads which package is an application
  ## from the export (`classifyPackages`, made without the host-local lock
  ## or inventory). Actual previews still honor the local lock, so a pin
  ## that changes a package's concern must be checked as well.
  ## A package this host's selection puts in the other concern would then be
  ## applied by neither side (or by both): refuse, naming it and the remedy.
  ## A host that keeps both concerns on one side never consults it.
  if not applied.declared or
      (hcPackages in applied.concerns) == (hcApplications in applied.concerns):
    return
  let exported = classifyPackages(plan.packages, plan.adapterPreference,
    opts.targetContext.platform, opts.targetContext.arch, catalog)
  var problems: seq[string]
  for i, pp in previews:
    let key = packageClassificationKey(plan.packages[i].packageId,
      plan.packages[i].requestedVersion)
    let here = packageConcern(pp)
    let there = exported.concernOf(key)
    if here != there:
      problems.add pp.packageId & " is `" & $here & "` by this host's " &
        "selection (" & pp.detail & ") but `" & $there & "` by the " &
        "selection `repro home export` publishes, which cannot consult this " &
        "host's home.lock, PATH or Scoop inventory"
  if problems.len > 0:
    raisePlanFailed("hosts." & opts.host & ".applies gives `packages` and " &
      "`applications` to different tools, and the Nix side reads which " &
      "package is an application from `repro home export`; " &
      problems.join("; ") & ". Order `adapterPreference` so that a " &
      "host-inventory kind (path, scoop) does not precede the application's " &
      "realization; inspect the current catalog and use `--relock` to " &
      "replace a differing local pin, or give both concerns to the same side")

proc concernSeed(applied: AppliedConcerns): string =
  ## The generation-id contribution of a concern declaration: the applied
  ## set, so narrowing or widening it is a new generation. Empty without a
  ## declaration, so the ids of undeclared profiles are unchanged.
  if applied.declared:
    "\x00concerns:" & concernNames(applied.concerns).join(",")
  else:
    ""

proc readGenerationManifest(stateDir: string; store: var Store;
                            generationIdHex: string): Option[ActivationManifest] =
  ## The activation manifest of a generation, or none when there is no such
  ## generation or its manifest cannot be read.
  if generationIdHex.len == 0:
    return none(ActivationManifest)
  let pointerFile = pointerPath(stateDir, generationIdHex)
  if not fileExists(extendedPath(pointerFile)):
    return none(ActivationManifest)
  try:
    let envelope = readPointerFile(pointerFile)
    var key: PrefixIdBytes
    for i in 0 ..< 32:
      key[i] = envelope.activationManifestDigest[i]
    some(decodeManifestBytes(readCasBlob(store, key)))
  except CatchableError:
    none(ActivationManifest)

type
  ReleasedRecord* = object
    ## A record of the previous generation in a concern the new apply does
    ## not own: released, not removed.
    category*: string    ## "generated-file" | "managed-block" | "resource"
    name*: string        ## path, `<file>#<block>`, or resource address
    concern*: HomeConcern

proc releasedRecordsOf*(manifest: ActivationManifest;
                        owned: ConcernSet): seq[ReleasedRecord] =
  ## What `manifest` recorded in concerns outside `owned`, classified by
  ## the one classification (`repro_home_resources/concerns`). Launchers are
  ## not listed: they live in the generation's own bin directory, not in the
  ## home, and follow the generation.
  if GeneratedFileConcern notin owned:
    for gf in manifest.generatedFiles:
      result.add ReleasedRecord(category: "generated-file",
        name: gf.absoluteOutputPath, concern: GeneratedFileConcern)
  if ManagedBlockRecordConcern notin owned:
    for mb in manifest.managedBlocks:
      result.add ReleasedRecord(category: "managed-block",
        name: mb.hostFilePath & "#" & mb.blockId,
        concern: ManagedBlockRecordConcern)
  let apps = applicationPackagesOf(manifest)
  for rb in manifest.resourceBindings:
    if rb.resourceKind.len == 0 or isZeroDigest(rb.postWriteDigest):
      # A V1 stub, or a record of a destroyed resource: nothing is placed.
      continue
    let concern = concernOfBinding(rb, apps)
    if concern notin owned:
      result.add ReleasedRecord(category: "resource",
        name: rb.resourceAddress, concern: concern)

proc selectionSeedOf(previews: seq[PackagePreview]): string =
  ## Canonical bytes of what every reference selected, for the generation
  ## id (``deriveGenerationId``). Test-seam bindings contribute their
  ## detail text; an unresolved reference its failure.
  for pv in previews:
    result.add(pv.packageId & "\x1f")
    if pv.resolved:
      let selection = pv.resolution.selection
      result.add($selection.kind & "\x1f" & selection.lockIdentity)
    else:
      result.add($pv.kind & "\x1f" & pv.detail)
    result.add("\n")

proc lockRecordOf(ctx: ProfileResolutionContext;
                  previews: seq[PackagePreview]): HomeLockTarget =
  result = HomeLockTarget(target: describeTarget(ctx.target),
    policy: ctx.policy, policySource: ctx.policySource)
  for pv in previews:
    if not pv.resolved:
      continue
    let selection = pv.resolution.selection
    result.packages.add(HomeLockSelection(package: pv.packageId,
      kind: selection.kind, contributor: selection.contributor,
      version: selection.version, lockIdentity: selection.lockIdentity,
      ambient: selection.ambient))

proc recordSelectionsInLock(opts: ApplyOptions;
                            ctx: ProfileResolutionContext;
                            previews: seq[PackagePreview]) =
  ## Serialise this apply's selections into ``home.lock`` beside the
  ## profile (Provisioning-Contributions.md §"The home-profile lock"): the
  ## record of this target is replaced, every other target's record is
  ## carried forward. Written only when it changes, so an unchanged apply
  ## does not touch the profile directory.
  let path = homeProfileLockPath(opts.profileDir)
  let existing = readHomeProfileLock(path)
  let base =
    if existing.isSome: existing.get
    else: HomeProfileLock(schema: HomeProfileLockSchemaV1)
  let updated = base.withTarget(lockRecordOf(ctx, previews))
  if existing.isSome and serializeHomeProfileLock(existing.get) ==
      serializeHomeProfileLock(updated):
    return
  writeHomeProfileLock(path, updated)

type
  ProfileSelections* = object
    ## Every package reference of a profile, resolved for one target —
    ## what ``--plan`` prints and what an apply realizes and locks.
    target*: string
      ## ``describeTarget`` spelling, e.g. ``aarch64-macos``.
    policy*: SelectionPolicy
    policySource*: string
    previews*: seq[PackagePreview]

proc resolveProfileSelections*(rawOpts: ApplyOptions): ProfileSelections =
  ## Resolve every package reference of the profile ``rawOpts`` names, for
  ## its target, exactly as ``--plan`` and apply do — load intent, build the
  ## plan, build the resolution context (lock included), select. Mutates
  ## nothing. The library entry point for callers that need the selections
  ## themselves (kind, contributor, lock identity) rather than plan text.
  let opts = resolveOptions(rawOpts)
  if not fileExists(extendedPath(opts.profilePath)):
    raiseIntentLoad(opts.profilePath,
      "no home.nim at expected path (profile-dir: " & opts.profileDir & ")")
  let profile = resolveProfileFromOpts(opts)
  let applyPlan = buildPlan(profile, opts.profileDir, opts.targetContext)
  let ctx = packageResolutionContext(opts, applyPlan,
    packageResolutionCatalog(opts, applyPlan))
  result.target = describeTarget(ctx.target)
  result.policy = ctx.policy
  result.policySource = ctx.policySource
  result.previews = previewPackageResolutions(applyPlan.packages, ctx)

type
  PlannedDesiredState* = object
    ## The desired state of a home, as the planning half of the apply
    ## computes it: what `repro home apply --plan` previews and what the
    ## host-facts producer (`host_facts.collectHostFacts`) reports. One
    ## constructor, `planDesiredState`, so the two can never plan
    ## differently.
    options*: ApplyOptions          ## the resolved options
    profile*: Profile
    plan*: ApplyPlan                ## packages, and every planned file
                                    ## (synthetic + stow, after stow
                                    ## shadowing) in `plan.generatedFiles`
    stowDiscovery*: StowDiscovery
    desiredResources*: DesiredSet   ## the composed `resources:` set,
                                    ## topologically ordered
    applied*: AppliedConcerns       ## the concerns an apply executes on
                                    ## the host; the planned state above
                                    ## always covers EVERY concern (host
                                    ## facts describe them all)

proc planDesiredState*(rawOpts: ApplyOptions): PlannedDesiredState =
  ## Steps 2 and 4 of the apply (load intent, build the plan, stow
  ## discovery and shadowing) plus the composed desired resource set, for
  ## the host and target platform in `rawOpts`. Performs only reads: no
  ## store write, no generation, nothing under `homeDir` (stow discovery
  ## reads the profile's `stow/` tree; target paths are computed, not
  ## touched). Raises what the apply raises for an intent that cannot be
  ## planned (`EApplyIntentLoad`, `EHomePlanCyclicDependency`, ...).
  let opts = resolveOptions(rawOpts)
  result.options = opts
  if not fileExists(extendedPath(opts.profilePath)):
    raiseIntentLoad(opts.profilePath,
      "no home.nim at expected path (profile-dir: " & opts.profileDir & ")")
  result.profile = resolveProfileFromOpts(opts)
  result.plan = buildPlan(result.profile, opts.profileDir, opts.targetContext)
  var packageIds: seq[string]
  for p in result.plan.packages:
    packageIds.add(p.packageId)
  let synthetic = parseSyntheticPackageGenerates(opts.homeDir, packageIds,
    result.plan.configContributions)
  for s in synthetic:
    result.plan.generatedFiles.add(s)
  # GM11: only the stow packages this host gets (activity-scoped claims).
  result.stowDiscovery = selectStowEntries(
    discoverStowEntries(opts.profileDir, opts.homeDir), result.profile,
    opts.targetContext)
  # Two packages on one path: refused before anything is written.
  refuseStowPackagesOnOnePath(result.stowDiscovery.entries)
  if result.stowDiscovery.entries.len > 0:
    for sp in stowEntriesToPlanned(result.stowDiscovery.entries):
      result.plan.generatedFiles.add(sp)
  let suppressed = suppressStowShadowed(result.plan.generatedFiles,
    result.plan.configContributions)
  result.plan.generatedFiles = suppressed.files
  result.desiredResources = composeDesiredResources(result.profile,
    opts.homeDir, opts.targetContext)
  # A stow file and an `fs.userFile` on one path: one writer when they
  # agree, refused when they do not (`resolveStowResourceOverlap`).
  let overlap = resolveStowResourceOverlap(result.plan.generatedFiles,
    result.stowDiscovery.entries, result.desiredResources, opts.profileDir,
    opts.homeDir, opts.targetContext.platform)
  result.plan.generatedFiles = overlap.files
  result.stowDiscovery.entries = overlap.stowEntries
  result.applied = appliedConcernsFor(result.profile, opts.host)

proc runApplyPlan*(rawOpts: ApplyOptions): PlanPreview =
  ## M72 Deliverable 2: `repro home apply --plan`. A NON-MUTATING
  ## preview of the FULL apply. Runs the planning half of the pipeline
  ## — load intent (step 2), finalize (step 3), build plan (step 4),
  ## generation-id derivation + no-op detection (step 6), production
  ## package-catalog resolution, stow discovery, and the
  ## generated-file / managed-block / launcher / resource planning —
  ## but does NOT execute steps 7-11 (no realize, no stage, no
  ## materialize, no rotate, no commit).
  ##
  ## Mutates NOTHING: no store writes, no generation written, no
  ## `current` rotation, no file/registry writes, no `scoop install`.
  ## Package resolution (PATH probes, `scoop list`, bucket-manifest reads)
  ## is a READ and is allowed; `scoop install` is not — the planner calls
  ## `previewPackageResolutions` (a pure query), never a realizer, and
  ## reads the home-profile lock without writing it.
  ##
  ## The apply lock is intentionally NOT acquired: a read-only plan
  ## must never block a concurrent real apply.
  let opts = resolveOptions(rawOpts)
  ensureStateDir(opts.stateDir)

  # ---- Steps 2 and 4: load intent, build plan + synthetic seams + stow
  # discovery (`planDesiredState`, shared with the host-facts producer) --
  let state = planDesiredState(opts)
  let profile = state.profile
  var applyPlan = state.plan
  let stowDiscovery = state.stowDiscovery
  let stowEntries = stowDiscovery.entries
  var packageIds: seq[string]
  for p in applyPlan.packages:
    packageIds.add(p.packageId)

  # ---- Step 6: derive generation id + no-op detection -------------------
  let intentSnapshot = profileIntentSnapshot(opts.profileDir, profile)
  let snapshotBytes = encodeSnapshot(intentSnapshot)
  let snapshotDig = digestOf(snapshotBytes)
  # M78: the generation-id resource seed is the composed desired set
  # (profile `resources:` block + `REPRO_TEST_RESOURCES` override),
  # so a change to a profile-declared resource produces a distinct id.
  let applied = state.applied
  result.host = opts.host
  result.applied = applied
  let owned = applied.concerns
  # GM7: the applied concern set is part of the generation id (empty seed
  # without a declaration).
  let resourcesSeed = resourceSeedString(state.desiredResources) &
    concernSeed(applied)
  # GM4b: resolve every package reference first — the selections are part
  # of the generation id. Resolution is static metadata plus host-inventory
  # READS (PATH, `scoop list`, bucket manifests); nothing is realized and the
  # home-profile lock is read, never written.
  let catalog = packageResolutionCatalog(opts, applyPlan)
  let resolutionCtx = packageResolutionContext(opts, applyPlan, catalog)
  let packagePreviews = previewPackageResolutions(applyPlan.packages,
    resolutionCtx)
  addApplicationCommands(applyPlan, packagePreviews)
  # GM7: on a host that splits `packages` from `applications`, the Nix side
  # reads the export's classification; refuse a package this host would put
  # in the other concern.
  refuseClassificationDisagreement(opts, applyPlan, packagePreviews, applied,
    catalog)
  let candidateId = deriveGenerationId(applyPlan, snapshotDig, resourcesSeed,
    selectionSeedOf(packagePreviews))
  result.generationIdHex = generationIdHex(candidateId)
  let activeGenIdHex = readCurrentGenerationId(opts.stateDir)

  # ---- Package preview (READ ONLY) --------------------------------------
  # The selections computed above, one plan line each. The same context
  # resolves the real apply's packages, so the plan and the apply cannot
  # select differently.
  # GM7: a reference of a concern the host does not apply is shown, never
  # realized, and never a failure -- a missing realization included.
  var packageConcernOf = initTable[string, HomeConcern]()
  for pp in packagePreviews:
    let concern = packageConcern(pp)
    packageConcernOf[pp.packageId] = concern
    var item = PlanItem(category: "package", name: pp.packageId,
      detail: pp.detail, concern: concern, notApplied: concern notin owned)
    case pp.kind
    of ppkRealize: item.action = piaRealize
    of ppkCacheHit: item.action = piaCacheHit
    of ppkMissing:
      item.action = piaMissing
      if not item.notApplied:
        inc result.driftCount
    result.items.add(item)

  # ---- Application bundles (READ ONLY) ----------------------------------
  # GM4c: a resolved application is placed in ~/Applications by the apply.
  # The plan names the target and reports a path the active generation does
  # not own, which the apply refuses to replace (Store-And-Installation-
  # Layout.md § macOS Application Bundles, "Ownership"). Only for this host:
  # another host's Applications directory is not readable from here.
  # The resource preview below leaves these addresses to this section: they
  # are synthesized from realized packages, which a plan does not realize.
  var plannedAppAddresses: HashSet[string]
  # A macOS installer application places the product its installer
  # produced -- a bundle, or the folder holding it -- exactly as an
  # `app-bundle` record places its bundle (§ Installer applications).
  for pp in packagePreviews:
    if placesApplication(pp):
      plannedAppAddresses.incl(appBundleAddress(pp.packageId))
  if not opts.recordOnlyGeneratedFiles and targetIsThisHost(opts):
    var ownedApps: HashSet[string]
    var ownedRead = false
    for pp in packagePreviews:
      if appBundleAddress(pp.packageId) notin plannedAppAddresses:
        continue
      if not ownedRead:
        ownedRead = true
        try:
          var store = openStore(opts.storeRoot)
          defer:
            try: store.close() except CatchableError: discard
          ownedApps = ownedAppBundleAddresses(opts.stateDir, store,
            activeGenIdHex)
        except CatchableError:
          discard
      let address = appBundleAddress(pp.packageId)
      let target = applicationsDir(apsHome, opts.homeDir) /
        appPlacedItem(pp.resolution.archive).item
      var item = PlanItem(category: "app-bundle", name: target,
        concern: hcApplications, notApplied: hcApplications notin owned)
      let present = symlinkExists(target) or fileExists(target) or
        dirExists(target)
      if present and address notin ownedApps and
          address notin opts.adoptAddresses:
        item.action = piaConflictDrift
        item.detail = "occupied by a bundle Reprobuild did not place; " &
          "the apply refuses to replace it (remove it, or claim it with " &
          "`repro home adopt " & address & "`)"
        if not item.notApplied:
          inc result.driftCount
      elif present:
        item.action = piaUpdate
        let placedVersion = describeIdentityVersion(
          observeAppBundleAt(target).rawBytes)
        item.detail = "placed by the active generation (" & address &
          (if placedVersion.len > 0: ", " & placedVersion & " there now"
           else: "") &
          "); re-placed when the realized bundle differs and is newer " &
          "than a vendor update of it"
        let pids = processesRunningFrom(target)
        if pids.len > 0:
          var ids: seq[string]
          for pid in pids:
            ids.add $pid
          item.detail.add("; running (pid " & ids.join(", ") &
            "): a replacement is deferred until it quits")
      else:
        item.action = piaCreate
        item.detail = "would place " & pp.packageId & "'s verified bundle (" &
          address & ")"
      result.items.add(item)

  # ---- The current generation's file records -----------------------------
  # Read once, for the stow preview (a link the current generation recorded
  # is its own, `stow.isRecordedStowTarget`) and the generated-file preview
  # (cache-hit digests).
  var prevFileDigests = initTable[string, Digest256]()
  var recordedStow = initTable[string, GeneratedFile]()
  if activeGenIdHex.len > 0:
    let prevPointerFile = pointerPath(opts.stateDir, activeGenIdHex)
    if fileExists(extendedPath(prevPointerFile)):
      try:
        let prevEnv = readPointerFile(prevPointerFile)
        var prevKey: PrefixIdBytes
        for i in 0 ..< 32:
          prevKey[i] = prevEnv.activationManifestDigest[i]
        var store = openStore(opts.storeRoot)
        defer:
          try: store.close() except CatchableError: discard
        let prevBytes = readCasBlob(store, prevKey)
        let prevManifest = decodeManifestBytes(prevBytes)
        for gf in prevManifest.generatedFiles:
          prevFileDigests[gf.absoluteOutputPath] = gf.postWriteDigest
          if gf.ownershipPolicy in {gfoStowSymlink, gfoStowCopy}:
            recordedStow[gf.absoluteOutputPath] = gf
      except CatchableError:
        discard

  # ---- Stow preview -----------------------------------------------------
  let filesApplied = GeneratedFileConcern in owned
  for entry in stowEntries:
    var item = previewStowItem(opts.profileDir, opts.homeDir, entry,
      recordedStow)
    item.concern = GeneratedFileConcern
    item.notApplied = not filesApplied
    if item.action == piaConflictDrift and filesApplied:
      inc result.driftCount
    result.items.add(item)
  # M73: a file directly under `stow/` is not valid GNU `stow` layout
  # — report it as a skipped stow item; it is not materialized.
  for loose in stowDiscovery.looseFiles:
    result.items.add(PlanItem(category: "stow",
      name: StowSubdirName & "/" & loose,
      concern: GeneratedFileConcern, notApplied: not filesApplied,
      action: piaSkip,
      detail: "loose file directly under stow/ — not a GNU stow " &
        "package; skipped (IStowLooseFile)"))

  # ---- Generated files / managed blocks / launchers preview -------------
  for g in applyPlan.generatedFiles:
    if g.sourceKind != pgfsPackageOutput:
      continue
    var item = PlanItem(category: "generated-file",
      name: g.absoluteOutputPath, concern: GeneratedFileConcern,
      notApplied: not filesApplied)
    let candidateDigest = digestOf(g.contentBytes)
    if g.absoluteOutputPath in prevFileDigests and
       prevFileDigests[g.absoluteOutputPath] == candidateDigest and
       fileExists(extendedPath(g.absoluteOutputPath)):
      item.action = piaCacheHit
      item.detail = "content unchanged from the active generation"
    else:
      item.action = piaWrite
      item.detail = "would write " & $g.contentBytes.len & " bytes"
    result.items.add(item)
  let syntheticBlocks = parseSyntheticPackageManagedBlocks(opts.homeDir,
    packageIds)
  for mb in syntheticBlocks:
    result.items.add(PlanItem(category: "managed-block",
      name: mb.hostFilePath & "#" & mb.blockId,
      concern: ManagedBlockRecordConcern,
      notApplied: ManagedBlockRecordConcern notin owned,
      action: piaWrite,
      detail: "would materialize managed block"))
  for l in applyPlan.launchers:
    let concern = packageConcernOf.getOrDefault(l.fromPackageId, hcPackages)
    result.items.add(PlanItem(category: "launcher",
      name: l.commandName,
      concern: concern, notApplied: concern notin owned,
      action: piaWrite,
      detail: "launcher for package " & l.fromPackageId))

  # ---- Resource preview (reuses the M68 read-only planner) --------------
  # M78: the desired set is the profile's `resources:` block, with
  # `REPRO_TEST_RESOURCES` merged over it as a test-only override.
  let desiredResources = state.desiredResources
  # M69 Phase C follow-up: defence-in-depth layer 1 — the SAME
  # pre-dispatch gate as `runApply`. The `--plan` path composes the
  # plan via `composePlan` -> `observeResource` -> the observe procs
  # (`observeGsettings` / `observeUserDefault` / `observeLaunchAgent`
  # / `observeUserUnit`), which shell out. A preview must therefore
  # refuse an unsafe operator-controlled field exactly as apply does,
  # fail-closed, before any observe driver runs.
  for addr1, res in desiredResources.resources:
    let validationErr = resourceValidationError(res)
    if validationErr.len > 0:
      raiseResourceDriver(addr1, $res.kind,
        "pre-dispatch validation", validationErr)
  # GM7: the previous generation's records of a concern this host no longer
  # applies are released (left in place, not recorded again), never
  # destroyed; the rest feed the lifecycle as before.
  var prevManifest = none(ActivationManifest)
  if activeGenIdHex.len > 0:
    try:
      var store = openStore(opts.storeRoot)
      defer:
        try: store.close() except CatchableError: discard
      prevManifest = readGenerationManifest(opts.stateDir, store,
        activeGenIdHex)
    except CatchableError:
      discard
  var recordedBindings = initOrderedTable[string, RecordedBinding]()
  var recordedConcern = initTable[string, HomeConcern]()
  if prevManifest.isSome:
    let apps = applicationPackagesOf(prevManifest.get)
    for rb in prevManifest.get.resourceBindings:
      if rb.resourceKind.len == 0: continue
      let concern = concernOfBinding(rb, apps)
      if concern notin owned:
        continue
      # GM4c: a placed application that is still planned is previewed in
      # the app-bundle section; without its realized identity the
      # resource planner would read it as destroyed.
      if rb.resourceKind == $rkMacosAppBundle and
          rb.resourceAddress in plannedAppAddresses:
        continue
      recordedBindings[rb.resourceAddress] = toRecorded(rb)
      recordedConcern[rb.resourceAddress] = concern
    for r in releasedRecordsOf(prevManifest.get, owned):
      result.items.add(PlanItem(category: r.category, name: r.name,
        action: piaRelease, concern: r.concern,
        detail: "recorded by the active generation in concern `" &
          $r.concern & "`, which " & opts.host & " no longer applies: " &
          "left in place and no longer managed"))
      inc result.releasedCount
  var ownedDesired = initDesiredSet()
  var otherDesired = initDesiredSet()
  for address, res in desiredResources.resources:
    if concernOfResourceKind(res.kind) in owned:
      ownedDesired.resources[address] = res
    else:
      otherDesired.resources[address] = res
  let reconcilePolicy =
    if opts.reconcileStowDrift or getEnv(ReconcileDriftEnvVar) == "1" or
       getEnv(AcceptOverwriteEnvVar) == "1":
      rpReconcileDrift
    else:
      rpFailClosed
  proc addResourceItems(preview: var PlanPreview; plan: PlanReport;
                        desired: DesiredSet; notApplied: bool) =
    for a in plan.actions:
      let concern =
        if a.address in desired.resources:
          concernOfResourceKind(desired.resources[a.address].kind)
        else:
          recordedConcern.getOrDefault(a.address, hcPackages)
      var item = PlanItem(category: "resource", name: a.address,
        concern: concern, notApplied: notApplied)
      case a.kind
      of rakCreate: item.action = piaCreate
      of rakUpdate: item.action = piaUpdate
      of rakReplace: item.action = piaUpdate
      of rakDestroy: item.action = piaDestroy
      of rakNoOp: item.action = piaNoOp
      of rakAdopt: item.action = piaNoOp
      of rakDriftBlocked:
        item.action = piaConflictDrift
        if not notApplied:
          inc preview.driftCount
      item.detail = a.summary
      preview.items.add(item)
  result.addResourceItems(composePlan(ownedDesired, recordedBindings,
    DecisionOptions(reconcile: reconcilePolicy, enforcePreventDestroy: true)),
    ownedDesired, notApplied = false)
  if otherDesired.resources.len > 0:
    # What the resources of the other concerns would do if this host applied
    # them: against the live state, with no recorded binding (they are not
    # this generation's). Observation only; nothing is executed.
    result.addResourceItems(composePlan(otherDesired,
      initOrderedTable[string, RecordedBinding](),
      DecisionOptions(reconcile: reconcilePolicy,
        enforcePreventDestroy: true)), otherDesired, notApplied = true)
  for item in result.items:
    if item.notApplied:
      inc result.notAppliedCount

  # ---- No-op classification ---------------------------------------------
  result.isNoOp = activeGenIdHex.len > 0 and
    result.generationIdHex == activeGenIdHex and result.driftCount == 0

proc renderPlanPreview*(preview: PlanPreview): string =
  ## Stable, line-oriented rendering of a `--plan` preview. The gate
  ## asserts on the category headers and the per-item action verbs.
  ##
  ## GM7: items of a concern the host does not apply are listed apart, after
  ## the applied ones, under `not applied on <host>`; records released by a
  ## narrowed concern set under `released`. Neither section exists for a
  ## host that applies every concern and released nothing, so the rendering
  ## of an undeclared profile is unchanged.
  result = "repro home apply --plan: " & $preview.items.len &
    " operation(s) previewed, " & $preview.driftCount & " drift(s)\n"
  result.add("  target generation: " & preview.generationIdHex & "\n")
  if preview.applied.declared:
    result.add("  concerns applied: " &
      describeAppliedConcerns(preview.applied, preview.host) & "\n")
    if preview.notAppliedCount > 0:
      result.add("  not applied: " & $preview.notAppliedCount &
        " operation(s) of concerns " & preview.host & " leaves to " &
        "another tool\n")
  if preview.isNoOp:
    result.add("  plan status: no-op (matches the active generation)\n")
  let categories = @["package", "app-bundle", "stow", "generated-file",
    "managed-block", "launcher", "resource"]
  proc renderItem(outp: var string; item: PlanItem; prefix = "") =
    outp.add("    " & prefix & $item.action & "  " & item.name)
    if item.detail.len > 0:
      outp.add("  (" & item.detail & ")")
    outp.add("\n")
  for cat in categories:
    var any = false
    for item in preview.items:
      if item.category == cat and not item.notApplied and
          item.action != piaRelease:
        if not any:
          result.add("  [" & cat & "]\n")
          any = true
        result.renderItem(item)
  for concern in HomeConcern:
    var any = false
    for cat in categories:
      for item in preview.items:
        if item.notApplied and item.concern == concern and
            item.category == cat:
          if not any:
            result.add("  [not applied on " & preview.host & ": concern " &
              $concern & " is not in hosts." & preview.host &
              ".applies]\n")
            any = true
          result.renderItem(item, "[" & cat & "] ")
  var anyReleased = false
  for item in preview.items:
    if item.action == piaRelease:
      if not anyReleased:
        result.add("  [released: recorded in concerns " & preview.host &
          " no longer applies; left in place]\n")
        anyReleased = true
      result.renderItem(item, "[" & item.category & "] ")

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

proc refuseUnmanagedAppBundles(activations: seq[Resource];
                               owned: HashSet[string];
                               adoptAddresses: seq[string]) =
  ## GM4c: raise `EAppBundleCollision` for the first activation whose target
  ## path is occupied by a bundle the active generation does not own
  ## (Store-And-Installation-Layout.md § macOS Application Bundles,
  ## "Ownership"). An address being adopted is claimed, not replaced.
  for res in activations:
    if res.address in owned or res.address in adoptAddresses:
      continue
    let target = realWorldIdentity(res)
    if symlinkExists(target) or fileExists(target) or dirExists(target):
      var e = newException(EAppBundleCollision, "repro home apply: " &
        target.escape & " already exists and was not placed by " &
        "Reprobuild; refusing to replace it (resource " & res.address &
        "). Remove or rename it, or claim it with `repro home adopt " &
        res.address & "`.")
      e.targetPath = target
      raise e

proc runApply*(rawOpts: ApplyOptions): ApplyOutcome =
  ## Execute the apply pipeline. Synchronous; takes the `apply.lock`
  ## for the duration. Returns an `ApplyOutcome` summarizing what
  ## happened so the CLI layer can render a single status line.
  let opts = resolveOptions(rawOpts)

  # ---- Pre-step: partial-apply recovery ----------------------------------
  ensureStateDir(opts.stateDir)
  let recovered = recoverPartialApply(opts.stateDir)
  result.abortedRecovered = recovered

  # ---- Step 1: acquire apply lock ---------------------------------------
  var lock = acquireApplyLock(opts.stateDir, timeoutSeconds = 30)
  try:
    if shouldKillAfter(1):
      writeMarker(opts.stateDir, "", "killed-after-step-1")
      raiseKilledByTestHook(1)

    # ---- Step 2: load intent layer --------------------------------------
    if not fileExists(extendedPath(opts.profilePath)):
      raiseIntentLoad(opts.profilePath,
        "no home.nim at expected path (profile-dir: " & opts.profileDir &
        ")")
    let profile = resolveProfileFromOpts(opts)
    # GM7: the concerns this apply executes on the host
    # (Gradual-Nix-To-Reprobuild-Migration.md §Concern-scoped apply). The
    # whole profile is still planned -- the generation id covers it -- but
    # only operations of these concerns run; the rest are counted, and what
    # the previous generation recorded in the others is released.
    let applied = appliedConcernsFor(profile, opts.host)
    let owned = applied.concerns
    let filesApplied = GeneratedFileConcern in owned
    let blocksApplied = ManagedBlockRecordConcern in owned
    result.applied = applied
    if shouldKillAfter(2):
      writeMarker(opts.stateDir, "", "killed-after-step-2")
      raiseKilledByTestHook(2)

    # ---- Step 3: finalize configurables ---------------------------------
    # M65 wires this seam. The applyMode the caller declared tells us
    # whether to take the incremental-refinalize fast path (`amSet` —
    # caller knows exactly one `<pkg>.<key>` changed and seeds the
    # M58 `withOverrides` dirty closure with that key) or the full
    # refinalize path (`amFull` — every configurable is re-resolved
    # from scratch). At this milestone, the resolution itself is
    # carried out by the planner reading the harvested `config:`
    # contributions from the parsed intent (`applyPlan.configContributions`)
    # and substituting them into the configurable-driven
    # `PlannedGeneratedFile.contentBytes` via the placeholder
    # resolver. The fast-path advantage lands in step 8: by the time
    # we get there, each new generated file's content digest is
    # compared against the previous generation's recorded
    # `postWriteDigest` for the same path. Files whose digest is
    # unchanged cache-hit and are NOT re-staged.
    if opts.applyMode == amSet:
      let key = if opts.setOverrideKey.len > 0: opts.setOverrideKey else: "?"
      stdout.writeLine("apply: step 3 refinalize incremental key=" & key)
    if shouldKillAfter(3):
      writeMarker(opts.stateDir, "", "killed-after-step-3")
      raiseKilledByTestHook(3)

    # ---- Step 4: derive ApplyPlan (package walk + stow discovery) -------
    var applyPlan = buildPlan(profile, opts.profileDir, opts.targetContext)
    # Phase B: pull in any synthetic package-output entries the test
    # hook declared. In production this seam will be fed by the M59
    # stdlib renderer.
    var packageIds: seq[string]
    for p in applyPlan.packages:
      packageIds.add(p.packageId)
    let synthetic = parseSyntheticPackageGenerates(opts.homeDir, packageIds,
      applyPlan.configContributions)
    for s in synthetic:
      applyPlan.generatedFiles.add(s)
    # GM11: only the stow packages this host gets (activity-scoped claims).
    let stowDiscovery = selectStowEntries(
      discoverStowEntries(opts.profileDir, opts.homeDir), profile,
      opts.targetContext)
    # Two packages on one path: refused here, before the commit marker
    # (`planDesiredState` applies the same rule for `--plan` and facts).
    refuseStowPackagesOnOnePath(stowDiscovery.entries)
    var stowEntries = stowDiscovery.entries
    if stowEntries.len > 0:
      let stowPlanned = stowEntriesToPlanned(stowEntries)
      for sp in stowPlanned:
        applyPlan.generatedFiles.add(sp)
    # M73: a file located directly under `stow/` (not inside a GNU
    # `stow` package directory) is not valid GNU `stow` layout. Emit
    # an informational `IStowLooseFile` diagnostic per loose file and
    # do NOT materialize it — apply continues normally.
    for loose in stowDiscovery.looseFiles:
      applyPlan.diagnostics.add(StowDiagnostic(
        severity: dsInfo,
        code: sdIStowLooseFile,
        path: StowSubdirName & "/" & loose,
        message: "IStowLooseFile: '" & StowSubdirName & "/" & loose &
          "' sits directly under stow/ and is not inside a GNU stow " &
          "package directory; it was skipped and not materialized. " &
          "Move it into a package subdirectory (e.g. stow/<package>/" &
          loose & ") for it to be applied."))
    # Suppression deduplicates by `relativeHomePath`. The stow entry
    # wins where it overlaps a package output; diagnostics are emitted
    # for shadowed package outputs and dead config: contributions.
    let suppressed = suppressStowShadowed(applyPlan.generatedFiles,
      applyPlan.configContributions)
    applyPlan.generatedFiles = suppressed.files
    for d in suppressed.diagnostics:
      applyPlan.diagnostics.add(d)
    # A stow file and an `fs.userFile` resource naming one path: the
    # resource is the one writer when the two agree on mode and digest, and
    # the apply is refused here -- before the commit marker, so before
    # anything is written -- when they do not (Home-Profile-Intent-Layer.md
    # §Stow-Style Dotfile Support; `planDesiredState` applies the same rule
    # for `--plan` and `repro home facts`).
    let overlap = resolveStowResourceOverlap(applyPlan.generatedFiles,
      stowEntries, composeDesiredResources(profile, opts.homeDir,
        opts.targetContext), opts.profileDir, opts.homeDir,
      opts.targetContext.platform)
    applyPlan.generatedFiles = overlap.files
    stowEntries = overlap.stowEntries
    for d in overlap.diagnostics:
      applyPlan.diagnostics.add(d)
    if opts.recordOnlyGeneratedFiles:
      if stowEntries.len > 0:
        raisePlanFailed("remote bundle evaluation cannot replay stow " &
          "entries on the target yet")
      let remoteDesiredResources = composeDesiredResources(profile,
        opts.homeDir, opts.targetContext)
      if remoteDesiredResources.len > 0:
        raisePlanFailed("remote bundle evaluation cannot replay home " &
          "resources on the target yet")
      let syntheticBlocks = parseSyntheticPackageManagedBlocks(opts.homeDir,
        packageIds)
      if syntheticBlocks.len > 0:
        raisePlanFailed("remote bundle evaluation cannot replay managed " &
          "blocks on the target yet")
    result.diagnostics = applyPlan.diagnostics
    if shouldKillAfter(4):
      writeMarker(opts.stateDir, "", "killed-after-step-4")
      raiseKilledByTestHook(4)

    # ---- Step 5: load active generation's manifest (for diff) -----------
    let activeGenIdHex = readCurrentGenerationId(opts.stateDir)
    var store = openStore(opts.storeRoot)
    var storeClosed = false
    try:
      # ---- Step 6: no-op short-circuit ----------------------------------
      let intentSnapshot = profileIntentSnapshot(opts.profileDir, profile)
      let snapshotBytes = encodeSnapshot(intentSnapshot)
      let snapshotDig = digestOf(snapshotBytes)
      # M78: the generation-id resource seed is the composed desired
      # set (profile `resources:` block + `REPRO_TEST_RESOURCES`
      # override). A change to a profile-declared resource therefore
      # produces a distinct generation id (the no-op short-circuit is
      # not taken). M68 Phase B: an adopt run also contributes its
      # adopt-address set so the adopted binding lands in a new id.
      var resourcesSeed = resourceSeedString(
        composeDesiredResources(profile, opts.homeDir, opts.targetContext)) &
        concernSeed(applied)
      if opts.adoptAddresses.len > 0:
        resourcesSeed.add("\x00adopt:")
        for a in opts.adoptAddresses:
          resourcesSeed.add(a)
          resourcesSeed.add(",")
      # GM4b: resolve every package reference before the no-op check — the
      # selections are part of the generation id — with the same context
      # `--plan` uses. Step 7 realizes these packages in the same context.
      let catalog = packageResolutionCatalog(opts, applyPlan)
      let resolutionCtx = packageResolutionContext(opts, applyPlan, catalog)
      let packagePreviews = previewPackageResolutions(applyPlan.packages,
        resolutionCtx)
      # The commands application packages declare become launchers (and
      # part of the generation id); see `addApplicationCommands`.
      addApplicationCommands(applyPlan, packagePreviews)
      # GM7: see `refuseClassificationDisagreement` (`runApplyPlan`).
      refuseClassificationDisagreement(opts, applyPlan, packagePreviews,
        applied, catalog)
      let candidateId = deriveGenerationId(applyPlan, snapshotDig,
        resourcesSeed, selectionSeedOf(packagePreviews))
      # GM7: the package references this apply realizes -- those whose
      # concern (`packageConcern`, from the selection the plan made) the host
      # applies. A reference of another concern is never realized, so one
      # with no realization does not fail the apply.
      var ownedPackageIds = initHashSet[string]()
      for pp in packagePreviews:
        if packageConcern(pp) in owned:
          ownedPackageIds.incl pp.packageId
        else:
          inc result.notAppliedCount
      var ownedPackages: seq[PlannedPackage]
      for p in applyPlan.packages:
        if p.packageId in ownedPackageIds:
          ownedPackages.add p
      var ownedLaunchers: seq[PlannedLauncher]
      for l in applyPlan.launchers:
        if l.fromPackageId in ownedPackageIds:
          ownedLaunchers.add l
      let materializedStowEntries =
        if filesApplied: stowEntries
        else: newSeq[StowEntry]()
      if not filesApplied:
        result.notAppliedCount += stowEntries.len
        for g in applyPlan.generatedFiles:
          if g.sourceKind == pgfsPackageOutput:
            inc result.notAppliedCount
      let prevManifest = readGenerationManifest(opts.stateDir, store,
        activeGenIdHex)
      if prevManifest.isSome:
        for r in releasedRecordsOf(prevManifest.get, owned):
          result.released.add(r.category & " " & r.name)
      # No-op detection (spec §"No-Op Detection"): a re-apply is a
      # no-op iff the planner's content id matches the active
      # generation's recorded id AND all of the active generation's
      # post-write digests still verify against the live filesystem.
      # Both halves are required: an intent edit that removes a
      # package would otherwise verify as a "no-op" until the next
      # apply rewrites the bin dir, because the active generation's
      # files are still on disk.
      var verifyCount = 0
      # M68 Phase B: `repro home adopt` MUST run the resource step
      # (it observes + records the named binding) — so it never
      # takes the no-op short-circuit even when the intent / plan
      # is otherwise unchanged. An adopt with `adoptAddresses` set
      # always falls through to step 9b.
      if activeGenIdHex.len > 0 and opts.adoptAddresses.len == 0:
        # The pointer's `generationId` IS the content id (we set it
        # to `deriveGenerationId` which the writer copies in verbatim
        # — the writer leaves the id slot alone and only fills the
        # CAS-digest slots).
        let candidateIdHex = generationIdHex(candidateId)
        if candidateIdHex == activeGenIdHex and
           verifyManifestDigests(opts.stateDir, store, activeGenIdHex,
             opts.homeDir, verifyCount):
          result.kind = aokNoOpVerified
          result.generationIdHex = activeGenIdHex
          result.verifiedDigestCount = verifyCount
          stdout.writeLine(NoOpLogPrefix & $verifyCount & " recorded digests")
          # The selections equal the active generation's (they are in its
          # id); recording them creates a missing lock and is otherwise a
          # byte-identical no-op.
          if not opts.recordOnlyGeneratedFiles:
            recordSelectionsInLock(opts, resolutionCtx, packagePreviews)
          return

      if shouldKillAfter(6):
        writeMarker(opts.stateDir, generationIdHex(candidateId),
          "killed-after-step-6")
        raiseKilledByTestHook(6)

      # ---- Commit: write marker before any destructive step. ------------
      writeMarker(opts.stateDir, generationIdHex(candidateId), "in-progress")
      # Create the per-generation directory eagerly so partial-apply
      # recovery has a target to quarantine even when the kill happens
      # before the launcher / manifest writes that would otherwise
      # populate it. The directory ALONE does not advance `current` —
      # rotation in step 10 is the point of no return.
      let earlyGenDir = generationDir(opts.stateDir,
        generationIdHex(candidateId))
      createDir(extendedPath(earlyGenDir))

      # ---- Step 7: realize packages -------------------------------------
      # GM4b: the resolution context `--plan` uses, so the plan and the
      # apply cannot select differently.
      let realized = realizePlannedPackages(store, ownedPackages,
        resolutionCtx, opts.appTrust)
      if shouldKillAfter(7):
        raiseKilledByTestHook(7)
      # ---- Step 7b (GM4c): refuse an unmanaged application bundle ----
      # A bundle at an Applications-directory path that the previous
      # generation did not record (or recorded as destroyed) belongs to
      # someone else -- the user, another installer -- even when it is the
      # same application. Refused HERE, before step 8 writes any file, so
      # the apply changes nothing in the home directory.
      if not opts.recordOnlyGeneratedFiles:
        refuseUnmanagedAppBundles(
          planAppBundleActivations(realized, opts.homeDir),
          ownedAppBundleAddresses(opts.stateDir, store, activeGenIdHex),
          opts.adoptAddresses)

      # ---- Step 8: stage generated files + managed blocks ---------------
      # M65 cache-hit-vs-rebuilt accounting: pre-load the previous
      # generation's manifest (when one exists) into a per-path digest
      # map so each candidate file can be classified before we touch
      # the disk. A file whose new content digest is byte-identical to
      # the previous generation's recorded `postWriteDigest` AND whose
      # live bytes still match is a cache-hit — we leave the live file
      # alone and reuse the recorded digest. Anything else rebuilds.
      var prevFileDigests = initTable[string, Digest256]()
      if activeGenIdHex.len > 0:
        let prevPointerFile = pointerPath(opts.stateDir, activeGenIdHex)
        if fileExists(extendedPath(prevPointerFile)):
          try:
            let prevEnv = readPointerFile(prevPointerFile)
            var prevKey: PrefixIdBytes
            for i in 0 ..< 32:
              prevKey[i] = prevEnv.activationManifestDigest[i]
            let prevBytes = readCasBlob(store, prevKey)
            let prevManifest = decodeManifestBytes(prevBytes)
            for gf in prevManifest.generatedFiles:
              prevFileDigests[gf.absoluteOutputPath] = gf.postWriteDigest
          except CatchableError:
            discard
      var stagedFiles: seq[StagedFileRecord]
      var cacheHitCount = 0
      var rebuiltCount = 0
      # M72 Deliverable 3: the stow materializer is non-destructive. A
      # conflicting pre-existing target raises `EStowConflict` unless a
      # reconcile-drift policy is in effect. The policy is sourced from
      # the CLI flag (`opts.reconcileStowDrift`) OR the env seams the
      # M68/M70 gates already use (`REPRO_HOME_APPLY_RECONCILE_DRIFT` /
      # `REPRO_HOME_APPLY_ACCEPT_OVERWRITE`).
      let stowReconcile =
        if opts.reconcileStowDrift or
           getEnv(ReconcileDriftEnvVar) == "1" or
           getEnv(AcceptOverwriteEnvVar) == "1":
          srpReconcileDrift
        else:
          srpFailClosed
      # A removed `fs.userFile` that agreed with a stow file hands its path
      # back: remove the file it wrote (only while its bytes are what it
      # recorded writing) so the stow file is linked again, and release its
      # binding in step 9b instead of destroying it (`file_facts`).
      let stowIds = stowTargetIds(materializedStowEntries, opts.homeDir)
      if prevManifest.isSome and stowIds.len > 0:
        let handoverDesired = composeDesiredResources(profile, opts.homeDir,
          opts.targetContext)
        for rb in prevManifest.get.resourceBindings:
          if rb.resourceKind.len == 0: continue
          let recorded = toRecorded(rb)
          if handedToStow(recorded, handoverDesired, stowIds, opts.homeDir):
            discard removeUnchangedUserFile(recorded)
      # A path whose stow file now comes from another package: the link (or
      # copy) the current generation recorded there, if still unchanged, is
      # its own and is replaced, not refused as drift
      # (`stow.isRecordedStowTarget`).
      var recordedStow = initTable[string, GeneratedFile]()
      if prevManifest.isSome:
        for gf in prevManifest.get.generatedFiles:
          if gf.ownershipPolicy in {gfoStowSymlink, gfoStowCopy}:
            recordedStow[gf.absoluteOutputPath] = gf
      for entry in materializedStowEntries:
        if entry.targetAbsolutePath in recordedStow:
          discard releaseRecordedStowTarget(entry.targetAbsolutePath,
            entry.sourceAbsolutePath, recordedStow[entry.targetAbsolutePath])
        let rec = materializeStowEntry(opts.profileDir, opts.homeDir, entry,
          stowReconcile)
        var staged: StagedFileRecord
        staged.absoluteOutputPath = rec.targetAbsolutePath
        staged.sourceKind = pgfsStowFile
        staged.stowSource = rec.sourceAbsolutePath
        staged.ownershipPolicy = modeToOwnershipPolicy(rec.mode)
        staged.hasPreWriteDigest = rec.hasPreWriteDigest
        staged.preWriteDigest = rec.preWriteDigest
        staged.postWriteDigest = rec.postWriteDigest
        stagedFiles.add(staged)
        # Stow entries are always classified as "rebuilt" — symlink/
        # junction materialization is idempotent but we don't have a
        # cheap pre-check, and the M65 cache-hit signal is most
        # relevant for package-driven outputs that consume
        # configurables.
        inc rebuiltCount
        if rec.mode != smSymlink:
          # Emit IStowFellBack once per generation per fallback kind.
          var seenSym = false
          var seenJunc = false
          for d in result.diagnostics:
            if d.code == sdIStowFellBack:
              if d.fallbackTo == "junction": seenJunc = true
              if d.fallbackTo == "copy":
                if d.fallbackFrom == "symlink": seenSym = true
                else: seenJunc = true
          case rec.mode
          of smJunction:
            if not seenJunc:
              result.diagnostics.add(StowDiagnostic(
                severity: dsInfo,
                code: sdIStowFellBack,
                path: rec.targetAbsolutePath,
                fallbackFrom: "symlink",
                fallbackTo: "junction",
                message: "IStowFellBack: symlink unavailable for " &
                  rec.targetAbsolutePath & "; used NTFS junction at " &
                  "the deepest stow-exclusive ancestor."))
          of smCopy:
            if not seenSym:
              result.diagnostics.add(StowDiagnostic(
                severity: dsInfo,
                code: sdIStowFellBack,
                path: rec.targetAbsolutePath,
                fallbackFrom: "symlink",
                fallbackTo: "copy",
                message: "IStowFellBack: symlink and junction both " &
                  "unavailable for " & rec.targetAbsolutePath &
                  "; copied the source file contents."))
          else: discard
      # Package-driven files. M65: classify each file as cache-hit or
      # rebuilt before deciding whether to re-write. We compute the
      # candidate post-write digest from the planned content bytes
      # and compare against the previous generation's recorded digest
      # for the same absolute path. If they match AND the live file
      # exists with the same digest, the file is a cache-hit: we
      # synthesize the `StagedFileRecord` from the cached digest and
      # skip the atomic write entirely.
      for g in applyPlan.generatedFiles:
        if g.sourceKind != pgfsPackageOutput or not filesApplied:
          continue
        let candidateDigest = digestOf(g.contentBytes)
        var isCacheHit = false
        if g.absoluteOutputPath in prevFileDigests and
           prevFileDigests[g.absoluteOutputPath] == candidateDigest and
           fileExists(extendedPath(g.absoluteOutputPath)):
          let raw = readFile(extendedPath(g.absoluteOutputPath))
          var liveBuf = newSeq[byte](raw.len)
          for i, ch in raw:
            liveBuf[i] = byte(ord(ch))
          if digestOf(liveBuf) == candidateDigest:
            isCacheHit = true
        if opts.recordOnlyGeneratedFiles:
          var staged: StagedFileRecord
          staged.absoluteOutputPath = g.absoluteOutputPath
          staged.sourceKind = pgfsPackageOutput
          staged.contributingPackage = g.contributingPackage
          staged.ownershipPolicy = gfoOwned
          staged.hasPreWriteDigest = false
          staged.postWriteDigest = candidateDigest
          stagedFiles.add(staged)
          inc rebuiltCount
        elif isCacheHit:
          var staged: StagedFileRecord
          staged.absoluteOutputPath = g.absoluteOutputPath
          staged.sourceKind = pgfsPackageOutput
          staged.contributingPackage = g.contributingPackage
          staged.ownershipPolicy = gfoOwned
          staged.hasPreWriteDigest = true
          staged.preWriteDigest = candidateDigest
          staged.postWriteDigest = candidateDigest
          stagedFiles.add(staged)
          inc cacheHitCount
        else:
          stagedFiles.add(materializePackageOutput(g))
          inc rebuiltCount
      # Seal every staged file's content bytes into CAS keyed by the
      # post-write digest. This is what enables M64 rollback to restore
      # files whose live target is being overwritten: the target
      # generation's manifest carries `storeContentHash = postWriteDigest`
      # and the bytes are reachable via `readCasBlob`. M63 only RECORDS
      # the digest; M64 needs the bytes too.
      proc readFileBytes(path: string): seq[byte] =
        let raw = readFile(extendedPath(path))
        result = newSeq[byte](raw.len)
        for i, ch in raw:
          result[i] = byte(ord(ch))
      for g in applyPlan.generatedFiles:
        if g.sourceKind == pgfsPackageOutput and filesApplied:
          discard storeCasBlob(store, g.contentBytes)
      for entry in materializedStowEntries:
        if fileExists(extendedPath(entry.sourceAbsolutePath)):
          let bytes = readFileBytes(entry.sourceAbsolutePath)
          discard storeCasBlob(store, bytes)
      # Materialize synthetic managed blocks from the M64 test hook.
      # In production, M65 wires the M59 `fs.managedBlock` stdlib hook
      # to populate this list; for now the gates use the env-var seam.
      var appliedManagedBlocks: seq[AppliedManagedBlockRecord]
      let syntheticBlocks = parseSyntheticPackageManagedBlocks(opts.homeDir,
        packageIds)
      for mb in syntheticBlocks:
        if blocksApplied:
          appliedManagedBlocks.add(applyManagedBlock(mb))
        else:
          inc result.notAppliedCount
      # Diff against the previous generation's manifest: any file or
      # managed block it owned that the new generation does NOT own
      # is removed before we commit. Without this, files that A's plan
      # generated but B's plan no longer mentions would persist on
      # disk across the A -> B transition (and would block M64 rollback's
      # symmetric "remove + restore" plan). The drift here matches the
      # apply pipeline's documented "Step 5: Plan diff against current"
      # spec line; M63 deferred the actual deletion work to a later
      # milestone, and we land it under M64 because rollback's
      # symmetry assumes apply already cleaned up.
      if activeGenIdHex.len > 0 and not opts.recordOnlyGeneratedFiles:
        let prevPointerFile = pointerPath(opts.stateDir, activeGenIdHex)
        if fileExists(extendedPath(prevPointerFile)):
          var newPaths: seq[string]
          for sf in stagedFiles:
            newPaths.add(sf.absoluteOutputPath)
          let prevEnv = readPointerFile(prevPointerFile)
          var prevManifestKey: PrefixIdBytes
          for i in 0 ..< 32:
            prevManifestKey[i] = prevEnv.activationManifestDigest[i]
          try:
            let prevManifestBytes = readCasBlob(store, prevManifestKey)
            let prevManifest = decodeManifestBytes(prevManifestBytes)
            for gf in prevManifest.generatedFiles:
              # GM7: a file of a concern this apply does not own is released
              # (listed in `result.released`), never deleted.
              if gf.absoluteOutputPath notin newPaths and filesApplied:
                deleteRemovedFile(gf.absoluteOutputPath)
            # Same for managed blocks.
            var newBlockKeys: seq[string]
            for mb in appliedManagedBlocks:
              newBlockKeys.add(mb.hostFilePath & "\x1a" & mb.blockId)
            for mb in prevManifest.managedBlocks:
              let k = mb.hostFilePath & "\x1a" & mb.blockId
              if k notin newBlockKeys and blocksApplied:
                # Strip the sentinel-delimited region from the host file.
                if fileExists(extendedPath(mb.hostFilePath)):
                  let existing = readFile(extendedPath(mb.hostFilePath))
                  let openS = OpenSentinelPrefix & mb.blockId &
                    OpenSentinelSuffix
                  let closeS = CloseSentinelPrefix & mb.blockId &
                    CloseSentinelSuffix
                  let openIdx = existing.find(openS)
                  let closeIdx = existing.find(closeS)
                  if openIdx >= 0 and closeIdx >= 0 and closeIdx > openIdx:
                    var openLineStart = openIdx
                    while openLineStart > 0 and
                        existing[openLineStart - 1] != '\n':
                      dec openLineStart
                    var closeLineEnd = closeIdx + closeS.len
                    if closeLineEnd < existing.len and
                        existing[closeLineEnd] == '\n':
                      inc closeLineEnd
                    let rewritten = existing[0 ..< openLineStart] &
                      existing[closeLineEnd .. ^1]
                    writeFile(extendedPath(mb.hostFilePath), rewritten)
          except CatchableError:
            # The previous manifest may be unreadable in pathological
            # cases (manifest in CAS was GC'd by another tool, etc.).
            # The apply still proceeds; rollback would surface the
            # missing-blob diagnostic later.
            discard
      if shouldKillAfter(8):
        raiseKilledByTestHook(8)

      # ---- Step 9: materialize launch plans -----------------------------
      let perGenBin = generationBinDir(opts.stateDir,
        generationIdHex(candidateId))
      createDir(extendedPath(perGenBin))
      # An application's launchers run its placed copy in ~/Applications
      # (`app_activation.launcherExecutablePath`); a remote bundle build
      # places nothing, so its launchers keep the store path.
      let launchers = materializeLaunchers(store, perGenBin, realized,
        ownedLaunchers,
        if opts.recordOnlyGeneratedFiles: ""
        else: applicationsDir(apsHome, opts.homeDir))
      if shouldKillAfter(9):
        raiseKilledByTestHook(9)

      # ---- Step 9b: reconcile typed resources (M68 / M78) ---------------
      # M78: the M68 DesiredSet is composed from the profile's
      # `resources:` block (the production source). For each desired
      # resource + any recorded binding from the previous generation,
      # decide the action via the lifecycle algorithm and execute it
      # via the appropriate M68 driver. Each applied action produces a
      # `ResourceBinding` record for the manifest. `REPRO_TEST_RESOURCES`
      # remains as a TEST-ONLY override merged over the profile entries
      # by address (so existing M68/M70 gates keep working).
      var desiredResources = initDesiredSet()
      if not opts.recordOnlyGeneratedFiles:
        # GM7: only the declared resources of an applied concern.
        for address, res in composeDesiredResources(profile, opts.homeDir,
            opts.targetContext).resources:
          if concernOfResourceKind(res.kind) in owned:
            desiredResources.resources[address] = res
          else:
            inc result.notAppliedCount
      # M69 step 5: synthesize PATH + per-tool env var resources from
      # the realized records and merge them into the desired set. The
      # synthesis is by-package, so a re-apply with unchanged catalog
      # slices produces byte-identical resources and the lifecycle
      # planner cache-hits on the second apply. Author-written
      # `resources:` entries WIN over the synthesized records: the
      # profile is the source of truth, the synthesized records are a
      # fallback that fills the PATH/env binding gap when the profile
      # did not declare an explicit `env.userPath` / `env.userVariable`
      # for the package. Skip when `recordOnlyGeneratedFiles` is set
      # (remote-apply bundle build) so the bundle stays focused on
      # generated files per 17e43c7's intent.
      if not opts.recordOnlyGeneratedFiles:
        let envBindingPlan = planEnvBindings(realized, opts.homeDir)
        for synthRes in envBindingPlan.resources:
          if synthRes.address notin desiredResources.resources:
            desiredResources.resources[synthRes.address] = synthRes
        # GM4c: every realized macOS application bundle is placed in
        # ~/Applications by a synthesized `macos.appBundle` resource
        # (Store-And-Installation-Layout.md § macOS Application Bundles).
        for appRes in planAppBundleActivations(realized, opts.homeDir):
          desiredResources.resources[appRes.address] = appRes
      # M69 Phase C follow-up: defence-in-depth layer 1. The four
      # POSIX/macOS home drivers (`gsettings`, `defaults`,
      # `systemd_user`, `launchd_user`) interpolate operator-controlled
      # typed fields into shell command lines. Reject — fail-closed,
      # before the plan is composed or any driver runs — any resource
      # whose shell-bound field bears a shell metacharacter or falls
      # outside its closed identifier set. The drivers also `quoteShell`
      # those fields at the call site (layer 2).
      for addr1, res in desiredResources.resources:
        let validationErr = resourceValidationError(res)
        if validationErr.len > 0:
          raiseResourceDriver(addr1, $res.kind,
            "pre-dispatch validation", validationErr)
      var recordedBindings = initOrderedTable[string, RecordedBinding]()
      if activeGenIdHex.len > 0 and not opts.recordOnlyGeneratedFiles:
        let prevPointerFile = pointerPath(opts.stateDir, activeGenIdHex)
        if fileExists(extendedPath(prevPointerFile)):
          try:
            let prevEnv = readPointerFile(prevPointerFile)
            var prevKey: PrefixIdBytes
            for i in 0 ..< 32:
              prevKey[i] = prevEnv.activationManifestDigest[i]
            let prevBytes = readCasBlob(store, prevKey)
            let prevManifest = decodeManifestBytes(prevBytes)
            let prevApps = applicationPackagesOf(prevManifest)
            for rb in prevManifest.resourceBindings:
              # Only consider V2 records (with resourceKind set);
              # V1 records may have empty kind which we skip.
              if rb.resourceKind.len == 0: continue
              # GM7: a binding of a concern this apply does not own is
              # released: not planned (so never destroyed or drift-checked)
              # and not recorded by the new generation.
              if concernOfBinding(rb, prevApps) notin owned: continue
              # A removed `fs.userFile` whose path a stow file of this
              # generation now links is released too: the stow step has
              # already put its link there, and destroying the binding would
              # delete that link (`file_facts.handedToStow`).
              let recorded = toRecorded(rb)
              if handedToStow(recorded, desiredResources, stowIds,
                  opts.homeDir):
                continue
              # Skip destroyed records (postWriteDigest is zero).
              recordedBindings[rb.resourceAddress] = recorded
          except CatchableError:
            discard
      var reconcilePolicy = rpFailClosed
      if getEnv(ReconcileDriftEnvVar) == "1":
        reconcilePolicy = rpReconcileDrift
      elif getEnv(AcceptOverwriteEnvVar) == "1":
        reconcilePolicy = rpAcceptOverwrite
      # M68 Phase B: `lifecyclePolicy = preventDestroy` enforcement
      # is now active in the apply executor. The lifecycle algorithm
      # raises `EPreventDestroy` for any resource that would be
      # destroyed while carrying `lpPreventDestroy` — `preventDestroy`
      # is absolute at home scope: it is NOT bypassable by
      # `--reconcile-drift` or `--accept-overwrite` (the enforcement
      # branch in `decideAction` fires before the destroy action is
      # ever produced, regardless of `reconcile`).
      var decisionOpts = DecisionOptions(reconcile: reconcilePolicy,
        enforcePreventDestroy: true)
      let planReport = composePlan(desiredResources, recordedBindings,
        decisionOpts)
      # M68 Phase B: `repro home adopt` passes one or more resource
      # addresses through `opts.adoptAddresses`. Adopt CLAIMS an
      # existing out-of-band object: the resource MUST be declared
      # in the profile's intent (the desired set), and the apply
      # step records its live observed bytes as both the pre- and
      # post-write digest WITHOUT running the driver's create /
      # update. A subsequent apply then sees the resource as a
      # cache-hit because the recorded post-write digest matches
      # the live state.
      var adoptSet = initHashSet[string]()
      for a in opts.adoptAddresses:
        if a notin desiredResources.resources:
          raiseAdoptUndeclared(a)
        adoptSet.incl(a)
      # GM4c: replacing a bundle is allowed only when the previous
      # generation recorded (and did not destroy) it; the early check after
      # step 7 refused every other occupied target already.
      proc managesAppBundle(address: string): bool =
        address in recordedBindings and
          not isZeroDigest(recordedBindings[address].postWriteDigest)
      var appliedResourceBindings: seq[ResourceBinding]
      for action in planReport.actions:
        # Adopt override: regardless of what the lifecycle decided
        # (create / update / drift), an adopt address is recorded
        # as-is from the live observation.
        if action.address in adoptSet:
          let desired = desiredResources.resources[action.address]
          let observed = observeResource(desired)
          var rb: ResourceBinding
          if observed.present:
            # Adopt the live bytes verbatim: preWrite == postWrite
            # == digest(observed). No driver write happened.
            rb = bindingOfLiveObject(action.address, desired, observed)
            # `toResourceBinding` sets preWriteDigest from the
            # observed state when present — for adopt the pre- and
            # post-write digests are intentionally equal.
          else:
            # Nothing to adopt at this address — the object does
            # not exist out-of-band. Surface a clear failure.
            raiseAdoptFailed(action.address,
              "no existing object found to adopt; `repro home apply` " &
              "would CREATE this resource — run apply instead of adopt")
          appliedResourceBindings.add(rb)
          continue
        case action.kind
        of rakDriftBlocked:
          raiseIfDriftBlocked(action)
        of rakNoOp:
          # Cache-hit: re-record the previous binding's bytes so
          # rollback diffs cleanly. A deferred change (the object is in
          # use) and a kept vendor update are no-ops too: the live object
          # is still the recorded one (or its vendor's update of it), so
          # the record stays. A deferred record is marked, so the next
          # apply cannot short-circuit past the change it still owes.
          if action.address in recordedBindings:
            let prev = recordedBindings[action.address]
            var rb = ResourceBinding(
              resourceAddress: prev.address,
              providerIdentity: "repro.builtin",
              realWorldIdentity: prev.resourceId,
              lifecyclePolicy: $prev.lifecyclePolicy,
              resourceKind: $prev.kind,
              hasPreWriteDigest: prev.hasPreWriteDigest,
              preWriteDigest: prev.preWriteDigest,
              postWriteDigest: prev.postWriteDigest,
              payloadKind:
                if action.deferred: withDeferredMark(prev.payloadKind)
                else: withoutDeferredMark(prev.payloadKind),
              payloadBytes: prev.payloadBytes)
            appliedResourceBindings.add(rb)
            if action.deferred:
              result.deferred.add(action.address & " " & action.summary)
            if action.keptVendorUpdate:
              let observed = observeRecorded(action.address, prev)
              result.keptVendorUpdates.add(action.address & " " &
                describeIdentityVersion(observed.rawBytes))
          elif action.address in desiredResources.resources and
              not action.deferred:
            # A first apply that found the object already holding the
            # declared state: record it as written (pre- == post-write ==
            # the observation, as `repro home adopt` does), so the next
            # apply knows the object is this generation's -- a later change
            # of the declared content is then an ordinary update, and
            # removing the resource destroys it. Without the record, the
            # next apply would see an unrecorded object, which for a whole
            # object is drift (`lifecycle.decideAction`).
            let desired = desiredResources.resources[action.address]
            let observed = observeResource(desired)
            if observed.present and desired.kind != rkMacosAppBundle:
              appliedResourceBindings.add(
                bindingOfLiveObject(action.address, desired, observed))
        of rakCreate, rakUpdate, rakReplace:
          let desired = desiredResources.resources[action.address]
          let identity = realWorldIdentity(desired)
          var preWrite = observeResource(desired)
          # Drive the driver per kind.
          var postWriteBytes: seq[byte]
          var payloadKindStr = ""
          case desired.kind
          of rkWindowsRegistryValue:
            when defined(windows):
              let subkey = stripHkcuPrefix(desired.registryKey)
              let regType = registryValueKindToRegType(
                desired.registryPayload.kind)
              writeRegistryValue(subkey, desired.registryName, regType,
                desired.registryPayload.bytes)
              if desired.registryBroadcastChange:
                broadcastEnvironmentChange()
            postWriteBytes = desired.registryPayload.bytes
            payloadKindStr = $desired.registryPayload.kind
          of rkEnvUserVariable:
            postWriteBytes = applyUserVariableCreate(desired.envVarName,
              desired.envVarPayload, desired.envVarHostFilePath)
            payloadKindStr = $desired.envVarPayload.kind
          of rkEnvUserPath:
            var priorEntries: seq[string] = @[]
            if action.address in recordedBindings:
              priorEntries = parseRecordedPathEntries(
                recordedBindings[action.address].payloadBytes)
            postWriteBytes = applyUserPath(desired.pathEntries,
              priorEntries, desired.pathHostFilePath,
              desired.pathBlockId)
            payloadKindStr = "joined-entries"
          of rkWindowsStartup:
            postWriteBytes = applyStartup(desired.startupName,
              desired.startupCommand)
            payloadKindStr = "string"
          of rkShellIntegration:
            postWriteBytes = applyShellIntegration(desired.shellHostFilePath,
              desired.shellBlockId, desired.shellBlockContent)
            payloadKindStr = "shell-block"
          of rkFsManagedBlock:
            postWriteBytes = applyManagedBlockResource(desired.hostFilePath,
              desired.managedBlockId, desired.managedBlockContent)
            payloadKindStr = "managed-block"
          of rkLinuxGsettings:
            # Phase B driver: re-raises ENotImplementedPlatform off-Linux.
            postWriteBytes = applyGsettings(desired.gsettingsSchema,
              desired.gsettingsPath, desired.gsettingsKey,
              desired.gsettingsValueLiteral)
            payloadKindStr = "gvariant-literal"
          of rkSystemdUserUnit:
            # Phase B driver: re-raises ENotImplementedPlatform off-Linux.
            # M83 step 4b: pass the typed `unitState` through so the
            # driver can converge start/stop separately from
            # enable/disable.
            postWriteBytes = applyUserUnit(opts.homeDir, desired.unitName,
              desired.unitContent, desired.unitEnabled, desired.unitState)
            payloadKindStr = "unit-content"
          of rkMacosUserDefault:
            # Phase B driver: re-raises ENotImplementedPlatform off-macOS.
            postWriteBytes = applyUserDefault(desired.defaultsDomain,
              desired.defaultsKey, desired.defaultsValueLiteral,
              desired.defaultsRestartTarget, valueChanged = true)
            payloadKindStr = "defaults-literal"
          of rkLaunchdUserAgent:
            # Phase B driver: re-raises ENotImplementedPlatform off-macOS.
            # M83 step 4b: the plist bytes the driver writes come from
            # `launchAgentPlistFor`, which renders from the typed
            # `programArgs` / `runAtLoad` / `keepAlive` fields when
            # `launchdPlistContent` is empty. The canonical-content
            # path mirrors `digestOfResource(rkLaunchdUserAgent)` so a
            # re-apply with unchanged typed fields cache-hits.
            let plistBytes = launchAgentPlistFor(desired.launchdLabel,
              desired.launchdProgramArgs, desired.launchdRunAtLoad,
              desired.launchdKeepAlive, desired.launchdPlistContent)
            postWriteBytes = applyLaunchAgent(opts.homeDir,
              desired.launchdLabel, plistBytes,
              desired.launchdRunAtLoad, desired.launchdKeepAlive)
            payloadKindStr = "plist-content"
          of rkFsUserFile:
            # `applyUserFileResource` does the create / overwrite,
            # applies POSIX mode on POSIX hosts, no-ops mode on
            # Windows, and re-probes via `observeUserFile`. The
            # returned bytes are exactly what's on disk after the
            # write — used as the recorded payload.
            #
            # M83 step 10: when `userFileContentFromCommand` is non-
            # empty, route through `applyUserFileResourceCmd`. The
            # recorded post-write digest from the previous
            # generation (if any) is passed so the driver can
            # short-circuit the command invocation on a cache-hit
            # when `userFileCacheKey` is non-empty.
            if desired.userFileContentFromCommand.len > 0:
              var recordedPostDigest = zeroDigest()
              var hasRecordedPost = false
              if action.address in recordedBindings:
                let prev = recordedBindings[action.address]
                if not isZeroDigest(prev.postWriteDigest):
                  recordedPostDigest = prev.postWriteDigest
                  hasRecordedPost = true
              postWriteBytes = applyUserFileResourceCmd(
                desired.userFileHostPath,
                desired.userFileContentFromCommand,
                desired.userFileMode,
                desired.userFileCacheKey,
                recordedPostDigest,
                hasRecordedPost)
            else:
              postWriteBytes = applyUserFileResource(desired.userFileHostPath,
                desired.userFileContent, desired.userFileMode)
            payloadKindStr = "user-file"
          of rkVscodeExtension:
            # The vscode.extension driver wraps `code --list/install/
            # uninstall-extension`. Reconciles the live installed
            # extension set to the desired declared set (subset
            # semantics when `removeUnknown=false`, strict-set
            # semantics when `removeUnknown=true`). The recorded
            # payload is the canonical-observed bytes.
            postWriteBytes = applyVscodeExtensions(
              desired.vscodeExtensions, desired.vscodeRemoveUnknown)
            payloadKindStr = "vscode-extensions"
          of rkLinuxDconfKey:
            # M83 step 7 Driver A. Phase B driver: re-raises
            # ENotImplementedPlatform off-Linux.
            postWriteBytes = applyDconfKey(desired.dconfKey,
              desired.dconfValue)
            payloadKindStr = "gvariant-literal"
          of rkLinuxKdeConfigKey:
            # M83 step 7 Driver B. Phase B driver: re-raises
            # ENotImplementedPlatform off-Linux.
            postWriteBytes = applyKdeConfigKey(desired.kdeFile,
              desired.kdeGroup, desired.kdeKey, desired.kdeValue,
              desired.kdeVersion)
            payloadKindStr = "kde-config-value"
          of rkHomebrewFormula:
            # M83 step 9 Driver A. macOS-only: re-raises
            # ENotImplementedPlatform off-macOS. The driver runs
            # `brew install` (or `brew upgrade` on a version
            # mismatch) and returns the canonical bytes for the
            # ACTUALLY-installed version, so the manifest payload
            # reflects what's really on disk.
            postWriteBytes = applyHomebrewFormula(desired.formulaName,
              desired.formulaVersion, desired.formulaArgs)
            payloadKindStr = "homebrew-formula-version"
          of rkHomebrewCask:
            # M83 step 9 Driver B. macOS-only: re-raises
            # ENotImplementedPlatform off-macOS. Same shape as
            # the formula apply branch but routed through
            # `brew install --cask`.
            postWriteBytes = applyHomebrewCask(desired.caskName,
              desired.caskVersion, desired.caskArgs)
            payloadKindStr = "homebrew-cask-version"
          of rkMacosAppBundle:
            # GM4c: copy the store bundle beside the target, verify the
            # staged copy (trust checks + the store bundle's identity),
            # rename it into place. Replacing an existing bundle is allowed
            # only when this profile placed it (checked above as well).
            # A refusal of the staged copy, or a failed copy or rename, is
            # an apply failure naming the package, the bundle and the
            # check; `stageAppBundle` / `commitStagedAppBundle` have already
            # removed the staged copy and left the target as it was.
            #
            # The placed item may be a FOLDER (an installer application's
            # product folder, Store-And-Installation-Layout.md § Installer
            # applications): it is staged and verified as a whole, and what
            # is recorded is the placed item's identity -- the folder
            # identity for a folder, the bundle's for a bundle.
            let placed =
              try:
                let staged = stageAppBundle(desired.appBundleSource,
                  desired.appBundleTargetDir, desired.appBundleName,
                  desired.appBundleExpectation, desired.appBundleTrust,
                  managedPrior = managesAppBundle(action.address),
                  pinned = desired.appBundleIdentity,
                  mainBundle = desired.appBundleMainPath)
                discard commitStagedAppBundle(staged)
                staged.itemIdentity
              except EAppBundleRefused as err:
                raiseAppBundleFailed(
                  packageIdOfAppBundleAddress(action.address),
                  action.address, desired.appBundleName,
                  desired.appBundleTargetDir / desired.appBundleName,
                  err.check, err.msg)
              except EAppBundlePlacement as err:
                raiseAppBundleFailed(
                  packageIdOfAppBundleAddress(action.address),
                  action.address, desired.appBundleName,
                  desired.appBundleTargetDir / desired.appBundleName,
                  "placement", err.msg)
            postWriteBytes = placed
            payloadKindStr = "app-bundle-identity"
          let rb = toResourceBinding(action.address, desired.kind,
            identity, preWrite, postWriteBytes, payloadKindStr,
            desired.lifecyclePolicy)
          appliedResourceBindings.add(rb)
        of rakDestroy:
          let prev = recordedBindings[action.address]
          var preWrite: ObservedState
          # Drive driver-specific destroy.
          case prev.kind
          of rkWindowsRegistryValue:
            preWrite = observeRecorded(action.address, prev)
            when defined(windows):
              let bs = prev.resourceId.rfind('\\')
              if bs > 0:
                let subkey = stripHkcuPrefix(prev.resourceId[0 ..< bs])
                let name = prev.resourceId[bs + 1 .. ^1]
                deleteRegistryValue(subkey, name)
          of rkEnvUserVariable:
            preWrite = observeRecorded(action.address, prev)
            applyUserVariableDestroy(
              userVariableNameFromIdentity(prev.resourceId),
              userVariableHostFromIdentity(prev.resourceId))
          of rkEnvUserPath:
            let priorEntries = parseRecordedPathEntries(prev.payloadBytes)
            let hostFile = userPathHostFromIdentity(prev.resourceId)
            let blockId = userPathBlockIdFromIdentity(prev.resourceId)
            preWrite = observeUserPath(priorEntries, hostFile, blockId)
            removeUserPathContribution(priorEntries, hostFile, blockId)
          of rkWindowsStartup:
            preWrite = observeRecorded(action.address, prev)
            let bs = prev.resourceId.rfind('\\')
            if bs > 0:
              destroyStartup(prev.resourceId[bs + 1 .. ^1])
          of rkShellIntegration, rkFsManagedBlock:
            preWrite = observeRecorded(action.address, prev)
            let hash = prev.resourceId.rfind('#')
            if hash > 0:
              destroyManagedBlockResource(prev.resourceId[0 ..< hash],
                prev.resourceId[hash + 1 .. ^1])
          of rkLinuxGsettings:
            # Phase B driver: re-raises ENotImplementedPlatform off-Linux.
            preWrite = observeRecorded(action.address, prev)
            let parsed = parseGsettingsIdentity(prev.resourceId)
            if parsed.schema.len > 0 and parsed.key.len > 0:
              destroyGsettings(parsed.schema, parsed.path, parsed.key)
          of rkSystemdUserUnit:
            # Phase B driver: re-raises ENotImplementedPlatform off-Linux.
            preWrite = observeRecorded(action.address, prev)
            # resourceId = "systemd:user:<unitName>"
            const sysPrefix = "systemd:user:"
            if prev.resourceId.startsWith(sysPrefix):
              destroyUserUnit(opts.homeDir,
                prev.resourceId[sysPrefix.len .. ^1])
          of rkMacosUserDefault:
            # Phase B driver: re-raises ENotImplementedPlatform off-macOS.
            preWrite = observeRecorded(action.address, prev)
            # resourceId = "defaults:<domain>:<key>"
            let body = prev.resourceId
            if body.startsWith("defaults:"):
              let rest = body[len("defaults:") .. ^1]
              let colon = rest.rfind(':')
              if colon > 0:
                destroyUserDefault(rest[0 ..< colon],
                  rest[colon + 1 .. ^1], "")
          of rkLaunchdUserAgent:
            # Phase B driver: re-raises ENotImplementedPlatform off-macOS.
            preWrite = observeRecorded(action.address, prev)
            # resourceId = "launchd:user:<label>"
            const lcPrefix = "launchd:user:"
            if prev.resourceId.startsWith(lcPrefix):
              destroyLaunchAgent(opts.homeDir,
                prev.resourceId[lcPrefix.len .. ^1])
          of rkLinuxDconfKey:
            # M83 step 7 Driver A. Phase B driver: re-raises
            # ENotImplementedPlatform off-Linux. The destroy direction
            # resets the dconf key to its schema default.
            preWrite = observeRecorded(action.address, prev)
            const dcPrefix = "dconf:"
            if prev.resourceId.startsWith(dcPrefix):
              destroyDconfKey(prev.resourceId[dcPrefix.len .. ^1])
          of rkLinuxKdeConfigKey:
            # M83 step 7 Driver B. Phase B driver: re-raises
            # ENotImplementedPlatform off-Linux. The destroy direction
            # passes `--delete` to remove the key. The recorded
            # binding does not carry `kdeVersion`; default to 6.
            preWrite = observeRecorded(action.address, prev)
            const kdePrefix = "kde:"
            if prev.resourceId.startsWith(kdePrefix):
              let body = prev.resourceId[kdePrefix.len .. ^1]
              let parts = body.split(':')
              if parts.len >= 3:
                let kdeFile = parts[0]
                let kdeGroup = parts[1]
                let kdeKey = parts[2 .. ^1].join(":")
                destroyKdeConfigKey(kdeFile, kdeGroup, kdeKey, 6)
          of rkHomebrewFormula:
            # M83 step 9 Driver A. macOS-only: re-raises
            # ENotImplementedPlatform off-macOS. The destroy
            # direction runs `brew uninstall <name>`. The
            # `resourceId` is `homebrew:formula:<name>` — strip
            # the prefix to recover the name.
            preWrite = observeRecorded(action.address, prev)
            const formulaPrefix = "homebrew:formula:"
            if prev.resourceId.startsWith(formulaPrefix):
              destroyHomebrewFormula(
                prev.resourceId[formulaPrefix.len .. ^1])
          of rkHomebrewCask:
            # M83 step 9 Driver B. macOS-only: re-raises
            # ENotImplementedPlatform off-macOS. The destroy
            # direction runs `brew uninstall --cask <name>`.
            # The `resourceId` is `homebrew:cask:<name>`.
            preWrite = observeRecorded(action.address, prev)
            const caskPrefix = "homebrew:cask:"
            if prev.resourceId.startsWith(caskPrefix):
              destroyHomebrewCask(
                prev.resourceId[caskPrefix.len .. ^1])
          of rkMacosAppBundle:
            # GM4c: the lifecycle established the bundle at the recorded
            # path is the one this profile placed (observed identity ==
            # recorded post-write identity); remove it.
            preWrite = observeRecorded(action.address, prev)
            removeAppBundle(prev.resourceId)
          of rkFsUserFile:
            # `resourceId` is the resolved host path verbatim. The
            # destroy direction deletes the file; the pre-write
            # observation captures the bytes we destroyed so rollback
            # can restore them.
            preWrite = observeRecorded(action.address, prev)
            destroyUserFileResource(prev.resourceId)
          of rkVscodeExtension:
            # The pre-write observation feeds the rollback record;
            # the destroy direction uninstalls every extension we
            # declared in the recorded payload. Extensions the user
            # installed out-of-band stay.
            preWrite = observeRecorded(action.address, prev)
            # Parse the recorded payload bytes back into the declared
            # extension list (one ID per line — the canonical
            # rendering produced by the apply path).
            var declared: seq[string]
            var line = ""
            for b in prev.payloadBytes:
              if char(b) == '\n':
                if line.len > 0:
                  declared.add(line)
                line = ""
              else:
                line.add(char(b))
            if line.len > 0:
              declared.add(line)
            destroyVscodeExtensions(declared)
          let rb = toDestroyBinding(action.address, prev.kind,
            prev.resourceId, preWrite, prev.payloadKind,
            prev.lifecyclePolicy)
          appliedResourceBindings.add(rb)
        of rakAdopt:
          # Phase B: claim an existing resource into management.
          # Phase A skeleton: just record the observation.
          let prev = recordedBindings.getOrDefault(action.address)
          let rb = ResourceBinding(
            resourceAddress: action.address,
            providerIdentity: "repro.builtin",
            realWorldIdentity: prev.resourceId,
            lifecyclePolicy: $prev.lifecyclePolicy,
            resourceKind: $prev.kind,
            postWriteDigest: prev.postWriteDigest,
            payloadKind: prev.payloadKind,
            payloadBytes: prev.payloadBytes)
          appliedResourceBindings.add(rb)

      # ---- Step 10: atomic switch of `current` --------------------------
      # Compose the activation manifest before rotation (rotation is
      # the point of no return). The manifest still needs to be sealed
      # into CAS in step 11.
      var manifest = ActivationManifest(schemaVersion: ManifestSchemaVersion)
      for r in realized:
        manifest.realizedPackages.add(RealizedPackage(
          packageId: r.packageId,
          realizedPrefixId: digestFromKey(r.prefixId),
          adapter: $r.adapter,
          provenance: r.provenance))
      for l in launchers:
        manifest.exportedCommands.add(ExportedCommand(
          commandName: l.commandName,
          launchPlanDigest: l.launchPlanDigest,
          binDirRelativePath: l.binDirRelativePath,
          binDirArtifactKind: l.binDirArtifactKind))
      for sf in stagedFiles:
        var gf: GeneratedFile
        gf.absoluteOutputPath = sf.absoluteOutputPath
        gf.storeContentHash = sf.postWriteDigest
        gf.ownershipPolicy = sf.ownershipPolicy
        gf.hasPreWriteDigest = sf.hasPreWriteDigest
        if sf.hasPreWriteDigest:
          gf.preWriteDigest = sf.preWriteDigest
        gf.postWriteDigest = sf.postWriteDigest
        gf.stowSource = sf.stowSource
        manifest.generatedFiles.add(gf)
      # Managed blocks come from the test-hook synthesizer in
      # Phase A. M68: ResourceBinding records come from the
      # resource lifecycle layer's `appliedResourceBindings`
      # sequence built above.
      for mb in appliedManagedBlocks:
        manifest.managedBlocks.add(ManagedBlock(
          hostFilePath: mb.hostFilePath,
          blockId: mb.blockId,
          preWriteFileDigest: mb.preWriteFileDigest,
          postWriteBlockBytes: mb.postWriteBlockBytes,
          postWriteFileDigest: mb.postWriteFileDigest))
      manifest.resourceBindings = appliedResourceBindings
      # GM7: the generation records the concerns it applied (schema 3), so
      # rollback releases rather than removes what it did not own.
      manifest.concernsDeclared = applied.declared
      if applied.declared:
        manifest.ownedConcerns = concernNames(owned)
      let manifestBytes = encodeManifest(manifest)

      # Build the envelope before rotation; writeGeneration also
      # writes it but we need realizedPrefixIds first.
      var envelope = PointerEnvelope(schemaVersion: 1'u16,
        activationTimestamp: opts.activationTimestamp,
        hostIdentity: opts.host)
      for r in realized:
        envelope.realizedPrefixIds.add(digestFromKey(r.prefixId))
      envelope.generationId = candidateId

      # Step 11 (commit): seal manifest + intent snapshot + RBCG into
      # CAS, write pointer.bin, register store root, attach holds.
      # The pipeline runs the commit BEFORE rotation so a crash
      # during CAS sealing leaves the partial-recovery marker in
      # place and the next apply quarantines this generation. After
      # commit, rotation is a single write of `current.txt` (Windows)
      # or symlink swap (POSIX), neither of which can fail in a way
      # that leaves the system in an inconsistent state.
      let rbcgBytes = manifestBytes  # Phase A: no separate RBCG;
                                     # reuse the manifest bytes as
                                     # placeholder until M58 wires
                                     # configurables.
      writeGeneration(opts.stateDir, envelope, manifestBytes,
        snapshotBytes, rbcgBytes, store)
      if shouldKillAfter(10):
        raiseKilledByTestHook(10)

      # ---- Step 10b: rotate current. From this point forward the
      # generation is reachable from `current`. ---------------------
      rotateCurrent(opts.stateDir, generationIdHex(candidateId))

      # ---- Step 11 (eager GC) -------------------------------------
      result.gcResult = gc(store)

      # Clear the partial-apply marker — success.
      clearMarker(opts.stateDir)

      # GM4b: the generation is committed and current; serialise what it
      # selected into the home-profile lock. A remote bundle built here is
      # applied elsewhere and records nothing beside this profile.
      if not opts.recordOnlyGeneratedFiles:
        recordSelectionsInLock(opts, resolutionCtx, packagePreviews)

      result.kind = aokFreshApplied
      result.generationIdHex = generationIdHex(candidateId)
      result.activationManifestDigestHex = digestHex(envelope.activationManifestDigest)
      result.cacheHitCount = cacheHitCount
      result.rebuiltCount = rebuiltCount
      store.close()
      storeClosed = true
    finally:
      if not storeClosed:
        try: store.close() except CatchableError: discard
  finally:
    releaseApplyLock(lock)
