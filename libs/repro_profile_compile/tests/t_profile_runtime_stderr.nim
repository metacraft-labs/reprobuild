## The profile runtime's stdout is the intent; stderr is diagnostic text.
## Drive real Nim compilation and the production helper, including output
## larger than either pipe buffer so sequential draining cannot pass.
##
## Since the profile compile was split into a compile edge and a run edge
## (reprobuild-pm `spec/Profile-Compilation-Model.md` §2), the production
## helper ONLY compiles; the cases that drive it check that it never runs the
## profile (the premise of the compile edge's entropy blessing). The run edge
## invokes the binary under the intent-output contract
## (`ReproIntentOutFlag`), checked here at the binary level. What the user
## sees when a profile emits no intent or fails at run time is now produced
## by `compileProfileToRbpi` from the run edge's result, and is checked
## end-to-end in `tests/e2e/m83/t_e2e_repro_profile_compile_via_action.nim`.
import std/[os, osproc, strutils, tables, tempfiles, unittest]
from repro_core/process_streams import drainStream, drainStdoutAndStderr
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

const helperBinaryName = addFileExt("profile-build", ExeExt)

proc helperIn(root, body: string): tuple[output, stderrText: string; exitCode: int] =
  ## Drive the production compile helper (`runProfileCompileHelper`, the
  ## compile edge's body) in a child of this test.
  let profile = root / "home.nim"
  writeFile(profile, body)
  let p = startProcess(getAppFilename(), args = @["--profile-helper",
    "--profile", profile, "--binary", root / helperBinaryName,
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

  test "the compile helper compiles and does NOT run the profile":
    # The compile edge carries the provider compile's entropy blessing, and
    # that is sound only because nothing in its process tree runs what it
    # compiled (reprobuild-pm `spec/Profile-Compilation-Model.md` §2.1). The
    # fixture writes a marker file and a stderr line when it RUNS; after the
    # helper neither exists, while the binary does.
    let root = createTempDir("repro-profile-stderr-helper-", "")
    defer: removeDir(root)
    let marker = root / "ran.marker"
    let res = helperIn(root, "writeFile(\"" & marker.replace('\\', '/') &
      "\", \"ran\")\nstderr.writeLine(\"runtime warning\")\n" & IntentBody)
    checkpoint(res.stderrText)
    check res.exitCode == 0
    check res.output.len == 0
    check fileExists(root / helperBinaryName)
    check not fileExists(marker)
    check "runtime warning" notin res.stderrText
    # Positive control: the same binary, run, does both.
    let run = runProfileBinary(root / helperBinaryName)
    check run.exitCode == 0
    check fileExists(marker)
    check "runtime warning" in run.stderrText
    check parseProfileIntentJson(run.output).name == "stderrProfile"

  test "the compile helper fails with nim's diagnostics and links nothing":
    let root = createTempDir("repro-profile-stderr-nimfail-", "")
    defer: removeDir(root)
    let res = helperIn(root, "import repro_profile\nthis is not nim\n")
    check res.exitCode == 1
    check "---- nim diagnostics ----" in res.stderrText
    check "nim compile failed" in res.stderrText
    check not fileExists(root / helperBinaryName)

  test "the intent-output contract writes the document to the named file":
    # `<binary> --repro-intent-out <path>` is how the run edge invokes a
    # profile: the document goes to the file (the edge's declared output),
    # stdout and stderr stay the profile's own. With no arguments the binary
    # prints the document on stdout, as Phase A defined.
    let root = createTempDir("repro-profile-intent-out-", "")
    defer: removeDir(root)
    let profile = root / "home.nim"
    writeFile(profile, "echo \"stdout chatter\"\n" &
      "stderr.writeLine(\"stderr chatter\")\n" & IntentBody)
    discard compileProfileExecutable(profile, root / "nimcache",
      root / helperBinaryName, ProjectRoot)
    let document = root / "intent.json"
    let p = startProcess(root / helperBinaryName,
      args = [ReproIntentOutFlag, document], options = {})
    let captured = drainStdoutAndStderr(p)
    check p.waitForExit() == 0
    p.close()
    check fileExists(document)
    let intent = parseProfileIntentJson(readFile(document))
    check intent.name == "stderrProfile"
    check intent.resources.len == 1
    # The document is NOT on stdout; the profile's own output is.
    check captured.output.strip() == "stdout chatter"
    check "stderr chatter" in captured.errorOutput
    # Without the flag, the same binary prints the document on stdout.
    let plain = runProfileBinary(root / helperBinaryName)
    check plain.exitCode == 0
    check plain.output.startsWith("stdout chatter")
    check readFile(document).strip() in plain.output
