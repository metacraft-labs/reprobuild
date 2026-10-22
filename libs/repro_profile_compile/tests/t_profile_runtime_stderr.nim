## The profile runtime's stdout is the intent; stderr is diagnostic text.
## Drive real Nim compilation and the production helper, including output
## larger than either pipe buffer so sequential draining cannot pass.
import std/[os, osproc, strutils, tables, tempfiles, unittest]
from repro_core/process_streams import drainStream
import repro_profile
import repro_profile_compile/[compile, helper]

const ProjectRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir

if paramCount() > 0 and paramStr(1) == "--profile-helper":
  quit(runProfileCompileHelper(commandLineParams()[1 .. ^1]))

const IntentBody = """
import repro_profile
profile "stderrProfile":
  resources:
    fsUserFile(hostFile = "~/stderr-marker.txt", content = "intent payload")
"""

proc expectedLargeStderr(payloadBytes: int): string =
  if payloadBytes == 0: "" else: "large:" & repeat('l', payloadBytes) & "\n"

proc runProfileBinaryOnce(binary: string; payloadBytes: int): int =
  ## Child mode of the fresh-process regression below: run the compiled
  ## profile once through `runProfileBinary` and verify the capture. The
  ## result is DESTROYED when this proc returns -- before `quit` -- which is
  ## the free that used to crash.
  let res = runProfileBinary(binary)
  if res.exitCode != 0:
    echo "profile binary exited ", res.exitCode
    return 2
  if res.stderrText != expectedLargeStderr(payloadBytes):
    echo "stderr capture differs: ", res.stderrText.len, " bytes, wanted ",
      expectedLargeStderr(payloadBytes).len
    return 3
  if parseProfileIntentJson(res.output).name != "stderrProfile":
    echo "stdout is not the intent"
    return 4
  0

if paramCount() == 3 and paramStr(1) == "--run-profile-binary":
  quit(runProfileBinaryOnce(paramStr(2), parseInt(paramStr(3))))

proc compileIn(root, body: string): tuple[jsonOutput, stderrText: string] =
  let profile = root / "home.nim"
  writeFile(profile, body)
  compileProfileBinary(profile, root / "nimcache", root / "profile-build",
    ProjectRoot)

proc helperIn(root, body: string): tuple[output, stderrText: string; exitCode: int] =
  let profile = root / "home.nim"
  writeFile(profile, body)
  let p = startProcess(getAppFilename(), args = @["--profile-helper",
    "--profile", profile, "--rbpi", root / "profile.rbpi",
    "--nimcache", root / "nimcache", "--repo-root", ProjectRoot],
    options = {})
  # Helper fixtures emit only bounded stderr and no stdout. Read stderr
  # first so the assertions independently verify the diagnostic channel.
  result.stderrText = drainStream(p.errorStream)
  result.output = drainStream(p.outputStream)
  result.exitCode = p.waitForExit()
  p.close()

