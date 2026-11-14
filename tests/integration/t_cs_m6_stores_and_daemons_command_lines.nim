## The store and daemon commands (`daemon`, `store`, `cas`, `cache`,
## `bundle`, `reap`, `launch-plan`, `cert-signer`, `self`) take their command
## lines from repro's description: each answers `--help` (and `repro help
## <command>`) from its declarations, a command line the description does not
## accept is a usage error (exit 2) naming the command, and a command line it
## accepts reaches the command with the values it gave.
##
## The arms, and what makes each one evidence:
##
##   1. Help. Every command and subcommand of the group prints its generated
##      usage on stdout and exits 0, through `<command> --help`, `help
##      <command>`, and the spellings the commands kept (`bundle help`,
##      `cache help`, a bare `cache`). Internal and hidden declarations stay
##      out of the help they must not be in. Before this group moved, `repro
##      store --help`, `repro self --help` and `repro daemon --help` were
##      errors, so the arm can fail.
##   2. Usage errors. Unknown flags, a missing or unknown subcommand, a
##      missing or extra argument, a value that is not a number, a value
##      flag spelt with a space where only `--flag=VALUE` is accepted, and a
##      flag before the subcommand where only the subcommand declares it:
##      each exits 2 and names the command, and none reaches the command
##      (nothing is written to the scratch directory or the scratch HOME).
##   3. Values reach the command. Each check depends on a parsed value: the
##      state root `reap` reports, the refusal of `repro build`'s spellings,
##      `cas`'s namespace flag before or after the subcommand, the default
##      log path `daemon logs` derives from `--state-dir`, the key
##      `cache derive-key` derives (and the CPU alias it canonicalises), and
##      the checks the commands still make on parsed values (`store gc`'s
##      budget flags, `--to`, `--root`, `--dev`, a wildcard `--bind`, a
##      digest's length) with their own messages and exit codes.
##
## No mocks: the real `build/bin/repro` runs as a subprocess, in an empty
## directory with a fresh HOME and XDG directories. Nothing here starts a
## daemon or contacts a cache: every command line either fails before it
## would, or only reads paths under the scratch directories.

import std/[os, strutils, tempfiles, unittest]

import repro_test_support

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc entriesUnder(dir: string): seq[string] =
  for entry in walkDirRec(dir, yieldFilter = {pcFile, pcDir, pcLinkToFile,
      pcLinkToDir}):
    result.add(entry)

type Scratch = object
  cwd, home: string
  env: seq[(string, string)]

proc newScratch(): Scratch =
  result.cwd = createTempDir("repro-cs-m6-g3-cwd-", "")
  result.home = createTempDir("repro-cs-m6-g3-home-", "")
  let home = result.home
  result.env = @[("HOME", home), ("XDG_STATE_HOME", home / "state"),
    ("XDG_CONFIG_HOME", home / "config"), ("XDG_CACHE_HOME", home / "cache"),
    ("XDG_DATA_HOME", home / "data"), ("XDG_RUNTIME_DIR", home / "run"),
    ("REPRO_STORE_ROOT", home / "store"),
    ("REPRO_BINARY_CACHE_URL", "http://127.0.0.1:9")]

proc dispose(s: Scratch) =
  removeDir(s.cwd)
  removeDir(s.home)

proc run(s: Scratch; argv: openArray[string]): tuple[code: int,
         output: string] =
  let res = runShell(shellCommand(@[reproBinary()] & @argv, s.env),
    cwd = s.cwd, timeoutMs = 60_000)
  checkpoint("repro " & argv.join(" ") & " -> exit " & $res.code & "\n" &
    res.output)
  (res.code, res.output)

const Digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

