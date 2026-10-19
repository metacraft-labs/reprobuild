## `repro home export` — the evaluated home-profile intent as a versioned,
## documented JSON document, plus the comparison behind `--check`.
##
## The document is a published interface: tools outside Reprobuild (a Nix
## module reading a committed snapshot, an equivalence report, a script that
## asks which activities a host runs) consume it instead of re-deriving any of
## it. Its schema is specified in the user guide (`docs/user-guide/home-export.md`)
## and versioned by `HomeExportSchemaVersion`. Bump the version whenever an
## existing field changes meaning or shape; adding a field is compatible.
##
## Everything here is computed from what the normal profile-compile edge
## produced and from the planner's own rules. Nothing is re-derived:
##
## * `intent` is the decoded RBPI envelope the planner consumes, rendered by
##   the one ProfileIntent JSON encoder (`emitProfileIntentJson`).
## * `selection` comes from `enabledActivitiesFor`, the proc `buildPlan`
##   applies, over the same `profileIntentToHomeProfile` adaptation the apply
##   path performs.
## * `provenance.profile.inputs` is the set of profile-directory files io-mon
##   observed the compile edge read — the edge's own dependency record, not a
##   scan of `import` lines.
## * `platforms` compares the intent with the profile evaluated for every
##   target platform by the platform-probe edge (`probeProfilePlatforms`), so
##   a document whose content a compile-time `when defined(...)` decided says
##   so, per platform.
##
## `evaluateHomeExport` is the consumer side: it evaluates a document's
## guards for a target platform and host with the planner's own rules, and
## refuses a target the document cannot describe.
##
## The module performs no plan or apply step and writes nothing; the caller
## compiles (`compileProfileToRbpi`, `probeProfilePlatforms`) and hands the
## results in.

import std/[algorithm, json, options, os, sets, strutils, tables]
from repro_core/paths import extendedPath

import blake3
import repro_core
import repro_home_intent
import repro_home_apply
from repro_home_generations/intent_snapshot import observedProfileFiles
import repro_profile_compile
import repro_home_resources/concerns
from repro_project_dsl/reprobuild_packages_catalog import
  reachableReprobuildPackagesRoots, ReprobuildPackagesRootEnv
from repro_profile/types import ProfileIntent
from repro_profile/host_system import systemManagementFor
from repro_profile/emit import emitProfileIntentJson, parseProfileIntentJson

const
  HomeExportFormat* = "repro.home.export"
    ## Value of the document's `format` field. Identifies the document kind
    ## so a consumer handed some other JSON file fails loudly.
  HomeExportSchemaVersion* = 4
    ## Value of the document's `schemaVersion` field. Version 2 (GM3): the
    ## intent's resources and config overrides carry a `guard`, and the
    ## `platforms` map says which platforms the document describes. A
    ## version-1 reader would apply a guarded resource on every platform, so
    ## this is a new version, not a compatible addition. Version 3 (GM9):
    ## each intent resource carries `activity` (the activity it belongs to,
    ## `null` for profile-wide), and the evaluation keeps an activity-scoped
    ## resource only for a host that selects the activity. A version-2
    ## reader would apply such a resource on every host -- a change of
    ## meaning, so again a new version.
    ## Version 4 (GM10): the intent carries `systemManagedElsewhere` (the
    ## hosts whose system scope something else manages, with the pointer
    ## to it) and the evaluation carries `system`. In a version-3 document
    ## the absence of the map cannot be told from "every host is managed
    ## here", so a reader that acts on the attribute (a system switch
    ## deciding whether to take over a host) would take over every host an
    ## older export describes. A new version makes such a reader refuse the
    ## old document instead.
    ## GM11 adds `intent.stowScopes` (the stow packages an activity's
    ## `stow:` block claims, present only when some activity has one)
    ## WITHOUT a new version: no export reader materializes the stow tree
    ## (the Nix side keeps its own links), so a reader that ignores the key
    ## applies exactly what it applied before; `--check` sees a claim edit
    ## because the key is part of `intent`.
  HomeExportComparedFields* = ["format", "schemaVersion", "selection",
    "intent", "concerns", "platforms"]
    ## The top-level fields `--check` compares. `provenance` is deliberately
    ## absent: it records how the document was produced (which `repro`, from
    ## which files, on which platform), not what it tells a consumer, and
    ## comparing it would make every `repro` upgrade or comment edit look
    ## like an intent change. See `diffHomeExports`.
  MaxReportedDifferences* = 40

