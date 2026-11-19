## The command lines of round 8a of repro's move onto its description:
## `repro attest`, the commands that forward their words to another command
## line (`repro system addon|state|secret|adopt`, `repro debug io monitor`),
## and the environment variables the help texts used to name by hand, now
## declared on their flags.
##
## The arms, and what makes each one evidence:
##
##   1. `repro attest` is parsed from the description. Its help is generated
##      (`--help`, `-h`, `help attest`), lists its exit codes in its long help
##      and names every value set the command knows (backends, hypervisors,
##      tdx fold orders, clouds) and the defaults of its numeric flags, each
##      checked against the constants the command reads, so the help cannot
##      drift from them. A command line it does not accept is a usage error
##      (exit 2): no subcommand, an unknown one, another subcommand's flag, a
##      stray word. Each subcommand's flags reach `AttestCliOptions` with the
##      values given; the command's own refusals keep exit 2.
##   2. The forwarding commands hand every word after the subcommand to the
##      add-on's or io-mon's command line verbatim (`--help` and `--`
##      included), as before; `repro help` of them is generated.
##   3. Every flag-over-variable default a help text named is declared, and
##      holds in both orders, an empty variable counting as unset: the store
##      root (`REPRO_STORE_ROOT`) of every store command, the development
##      store daemon's endpoint (`REPROSTORED_ENDPOINT`), `repro cargo`'s
##      target directory (`CARGO_TARGET_DIR`) and live-set settings
##      (`REPRO_CARGO_GC_KEEP_SETS`, `REPRO_CARGO_GC_MIN_AGE`), the gateway's
##      bare (`GIT_DIR`), `repro shell --shell` (`SHELL`), `repro home add
##      --catalog` (`REPRO_HOME_PACKAGE_CATALOG`), and the development
##      environment commands' work root (`REPROBUILD_WORK_ROOT`).
##      `--host` and `REPRO_HOST`, where the variable takes precedence and a
##      contradicting flag is refused: the variable alone gives the flag its
##      value, and the host resolver still refuses two different values.
##      `repro build --progress` (and its variables) wins over the quiet
##      default of an agent's shell (`$IN_AGENT_SHELL`), with and without
##      the flag.
##   4. The variables set in nearly every environment change no accepted
##      command line: `$SHELL` does not count as `--shell` (`repro shell --
##      <command>` is not refused), `$GIT_DIR` (set by git for every hook)
##      reaches only the gateway, `$REPROBUILD_WORK_ROOT` does not pick a
##      form of `repro develop`, and an unparsable `$REPRO_CARGO_GC_*` stays a
##      warning where the flag's value is an error.
##
## No mocks: the real `build/bin/repro` runs as a subprocess in an empty
## directory with a fresh HOME, XDG directories, store root and daemon
## endpoint, and arms 1 and 3 also run the generated parser in process. No
## command line here gets past its parse into anything that changes the
## machine: every subprocess either prints help, is refused, or fails on the
## empty directory before it does anything; `repro system addon --help`
## prints the add-on's usage text and returns.

import std/[options, os, strutils, tables, tempfiles, unittest]

import repro_test_support

import repro_attest
import repro_attest/cloud_lease
import repro_attest_verify
import repro_cli_support
import repro_cli_support/attest
import repro_cli_support/cli_program

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

const RoundEnv = ["REPRO_STORE_ROOT", "REPROSTORED_ENDPOINT",
  "CARGO_TARGET_DIR", "REPRO_CARGO_GC_KEEP_SETS", "REPRO_CARGO_GC_MIN_AGE",
  "GIT_DIR", "SHELL", "REPRO_HOME_PACKAGE_CATALOG", "REPROBUILD_WORK_ROOT",
  "REPRO_HOST"]

type Scratch = object
  cwd, home: string
  env: seq[(string, string)]

