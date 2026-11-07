## GM4 gate `e2e_data_file_rollback_restores_rows`: a generation records
## the plan-time data it was planned from, so rolling back to it restores
## that data's expansion WITHOUT the data file being reverted.
##
## Everything is applied into the sandbox's isolated `HOME`, state directory
## and store (`profile_compile_edge_harness`); this machine's real home is
## never touched.
##
## 1. Apply with `data/apps.toml` holding one row (`gm4-alpha`): generation
##    A; `gm4-alpha`'s launcher is live, `gm4-beta`'s is not; `repro home
##    history` reports A's data file with the BLAKE3 of those bytes.
## 2. Append a `gm4-beta` package row and an `fs.userFile` resource row and
##    apply again: generation B (≠ A); both launchers live and the resource's
##    file written in the sandbox HOME; history reports B's data digest.
## 3. `repro home rollback`: current is A again, `gm4-beta`'s launcher and
##    the resource's file are gone and `gm4-alpha`'s launcher is live — while
##    `data/apps.toml` on disk is not A's: it is replaced, before the
##    rollback, by a file the planner refuses (a row without `activity`), so
##    a rollback that consulted the live file could not succeed. A's
##    recorded data (its intent snapshot, read back from the store) is
##    exactly the one-row file, and history still reports A's digest.
## 4. Negative control: with B's bytes put back, a `repro home apply --plan`
##    plans B's generation and `gm4-beta` again — the live file did not
##    decide what the rollback restored.
##
## Falsifying mutations (performed when this gate was written, see the
## milestone file): (a) leaving the data files out of the intent snapshot
## (`profileIntentSnapshot` in `repro_home_apply/pipeline.nim` without the
## `loadedDataFiles` loop) — red at the history digests and A's recorded
## data (the launcher checks stay green: rollback replays activation
## manifests); (b) not expanding the data (the compile-then-adapt path
## calling `profileIntentToHomeProfile` directly) — red at step 1, no
## `gm4-alpha` launcher, and A and B are the same generation.
##
## No mocks: the real `build/bin/repro` (apply, history, rollback), real Nim,
## the real store. Packages are bound to fixture executables through the
## documented `REPRO_TEST_PACKAGE_SOURCE` seam; their realization into the
## store and the launchers are the real ones.
##
## Platforms: every host (launchers are checked in the generation's `bin/`
## on POSIX and in the stable bin directory on Windows, as the M64 rollback
## gate does).

import std/[os, sequtils, strutils, unittest]

import blake3
import repro_home_generations
import repro_home_intent
import repro_local_store

import ./profile_compile_edge_harness

const ProfileText = """
import repro_profile

profile "gm4DataRollback":
  data:
    "data/apps.toml"

  activity default:
    `gm4-base`

  hosts:
    "gm4-host": [tools]
"""

const AppsA = """
# One row: generation A.
[[package]]
name = "gm4-alpha"
activity = "tools"
"""

const AppsB = AppsA & """

[[package]]
name = "gm4-beta"
activity = "tools"

[[resource]]
kind = "fs.userFile"
hostFile = "~/gm4-data-marker.txt"
content = "from a data row\n"
"""

proc launcherPresent(sb: ProfileSandbox; command: string): bool =
  when defined(windows):
    let stable = sb.stateDir / "bin"
    fileExists(stable / (command & ".exe")) or
      fileExists(stable / (command & ".cmd"))
  else:
    let active = readCurrentGenerationId(sb.stateDir)
    if active.len == 0: return false
    fileExists(generationDir(sb.stateDir, active) / "bin" / command)

proc recordedData(sb: ProfileSandbox; generation: string): seq[IntentFileEntry] =
  ## The data files generation `generation` recorded, read back from its
  ## intent snapshot in the store.
  let env = readPointerFile(pointerPath(sb.stateDir, generation))
  var key: PrefixIdBytes
  for i in 0 ..< 32:
    key[i] = env.intentSnapshotDigest[i]
  var store = openStore(sb.storeRoot)
  defer: store.close()
  for entry in decodeSnapshotBytes(readCasBlob(store, key)).files:
    if entry.role == ifrData:
      result.add entry

