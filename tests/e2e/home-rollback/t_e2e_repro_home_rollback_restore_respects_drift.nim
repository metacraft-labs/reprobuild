## `e2e_repro_home_rollback_restore_respects_drift`.
##
## A rollback RESTORE -- a file, managed block or resource the target
## generation recorded and the current one does not -- obeys the lifecycle's
## drift rule like every other rollback write (Home-Profile-Resource-
## Lifecycle.md §Drift Handling; reprobuild-pm issue
## 2026-10-16-home-rollback-restore-replaces-an-object-the-current-generation-does-not-own):
## it runs when the live object is absent or already holds the target's
## recorded content, and is refused as a user edit otherwise, unless
## `--accept-overwrite` is passed. No generation of the current state records
## the object, so whatever sits there now was put there by someone else.
##
##   1. Apply A (a generated `~/.fooconfig`, a managed block in `~/.bashrc`,
##      an `fs.userFile` `~/.restore-marker`), then B, which has none of the
##      three: B's apply removes them.
##   2. The user puts their own `~/.fooconfig` back. `repro home rollback`
##      (to A) exits non-zero naming it, and changes nothing -- the user's
##      file, the current generation. The same for a re-created block and a
##      re-created `~/.restore-marker`, one at a time.
##   3. Positive controls: with each object holding exactly what A recorded,
##      or absent, the rollback runs without `--accept-overwrite`.
##   4. `--accept-overwrite` replaces a foreign object with A's content.
##
## Before the fix every refusal case below restored over the user's object
## and exited 0 (the drift pass skipped restores).
##
## Real `build/bin/repro`, real profile compile, real filesystem. The package
## seams (`REPRO_TEST_PACKAGE_SOURCE` / `_GENERATES` / `_MANAGED_BLOCKS`) are
## the ones the M64 rollback gates use; they stand in for package
## realization, which this test is not about.

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_home_generations

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir().parentDir()

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  result = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(result),
    "repro binary not found at " & result & "; build with `just build` first"

proc writeFixtureExe(path: string) =
  when defined(windows):
    writeFile(path, "@echo off\r\nexit /b 0\r\n")
  else:
    writeFile(path, "#!/bin/sh\nexit 0\n")
    setFilePermissions(path, {fpUserExec, fpUserWrite, fpUserRead})

const
  ConfigA = "[foo]\nfrom=a"
  BlockA = "export FOO=a"
  BlockId = "repro.restore"
  MarkerA = "from-a\n"
  Foreign = "the user's own content\n"

  ProfileA = """
import repro_profile

profile "rollback-restore-a":
  activity default:
    `pkg-x`
    `pkg-y`

  resources:
    fsUserFile(hostFile = "~/.restore-marker", content = "from-a\n")
"""
  ProfileB = """
import repro_profile

profile "rollback-restore-b":
  activity default:
    `pkg-x`
    `pkg-z`
"""

type Sandbox = object
  root, stateDir, storeRoot, profileDir, homeDir: string
  sources: string

proc newSandbox(label: string): Sandbox =
  result.root = createTempDir("repro-rollback-restore-" & label & "-", "")
  result.stateDir = result.root / "state"
  result.storeRoot = result.root / "store"
  result.profileDir = result.root / "profile"
  result.homeDir = result.root / "home"
  for d in [result.stateDir, result.storeRoot, result.profileDir,
            result.homeDir, result.root / "fixtures"]:
    createDir(d)
  let ext = when defined(windows): ".cmd" else: ""
  var pairs: seq[string]
  for name in ["pkg-x", "pkg-y", "pkg-z"]:
    let exe = result.root / "fixtures" / (name & ext)
    writeFixtureExe(exe)
    pairs.add name & "=" & exe
  result.sources = pairs.join(";")

proc run(sb: Sandbox; generates, blocks: string;
         args: openArray[string]): tuple[exitCode: int; output: string] =
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env["REPRO_HOME_PROFILE_DIR"] = sb.profileDir
  env["REPRO_HOME_STATE_DIR"] = sb.stateDir
  env["REPRO_STORE_ROOT"] = sb.storeRoot
  env["HOME"] = sb.homeDir
  env["USERPROFILE"] = sb.homeDir
  env["REPRO_HOST"] = "rollback-restore-host"
  env["REPRO_TEST_PACKAGE_SOURCE"] = sb.sources
  env["REPRO_HOME_PACKAGE_CATALOG"] = "pkg-x,pkg-y,pkg-z"
  env["REPRO_TEST_PACKAGE_GENERATES"] = generates
  env["REPRO_TEST_PACKAGE_MANAGED_BLOCKS"] = blocks
  let p = startProcess(reproBinary(), args = @args, env = env,
    options = {poUsePath, poStdErrToStdOut})
  let output = p.outputStream().readAll()
  let code = p.waitForExit()
  p.close()
  (exitCode: code, output: output)

proc applyA(sb: Sandbox): tuple[exitCode: int; output: string] =
  writeFile(sb.profileDir / "home.nim", ProfileA)
  sb.run("pkg-x=.fooconfig:" & ConfigA,
    "pkg-y=.bashrc#" & BlockId & ":" & BlockA, ["home", "apply"])

