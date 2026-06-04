## M72 gate 2: `e2e_apply_plan_dry_run`.
##
## Drives the real `repro` binary's `repro home apply --plan` flag —
## the M72 Deliverable 2 non-mutating dry run.
##
## Assertions:
##   * `--plan` prints a per-item preview covering EVERY category of
##     operation: packages, stow files, generated files, managed
##     blocks, launchers, resources.
##   * A checksum of (state dir + store + target HOME) taken before
##     and after the dry run is byte-identical — the dry run mutates
##     NOTHING (no store writes, no generation, no `current`
##     rotation, no file writes, no `scoop install`).
##   * Exit 0 on a clean / no-op plan.
##   * Exit non-zero when drift is detected, unless `--allow-drift`
##     is passed.
##
## The fixture binds packages through the `path` adapter test seam
## (a fixture stub executable) so the gate needs no Scoop sandbox —
## the M72 deliverable text allows "fixture profile and fixture
## tools only" for this gate.

import std/[algorithm, os, osproc, sequtils, streams, strtabs, strutils,
  tempfiles, unittest]

import blake3

import repro_test_support

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()
const FixtureSrc = currentSourcePath().parentDir().parentDir()
  .parentDir() / "fixtures" / "m72" / "plan_dry_run"

proc reproBinary(): string =
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate &
    "; build with `just build` first"
  candidate

proc copyTree(src, dst: string) =
  createDir(dst)
  for kind, entry in walkDir(src, relative = true):
    let from0 = src / entry
    let to0 = dst / entry
    case kind
    of pcFile:
      createDir(parentDir(to0))
      copyFile(from0, to0)
    of pcDir:
      copyTree(from0, to0)
    else: discard

proc runRepro(envOverrides: openArray[tuple[k, v: string]];
              args: openArray[string]):
    tuple[exitCode: int; output: string] =
  var processEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    processEnv[k] = v
  for kv in envOverrides:
    processEnv[kv.k] = kv.v
  let p = startProcess(reproBinary(), args = @args, env = processEnv,
    options = {poUsePath, poStdErrToStdOut})
  let stream = p.outputStream()
  var combined = ""
  while not stream.atEnd():
    let chunk = stream.readAll()
    if chunk.len == 0: break
    combined.add chunk
  let code = p.waitForExit()
  p.close()
  result = (exitCode: code, output: combined)

proc treeChecksum(roots: openArray[string]): string =
  ## BLAKE3 over every regular file under every root: rel-path + size
  ## + content digest. A byte-identical checksum before vs after the
  ## dry run proves it mutated nothing.
  var lines: seq[string]
  for root in roots:
    if not dirExists(root):
      lines.add("ABSENT:" & root)
      continue
    for path in walkDirRec(root, yieldFilter = {pcFile}):
      let rel = path[root.len .. ^1].replace('\\', '/')
      let data = readFile(path)
      var bytes = newSeq[byte](data.len)
      for i, c in data:
        bytes[i] = byte(ord(c))
      lines.add(rel & ":" & $data.len & ":" &
        blake3.digest(bytes).toHex())
  lines.sort()
  var joinedBytes = newSeq[byte](0)
  let joined = lines.join("\n")
  joinedBytes = newSeq[byte](joined.len)
  for i, c in joined:
    joinedBytes[i] = byte(ord(c))
  blake3.digest(joinedBytes).toHex()

when not defined(windows):
  suite "M72 gate 2: e2e_apply_plan_dry_run":
    when isNixSupported:
      test "platform N/A":
        echo "[platform N/A] t_e2e_apply_plan_dry_run: currently exercises the Windows home-apply dry-run gate"
        check true
