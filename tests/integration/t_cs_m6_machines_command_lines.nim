## The machine commands (`home`, `system`, `infra`, `anywhere`,
## `deploy-agent`, `hardware`, `disk`, `cargo`, `health`, `debug`) take their
## command lines from repro's description: each answers `--help` (and `repro
## help <command>`) from its declarations, a command line the description
## does not accept is a usage error (exit 2) naming the command, and a command
## line it accepts reaches the command with the values it gave.
##
## The arms, and what makes each one evidence:
##
##   1. Help. Every command and subcommand of the group (the internal ones
##      included) prints its generated usage on stdout and exits 0, through
##      `<command> --help`, `<command> -h` and `help <command>`, and `cargo
##      help`. Internal declarations stay out of the help they must not be in.
##      Before this group moved, `repro home --help`, `repro system --help`,
##      `repro infra plan --help` with a stray word, `repro disk apply -h`
##      and `repro hardware probe --help` were errors or ran the command, so
##      the arm can fail.
##   2. Usage errors. Unknown flags, a missing or unknown subcommand, a
##      missing or extra argument, a value that is not a number or not in its
##      set, and a flag of one subcommand given to another: each exits 2 and
##      names the command, and none reaches the command (nothing is written
##      to the scratch directory or the scratch HOME).
##   3. Values reach the command. Each check depends on a parsed value: the
##      pending notices that echo `disk generate --probe` and `disk image
##      --output/--size`; the checks the commands still make on parsed values
##      (both `--when` and `--if`, an empty `--check=`/`--output=`, two
##      `--allow`, a `--keep-generations` below 1, a negative retention
##      bound, `-j -1`, `--keep-sets=0`, `--target-*` without `--plan`, a
##      required flag left out, `--probe-c-compiler` with another option)
##      with their own messages and exit codes; `repro home --profile-dir`
##      reaching the command from either side of the subcommand word; `repro
##      hardware probe --output` writing exactly where it was told and
##      refusing to overwrite without `--regenerate`.
##
## No mocks: the real `build/bin/repro` runs as a subprocess, in an empty
## directory with a fresh HOME and XDG directories, `$REPRO_HOME_PROFILE_DIR`,
## `$REPRO_HOME_STATE_DIR` and `$REPRO_STORE_ROOT` under it. Every command
## line here either fails before it would change anything, or only reads
## (`home list` of a profile that does not exist, `debug artifact` of a file
## that does not exist) or writes under the scratch directories (`hardware
## probe --output`). Nothing touches the host's system or home state.