type
  HostSelection* = object
    host*: string
    hostDeclared*: bool
      ## The profile's `hosts:` block has an entry for `host`.
    activities*: seq[string]
      ## Activities the planner enables on `host` that the profile declares,
      ## in declaration order.
    unknownActivities*: seq[string]
      ## Activities the host's `hosts:` entry names that the profile does not
      ## declare (the planner enables them and finds nothing in them). Sorted.

  ProfileInput* = object
    path*: string    ## relative to the profile directory, `/`-separated
    blake3*: string  ## BLAKE3-256 of the file's bytes, lower-case hex

  PlatformStatus* = enum
    ## Whether an export describes a target platform (`platforms` field).
    psSame = "same"
      ## The profile evaluated for that platform declares exactly the
      ## exported intent.
    psDiffers = "differs"
      ## It declares something else: a compile-time `when defined(...)`
      ## changed the intent. Consumers refuse the document for it.
    psUnevaluated = "unevaluated"
      ## The probe could not evaluate the profile for it (or could not be
      ## trusted at all); treated as `differs`.

  PlatformDependence* = object
    statuses*: seq[(string, PlatformStatus)]
      ## One entry per `ProfileTargetPlatforms` platform, in table order.
    diagnostics*: seq[(string, string)]
      ## Why each unevaluated platform is unevaluated.

  HomeExportRefused* = object of CatchableError
    ## `evaluateHomeExport` was asked for a target the document cannot
    ## describe. The message names the target, the compiling platform and
    ## the reason.

# ---------------------------------------------------------------------------
# Selection.
# ---------------------------------------------------------------------------

proc hostSelection*(intent: ProfileIntent; profilePath, host: string):
    HostSelection =
  ## The activities the planner enables for `host`, computed by the
  ## planner's own rule (`enabledActivitiesFor`) over the same adaptation of
  ## the compiled intent the apply path uses.
  let profile = profileIntentToHomeProfile(intent, profilePath)
  let active = enabledActivitiesFor(profile, host)
  result.host = host
  result.hostDeclared = intent.hosts.hasKey(host)
  var declared = initHashSet[string]()
  for activity in intent.activities:
    declared.incl activity.name
    if activity.name in active and activity.name notin result.activities:
      result.activities.add activity.name
  for name in active:
    # `default` is enabled on every host whether or not the profile declares
    # it; an absent `activity default:` is not something the host selected.
    if name notin declared and name != "default":
      result.unknownActivities.add name
  result.unknownActivities.sort(cmp[string])

# ---------------------------------------------------------------------------
# Provenance.
# ---------------------------------------------------------------------------

proc fileBlake3Hex(path: string): string =
  blake3.toHex(blake3.digest(readFile(extendedPath(path))))

proc profileInputs*(profileDir: string; observed: openArray[string]):
    seq[ProfileInput] =
  ## The files under `profileDir` among the compile edge's observed reads
  ## that still exist as regular files, with their content digests, sorted by
  ## path. A read of something that is gone (the helper's temporary
  ## `config.nims`) or is a directory is not an input a reader could check.
  ## The selection is the one a home generation's intent snapshot records
  ## (`repro_home_generations.observedProfileFiles`), so the export's
  ## `provenance.profile.inputs` and the snapshot name the same files.
  for rel in observedProfileFiles(profileDir, observed):
    result.add ProfileInput(path: rel,
      blake3: fileBlake3Hex(profileDir / rel))

proc profileDigest*(inputs: openArray[ProfileInput]): string =
  ## BLAKE3 over `<path>\t<blake3>\n` for each input in path order; `""`
  ## when there are none (the engine had no observed read set to report).
  if inputs.len == 0:
    return ""
  var canonical = ""
  for input in inputs:
    canonical.add input.path & "\t" & input.blake3 & "\n"
  blake3.toHex(blake3.digest(canonical))

# ---------------------------------------------------------------------------
# Platform dependence.
# ---------------------------------------------------------------------------