suite "CS-M6: the store and daemon command lines":

  test "every command of the group answers help from its declarations":
    let s = newScratch()
    defer: s.dispose()
    var lines: seq[(seq[string], string)] = @[]
    for path in [@["daemon"], @["daemon", "status"], @["daemon", "start"],
        @["daemon", "stop"], @["daemon", "restart"], @["daemon", "logs"],
        @["daemon", "sessions"], @["daemon", "serve"], @["store"],
        @["store", "gc"], @["store", "recover"], @["store", "roots"],
        @["store", "list"], @["store", "optimise"], @["store", "materialize"],
        @["store", "closure"], @["store", "export"], @["store", "import"],
        @["store", "copy"], @["store", "daemon"], @["store", "daemon", "start"],
        @["store", "serve"], @["cas"], @["cas", "gc"], @["cas", "verify"],
        @["cas", "path"], @["cas", "exists"], @["cache"],
        @["cache", "lookup"], @["cache", "substitute"], @["cache", "publish"],
        @["cache", "derive-key"], @["cache", "gen-key"], @["bundle"],
        @["bundle", "create"], @["bundle", "publish"], @["bundle", "restore"],
        @["reap"], @["launch-plan"], @["launch-plan", "show"],
        @["launch-plan", "id"], @["cert-signer"], @["cert-signer", "serve"],
        @["cert-signer", "registration"], @["self"], @["self", "install"],
        @["self", "provision"], @["self", "hold"], @["self", "which"],
        @["self", "list"], @["self", "prune-roots"]]:
      let usage = "Usage: repro " & path.join(" ")
      lines.add((path & @["--help"], usage))
      lines.add((@["help"] & path, usage))
    lines.add((@["store", "optimize", "-h"], "Usage: repro store optimise"))
    lines.add((@["cache"], "Usage: repro cache"))
    lines.add((@["cache", "help"], "Usage: repro cache"))
    lines.add((@["bundle", "help"], "Usage: repro bundle"))
    lines.add((@["bundle", "help", "create"], "Usage: repro bundle create"))
    for (argv, usage) in lines:
      let res = s.run(argv)
      check res.code == 0
      check usage in res.output
    # The declarations' own words reach the help, and what is internal or
    # hidden does not.
    let daemonHelp = s.run(["daemon", "--help"]).output
    check "--state-dir" in daemonHelp
    check "serve" in daemonHelp
    check "--daemon-exe" notin daemonHelp
    check "--restart-run-id" notin daemonHelp
    check "--budget" in s.run(["store", "gc", "--help"]).output
    check "--after-bootstrap" notin s.run(["bundle", "restore",
      "--help"]).output
    let reapHelp = s.run(["reap", "--help"]).output
    check "--state-root" in reapHelp
    check "--hard-rebuild" notin reapHelp
    check "--platform-cpu" in s.run(["cache", "publish", "--help"]).output
    check "--bind" in s.run(["cert-signer", "serve", "--help"]).output
    check "--from" in s.run(["self", "install", "--help"]).output
    # Internal subcommands are listed by their namespace, not by the
    # primary help.
    let primary = s.run(["--help"]).output
    check "launch-plan" in primary
    check "--daemon-exe" notin primary
    check entriesUnder(s.cwd).len == 0
    check entriesUnder(s.home).len == 0

  test "a command line the description does not accept is a usage error":
    let s = newScratch()
    defer: s.dispose()
    for (argv, names) in [
        (@["daemon"], "'repro daemon' needs a subcommand"),
        (@["daemon", "reload"], "unknown subcommand 'reload' for " &
          "'repro daemon'"),
        (@["daemon", "status", "--bogus"], "'repro daemon status'"),
        (@["daemon", "status", "extra"], "'repro daemon status'"),
        (@["store"], "'repro store' needs a subcommand"),
        (@["store", "compact"], "unknown subcommand 'compact' for " &
          "'repro store'"),
        (@["store", "gc", "--budget", "3G"], "'repro store gc'"),
        (@["store", "gc", "--grace-seconds=soon"], "'repro store gc'"),
        (@["store", "list", "--json"], "'repro store list'"),
        (@["store", "--json", "list"], "'repro store'"),
        (@["store", "materialize", "a"], "'repro store materialize'"),
        (@["store", "export", "--zstd-level=high"], "'repro store export'"),
        (@["store", "daemon"], "'repro store daemon' needs a subcommand"),
        (@["cas"], "'repro cas' needs a subcommand"),
        (@["cas", "verify"], "'repro cas verify'"),
        (@["cas", "verify", Digest, Digest], "'repro cas verify'"),
        (@["cas", "gc", "--keep"], "'repro cas gc'"),
        (@["cache", "frob"], "unknown subcommand 'frob' for 'repro cache'"),
        (@["cache", "lookup"], "'repro cache lookup'"),
        (@["cache", "lookup", Digest, "extra"], "'repro cache lookup'"),
        (@["cache", "publish", Digest], "'repro cache publish'"),
        (@["cache", "derive-key", "--nonsense=1"], "'repro cache derive-key'"),
        (@["bundle"], "'repro bundle' needs a subcommand"),
        (@["bundle", "create"], "'repro bundle create'"),
        (@["bundle", "create", "sel", "--level=high"],
          "'repro bundle create'"),
        (@["bundle", "publish", "dir", "--json"], "'repro bundle publish'"),
        (@["reap", "--bogus"], "'repro reap'"),
        (@["reap", "--state-root", "x"], "'repro reap'"),
        (@["launch-plan"], "'repro launch-plan' needs a subcommand"),
        (@["launch-plan", "show"], "'repro launch-plan show'"),
        (@["cert-signer"], "'repro cert-signer' needs a subcommand"),
        (@["cert-signer", "serve", "--port=any"], "'repro cert-signer serve'"),
        (@["cert-signer", "registration", "--bind=x"],
          "'repro cert-signer registration'"),
        (@["self"], "'repro self' needs a subcommand"),
        (@["self", "use"], "unknown subcommand 'use' for 'repro self'"),
        (@["self", "list", "--version=1"], "'repro self list'"),
        (@["self", "which", "--project", "x"], "'repro self which'")]:
      let res = s.run(argv)
      check res.code == 2
      check names in res.output
    check entriesUnder(s.cwd).len == 0
    check entriesUnder(s.home).len == 0

  test "the values the description accepts reach the command":
    let s = newScratch()
    defer: s.dispose()
    let missing = s.home / "no-state"
    let reap = s.run(["reap", "--once", "--state-root=" & missing])
    check reap.code == 0
    check ("repro reap: no state store at " & missing) in reap.output
    for spelling in ["--hard-rebuild", "--rebuild-host-bound"]:
      let refused = s.run(["reap", spelling])
      check refused.code == 2
      check ("repro reap: " & spelling & " is a `repro build` verb") in
        refused.output
      check "repro reap --force" in refused.output

    # `cas`'s store root is the namespace's own flag: either side of the
    # subcommand. An absent blob exits 1 either way.
    let casRoot = s.home / "cas-store"
    check s.run(["cas", "--store-root=" & casRoot, "exists", Digest]).code == 1
    check s.run(["cas", "exists", Digest, "--store-root=" & casRoot]).code == 1
    let shortDigest = s.run(["cas", "path", "abc"])
    check shortDigest.code == 2
    check "not a 64-char hex digest" in shortDigest.output

    # `daemon logs` reads the log `--state-dir` implies, from either side of
    # the subcommand; `--log` replaces it.
    let stateDir = s.home / "daemon-state"
    let logs = s.run(["daemon", "logs", "--state-dir", stateDir])
    check logs.code == 0
    check ("no log file at " & (stateDir / "logs" / "repro-daemon.log")) in
      logs.output
    let logsBefore = s.run(["daemon", "--state-dir=" & stateDir, "logs",
      "--log", s.home / "elsewhere.log"])
    check logsBefore.code == 0
    check ("no log file at " & (s.home / "elsewhere.log")) in
      logsBefore.output

    # `cache derive-key` derives the key from the identity flags, with the
    # CPU alias canonicalised.
    let key = s.run(["cache", "derive-key", "--package-name=zlib",
      "--package-version=1.3", "--platform-cpu=amd64", "--platform-os=linux",
      "--platform-libc="])
    check key.code == 0
    check key.output.strip().len == 64
    let sameKey = s.run(["cache", "derive-key", "--platform-os=linux",
      "--package-version=1.3", "--package-name=zlib",
      "--platform-cpu=x86_64"])
    check sameKey.code == 0
    check sameKey.output.strip() == key.output.strip()
    let badOption = s.run(["cache", "derive-key", "--option=nameonly"])
    check badOption.code == 2
    check "--option requires name=value form" in badOption.output
    let badCpu = s.run(["cache", "derive-key", "--platform-cpu=sparc"])
    check badCpu.code == 1
    check "names no CPU family" in badCpu.output
    let badKey = s.run(["cache", "lookup", "abc"])
    check badKey.code == 1
    check "repro cache: error: entry-key hex must be 64 chars" in
      badKey.output

    for (argv, code, message) in [
        (@["store", "gc", "--dry-run"], 2,
          "--target / --keep-recent / --evict-cas / --dry-run need " &
          "--budget=SIZE"),
        (@["store", "gc", "--budget=1G", "--target=2G"], 2,
          "--target must not exceed --budget"),
        (@["store", "gc", "--budget=lots"], 2,
          "--budget wants a size such as 384G"),
        (@["store", "copy", "prefixes/x"], 2,
          "repro store copy: --to=STORE-ROOT is required"),
        (@["store", "closure"], 2,
          "repro store closure: at least one --root=DIR is required"),
        (@["store", "daemon", "status"], 2,
          "repro store daemon: only --dev is implemented"),
        (@["store", "serve"], 2, "only --dev is implemented"),
        (@["launch-plan", "show", "abc"], 2,
          "expected 64-char hex digest, got 3 chars"),
        (@["launch-plan", "id", s.home / "absent.rblp"], 1,
          "repro launch-plan id: error:"),
        (@["self", "install", "--version=1.0"], 2,
          "repro self install: --from=DIR and --version=V are both required"),
        (@["self", "provision"], 2, "repro self provision: --version=V is " &
          "required"),
        (@["cert-signer", "registration", "--state", s.home / "signer",
          "--worker", "abc"], 2, "usage: repro cert-signer registration"),
        (@["cert-signer", "serve", "--state=" & s.home / "signer",
          "--identity=" & s.home / "id", "--anchors=" & s.home / "anchors",
          "--authorized=" & s.home / "authorized", "--bind", "0.0.0.0"], 2,
          "refusing wildcard bind 0.0.0.0"),
        (@["bundle", "publish", s.home / "bundle"], 2,
          "repro bundle publish: a bundle directory and --to=")]:
      let res = s.run(argv)
      check res.code == code
      check message in res.output
    # The refusals above wrote nothing; `reap` and `daemon logs` only read.
    check not dirExists(missing)
    check not dirExists(stateDir)
    # `cas` opened the store at the root it was given, and only there.
    check dirExists(casRoot)
    check not dirExists(s.home / "store")
    check not dirExists(s.home / "signer")
