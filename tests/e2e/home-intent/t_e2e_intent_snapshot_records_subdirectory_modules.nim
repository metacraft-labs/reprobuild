## A home generation's intent snapshot records the modules the profile
## imports from subdirectories (reprobuild-pm issue
## 2026-10-18-home-intent-snapshot-omits-imported-modules-in-subdirectories;
## Home-Profile-Generations-And-State.md §Intent Snapshot: "the resolved
## intent files (`home.nim` + any sibling files imported, with their actual
## byte contents)"; Profile-Migration-Patterns.md, the helper-module layout).
##
## Before the fix the snapshot was every `*.nim` directly under the profile
## directory, so `modules/gnm_tools.nim` -- imported by `home.nim` -- was not
## in it: the generation could not be compiled from its own snapshot, and
## `repro home get`, which compiles the on-disk profile only while the
## snapshot's files equal the on-disk ones, answered with an unapplied value
## after an edit to the module alone.
##
## Through the real `build/bin/repro`, on a profile composed the way
## zah/dotfiles' home.nim is (helpers imported from `./modules/...`, one of
## them called in `config:`):
##
## * `e2e_snapshot_holds_the_imported_subdirectory_module`: after `repro home
##   apply` the current generation's snapshot (read from the sandbox's CAS)
##   holds `home.nim` AND `modules/gnm_tools.nim`, each byte for byte, and
##   not `notes/unused.nim`, a subdirectory file nothing imports (the
##   snapshot is the compile's source closure, not a recursive walk). The
##   snapshot is self-contained: a fresh profile directory holding only its
##   files compiles, and `repro home get` there answers the generation's
##   value. Negative control for the byte-compatibility promise: a profile
##   that imports nothing from a subdirectory snapshots exactly
##   `defaultWalkProfileFiles` of its directory (its snapshot bytes and
##   generation ids are unchanged by the fix).
## * `e2e_get_refuses_after_an_unapplied_edit_to_a_module`: edit only
##   `modules/gnm_tools.nim` (the helper now assigns another value) and do
##   not apply: `repro home get` refuses ("differs from the one on disk")
##   instead of printing the unapplied value; after `repro home apply` it
##   prints the new value, and the generation id moved.
##
## Falsifying mutations (performed; see the issue's Resolution): with
## `profileIntentSnapshot` back on `defaultWalkProfileFiles` alone, both
## cases go red (the module is missing from the snapshot; `get` prints the
## edited module's value); with `snapshotMatchesProfileDir` back on the
## top-level walk comparison, the second goes red.
##
## No mocks: the real binary, profile compile edge, apply pipeline and CAS
## in the harness's isolated sandbox (HOME, state and store); packages are
## bound to fixture executables through `REPRO_TEST_PACKAGE_SOURCE`
## (`fixturePackageEnv`). Platforms: every host.

import std/[os, strutils, unittest]
from repro_core/paths import extendedPath

import repro_home_generations
import repro_local_store

import ../m83/profile_compile_edge_harness

const Tools = """
import repro_profile

proc baseTools*(): seq[ActivityElement] =
  @[package "gnm-helper-base"]

template gnmIdentity*(targetOverrides: var seq[ConfigOverride];
                      name: string) =
  targetOverrides.add ConfigOverride(pkg: "git", key: "userName",
    value: strValue(name))
"""

const ConfigHelper = """
import repro_profile
import ./modules/gnm_tools

profile "probe":
  activity default:
    ripgrep
    baseTools()

  config:
    git:
      userName = "Probe"
    gnmIdentity(name = "From Helper")
"""

const NoImports = """
import repro_profile

profile "probe":
  activity default:
    ripgrep

  config:
    git:
      userName = "Probe"
"""

const Unused = "# nothing imports this file\n"

proc show(label: string; r: ReproRun) =
  checkpoint label & " (exit " & $r.exitCode & ")\n--- stdout\n" & r.stdout &
    "\n--- stderr\n" & r.stderr

proc sandbox(label, text: string): ProfileSandbox =
  result = newProfileSandbox(label, text)
  result.writeProfileFile("modules/gnm_tools.nim", Tools)
  result.writeProfileFile("notes/unused.nim", Unused)

