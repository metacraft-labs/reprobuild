## Shared harness for the profile-compile-edge gates
## (`t_e2e_profile_compile_staticread_payload_change.nim`,
## `t_e2e_profile_compile_runtime_read_tracked.nim`).
##
## Each gate drives the PUBLIC `repro home plan` command — the path a user's
## `repro home apply` takes — against a profile in a throwaway sandbox, and
## reads back three things after every run:
##
## * what the plan printed (the `create` lines and the summary);
## * the envelope the profile-compile edge published, decoded, so a gate can
##   assert on the resource CONTENT and not only on the address the plan
##   prints;
## * how many times `nim` was spawned during the run.
##
## ISOLATION. Every run gets its own `HOME`, profile directory, state
## directory, store root and XDG roots under one temp directory. Nothing is
## applied: `repro home plan` is non-mutating, and its `HOME` is the sandbox's.
##
## THE `nim` SPY, AND WHY IT IS NOT A MOCK. "The second run is an action-cache
## hit and does not spawn nim" has to be observed, not inferred from a fast
## wall clock or an unchanged mtime (Nim can legitimately skip relinking an
## unchanged binary, so an mtime proves nothing). The sandbox therefore puts a
## directory first on `PATH` holding a two-line POSIX shell script named `nim`
## that appends one line to a log and then `exec`s the REAL compiler — the one
## the test process itself resolves — with the arguments unchanged. The
## compile is still the real Nim compiler on the real profile, monitored by
## the real io-mon shim; the script only counts invocations. Measured: the
## script's own reads and its append to the log do not perturb the edge's
## action-cache key (an unchanged profile behind the spy is a hit). It is a
## POSIX shell script, which is why these gates run on POSIX hosts only.

import std/[os, osproc, streams, strtabs, strutils, tempfiles]
from repro_core/paths import extendedPath

import repro_profile
import repro_profile_intent
import repro_profile_compile
import repro_test_support

const ProjectRoot* = currentSourcePath().parentDir().parentDir().
  parentDir().parentDir()

type
  ProfileSandbox* = object
    root*: string
    profileDir*: string
    profilePath*: string
    stateDir*: string
    storeRoot*: string
    homeDir*: string
    spyDir*: string
    spyLog*: string
    realNim*: string

  PlanRun* = object
    exitCode*: int
    output*: string
    createLines*: seq[string]
      ## The plan's `create …` lines, stripped.
    nimSpawns*: int
      ## How many `nim` invocations the spy logged during THIS run.
    intent*: ProfileIntent
      ## The envelope the edge published, decoded (only when exitCode == 0).

proc reproBinary*(): string =
  requireBinary(ProjectRoot / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc writeSpy(sb: ProfileSandbox) =
  createDir(extendedPath(sb.spyDir))
  let script = "#!/bin/sh\n" &
    "echo \"nim $*\" >> " & quoteShell(sb.spyLog) & "\n" &
    "exec " & quoteShell(sb.realNim) & " \"$@\"\n"
  let path = sb.spyDir / "nim"
  writeFile(extendedPath(path), script)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc newProfileSandbox*(label, homeNim: string): ProfileSandbox =
  ## A fresh sandbox whose profile root is `home.nim` with `homeNim` as its
  ## text. Further files are written with `writeProfileFile`.
  result.realNim = findExe("nim")
  doAssert result.realNim.len > 0,
    "profile compilation requires `nim` on PATH (enter the dev shell)"
  result.root = createTempDir("repro-gm0-" & label & "-", "")
  result.profileDir = result.root / "profile"
  result.profilePath = result.profileDir / "home.nim"
  result.stateDir = result.root / "state"
  result.storeRoot = result.root / "store"
  result.homeDir = result.root / "home"
  result.spyDir = result.root / "spy-bin"
  result.spyLog = result.root / "nim-spawns.log"
  for dir in [result.profileDir, result.stateDir, result.storeRoot,
              result.homeDir]:
    createDir(extendedPath(dir))
  writeFile(extendedPath(result.profilePath), homeNim)
  writeSpy(result)

proc writeProfileFile*(sb: ProfileSandbox; relPath, content: string) =
  let path = sb.profileDir / relPath
  createDir(extendedPath(path.parentDir))
  writeFile(extendedPath(path), content)

proc dispose*(sb: ProfileSandbox) =
  try: removeDir(extendedPath(sb.root)) except CatchableError: discard

proc nimSpawnCount*(sb: ProfileSandbox): int =
  if not fileExists(extendedPath(sb.spyLog)):
    return 0
  for line in readFile(extendedPath(sb.spyLog)).splitLines():
    if line.strip().len > 0:
      inc result

proc publishedRbpiPath*(sb: ProfileSandbox): string =
  ## Where the profile-compile edge publishes this sandbox's envelope.
  cachedRbpiPath(sb.stateDir, profileCompileKey(sb.profilePath))

proc profileBinaryPath*(sb: ProfileSandbox): string =
  ## The profile binary the edge compiled (it lives in the edge's nimcache).
  cachedNimcacheDir(sb.stateDir, profileCompileKey(sb.profilePath)) /
    addFileExt("profile-build", ExeExt)

proc sandboxEnv(sb: ProfileSandbox): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    result[k] = v
  result["PATH"] = sb.spyDir & $PathSep & getEnv("PATH")
  result["HOME"] = sb.homeDir
  result["XDG_CACHE_HOME"] = sb.root / "xdg-cache"
  result["XDG_STATE_HOME"] = sb.root / "xdg-state"
  result["XDG_CONFIG_HOME"] = sb.root / "xdg-config"
  result["XDG_DATA_HOME"] = sb.root / "xdg-data"
  result["REPRO_HOME_PROFILE_DIR"] = sb.profileDir
  result["REPRO_HOME_STATE_DIR"] = sb.stateDir
  result["REPRO_STORE_ROOT"] = sb.storeRoot
  result["REPRO_HOST"] = "gm0-profile-compile-host"
  result["REPROBUILD_REPO_ROOT"] = ProjectRoot

proc runHomePlan*(sb: ProfileSandbox): PlanRun =
  ## One `repro home plan` against the sandbox.
  let before = sb.nimSpawnCount()
  let p = startProcess(reproBinary(), args = ["home", "plan"],
    workingDir = sb.root, env = sb.sandboxEnv(),
    options = {poStdErrToStdOut})
  var output = ""
  let stream = p.outputStream()
  while not stream.atEnd():
    let chunk = stream.readAll()
    if chunk.len == 0:
      break
    output.add(chunk)
  result.exitCode = p.waitForExit()
  p.close()
  result.output = output
  for line in output.splitLines():
    let stripped = line.strip()
    if stripped.startsWith("create"):
      result.createLines.add(stripped)
  result.nimSpawns = sb.nimSpawnCount() - before
  if result.exitCode == 0:
    result.intent = decodeRbpi(readBytes(sb.publishedRbpiPath()))

proc runProfileBinaryDirectly*(sb: ProfileSandbox): string =
  ## Run the compiled profile binary OUTSIDE any edge and return its stdout
  ## (the ProfileIntent JSON). Used only to establish where a read happens —
  ## never to produce what a gate asserts the plan says.
  let res = execCmdEx(quoteShell(sb.profileBinaryPath()),
    options = {poUsePath})
  doAssert res.exitCode == 0, "profile binary failed: " & res.output
  res.output
