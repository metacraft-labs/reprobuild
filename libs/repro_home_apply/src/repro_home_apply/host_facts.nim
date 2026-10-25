## Host facts, Reprobuild side (reprobuild-pm spec
## Gradual-Nix-To-Reprobuild-Migration.md §Measuring equivalence, §Host
## facts; user guide `docs/user-guide/host-facts.md`).
##
## A host-facts document is one host's home reduced to the four categories
## both the Nix path (Home Manager) and the Reprobuild path can be compared
## on -- packages, files, environment, user services -- keyed on logical ids
## both sides share: canonical Reprobuild package names, `~/`-relative
## paths, variable names, unit names and launchd labels.
##
## This module produces the Reprobuild side from the planning half of the
## apply (`pipeline.planDesiredState`, the constructor `repro home apply
## --plan` uses), so the facts are what an apply would write, never what
## the live home happens to hold. The caller passes a private home
## directory and state directory (`repro home facts` creates both): the
## plan computes target paths under that home and every path is reported
## relative to it, so nothing about the machine's real home enters the
## document. The Nix side is produced by `reprobuild.lib.homeManagerFacts`
## (nix/lib/host-facts.nix) with the same schema.
##
## Content digests are SHA-256 (`sha256:<hex>`) because the Nix producer
## computes them with coreutils over Home Manager's `home-files` tree.

import std/[algorithm, json, strutils, tables]

import repro_home_intent
import repro_home_resources
import repro_profile/concerns

import ./plan
import ./pipeline
import ./file_facts

export file_facts.sha256Digest, file_facts.homeRelativeId

const
  HostFactsFormat* = "repro.host-facts"
  HostFactsSchemaVersion* = 1
    ## Bumped on any change to the meaning of an existing field. Adding an
    ## informational field is compatible; adding a COMPARED field is not
    ## (an older document would then differ from a newer one on a field it
    ## never had).
  HostFactsCategories* = ["packages", "files", "environment", "services"]
    ## The compared categories, in report order.
  HostFactsInformationalFields* = ["id", "origin", "version"]
    ## Entry fields `repro home compare` never compares: the identity
    ## itself, where an entry came from, and the package version (spec
    ## Open question 2: identity only).

proc homeRelativePathEntry*(entry, homeDir: string): string =
  ## The logical id of a PATH entry: `~/<rel>` for an entry under the home
  ## directory however it spells the home (`$HOME`, `${HOME}`, `~`, the
  ## absolute directory), the entry as written otherwise. The Nix producer
  ## (nix/lib/host-facts.nix, `pathEntryId`) names `home.sessionPath`
  ## entries the same way, so one directory has one id on both sides.
  for spelling in ["$HOME", "${HOME}", "~"]:
    if entry == spelling:
      return "~"
    if entry.startsWith(spelling & "/"):
      return "~/" & entry[spelling.len + 1 .. ^1]
  homeRelativeId(entry, homeDir)

proc entry(id, origin: string): JsonNode =
  result = newJObject()
  result["id"] = %id
  result["origin"] = %origin

proc unmappedEntry(category, id, origin, reason: string): JsonNode =
  result = newJObject()
  result["category"] = if category.len > 0: %category else: newJNull()
  result["id"] = %id
  result["origin"] = %origin
  result["reason"] = %reason

proc byId(a, b: JsonNode): int = cmp(a["id"].getStr, b["id"].getStr)

proc sortedArray(items: seq[JsonNode]): JsonNode =
  var sortedItems = items
  sortedItems.sort(byId)
  result = newJArray()
  for it in sortedItems:
    result.add it

type
  FactsBuilder = object
    homeDir: string
    categories: OrderedTable[string, OrderedTable[string, JsonNode]]
    unmapped: seq[JsonNode]
    uncategorized: seq[JsonNode]

proc initFactsBuilder(homeDir: string): FactsBuilder =
  result.homeDir = homeDir
  for c in HostFactsCategories:
    result.categories[c] = initOrderedTable[string, JsonNode]()

proc differingComparedFields*(a, b: JsonNode): seq[string] =
  ## The compared fields (every field but `HostFactsInformationalFields`;
  ## spec §Host facts, "Compared fields") on which two entries for one id
  ## differ, in field-name order. A field one entry has and the other
  ## lacks differs.
  var names: seq[string]
  for k, _ in a:
    if k notin HostFactsInformationalFields and k notin names:
      names.add k
  for k, _ in b:
    if k notin HostFactsInformationalFields and k notin names:
      names.add k
  names.sort()
  for k in names:
    if not (a.hasKey(k) and b.hasKey(k) and a[k] == b[k]):
      result.add k

proc add(b: var FactsBuilder; category: string; e: JsonNode) =
  ## A category holds each id once. Two producers reporting one id describe
  ## the same fact when they agree on every compared field: the first entry
  ## is kept (its `origin` names one of them). When they differ on a
  ## compared field, the host would get one of two different things, so the
  ## document is refused, naming both origins and the differing fields. A
  ## stow file and an `fs.userFile` on one path never reach here -- the
  ## planner keeps one writer or refuses the pair (`file_facts`).
  let id = e["id"].getStr
  if id in b.categories[category]:
    let first = b.categories[category][id]
    let differing = differingComparedFields(first, e)
    if differing.len > 0:
      var detail: seq[string]
      for k in differing:
        detail.add k & " " &
          (if first.hasKey(k): $first[k] else: "(absent)") & " vs " &
          (if e.hasKey(k): $e[k] else: "(absent)")
      raise newException(ValueError, "host facts: two " & category &
        " entries for `" & id & "` (" & first["origin"].getStr & "; " &
        e["origin"].getStr & ") that disagree on " & detail.join(", "))
    return
  b.categories[category][id] = e

