## t_build_progress_modes —
## Test the new progress reporting modes: simple-dots, dots, simple-lines, live-lines.
## Asserts output format under different progress configurations and --unicode switches.

import std/[os, osproc, strutils, tempfiles, unittest]

const RepoMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and
        fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc runBuild(reproBin, repoRoot: string; progressMode: string; workRoot: string; extraArgs: seq[string] = @[]): tuple[output: string; exitCode: int] =
  let tempCache = createTempDir("repro-progress-cache-", "")
  defer: removeDir(tempCache)
  
  var args = @[
    reproBin,
    "build",
    ".#test-helpers",
  ]
  if progressMode.len > 0:
    args.add("--progress=" & progressMode)
  args.add("--no-runquota")
  args.add("--tool-provisioning=path")
  args.add("--action-cache-root=" & tempCache)
  args.add("--work-root=" & workRoot)
  for arg in extraArgs:
    args.add(arg)
  let cmd = args.join(" ")
  let res = execCmdEx(cmd, workingDir = repoRoot)
  (output: res.output, exitCode: res.exitCode)

suite "t_build_progress_modes":
  test "verify advanced progress reporting modes":
    let repoRoot = findRepoRoot()
    let reproBin = repoRoot / "build" / "bin" / addFileExt("repro", ExeExt)
    
    if not fileExists(reproBin):
      checkpoint("skipped — " & reproBin & " is missing; run `just build` first")
      skip()
    else:
      let tempRoot = createTempDir("repro-progress-root-", "")
      defer: removeDir(tempRoot)
      let workRoot = tempRoot / "work"
      createDir(workRoot)

      # 1. Test `simple-dots` with real execution (cold cache)
      # We want to see dots representing completion of launched actions.
      let dotsRes = runBuild(reproBin, repoRoot, "simple-dots", workRoot)
      check dotsRes.exitCode == 0
      # Verify that dots were output to stderr (captured in output)
      check dotsRes.output.contains(".")

      # 2. Test `simple-lines` with --dry-run
      # We want to see "Starting: " and "Finished: " lines with elapsed time.
      let linesRes = runBuild(reproBin, repoRoot, "simple-lines", workRoot, @["--dry-run"])
      check linesRes.exitCode == 0
      check linesRes.output.contains("Starting:")
      check linesRes.output.contains("Finished:")
      check linesRes.output.contains(" ms") or linesRes.output.contains(" s")

      # 3. Test `live-lines` with --dry-run and --unicode
      # We want to see completed lines ending with unicode checkboxes like [✓]
      let liveUnicodeRes = runBuild(reproBin, repoRoot, "live-lines", workRoot, @["--dry-run", "--unicode"])
      check liveUnicodeRes.exitCode == 0
      check liveUnicodeRes.output.contains("[✓]") or liveUnicodeRes.output.contains("[✗]")

      # 4. Test `live-lines` with --dry-run and --no-unicode
      # We want to see completed lines ending with ASCII indicators like [OK]
      let liveAsciiRes = runBuild(reproBin, repoRoot, "live-lines", workRoot, @["--dry-run", "--no-unicode"])
      check liveAsciiRes.exitCode == 0
      check liveAsciiRes.output.contains("[OK]") or liveAsciiRes.output.contains("[FAIL]")

      # 5. Test `dots` mode with --dry-run
      # We want to see dots representation (bright or pale dots)
      let paleDotsRes = runBuild(reproBin, repoRoot, "dots", workRoot, @["--dry-run"])
      check paleDotsRes.exitCode == 0
      check paleDotsRes.output.contains(".")

      # 6. Test `IN_AGENT_SHELL` override (defaults to quiet mode)
      putEnv("IN_AGENT_SHELL", "1")
      let agentShellRes = runBuild(reproBin, repoRoot, "", workRoot, @["--dry-run"])
      delEnv("IN_AGENT_SHELL")
      check agentShellRes.exitCode == 0
      # In quiet mode, stdout/stderr progress updates are suppressed
      check not agentShellRes.output.contains("Starting:")
      check not agentShellRes.output.contains("Finished:")
      check not agentShellRes.output.contains("[OK]")
      check not agentShellRes.output.contains("[✓]")