import std/[os, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip

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
  result.cwd = createTempDir("repro-cs-m6-g4-cwd-", "")
  result.home = createTempDir("repro-cs-m6-g4-home-", "")
  let home = result.home
  result.env = @[("HOME", home), ("XDG_STATE_HOME", home / "state"),
    ("XDG_CONFIG_HOME", home / "config"), ("XDG_CACHE_HOME", home / "cache"),
    ("XDG_DATA_HOME", home / "data"), ("XDG_RUNTIME_DIR", home / "run"),
    ("REPRO_STORE_ROOT", home / "store"),
    ("REPRO_HOME_PROFILE_DIR", home / "profile"),
    ("REPRO_HOME_STATE_DIR", home / "home-state"),
    ("REPRO_HOST", "cs-m6-machines")]

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

suite "CS-M6: the machine command lines":

  test "every command of the group answers help from its declarations":
    let s = newScratch()
    defer: s.dispose()
    var lines: seq[(seq[string], string)] = @[]
    for path in [@["home"], @["home", "add"], @["home", "remove"],
        @["home", "enable"], @["home", "disable"], @["home", "list"],
        @["home", "why"], @["home", "history"], @["home", "apply"],
        @["home", "plan"], @["home", "export"], @["home", "facts"],
        @["home", "compare"], @["home", "rollback"], @["home", "gc"],
        @["home", "set"], @["home", "get"], @["home", "adopt"],
        @["home", "resource"], @["home", "resource", "move"],
        @["home", "migrate-from-env-scripts"], @["home", "__build-bundle"],
        @["home", "__receive-bundle"], @["home", "__transfer-bundle"],
        @["home", "__remote-activate"], @["system"], @["system", "add"],
        @["system", "remove"], @["system", "list"], @["system", "why"],
        @["system", "plan"], @["system", "apply"], @["system", "sync"],
        @["system", "history"], @["system", "rollback"],
        @["system", "audit"], @["infra"], @["infra", "plan"],
        @["infra", "apply"], @["infra", "cache-keys"],
        @["infra", "install-root"], @["infra", "image"], @["anywhere"],
        @["deploy-agent"], @["deploy-agent", "keygen"],
        @["deploy-agent", "compile-profile"], @["hardware"],
        @["hardware", "probe"], @["disk"], @["disk", "plan"],
        @["disk", "apply"], @["disk", "mount"], @["disk", "unmount"],
        @["disk", "generate"], @["disk", "image"], @["cargo"],
        @["cargo", "gc"], @["cargo", "record-live"], @["cargo", "run"],
        @["health"], @["debug"], @["debug", "artifact"]]:
      let usage = "Usage: repro " & path.join(" ")
      lines.add((path & @["--help"], usage))
      lines.add((path & @["-h"], usage))
      lines.add((@["help"] & path, usage))
    lines.add((@["cargo", "help"], "Usage: repro cargo"))
    lines.add((@["cargo", "help", "gc"], "Usage: repro cargo gc"))
    lines.add((@["help", "debug", "io", "monitor"],
      "Usage: repro debug io monitor"))
    # `--help` wins over the words around it.
    lines.add((@["infra", "plan", "stray", "--help"], "Usage: repro infra plan"))
    lines.add((@["disk", "apply", "layout.nim", "--confirm", "-h"],
      "Usage: repro disk apply"))
    for (argv, usage) in lines:
      let res = s.run(argv)
      check res.code == 0
      check usage in res.output
    # The declarations' own words reach the help, and what is internal does
    # not reach the help it must stay out of.
    let homeHelp = s.run(["home", "--help"]).output
    check "--profile-dir" in homeHelp
    check "migrate-from-env-scripts" in homeHelp
    check "__build-bundle" in homeHelp       # listed by its namespace
    check "--accept-overwrite" in s.run(["home", "apply", "--help"]).output
    check "--keep-days" in s.run(["infra", "apply", "--help"]).output
    # `system plan|apply` take the flags `infra plan|apply` take.
    check "--keep-days" in s.run(["system", "apply", "--help"]).output
    check "--no-elevate" in s.run(["system", "apply", "--help"]).output
    check "--json" in s.run(["system", "plan", "--help"]).output
    check "--json" in s.run(["infra", "plan", "--help"]).output
    check "compile-profile" in s.run(["deploy-agent", "--help"]).output
    check "--allowed-signers" in s.run(["deploy-agent", "--help"]).output
    let primary = s.run(["--help"]).output
    check "deploy-agent" in primary
    check "__build-bundle" notin primary
    check "__remote-activate" notin primary
    check "compile-profile" notin primary
    check entriesUnder(s.cwd).len == 0
    check entriesUnder(s.home).len == 0

  test "a command line the description does not accept is a usage error":
    let s = newScratch()
    defer: s.dispose()
    for (argv, names) in [
        (@["home"], "'repro home' needs a subcommand"),
        (@["home", "frob"], "unknown subcommand 'frob' for 'repro home'"),
        (@["home", "add"], "'repro home add'"),
        (@["home", "add", "git", "--bogus"], "'repro home add'"),
        (@["home", "add", "git", "extra"], "'repro home add'"),
        (@["home", "list", "extra"], "'repro home list'"),
        (@["home", "history", "--host=x"], "'repro home history'"),
        (@["home", "apply", "--no-apply"], "'repro home apply'"),
        (@["home", "set", "a.b", "c", "--if", "linux"], "'repro home set'"),
        (@["home", "gc", "--keep-generations=two"], "'repro home gc'"),
        (@["home", "enable", "x", "--port=many"], "'repro home enable'"),
        (@["home", "enable", "x", "--target-store-daemon=prod"],
          "'repro home enable'"),
        (@["home", "disable", "x", "--target-wsl=maybe"],
          "'repro home disable'"),
        (@["home", "resource"], "'repro home resource' needs a subcommand"),
        (@["home", "resource", "move", "a"], "'repro home resource move'"),
        (@["home", "__transfer-bundle", "--port=x"],
          "'repro home __transfer-bundle'"),
        (@["system"], "'repro system' needs a subcommand"),
        (@["system", "frob"], "unknown subcommand 'frob' for 'repro system'"),
        (@["system", "why"], "'repro system why'"),
        (@["system", "history", "--profile", "x"], "'repro system history'"),
        (@["system", "plan", "--plan", "x"], "'repro system plan'"),
        (@["system", "plan", "extra"], "'repro system plan'"),
        (@["system", "apply", "--json"], "'repro system apply'"),
        (@["system", "apply", "--keep-days=x"], "'repro system apply'"),
        (@["system", "apply", "a", "b"], "'repro system apply'"),
        (@["system", "why", "a", "--json"], "'repro system why'"),
        (@["home", "why", "git", "--json"], "'repro home why'"),
        (@["infra"], "'repro infra' needs a subcommand"),
        (@["infra", "plan", "--plan", "x"], "'repro infra plan'"),
        (@["infra", "apply", "--keep-days=x"], "'repro infra apply'"),
        (@["infra", "cache-keys", "--host", "x"], "'repro infra cache-keys'"),
        (@["infra", "install-root", "extra"], "'repro infra install-root'"),
        (@["infra", "image", "--assembly-timeout=soon"],
          "'repro infra image'"),
        (@["anywhere", "--ssh-port=x"], "'repro anywhere'"),
        (@["anywhere", "a@b", "c@d"], "'repro anywhere'"),
        (@["deploy-agent", "--fetch-timeout-ms=x"], "'repro deploy-agent'"),
        (@["deploy-agent", "--bogus"], "'repro deploy-agent'"),
        (@["deploy-agent", "keygen", "extra"], "'repro deploy-agent keygen'"),
        (@["deploy-agent", "keygen", "--target", "t"],
          "'repro deploy-agent keygen'"),
        (@["hardware"], "'repro hardware' needs a subcommand"),
        (@["hardware", "probe", "--nope"], "'repro hardware probe'"),
        (@["disk"], "'repro disk' needs a subcommand"),
        (@["disk", "doctor"], "unknown subcommand 'doctor' for 'repro disk'"),
        (@["disk", "plan"], "'repro disk plan'"),
        (@["disk", "plan", "a.nim", "b.nim"], "'repro disk plan'"),
        (@["disk", "plan", "a.nim", "--confirm"], "'repro disk plan'"),
        (@["disk", "generate", "a.nim"], "'repro disk generate'"),
        (@["cargo"], "'repro cargo' needs a subcommand"),
        (@["cargo", "gc", "--bogus"], "'repro cargo gc'"),
        (@["cargo", "record-live", "--min-age=1d"],
          "'repro cargo record-live'"),
        (@["cargo", "run", "-j", "many", "--", "cargo", "build"],
          "'repro cargo run'"),
        (@["health", "--bogus"], "'repro health'"),
        (@["health", "a", "b"], "'repro health'"),
        (@["debug"], "'repro debug' needs a subcommand"),
        (@["debug", "artifact"], "'repro debug artifact'"),
        (@["debug", "artifact", "a", "--format"], "'repro debug artifact'")]:
      let res = s.run(argv)
      check res.code == 2
      check names in res.output
    check entriesUnder(s.cwd).len == 0
    check entriesUnder(s.home).len == 0

  test "the values the description accepts reach the command":
    let s = newScratch()
    defer: s.dispose()
    for (argv, code, message) in [
        (@["disk", "generate", "--probe", "/x-probe-root"], 2,
          "probe root: /x-probe-root"),
        (@["disk", "image", "l.nim", "--output=out.img", "--size", "8G"], 2,
          "size:   8G"),
        (@["disk", "mount", "l.nim"], 2,
          "repro disk mount: --target is required"),
        (@["disk", "image", "l.nim"], 2,
          "repro disk image: --output is required"),
        (@["home", "add", "git", "--when", "linux", "--if", "linux"], 2,
          "repro home add: give one of --when and --if"),
        (@["home", "set", "a.b", "c", "--when", "  "], 2,
          "repro home set: --when needs a predicate"),
        (@["home", "export", "--check="], 2,
          "repro home export: --check needs a file"),
        (@["home", "export", "--target=plan9"], 2,
          "repro home export: unknown --target 'plan9'"),
        (@["home", "facts", "--output="], 2,
          "repro home facts: --output needs a file"),
        (@["home", "compare", "--facts", "a.json"], 2,
          "give exactly two --facts files"),
        (@["home", "compare", "--allow=a", "--allow=b"], 2,
          "repro home compare: --allow given twice"),
        (@["home", "gc", "--keep-generations", "0"], 2,
          "--keep-generations must be >= 1"),
        (@["home", "apply", "--target-arch", "arm64"], 2,
          "--target-platform / --target-arch plan for another platform"),
        (@["home", "enable", "work", "--host="], 2,
          "repro home enable: --host needs a non-empty name"),
        (@["home", "__receive-bundle"], 2,
          "repro home __receive-bundle: --store-root is required"),
        (@["home", "__transfer-bundle", "--target", "h"], 2,
          "--bundle-digest, --target, and --target-store-root are required"),
        (@["home", "__remote-activate", "--store-root", "r"], 2,
          "--store-root and --state-dir are required"),
        (@["__remote-activate", "--state-dir", "d"], 2,
          "--store-root and --state-dir are required"),
        (@["infra", "apply", "--no-preview", "--keep-days", "-1"], 2,
          "--keep-days expects a non-negative integer, got -1"),
        (@["system", "apply", "--no-preview", "--keep-days", "-1"], 2,
          "repro system apply: --keep-days expects a non-negative " &
            "integer, got -1"),
        (@["infra", "install-root", "--source=", "--dry-run"], 2,
          "--source must be a non-empty path"),
        (@["anywhere", "--mode", "convert"], 2,
          "repro anywhere: --mode addon is the only mode"),
        (@["anywhere", "--mode=addon"], 2,
          "repro anywhere: --profile is required"),
        (@["deploy-agent", "keygen"], 2,
          "repro deploy-agent keygen: --secrets-key <FILE> is required"),
        (@["deploy-agent", "--target", "t", "--manifest", "m"], 2,
          "repro deploy-agent: --allowed-signers is required"),
        (@["deploy-agent", "--target=t", "--manifest=m",
          "--allowed-signers=s", "--secrets-dir=d"], 2,
          "--secrets-dir given without --secrets-key"),
        (@["deploy-agent", "compile-profile", "--probe-c-compiler",
          "--stdio"], 2, "--probe-c-compiler takes no other option"),
        (@["deploy-agent", "compile-profile", "--staged", "x.nim"], 2,
          "--staged, --canonical-out and --actions-out are required"),
        (@["cargo", "run", "-j", "-1", "--", "cargo", "build"], 2,
          "repro cargo run: -j takes a whole number"),
        (@["cargo", "run", "--products", "p.txt"], 2,
          "repro cargo run: no cargo command after `--`"),
        (@["cargo", "gc", "--keep-sets=0"], 2,
          "repro cargo gc: invalid --keep-sets or --min-age"),
        (@["debug", "artifact", s.home / "absent.bin", "--json"], 1,
          "repro debug artifact: error:")]:
      let res = s.run(argv)
      check res.code == code
      check message in res.output

    # `repro home --profile-dir` is the namespace's own flag: it reaches the
    # command from either side of the subcommand word. `list` of a profile
    # directory with no `home.nim` only reads, and names the directory.
    let profileDir = s.home / "elsewhere-profile"
    for argv in [@["home", "--profile-dir", profileDir, "list"],
                 @["home", "list", "--profile-dir=" & profileDir]]:
      let res = s.run(argv)
      check res.code == 1
      check ("profile directory: " & profileDir) in res.output
    check not dirExists(profileDir)
    check not dirExists(s.home / "profile")
    check not dirExists(s.home / "home-state")
    check not dirExists(s.home / "store")
    check entriesUnder(s.cwd).len == 0

  test "hardware probe writes where --output says, and only there":
    when not defined(linux):
      skip("the live hardware probe reads /proc and /sys; Linux only")
    else:
      let s = newScratch()
      defer: s.dispose()
      let target = s.home / "probe" / "hardware.nim"
      let first = s.run(["hardware", "probe", "--output=" & target])
      check first.code == 0
      check ("repro hardware probe: wrote " & target) in first.output
      check fileExists(target)
      let again = s.run(["hardware", "probe", "--output", target])
      check again.code == 2
      check "pass --regenerate to force" in again.output
      check s.run(["hardware", "probe", "--output", target,
        "--regenerate"]).code == 0
      let dry = s.run(["hardware", "probe", "--dry-run"])
      check dry.code == 0
      check "hardware \"" in dry.output
      check entriesUnder(s.cwd).len == 0