proc platformDependence*(intent: ProfileIntent;
                         outcomes: openArray[ProbeOutcome]):
    PlatformDependence =
  ## Compare the exported (native) intent with the platform probe's
  ## evaluation of the profile for each target platform.
  ##
  ## The probe evaluates in Nim's compile-time VM, so it is trusted only
  ## when its evaluation for the COMPILING platform reproduces the native
  ## intent byte for byte (both rendered by `emitProfileIntentJson`). When it
  ## does not, nothing it says about other platforms is used: every other
  ## platform is unevaluated.
  let native = emitProfileIntentJson(intent)
  let compiling = compilingPlatformSystem()
  var byPlatform = initTable[string, ProbeOutcome]()
  for o in outcomes:
    byPlatform[o.system] = o
  var trustReason = ""
  if findTargetPlatform(compiling) < 0:
    trustReason = "the compiling platform " & compiling &
      " is not a probed platform"
  elif compiling notin byPlatform or not byPlatform[compiling].evaluated:
    trustReason = "the probe could not evaluate the profile for the " &
      "compiling platform " & compiling
  elif byPlatform[compiling].intentJson != native:
    trustReason = "the probe's compile-time evaluation of the profile for " &
      "the compiling platform " & compiling & " differs from its native " &
      "run (the profile does something Nim's compile-time VM does not " &
      "reproduce), so the probe cannot vouch for any platform"
  for t in ProfileTargetPlatforms:
    var status = psUnevaluated
    var why = ""
    if t.system notin byPlatform:
      why = "the probe reported nothing for this platform"
    elif not byPlatform[t.system].evaluated:
      why = byPlatform[t.system].diagnostic
    elif trustReason.len > 0:
      why = trustReason
    elif byPlatform[t.system].intentJson == native:
      status = psSame
    else:
      status = psDiffers
    result.statuses.add (t.system, status)
    if status == psUnevaluated:
      result.diagnostics.add (t.system, why)

proc stringArray(items: openArray[string]): JsonNode =
  result = newJArray()
  for item in items:
    result.add %item

proc concernsDocument*(): JsonNode =
  ## The export's `concerns` object: the concern names in canonical order,
  ## every home-scope resource kind with its concern, and the concern of a
  ## `config:` override -- `repro_home_resources/concerns`, published as
  ## data. Package references are classified per target system by
  ## `packageClassificationDocument` (`concerns.packages`): their concern
  ## depends on the realization the planner selects there.
  ##
  ## `profileBin` is, per target system, where the launchers of the active
  ## generation are reached (`defaultProfileBinLocation`): a base directory
  ## (`home`, `xdgStateHome`, `localAppData`) and a `/`-separated path below
  ## it. A host that gives Reprobuild the `packages` or `applications`
  ## concern but leaves `environment` to Nix needs that directory on `PATH`,
  ## and only the Nix side writes the shell environment there
  ## (Gradual-Nix-To-Reprobuild-Migration.md §Concern-scoped apply, "The
  ## profile's commands").
  var kinds = newJObject()
  for (kind, concern) in resourceKindConcerns():
    kinds[kind] = %($concern)
  var profileBin = newJObject()
  for t in ProfileTargetPlatforms:
    let location = defaultProfileBinLocation(t.platform)
    profileBin[t.system] = %*{"base": $location.base,
      "path": location.components.join("/")}
  %*{"names": stringArray(homeConcernNames()),
    "resourceKinds": kinds,
    "configOverrides": $ConfigOverrideConcern,
    "profileBin": profileBin}

proc sortedNames(s: HashSet[string]): JsonNode =
  var items: seq[string]
  for item in s:
    items.add item
  items.sort()
  stringArray(items)

