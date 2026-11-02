## `repro build` and an environment-provided library prefix
## (reprobuild-pm Package-Model.md §"Environment-provided library prefixes",
## approved by Zahary Karadjov, 2026-11-02): the engine-level half of the
## spec's tests 1, 3, 4 and 5; the resolver-level half is
## `libs/repro_tool_profiles/tests/t_environment_prefix_provisioning.nim`.
##
## The stdlib's `sqlite` package declares `environmentPrefix
## "SQLITE_PREFIX"`. A recipe that `uses: "sqlite"` and names it in an
## action's `toolIdentityRefs` is handed:
##   * `DEP_SQLITE_PREFIX`, the prefix, as the action's environment;
##   * a cache key that follows the prefix's FILES: a second build with the
##     same bytes launches nothing; new bytes under the same path launch the
##     action again.
## Under `--target` the variable is not taken: with no sibling build the
## build is refused, naming the sibling, and launches nothing.
##
## The real `repro`, a real project and real files; no mocks. The "library"
## is an ELF header -- the action only prints the variable, so nothing links
## it; what is under test is resolution, identity and the cache key.

import std/[monotimes, os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_test_support/reasoned_skip

const
  ReprobuildRepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
  reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)
  Triple = "armv7-unknown-linux-gnueabihf"

  Recipe = """
import repro_project_dsl

package envPrefixProbe:
  defaultToolProvisioning "path"
  uses:
    "sqlite"
  build:
    let probe = buildAction(id = "probe.prefix",
      call = inlineExecCall(@["/bin/sh", "-c",
        "printf %s \"$DEP_SQLITE_PREFIX\" > build/prefix.txt"],
        activeProviderProjectRoot()),
      outputs = @["build/prefix.txt"],
      toolIdentityRefs = @["sqlite"],
      cacheable = true)
    defaultBuildAction(probe)
"""

proc elfObject(payload: string): string =
  var head = newString(64)
  head[0] = '\x7f'; head[1] = 'E'; head[2] = 'L'; head[3] = 'F'
  head[4] = '\x02'; head[5] = '\x01'; head[6] = '\x01'
  let machine = case hostCPU
    of "arm64": 183
    of "arm": 40
    else: 62
  head[18] = char(machine and 0xff)
  head & payload

proc makePrefix(root, payload: string): string =
  result = root / "sqlite-prefix"
  createDir(result / "lib")
  writeFile(result / "lib" / "libsqlite3.so.0", elfObject(payload))
  createSymlink("libsqlite3.so.0", result / "lib" / "libsqlite3.so")

proc createProject(root: string): string =
  result = root / "proj"
  createDir(result / "build")
  writeFile(result / "repro.nim", Recipe)

proc runBuild(root, project: string; args: seq[string];
              extraEnv: openArray[(string, string)] = []):
    tuple[code: int, output: string] =
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): env[key] = value
  env["REPROBUILD_WORK_ROOT"] = root / "work"
  env["REPROBUILD_ACTION_CACHE_ROOT"] = root / "action-cache"
  env["REPRO_LOCAL_STORE"] = root / "store"
  env["REPRO_STORE_ROOT"] = root / "cas"
  env["REPRO_CACHE_DISABLE"] = "1"
  env.del("REPRO_VARIANTS")
  env.del("SQLITE_PREFIX")
  for (k, v) in extraEnv: env[k] = v
  env["PATH"] = reproBinary.parentDir & PathSep & getEnv("PATH")
  let log = root / ("build-" & $getMonoTime().ticks & ".log")
  let argv = @[reproBinary, "build", "--daemon=off", "--progress=quiet",
    "--log=actions"] & args
  let p = startProcess(findExe("sh"), args = @["-c",
    quoteShellCommand(argv) & " > " & quoteShell(log) & " 2>&1"],
    workingDir = project, env = env, options = {poParentStreams})
  let code = p.waitForExit()
  p.close()
  (code, readFile(log))

proc launchedActions(output: string): int =
  for line in output.splitLines():
    if line.startsWith("action: ") and " launched=true " in line:
      inc result

template requireBuiltRepro(body: untyped) =
  if not fileExists(reproBinary):
    if getEnv("REPROBUILD_GATE_RUN") == "1":
      checkpoint(reproBinary & " is not built in a gate run")
      check false
    else:
      skip(reproBinary & " is not built; run `just build`")
  elif findExe("sh").len == 0:
    skip("sh is not on PATH")
  else:
    body

suite "an environment-provided library prefix, through repro build":

  test "t_env_prefix_native_build_hands_the_prefix_and_keys_on_its_files":
    requireBuiltRepro:
      let root = createTempDir("env-prefix-native-", "")
      defer: removeDir(root)
      let project = createProject(root)
      let prefix = makePrefix(root, "version-one")
      let env = @[("SQLITE_PREFIX", prefix)]
      # 1. The prefix reaches the action as DEP_SQLITE_PREFIX.
      let first = runBuild(root, project, @[], env)
      checkpoint(first.output)
      require first.code == 0
      check readFile(project / "build" / "prefix.txt") == prefix
      check launchedActions(first.output) >= 1
      # Control: the same bytes launch nothing -- the cache key is stable,
      # so the next case's miss is the files, not noise.
      let again = runBuild(root, project, @[], env)
      checkpoint(again.output)
      require again.code == 0
      check launchedActions(again.output) == 0
      # 3. New bytes under the unchanged path: the action runs again.
      writeFile(prefix / "lib" / "libsqlite3.so.0", elfObject("version-TWO"))
      let changed = runBuild(root, project, @[], env)
      checkpoint(changed.output)
      require changed.code == 0
      check launchedActions(changed.output) >= 1

  test "t_env_prefix_unset_and_incomplete_prefixes_are_refused_by_name":
    requireBuiltRepro:
      let root = createTempDir("env-prefix-refused-", "")
      defer: removeDir(root)
      let project = createProject(root)
      let unset = runBuild(root, project, @[])
      checkpoint(unset.output)
      check unset.code != 0
      check "SQLITE_PREFIX is not set" in unset.output
      check launchedActions(unset.output) == 0
      let prefix = makePrefix(root, "v")
      removeFile(prefix / "lib" / "libsqlite3.so")
      removeFile(prefix / "lib" / "libsqlite3.so.0")
      let noLibrary = runBuild(root, project, @[], [("SQLITE_PREFIX", prefix)])
      checkpoint(noLibrary.output)
      check noLibrary.code != 0
      check "holds no libsqlite3" in noLibrary.output
      check "SQLITE_PREFIX=" & prefix in noLibrary.output
      check launchedActions(noLibrary.output) == 0

  test "t_env_prefix_is_never_taken_under_target":
    requireBuiltRepro:
      let root = createTempDir("env-prefix-target-", "")
      defer: removeDir(root)
      let project = createProject(root)
      let prefix = makePrefix(root, "v")
      # An empty recipe root: no sibling `sqlite` to build for the target.
      let recipes = root / "recipes"
      createDir(recipes)
      let cross = runBuild(root, project, @["--target=" & Triple],
        [("SQLITE_PREFIX", prefix), ("REPRO_FROM_SOURCE_ROOT", recipes)])
      checkpoint(cross.output)
      check cross.code != 0
      check "'sqlite'" in cross.output
      check "--target '" & Triple & "'" in cross.output
      check "SQLITE_PREFIX is set, but an environment prefix is the build " &
        "host's library" in cross.output
      check launchedActions(cross.output) == 0
      check not fileExists(project / "build" / "prefix.txt")