proc addResource(b: var FactsBuilder; r: Resource) =
  let origin = resourceOrigin(r.address)
  case r.kind
  of rkFsUserFile:
    var e = entry(homeRelativeId(r.userFileHostPath, b.homeDir), origin)
    e["mode"] = %r.userFileMode
    # A command-generated file's bytes exist only at apply time; the digest
    # is unknown (null) and compares unequal to any real digest.
    let digest = userFileDigest(r)
    e["digest"] = if digest.len == 0: newJNull() else: %digest
    b.add("files", e)
  of rkEnvUserVariable:
    var e = entry("var:" & r.envVarName, origin)
    e["value"] = %decodeRegistryStringValue(r.envVarPayload)
    b.add("environment", e)
  of rkEnvUserPath:
    for p in r.pathEntries:
      b.add("environment", entry("path:" & homeRelativePathEntry(p,
        b.homeDir), origin))
  of rkShellIntegration:
    var e = entry("block:" & homeRelativeId(r.shellHostFilePath, b.homeDir) &
      "#" & r.shellBlockId, origin)
    e["digest"] = %sha256Digest(r.shellBlockContent)
    b.add("environment", e)
  of rkFsManagedBlock:
    var e = entry("block:" & homeRelativeId(r.hostFilePath, b.homeDir) &
      "#" & r.managedBlockId, origin)
    e["digest"] = %sha256Digest(r.managedBlockContent)
    b.add("environment", e)
  of rkSystemdUserUnit:
    var e = entry("systemd:" & r.unitName, origin)
    e["enabled"] = %r.unitEnabled
    e["digest"] = %sha256Digest(r.unitContent)
    b.add("services", e)
  of rkLaunchdUserAgent:
    var e = entry("launchd:" & r.launchdLabel, origin)
    e["programArguments"] = %r.launchdProgramArgs
    e["runAtLoad"] = %r.launchdRunAtLoad
    e["keepAlive"] = %r.launchdKeepAlive
    b.add("services", e)
  of rkHomebrewCask, rkHomebrewFormula:
    # A Homebrew token is not a canonical package name; the profile should
    # name the package and let the bridge record say which token installs
    # it (Provisioning-Contributions.md §Homebrew Bridge Records).
    b.unmapped.add unmappedEntry("packages", r.address, origin,
      "a Homebrew token resource names no canonical package; declare " &
      "the canonical package instead")
  of rkWindowsRegistryValue, rkWindowsStartup, rkLinuxGsettings,
     rkMacosUserDefault, rkVscodeExtension, rkLinuxDconfKey,
     rkLinuxKdeConfigKey, rkMacosAppBundle:
    b.uncategorized.add unmappedEntry("", r.address, origin,
      "no host-facts category covers resource kind `" & $r.kind & "`")

proc hostFactsFromState*(state: PlannedDesiredState; system: string):
    JsonNode =
  ## The Reprobuild-side host-facts document for an already planned state.
  ## `system` is the target platform name (`x86_64-linux`, ...).
  let opts = state.options
  var b = initFactsBuilder(opts.homeDir)

  for p in state.plan.packages:
    var e = entry(p.packageId, "activity " & p.fromActivity)
    if p.requestedVersion.len > 0:
      e["version"] = %p.requestedVersion
    b.add("packages", e)

  for g in state.plan.generatedFiles:
    let id = "~/" & g.relativeHomePath.replace('\\', '/')
    case g.sourceKind
    of pgfsStowFile:
      var e = entry(id, stowOrigin(g.stowSourcePath, opts.profileDir))
      e["mode"] = %linkedMode(g.stowSourcePath, opts.targetContext.platform)
      e["digest"] = %sha256Digest(g.contentBytes)
      b.add("files", e)
    of pgfsPackageOutput:
      var e = entry(id, "package " & g.contributingPackage)
      e["mode"] = %"0644"
      e["digest"] = %sha256Digest(g.contentBytes)
      b.add("files", e)

  for _, r in state.desiredResources.resources:
    b.addResource(r)

  result = newJObject()
  result["format"] = %HostFactsFormat
  result["schemaVersion"] = %HostFactsSchemaVersion
  result["side"] = %"reprobuild"
  result["host"] = %opts.host
  result["system"] = %system
  var cats = newJObject()
  for c in HostFactsCategories:
    var items: seq[JsonNode]
    for _, e in b.categories[c]:
      items.add e
    cats[c] = sortedArray(items)
  result["categories"] = cats
  result["unmapped"] = sortedArray(b.unmapped)
  result["uncategorized"] = sortedArray(b.uncategorized)
  # GM7: informational, never compared -- which concerns Reprobuild applies
  # on this host (Gradual-Nix-To-Reprobuild-Migration.md §Concern-scoped
  # apply). The categories above always describe EVERY concern, so a concern
  # is measured before its declaration moves it.
  var applied = newJArray()
  for name in concernNames(state.applied.concerns):
    applied.add %name
  result["concerns"] = %*{"declared": state.applied.declared,
    "applied": applied}

proc collectHostFacts*(opts: ApplyOptions; system: string): JsonNode =
  ## Plan `opts` (`planDesiredState`) and report its host facts. The
  ## caller chooses `opts.homeDir` / `opts.stateDir`; `repro home facts`
  ## always passes fresh private directories.
  hostFactsFromState(planDesiredState(opts), system)
