## `repro home export` prints the intent the planner consumes, with the
## planner's host selection applied.
##
## Primary assertion — `e2e_home_export_matches_compiled_intent`: for a
## fixture profile with two hosts that select DIFFERENT activities,
##
## * the export's `intent` equals the ProfileIntent `repro home plan`
##   compiled and consumed — read independently, from the envelope the plan's
##   compile edge published, not from anything the export wrote;
## * the export's `selection.activities` for each host is the set the
##   planner itself expands (`buildPlan` over the same intent and host:
##   the activities its planned packages come from), and equals the
##   hand-written expectation for each host;
## * the export compiled through the normal edge: run after the plan, the
##   compile is an action-cache hit (no `nim c`); the export's platform probe
##   runs once (one `nim dump`, one `nim check` per target platform), and the
##   next export is answered from the cache for both edges (no `nim` at all);
## * nothing outside the compile cache is written: the state directory (minus
##   `profile-cache/`), the store root and `HOME` are byte-for-byte unchanged
##   across every export run, and no generation exists.
##
## Host selection is exercised, not assumed: `alpha` and `beta` select
## different activities, an undeclared host gets `default` alone, a
## `$REPRO_HOST` selects like `--host` does, and a `--host` that `$REPRO_HOST`
## would silently override is refused.
##
## Schema tripwire: the document's key sets, and the shapes of the activity
## elements, config overrides and resources in it, are the documented schema
## version 2 (GM3 added `platforms`, the `guard` of resources and config
## overrides, and `provenance.compile.target` / `probe`). The
## intent is rendered by the shared ProfileIntent encoder, so an encoder
## change fails here instead of silently changing the published schema.
## GM4 filled `provenance.dataFiles` (reserved, empty, since version 1) and
## carries data rows expanded into ordinary activity elements: the second
## case, "the data-file fields are the documented schema", pins the entry
## shape (`path`, `blake3`, `rows`), that a profile with a `data:` section
## exports the same `intent` key set (no `dataFiles` key — the rows are
## already expanded), and that its package and resource rows have the
## existing element and resource shapes.
## Those are compatible additions, so `schemaVersion` stays 2.
##
## Vacuity guards: the intent has four activities, a config override, two
## hosts entries and one resource; every selected activity contributes at
## least one planned package; the provenance names `home.nim` among the
## compile's observed inputs with that file's digest.
##
## Falsifying mutation (performed when this gate was written): make the
## export ignore `--host` (select the OS hostname). The gate goes red at the
## `alpha` selection, which collapses to `default`.
##
## No mocks: real `build/bin/repro`, real Nim, real io-mon shim, real
## filesystem; the `nim` spy is a pass-through counter (harness header).

## Platforms: every host. The cache-answer checks accept, on macOS only, a
## complete re-run of an edge in place of a hit (milestone GM0m; harness
## header, `cacheAnswered`); the exported content is checked exactly
## everywhere.

import std/[algorithm, json, os, osproc, sets, strutils, unittest]

import blake3
import repro_profile
import repro_profile_intent
import repro_profile_compile
import repro_home_intent
import repro_home_apply
import repro_home_generations

import ./profile_compile_edge_harness

const ExportProfile = """
import repro_profile

profile "gm2Export":
  activity default:
    ripgrep

  activity alpha_tools:
    jq
    when linux:
      strace

  activity beta_tools:
    fd
    bat

  activity unused_tools:
    htop

  config:
    jq:
      color = true

  hosts:
    "alpha": [alpha_tools]
    "beta": [beta_tools, retired_tools]

  resources:
    fsUserFile(hostFile = "~/gm2-export-marker.txt",
      content = "exported\n")
"""

proc exportFor(sb: ProfileSandbox; args: openArray[string];
               envHost = ""): (ReproRun, JsonNode) =
  let run = sb.runRepro(@["home", "export"] & @args, host = envHost)
  checkpoint("repro home export " & args.join(" ") & " (REPRO_HOST=" &
    envHost & ") exit " & $run.exitCode & "\nstderr:\n" & run.stderr)
  var doc: JsonNode = nil
  if run.exitCode == 0:
    doc = parseJson(run.stdout)
  (run, doc)

proc strings(n: JsonNode): seq[string] =
  for item in n: result.add item.getStr