proc text(bytes: seq[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes: result[i] = char(b)

proc historyDigestFor(history, generation: string): string =
  ## The `data data/apps.toml blake3=<hex>` line under `generation`'s entry.
  var inEntry = false
  for line in history.splitLines():
    let s = line.strip()
    if s.startsWith(generation[0 ..< 12]):
      inEntry = true
      continue
    if inEntry:
      if s.startsWith("data data/apps.toml blake3="):
        return s["data data/apps.toml blake3=".len .. ^1]
      if not s.startsWith("data "):
        inEntry = false
  ""

suite "GM4: plan-time data files and generations":

  test "e2e_data_file_rollback_restores_rows":
    let sb = newProfileSandbox("gm4-data-rollback", ProfileText)
    defer: sb.dispose()
    let env = sb.fixturePackageEnv(["gm4-base", "gm4-alpha", "gm4-beta"])
    let digestA = blake3.toHex(blake3.digest(AppsA))
    let digestB = blake3.toHex(blake3.digest(AppsB))

    # 1. Generation A.
    sb.writeProfileFile("data/apps.toml", AppsA)
    let applyA = sb.runRepro(["home", "apply"], host = "gm4-host",
      extraEnv = env)
    checkpoint("apply A:\n" & applyA.stdout & applyA.stderr)
    require applyA.exitCode == 0
    let genA = readCurrentGenerationId(sb.stateDir)
    require genA.len > 0
    check sb.launcherPresent("gm4-base")
    check sb.launcherPresent("gm4-alpha")
    check not sb.launcherPresent("gm4-beta")
    let historyA = sb.runRepro(["home", "history"], host = "gm4-host",
      extraEnv = env)
    checkpoint("history after A:\n" & historyA.stdout)
    check historyDigestFor(historyA.stdout, genA) == digestA

    # 2. Generation B: the data file only gains a row.
    sb.writeProfileFile("data/apps.toml", AppsB)
    let applyB = sb.runRepro(["home", "apply"], host = "gm4-host",
      extraEnv = env)
    checkpoint("apply B:\n" & applyB.stdout & applyB.stderr)
    require applyB.exitCode == 0
    let genB = readCurrentGenerationId(sb.stateDir)
    check genB.len > 0
    check genB != genA
    check sb.launcherPresent("gm4-alpha")
    check sb.launcherPresent("gm4-beta")
    let marker = sb.homeDir / "gm4-data-marker.txt"
    check fileExists(marker) and readFile(marker) == "from a data row\n"
    let historyB = sb.runRepro(["home", "history"], host = "gm4-host",
      extraEnv = env)
    checkpoint("history after B:\n" & historyB.stdout)
    check historyDigestFor(historyB.stdout, genB) == digestB
    check historyDigestFor(historyB.stdout, genA) == digestA

    # 3. Roll back to A; the data file is NOT reverted. To show the rollback
    #    does not read the live file at all, it is made unreadable to the
    #    planner first (a row without its required `activity`): a rollback
    #    that re-planned from it would fail, not restore A.
    const Unplannable = "[[package]]\nname = \"gm4-alpha\"\n"
    sb.writeProfileFile("data/apps.toml", Unplannable)
    let refusedPlan = sb.runRepro(["home", "apply", "--plan"],
      host = "gm4-host", extraEnv = env)
    check refusedPlan.exitCode == 1
    check refusedPlan.stderr.contains("required key missing")
    let rollback = sb.runRepro(["home", "rollback"], host = "gm4-host",
      extraEnv = env)
    checkpoint("rollback:\n" & rollback.stdout & rollback.stderr)
    require rollback.exitCode == 0
    check rollback.stdout.contains("rolled back from " & genB & " to " & genA)
    check readCurrentGenerationId(sb.stateDir) == genA
    check readFile(sb.profileDir / "data" / "apps.toml") == Unplannable
    check sb.launcherPresent("gm4-base")
    check sb.launcherPresent("gm4-alpha")
    check not sb.launcherPresent("gm4-beta")
    check not fileExists(marker)
    # A's recorded data is the one-row file, exactly.
    let recorded = sb.recordedData(genA)
    require recorded.len == 1
    check recorded[0].path == "data/apps.toml"
    check text(recorded[0].content) == AppsA
    let rows = parseDataFileText("", "data/apps.toml",
      text(recorded[0].content))
    check rows.mapIt(it.name) == @["gm4-alpha"]
    let historyAfter = sb.runRepro(["home", "history"], host = "gm4-host",
      extraEnv = env)
    checkpoint("history after rollback:\n" & historyAfter.stdout)
    check historyDigestFor(historyAfter.stdout, genA) == digestA

    # 4. Negative control: with B's bytes back in the live file, a plan from
    #    it would bring gm4-beta back.
    sb.writeProfileFile("data/apps.toml", AppsB)
    let replan = sb.runRepro(["home", "apply", "--plan"], host = "gm4-host",
      extraEnv = env)
    checkpoint("re-plan:\n" & replan.stdout & replan.stderr)
    require replan.exitCode == 0
    check replan.stdout.contains(genB)
    check replan.stdout.contains("gm4-beta")
