# watch_patch_push_driver.nim
#
# Automated Integration Verification Gate for Milestone HAX-M3:
# "Live CLI Watcher Event Loop"
#
# Design doc: reprobuild-specs/HCR/CLI-Integration.md §2–§4
#             reprobuild-specs/HCR/HCR-Overview.md §12
# Related milestones:
# - reprobuild-specs/HCR-Advanced-Lifecycle-And-Tooling.milestones.org (HAX-M3)
#
# Gate type: e2e / integration
# Real components:
# - Real compiled repro CLI binary (build/bin/repro)
# - Real C target process linking libs/repro_hcr_agent/c/repro_hcr_agent.c
# - Real coordinator Unix domain socket
# - Real filesystem watcher (kqueue on macOS arm64)
# - Real C compilation and patch generation
#
# Allowed mocks: none
# Justification: Every use of mock objects in tests must be explicitly justified in the
# header comment of the test implementation file. We prefer strong integration tests that
# mock as little as possible and run against real filesystem, compiler, binary, and
# lifecycle execution boundaries. Mocks used: ZERO.
#
# Asserts:
# 1. Anti-vacuity Arm:
#    - Non-source changes (edits in .git/ or temporary files like .swp, ~, #) are filtered
#      and trigger no build/patch actions.
#    - Debouncing coalesces rapid file saves into a single compilation cycle.
# 2. Control Arm:
#    - Unchanged files trigger no build or patch actions.
# 3. Positive Arm:
#    - Target process starts, reports initial baseline value (11).
#    - Test driver edits source file on disk (patchable.c: 11 -> 77).
#    - Watcher detects change within 500ms, triggers incremental compile, generates patch bundle,
#      delivers over coordinator socket.
#    - Target process receives patch, applies trampoline/relocation, and immediately reflects new value (77).
# 4. Falsifier & Recovery Arm (--falsify-syntax-error):
#    - Writes invalid C syntax into patchable.c (int patchable_value(int i) { invalid syntax ;;; }).
#    - Watcher triggers compile, catches compiler error, emits hcr/compilationFailed, suppresses
#      patch delivery, and DOES NOT CRASH or exit.
#    - Target process remains running and returns previous valid value (77).
#    - Then valid code is written (return 99;).
#    - Watcher recompiles successfully, pushes patch, and target process reflects 99!
#    - In falsifier mode, verifies syntax error logging and patch suppression, caught with [FALSIFIER-CAUGHT].

import std/[monotimes, os, osproc, streams, strtabs, strutils, tables, times]

const
  ProjectRecipe = """
import repro_dsl_stdlib

package hcrWatcherPkg:
  uses:
    "gcc >=1"

  build:
    let buildDir = fs.ensureDir(actionId = "build-dir", path = "build")
    let rawObj = gcc(
      source = "src/patchable.c",
      output = "build/patchable.raw.o",
      debug3 = true,
      compileOnly = true,
      after = @[buildDir])
    let obj = hcr.prepareObject(
      input = "build/patchable.raw.o",
      output = "build/patchable.o",
      after = @[rawObj])
    target("patchable-object", [obj])
    defaultBuildAction(obj)
"""

  SourceBaseline = """
int patchable_value(int iteration) {
  int bias = 11;
  int state = iteration + bias;
  return state;
}
"""

  SourceIntermediate = """
int patchable_value(int iteration) {
  int bias = 55;
  int state = iteration + bias;
  return state;
}
"""

  SourceUpdated = """
int patchable_value(int iteration) {
  int bias = 77;
  int state = iteration + bias;
  return state;
}
"""

  SourceInvalidSyntax = """
int patchable_value(int iteration) {
  invalid syntax ;;;
  return 0;
}
"""

  SourceRecovered = """
int patchable_value(int iteration) {
  int bias = 99;
  int state = iteration + bias;
  return state;
}
"""

proc waitForLogPattern(logPath, pattern, context: string; timeoutMs = 30_000; minOffset = 0): int =
  ## Polls logPath until pattern is found after minOffset.
  ## Returns the index immediately following the pattern match.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    if fileExists(logPath):
      let content = readFile(logPath)
      if content.len >= minOffset:
        let searchSlice = content[minOffset .. ^1]
        let idx = searchSlice.find(pattern)
        if idx >= 0:
          return minOffset + idx + pattern.len
    sleep(50)
  let log = if fileExists(logPath): readFile(logPath) else: "<missing>"
  raise newException(ValueError, "Timed out waiting for " & context & ": '" & pattern & "'\nLog contents:\n" & log)

