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
import repro_local_store

import ./dep_graph
import ./errors
import ./plan
import ./realize
import ./materialize_files
import ./materialize_managed_blocks
import ./materialize_launchers
import ./current_rotation
import ./partial_recovery
import ./stow
import ./suppression

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

  PlanItem* = object
    ## One previewed operation in a `repro home apply --plan` run.
    category*: string                 ## "package" | "stow" | "generated-file"
                                       ## | "managed-block" | "launcher"
                                       ## | "resource"
    name*: string                     ## package id / target path / address
    action*: PlanItemAction
    detail*: string                   ## human-readable extra context

  PlanPreview* = object
    ## M72 Deliverable 2: the result of `repro home apply --plan`.
    ## A non-mutating preview of the full apply.
    items*: seq[PlanItem]
    driftCount*: int                   ## items whose action is a drift
    generationIdHex*: string           ## the generation id this plan
                                       ## would produce
    isNoOp*: bool                      ## true when the plan matches the
                                       ## active generation exactly

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

  ApplyOptions* = object
    profileDir*: string                ## "" → resolveProfileDir()
    profilePath*: string               ## "" → resolveProfilePath()
    host*: string                      ## "" → currentHost()
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
  if result.host.len == 0:
    result.host = currentHost()
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
      for c in overrides:
        if c.packageName == pkg and c.configKey == cfgKey:
          resolved = unquoteValueSource(c.configValue)
          found = true
          break
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
        envVarName: parts[0])
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
      lifecyclePolicy: lpDefault, pathEntries: clean)
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
      envVarName: requireAttr(profilePath, entry, "name"))
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
    # `hostFile`, `content`, `mode`, `executable`, plus the
    # cross-kind `depends_on`. An unknown key is refused so a typo
    # ("modee", "execable") never silently degrades to its default —
    # it surfaces as `EUnstructured` naming the offending key.
    const userFileAllowedKeys = ["hostFile", "content", "mode",
      "executable", "depends_on"]
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
    let content = requireAttr(profilePath, entry, "content")
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
      userFileMode: mode,
      userFileExecutable: executable)
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

proc collectProfileResources(profilePath, homeDir, host: string;
                             nodes: seq[IntentNode];
                             into: var DesiredSet) =
  ## Walk a `resources:` block body, emitting one `Resource` per
  ## reachable `nkResourceEntry`. A `nkCondBlock` is recursed into
  ## only when its predicate evaluates true against the host —
  ## reusing the planner's `evaluateHostPredicate` so a
  ## `when windows:`-guarded resource is materialized on Windows and
  ## absent under a non-matching predicate.
  for node in nodes:
    case node.kind
    of nkResourceEntry:
      let r = resourceFromEntry(profilePath, homeDir, node)
      if r.address in into.resources:
        resourceProfileError(profilePath, node.resourceHeaderLine,
          "duplicate resource address `" & r.address &
          "` in the profile's `resources:` block")
      into.add(r)
    of nkCondBlock:
      if evaluateHostPredicate(node.predicateAst, host):
        collectProfileResources(profilePath, homeDir, host,
          node.condChildren, into)
    else:
      discard

proc parseProfileResources*(profile: Profile; homeDir, host: string):
    DesiredSet =
  ## M78: build a `DesiredSet` from the parsed profile's `resources:`
  ## block. Predicates are resolved against `host`. Raises
  ## `EUnstructured` on a malformed entry.
  result = initDesiredSet()
  let blkOpt = findResourcesBlock(profile)
  if blkOpt.isNone:
    return
  collectProfileResources(profile.path, homeDir, host,
    blkOpt.get.resourcesEntries, result)

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
      # Composite seed: host path + mode + content. The seed is fed
      # into the generation-id derivation, so a mode-only or path-only
      # change ALSO bumps the id (the lifecycle's per-resource digest
      # is content-only — mode-only changes are intentionally not
      # treated as drift — but the generation id is content-addressed
      # over the FULL declared shape, including bookkeeping fields,
      # so the no-op short-circuit fires only when the inputs are
      # bytewise identical).
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
    result.add('\x1d')

proc composeDesiredResources*(profile: Profile; homeDir, host: string):
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
  let profileSet = parseProfileResources(profile, homeDir, host)
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
  loadProfileOrRaise(opts.profilePath)

