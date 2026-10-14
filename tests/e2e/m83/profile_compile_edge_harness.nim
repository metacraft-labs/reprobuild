## Shared harness for the profile-compile-edge gates
## (`t_e2e_profile_compile_staticread_payload_change.nim`,
## `t_e2e_profile_compile_runtime_read_tracked.nim`) and the `repro home
## export` / `repro home set` gates built on them (`t_e2e_home_export_*`,
## `t_e2e_export_*`, `t_e2e_home_set_writes_guarded_config.nim`).
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
## directory first on `PATH` holding a pass-through `nim` (`nim.exe` on
## Windows): the graph-built `nim_spy` program (`nim_spy.nim`, edge
## `reprobuild.test_helpers.nim_spy`) copied in, which appends one line to a
## log and then runs the REAL compiler — the one the test process itself
## resolves — with the arguments unchanged. The compile is still the real Nim
## compiler on the real profile, monitored by the real io-mon shim; the spy
## only counts invocations. Measured: the spy's own reads and its append to
## the log do not perturb the edge's action-cache key (an unchanged profile
## behind the spy is a hit). It used to be a POSIX shell script, which kept
## these gates off Windows (no `/bin/sh`, and an extension-less `nim` is not
## found on `PATH`) and on macOS ran the real `nim` from SIP-protected
## `/bin/sh`, whose loader drops the monitor shim's `DYLD_*` variables.
##
## PROCESSES ARE SPAWNED FROM ARGV, never through a shell, so the harness runs
## unchanged on Linux, macOS and Windows.
##
## CACHE ANSWERS ON macOS. Whether the profile-compile edge can be answered
## from the action cache on macOS depends on what macOS monitoring observes
## (milestone GM0m, `MacOS-Monitoring.md`): where it cannot vouch for an
## edge's reads, the edge must FAIL CLOSED — re-run every time — and never
## serve a stale intent. `cacheAnswered` encodes that: on Linux and Windows a
## run that should be a cache answer must spawn no `nim`; on macOS it may
## instead be a complete re-run (exactly the spawns of an executed edge), which
## it reports on the test output. Staleness is never admitted: every gate
## asserts the CONTENT of what the run planned or exported.

import std/[algorithm, hashes, os, osproc, streams, strtabs, strutils, tempfiles, times]
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

proc nimSpyBinary*(): string =
  ## The graph-built pass-through `nim` (see the header).
  requireBinary(ProjectRoot / "build" / "test-bin" / addFileExt("nim_spy",
    ExeExt), "reprobuild.test_helpers.nim_spy")

const NimSpyConfName = "nim-spy.conf"
  ## Read by `nim_spy.nim` from its own directory: the log, then the real nim.

proc writeSpy(sb: ProfileSandbox) =
  createDir(extendedPath(sb.spyDir))
  let path = sb.spyDir / addFileExt("nim", ExeExt)
  copyFileWithPermissions(nimSpyBinary(), path)
  writeFile(extendedPath(sb.spyDir / NimSpyConfName),
    sb.spyLog & "\n" & sb.realNim & "\n")

proc realNimCompiler(): string =
  ## The compiler the edge would use without the spy: the one
  ## `$REPRO_NIM_COMPILER` names, else `nim` on `PATH` (the order
  ## `resolveProfileNimCompiler` applies). The sandbox removes the variable
  ## so the edge resolves the spy instead.
  result = getEnv(ProfileNimCompilerEnvVar)
  if result.len == 0:
    result = findExe("nim")

proc newProfileSandbox*(label, homeNim: string): ProfileSandbox =
  ## A fresh sandbox whose profile root is `home.nim` with `homeNim` as its
  ## text. Further files are written with `writeProfileFile`.
  result.realNim = realNimCompiler()
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

proc nimSpawnCount*(sb: ProfileSandbox; command: string): int =
  ## How many logged `nim` invocations ran `command` (`c` for the profile
  ## compile, `check` / `dump` for `repro home export`'s platform probe).
  if not fileExists(extendedPath(sb.spyLog)):
    return 0
  for line in readFile(extendedPath(sb.spyLog)).splitLines():
    if line.startsWith("nim " & command & " "):
      inc result