proc packageClassificationDocument*(intent: ProfileIntent;
                                    profilePath, stateDir: string): JsonNode =
  ## The export's `concerns.packages`: for every `ProfileTargetPlatforms`
  ## system, the package references (`packageClassificationKey`) whose
  ## selection there places an application and those that resolve to
  ## nothing there -- `classifyPackages`, the planner's selection without the
  ## host inventory, over every reference of the profile
  ## (Gradual-Nix-To-Reprobuild-Migration.md §Concern-scoped apply, "The
  ## per-package split comes from Reprobuild"). `intent` is the expanded
  ## intent; catalog projections are staged under `stateDir`. The host-local
  ## lock is not read: one host's selections must not change a shared export.
  ##
  ## Raises `ValueError` when a reference is defined nowhere this process can
  ## see and no `reprobuild-packages` catalog is reachable: the catalog might
  ## define it as an application, and publishing `packages` for it would be
  ## a guess the Nix side then acts on.
  let profile = profileIntentToHomeProfile(intent, profilePath)
  let references = profilePackageReferences(profile)
  var names: seq[string]
  for r in references:
    if r.packageId notin names:
      names.add r.packageId
  let catalog = projectCatalogPackages(names, profilePath,
    stateDir / "catalog-projection", profile.catalogImports)
  var unknown: seq[string]
  result = newJObject()
  for t in ProfileTargetPlatforms:
    let c = classifyPackages(references, profile.adapterPreference,
      t.platform, t.arch, catalog)
    result[t.system] = %*{"applications": sortedNames(c.applications),
      "unresolved": sortedNames(c.unresolved)}
    for key in c.unknownDefinitions:
      if key notin unknown:
        unknown.add key
  if unknown.len > 0 and
      reachableReprobuildPackagesRoots(profilePath).len == 0:
    unknown.sort()
    raise newException(ValueError, "cannot classify the packages of a " &
      "profile whose hosts: entries declare `applies:`: " &
      unknown.join(", ") & " " &
      (if unknown.len == 1: "is" else: "are") & " defined nowhere this " &
      "repro can see, and no reprobuild-packages catalog is reachable, so " &
      "whether " & (if unknown.len == 1: "it is" else: "they are") &
      " an application cannot be known. Point $" &
      ReprobuildPackagesRootEnv & " at a reprobuild-packages checkout " &
      "(Nix IFD: readIntent's / the module's `packagesCatalog`)")

proc buildHomeExport*(intent: ProfileIntent;
                      artifact: ProfileCompileArtifact;
                      probe: ProfilePlatformProbeArtifact;
                      profilePath, host: string;
                      hostSource: HostSource;
                      stateDir: string): JsonNode =
  ## Assemble the export document (schema version `HomeExportSchemaVersion`)
  ## from a compiled intent. Field order is fixed so the rendered bytes are
  ## stable for an unchanged input.
  ##
  ## GM4: `intent` is the compiled intent with its data-file REFERENCES;
  ## the document carries it EXPANDED (`expandProfileData`, the planner's own
  ## expansion), so a consumer reads every row as an ordinary activity
  ## element and never needs the data files, and `--check` sees a data edit
  ## as an intent change. The references move to `provenance.dataFiles`
  ## with the digests of the bytes expanded. The platform comparison uses
  ## the unexpanded intent: the probe evaluates the compile, and the rows
  ## are platform-neutral data (their guards are evaluated per target).
  let expanded = expandProfileData(intent, profilePath)
  let selection = hostSelection(expanded.intent, profilePath, host)
  let inputs = profileInputs(profilePath.parentDir, artifact.observedInputs)
  let digest = profileDigest(inputs)

  var inputsNode = newJArray()
  for input in inputs:
    inputsNode.add %*{"path": input.path, "blake3": input.blake3}
  let revision = sourceRevisionString()
  let dependence = platformDependence(intent, probe.outcomes)
  var platformsNode = newJObject()
  for (system, status) in dependence.statuses:
    platformsNode[system] = %($status)
  var probeNode = newJObject()
  for (system, why) in dependence.diagnostics:
    probeNode[system] = %why
  var dataFilesNode = newJArray()
  for f in expanded.dataFiles:
    dataFilesNode.add %*{"path": f.path,
      "blake3": blake3.toHex(blake3.digest(f.content)),
      "rows": f.rows.len + f.resources.len}

  result = newJObject()
  result["format"] = %HomeExportFormat
  result["schemaVersion"] = %HomeExportSchemaVersion
  result["selection"] = %*{
    "host": selection.host,
    "hostDeclared": selection.hostDeclared,
    "activities": stringArray(selection.activities),
    "unknownActivities": stringArray(selection.unknownActivities)}
  result["intent"] = parseJson(emitProfileIntentJson(expanded.intent))
  # GM7: the concern vocabulary and classification, for a profile that
  # declares which concerns Reprobuild applies per host, so the Nix side
  # reads the classification instead of restating it
  # (Gradual-Nix-To-Reprobuild-Migration.md §Concern-scoped apply).
  if expanded.intent.hostApplies.len > 0:
    result["concerns"] = concernsDocument()
    result["concerns"]["packages"] = packageClassificationDocument(
      expanded.intent, profilePath, stateDir)
  result["platforms"] = platformsNode
  result["provenance"] = %*{
    "repro": {
      "version": versionString(),
      "sourceRevision": (if revision.len > 0: %revision else: newJNull())},
    "hostSource": $hostSource,
    "profile": {
      "root": profilePath.extractFilename,
      "digest": (if digest.len > 0: %digest else: newJNull()),
      "inputs": inputsNode},
    "dataFiles": dataFilesNode,
    "compile": {
      "target": compilingPlatformSystem(),
      "os": hostOS,
      "cpu": hostCPU,
      "defines": stringArray(ProfileCompileDefines),
      "probe": probeNode}}