proc deriveGenerationId(plan: ApplyPlan;
                        intentSnapshotDigest: Digest256;
                        resourcesSeed: string = ""): GenerationId =
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
        let bs = rb.realWorldIdentity.rfind('\\')
        if bs > 0:
          live = observeUserVariable(rb.realWorldIdentity[bs + 1 .. ^1])
      of rkEnvUserPath:
        let entries = parseRecordedPathEntries(rb.payloadBytes)
        live = observeUserPath(entries, userPathHostFromIdentity(
          rb.realWorldIdentity))
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

proc previewStowItem(profileDir, homeDir: string;
                     entry: StowEntry): PlanItem =
  ## Read-only classification of one stow entry: would it create a
  ## link, cache-hit (target already correct), or hit a conflict
  ## (target exists as a regular file / wrong link)? Performs ONLY
  ## reads — never touches the filesystem.
  result.category = "stow"
  result.name = entry.targetAbsolutePath
  let target = entry.targetAbsolutePath
  let source = entry.sourceAbsolutePath
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
  ## The package-catalog query (`scoop list`, bucket-manifest reads)
  ## is a READ and is allowed; `scoop install` is not — the planner
  ## calls `resolvePackage` (a pure query), never `realizeScoopAdapter`.
  ##
  ## The apply lock is intentionally NOT acquired: a read-only plan
  ## must never block a concurrent real apply.
  let opts = resolveOptions(rawOpts)
  ensureStateDir(opts.stateDir)

  # ---- Step 2: load intent ----------------------------------------------
  if not fileExists(extendedPath(opts.profilePath)):
    raiseIntentLoad(opts.profilePath,
      "no home.nim at expected path (profile-dir: " & opts.profileDir & ")")
  let profile = resolveProfileFromOpts(opts)

  # ---- Step 4: build plan + synthetic seams + stow discovery ------------
  var applyPlan = buildPlan(profile, opts.profileDir, opts.host)
  var packageIds: seq[string]
  for p in applyPlan.packages:
    packageIds.add(p.packageId)
  let synthetic = parseSyntheticPackageGenerates(opts.homeDir, packageIds,
    applyPlan.configContributions)
  for s in synthetic:
    applyPlan.generatedFiles.add(s)
  let stowDiscovery = discoverStowEntries(opts.profileDir, opts.homeDir)
  let stowEntries = stowDiscovery.entries
  if stowEntries.len > 0:
    let stowPlanned = stowEntriesToPlanned(stowEntries)
    for sp in stowPlanned:
      applyPlan.generatedFiles.add(sp)
  let suppressed = suppressStowShadowed(applyPlan.generatedFiles,
    applyPlan.configContributions)
  applyPlan.generatedFiles = suppressed.files

  # ---- Step 6: derive generation id + no-op detection -------------------
  let intentSnapshot = IntentSnapshot(schemaVersion: 1'u16,
    files: defaultWalkProfileFiles(opts.profileDir))
  let snapshotBytes = encodeSnapshot(intentSnapshot)
  let snapshotDig = digestOf(snapshotBytes)
  # M78: the generation-id resource seed is the composed desired set
  # (profile `resources:` block + `REPRO_TEST_RESOURCES` override),
  # so a change to a profile-declared resource produces a distinct id.
  let resourcesSeed = resourceSeedString(
    composeDesiredResources(profile, opts.homeDir, opts.host))
  let candidateId = deriveGenerationId(applyPlan, snapshotDig, resourcesSeed)
  result.generationIdHex = generationIdHex(candidateId)
  let activeGenIdHex = readCurrentGenerationId(opts.stateDir)

  # ---- Package preview: production catalog resolution (READ ONLY) -------
  # The catalog query (scoop list / bucket manifests) is a read; the
  # preview never calls `realizeScoopAdapter`, so no `scoop install`
  # runs. `previewPackageResolutions` lives in `realize.nim` so the
  # preview and the real dispatch share one resolution path.
  for pp in previewPackageResolutions(applyPlan.packages):
    var item = PlanItem(category: "package", name: pp.packageId,
      detail: pp.detail)
    case pp.kind
    of ppkRealize: item.action = piaRealize
    of ppkCacheHit: item.action = piaCacheHit
    of ppkMissing:
      item.action = piaMissing
      inc result.driftCount
    result.items.add(item)

  # ---- Stow preview -----------------------------------------------------
  for entry in stowEntries:
    let item = previewStowItem(opts.profileDir, opts.homeDir, entry)
    if item.action == piaConflictDrift:
      inc result.driftCount
    result.items.add(item)
  # M73: a file directly under `stow/` is not valid GNU `stow` layout
  # — report it as a skipped stow item; it is not materialized.
  for loose in stowDiscovery.looseFiles:
    result.items.add(PlanItem(category: "stow",
      name: StowSubdirName & "/" & loose,
      action: piaSkip,
      detail: "loose file directly under stow/ — not a GNU stow " &
        "package; skipped (IStowLooseFile)"))

  # ---- Generated files / managed blocks / launchers preview -------------
  var prevFileDigests = initTable[string, Digest256]()
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
      except CatchableError:
        discard
  for g in applyPlan.generatedFiles:
    if g.sourceKind != pgfsPackageOutput:
      continue
    var item = PlanItem(category: "generated-file",
      name: g.absoluteOutputPath)
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
      action: piaWrite,
      detail: "would materialize managed block"))
  for l in applyPlan.launchers:
    result.items.add(PlanItem(category: "launcher",
      name: l.commandName,
      action: piaWrite,
      detail: "launcher for package " & l.fromPackageId))

  # ---- Resource preview (reuses the M68 read-only planner) --------------
  # M78: the desired set is the profile's `resources:` block, with
  # `REPRO_TEST_RESOURCES` merged over it as a test-only override.
  let desiredResources = composeDesiredResources(profile, opts.homeDir,
    opts.host)
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
  var recordedBindings = initOrderedTable[string, RecordedBinding]()
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
        for rb in prevManifest.resourceBindings:
          if rb.resourceKind.len == 0: continue
          recordedBindings[rb.resourceAddress] = toRecorded(rb)
      except CatchableError:
        discard
  let reconcilePolicy =
    if opts.reconcileStowDrift or getEnv(ReconcileDriftEnvVar) == "1" or
       getEnv(AcceptOverwriteEnvVar) == "1":
      rpReconcileDrift
    else:
      rpFailClosed
  let resourcePlan = composePlan(desiredResources, recordedBindings,
    DecisionOptions(reconcile: reconcilePolicy, enforcePreventDestroy: true))
  for a in resourcePlan.actions:
    var item = PlanItem(category: "resource", name: a.address)
    case a.kind
    of rakCreate: item.action = piaCreate
    of rakUpdate: item.action = piaUpdate
    of rakReplace: item.action = piaUpdate
    of rakDestroy: item.action = piaDestroy
    of rakNoOp: item.action = piaNoOp
    of rakAdopt: item.action = piaNoOp
    of rakDriftBlocked:
      item.action = piaConflictDrift
      inc result.driftCount
    item.detail = a.summary
    result.items.add(item)

  # ---- No-op classification ---------------------------------------------
  result.isNoOp = activeGenIdHex.len > 0 and
    result.generationIdHex == activeGenIdHex and result.driftCount == 0