proc newScratch(): Scratch =
  result.cwd = createTempDir("repro-r8a-cwd-", "")
  result.home = createTempDir("repro-r8a-home-", "")
  let home = result.home
  result.env = @[("HOME", home), ("XDG_STATE_HOME", home / "state"),
    ("XDG_CONFIG_HOME", home / "config"), ("XDG_CACHE_HOME", home / "cache"),
    ("XDG_DATA_HOME", home / "data"), ("XDG_RUNTIME_DIR", home / "run"),
    ("REPRO_STORE_ROOT", home / "store"),
    ("REPRO_DAEMON_ENDPOINT", home / "daemon" / "repro-daemon.sock"),
    ("REPRO_DAEMON_STATE_DIR", home / "daemon-state"),
    ("REPROSTORED_ENDPOINT", home / "reprostored.sock"),
    ("REPRO_DAEMON", ""), ("REPROBUILD_WORK_ROOT", ""),
    ("REPRO_CARGO_GC_KEEP_SETS", ""), ("REPRO_CARGO_GC_MIN_AGE", ""),
    ("CARGO_TARGET_DIR", ""), ("GIT_DIR", ""), ("REPRO_HOST", ""),
    ("REPRO_HOME_PACKAGE_CATALOG", ""), ("REPRO_WORKSPACE_CONFIG", "")]

proc dispose(s: Scratch) =
  removeDir(s.cwd)
  removeDir(s.home)

proc run(s: Scratch; argv: openArray[string];
         extraEnv: openArray[(string, string)] = []): tuple[code: int,
         output: string] =
  let res = runShell(shellCommand(@[reproBinary()] & @argv,
    s.env & @extraEnv), cwd = s.cwd, timeoutMs = 120_000)
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
  ## What a command line left behind in ``dir``.
  for entry in walkDirRec(dir, yieldFilter = {pcFile, pcDir, pcLinkToFile,
                                              pcLinkToDir}):
    result.add(entry)

const NoEnv: seq[(string, string)] = @[]

template withRoundEnv(assignments: openArray[(string, string)];
                      body: untyped) =
  ## ``body`` with exactly ``assignments`` among this round's variables, the
  ## process environment restored afterwards.
  block:
    var saved: seq[(string, bool, string)]
    for name in RoundEnv:
      saved.add((name, existsEnv(name), getEnv(name)))
      delEnv(name)
    try:
      for (name, value) in assignments:
        putEnv(name, value)
      body
    finally:
      for (name, present, value) in saved:
        if present: putEnv(name, value) else: delEnv(name)

var parsedCommand: ReproCommandLine
var parsedOrigins: ReproCommandLineOrigins

proc parsed(argv: openArray[string]): int =
  ## ``argv`` through the generated parser, in process, as `repro` parses
  ## it; the configuration and its origins are left in ``parsedCommand`` and
  ## ``parsedOrigins``. -1 when a command was selected, else the exit code
  ## the parser answered with (2 for a usage error).
  parsedCommand = ReproCommandLine()
  parsedOrigins = ReproCommandLineOrigins()
  loadReproCommandLine(argv, parsedCommand, parsedOrigins)