proc renderHomeExport*(doc: JsonNode): string =
  ## Two-space indented JSON with a trailing newline: a committed snapshot
  ## diffs line by line.
  pretty(doc, 2) & "\n"

# ---------------------------------------------------------------------------
# Comparison (`--check`).
# ---------------------------------------------------------------------------

proc shortValue(n: JsonNode): string =
  let text = if n.isNil: "(absent)" else: $n
  if text.len > 120: text[0 ..< 117] & "..." else: text

proc arrayKeyField(a, b: JsonNode): string =
  ## Arrays whose elements are all objects carrying a unique `name` (e.g.
  ## activities) or `address` (resources) are compared by that key, so an
  ## inserted activity is reported as one addition, not as every later
  ## element changing.
  for field in ["name", "address"]:
    var ok = true
    for arr in [a, b]:
      var seen = initHashSet[string]()
      for item in arr:
        if item.kind != JObject or not item.hasKey(field) or
            item[field].kind != JString or item[field].getStr in seen:
          ok = false
          break
        seen.incl item[field].getStr
      if not ok:
        break
    if ok:
      return field
  ""

proc diffNodes(path: string; snap, fresh: JsonNode; outp: var seq[string]) =
  if snap.kind != fresh.kind:
    outp.add path & ": snapshot has " & shortValue(snap) &
      ", a fresh export has " & shortValue(fresh)
    return
  case snap.kind
  of JObject:
    var keys: seq[string]
    for k in snap.keys: keys.add k
    for k in fresh.keys:
      if not snap.hasKey(k): keys.add k
    for k in keys:
      let sub = if path.len > 0: path & "." & k else: k
      if not fresh.hasKey(k):
        outp.add sub & ": only in the snapshot: " & shortValue(snap[k])
      elif not snap.hasKey(k):
        outp.add sub & ": only in a fresh export: " & shortValue(fresh[k])
      else:
        diffNodes(sub, snap[k], fresh[k], outp)
  of JArray:
    let keyField = arrayKeyField(snap, fresh)
    if keyField.len > 0:
      var freshByKey = initOrderedTable[string, JsonNode]()
      for item in fresh: freshByKey[item[keyField].getStr] = item
      var snapKeys = initHashSet[string]()
      for item in snap:
        let key = item[keyField].getStr
        snapKeys.incl key
        let sub = path & "[" & keyField & "=" & escapeJson(key) & "]"
        if key notin freshByKey:
          outp.add sub & ": only in the snapshot"
        else:
          diffNodes(sub, item, freshByKey[key], outp)
      for key, item in freshByKey:
        if key notin snapKeys:
          outp.add path & "[" & keyField & "=" & escapeJson(key) &
            "]: only in a fresh export"
      # Same members, different order: order is meaningful for consumers
      # that preserve it, so it is a difference too.
      var snapOrder, freshOrder: seq[string]
      for item in snap:
        if item[keyField].getStr in freshByKey:
          snapOrder.add item[keyField].getStr
      for item in fresh:
        if item[keyField].getStr in snapKeys:
          freshOrder.add item[keyField].getStr
      if snapOrder != freshOrder:
        outp.add path & ": order differs: snapshot " & $snapOrder &
          ", a fresh export " & $freshOrder
    else:
      # Unkeyed arrays (an activity body, a string list): align equal
      # elements with a longest-common-subsequence pass, so one inserted
      # package is one "only in a fresh export" line instead of every later
      # element appearing to change. Arrays here are short (one activity's
      # lines), so the quadratic table is cheap.
      let n = snap.len
      let m = fresh.len
      var lcs = newSeq[seq[int]](n + 1)
      for i in 0 .. n: lcs[i] = newSeq[int](m + 1)
      for i in countdown(n - 1, 0):
        for j in countdown(m - 1, 0):
          lcs[i][j] =
            if snap[i] == fresh[j]: lcs[i + 1][j + 1] + 1
            else: max(lcs[i + 1][j], lcs[i][j + 1])
      var i = 0
      var j = 0
      var removed, added: seq[int]
      proc flush(outp: var seq[string]) =
        # One element replaced by one element of the same shape: descend, so
        # the line names the field that changed.
        if removed.len == 1 and added.len == 1 and
            snap[removed[0]].kind == fresh[added[0]].kind and
            (snap[removed[0]].kind != JObject or
             snap[removed[0]].getOrDefault("kind") ==
               fresh[added[0]].getOrDefault("kind")):
          diffNodes(path & "[" & $added[0] & "]", snap[removed[0]],
            fresh[added[0]], outp)
        else:
          for r in removed:
            outp.add path & "[" & $r & "]: only in the snapshot: " &
              shortValue(snap[r])
          for a in added:
            outp.add path & "[" & $a & "]: only in a fresh export: " &
              shortValue(fresh[a])
        removed.setLen(0)
        added.setLen(0)
      while i < n or j < m:
        if i < n and j < m and snap[i] == fresh[j]:
          flush(outp)
          inc i
          inc j
        elif j < m and (i == n or lcs[i][j + 1] >= lcs[i + 1][j]):
          added.add j
          inc j
        else:
          removed.add i
          inc i
      flush(outp)
  else:
    if snap != fresh:
      outp.add path & ": snapshot has " & shortValue(snap) &
        ", a fresh export has " & shortValue(fresh)