proc publishedRbpiPath*(sb: ProfileSandbox): string =
  ## Where the profile-compile edge publishes this sandbox's envelope.
  cachedRbpiPath(sb.stateDir, profileCompileKey(sb.profilePath))

proc profileBinaryPath*(sb: ProfileSandbox): string =
  ## The profile binary the edge compiled (it lives in the edge's nimcache).
  cachedNimcacheDir(sb.stateDir, profileCompileKey(sb.profilePath)) /
    addFileExt("profile-build", ExeExt)

const DefaultSandboxHost* = "gm0-profile-compile-host"
  ## The `$REPRO_HOST` every run gets unless the caller names another.

proc sandboxEnv*(sb: ProfileSandbox; host = DefaultSandboxHost):
    StringTableRef =
  ## The isolated environment every run gets. `host` is exported as
  ## `$REPRO_HOST`; an empty `host` removes the variable, so a run selects its
  ## host with `--host` (or falls back to the OS hostname).
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    result[k] = v
  result["PATH"] = sb.spyDir & $PathSep & getEnv("PATH")
  result["HOME"] = sb.homeDir
  result["USERPROFILE"] = sb.homeDir
  if result.hasKey(ProfileNimCompilerEnvVar):
    # The edge would take this compiler over `PATH` and bypass the spy; the
    # spy forwards to it instead (`realNimCompiler`).
    result.del(ProfileNimCompilerEnvVar)
  result["XDG_CACHE_HOME"] = sb.root / "xdg-cache"
  result["XDG_STATE_HOME"] = sb.root / "xdg-state"
  result["XDG_CONFIG_HOME"] = sb.root / "xdg-config"
  result["XDG_DATA_HOME"] = sb.root / "xdg-data"
  result["REPRO_HOME_PROFILE_DIR"] = sb.profileDir
  result["REPRO_HOME_STATE_DIR"] = sb.stateDir
  result["REPRO_STORE_ROOT"] = sb.storeRoot
  if host.len > 0:
    result["REPRO_HOST"] = host
  elif result.hasKey("REPRO_HOST"):
    result.del("REPRO_HOST")
  result["REPROBUILD_REPO_ROOT"] = ProjectRoot

proc runMerged(exe: string; args: openArray[string]; workingDir = "";
               env: StringTableRef = nil): tuple[exitCode: int; output: string] =
  ## Run `exe` from argv (no shell) with stdout and stderr merged.
  let p = startProcess(exe, args = args, workingDir = workingDir, env = env,
    options = {poStdErrToStdOut})
  let stream = p.outputStream()
  while not stream.atEnd():
    let chunk = stream.readAll()
    if chunk.len == 0:
      break
    result.output.add(chunk)
  result.exitCode = p.waitForExit()
  p.close()

proc runHomePlan*(sb: ProfileSandbox; host = DefaultSandboxHost): PlanRun =
  ## One `repro home plan` against the sandbox.
  let before = sb.nimSpawnCount()
  let (exitCode, output) = runMerged(reproBinary(), ["home", "plan"],
    workingDir = sb.root, env = sb.sandboxEnv(host))
  result.exitCode = exitCode
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
  let res = runMerged(sb.profileBinaryPath(), [])
  doAssert res.exitCode == 0, "profile binary failed: " & res.output
  res.output

type
  ReproRun* = object
    exitCode*: int
    stdout*: string
    stderr*: string
    nimSpawns*: int
      ## How many `nim` invocations the spy logged during THIS run.
    nimCompileSpawns*: int
      ## Of those, how many were `nim c` -- the profile compile (the rest are
      ## `repro home export`'s platform probe: one `nim dump`, one
      ## `nim check` per target platform).