else:
  suite "M72 gate 2: e2e_apply_plan_dry_run":
    when isNixSupported:
      test "apply --plan previews every category and mutates nothing":
        when not defined(windows):
          checkpoint "platform-skip: M72 plan dry-run gate is Windows-specific"
          check true
          return

        let tempRoot = createTempDir("repro-m72-plan-", "")
        defer:
          try: removeDir(tempRoot) except OSError: discard
        let stateDir = tempRoot / "state"
        let storeRoot = tempRoot / "store"
        let homeDir = tempRoot / "home"
        let profileDir = tempRoot / "profile"
        createDir(stateDir)
        createDir(storeRoot)
        createDir(homeDir)
        copyTree(FixtureSrc, profileDir)

        # `path`-adapter fixture executable for the single package.
        let fixtureExe = tempRoot / "m72-plan-fixture.cmd"
        writeFile(fixtureExe,
          "@echo off\r\n" &
          "if /I \"%1\"==\"--version\" ( echo m72-plan-fixture 1.0.0 & " &
          "exit /b 0 )\r\n" &
          "exit /b 0\r\n")

        # Drive generated files + managed blocks + resources through the
        # test seams so the `--plan` preview can cover every category.
        # The resource is an `fs.managedBlock` in an ISOLATED `$HOME` file
        # (never the real registry) so the gate can drift it out-of-band
        # without perturbing the live environment.
        let genSeam = "m72-plan-fixture=.m72-generated:m72 generated content"
        let blockSeam = "m72-plan-fixture=.m72-bashrc#m72.block:export M72=1"
        let resourceFile = homeDir / ".m72-resource"
        let resourceSeam = "managedblock:m72.res:~/.m72-resource;" &
          "m72.resblock;m72 resource block body"

        let baseEnv = @[
          (k: "REPRO_HOME_PROFILE_DIR", v: profileDir),
          (k: "REPRO_HOME_STATE_DIR", v: stateDir),
          (k: "REPRO_STORE_ROOT", v: storeRoot),
          (k: "HOME", v: homeDir),
          (k: "USERPROFILE", v: homeDir),
          (k: "REPRO_HOST", v: "m72-gate2-host"),
          (k: "REPRO_HOME_PACKAGE_CATALOG", v: "m72-plan-fixture"),
          (k: "REPRO_TEST_PACKAGE_SOURCE", v: "m72-plan-fixture=" & fixtureExe),
          (k: "REPRO_TEST_PACKAGE_GENERATES", v: genSeam),
          (k: "REPRO_TEST_PACKAGE_MANAGED_BLOCKS", v: blockSeam),
          (k: "REPRO_TEST_RESOURCES", v: resourceSeam)]

        # ----- Dry run on a fresh (never-applied) profile. -----
        let beforeChecksum = treeChecksum([stateDir, storeRoot, homeDir])

        let plan = runRepro(baseEnv, ["home", "apply", "--plan"])
        check plan.exitCode == 0
        # Per-item preview covers EVERY category.
        check plan.output.contains("[package]")
        check plan.output.contains("[stow]")
        check plan.output.contains("[generated-file]")
        check plan.output.contains("[managed-block]")
        check plan.output.contains("[launcher]")
        check plan.output.contains("[resource]")
        # Per-item action verbs are present.
        check plan.output.contains("m72-plan-fixture")
        check plan.output.contains("realize")        # package
        check plan.output.contains("link")           # stow file
        check plan.output.contains("write")          # generated file / block
        check plan.output.contains("create")         # resource

        # NOTHING was mutated by the dry run.
        let afterChecksum = treeChecksum([stateDir, storeRoot, homeDir])
        check beforeChecksum == afterChecksum
        # No generation was written.
        check not dirExists(stateDir / "generations") or
              walkDirRec(stateDir / "generations").toSeq().len == 0
        # The dry run never wrote the stow target / generated file.
        check not fileExists(homeDir / ".gitconfig")
        check not fileExists(homeDir / ".m72-generated")

        # ----- A real apply, then a no-op dry run. -----
        let realApply = runRepro(baseEnv, ["home", "apply"])
        check realApply.exitCode == 0
        check realApply.output.contains("applied generation ")

        let postApplyChecksum = treeChecksum([stateDir, storeRoot, homeDir])
        let noopPlan = runRepro(baseEnv, ["home", "apply", "--plan"])
        # Exit 0 on a clean / no-op plan.
        check noopPlan.exitCode == 0
        check noopPlan.output.contains("no-op")
        # The no-op dry run also mutated nothing.
        check treeChecksum([stateDir, storeRoot, homeDir]) == postApplyChecksum

        # ----- Drift: edit the managed file out-of-band, re-plan. -----
        # The real apply created the `fs.managedBlock` resource in
        # `~/.m72-resource`. Editing the block body out-of-band makes the
        # live observed state diverge from the recorded binding — genuine
        # drift the planner must surface.
        doAssert fileExists(resourceFile),
          "fixture invariant: the real apply must have created the " &
          "managed-block resource file"
        let resourceBefore = readFile(resourceFile)
        let driftedContent = resourceBefore.replace(
          "m72 resource block body", "m72 resource block body EDITED")
        writeFile(resourceFile, driftedContent)
        let postDriftEditChecksum = treeChecksum([stateDir, storeRoot, homeDir])

        let driftPlan = runRepro(baseEnv, ["home", "apply", "--plan"])
        # The plan reports drift; exit non-zero without --allow-drift.
        check driftPlan.exitCode != 0
        check (driftPlan.output.contains("drift") or
               driftPlan.output.contains("conflict-drift"))
        # --allow-drift makes the same drifted plan exit 0.
        let driftAllowed = runRepro(baseEnv,
          ["home", "apply", "--plan", "--allow-drift"])
        check driftAllowed.exitCode == 0
        check (driftAllowed.output.contains("drift") or
               driftAllowed.output.contains("conflict-drift"))
        # The drift re-plans mutated nothing either (the out-of-band edit
        # is the only change; the dry runs added nothing on top).
        check treeChecksum([stateDir, storeRoot, homeDir]) == postDriftEditChecksum