proc diffHomeExports*(snapshot, fresh: JsonNode): seq[string] =
  ## The differences between a committed snapshot and a fresh export in the
  ## fields a consumer reads (`HomeExportComparedFields`), one line each.
  ## Empty means the snapshot is current.
  ##
  ## WHY PROVENANCE IS NOT COMPARED. A snapshot is stale when a consumer
  ## reading it would learn something different from what the profile now
  ## says. `provenance` (the `repro` version and revision, the profile files'
  ## digests, the compiling platform) describes how the document was made.
  ## Comparing it would fail the check on every `repro` upgrade and on every
  ## comment-only edit, and a check that fails for no consumer-visible reason
  ## teaches people to regenerate the snapshot without reading the diff —
  ## which is how a real intent change slips through. A provenance change
  ## that DOES change the intent (a module edit, a different platform's
  ## `when defined` branch) shows up in `intent` and fails the check there.
  if snapshot.kind != JObject:
    return @["the snapshot is not a JSON object (expected a `" &
      HomeExportFormat & "` document)"]
  for field in ["format", "schemaVersion"]:
    let snap = snapshot.getOrDefault(field)
    if snap.isNil or snap != fresh[field]:
      return @[field & ": snapshot has " & shortValue(snap) &
        ", this repro writes " & shortValue(fresh[field]) &
        " (the documents are not comparable; re-export)"]
  for field in HomeExportComparedFields:
    if field in ["format", "schemaVersion"]:
      continue
    let snap = snapshot.getOrDefault(field)
    let freshNode = fresh.getOrDefault(field)
    # `concerns` is present only for a profile that declares `applies:`.
    if snap.isNil and freshNode.isNil:
      continue
    if snap.isNil:
      result.add field & ": only in a fresh export"
    elif freshNode.isNil:
      result.add field & ": only in the snapshot"
    else:
      diffNodes(field, snap, freshNode, result)

proc provenanceNotes*(snapshot, fresh: JsonNode): seq[string] =
  ## Informational lines naming provenance fields that differ. They never
  ## make `--check` fail (see `diffHomeExports`).
  proc at(n: JsonNode; path: openArray[string]): JsonNode =
    result = n
    for key in path:
      if result.isNil or result.kind != JObject or not result.hasKey(key):
        return nil
      result = result[key]
  for path in [@["repro", "version"], @["repro", "sourceRevision"],
               @["profile", "digest"], @["dataFiles"], @["compile", "target"],
               @["compile", "os"], @["compile", "cpu"]]:
    let a = at(snapshot, @["provenance"] & path)
    let b = at(fresh, @["provenance"] & path)
    if (a.isNil and not b.isNil) or (not a.isNil and (b.isNil or a != b)):
      result.add "provenance." & path.join(".") & ": snapshot " &
        shortValue(a) & ", now " & shortValue(b)