proc applyB(sb: Sandbox): tuple[exitCode: int; output: string] =
  writeFile(sb.profileDir / "home.nim", ProfileB)
  sb.run("pkg-x=.barconfig:[bar]\nfrom=b", "pkg-z=.bashrc#repro.other:x=b",
    ["home", "apply"])

proc rollback(sb: Sandbox; accept = false):
    tuple[exitCode: int; output: string] =
  # The seams are B's: rollback reads the generations, not the profile.
  var args = @["home", "rollback"]
  if accept:
    args.add "--accept-overwrite"
  sb.run("pkg-x=.barconfig:[bar]\nfrom=b", "pkg-z=.bashrc#repro.other:x=b",
    args)

type Generations = tuple[a, b, bashrcA: string]

proc twoGenerations(sb: Sandbox): Generations =
  ## Apply A then B; returns both ids and `~/.bashrc` as A left it.
  let ra = sb.applyA()
  doAssert ra.exitCode == 0, ra.output
  result.a = readCurrentGenerationId(sb.stateDir)
  result.bashrcA = readFile(sb.homeDir / ".bashrc")
  doAssert BlockA in result.bashrcA
  doAssert readFile(sb.homeDir / ".restore-marker") == MarkerA
  let rb = sb.applyB()
  doAssert rb.exitCode == 0, rb.output
  result.b = readCurrentGenerationId(sb.stateDir)
  doAssert result.b != result.a
  # B removed all three of A's objects (the restores below need them gone).
  doAssert not fileExists(sb.homeDir / ".fooconfig")
  doAssert not fileExists(sb.homeDir / ".restore-marker")
  doAssert BlockA notin readFile(sb.homeDir / ".bashrc")

suite "rollback restores respect drift":

  test "a re-created generated file is not overwritten without " &
       "--accept-overwrite":
    let sb = newSandbox("file")
    defer: removeDir(sb.root)
    let gens = sb.twoGenerations()
    writeFile(sb.homeDir / ".fooconfig", Foreign)
    let refused = sb.rollback()
    checkpoint refused.output
    check refused.exitCode != 0
    check "user edit detected" in refused.output
    check ".fooconfig" in refused.output
    check "--accept-overwrite" in refused.output
    check readFile(sb.homeDir / ".fooconfig") == Foreign
    check readCurrentGenerationId(sb.stateDir) == gens.b
    # Nothing else moved either: the marker A would restore is still absent.
    check not fileExists(sb.homeDir / ".restore-marker")

    let accepted = sb.rollback(accept = true)
    checkpoint accepted.output
    check accepted.exitCode == 0
    check readCurrentGenerationId(sb.stateDir) == gens.a
    check readFile(sb.homeDir / ".fooconfig") == ConfigA
    check readFile(sb.homeDir / ".restore-marker") == MarkerA

  test "a re-created resource is not overwritten without " &
       "--accept-overwrite":
    let sb = newSandbox("resource")
    defer: removeDir(sb.root)
    let gens = sb.twoGenerations()
    writeFile(sb.homeDir / ".restore-marker", Foreign)
    let refused = sb.rollback()
    checkpoint refused.output
    check refused.exitCode != 0
    check "user edit detected" in refused.output
    check "restore-marker" in refused.output
    check readFile(sb.homeDir / ".restore-marker") == Foreign
    check not fileExists(sb.homeDir / ".fooconfig")
    check readCurrentGenerationId(sb.stateDir) == gens.b

  test "a re-created managed block is not overwritten without " &
       "--accept-overwrite":
    let sb = newSandbox("block")
    defer: removeDir(sb.root)
    let gens = sb.twoGenerations()
    # The user puts the block back (A's sentinel lines) with their own body,
    # below B's own block, which stays as B wrote it.
    var aBlock: seq[string]
    var inside = false
    for line in gens.bashrcA.splitLines():
      if BlockId in line:
        aBlock.add line
        inside = not inside
      elif inside:
        aBlock.add line.replace(BlockA, "export FOO=mine")
    check aBlock.len == 3
    let ownBlock = readFile(sb.homeDir / ".bashrc") & aBlock.join("\n") & "\n"
    writeFile(sb.homeDir / ".bashrc", ownBlock)
    let refused = sb.rollback()
    checkpoint refused.output
    check refused.exitCode != 0
    check "user edit detected" in refused.output
    check BlockId in refused.output
    check readFile(sb.homeDir / ".bashrc") == ownBlock
    check readCurrentGenerationId(sb.stateDir) == gens.b

  test "positive control: absent, or already holding the target's " &
       "content, restores without --accept-overwrite":
    let sb = newSandbox("control")
    defer: removeDir(sb.root)
    let gens = sb.twoGenerations()
    # `.fooconfig` already holds A's bytes; the marker and the block are
    # absent.
    writeFile(sb.homeDir / ".fooconfig", ConfigA)
    let ok = sb.rollback()
    checkpoint ok.output
    check ok.exitCode == 0
    check readCurrentGenerationId(sb.stateDir) == gens.a
    check readFile(sb.homeDir / ".fooconfig") == ConfigA
    check readFile(sb.homeDir / ".restore-marker") == MarkerA
    check BlockA in readFile(sb.homeDir / ".bashrc")