suite "repro attest is parsed from the description":

  test "its help is generated, with the exit codes and the known values":
    let s = newScratch()
    defer: s.dispose()
    let long = s.runStdout(["attest", "--help"])
    check long.code == 0
    check long.stdout.startsWith("Compute and check launch measurements")
    check "Exit codes:" in long.stdout
    for sub in ["expect", "challenge", "verify", "cross-check", "launch",
                "reap"]:
      check ("  " & sub) in long.stdout
    let short = s.runStdout(["attest", "-h"])
    check short.code == 0
    check "Usage: repro attest" in short.stdout
    check s.runStdout(["help", "attest"]).stdout == short.stdout
    # The in-process page is the one the binary prints.
    let page = ReproCommandLine.helpText(["attest"], long = true)
    check "Exit codes:" in page
    for sub in ["expect", "challenge", "verify", "cross-check", "launch",
                "reap"]:
      let help = s.runStdout(["attest", sub, "--help"])
      check help.code == 0
      check ("Usage: repro attest " & sub) in help.stdout
    # Every value set and default the help names is the one the command
    # reads (the help is a declaration, so it is held to the constants).
    # (Each page with its lines joined: a value may wrap onto the next.)
    proc pageOf(path: openArray[string]): string =
      ReproCommandLine.helpText(path).splitWhitespace().join(" ")
    let expectHelp = pageOf(["attest", "expect"])
    for backend in KnownBackends:
      check ("`" & backend & "`") in expectHelp
    for vmm in KnownVmms:
      check ("`" & vmm & "`") in expectHelp
    for order in tdxHostOrderNames().split(", "):
      check ("`" & order & "`") in expectHelp
    let launchHelp = pageOf(["attest", "launch"])
    for provider in cloudProviderNames().split(", "):
      check ("`" & provider & "`") in launchHelp
    check ("default " & $DefaultLeaseTtlSeconds) in launchHelp
    let challengeHelp = pageOf(["attest", "challenge"])
    check ("[default: " & $ChallengeBytes & "]") in challengeHelp
    check ("at least " & $ChallengeMinBytes) in challengeHelp
    let reapHelp = pageOf(["attest", "reap"])
    check ("default " & $DefaultReapIntervalSeconds) in reapHelp
    check ("at most " & $MaxReapIntervalSeconds) in reapHelp

  test "a command line it does not accept is a usage error":
    let s = newScratch()
    defer: s.dispose()
    for (argv, message) in [
        (@["attest"], "'repro attest' needs a subcommand"),
        (@["attest", "frob"], "unknown subcommand 'frob' for 'repro attest'"),
        # Another subcommand's flag is not this one's.
        (@["attest", "challenge", "--image", "x"],
          "unknown flag '--image' for 'repro attest challenge'"),
        (@["attest", "expect", "stray"],
          "unexpected argument 'stray' for 'repro attest expect'"),
        (@["attest", "launch", "--armed"],
          "unknown flag '--armed' for 'repro attest launch'"),
        (@["attest", "challenge", "--bytes", "many"],
          "invalid value 'many' for '--bytes' of 'repro attest challenge'")]:
      let res = s.run(argv)
      check res.code == 2
      check message in res.output
      check "error: " in res.output
    check entriesUnder(s.cwd).len == 0

  test "each subcommand's flags reach its options":
    check parsed(["attest", "expect", "--image=i", "--uki", "u",
      "--verity-image", "v", "--verity-image-digest", "sha256:d",
      "--verity-root-hash", "h", "--verity-root-hash-file", "hf",
      "--config-fingerprint", "c", "--backend", "sev-snp", "--backend=tdx",
      "--firmware", "f", "--vcpus", "4", "--vcpu-type", "EPYC-Milan",
      "--guest-policy", "0x30000", "--guest-features", "0x1", "--vmm", "qemu",
      "--launch-kernel", "k", "--launch-initrd", "r", "--launch-cmdline=",
      "--td-firmware", "tf", "--td-register-log", "tl",
      "--td-page-order", "per-page", "--out", "o", "--check", "-x"]) == -1
    let e = attestOptionsOf(parsedCommand.attest)
    check e.sub == ascExpect
    check e.image == "i" and e.uki == "u" and e.verityImage == "v"
    check e.verityImageDigest == "sha256:d" and e.verityRootHash == "h"
    check e.verityRootHashFile == "hf" and e.configFingerprint == "c"
    check e.backends == @["sev-snp", "tdx"]
    check e.firmware == "f" and e.vcpus == "4" and e.vcpuType == "EPYC-Milan"
    check e.guestPolicy == "0x30000" and e.guestFeatures == "0x1"
    check e.vmm == "qemu" and e.snpKernel == "k" and e.snpInitrd == "r"
    # Given empty, the command line is stated (and empty).
    check e.hasSnpCmdline and e.snpCmdline == ""
    check e.tdxFirmware == "tf" and e.tdxRegisterLog == "tl"
    check e.tdxPageOrder == "per-page"
    # A value is taken as the next word whatever it looks like, as before.
    check e.outPath == "o" and e.checkPath == "-x"
    check parsed(["attest", "expect", "--image", "i"]) == -1
    check not attestOptionsOf(parsedCommand.attest).hasSnpCmdline

    check parsed(["attest", "challenge"]) == -1
    let c0 = attestOptionsOf(parsedCommand.attest)
    check c0.sub == ascChallenge and c0.challengeBytes == ChallengeBytes
    check not c0.hexOnly
    check parsed(["attest", "challenge", "--bytes=48", "--hex",
      "--out", "o"]) == -1
    let c = attestOptionsOf(parsedCommand.attest)
    check c.challengeBytes == 48 and c.hexOnly and c.outPath == "o"

    check parsed(["attest", "verify", "--report-file", "r", "--report-url",
      "u", "--policy", "p", "--manifest", "m", "--challenge", "ab",
      "--challenge-file", "cf", "--challenge-issued-at", "t",
      "--trust-anchor", "a1", "--trust-anchor", "a2", "--revocation-list",
      "l", "--attestations", "at", "--signer-key", "k", "--signer-admission",
      "kid=a/b", "--revoked-signer", "kid=x:y", "--vendor-revocation-list",
      "vl", "--witnessed-root", "w", "--json", "--out", "o"]) == -1
    let v = attestOptionsOf(parsedCommand.attest)
    check v.sub == ascVerify and v.reportFile == "r" and v.reportUrl == "u"
    check v.policyPath == "p" and v.manifestPath == "m"
    check v.challengeHex == "ab" and v.challengeFile == "cf"
    check v.challengeIssuedAt == "t"
    check v.trustAnchorPaths == @["a1", "a2"]
    check v.revocationListPaths == @["l"] and v.attestationsPath == "at"
    check v.signerKeyPaths == @["k"] and v.signerAdmissions == @["kid=a/b"]
    check v.revokedSigners == @["kid=x:y"]
    check v.vendorRevocationListPaths == @["vl"]
    check v.witnessedRoots == @["w"] and v.asJson and v.outPath == "o"

    # `cross-check` declares `verify`'s report flags and `--check` so that it
    # refuses each by name: they reach its options, and it refuses them.
    check parsed(["attest", "cross-check", "--manifest", "m", "--policy",
      "p", "--attestations", "a", "--config-fingerprint", "c", "--uki", "u",
      "--report-file", "r"]) == -1
    let x = attestOptionsOf(parsedCommand.attest)
    check x.sub == ascCrossCheck and x.reportFile == "r" and x.uki == "u"
    check x.manifestPath == "m" and x.attestationsPath == "a"

    check parsed(["attest", "launch", "--provider", "aws-ec2", "--region",
      "r", "--instance-name", "n", "--instance-shape", "s",
      "--image-reference", "ir", "--subnet", "sn", "--ssh-key-reference",
      "sk", "--lease-store", "ls", "--lease-ttl-seconds", "60",
      "--lease-rate-micros-per-hour", "7", "--lease-out", "lo", "--plan-out",
      "po", "--now", "1"]) == -1
    let l = attestOptionsOf(parsedCommand.attest)
    check l.sub == ascLaunch and l.provider == "aws-ec2" and l.region == "r"
    check l.instanceName == "n" and l.instanceShape == "s"
    check l.imageReference == "ir" and l.subnet == "sn"
    check l.sshKeyReference == "sk" and l.leaseStore == "ls"
    check l.leaseTtlSeconds == "60" and l.leaseRateMicros == "7"
    check l.leaseOut == "lo" and l.planOut == "po" and l.leaseNow == "1"

    check parsed(["attest", "reap", "--lease-store", "ls", "--now", "2",
      "--destroy", "--tag-sweep", "--provider", "gcp-compute", "--region",
      "r", "--interval-seconds", "30", "--sweeps", "3"]) == -1
    let r = attestOptionsOf(parsedCommand.attest)
    check r.sub == ascReap and r.leaseStore == "ls" and r.leaseNow == "2"
    check r.reapDestroy and r.reapTagSweep and r.provider == "gcp-compute"
    check r.region == "r" and r.reapInterval == "30" and r.reapSweeps == "3"

  test "the command's own refusals keep exit 2, and it runs":
    let s = newScratch()
    defer: s.dispose()
    # `verify` without a report: the command's refusal, not the parser's.
    check runAttestCommand(@["verify", "--policy", s.cwd / "absent.toml"]) ==
      AttestExitUsage
    # `cross-check` refuses `--check` by name.
    let refused = s.run(["attest", "cross-check", "--manifest", "m",
      "--policy", "p", "--attestations", "a", "--check", "c"])
    check refused.code == 2
    check "--check compares two documents byte for byte" in refused.output
    # A real run: a nonce on stdout, nothing written.
    let nonce = s.runStdout(["attest", "challenge", "--hex"])
    check nonce.code == 0
    check nonce.stdout.strip().len == 2 * ChallengeBytes
    check entriesUnder(s.cwd).len == 0

