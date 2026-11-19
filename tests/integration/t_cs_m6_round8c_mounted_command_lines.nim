## The command lines of round 8c of repro's move onto its description: the
## other programs' command lines repro mounts. The add-on's
## (`repro_infra/addon_command_line`, the static add-on binary's whole command
## line) is spliced under `repro system addon|state|secret|adopt`; io-mon's
## (`io_mon/cli_description`, io-mon's own binary's) under `repro debug io
## monitor` and `repro internal io monitor`.
##
## The arms, and what makes each one evidence:
##
##   1. repro's parser knows every verb and flag of the mounted command
##      lines: each parses into repro's typed configuration with the values
##      given, and a flag a verb does not declare, a missing required flag or
##      an unknown verb is a usage error (exit 2) in process.
##   2. The words a mounted command's handler hands over
##      (`reproWordsAfterMount`) parse, through the mounted program's own
##      generated parser, into the same values: the two parsers read one
##      declaration. Checked for the add-on's program (`ReproAddonCommandLine`)
##      over the command lines its systemd units, the apt hook, the confined
##      shipping run and the documented runbooks write, and for io-mon's
##      bare spawn form the build engine writes.
##   3. The static binary's own command line (`system adopt|rollback`,
##      `system state` -- the restore unit it writes, read from that unit's
##      text --, `infra plan|apply`, `store`, `--version`) and the
##      fingerprint tool's parse from their descriptions.
##   4. `repro <mounted command> --help`, `-h` and `repro help <command>` print
##      generated help (exit 0) naming the mounted verbs and flags, and an
##      unknown flag is clispec's error block (exit 2), through the real
##      `build/bin/repro`.
##
## No mocks: the generated parsers run in process, and the real
## `build/bin/repro` runs as a subprocess in an empty directory with a fresh
## HOME and XDG directories. No command line here gets past its parse into
## anything that changes the machine: every subprocess prints help or is
## refused.

import std/[options, os, strutils, tempfiles, unittest]

import repro_test_support

import repro_cli_support
import repro_cli_support/cli_program

import io_mon/cli as io_mon_cli

when defined(linux):
  import repro_addon/cli as addon_cli
  from repro_addon/adoption_cli import stateRestoreUnitText

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type Scratch = object
  cwd, home: string
  env: seq[(string, string)]

proc newScratch(): Scratch =
  result.cwd = createTempDir("repro-r8c-cwd-", "")
  result.home = createTempDir("repro-r8c-home-", "")
  let home = result.home
  result.env = @[("HOME", home), ("XDG_STATE_HOME", home / "state"),
    ("XDG_CONFIG_HOME", home / "config"), ("XDG_CACHE_HOME", home / "cache"),
    ("XDG_DATA_HOME", home / "data"), ("XDG_RUNTIME_DIR", home / "run"),
    ("REPRO_STORE_ROOT", home / "store"),
    ("REPRO_DAEMON_ENDPOINT", home / "daemon" / "repro-daemon.sock"),
    ("REPRO_DAEMON_STATE_DIR", home / "daemon-state"),
    ("REPRO_DAEMON", ""), ("TERM", "dumb"), ("NO_COLOR", "1")]

proc dispose(s: Scratch) =
  removeDir(s.cwd)
  removeDir(s.home)

proc run(s: Scratch; argv: openArray[string]): tuple[code: int,
         output: string] =
  let res = runShell(shellCommand(@[reproBinary()] & @argv, s.env),
    cwd = s.cwd, timeoutMs = 120_000)
  checkpoint("repro " & argv.join(" ") & " -> exit " & $res.code & "\n" &
    res.output)
  (res.code, res.output)

proc runStdout(s: Scratch; argv: openArray[string]): tuple[code: int,
               stdout: string] =
  ## Like ``run``, with stdout alone: `sh` discards the command's stderr.
  let res = runShell(shellCommand(@["sh", "-c", "\"$@\" 2>/dev/null", "sh",
    reproBinary()] & @argv, s.env), cwd = s.cwd, timeoutMs = 120_000)
  checkpoint("repro " & argv.join(" ") & " (stdout) -> exit " & $res.code &
    "\n" & res.output)
  (res.code, res.output)

proc entriesUnder(dir: string): seq[string] =
  for entry in walkDirRec(dir, yieldFilter = {pcFile, pcDir, pcLinkToFile,
                                              pcLinkToDir}):
    result.add(entry)

var parsedCommand: ReproCommandLine

proc parsed(argv: openArray[string]): int =
  ## ``argv`` through repro's generated parser, in process; -1 when a command
  ## was selected, else the exit code the parser answered with.
  parsedCommand = ReproCommandLine()
  loadReproCommandLine(argv, parsedCommand)

