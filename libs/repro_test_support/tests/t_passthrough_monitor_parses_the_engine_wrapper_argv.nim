## The passthrough monitor driver (``repro_test_support/passthrough_monitor``)
## parses the argv the engine actually wraps a monitored action in, on the
## host's own shell: ``sh`` on POSIX, ``cmd.exe`` on Windows.
##
## The driver is a fixture other suites stand on -- every ``dgAutomaticMonitor``
## action in ``test_tool_identity_env_plumbing`` and in the profile-compile
## Phase G smoke runs through it -- so a parsing defect in it surfaces there
## as an unexplained ``asFailed`` action. That is how the positional Windows
## copy failed after the engine added ``--interest`` and ``--evidence``: the
## interest token was run as a program (reprobuild-pm
## ``issues/2026-11-16-windows-tool-identity-env-plumbing-probes-fail-on-eli-pc.md``).
## These cases pin the contract directly, with flags the driver does not know,
## a comma-separated value (cmd.exe splits arguments at commas), a depfile
## path with a space, and a payload whose own arguments carry a ``--``.
##
## No mocks: the driver is written by the real helper and run as a real child
## process through ``startProcess``, which is how the engine's bypass path
## reaches it too.

import std/[os, osproc, streams, strutils, tempfiles, unittest]

import repro_test_support/passthrough_monitor

proc runDriver(driver: string; args: openArray[string]): (int, string) =
  ## Run ``driver`` with ``args`` and return its exit code and merged output.
  ## Windows cannot ``CreateProcess`` a ``.cmd`` directly, so it goes through
  ## ``cmd /D /C`` there, as the engine's launcher does.
  let p =
    when defined(windows):
      startProcess("cmd", args = @["/D", "/C", driver] & @args,
        options = {poUsePath, poStdErrToStdOut})
    else:
      startProcess(driver, args = @args, options = {poStdErrToStdOut})
  defer: p.close()
  # Read to EOF before waiting: ``readAll`` on a pipe can stop at the first
  # short read, and waiting first could block on a full pipe.
  var output = ""
  let s = p.outputStream
  while not s.atEnd:
    output.add(s.readChar)
  result = (p.waitForExit(), output)

proc payloadArgv(marker: string): seq[string] =
  ## A payload that prints ``marker`` and every argument it was given, each
  ## framed by ``[`` ``]``, so the test sees exactly what reached it.
  when defined(windows):
    @["cmd", "/D", "/C", "echo", "[" & marker & "]", "--", "[after]"]
  else:
    @["sh", "-c", "printf '[%s]' \"$@\"", "payload", marker, "--", "after"]

suite "passthrough monitor driver":

  test "copies the evidence to --depfile and runs the argv after the first --":
    let root = createTempDir("passthrough-monitor-", "")
    defer: removeDir(root)
    # No space in the driver's own directory: ``cmd /C`` strips the outer
    # quotes of a quoted first token followed by more quoted arguments, which
    # is a property of this test's launcher, not of the driver.
    let dir = root / "monitor-cli"
    createDir(dir)
    let evidence = dir / "empty.rmdf"
    writeFile(evidence, "evidence-bytes")
    let driver = writePassthroughMonitorCli(dir, evidence)
    let depfile = root / "deps with space" / "nested" / "capture.iomon"

    # The engine's wrapper shape: flags before ``--`` that the driver does
    # not know, one of them carrying a comma list, ``--depfile`` among them
    # but not first.
    let (code, output) = runDriver(driver,
      @["--interest", "file-reads,proc,lib", "--depfile", depfile,
        "--evidence", "full", "--future-flag", "value", "--"] &
      payloadArgv("payload-ran"))
    check code == 0
    check "[payload-ran]" in output
    # The payload received its own ``--`` and what followed it: the driver
    # split at the FIRST ``--`` only.
    when defined(windows):
      check "-- [after]" in output
    else:
      check "[--][after]" in output
    # The flags before ``--`` never reached the payload.
    check "file-reads" notin output
    check "future-flag" notin output
    check fileExists(depfile) and readFile(depfile) == "evidence-bytes"

  test "refuses an argv with no -- instead of running its flags":
    let root = createTempDir("passthrough-monitor-", "")
    defer: removeDir(root)
    let evidence = root / "empty.rmdf"
    writeFile(evidence, "evidence-bytes")
    let driver = writePassthroughMonitorCli(root, evidence)
    let depfile = root / "capture.iomon"
    # ``echo`` would print "not-a-separator" if the driver ran its arguments.
    let (code, output) = runDriver(driver,
      @["--depfile", depfile, "echo", "not-a-separator"])
    check code == 2
    check "no -- separates the action argv" in output
    check "not-a-separator" notin output
    check not fileExists(depfile)