suite "the forwarding commands hand their words over verbatim":

  test "every word after the subcommand reaches the other command line":
    for (argv, words) in [
        (@["system", "addon", "preflight", "--json"], @["preflight", "--json"]),
        (@["system", "addon", "--help"], @["--help"]),
        (@["system", "state", "save", "--", "x"], @["save", "--", "x"]),
        (@["system", "secret", "materialise", "--boot"],
          @["materialise", "--boot"]),
        (@["system", "adopt", "-h"], @["-h"])]:
      check parsed(argv) == -1
      let got =
        case parsedCommand.system.command
        of ReproCommandLineSystemCommand.addon: parsedCommand.system.addon.args
        of ReproCommandLineSystemCommand.state: parsedCommand.system.state.args
        of ReproCommandLineSystemCommand.secret:
          parsedCommand.system.secret.args
        of ReproCommandLineSystemCommand.adopt: parsedCommand.system.adopt.args
        else: @["<another command>"]
      check got == words
    check parsed(["debug", "io", "monitor", "--dep-file", "d", "--", "true",
      "--help"]) == -1
    check parsedCommand.debug.io.monitor.args ==
      @["--dep-file", "d", "--", "true", "--help"]

  test "the other command line answers its own help; repro help is generated":
    let s = newScratch()
    defer: s.dispose()
    when defined(linux):
      let addon = s.runStdout(["system", "addon", "--help"])
      check addon.code == 0
      check addon.stdout.startsWith("usage: repro system addon <command>")
    let monitor = s.run(["debug", "io", "monitor", "--help"])
    check monitor.code == 1
    check "repro debug io monitor: error: unsupported fs-snoop argument: " &
      "--help" in monitor.output
    for path in [@["system", "addon"], @["system", "state"],
                 @["system", "secret"], @["system", "adopt"],
                 @["debug", "io", "monitor"]]:
      let help = s.runStdout(@["help"] & path)
      check help.code == 0
      check ("Usage: repro " & path.join(" ") & " [<args>...]") in
        help.stdout
      # Words after it are the other program's: `repro help` still prints
      # the command's own help, as it did before the command was declared.
      let deeper = s.runStdout(@["help"] & path & @["somewhere", "else"])
      check deeper.code == 0
      check deeper.stdout == help.stdout
    check entriesUnder(s.cwd).len == 0

