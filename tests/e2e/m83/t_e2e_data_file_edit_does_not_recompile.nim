## GM4 gate `e2e_data_file_edit_does_not_recompile`: a profile's plan-time
## data file (`data:` section, `data/apps.toml`) is read by the PLANNER, not
## compiled into the profile binary, so editing it changes the plan while the
## profile-compile edge is answered from the action cache.
##
## 1. A profile declares `data/apps.toml` with one row; `repro home apply
##    --plan` (the real apply's planner, non-mutating) plans the row's package
##    and the compile edge runs (`nim c` spawned).
## 2. A row is appended to the data file. The next `--plan` plans the new
##    package — the plan diff names it (VACUITY GUARD: the edit is visible in
##    what was planned, so the hit is not a hit on a plan that ignored it) —
##    and the compile edge spawns NO `nim` (action-cache hit; macOS may fail
##    closed per GM0m, see the harness).
## 3. The compile edge never observed the data file: `repro home export`
##    reports the edge's observed profile inputs (`provenance.profile.inputs`)
##    without `data/apps.toml`, and lists it under `provenance.dataFiles`
##    with the BLAKE3 of the bytes the planner expanded.
##
## FALSIFYING MUTATION (performed when this gate was written, see the
## milestone file): make the `profile` macro read each declared data file
## with `staticRead` (`parseDataSection` in
## `libs/repro_profile/src/repro_profile/macros.nim`). The compile then
## depends on the file, io-mon observes the read, and step 2 goes red: the
## edge re-runs (`nim c` spawned) and `provenance.profile.inputs` names
## `data/apps.toml`.
##
## No mocks: the real `build/bin/repro`, real Nim, the real io-mon shim, the
## real filesystem. Packages are bound to fixture executables through the
## documented `REPRO_TEST_PACKAGE_SOURCE` seam so the plan resolves them
## without network access; the resolution itself is the real one. The `nim`
## spy is a pass-through counter (harness header).
##
## Platforms: every host. The rows are platform-neutral (`host ==` guards
## only), and the cache answer follows the harness's per-platform rule.

import std/[json, os, sequtils, sets, strutils, unittest]

import blake3

import ./profile_compile_edge_harness

const ProfileText = """
import repro_profile

profile "gm4DataEdit":
  data:
    "data/apps.toml"

  activity default:
    `gm4-base`

  hosts:
    "gm4-host": [tools]
"""

const AppsV1 = """
# Applications by canonical package name (GM4 gate fixture).
[[package]]
name = "gm4-alpha"
activity = "tools"
"""

const AppsAddedRow = """

[[package]]
name = "gm4-beta"
activity = "tools"
when = "host == \"gm4-host\""
"""

proc packageLines(output: string): seq[string] =
  ## The `[package]` lines of a `repro home apply --plan` preview.
  var inPackages = false
  for line in output.splitLines():
    let s = line.strip()
    if s.startsWith("["):
      inPackages = s == "[package]"
      continue
    if inPackages and s.len > 0:
      result.add s

suite "GM4: plan-time data files":

  test "e2e_data_file_edit_does_not_recompile":
    let sb = newProfileSandbox("gm4-data-edit", ProfileText)
    defer: sb.dispose()
    sb.writeProfileFile("data/apps.toml", AppsV1)
    let env = sb.fixturePackageEnv(["gm4-base", "gm4-alpha", "gm4-beta"])

    # 1. First plan: the compile edge runs, the row is planned.
    let first = sb.runRepro(["home", "apply", "--plan"], host = "gm4-host",
      extraEnv = env)
    checkpoint("first --plan:\n" & first.stdout & first.stderr)
    require first.exitCode == 0
    check first.nimCompileSpawns >= 1
    let before = packageLines(first.stdout)
    check before.anyIt(it.contains("gm4-alpha"))
    check before.anyIt(it.contains("gm4-base"))
    check not before.anyIt(it.contains("gm4-beta"))

    # 2. Edit the data file only: a new row.
    sb.writeProfileFile("data/apps.toml", AppsV1 & AppsAddedRow)
    let second = sb.runRepro(["home", "apply", "--plan"], host = "gm4-host",
      extraEnv = env)
    checkpoint("second --plan:\n" & second.stdout & second.stderr)
    require second.exitCode == 0
    let after = packageLines(second.stdout)
    # Vacuity guard: the plan diff names the added row.
    var added: seq[string]
    for line in after:
      if line notin before:
        added.add line
    checkpoint("plan diff: " & $added)
    check added.len == 1
    check added.len > 0 and added[0].contains("gm4-beta")
    # The edit changed the generation the plan would produce.
    check first.stdout != second.stdout
    # The compile edge was answered from the action cache.
    check cacheAnswered(second.nimCompileSpawns, first.nimCompileSpawns,
      "data-file edit")

    # 3. The compile edge never observed the data file; the export records
    #    it as a data file with the digest of the bytes expanded.
    let exported = sb.runRepro(["home", "export", "--format", "json"],
      host = "gm4-host", extraEnv = env)
    checkpoint("export stderr:\n" & exported.stderr)
    require exported.exitCode == 0
    check cacheAnswered(exported.nimCompileSpawns, first.nimCompileSpawns,
      "export after the data edit")
    let doc = parseJson(exported.stdout)
    var observed = initHashSet[string]()
    for input in doc["provenance"]["profile"]["inputs"]:
      observed.incl input["path"].getStr
    check "home.nim" in observed
    check "data/apps.toml" notin observed
    let dataFiles = doc["provenance"]["dataFiles"]
    require dataFiles.len == 1
    check dataFiles[0]["path"].getStr == "data/apps.toml"
    check dataFiles[0]["blake3"].getStr ==
      blake3.toHex(blake3.digest(AppsV1 & AppsAddedRow))
    check dataFiles[0]["rows"].getInt == 2