suite "profile runtime stderr":
  test "stderr before the intent is captured separately and RBPI encodes":
    let root = createTempDir("repro profile stderr-", "")
    defer: removeDir(root)
    let res = compileIn(root,
      "stderr.writeLine(\"profile: note on stderr\")\n" & IntentBody)
    check "profile: note on stderr" notin res.jsonOutput
    check "profile: note on stderr" in res.stderrText
    let intent = parseProfileIntentJson(res.jsonOutput)
    check intent.name == "stderrProfile"
    check intent.resources.len == 1
    check rbpiBytesFromJson(res.jsonOutput).len > 0

  test "large stderr before and after large stdout drains both pipes":
    let root = createTempDir("repro-profile-stderr-large-", "")
    defer: removeDir(root)
    let res = compileIn(root,
      "import repro_profile\nimport std/strutils\n" &
      "stderr.writeLine(\"before:\" & repeat('a', 262144))\n" &
      # The profile macro quits after emitting; use the same emitter
      # explicitly so this fixture can also write stderr after its JSON.
      "var intent = ProfileIntent(name: \"stderrProfile\")\n" &
      "fsUserFile(intent.resources, hostFile = \"~/stderr-marker.txt\", " &
      "content = repeat('x', 262144))\n" &
      "stdout.writeLine(emitProfileIntentJson(intent))\n" &
      "stderr.writeLine(\"after:\" & repeat('b', 262144))\n")
    check "before:" notin res.jsonOutput
    check "after:" notin res.jsonOutput
    check ("before:" & repeat('a', 262144) & "\n") in res.stderrText
    check ("after:" & repeat('b', 262144) & "\n") in res.stderrText
    let intent = parseProfileIntentJson(res.jsonOutput)
    check intent.resources.len == 1
    check intent.resources[0].fields["content"].s == repeat('x', 262144)
    check rbpiBytesFromJson(res.jsonOutput).len > 262144

  test "runtime failure retains stdout and stderr including final bursts":
    let root = createTempDir("repro-profile-stderr-fail-", "")
    defer: removeDir(root)
    var failed = false
    try:
      discard compileIn(root, "import std/strutils\n" &
        "stderr.writeLine(\"failure:\" & repeat('e', 262144))\n" &
        "stdout.writeLine(\"runtime stdout detail\")\n" &
        "stderr.writeLine(\"runtime stderr tail\")\nquit(7)\n")
    except CompileFailure as err:
      failed = true
      check "exited 7" in err.msg
      check ("failure:" & repeat('e', 262144)) in err.stderrText
      check "runtime stdout detail" in err.stderrText
      check "runtime stderr tail" in err.stderrText
    check failed

  # REGRESSION: the runtime capture must not free memory owned by a thread
  # that has already exited. Its stderr reader used to build the captured
  # text in a Nim string on the READER's ORC heap; the reader exited at
  # `joinThread`, and the caller freed that string when the result was
  # destroyed, which made Nim's allocator write into the dead thread's
  # region (`rawDealloc` -> `addToSharedFreeList`). On Windows the region
  # is thread-local storage the loader releases at thread exit, and the
  # profile compile died with a SIGSEGV whether or not the profile wrote
  # anything to stderr.
  #
  # EACH RUN IS A FRESH PROCESS. Whether the write into released memory
  # faults depends on the state of the process heap: in a fresh process
  # (the shape of the real `repro` helper) it faulted on every run measured
  # on eli-pc, while the same loop inside this long-lived test process
  # survived 25 runs on the unfixed code. So the binary is compiled once
  # and run `FreshProcessRuns` times, each in a child of this test
  # (`--run-profile-binary`) that captures it once and exits.
  const FreshProcessRuns = 10

  proc runInFreshProcesses(body: string; payloadBytes: int):
      seq[tuple[output: string; exitCode: int]] =
    ## Compile `body` once, then run the binary in `FreshProcessRuns`
    ## children (`--run-profile-binary`); returns each child's exit code and
    ## its own diagnostic output.
    let root = createTempDir("repro-profile-stderr-fresh-", "")
    defer: removeDir(root)
    discard compileIn(root, body)
    for i in 1 .. FreshProcessRuns:
      let p = startProcess(getAppFilename(), args = @["--run-profile-binary",
        root / "profile-build", $payloadBytes], options = {poStdErrToStdOut})
      try:
        let output = drainStream(p.outputStream)
        result.add((output: output, exitCode: p.waitForExit()))
      finally:
        p.close()

  test "fresh-process runtime captures with an EMPTY stderr":
    for run in runInFreshProcesses(IntentBody, 0):
      checkpoint(run.output)
      check run.exitCode == 0

  test "fresh-process runtime captures with a LARGE stderr":
    let body = "import std/strutils\n" &
      "stderr.writeLine(\"large:\" & repeat('l', 262144))\n" & IntentBody
    for run in runInFreshProcesses(body, 262144):
      checkpoint(run.output)
      check run.exitCode == 0

  test "helper forwards runtime diagnostics on successful encoding":
    let root = createTempDir("repro-profile-stderr-helper-", "")
    defer: removeDir(root)
    let res = helperIn(root, "stderr.writeLine(\"success warning\")\n" & IntentBody)
    checkpoint(res.stderrText)
    check res.exitCode == 0
    check res.output.len == 0
    check "success warning" in res.stderrText
    check rbpiEnvelopeIsValid(root / "profile.rbpi")

  test "helper retains stderr when stdout is malformed JSON":
    let root = createTempDir("repro-profile-stderr-json-", "")
    defer: removeDir(root)
    let res = helperIn(root, "stderr.writeLine(\"malformed stdout diagnostic\")\n" &
      "stdout.writeLine(\"not intent json\")\n")
    check res.exitCode == 1
    check "failed to encode RBPI envelope" in res.stderrText
    check "malformed stdout diagnostic" in res.stderrText
    check not fileExists(root / "profile.rbpi")

  test "helper identifies missing stdout intent and retains stderr":
    let root = createTempDir("repro-profile-stderr-empty-", "")
    defer: removeDir(root)
    let res = helperIn(root, "stderr.writeLine(\"missing emitter diagnostic\")\n")
    check res.exitCode == 1
    check "printed no ProfileIntent JSON on stdout" in res.stderrText
    check "missing emitter diagnostic" in res.stderrText
    check not fileExists(root / "profile.rbpi")