proc runRepro*(sb: ProfileSandbox; args: openArray[string];
               host = DefaultSandboxHost;
               extraEnv: openArray[(string, string)] = []): ReproRun =
  ## One `repro <args>` against the sandbox with stdout and stderr captured
  ## SEPARATELY (a command whose stdout is a document must not have
  ## diagnostics mixed into it). Both pipes are drained concurrently by
  ## `runProgramSplit`, so a chatty stderr cannot fill its pipe while the
  ## parent is still reading stdout. `extraEnv` adds variables on top of the
  ## sandbox's isolated environment (e.g. the apply gates' package seams).
  let before = sb.nimSpawnCount()
  let compilesBefore = sb.nimSpawnCount("c")
  let env = sb.sandboxEnv(host)
  for (k, v) in extraEnv:
    env[k] = v
  let res = runProgramSplit(reproBinary(), args, cwd = sb.root, env = env)
  result.exitCode = res.code
  result.stdout = res.stdout
  result.stderr = res.stderr
  result.nimSpawns = sb.nimSpawnCount() - before
  result.nimCompileSpawns = sb.nimSpawnCount("c") - compilesBefore

const EdgeMayFailClosed* = defined(macosx)
  ## True where a run the action cache should answer may instead re-run the
  ## edge completely (fail closed): macOS, until GM0m settles what macOS
  ## monitoring can vouch for. See the header.

proc cacheAnswered*(spawns, executedSpawns: int; what: string): bool =
  ## The check for "this run was answered from the action cache": `spawns`
  ## (the `nim` processes the spy logged for one edge during the run) is 0.
  ## Where `EdgeMayFailClosed`, a complete re-run is accepted instead —
  ## exactly `executedSpawns`, the spawns of the same edge when it executed —
  ## and announced on the test output so the run records which arm it took.
  if spawns == 0:
    return true
  when EdgeMayFailClosed:
    if executedSpawns > 0 and spawns == executedSpawns:
      echo "    [fail-closed, GM0m] ", what, ": the edge re-ran (", spawns,
        " nim spawn(s)) instead of being answered from the action cache"
      return true
  false

proc treeFingerprint*(root: string; excludePrefixes: openArray[string] = []):
    seq[string] =
  ## One line per entry under `root` — relative path, kind, and for files the
  ## size, modification time and a hash of the bytes — sorted. Two equal
  ## fingerprints mean nothing under `root` was created, removed, rewritten
  ## or touched. `excludePrefixes` are absolute paths whose subtrees are
  ## skipped (state a command is ALLOWED to write, e.g. the compile cache).
  if not dirExists(extendedPath(root)):
    return @["<absent>"]
  for path in walkDirRec(root, yieldFilter = {pcFile, pcDir, pcLinkToFile,
                                             pcLinkToDir}, relative = false):
    var skip = false
    for prefix in excludePrefixes:
      if path == prefix or path.startsWith(prefix & DirSep):
        skip = true
        break
    if skip:
      continue
    let rel = path.relativePath(root)
    if symlinkExists(path):
      result.add rel & "\tlink\t" & expandSymlink(path)
    elif dirExists(path):
      result.add rel & "\tdir"
    else:
      result.add rel & "\tfile\t" & $getFileSize(path) & "\t" &
        $getLastModificationTime(path).toUnixFloat & "\t" &
        $hash(readFile(path))
  result.sort()

proc fixturePackageEnv*(sb: ProfileSandbox; names: openArray[string]):
    seq[(string, string)] =
  ## Bind each package in `names` to a trivial fixture executable through
  ## the documented test seams: `REPRO_TEST_PACKAGE_SOURCE` (the binding the
  ## real `path` realization then installs into the sandbox's store) and
  ## `REPRO_HOME_PACKAGE_CATALOG` (the names `repro home add` accepts).
  ## Pass the result as `extraEnv` to `runRepro`. Used by the GM4 data-file
  ## gates, which plan and apply real packages without network access.
  let ext = when defined(windows): ".cmd" else: ""
  let dir = sb.root / "fixture-pkgs"
  createDir(extendedPath(dir))
  var bindings: seq[string]
  for name in names:
    let exe = dir / (name & ext)
    when defined(windows):
      writeFile(extendedPath(exe), "@echo off\r\nexit /b 0\r\n")
    else:
      writeFile(exe, "#!/bin/sh\nexit 0\n")
      setFilePermissions(exe, {fpUserExec, fpUserWrite, fpUserRead})
    bindings.add name & "=" & exe
  @[("REPRO_TEST_PACKAGE_SOURCE", bindings.join(";")),
    ("REPRO_HOME_PACKAGE_CATALOG", @names.join(","))]
