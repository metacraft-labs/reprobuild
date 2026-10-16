## Run a test binary the way the suite runner does — one ``--list-json``
## probe, then every case in a process of its own — and report each process.
##
## This is the execution model a test file's fixtures have to survive. The
## runner (``tools/test-runner/repro_test_runner.nim``) asks each binary for
## its catalog with ``--list-json`` and then runs ``--run "<suite>::<test>"``
## once per case, each in a fresh process with ``NIMTEST_RESULT_FILE`` set.
## A property that holds when a binary runs all its cases in one process —
## "the last case removes what the first one created" — can be false in
## every one of those processes. Driving the binary through this module is
## how a test checks the model the runner actually uses rather than the one
## a reader assumes.
##
## The caller supplies the child environment, so it can point ``TMPDIR`` /
## ``HOME`` at a directory of its own and attribute anything left there to
## the binary under test rather than to whatever else shares the host.

import std/[json, os, osproc, strtabs, strutils]

type
  CaseProcess* = object
    ## One process this module started.
    name*: string
      ## The ``suite::test`` it ran; empty for the ``--list-json`` probe.
    pid*: int
    exitCode*: int
    output*: string
      ## Its standard output (on Windows, interleaved with standard error).
    errorOutput*: string
      ## Its standard error (POSIX; empty on Windows).

proc runOne(binary: string; args: openArray[string]; env: StringTableRef;
            name, outFile: string): CaseProcess =
  ## Start one process and wait for it.
  ##
  ## ON POSIX ITS OUTPUT GOES TO A FILE, NOT A PIPE. The processes this module
  ## exists to judge are the ones that leave a daemon behind, and a daemon
  ## that inherited the write end of a pipe keeps it open: reading the pipe
  ## to its end would then wait for the leaked daemon, i.e. forever, and the
  ## leak would surface as a hang instead of as a named survivor. ``exec``
  ## keeps the pid the shell was given, so ``pid`` is the binary's own.
  result.name = name
  when defined(posix):
    var shArgs = @["-c", "exec \"$0\" \"$@\" >" & quoteShell(outFile) &
      " 2>" & quoteShell(outFile & ".stderr"), binary]
    for a in args:
      shArgs.add(a)
    let p = startProcess("/bin/sh", args = shArgs, env = env,
                         options = {poParentStreams})
    result.pid = p.processID
    try:
      result.exitCode = p.waitForExit()
    finally:
      p.close()
    try:
      result.output = readFile(outFile)
    except CatchableError as err:
      result.output = "(could not read " & outFile & ": " & err.msg & ")"
    try:
      result.errorOutput = readFile(outFile & ".stderr")
    except CatchableError:
      discard
  else:
    let p = startProcess(binary, args = args, env = env,
                         options = {poStdErrToStdOut})
    result.pid = p.processID
    try:
      result.output = p.outputStream.readAll()
    finally:
      result.exitCode = p.waitForExit()
      p.close()

proc catalogCaseNames*(listJson: string): seq[string] =
  ## The ``name`` of every entry in a ``--list-json`` document. Both
  ## implementations in this tree (the protocol-carrying ``std/unittest`` and
  ## the ``ct_test_unittest_parallel`` shim) emit ``{"tests": [{"name":
  ## "<suite>::<test>", ...}]}``. Raises ``ValueError`` on anything else: a
  ## probe whose document cannot be read must not pass as "zero cases".
  # The document starts at the first line that opens an object; on Windows
  # stderr shares the stream, so a diagnostic may precede it.
  var start = if listJson.startsWith("{"): 0 else: listJson.find("\n{")
  if start > 0: inc start
  if start < 0:
    raise newException(ValueError, "no JSON document in --list-json output: " &
      listJson.strip())
  let doc = parseJson(listJson[start .. ^1])
  if doc.kind != JObject or not doc.hasKey("tests") or
      doc["tests"].kind != JArray:
    raise newException(ValueError,
      "--list-json output has no `tests` array: " & listJson.strip())
  for entry in doc["tests"]:
    result.add(entry["name"].getStr())

proc runEveryCaseInItsOwnProcess*(binary: string; env: StringTableRef;
                                  resultDir: string): seq[CaseProcess] =
  ## Probe ``binary`` with ``--list-json`` and then run each case it lists
  ## with ``--run``, one process per case, sequentially. ``env`` is the
  ## complete child environment (``nil`` inherits this process's); each case
  ## additionally gets ``NIMTEST_RESULT_FILE`` under ``resultDir``, which the
  ## caller should keep OUTSIDE any directory it inspects for leftovers.
  ##
  ## The probe is element 0 of the result, so a result of length 1 means the
  ## binary registers no case on this platform; the caller decides what that
  ## means. Raises when the probe itself fails, because "no cases ran" must
  ## not read as "nothing leaked".
  createDir(resultDir)
  let probe = runOne(binary, ["--list-json"], env, "",
                     resultDir / "list-json.out")
  result.add(probe)
  if probe.exitCode != 0:
    raise newException(OSError, binary & " --list-json exited " &
      $probe.exitCode & ": " & probe.output.strip() & " " &
      probe.errorOutput.strip())
  let names = catalogCaseNames(probe.output)
  for i, name in names:
    let caseEnv = newStringTable(modeCaseSensitive)
    if env == nil:
      for k, v in envPairs():
        caseEnv[k] = v
    else:
      for k, v in env.pairs:
        caseEnv[k] = v
    caseEnv["NIMTEST_RESULT_FILE"] = resultDir / ("case-" & $i & ".json")
    result.add(runOne(binary, ["--run", name], caseEnv, name,
                      resultDir / ("case-" & $i & ".out")))

proc processesMentioning*(needle: string): seq[string] =
  ## Live processes whose command line or working directory mentions
  ## ``needle``, as ``"<pid>: <cmdline>"``. This is how a daemon a test
  ## started and never stopped is found after the test is gone: it has been
  ## re-parented to init, but its argv still names the socket under the
  ## test's scratch tree.
  ##
  ## Linux only (``/proc``); elsewhere it returns nothing, and a caller that
  ## relies on it must say so rather than read the empty answer as "none".
  when defined(linux):
    for kind, path in walkDir("/proc"):
      if kind != pcDir:
        continue
      let pidText = path.extractFilename
      if pidText.len == 0 or not pidText.allCharsInSet(Digits):
        continue
      var cmdline = ""
      try:
        cmdline = readFile(path / "cmdline").replace('\0', ' ').strip()
      except CatchableError:
        continue          # exited while we looked, or not ours to read
      var cwd = ""
      try:
        cwd = expandSymlink(path / "cwd")
      except CatchableError:
        discard
      if needle in cmdline or (cwd.len > 0 and needle in cwd):
        result.add(pidText & ": " & cmdline)
  else:
    discard needle