type
  SysCmd = ReproCommandLineSystemCommand
  AddonCmd = ReproCommandLineSystemAddonCommand

suite "repro's parser knows the mounted add-on command line":

  test "each verb parses into repro's configuration with its values":
    check parsed(["system", "addon", "preflight", "--json",
      "--deploy-signers", "s", "--manifest", "m1", "--manifest=m2",
      "--poll-interval", "30", "--defer-recipient-key"]) == -1
    check parsedCommand.system.command == SysCmd.addon
    let a = parsedCommand.system.addon
    check a.command == AddonCmd.preflight
    check a.preflight.json and a.preflight.deferRecipientKey
    check a.preflight.deploySigners == "s"
    check a.preflight.manifest == @["m1", "m2"]
    check a.preflight.pollInterval.get(0) == 30
    check parsed(["system", "addon", "verify-discard-record", "rec",
      "--key", "04ab"]) == -1
    check parsedCommand.system.addon.verifyDiscardRecord.record == "rec"
    check parsedCommand.system.addon.verifyDiscardRecord.key == "04ab"
    check parsed(["system", "addon", "fingerprint", "diff", "a", "b",
      "--except", "c:k*", "--except", "d:*"]) == -1
    check parsedCommand.system.addon.fingerprint.diff.exceptRule ==
      @["c:k*", "d:*"]
    check parsed(["system", "addon", "fingerprint", "--root", "/r",
      "--no-live", "--out", "f"]) == -1
    check parsedCommand.system.addon.fingerprint.call.outPath == "f"
    check parsed(["system", "addon", "state", "verify", "--from", "d",
      "--only", "keep", "--source"]) == -1
    check parsedCommand.system.addon.state.verify.fromDir == "d"
    check parsed(["system", "state", "restore", "--boot"]) == -1
    check parsedCommand.system.state.restore.boot
    check parsed(["system", "secret", "put", "--service", "s", "--name",
      "n"]) == -1
    check parsedCommand.system.secret.put.service == "s"
    check parsed(["system", "secret", "materialise", "--boot"]) == -1
    check parsedCommand.system.secret.materialise.boot
    check parsed(["system", "adopt", "unit:x", "--profile", "p",
      "--accept-drift"]) == -1
    check parsedCommand.system.adopt.address == "unit:x"
    check parsedCommand.system.adopt.reconcileDrift

  test "a command line the add-on does not declare is a usage error":
    for argv in [
        @["system", "addon"],                              # no verb
        @["system", "addon", "preflight", "--bogus"],      # unknown flag
        @["system", "addon", "contain", "--operator", "x"], # --reason missing
        @["system", "addon", "image-assemble"],            # --payload missing
        @["system", "addon", "no-such-verb"],
        @["system", "addon", "test-sleep", "1"],           # the static binary's
        @["system", "state", "restore", "--profile", "p"], # another verb's flag
        @["system", "addon", "retention", "--keep-days", "x"],
        @["system", "adopt", "--profile", "p"]]:           # address missing
      checkpoint(argv.join(" "))
      check parsed(argv) == 2

  test "the mount point's words are the add-on's own command line":
    check reproWordsAfterMount(["system", "addon", "preflight", "--json"],
      ["system", "addon"]) == @["preflight", "--json"]
    check reproWordsAfterMount(["system", "state", "restore", "--boot"],
      ["system", "state"]) == @["restore", "--boot"]
    check reproWordsAfterMount(["system", "adopt"], ["system", "adopt"]) ==
      newSeq[string]()
    expect ValueError:
      discard reproWordsAfterMount(["system", "list"], ["system", "addon"])