suite "the variables the help texts named are declared on their flags":

  test "the flag wins over the variable, in both orders":
    template both(argv: openArray[string]; flagWord, name, field: untyped) =
      block:
        withRoundEnv([(name, "/env/v")]):
          check parsed(argv) == -1
          check field == "/env/v"
          check parsed(@argv & @[flagWord & "=/flag/v"]) == -1
          check field == "/flag/v"
        withRoundEnv([(name, "")]):
          check parsed(argv) == -1
          check field == ""
    template storeRoot(argv: openArray[string]; field: untyped) =
      both(argv, "--store-root", "REPRO_STORE_ROOT", field.storeRoot)
    storeRoot(["store", "gc"], parsedCommand.store.gc)
    storeRoot(["store", "recover"], parsedCommand.store.recover)
    storeRoot(["store", "roots"], parsedCommand.store.roots)
    storeRoot(["store", "list"], parsedCommand.store.list)
    storeRoot(["store", "optimise"], parsedCommand.store.optimise)
    storeRoot(["store", "copy", "--to=/d"], parsedCommand.store.copy)
    storeRoot(["store", "closure", "--root=/r"], parsedCommand.store.closure)
    storeRoot(["store", "export", "--root=/r", "--out=/o"],
      parsedCommand.store.export)
    storeRoot(["store", "import", "/b"], parsedCommand.store.import)
    storeRoot(["cas", "verify", "x"], parsedCommand.cas)
    storeRoot(["launch-plan", "id", "/p"], parsedCommand.launchPlan)
    storeRoot(["self", "list"], parsedCommand.self.list)
    storeRoot(["self", "prune-roots"], parsedCommand.self.pruneRoots)
    storeRoot(["bundle", "create", "--out=/o", "sel"], parsedCommand.bundle.create)
    storeRoot(["bundle", "restore", "/b"], parsedCommand.bundle.restore)
    both(["home", "gc"], "--store", "REPRO_STORE_ROOT",
      parsedCommand.home.gc.store)
    both(["store", "daemon", "status"], "--endpoint", "REPROSTORED_ENDPOINT",
      parsedCommand.store.daemon.endpoint)
    both(["cargo", "gc"], "--target-dir", "CARGO_TARGET_DIR",
      parsedCommand.cargo.gc.targetDir)
    both(["cargo", "record-live"], "--target-dir", "CARGO_TARGET_DIR",
      parsedCommand.cargo.recordLive.targetDir)
    both(["cargo", "gc"], "--keep-sets", "REPRO_CARGO_GC_KEEP_SETS",
      parsedCommand.cargo.gc.keepSets)
    both(["cargo", "record-live"], "--keep-sets", "REPRO_CARGO_GC_KEEP_SETS",
      parsedCommand.cargo.recordLive.keepSets)
    both(["cargo", "gc"], "--min-age", "REPRO_CARGO_GC_MIN_AGE",
      parsedCommand.cargo.gc.minAge)
    both(["gateway", "pre-receive"], "--gateway-dir", "GIT_DIR",
      parsedCommand.gateway.preReceive.gatewayDir)
    both(["gateway", "post-receive"], "--gateway-dir", "GIT_DIR",
      parsedCommand.gateway.postReceive.gatewayDir)
    both(["home", "add", "p"], "--catalog", "REPRO_HOME_PACKAGE_CATALOG",
      parsedCommand.home.add.catalog)
    when defined(windows):
      both(["shell"], "--shell", "COMSPEC", parsedCommand.shell.call.shell)
    else:
      both(["shell"], "--shell", "SHELL", parsedCommand.shell.call.shell)
    template workRoot(argv: openArray[string]; field: untyped) =
      both(argv, "--work-root", "REPROBUILD_WORK_ROOT", field.workRoot)
    workRoot(["exec"], parsedCommand.exec)
    workRoot(["shell"], parsedCommand.shell.call)
    workRoot(["run", "t"], parsedCommand.run)
    workRoot(["tasks"], parsedCommand.tasks)
    workRoot(["up"], parsedCommand.up)
    workRoot(["dev"], parsedCommand.dev)
    workRoot(["down"], parsedCommand.down)
    both(["develop", "--list-overrides"], "--work-root",
      "REPROBUILD_WORK_ROOT", parsedCommand.develop.workRoot.get(""))
    # Where the value came from is kept: the commands that must tell the two
    # apart ask (`repro shell`, `repro develop`, `repro cargo`).
    withRoundEnv([("REPROBUILD_WORK_ROOT", "/env/v")]):
      check parsed(["develop", "--list-overrides"]) == -1
      check not reproGivenOnCommandLine(parsedOrigins.develop.workRoot)
      check parsed(["develop", "--list-overrides", "--work-root=/f"]) == -1
      check reproGivenOnCommandLine(parsedOrigins.develop.workRoot)

  test "REPRO_HOST and --host: the variable alone, the flag alone, both":
    template host(argv: openArray[string]; field: untyped) =
      block:
        withRoundEnv([("REPRO_HOST", "envhost")]):
          check parsed(argv) == -1
          check field.host == some("envhost")
          check parsed(@argv & @["--host=envhost"]) == -1
          check field.host == some("envhost")
          # Two different values: the parser hands the flag's on, and the
          # host resolver, which reads the variable itself, refuses them
          # (below, end to end).
          check parsed(@argv & @["--host=other"]) == -1
          check field.host == some("other")
        withRoundEnv(NoEnv):
          check parsed(@argv & @["--host=flaghost"]) == -1
          check field.host == some("flaghost")
          check parsed(argv) == -1
          check field.host.isNone
        withRoundEnv([("REPRO_HOST", "")]):
          check parsed(argv) == -1
          check field.host.isNone
    host(["home", "list"], parsedCommand.home.list)
    host(["home", "why", "p"], parsedCommand.home.why)
    host(["home", "apply"], parsedCommand.home.apply)
    host(["home", "plan"], parsedCommand.home.plan)
    host(["home", "export"], parsedCommand.home.export)
    host(["home", "facts"], parsedCommand.home.facts)
    host(["system", "plan"], parsedCommand.system.plan)
    host(["system", "apply"], parsedCommand.system.apply)
    host(["system", "sync"], parsedCommand.system.sync)
    host(["system", "rollback"], parsedCommand.system.rollback)
    host(["infra", "plan"], parsedCommand.infra.plan)
    host(["infra", "apply"], parsedCommand.infra.apply)
    host(["infra", "image"], parsedCommand.infra.image)
    host(["anywhere"], parsedCommand.anywhere)
    host(["deploy-agent"], parsedCommand.deployAgent.call)
    host(["deploy-agent", "compile-profile"],
      parsedCommand.deployAgent.compileProfile)
    # The resolver still refuses a `--host` the variable contradicts, with
    # its own message and exit 2, as before the variable was declared.
    block:
      let s = newScratch()
      defer: s.dispose()
      let refused = s.run(["home", "plan", "--host=other"],
        [("REPRO_HOST", "envhost")])
      check refused.code == 2
      check "--host other conflicts with $REPRO_HOST=envhost" in
        refused.output
      let empty = s.run(["home", "plan", "--host="],
        [("REPRO_HOST", "envhost")])
      check empty.code == 2
      check "--host needs a non-empty name" in empty.output
    # `repro home enable|disable --host` names the TARGET entry, which may
    # differ from this machine's `$REPRO_HOST`: it declares no variable.
    withRoundEnv([("REPRO_HOST", "envhost")]):
      check parsed(["home", "enable", "a", "--host=other"]) == -1
      check parsedCommand.home.enable.host == some("other")
      check parsed(["home", "disable", "a"]) == -1
      check parsedCommand.home.disable.host.isNone

  test "--progress wins over the $IN_AGENT_SHELL default, in both orders":
    # `repro build`'s progress default is quiet in an agent's shell. That is
    # a default rule, not a value the variable supplies, so `--progress`
    # (and the variables it declares) must win over it: the build's own
    # resolver (`buildProgressModeFor`) on the build's own parse.
    const Names = ["IN_AGENT_SHELL", "REPROBUILD_PROGRESS", "REPRO_PROGRESS"]
    var saved: seq[(string, bool, string)]
    for name in Names:
      saved.add((name, existsEnv(name), getEnv(name)))
      delEnv(name)
    proc modeOf(args: seq[string]): BuildProgressMode =
      let (c, _) = loadBuildCommandLine(args)
      buildProgressModeFor(c.progress,
        inAgentShell = getEnv("IN_AGENT_SHELL").len > 0)
    try:
      # Outside an agent's shell: the bar, or the flag's mode.
      check modeOf(newSeq[string]()) == bpmBarLine
      check modeOf(@["--progress=lines"]) == bpmLines
      # In one: quiet without the flag, the flag's mode with it.
      putEnv("IN_AGENT_SHELL", "1")
      check modeOf(newSeq[string]()) == bpmQuiet
      check modeOf(@["--progress=lines"]) == bpmLines
      check modeOf(@["--progress=simple-dots"]) == bpmSimpleDots
      # A value from the flag's own variable wins over the default too, and
      # the typed flag over that variable.
      putEnv("REPROBUILD_PROGRESS", "dots")
      check modeOf(newSeq[string]()) == bpmDots
      check modeOf(@["--progress=lines"]) == bpmLines
    finally:
      for (name, present, value) in saved:
        if present: putEnv(name, value) else: delEnv(name)

  test "the help names each variable once, through the generated note":
    for (path, name) in [(@["store", "gc"], "REPRO_STORE_ROOT"),
        (@["store", "daemon"], "REPROSTORED_ENDPOINT"),
        (@["cargo", "gc"], "CARGO_TARGET_DIR"),
        (@["cargo", "gc"], "REPRO_CARGO_GC_KEEP_SETS"),
        (@["cargo", "gc"], "REPRO_CARGO_GC_MIN_AGE"),
        (@["gateway", "pre-receive"], "GIT_DIR"),
        (@["home", "add"], "REPRO_HOME_PACKAGE_CATALOG"),
        (@["home", "plan"], "REPRO_HOST"),
        (@["exec"], "REPROBUILD_WORK_ROOT"),
        (@["develop"], "REPROBUILD_WORK_ROOT")]:
      let page = ReproCommandLine.helpText(path)
      checkpoint(path.join(" ") & ":\n" & page)
      check ("[env: " & name & "]") in page
      # The hand-written `(default: `$NAME`, ...)` is gone.
      check ("default: `$" & name & "`") notin page