proc currentSnapshot(sb: ProfileSandbox): IntentSnapshot =
  ## The current generation's intent snapshot, read from the sandbox's CAS.
  let id = readCurrentGenerationId(sb.stateDir)
  doAssert id.len > 0, "no current generation"
  let env = readPointerFile(pointerPath(sb.stateDir, id))
  var key: PrefixIdBytes
  for i in 0 ..< 32:
    key[i] = env.intentSnapshotDigest[i]
  var store = openStore(sb.storeRoot)
  defer: store.close()
  decodeSnapshotBytes(readCasBlob(store, key))

proc text(e: IntentFileEntry): string =
  result = newString(e.content.len)
  for i, b in e.content:
    result[i] = char(b)

proc sourcePaths(s: IntentSnapshot): seq[string] =
  for e in s.files:
    if e.role == ifrSource:
      result.add e.path

suite "a home generation's intent snapshot records subdirectory modules":

  test "e2e_snapshot_holds_the_imported_subdirectory_module":
    let sb = sandbox("gnm-snap-modules", ConfigHelper)
    defer: sb.dispose()
    let env = sb.fixturePackageEnv(["ripgrep", "gnm-helper-base"])
    let applied = sb.runRepro(["home", "apply"], extraEnv = env)
    show("apply", applied)
    require applied.exitCode == 0
    let snap = sb.currentSnapshot()
    checkpoint("snapshot source files: " & $snap.sourcePaths)
    check snap.sourcePaths == @["home.nim", "modules/gnm_tools.nim"]
    for e in snap.files:
      if e.path == "home.nim":
        check e.text == ConfigHelper
      elif e.path == "modules/gnm_tools.nim":
        check e.text == Tools

    # Self-contained: a profile directory holding only the snapshot's files
    # compiles, and answers the generation's value.
    var homeText = ""
    for e in snap.files:
      if e.path == "home.nim":
        homeText = e.text
    let fromSnap = newProfileSandbox("gnm-snap-replay", homeText)
    defer: fromSnap.dispose()
    for e in snap.files:
      if e.path != "home.nim":
        fromSnap.writeProfileFile(e.path, e.text)
    let replayed = fromSnap.runRepro(["home", "get", "git.userName"])
    show("get from the snapshot's files", replayed)
    check replayed.exitCode == 0
    check replayed.stdout.strip() == "From Helper"

    # Negative control: nothing imported from a subdirectory -> exactly the
    # top-level walk, as before the fix.
    let plain = sandbox("gnm-snap-plain", NoImports)
    defer: plain.dispose()
    let plainApplied = plain.runRepro(["home", "apply"],
      extraEnv = plain.fixturePackageEnv(["ripgrep"]))
    show("apply (no imports)", plainApplied)
    require plainApplied.exitCode == 0
    let plainSnap = plain.currentSnapshot()
    var walked: seq[string]
    for e in defaultWalkProfileFiles(plain.profileDir):
      walked.add e.path
    check plainSnap.sourcePaths == walked
    check plainSnap.sourcePaths == @["home.nim"]

  test "e2e_get_refuses_after_an_unapplied_edit_to_a_module":
    let sb = sandbox("gnm-snap-get", ConfigHelper)
    defer: sb.dispose()
    let env = sb.fixturePackageEnv(["ripgrep", "gnm-helper-base"])
    let applied = sb.runRepro(["home", "apply"], extraEnv = env)
    show("apply", applied)
    require applied.exitCode == 0
    let firstGen = readCurrentGenerationId(sb.stateDir)
    let got = sb.runRepro(["home", "get", "git.userName"])
    show("get (applied)", got)
    check got.exitCode == 0
    check got.stdout.strip() == "From Helper"

    # Edit only the module; home.nim is untouched.
    sb.writeProfileFile("modules/gnm_tools.nim",
      Tools.replace("strValue(name)", "strValue(name & \" via module\")"))
    let stale = sb.runRepro(["home", "get", "git.userName"])
    show("get (module edited, not applied)", stale)
    check stale.exitCode == 1
    check stale.stdout.strip() == ""
    check "via module" notin stale.stdout
    check stale.stderr.contains("differs from the one on disk")

    let reapplied = sb.runRepro(["home", "apply"], extraEnv = env)
    show("apply (module edited)", reapplied)
    require reapplied.exitCode == 0
    check readCurrentGenerationId(sb.stateDir) != firstGen
    let fresh = sb.runRepro(["home", "get", "git.userName"])
    show("get (after second apply)", fresh)
    check fresh.exitCode == 0
    check fresh.stdout.strip() == "From Helper via module"