when defined(linux):
  type
    AVerb = ReproAddonCommandLineSystemAddonCommand

  proc addonParsed(argv: openArray[string]): ReproAddonCommandLine =
    ReproAddonCommandLine.load(argv)

  suite "the add-on's parser reads the same declarations":

    test "repro's mounted words parse to the same values there":
      let argv = @["system", "addon", "bootstrap", "--plan", "ab",
        "--evidence-sink", "h:1", "--evidence-sink-ca", "ca",
        "--heartbeat-interval=15"]
      check parsed(argv) == -1
      let theirs = addonParsed(@["system", "addon"] &
        reproWordsAfterMount(argv, ["system", "addon"])).system.addon
      check theirs.command == AVerb.bootstrap
      let ours = parsedCommand.system.addon.bootstrap
      check theirs.bootstrap.plan == ours.plan
      check theirs.bootstrap.evidenceSink == ours.evidenceSink
      check theirs.bootstrap.evidenceSinkCa == ours.evidenceSinkCa
      check theirs.bootstrap.heartbeatInterval == ours.heartbeatInterval

    test "every command line the add-on's callers write is accepted":
      # The systemd units of generation 0 (`generation0`), the apt hook, the
      # confined shipping run (`evidence_ship`), the restore unit
      # (`adoption_cli`), an image's assembly unit (`infra_image`) and the
      # runbooks' operator lines.
      for argv in [
          @["system", "addon", "reassert", "--boot"],
          @["system", "addon", "boot-confirm"],
          @["system", "addon", "secrets", "--boot"],
          @["system", "addon", "verify", "--boot"],
          @["system", "addon", "verify", "--after-dpkg"],
          @["system", "addon", "evidence-harvest"],
          @["system", "addon", "evidence-ship"],
          @["system", "addon", "evidence-ship", "--no-backoff", "--heartbeat"],
          @["system", "addon", "evidence-credential-check"],
          @["system", "addon", "store-verify", "--background"],
          @["system", "addon", "egress-check"],
          @["system", "addon", "agent-fetch"],
          @["system", "addon", "agent-apply"],
          @["system", "addon", "agent-tick", "--source", "s"],
          @["system", "addon", "image-assemble", "--payload", "/p"],
          @["system", "addon", "migrate"],
          @["system", "addon", "recover"],
          @["system", "addon", "status"],
          @["system", "addon", "contain", "--operator=o", "--reason", "r"],
          @["system", "addon", "evidence-enrol", "--rekey", "--no-handover"],
          @["system", "addon", "uninstall", "--keep-store"],
          @["system", "addon", "probe", "tcp:127.0.0.1:1"],
          @["system", "addon", "expected-delta", "-", "after"],
          @["system", "addon", "state", "install-unit", "--root", "/r"],
          @["system", "addon", "test-sleep", "1"],
          @["system", "rollback", "g1", "--reconcile-drift"],
          @["infra", "apply", "--profile", "p", "--keep-generations", "3",
            "--no-preview"],
          @["infra", "plan", "--profile=p"],
          @["store", "gc", "--grace-seconds", "5"],
          @["store", "recover"],
          @["--version"], @["version"]]:
        checkpoint(argv.join(" "))
        var conf: ReproAddonCommandLine
        check loadAddonCommandLine(argv, conf) == -1
      # The words the full engine's `repro system state restore --boot` hands
      # over: the restore unit's command line.
      var conf: ReproAddonCommandLine
      check loadAddonCommandLine(@["system", "addon", "state"] &
        reproWordsAfterMount(["system", "state", "restore", "--boot"],
          ["system", "state"]), conf) == -1
      check conf.system.addon.state.restore.boot

    test "the static binary runs the restore unit it writes":
      # `state unit` and `state install-unit` write a first-boot unit whose
      # ExecStart is `<this binary> system state restore --boot`. On an
      # add-on host this binary is the static one, so its own command line
      # must accept those words; it did not before round 8c (the unit failed
      # at boot with a usage error). The words are read from the unit text
      # the binary writes, not restated here.
      var execStart = ""
      for line in stateRestoreUnitText("/usr/local/repro/bin/repro").
          splitLines():
        if line.startsWith("ExecStart="):
          execStart = line["ExecStart=".len .. ^1]
      let words = execStart.splitWhitespace()
      checkpoint("ExecStart=" & execStart)
      require words.len > 1
      var conf: ReproAddonCommandLine
      check loadAddonCommandLine(words[1 .. ^1], conf) == -1
      check conf.command == ReproAddonCommandLineCommand.system
      check conf.system.command == ReproAddonCommandLineSystemCommand.state
      check conf.system.state.command ==
        ReproAddonCommandLineSystemStateCommand.restore
      check conf.system.state.restore.boot
      # The same verbs and flags as `repro system addon state`; a flag of
      # another verb is still refused.
      check loadAddonCommandLine(@["system", "state", "verify", "--from", "d",
        "--only", "carry"], conf) == -1
      check conf.system.state.verify.only == "carry"
      check loadAddonCommandLine(@["system", "state", "restore", "--profile",
        "p"], conf) == 2

    test "an assembly payload's preflight flags are read by the parser":
      let p = loadPreflightFlags(@["--deploy-signers", "s", "--target", "t",
        "--manifest", "m", "--defer-recipient-key"])
      check p.deploySigners == "s" and p.target == "t"
      check p.manifest == @["m"] and p.deferRecipientKey
      expect ValueError:
        discard loadPreflightFlags(@["--plan", "ab"])

    test "the fingerprint tool's command line is its own program's":
      let d = ReproAddonFingerprintTool.load(["diff", "a", "b", "--expect",
        "e"])
      check d.command == ReproAddonFingerprintToolCommand.diff
      check d.diff.before == "a" and d.diff.after == "b"
      check d.diff.expect == "e"
      let c = ReproAddonFingerprintTool.load(["--root", "/r"])
      check c.command == ReproAddonFingerprintToolCommand.call
      check c.call.root == "/r" and not c.call.noLive
      expect CliUsageError:
        discard ReproAddonFingerprintTool.load(["--bogus"])

