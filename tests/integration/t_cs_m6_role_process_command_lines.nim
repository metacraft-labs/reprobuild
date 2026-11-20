## The command lines of the processes repro spawns of itself (round 8b of
## repro's move onto its description): `repro internal <role>`, their hidden
## `__repro-<role>` spellings, `repro daemon serve` and `repro store serve`.
##
## The arms, and what makes each one evidence:
##
##   1. ROUND TRIP. For every role, the words the renderer writes from a set
##      of values (`reproArgvOf`, what the engine's spawners call) parse,
##      through the generated parser, back to exactly those values. The
##      values are the awkward ones a spawner really passes: empty words,
##      values that start with `-` or `--`, values holding `=` and spaces,
##      repeated list flags in order, switches on and off, and a command
##      after `--` that carries `--help` of its own. A renderer that wrote a
##      value as the next word, dropped an empty one or lost a list element
##      fails here (the falsifying mutation in the round's record).
##   2. THE OTHER SPELLING. Each `__repro-<role>` word reads the same words to
##      the same values as `internal <role>`: they are one declaration.
##   3. THE SPAWNERS BELOW THE PROGRAM. The RunQuota launcher's words
##      (`helperCliArgs`), the daemon's (`daemonProcessArgs`) and the store
##      daemon's (`storeServeArgs`) are written in libraries that cannot link
##      the parser; each parses back to the request, configuration and
##      command it was written from, a width flag spelt `-j` and a command
##      with its own `--` and `--help` included.
##   4. WHAT INSTALLED HOOKS RUN. The words the `.envrc` block and the native
##      shell hooks an older `repro` installed run (`__repro-direnv-activate
##      "$PWD" --dev-env-stats "$X"`, `__repro-native-shell-activate "$PWD"
##      --shell bash --previous-artifact "" ...`: values as the next word, some
##      empty) still parse to the request those hooks mean. Mixed versions:
##      a newer `repro` must serve what an older one wrote into rc files.
##   5. A ROLE'S BAD COMMAND LINE IS A USAGE ERROR. An unknown flag, a
##      missing required flag and a missing positional are clispec usage
##      errors, not words a role silently ignores (the hand-written readers
##      took the first `--module` and skipped every word they did not know).
##
## No mocks: the real description, the generated parser and renderer, and
## the real spawn builders of `repro_runquota`, `repro_daemon_core` and
## `repro_store_daemon`. Nothing is run: every case parses words.

import std/[options, os, sequtils, strutils, unittest]

import repro_cli_support/cli_program
import repro_cli_support/daemon_cli
from repro_cli_support/runquota_helper_cli import selectsRunQuotaHelper
import repro_daemon_core
import repro_runquota
import repro_store_daemon

proc parse(argv: openArray[string]): ReproCommandLine =
  ## ``argv`` through the generated parser, with no environment.
  ReproCommandLine.load(argv)

proc usageError(argv: openArray[string]): bool =
  ## Whether the generated parser refuses ``argv`` as a usage error.
  try:
    discard parse(argv)
    false
  except CliUsageError:
    true

const
  Awkward = ["", "-j", "--looks-like-a-flag", "a=b c", "with space"]
    ## Values a spawner passes that a value-as-next-word renderer would get
    ## wrong.

