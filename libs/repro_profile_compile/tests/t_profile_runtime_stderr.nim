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
