## An in-process profile compile must never re-execute its CALLER as the
## monitor driver.
##
## `compileAndAdaptHomeProfile` (and the infra compile sites beside it) build
## the profile through the engine, whose config wraps every action in
## ``<publicCliPath> internal io monitor --depfile <capture> -- <cmd>``. Those
## sites used to resolve ``publicCliPath`` with the bare
## ``publicCliImagePath()``, i.e. ``getAppFilename()``, so a test binary that
## called them in-process was spawned as its OWN monitor driver. A unittest
## binary does not implement ``internal io monitor``: it exited 0 without
## running the command or writing the capture. The real compile never ran,
## and the engine read the empty pre-created capture as
## ``monitor depfile read failed: iomon file is too short`` -- which is how
## M76's in-process case failed on Windows (reprobuild-pm issue
## 2026-10-27-windows-m76-differing-regular-file-case-fails-in-the-profile-compile).
##
## Distribution-And-Packaging.md §5.2 (reprobuild-pm) is the rule: "the
## engine spawns the running image with an internal verb only when that
## image has declared itself `repro`". This binary never declares itself, so
## it must be refused -- named explicitly or found implicitly -- with a
## diagnostic that names the cause, and it must never be spawned.
##
## HOW "NEVER SPAWNED" IS OBSERVED. Not from the error text alone: the module
## initialiser below recognises the monitor-driver argv and, before exiting,
## drops a marker next to the ``--depfile`` capture the engine handed it. The
## capture lives under the state directory, so a marker anywhere under it is
## proof that this image was re-executed. The child exits 0 without writing
## the capture, exactly as the unittest runner did, so the pre-fix behaviour
## is reproduced faithfully rather than approximated.
##
## No mocks: the compile runs through the real engine, and the positive case
## uses the real `repro` built at `build/bin/` (`just build`).

import std/[os, strutils, tempfiles, unittest]
from repro_core/paths import extendedPath
from repro_test_support import removeDirEventually

import repro_cli_support/home as cli_home
from repro_profile_compile import MissingPublicCliPathReason

const SelfSpawnMarkerSuffix = ".self-spawned"

# Runs before the suite in EVERY process this image becomes, including one
# the engine spawned as `<this> internal io monitor --depfile <f> -- <cmd>`.
if paramCount() >= 3 and paramStr(1) == "internal" and
    paramStr(2) == "io" and paramStr(3) == "monitor":
  for i in 4 ..< paramCount():
    if paramStr(i) == "--depfile":
      writeFile(paramStr(i + 1) & SelfSpawnMarkerSuffix, "")
      break
  quit(0)

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir()
  .parentDir()
const FixtureProfile = ProjectRoot / "tests" / "fixtures" / "m76" /
  "stow_byte_identical" / "home.nim"

proc reproBinary(): string =
  let candidate = ProjectRoot / "build" / "bin" / addFileExt("repro", ExeExt)
  doAssert fileExists(extendedPath(candidate)),
    "repro binary not found at " & candidate &
    "; build with `just build` first"
  candidate

proc selfSpawnMarkers(root: string): seq[string] =
  # Extended-length form: the engine's cache paths can pass MAX_PATH on
  # Windows, and a walk that cannot see them would miss a marker.
  for path in walkDirRec(extendedPath(root)):
    if path.endsWith(SelfSpawnMarkerSuffix):
      result.add(path)

proc freshProfile(): tuple[root, profilePath, stateDir: string] =
  let root = createTempDir("repro-inproc-profile-compile-", "")
  createDir(root / "profile")
  createDir(root / "state")
  copyFile(FixtureProfile, root / "profile" / "home.nim")
  (root: root, profilePath: root / "profile" / "home.nim",
    stateDir: root / "state")

suite "in-process profile compile never spawns its caller":
  # `REPRO_PUBLIC_CLI_PATH` would name a different image and make the
  # implicit-refusal case vacuous, so it is cleared for the whole suite.
  let savedPublicCli = getEnv("REPRO_PUBLIC_CLI_PATH")
  delEnv("REPRO_PUBLIC_CLI_PATH")

  test "an undeclared caller that names no repro image is refused, " &
       "not spawned":
    check extractFilename(getAppFilename()) != addFileExt("repro", ExeExt)
    let f = freshProfile()
    defer: removeDirEventually(f.root)
    let outcome = cli_home.compileAndAdaptHomeProfile(f.profilePath,
      f.stateDir)
    check outcome.profile == nil
    check outcome.compileError.contains("publicCliPath is required")
    check outcome.compileError.contains(MissingPublicCliPathReason)
    check not outcome.compileError.contains("iomon")
    check selfSpawnMarkers(f.stateDir).len == 0

  test "naming its own image does not get the caller spawned either":
    let f = freshProfile()
    defer: removeDirEventually(f.root)
    let outcome = cli_home.compileAndAdaptHomeProfile(f.profilePath,
      f.stateDir, publicCliPath = getAppFilename())
    check outcome.profile == nil
    check outcome.compileError.contains(MissingPublicCliPathReason)
    check selfSpawnMarkers(f.stateDir).len == 0

  test "a named repro image compiles the profile in-process":
    let f = freshProfile()
    defer: removeDirEventually(f.root)
    let outcome = cli_home.compileAndAdaptHomeProfile(f.profilePath,
      f.stateDir, publicCliPath = reproBinary())
    check outcome.compileError == ""
    check outcome.profile != nil
    check selfSpawnMarkers(f.stateDir).len == 0

  if savedPublicCli.len > 0:
    putEnv("REPRO_PUBLIC_CLI_PATH", savedPublicCli)