suite "a variable set in nearly every environment changes no command line":

  test "$SHELL is not --shell: `repro shell -- <command>` is not refused":
    let s = newScratch()
    defer: s.dispose()
    let shellVar = when defined(windows): "COMSPEC" else: "SHELL"
    # The command is refused only for a `--shell` written on the command
    # line. Without one it goes on to resolve the (absent) project and
    # fails there, exit 1; nothing runs.
    let direct = s.run(["shell", "--", "true"], [(shellVar, "/bin/sh")])
    check direct.code == 1
    check "`--shell` has no effect" notin direct.output
    let refused = s.run(["shell", "--shell=/bin/sh", "--", "true"],
      [(shellVar, "/bin/sh")])
    check refused.code == 2
    check "`--shell` has no effect" in refused.output
    withRoundEnv([(shellVar, "/bin/sh")]):
      check parsed(["shell", "--", "true"]) == -1
      check not reproGivenOnCommandLine(parsedOrigins.shell.call.shell)
    check entriesUnder(s.cwd).len == 0

  test "$GIT_DIR, which git sets for every hook, reaches only the gateway":
    # The variables a command line looks up are the ones its command (and
    # those below it) declares; a hook's own command lines declare none.
    withRoundEnv([("GIT_DIR", "/some/repo/.git")]):
      check "GIT_DIR" notin reproDeclaredEnvFor(["hooks", "dispatch",
        "pre-push"])
      check "GIT_DIR" notin reproDeclaredEnvFor(["check"])
      check "GIT_DIR" notin reproDeclaredEnvFor(["sync"])
      check reproDeclaredEnvFor(["gateway", "pre-receive"]).getOrDefault(
        "GIT_DIR") == "/some/repo/.git"
      # And a hook's command line parses with it as without it.
      check parsed(["hooks", "dispatch", "pre-push"]) == -1

  test "$REPROBUILD_WORK_ROOT picks no form of `repro develop`":
    let s = newScratch()
    defer: s.dispose()
    # The overlay and drop forms refuse a typed `--work-root`; the variable
    # must not make them refuse, nor route them elsewhere: each line gives
    # the same outcome with and without it.
    for argv in [@["develop", "some-dep", "--source=" & s.cwd / "absent"],
                 @["develop", "--drop=some-dep"],
                 @["develop", "--list-overrides"]]:
      let without = s.run(argv)
      let with = s.run(argv, [("REPROBUILD_WORK_ROOT", s.home / "w")])
      check with.code == without.code
      check with.output == without.output
      check "unsupported develop flag" notin with.output
    # A typed `--work-root` still names the target form.
    let typed = s.run(["develop", "--drop=some-dep", "--work-root=" &
      s.home / "w"])
    check typed.code != 0

  test "an unparsable $REPRO_CARGO_GC_* is a warning, the flag's an error":
    let s = newScratch()
    defer: s.dispose()
    let target = s.home / "target"
    createDir(target)
    let warned = s.run(["cargo", "gc", "--dry-run", "--target-dir=" & target],
      [("REPRO_CARGO_GC_KEEP_SETS", "many")])
    check warned.code != 2
    check "keep sets from $REPRO_CARGO_GC_* is 'many'" in warned.output
    check "invalid --keep-sets" notin warned.output
    let flagged = s.run(["cargo", "gc", "--dry-run", "--target-dir=" & target,
      "--keep-sets=many"])
    check flagged.code == 2
    check "invalid --keep-sets or --min-age" in flagged.output
    # A good value from the variable is reported as the variable's.
    let fromEnv = s.run(["cargo", "gc", "--dry-run", "--target-dir=" & target],
      [("REPRO_CARGO_GC_KEEP_SETS", "5")])
    check fromEnv.code == 0
    check "keep-sets=5 (environment)" in fromEnv.output
