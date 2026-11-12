## A changed `@FILE:<path>` reaches the next `repro build`, warm graph or not.
##
## Windows-System-Resources.md §"`@FILE:<path>` argv substitution": every
## `@FILE:<path>` argv entry of an `inlineExecCall` is replaced with the
## trimmed contents of `<path>` "at the moment of execution", and the plan
## keeps the literal token. Build-Engine-And-Scheduler.md §"Skippability and
## Invalidation" requires the edge's key to follow its command line.
##
## The defect (reprobuild-pm issue
## 2026-11-11-lowered-graph-cache-serves-a-stale-at-file-expansion): the
## lowering substituted the token, and the lowered graph -- argv and weak
## fingerprint both -- is cached on disk and reused while
## `loweredGraphCacheKey` holds. No field of that key covers a token file's
## contents, so after the file changed a warm build spawned the OLD value
## and looked the edge up under the OLD key: the edge either reran with the
## stale argument or was served the stale result. The cached graph also held
## the substituted value in plain text.
##
## Asserted, against the built `build/bin/repro` with every root in a fresh
## temp directory and nothing mocked:
##   1. the first build writes the file's first value (control: the edge
##      runs and the substitution happens);
##   2. a second build with the file unchanged launches nothing (control:
##      the key is stable, so the next case's launch is the file, not noise),
##      and its lowered graph was served from the on-disk cache;
##   3. after the file changes, the next build -- which reuses the same
##      cached lowered graph -- launches the edge and writes the NEW value;
##   4. the lowered-graph cache file holds the literal `@FILE:` token and
##      neither value the file ever held.
##
## Falsifiability: with the substitution back in the lowering
## (`expandArgFiles(literalArgv, ...)` in `lowerGraphAction`'s inline-exec
## branch), case 3 writes `first-value` again and case 4 finds it in the
## cache file.
##
## Skip rule: `sh` missing on PATH, or `build/bin/repro` unbuilt -- except in
## a gate run (`REPROBUILD_GATE_RUN=1`), where either FAILS the case.

import std/[monotimes, os, osproc, strtabs, strutils, tempfiles, times,
  unittest]

import repro_test_support/reasoned_skip

const
  ReprobuildRepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
  reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

const Recipe = """
import repro_project_dsl

package atFileProbe:
  defaultToolProvisioning "path"
  build:
    let probe = buildAction(id = "probe.atfile",
      call = inlineExecCall(@["/bin/sh", "-c",
        "printf %s \"$1\" > build/token.txt", "sh", "@FILE:TOKEN_PATH"],
        activeProviderProjectRoot()),
      outputs = @["build/token.txt"],
      cacheable = true)
    defaultBuildAction(probe)
"""

proc recipeFor(tokenPath: string): string =
  ## The edge prints its one substituted argument into an output, so what
  ## the spawned process received is observable as a file.
  Recipe.replace("TOKEN_PATH", tokenPath)

proc runBuild(root, project: string): tuple[code: int, output: string] =
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): env[key] = value
  env["REPROBUILD_WORK_ROOT"] = root / "work"
  env["REPROBUILD_ACTION_CACHE_ROOT"] = root / "action-cache"
  env["REPRO_LOCAL_STORE"] = root / "store"
  env["REPRO_STORE_ROOT"] = root / "cas"
  env["REPRO_CACHE_DISABLE"] = "1"
  env.del("REPRO_VARIANTS")
  env["PATH"] = reproBinary.parentDir & PathSep & getEnv("PATH")
  let log = root / ("build-" & $getMonoTime().ticks & ".log")
  let argv = @[reproBinary, "build", "--daemon=off", "--progress=quiet",
    "--log=actions"]
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

proc loweredGraphCacheFiles(roots: openArray[string]): seq[string] =
  ## Every lowered-graph cache file (`<outDir>/lowered-graph-cache/*.rbbg`)
  ## the builds wrote, wherever the out dir was placed.
  for root in roots:
    for path in walkDirRec(root):
      if path.endsWith(".rbbg") and
          path.parentDir.extractFilename == "lowered-graph-cache":
        result.add(path)

proc cacheFileTimes(paths: openArray[string]): seq[(string, Time)] =
  for path in paths:
    result.add((path, getFileInfo(path).lastWriteTime))

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

suite "an @FILE: argument, through a warm lowered graph":

  test "a changed @FILE: file reaches the next build and never the graph cache":
    requireBuiltRepro:
      let root = createTempDir("atfile-warm-graph-", "")
      defer: removeDir(root)
      let tokenPath = root / "token"
      let project = root / "proj"
      createDir(project / "build")
      writeFile(project / "repro.nim", recipeFor(tokenPath))
      writeFile(tokenPath, "first-value\n")

      # 1. The edge runs and receives the file's contents.
      let first = runBuild(root, project)
      checkpoint(first.output)
      require first.code == 0
      check launchedActions(first.output) >= 1
      check readFile(project / "build" / "token.txt") == "first-value"
      let cacheFiles = loweredGraphCacheFiles([root / "work", project])
      require cacheFiles.len > 0
      let lowered = cacheFileTimes(cacheFiles)

      # 2. Control: unchanged file, nothing launches, and the lowered graph
      # is the one cached on disk (no cache file was rewritten).
      let again = runBuild(root, project)
      checkpoint(again.output)
      require again.code == 0
      check launchedActions(again.output) == 0
      check cacheFileTimes(cacheFiles) == lowered

      # 3. The file changes and nothing else does: the warm graph is reused,
      # and the edge still sees the new value.
      writeFile(tokenPath, "second-value\n")
      let changed = runBuild(root, project)
      checkpoint(changed.output)
      require changed.code == 0
      check cacheFileTimes(cacheFiles) == lowered
      check launchedActions(changed.output) >= 1
      check readFile(project / "build" / "token.txt") == "second-value"

      # 4. The cached graph keeps the literal token, not the value.
      for path in loweredGraphCacheFiles([root / "work", project]):
        let bytes = readFile(path)
        checkpoint(path)
        check ("@FILE:" & tokenPath) in bytes
        check "first-value" notin bytes
        check "second-value" notin bytes