# ---------------------------------------------------------------------------
# Evaluation for a target (the consumer side).
# ---------------------------------------------------------------------------

proc docAt(doc: JsonNode; path: openArray[string]): JsonNode =
  result = doc
  for key in path:
    if result.isNil or result.kind != JObject or not result.hasKey(key):
      return nil
    result = result[key]

proc requireExportDocument(doc: JsonNode) =
  if doc.isNil or doc.kind != JObject or
      doc.getOrDefault("format") != %HomeExportFormat:
    raise newException(ValueError, "not a `" & HomeExportFormat &
      "` document")
  let version = doc.getOrDefault("schemaVersion")
  if version != %HomeExportSchemaVersion:
    raise newException(ValueError, "export schema version " &
      (if version.isNil: "(absent)" else: $version) & " is not " &
      $HomeExportSchemaVersion & ", the version this repro evaluates; " &
      "re-export")

proc refusalReason*(doc: JsonNode; system: string): string =
  ## Why `doc` cannot describe `system`, or "" when it can. A document
  ## always describes the platform that compiled it; any other platform
  ## needs `platforms[system] == "same"`.
  let compiledFor = docAt(doc, ["provenance", "compile", "target"])
  let compiled = if compiledFor.isNil: "" else: compiledFor.getStr
  if system == compiled:
    return ""
  let status = docAt(doc, ["platforms", system])
  let statusText = if status.isNil: "" else: status.getStr
  if statusText == $psSame:
    return ""
  let origin = "this export was compiled on " &
    (if compiled.len > 0: compiled else: "an unrecorded platform")
  if statusText == $psDiffers:
    return origin & ", and evaluated for " & system & " the profile " &
      "declares a different intent: a compile-time `when defined(...)` " &
      "decided part of it for " & compiled & ". Select platforms with " &
      "runtime predicates (`when macos():`) so one export describes every " &
      "platform, or export on " & system & "."
  let probe = docAt(doc, ["provenance", "compile", "probe", system])
  let why = if probe.isNil: "no probe result" else: probe.getStr
  origin & ", and the platform probe could not evaluate the profile for " &
    system & ", so whether a compile-time `when defined(...)` changes it " &
    "there is unknown (" & why.splitLines()[0] & "). Export on " & system &
    " instead."