type MonitorCmd = ReproCommandLineDebugIoMonitorCommand

suite "repro's parser knows the mounted io-mon command line":

  test "the bare form, run and inspect parse with their values":
    check parsed(["debug", "io", "monitor", "--depfile", "d", "--interest",
      "file-reads", "--", "true", "--help"]) == -1
    let m = parsedCommand.debug.io.monitor
    check m.command == MonitorCmd.call
    check m.call.depfile == "d"
    check m.call.interest == some("file-reads")
    check m.call.command == @["true", "--help"]
    check parsed(["debug", "io", "monitor", "run", "--format=jsonl",
      "--event-stream", "e", "--capture-stdio", "--", "x"]) == -1
    let r = parsedCommand.debug.io.monitor.run
    check r.events == "jsonl" and r.eventStream == "e" and r.captureStdio
    check r.command == @["x"]
    check parsed(["internal", "io", "monitor", "inspect", "f", "--format",
      "json"]) == -1
    check parsedCommand.internal.io.monitor.inspect.path == "f"
    check parsedCommand.internal.io.monitor.inspect.format == "json"

  test "a command line io-mon does not declare is a usage error":
    for argv in [
        @["debug", "io", "monitor", "run", "--bogus", "--", "x"],
        @["debug", "io", "monitor", "run", "--depfile", "d"],  # no command
        @["debug", "io", "monitor", "inspect"],                # no path
        @["debug", "io", "monitor", "run", "--events", "nope", "--", "x"],
        @["internal", "io", "monitor", "--bogus", "--", "x"]]:
      checkpoint(argv.join(" "))
      check parsed(argv) == 2

  test "the engine's spawn form reaches io-mon's parser with the same values":
    # What the build engine writes: `internal io monitor` and the bare form.
    let argv = @["internal", "io", "monitor", "--interest", "file-reads,proc",
      "--evidence", "reads-only", "--depfile", "/d.iomon", "--", "/bin/echo",
      "--flag-of-the-action", "x"]
    check parsed(argv) == -1
    let words = reproWordsAfterMount(argv, ["internal", "io", "monitor"])
    check words == argv[3 .. ^1]
    let theirs = io_mon_cli.parseFsSnoopArgs(words)
    check not theirs.inspectMode
    check theirs.request.depFilePath == "/d.iomon"
    check theirs.request.command == @["/bin/echo", "--flag-of-the-action", "x"]
    check parsedCommand.internal.io.monitor.call.depfile ==
      theirs.request.depFilePath

suite "the mounted command lines' help is generated":

  test "help, -h and repro help print the mounted verbs; errors are clispec's":
    let s = newScratch()
    defer: s.dispose()
    let addon = s.runStdout(["system", "addon", "--help"])
    check addon.code == 0
    check "Usage: repro system addon" in addon.stdout
    for verb in ["preflight", "bootstrap", "verify-discard-record",
                 "agent-tick", "fingerprint", "state"]:
      check verb in addon.stdout
    let preflight = s.runStdout(["system", "addon", "preflight", "-h"])
    check preflight.code == 0
    check "--deploy-signers" in preflight.stdout
    check "--json" in preflight.stdout
    let viaHelp = s.runStdout(["help", "system", "addon", "preflight"])
    check viaHelp.code == 0
    check "--deploy-signers" in viaHelp.stdout
    let state = s.runStdout(["system", "state", "--help"])
    check state.code == 0
    check "install-unit" in state.stdout
    let monitor = s.runStdout(["debug", "io", "monitor", "--help"])
    check monitor.code == 0
    check "Usage: repro debug io monitor" in monitor.stdout
    check "run" in monitor.stdout and "inspect" in monitor.stdout
    let run = s.runStdout(["internal", "io", "monitor", "run", "-h"])
    check run.code == 0
    check "--depfile" in run.stdout
    let refused = s.run(["system", "addon", "preflight", "--bogus"])
    check refused.code == 2
    check "error:" in refused.output
    check "--bogus" in refused.output
    check entriesUnder(s.cwd).len == 0