proc renderPlanPreview*(preview: PlanPreview): string =
  ## Stable, line-oriented rendering of a `--plan` preview. The gate
  ## asserts on the category headers and the per-item action verbs.
  result = "repro home apply --plan: " & $preview.items.len &
    " operation(s) previewed, " & $preview.driftCount & " drift(s)\n"
  result.add("  target generation: " & preview.generationIdHex & "\n")
  if preview.isNoOp:
    result.add("  plan status: no-op (matches the active generation)\n")
  var categories = @["package", "stow", "generated-file", "managed-block",
    "launcher", "resource"]
  for cat in categories:
    var any = false
    for item in preview.items:
      if item.category == cat:
        if not any:
          result.add("  [" & cat & "]\n")
          any = true
        result.add("    " & $item.action & "  " & item.name)
        if item.detail.len > 0:
          result.add("  (" & item.detail & ")")
        result.add("\n")

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

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
    var applyPlan = buildPlan(profile, opts.profileDir, opts.host)
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
    let stowDiscovery = discoverStowEntries(opts.profileDir, opts.homeDir)
    let stowEntries = stowDiscovery.entries
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
      let intentSnapshot = IntentSnapshot(schemaVersion: 1'u16,
        files: defaultWalkProfileFiles(opts.profileDir))
      let snapshotBytes = encodeSnapshot(intentSnapshot)
      let snapshotDig = digestOf(snapshotBytes)
      # M78: the generation-id resource seed is the composed desired
      # set (profile `resources:` block + `REPRO_TEST_RESOURCES`
      # override). A change to a profile-declared resource therefore
      # produces a distinct generation id (the no-op short-circuit is
      # not taken). M68 Phase B: an adopt run also contributes its
      # adopt-address set so the adopted binding lands in a new id.
      var resourcesSeed = resourceSeedString(
        composeDesiredResources(profile, opts.homeDir, opts.host))
      if opts.adoptAddresses.len > 0:
        resourcesSeed.add("\x00adopt:")
        for a in opts.adoptAddresses:
          resourcesSeed.add(a)
          resourcesSeed.add(",")
      let candidateId = deriveGenerationId(applyPlan, snapshotDig,
        resourcesSeed)
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
      let realized = realizePlannedPackages(store, applyPlan.packages)
      if shouldKillAfter(7):
        raiseKilledByTestHook(7)

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
      for entry in stowEntries:
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
        if g.sourceKind != pgfsPackageOutput:
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
        if isCacheHit:
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
        if g.sourceKind == pgfsPackageOutput:
          discard storeCasBlob(store, g.contentBytes)
      for entry in stowEntries:
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
        appliedManagedBlocks.add(applyManagedBlock(mb))
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
      if activeGenIdHex.len > 0:
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
              if gf.absoluteOutputPath notin newPaths:
                deleteRemovedFile(gf.absoluteOutputPath)
            # Same for managed blocks.
            var newBlockKeys: seq[string]
            for mb in appliedManagedBlocks:
              newBlockKeys.add(mb.hostFilePath & "\x1a" & mb.blockId)
            for mb in prevManifest.managedBlocks:
              let k = mb.hostFilePath & "\x1a" & mb.blockId
              if k notin newBlockKeys:
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
      let launchers = materializeLaunchers(store, perGenBin, realized,
        applyPlan.launchers)
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
      let desiredResources = composeDesiredResources(profile, opts.homeDir,
        opts.host)
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
            for rb in prevManifest.resourceBindings:
              # Only consider V2 records (with resourceKind set);
              # V1 records may have empty kind which we skip.
              if rb.resourceKind.len == 0: continue
              # Skip destroyed records (postWriteDigest is zero).
              recordedBindings[rb.resourceAddress] = toRecorded(rb)
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
      var appliedResourceBindings: seq[ResourceBinding]
      for action in planReport.actions:
        # Adopt override: regardless of what the lifecycle decided
        # (create / update / drift), an adopt address is recorded
        # as-is from the live observation.
        if action.address in adoptSet:
          let desired = desiredResources.resources[action.address]
          let identity = realWorldIdentity(desired)
          let observed = observeResource(desired)
          var rb: ResourceBinding
          if observed.present:
            # Adopt the live bytes verbatim: preWrite == postWrite
            # == digest(observed). No driver write happened.
            let adoptPayloadKind =
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
            rb = toResourceBinding(action.address, desired.kind,
              identity, observed, observed.rawBytes,
              adoptPayloadKind, desired.lifecyclePolicy)
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
          # rollback diffs cleanly.
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
              payloadKind: prev.payloadKind,
              payloadBytes: prev.payloadBytes)
            appliedResourceBindings.add(rb)
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
              desired.envVarPayload)
            payloadKindStr = $desired.envVarPayload.kind
          of rkEnvUserPath:
            var priorEntries: seq[string] = @[]
            if action.address in recordedBindings:
              priorEntries = parseRecordedPathEntries(
                recordedBindings[action.address].payloadBytes)
            postWriteBytes = applyUserPath(desired.pathEntries,
              priorEntries, desired.pathHostFilePath)
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
            let bs = prev.resourceId.rfind('\\')
            if bs > 0:
              applyUserVariableDestroy(prev.resourceId[bs + 1 .. ^1])
          of rkEnvUserPath:
            let priorEntries = parseRecordedPathEntries(prev.payloadBytes)
            let hostFile = userPathHostFromIdentity(prev.resourceId)
            preWrite = observeUserPath(priorEntries, hostFile)
            removeUserPathContribution(priorEntries, hostFile)
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