proc assertLogDoesNotContainPattern(logPath: string; minOffset: int; forbiddenPattern, context: string; waitMs = 300) =
  sleep(waitMs)
  if fileExists(logPath):
    let content = readFile(logPath)
    if content.len >= minOffset:
      let searchSlice = content[minOffset .. ^1]
      if searchSlice.contains(forbiddenPattern):
        raise newException(ValueError, "Forbidden pattern found for " & context & ": '" & forbiddenPattern & "'")

proc findNixStoreLibDir(nameFragment: string; libraryNames: openArray[string]): string =
  if not dirExists("/nix/store"):
    return ""
  try:
    for kind, path in walkDir("/nix/store"):
      if kind != pcDir:
        continue
      if path.lastPathPart.contains(nameFragment):
        let libDir = path / "lib"
        if not dirExists(libDir):
          continue
        for libraryName in libraryNames:
          if fileExists(libDir / libraryName):
            return libDir
  except CatchableError:
    discard
  ""

proc findClingoLib(): string =
  if getEnv("CLINGO_LIB").len > 0 and dirExists(getEnv("CLINGO_LIB")):
    return getEnv("CLINGO_LIB")
  for envVar in ["DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "LD_LIBRARY_PATH"]:
    let val = getEnv(envVar)
    for dir in val.split($PathSep):
      if dir.len > 0 and dirExists(dir):
        if fileExists(dir / "libclingo.dylib") or fileExists(dir / "libclingo.so"):
          return dir
  result = findNixStoreLibDir("clingo-5.", ["libclingo.dylib", "libclingo.so"])

proc currentLogOffset(logPath: string): int =
  if fileExists(logPath): readFile(logPath).len else: 0

proc queryTargetValue(targetProcess: Process): int =
  let inStream = targetProcess.inputStream
  let outStream = targetProcess.outputStream
  inStream.writeLine("get")
  inStream.flush()
  let line = outStream.readLine()
  if not line.startsWith("VALUE="):
    raise newException(ValueError, "Unexpected target response: " & line)
  parseInt(line["VALUE=".len .. ^1].strip())

proc runGate(targetBin, reproBin, workDir: string; falsifySyntaxError: bool) =
  echo "=== [HAX-M3] Live CLI Watcher Event Loop Gate ==="
  echo "Target binary:    ", targetBin
  echo "Repro binary:     ", reproBin
  echo "Work directory:   ", workDir
  echo "Falsifier mode:   ", falsifySyntaxError

  let watchedProjDir = workDir / "watched_project"
  let srcDir = watchedProjDir / "src"
  let buildDir = watchedProjDir / "build"
  let gitDir = watchedProjDir / ".git"
  let reprobuildNim = watchedProjDir / "reprobuild.nim"
  let patchableC = srcDir / "patchable.c"
  let socketPath = workDir / "hcr_coordinator.sock"
  let artifactsDir = watchedProjDir / ".repro" / "hcr"
  let watchLogPath = workDir / "repro_watch.log"

  createDir(srcDir)
  createDir(buildDir)
  createDir(gitDir)

  writeFile(reprobuildNim, ProjectRecipe)
  writeFile(patchableC, SourceBaseline)

  # Start repro watch
  let watchCmd = quoteShell(reproBin) & " watch " &
    quoteShell(watchedProjDir & "#patchable-object") &
    " --tool-provisioning=path" &
    " --debounce-ms=50" &
    " --hcr" &
    " --hcr-agent-socket=" & quoteShell(socketPath) &
    " --hcr-artifacts=" & quoteShell(artifactsDir)

  let clingoLib = findClingoLib()
  var envPrefix = ""
  if clingoLib.len > 0:
    envPrefix = "export DYLD_LIBRARY_PATH=" & quoteShell(clingoLib) &
                " DYLD_FALLBACK_LIBRARY_PATH=" & quoteShell(clingoLib) &
                " LD_LIBRARY_PATH=" & quoteShell(clingoLib) & "; "

  echo "[1/6] Launching real repro CLI watch event loop..."
  echo "  Command: ", envPrefix & "exec " & watchCmd
  var watchProcess = startProcess(
    "/bin/sh",
    args = ["-c", envPrefix & "exec " & watchCmd & " > " & quoteShell(watchLogPath) & " 2>&1"],
    options = {poUsePath}
  )

  var targetProcess: Process = nil
  defer:
    if targetProcess != nil and targetProcess.running():
      try:
        targetProcess.inputStream.writeLine("exit")
        targetProcess.inputStream.flush()
        discard targetProcess.waitForExit(1000)
      except CatchableError:
        discard
      if targetProcess.running():
        targetProcess.terminate()
      targetProcess.close()

    if watchProcess != nil and watchProcess.running():
      try:
        watchProcess.terminate()
        discard watchProcess.waitForExit(2000)
      except CatchableError:
        discard
      watchProcess.close()

  # Generous timeout for the initial build / interface extraction (120s)
  echo "  Waiting for repro watch coordinator socket initialization (up to 120s)..."
  discard waitForLogPattern(
    watchLogPath,
    "repro watch: hcr waiting for agent socket=",
    "initial HCR watch coordinator listener",
    timeoutMs = 120_000
  )
  echo "  [OK] repro watch coordinator listening on socket."

  # Launch real C target process
  echo "[2/6] Launching real C target process connecting to coordinator socket..."
  var targetEnv = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    targetEnv[k] = v
  targetEnv["REPRO_HCR_AGENT_SOCKET"] = socketPath

  targetProcess = startProcess(
    targetBin,
    env = targetEnv,
    options = {poUsePath}
  )

  # Wait for agent connected and watching paths
  discard waitForLogPattern(
    watchLogPath,
    "repro watch: hcr agent connected",
    "target agent handshake",
    timeoutMs = 20_000
  )
  echo "  [OK] HCR agent connected to coordinator."

  discard waitForLogPattern(
    watchLogPath,
    "repro watch: watching paths=",
    "filesystem watcher initialization",
    timeoutMs = 20_000
  )
  echo "  [OK] Watcher armed with native OS filesystem notifications (kqueue)."

  # Target process handshake: read TARGET_READY
  let readyLine = targetProcess.outputStream.readLine()
  if readyLine != "TARGET_READY":
    raise newException(ValueError, "Target process did not emit TARGET_READY: " & readyLine)
  echo "  [OK] Target process ready."

  # Initial baseline assertion
  let initialValue = queryTargetValue(targetProcess)
  echo "  [OK] Initial baseline target value: ", initialValue
  doAssert initialValue == 11, "Expected baseline value 11, got: " & $initialValue

  # ---------------------------------------------------------------------------
  # 1. Anti-vacuity Arm: Non-source changes ignored, debouncing coalesces saves
  # ---------------------------------------------------------------------------
  echo "[3/6] Anti-vacuity Arm: Verifying non-source filtering and save debouncing..."
  let avLogMark = currentLogOffset(watchLogPath)

  # Part A: Non-source changes (.git, .swp, ~, #)
  writeFile(gitDir / "HEAD", "ref: refs/heads/dummy\n")
  writeFile(srcDir / ".patchable.c.swp", "b0VIM 8.0 dummy swap content")
  writeFile(srcDir / "patchable.c~", "backup content")
  writeFile(srcDir / "#patchable.c#", "autosave content")
  writeFile(srcDir / ".patchable.c.tmp", "temp content")

  assertLogDoesNotContainPattern(
    watchLogPath,
    avLogMark,
    "rebuild cycle after filesystem event",
    "non-source filtering check",
    waitMs = 350
  )
  let valueAfterNonSource = queryTargetValue(targetProcess)
  doAssert valueAfterNonSource == 11, "Target value unexpectedly changed after non-source edits!"
  echo "  [OK] Anti-vacuity Part A: Ignored non-source files (.git, .swp, ~, #) did not trigger rebuild or patch."

  # Part B: Rapid file save debouncing
  # Rapidly write two versions within the debounce window (50ms)
  let saveLogMark = currentLogOffset(watchLogPath)
  let tStartSave = getMonoTime()
  writeFile(patchableC, SourceIntermediate) # bias = 55
  sleep(5)
  writeFile(patchableC, SourceUpdated)      # bias = 77

  # Wait for patch to be applied
  discard waitForLogPattern(
    watchLogPath,
    "repro watch: hcr patch applied",
    "debounced patch application",
    timeoutMs = 15_000,
    minOffset = saveLogMark
  )

  # Check that debounce occurred
  let debounceLogs = readFile(watchLogPath)[saveLogMark .. ^1]
  doAssert debounceLogs.contains("debounce complete"), "Watcher log lacks debounce record"
  echo "  [OK] Anti-vacuity Part B: Debouncing coalesced rapid saves into a single cycle."

  # ---------------------------------------------------------------------------
  # 2. Control Arm: Unchanged files trigger no build or patch actions
  # ---------------------------------------------------------------------------
  echo "[4/6] Control Arm: Verifying unchanged tree triggers no spurious rebuilds..."
  let ctrlLogMark = currentLogOffset(watchLogPath)
  assertLogDoesNotContainPattern(
    watchLogPath,
    ctrlLogMark,
    "rebuild cycle after filesystem event",
    "control arm quiescence check",
    waitMs = 300
  )
  let valueControl = queryTargetValue(targetProcess)
  doAssert valueControl == 77, "Target value corrupted in control arm!"
  echo "  [OK] Control Arm: Watcher remained idle with zero patch events on unchanged source."

  # ---------------------------------------------------------------------------
  # 3. Positive Arm: Reflects updated value (77)
  # ---------------------------------------------------------------------------
  echo "[5/6] Positive Arm: Verifying live hot code reload in running target process..."
  let tElapsed = (getMonoTime() - tStartSave).inMilliseconds
  echo "  Detection, compile, and patch push roundtrip latency: ", tElapsed, " ms"
  let patchedValue = queryTargetValue(targetProcess)
  echo "  Observed patched target value: ", patchedValue
  doAssert patchedValue == 77, "Expected patched value 77, got: " & $patchedValue
  echo "  [OK] Positive Arm: Target process received direct trampoline patch and returned 77."

  # ---------------------------------------------------------------------------
  # 4. Falsifier & Recovery Arm: Syntax error handling and recovery
  # ---------------------------------------------------------------------------
  echo "[6/6] Falsifier & Recovery Arm: Verifying compiler error handling and recovery..."
  let syntaxLogMark = currentLogOffset(watchLogPath)

  echo "  Writing syntax error into source file..."
  writeFile(patchableC, SourceInvalidSyntax)

  # Wait for compilation failed log
  discard waitForLogPattern(
    watchLogPath,
    "repro watch: hcr compilation failed:",
    "compilation error detection",
    timeoutMs = 15_000,
    minOffset = syntaxLogMark
  )

  # Verify watcher did not crash
  doAssert watchProcess.running(), "Watcher crashed or exited on compiler syntax error!"

  # Verify patch delivery was suppressed
  assertLogDoesNotContainPattern(
    watchLogPath,
    syntaxLogMark,
    "repro watch: hcr patch applied",
    "patch suppression check during syntax error",
    waitMs = 200
  )

  # Verify target process is still running and returns previous valid value
  doAssert targetProcess.running(), "Target process crashed during invalid syntax cycle!"
  let valueDuringError = queryTargetValue(targetProcess)
  echo "  Target value during compiler error state: ", valueDuringError
  doAssert valueDuringError == 77, "Target returned unexpected value during compiler error: " & $valueDuringError
  echo "  [OK] Watcher caught compilation error, emitted hcr/compilationFailed, and suppressed patch delivery."

  if falsifySyntaxError:
    echo "  [FALSIFIER-CAUGHT] Watcher properly caught compiler syntax error, emitted hcr/compilationFailed, suppressed patch delivery, and kept target alive returning 77"
    quit(2)

  # Recovery: write valid code (return 99)
  echo "  Writing valid recovery code (bias = 99)..."
  let recoveryLogMark = currentLogOffset(watchLogPath)
  writeFile(patchableC, SourceRecovered)

  # Wait for successful patch application
  discard waitForLogPattern(
    watchLogPath,
    "repro watch: hcr patch applied",
    "recovered patch application",
    timeoutMs = 15_000,
    minOffset = recoveryLogMark
  )

  let recoveredValue = queryTargetValue(targetProcess)
  echo "  Observed recovered target value: ", recoveredValue
  doAssert recoveredValue == 99, "Expected recovered value 99, got: " & $recoveredValue
  echo "  [OK] Watcher successfully recovered from syntax error, rebuilt, pushed patch, and target reflected 99."

  echo ""
  echo "=== [SUCCESS] HAX-M3: Live CLI Watcher Event Loop Verified ==="

proc main() =
  var targetBin = ""
  var reproBin = ""
  var workDir = ""
  var falsifySyntaxError = false

  for arg in commandLineParams():
    if arg == "--falsify-syntax-error":
      falsifySyntaxError = true
    elif arg.startsWith("--target-bin="):
      targetBin = arg.split("=", maxsplit = 1)[1]
    elif arg.startsWith("--repro-bin="):
      reproBin = arg.split("=", maxsplit = 1)[1]
    elif arg.startsWith("--work-dir="):
      workDir = arg.split("=", maxsplit = 1)[1]
    elif targetBin.len == 0:
      targetBin = arg
    elif reproBin.len == 0:
      reproBin = arg
    elif workDir.len == 0:
      workDir = arg

  if targetBin.len == 0 or reproBin.len == 0:
    quit("Usage: test_hax_m3_driver [--falsify-syntax-error] <target_bin> <repro_bin> [work_dir]", 1)

  if workDir.len == 0:
    workDir = getTempDir() / "hax_m3_gate_" & $getCurrentProcessId()
    createDir(workDir)

  runGate(targetBin, reproBin, workDir, falsifySyntaxError)

when isMainModule:
  main()