suite "CS-M6 round 8b: the role processes' command lines":

  test "every role's rendered words parse back to its values":
    # compile-provider: every flag, a list in order, a switch.
    for awkward in Awkward:
      let argv = reproArgvOf(["internal", "compile-provider"], [
        ("module", @["m.nim"]), ("out", @[awkward]),
        ("artifact", @["/a/art"]), ("interfaceArtifact", @["/i"]),
        ("interfaceFingerprint", @["fp:" & awkward]),
        ("workDir", @["/w"]), ("scratchDir", @[awkward]),
        ("anchor", @["/x", awkward, "/y"]), ("recipeRelative", @["true"])])
      checkpoint(argv.join(" | "))
      let c = parse(argv).internal.compileProvider
      check c.module == "m.nim"
      check c.`out` == awkward
      check c.artifact == "/a/art"
      check c.interfaceArtifact == "/i"
      check c.interfaceFingerprint == "fp:" & awkward
      check c.workDir == "/w"
      check c.scratchDir == awkward
      check c.anchor == @["/x", awkward, "/y"]
      check c.recipeRelative
    # extract-interface: a switch left off, then on.
    for requireStub in [false, true]:
      let argv = reproArgvOf(["internal", "extract-interface"], [
        ("module", @["/r/repro.nim"]), ("artifact", @["/o/a"]),
        ("stub", @["/o/s.nim"]), ("workDir", @["/w"]),
        ("consumerRoot", @["."]), ("resourceModule", @["-res.nim"]),
        ("requireStub", @[$requireStub]),
        ("extraPath", @["/p1", "--p2"])])
      let c = parse(argv).internal.extractInterface
      check c.requireStub == requireStub
      check c.consumerRoot == "."
      check c.resourceModule == "-res.nim"
      check c.extraPath == @["/p1", "--p2"]
      check not c.recipeRelative
    # The profile helpers.
    block:
      let c = parse(reproArgvOf(["internal", "compile-profile"], [
        ("profile", @["/p/home.nim"]), ("binary", @["/b"]),
        ("nimcache", @["/n"]), ("repoRoot", @["/r"]),
        ("verbose", @["true"])])).internal.compileProfile
      check (c.profile, c.binary, c.nimcache, c.repoRoot, c.verbose) ==
        ("/p/home.nim", "/b", "/n", "/r", true)
      let p = parse(reproArgvOf(["internal", "probe-profile-platforms"], [
        ("profile", @["/p"]), ("out", @["-o"]), ("nimcache", @["/n"]),
        ("repoRoot", @["/r"])])).internal.probeProfilePlatforms
      check (p.profile, p.`out`, p.nimcache, p.repoRoot) ==
        ("/p", "-o", "/n", "/r")
    # The development-environment helpers.
    block:
      let c = parse(reproArgvOf(["internal", "dev-env-introspect"], [
        ("providerBinary", @["/pb"]), ("providerArtifactId", @["id"]),
        ("projectRoot", @["/proj"]), ("out", @["/o"]),
        ("protocolRoot", @["/pr"]), ("entryPoint", @[""]),
        ("activity", @["a,b"]), ("lockSlice", @["s"]),
        ("developOverrides", @["/d.json"])])).internal.devEnvIntrospect
      check (c.providerBinary, c.providerArtifactId, c.projectRoot, c.`out`,
        c.protocolRoot, c.entryPoint, c.activity, c.lockSlice,
        c.developOverrides) == ("/pb", "id", "/proj", "/o", "/pr", "", "a,b",
          "s", "/d.json")
      let r = parse(reproArgvOf(["internal", "render-dev-env-shell"], [
        ("artifact", @["/a"]), ("out", @["/o"]),
        ("navigatorStats", @["/n"])])).internal.renderDevEnvShell
      check (r.artifact, r.`out`, r.navigatorStats) == ("/a", "/o", "/n")
      let d = parse(reproArgvOf(["internal", "direnv-activate"], [
        ("activity", @["web", "db,cache"]), ("workRoot", @["/w"]),
        ("lockSlice", @[""]), ("devEnvStats", @["/s"]),
        ("directory", @["-dir"])])).internal.direnvActivate
      check d.activity == @["web", "db,cache"]
      check (d.workRoot, d.lockSlice, d.devEnvStats, d.directory) ==
        ("/w", "", "/s", "-dir")
      let n = parse(reproArgvOf(["internal", "native-shell-activate"], [
        ("shell", @["fish"]), ("previousArtifact", @[""]),
        ("previousProjectRoot", @[""]), ("devEnvStats", @[""]),
        ("directory", @["/home/u/p"])])).internal.nativeShellActivate
      check (n.shell, n.previousArtifact, n.previousProjectRoot,
        n.devEnvStats, n.directory) == ("fish", "", "", "", "/home/u/p")
    # The development session's processes.
    block:
      let s = parse(reproArgvOf(["internal", "dev-session-supervisor"], [
        ("sessionId", @["s1"]), ("mode", @["dev"]),
        ("projectRoot", @["/p"]), ("module", @["/p/repro.nim"]),
        ("outDir", @["/o"]), ("workDir", @["/w"]), ("artifact", @["/a"]),
        ("activity", @[""]), ("lockSlice", @[""]),
        ("developOverrides", @[""]), ("monitorCli", @["/m"]),
        ("monitorShim", @["/m.so"]), ("http", @[""]),
        ("debounceMs", @["40"]), ("httpAllowRemote", @["true"]),
        ("foreground", newSeq[string]())])).internal.devSessionSupervisor
      check (s.sessionId, s.mode, s.projectRoot, s.module, s.outDir,
        s.workDir, s.artifact, s.activity, s.http, s.monitorCli,
        s.monitorShim) == ("s1", "dev", "/p", "/p/repro.nim", "/o", "/w",
          "/a", "", "", "/m", "/m.so")
      check s.debounceMs == 40
      check s.httpAllowRemote
      check not s.foreground
      let h = parse(reproArgvOf(["internal", "dev-session-http"], [
        ("sessionDir", @["/sd"]), ("parentPid", @["4242"]),
        ("supervised", @["true"]), ("sessionId", @["s1"]),
        ("host", @["127.0.0.1"]), ("port", @["0"])])).internal.devSessionHttp
      check (h.sessionDir, h.parentPid, h.supervised, h.sessionId, h.host,
        h.port, h.httpAllowRemote) ==
        ("/sd", 4242, true, "s1", "127.0.0.1", 0, false)
    # CMake regeneration, the shared-pool transport and resolve-package.
    block:
      let c = parse(reproArgvOf(["internal", "cmake-regenerate"], [
        ("metadata", @["/m"]), ("publicCli", @["/bin/repro"]),
        ("depfile", @["/d"])])).internal.cmakeRegenerate
      check (c.metadata, c.publicCli, c.depfile) ==
        ("/m", "/bin/repro", "/d")
      check parse(reproArgvOf(["internal", "shared-pool-upload-pack"],
        [("pool", @["/pool with space"])])).internal.sharedPoolUploadPack.pool ==
        "/pool with space"
      let r = parse(reproArgvOf(["internal", "resolve-package"], [
        ("consumerDir", @["/c"]), ("name", @["-pkg"])])).internal.resolvePackage
      check (r.consumerDir, r.name) == ("/c", "-pkg")
    # The RunQuota helper: a command after `--` with its own `--help`.
    block:
      let c = parse(reproArgvOf(["internal", "runquota-helper"], [
        ("resultPath", @["/r.json"]), ("cpu", @["1500"]),
        ("widthFlag", @["-j"]), ("pool", @[""]),
        ("env", @["A=1", "B=x=y"]), ("isolatedEnv", @["true"]),
        ("command", @["make", "--help", "--", "-x"])])).internal.runquotaHelper
      check c.resultPath == "/r.json"
      check c.cpu == 1500
      check c.widthFlag == "-j"
      check c.pool == ""
      check c.env == @["A=1", "B=x=y"]
      check c.isolatedEnv
      check c.command == @["make", "--help", "--", "-x"]

  test "each __repro-<role> spelling reads the same words as internal <role>":
    let words = reproArgvOf(["internal", "compile-profile"], [
      ("profile", @["/p"]), ("binary", @["-b"]), ("nimcache", @[""]),
      ("repoRoot", @["/r"])], commandWords = false)
    let a = parse(@["internal", "compile-profile"] & words).internal.compileProfile
    let b = parse(@["__repro-compile-profile"] & words).reproCompileProfile
    check (a.profile, a.binary, a.nimcache, a.repoRoot, a.verbose) ==
      (b.profile, b.binary, b.nimcache, b.repoRoot, b.verbose)
    # Every role that has a hidden spelling parses under it.
    for (internal, hidden) in [
        ("runquota-helper", "__repro-runquota-helper"),
        ("compile-provider", "__repro-compile-provider"),
        ("extract-interface", "__repro-extract-interface"),
        ("compile-profile", "__repro-compile-profile"),
        ("probe-profile-platforms", "__repro-probe-profile-platforms"),
        ("dev-env-introspect", "__repro-dev-env-introspect"),
        ("render-dev-env-shell", "__repro-render-dev-env-shell"),
        ("direnv-activate", "__repro-direnv-activate"),
        ("native-shell-activate", "__repro-native-shell-activate"),
        ("dev-session-supervisor", "__repro-dev-session-supervisor"),
        ("dev-session-http", "__repro-dev-session-http"),
        ("cmake-regenerate", "__repro-cmake-regenerate")]:
      checkpoint(hidden)
      check reproCommandAt([hidden]) >= 0
      check reproCommandAt(["internal", internal]) >= 0
      check not reproCommandIsShown(reproCommandAt([hidden]))

  test "the spawners below the program write words that parse back":
    # The RunQuota launcher.
    let request = ReproResourceRequest(label: "lbl", commandStatsId: "st",
      cpuMilli: 2000, memoryBytes: 1'u64 shl 33, namedPool: "",
      namedPoolUnits: 0, namedPoolCapacity: 0, cpuMinMilli: 500,
      cpuPreferredMilli: 1500)
    let command = ReproCommandSpec(argv: @["cargo", "test", "--", "--help"],
      cwd: "", env: @["K=v=w", "EMPTY="], stdoutLimit: 100,
      stderrLimit: 200, isolatedEnv: true, widthFlag: "-j")
    let helper = helperCliArgs(request, command, "/tmp/result.json")
    checkpoint(helper.join(" | "))
    check helper[0 .. 1] == @["internal", "runquota-helper"]
    # A fixture standing in for the CLI recognises the role in either
    # spelling, and nothing else.
    check selectsRunQuotaHelper(helper)
    check selectsRunQuotaHelper(@["__repro-runquota-helper"] & helper[2 .. ^1])
    check not selectsRunQuotaHelper(@["internal", "compile-profile"])
    check not selectsRunQuotaHelper(@["internal"])
    let h = parse(helper).internal.runquotaHelper
    check h.resultPath == "/tmp/result.json"
    check (h.label, h.stats, h.pool, h.cwd, h.widthFlag) ==
      ("lbl", "st", "", "", "-j")
    # The request's effective sizes (the CPU and memory given, here).
    check h.cpu == 2000
    check h.mem == int(1'u64 shl 33)
    check (h.cpuMin, h.cpuPref, h.stdoutLimit, h.stderrLimit) ==
      (500, 1500, 100, 200)
    check h.env == @["K=v=w", "EMPTY="]
    check h.isolatedEnv
    check h.command == @["cargo", "test", "--", "--help"]
    # The per-user daemon, with every optional flag set.
    var daemon = defaultUserDaemonConfig()
    daemon.endpoint = "/run/user/1/repro/d.sock"
    daemon.stateDir = "/home/u/.local/state/repro"
    daemon.logPath = "/home/u/d.log"
    daemon.devMode = true
    daemon.sourceExe = "/opt/repro/bin/reprobuild"
    daemon.stagedGenerationDir = "/s/gen-2"
    daemon.previousStagedGenerationDir = "/s/gen-1"
    daemon.restartRunId = "run-7"
    daemon.systemScope = true
    daemon.leaseStoreRoot = "/var/lib/repro/state"
    daemon.peerCacheSpec = "lan://10.0.0.0/24?listen=7000"
    daemon.trustProfile = "hardened"
    let words = daemonProcessArgs(daemon)
    check words[0 .. 1] == @["daemon", "serve"]
    let read = userDaemonConfigOfArgs(words)
    check read.foreground
    check (read.endpoint, read.stateDir, read.logPath, read.devMode,
      read.sourceExe, read.stagedGenerationDir,
      read.previousStagedGenerationDir, read.restartRunId,
      read.systemScope, read.leaseStoreRoot, read.peerCacheSpec,
      read.trustProfile) == (daemon.endpoint, daemon.stateDir,
        daemon.logPath, true, daemon.sourceExe, daemon.stagedGenerationDir,
        daemon.previousStagedGenerationDir, daemon.restartRunId, true,
        daemon.leaseStoreRoot, daemon.peerCacheSpec, daemon.trustProfile)
    # The development store daemon.
    let store = DevDaemonConfig(endpoint: "/run/s.sock", storeRoot: "/st")
    let s = parse(storeServeArgs(store)).store.serve
    check s.dev
    check (s.endpoint, s.storeRoot) == ("/run/s.sock", "/st")

  test "the words installed shell hooks run still parse (mixed versions)":
    # `.envrc`, as `repro hooks ensure --shell-direnv` writes it.
    let d = parse(["__repro-direnv-activate", "/home/u/p", "--dev-env-stats",
      "/tmp/stats.json"]).reproDirenvActivate
    check (d.directory, d.devEnvStats) == ("/home/u/p", "/tmp/stats.json")
    check parse(["__repro-direnv-activate", "/home/u/p"]).
      reproDirenvActivate.directory == "/home/u/p"
    # The native bash/zsh/fish hooks: values as the next word, unset ones
    # empty.
    let n = parse(["__repro-native-shell-activate", "/home/u/p", "--shell",
      "zsh", "--previous-artifact", "", "--previous-project-root", "",
      "--dev-env-stats", "/tmp/s"]).reproNativeShellActivate
    check (n.directory, n.shell, n.previousArtifact, n.previousProjectRoot,
      n.devEnvStats) == ("/home/u/p", "zsh", "", "", "/tmp/s")
    # The PowerShell hook's shell name.
    check parse(["__repro-native-shell-activate", "C:\\p", "--shell",
      "powershell"]).reproNativeShellActivate.shell == "powershell"
    # The `internal` spelling reads them the same.
    let i = parse(["internal", "native-shell-activate", "/home/u/p",
      "--shell", "zsh", "--previous-artifact", "",
      "--previous-project-root", ""]).internal.nativeShellActivate
    check (i.directory, i.shell, i.previousArtifact) == ("/home/u/p", "zsh", "")

  test "a role's bad command line is a usage error":
    # An unknown flag.
    check usageError(["internal", "compile-profile", "--profile=/p",
      "--binary=/b", "--nimcache=/n", "--repo-root=/r", "--no-such-flag"])
    # A missing required flag (`--repo-root`).
    check usageError(["internal", "compile-profile", "--profile=/p",
      "--binary=/b", "--nimcache=/n"])
    # A missing positional, and a second one.
    check usageError(["internal", "native-shell-activate", "--shell=bash"])
    check usageError(["internal", "shared-pool-upload-pack", "/a", "/b"])
    # A runquota helper without its result path.
    check usageError(["__repro-runquota-helper", "--", "true"])
    # The control: the same command lines made whole parse.
    check not usageError(["internal", "compile-profile", "--profile=/p",
      "--binary=/b", "--nimcache=/n", "--repo-root=/r"])
    check not usageError(["internal", "native-shell-activate", "/d"])
    check not usageError(["__repro-runquota-helper", "--result=/r", "--",
      "true"])
    # A name the spawner gives that the role does not declare is refused at
    # the spawner, before any word is written.
    expect ValueError:
      discard reproArgvOf(["internal", "compile-profile"],
        [("noSuchParameter", @["x"])])
    expect ValueError:
      discard reproArgvOf(["internal", "no-such-role"], [])