proc evaluateHomeExport*(doc: JsonNode; system: string; host = ""):
    JsonNode =
  ## Evaluate an export document for target platform `system` (a
  ## `ProfileTargetPlatforms` name, e.g. `aarch64-darwin`) and host `host`
  ## (default: the document's `selection.host`), with the planner's rules:
  ## the activities `enabledActivitiesFor` enables, the packages `buildPlan`
  ## plans under the target's predicate facts, and the resources and config
  ## overrides whose guards hold there (`applicableResourceEntries` /
  ## `applicableConfigEntries`, the walkers the planner applies) -- an
  ## activity-scoped resource (GM9) only when the host's selection enables
  ## its activity. Resources are the home-scope ones the home planner plans.
  ##
  ## Returns the `evaluation` object (`docs/user-guide/home-export.md`).
  ## Raises `HomeExportRefused` when the document cannot describe `system`
  ## (`refusalReason`), `ValueError` for a document of another format or
  ## version or an unknown platform name.
  requireExportDocument(doc)
  let index = findTargetPlatform(system)
  if index < 0:
    raise newException(ValueError, "unknown target platform '" & system &
      "' (known: " & targetSystemNames().join(", ") & ")")
  let refusal = refusalReason(doc, system)
  if refusal.len > 0:
    raise newException(HomeExportRefused, "cannot evaluate this export " &
      "for " & system & ": " & refusal)
  let selectedHost =
    if host.len > 0: host
    else: doc["selection"]["host"].getStr
  let rootNode = docAt(doc, ["provenance", "profile", "root"])
  let root = if rootNode.isNil: "home.nim" else: rootNode.getStr
  let intent = parseProfileIntentJson($doc["intent"])
  # An export's intent is always expanded (`buildHomeExport`). One that
  # still names data files was not produced by `repro home export`, and
  # evaluating it would silently omit their rows.
  if intent.dataFiles.len > 0:
    raise newException(ValueError, "the document's intent still names " &
      "data files (" & intent.dataFiles.join(", ") & "); an export carries " &
      "them expanded — re-export")
  let profile = profileIntentToHomeProfile(intent, root)
  let ctx = targetHostContext(ProfileTargetPlatforms[index], selectedHost)

  let plan = buildPlan(profile, "", ctx)
  var packages = newJArray()
  for p in plan.packages:
    packages.add %*{"name": p.packageId, "version": p.requestedVersion,
      "binaries": stringArray(p.binaries), "activity": p.fromActivity}
  let selection = hostSelection(intent, root, selectedHost)

  var resources = newJArray()
  let resourcesBlock = findResourcesBlock(profile)
  if resourcesBlock.isSome:
    # GM9: the host's activities decide the activity-scoped resources, by
    # the rule `buildPlan` (above) and the apply pipeline use.
    for entry in applicableResourceEntries(
        resourcesBlock.get.resourcesEntries, ctx,
        enabledActivitiesFor(profile, selectedHost)):
      resources.add doc["intent"]["resources"][
        entry.resourceIntentOrdinal - 1]
  # The planner groups overrides by package; report them in the intent's
  # declaration order.
  var ordinals: seq[int]
  let configBlock = findConfigBlock(profile)
  if configBlock.isSome:
    for pkg in applicableConfigPackages(configBlock.get, ctx):
      for entry in applicableConfigEntries(pkg, ctx):
        ordinals.add entry.configIntentOrdinal
  ordinals.sort()
  var overrides = newJArray()
  for ordinal in ordinals:
    overrides.add doc["intent"]["configOverrides"][ordinal - 1]

  result = %*{
    "target": system,
    "host": selectedHost,
    "activities": stringArray(selection.activities),
    "packages": packages,
    "resources": resources,
    "configOverrides": overrides}
  # GM10: who manages the host's system scope, from the registry entry
  # (`systemManagementFor`); always present, so a reader never mistakes an
  # absent key for "managed here".
  let management = systemManagementFor(intent, selectedHost)
  result["system"] = %*{
    "managed": (if management.managedElsewhere: "elsewhere" else: "here"),
    "managedBy": (if management.managedElsewhere and
                     management.managedBy.len > 0: %management.managedBy
                  else: newJNull())}
  # GM7: the concerns the host's entry declares Reprobuild applies, by the
  # planner's rule; absent when it declares none (every concern).
  let applied = appliedConcernsFor(profile, selectedHost)
  if applied.declared:
    result["applies"] = stringArray(concernNames(applied.concerns))
    # Each package's concern, from the classification the export carries for
    # this system (`packageClassificationDocument`); nothing is classified
    # here, so the Nix library's `evaluate` reads exactly the same.
    let classification = docAt(doc, ["concerns", "packages", system])
    if classification.isNil or classification.kind != JObject:
      raise newException(ValueError, "host " & selectedHost & " declares " &
        "the concerns Reprobuild applies, but the document carries no " &
        "package classification for " & system & " (concerns.packages." &
        system & "); it was produced by a repro that does not publish " &
        "one -- re-export")
    var applications, unresolved: HashSet[string]
    for item in classification{"applications"}.getElems():
      applications.incl item.getStr
    for item in classification{"unresolved"}.getElems():
      unresolved.incl item.getStr
    for p in result["packages"].getElems():
      let key = packageClassificationKey(p["name"].getStr,
        p["version"].getStr)
      p["concern"] = %(if key in applications: $hcApplications
                       else: $hcPackages)
      p["resolved"] = %(key notin unresolved)
    # The profile's commands: a host whose launchers Reprobuild writes
    # (`packages` / `applications`) while Nix writes its shell environment
    # gets the directory that reaches them, for Nix to put on `PATH`
    # (§Concern-scoped apply, "The profile's commands"). Read from the
    # document, as the Nix library's `evaluate` reads it.
    if (hcPackages in applied.concerns or
        hcApplications in applied.concerns) and
        hcEnvironment notin applied.concerns:
      let location = docAt(doc, ["concerns", "profileBin", system])
      if location.isNil or location.kind != JObject or
          location{"base"}.isNil or location{"path"}.isNil:
        raise newException(ValueError, "host " & selectedHost & " leaves " &
          "`environment` to Nix while Reprobuild applies its launchers, but " &
          "the document does not say where they are for " & system &
          " (concerns.profileBin." & system & "); it was produced by a " &
          "repro that does not publish it -- re-export")
      result["profileBin"] = %*{"base": location["base"].getStr,
        "path": location["path"].getStr}