proc plannerActivities(intent: ProfileIntent; sb: ProfileSandbox;
                       host: string): seq[string] =
  ## The activities the planner's own `buildPlan` draws packages from for
  ## `host`, over the intent the plan compiled. Every activity in the
  ## fixture contributes an unguarded package, so this is the selection.
  let profile = profileIntentToHomeProfile(intent, sb.profilePath)
  var ctx = currentHostContext()
  ctx.host = host
  let plan = buildPlan(profile, sb.profileDir, ctx)
  var seen = initHashSet[string]()
  for p in plan.packages:
    seen.incl p.fromActivity
  for name in seen: result.add name
  result.sort()

proc sorted(xs: seq[string]): seq[string] =
  result = xs
  result.sort()

proc keysOf(n: JsonNode): seq[string] =
  ## An object's keys, sorted.
  for key in n.keys:
    result.add key
  result.sort()

suite "repro home export: compiled intent":

  test "e2e_home_export_matches_compiled_intent":
    let sb = newProfileSandbox("gm2-export", ExportProfile)
    defer: sb.dispose()

    # The planner's input, obtained independently: `repro home plan` for
    # host alpha compiles the profile and publishes the envelope it
    # consumed.
    let plan = sb.runHomePlan(host = "alpha")
    checkpoint("repro home plan output:\n" & plan.output)
    require plan.exitCode == 0
    check plan.nimSpawns >= 1
    check plan.createLines.len == 1
    let plannerIntent = plan.intent
    let plannerJson = parseJson(emitProfileIntentJson(plannerIntent))

    # Vacuity: the fixture is not trivially empty.
    check plannerIntent.activities.len == 4
    check plannerIntent.configOverrides.len == 1
    check plannerIntent.hosts.len == 2
    check plannerIntent.resources.len == 1

    # Everything an export may NOT touch, fingerprinted after the plan.
    let cacheDir = sb.stateDir / ProfileCacheDirName
    let stateBefore = treeFingerprint(sb.stateDir, [cacheDir])
    let storeBefore = treeFingerprint(sb.storeRoot)
    let homeBefore = treeFingerprint(sb.homeDir)
    let profileBefore = treeFingerprint(sb.profileDir)

    # --- host alpha, selected with --host ------------------------------
    let (alphaRun, alpha) = sb.exportFor(["--host", "alpha"])
    require alphaRun.exitCode == 0
    # Same compile edge, answered from the action cache the plan
    # populated: no `nim c` (on macOS, or a complete re-run: one `nim c`).
    # The other `nim` processes are the platform probe's (a separate edge the
    # plan does not run): one `nim dump` and one `nim check` per target
    # platform.
    const ProbeSpawns = 1 + ProfileTargetPlatforms.len
    check cacheAnswered(alphaRun.nimCompileSpawns, 1,
      "export after plan, compile edge")
    check alphaRun.nimSpawns - alphaRun.nimCompileSpawns == ProbeSpawns
    check alpha["format"].getStr == "repro.home.export"
    check alpha["schemaVersion"].getInt == 2
    check alpha["intent"] == plannerJson
    # The intent round-trips through the one ProfileIntent decoder.
    check emitProfileIntentJson(parseProfileIntentJson($alpha["intent"])) ==
      emitProfileIntentJson(plannerIntent)
    # The document's shape is the documented schema version 2
    # (docs/user-guide/home-export.md). `intent` is rendered by the shared
    # ProfileIntent encoder, so a change to that encoder would otherwise
    # change this published schema without anyone bumping `schemaVersion`
    # or the documentation; these key sets are the tripwire. An added
    # field is compatible (document it and extend the set); a renamed or
    # reshaped one also bumps `HomeExportSchemaVersion`.
    check keysOf(alpha) == sorted(@["format", "schemaVersion", "selection",
      "intent", "platforms", "provenance"])
    # Every target platform has a status; this profile selects platforms
    # with runtime predicates only, so the document describes all of them.
    check keysOf(alpha["platforms"]) == sorted(targetSystemNames())
    for system, status in alpha["platforms"]:
      checkpoint(system & ": " & $status)
      check status.getStr == "same"
    check keysOf(alpha["selection"]) == sorted(@["host", "hostDeclared",
      "activities", "unknownActivities"])
    check keysOf(alpha["intent"]) == sorted(@["name", "activities",
      "configOverrides", "hosts", "resources", "buildActions",
      "adapterPreference"])
    check keysOf(alpha["provenance"]) == sorted(@["repro", "hostSource",
      "profile", "dataFiles", "compile"])
    check keysOf(alpha["provenance"]["repro"]) ==
      @["sourceRevision", "version"]
    check keysOf(alpha["provenance"]["profile"]) ==
      @["digest", "inputs", "root"]
    check keysOf(alpha["provenance"]["compile"]) ==
      @["cpu", "defines", "os", "probe", "target"]
    check alpha["provenance"]["compile"]["probe"].len == 0
    var elementShapes: seq[string]
    for activity in alpha["intent"]["activities"]:
      check keysOf(activity) == @["body", "name"]
      for element in activity["body"]:
        elementShapes.add element["kind"].getStr & ":" &
          keysOf(element).join(",")
    check "packageRef:kind,name,version" in elementShapes
    check "whenGuard:body,kind,predicate" in elementShapes
    for shape in elementShapes:
      check shape in ["packageRef:kind,name,version",
        "packageRef:binaries,kind,name,version",
        "whenGuard:body,kind,predicate"]
    for override in alpha["intent"]["configOverrides"]:
      check keysOf(override) == @["guard", "key", "pkg", "value"]
      check override["guard"].kind == JNull
    for resource in alpha["intent"]["resources"]:
      check keysOf(resource) ==
        @["address", "dependsOn", "fields", "guard", "kind"]
      check resource["guard"].kind == JNull
      for _, field in resource["fields"]:
        check keysOf(field) == @["kind", "value"]

    let alphaSel = alpha["selection"]
    check alphaSel["host"].getStr == "alpha"
    check alphaSel["hostDeclared"].getBool
    check strings(alphaSel["activities"]) == @["default", "alpha_tools"]
    check strings(alphaSel["unknownActivities"]).len == 0
    check sorted(strings(alphaSel["activities"])) ==
      plannerActivities(plannerIntent, sb, "alpha")
    check alpha["provenance"]["hostSource"].getStr == "flag"

    # Provenance.
    let prov = alpha["provenance"]
    check prov["repro"]["version"].getStr.len > 0
    let versionOut = execProcess(reproBinary(), args = ["--version"],
      options = {})
    check versionOut.contains(prov["repro"]["version"].getStr)
    check prov["repro"]["sourceRevision"].kind == JString
    checkpoint("sourceRevision: " & $prov["repro"]["sourceRevision"])
    check prov["profile"]["root"].getStr == "home.nim"
    check prov["profile"]["digest"].kind == JString
    var homeNimDigest = ""
    for input in prov["profile"]["inputs"]:
      if input["path"].getStr == "home.nim":
        homeNimDigest = input["blake3"].getStr
    check homeNimDigest ==
      blake3.toHex(blake3.digest(readFile(sb.profilePath)))
    check prov["dataFiles"].len == 0
    check prov["compile"]["os"].getStr == hostOS
    check prov["compile"]["cpu"].getStr == hostCPU
    check prov["compile"]["target"].getStr == compilingPlatformSystem()
    check prov["compile"]["defines"].kind == JArray

    # --- host beta: a different selection, the same intent ------------
    let (betaRun, beta) = sb.exportFor(["--host=beta"])
    require betaRun.exitCode == 0
    # Both edges -- compile and platform probe -- answered from the cache.
    check cacheAnswered(betaRun.nimCompileSpawns, 1,
      "second export, compile edge")
    check cacheAnswered(betaRun.nimSpawns - betaRun.nimCompileSpawns,
      ProbeSpawns, "second export, platform probe edge")
    check beta["platforms"] == alpha["platforms"]
    check beta["intent"] == plannerJson
    check strings(beta["selection"]["activities"]) ==
      @["default", "beta_tools"]
    check strings(beta["selection"]["unknownActivities"]) ==
      @["retired_tools"]
    check sorted(strings(beta["selection"]["activities"])) ==
      plannerActivities(plannerIntent, sb, "beta")

    # --- an undeclared host gets `default` only ------------------------
    let (nobodyRun, nobody) = sb.exportFor(["--host", "nobody"])
    require nobodyRun.exitCode == 0
    check not nobody["selection"]["hostDeclared"].getBool
    check strings(nobody["selection"]["activities"]) == @["default"]
    check plannerActivities(plannerIntent, sb, "nobody") == @["default"]

    # --- $REPRO_HOST selects exactly like --host -----------------------
    let (envRun, viaEnv) = sb.exportFor(newSeq[string](), envHost = "beta")
    require envRun.exitCode == 0
    check viaEnv["selection"] == beta["selection"]
    check viaEnv["intent"] == beta["intent"]
    check viaEnv["provenance"]["hostSource"].getStr == "env"

    # A --host that $REPRO_HOST would override is refused, not ignored.
    let (conflict, _) = sb.exportFor(["--host", "alpha"], envHost = "beta")
    check conflict.exitCode == 2
    check conflict.stderr.contains("conflicts with $REPRO_HOST")
    check conflict.stdout.len == 0

    # Usage errors.
    let (badFormat, _) = sb.exportFor(["--format", "yaml"])
    check badFormat.exitCode == 2

    # --- --profile-dir selects the profile, over $REPRO_HOME_PROFILE_DIR -
    # (which the sandbox points at the fixture above).
    let otherDir = sb.root / "other-profile"
    createDir(otherDir)
    writeFile(otherDir / "home.nim", """
import repro_profile

profile "gm2Other":
  activity default:
    tree
""")
    let (otherRun, other) = sb.exportFor(["--profile-dir", otherDir,
      "--host", "alpha"])
    require otherRun.exitCode == 0
    check other["intent"]["name"].getStr == "gm2Other"
    check strings(other["selection"]["activities"]) == @["default"]
    check not other["selection"]["hostDeclared"].getBool
    check other["provenance"]["profile"]["inputs"][0]["blake3"].getStr ==
      blake3.toHex(blake3.digest(readFile(otherDir / "home.nim")))

    # --- no plan or apply side effects ---------------------------------
    check treeFingerprint(sb.stateDir, [cacheDir]) == stateBefore
    check treeFingerprint(sb.storeRoot) == storeBefore
    check treeFingerprint(sb.homeDir) == homeBefore
    check treeFingerprint(sb.profileDir) == profileBefore
    check not fileExists(sb.homeDir / "gm2-export-marker.txt")
    var generations: seq[string]
    for kind, path in walkDir(sb.stateDir):
      if path.extractFilename.toLowerAscii.contains("generation"):
        generations.add path
    checkpoint("state dir entries named like generations: " &
      generations.join(", "))
    check generations.len == 0
    check readCurrentGenerationId(sb.stateDir).len == 0

  test "the data-file fields are the documented schema":
    let sb = newProfileSandbox("gm2-export-data", """
import repro_profile

profile "gm2ExportData":
  data:
    "data/apps.toml"

  activity default:
    ripgrep
""")
    defer: sb.dispose()
    sb.writeProfileFile("data/apps.toml", """
[[package]]
name = "jq"
activity = "default"

[[package]]
name = "ghostty"
activity = "desktop"
when = "macos"
binaries = ["ghostty"]

[[resource]]
kind = "fs.userFile"
when = "linux"
hostFile = "~/gm2-data.conf"
content = "x\n"
""")
    let (run, doc) = sb.exportFor(["--host", "alpha"])
    require run.exitCode == 0
    check doc["schemaVersion"].getInt == 2
    check keysOf(doc["intent"]) == sorted(@["name", "activities",
      "configOverrides", "hosts", "resources", "buildActions",
      "adapterPreference"])
    let files = doc["provenance"]["dataFiles"]
    require files.len == 1
    check keysOf(files[0]) == @["blake3", "path", "rows"]
    check files[0]["path"].getStr == "data/apps.toml"
    check files[0]["rows"].getInt == 3
    # A resource row is an entry of the existing shape, its `when` the guard.
    require doc["intent"]["resources"].len == 1
    let resource = doc["intent"]["resources"][0]
    check keysOf(resource) ==
      @["address", "dependsOn", "fields", "guard", "kind"]
    check resource["guard"].getStr == "linux"
    for _, field in resource["fields"]:
      check keysOf(field) == @["kind", "value"]
    var shapes: seq[string]
    for activity in doc["intent"]["activities"]:
      check keysOf(activity) == @["body", "name"]
      for element in activity["body"]:
        shapes.add element["kind"].getStr & ":" & keysOf(element).join(",")
    check shapes == @["packageRef:kind,name,version",
      "packageRef:kind,name,version", "whenGuard:body,kind,predicate"]
