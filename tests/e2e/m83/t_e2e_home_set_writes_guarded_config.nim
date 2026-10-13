## Gate: `e2e_home_set_writes_guarded_config`.
##
## `repro home set <pkg>.<key> <value> --when <pred>` writes a guarded
## `config:` entry into a compiled profile that already guards config with
## runtime `when` chains (GM3), and the structural editor leaves those chains
## intact while it edits around them. What the editor wrote is then read back
## the way the planner reads it -- the profile is COMPILED (`repro home
## export`) and the guards are evaluated per target platform
## (`evaluateHomeExport`, and `--target` through the CLI) -- so the gate
## checks that the text compiles, that the guard is the one asked for, and
## that the planner selects the value exactly where it holds:
##
## * an unguarded `set` next to the chain, then a guarded `set` of the same
##   key (default plus per-platform override) both land; the override wins
##   where its guard holds;
## * `repro home add` and `repro home get` work on the guarded profile (the
##   text-level inspector used to refuse every `when` in `config:`);
## * a guarded `set` of a package the current host does not enable is
##   allowed when the guard does not hold here (unguarded, it is refused);
## * refusals leave `home.nim` byte-identical: an unguarded value that would
##   override the guarded chain (exit 1, naming the guarded sites), `--if`
##   (exit 2: `config:` guards are `when` chains) and a malformed predicate
##   (exit 2, naming the flag).
##
## No mocks: real `build/bin/repro`, real Nim compile and platform probe,
## real io-mon shim, isolated HOME / state / store (the shared harness).
## Nothing is applied (`--no-apply`; `export` is read-only).

import repro_test_support/reasoned_skip

const PlatformSkipReason =
  "[platform N/A] t_e2e_home_set_writes_guarded_config: the shared " &
  "profile-compile harness spawns `repro` and its `nim` spy through " &
  "/bin/sh, which Windows lacks; the gate runs on Linux (home-pc) and " &
  "macOS (m1)."

when defined(windows):
  import std/unittest

  suite "repro home set: guarded config":
    test "e2e_home_set_writes_guarded_config":
      skip(PlatformSkipReason)
else:
  import std/[json, os, strutils, unittest]

  import repro_cli_support/home_export

  import ./profile_compile_edge_harness

  const Host = "gm3-set-host"

  const Profile = """
import repro_profile

profile "gm3Set":
  activity default:
    git
    ripgrep
    when windows():
      wterm

  config:
    git:
      userName = "gm3"
      when windows():
        autocrlf = "true"
      elif macos():
        autocrlf = "input"
    when linux():
      ripgrep:
        smartCase = "yes"

  hosts:
    "gm3-set-host": []
"""

  const Targets = ["x86_64-linux", "aarch64-linux", "aarch64-darwin",
    "x86_64-windows"]

  proc configOf(evaluation: JsonNode): seq[string] =
    ## `<pkg>.<key>=<value>` in the evaluation's (declaration) order.
    for c in evaluation["configOverrides"]:
      result.add c["pkg"].getStr & "." & c["key"].getStr & "=" &
        c["value"]["value"].getStr

  proc configSection(text: string): string =
    let a = text.find("  config:")
    let b = text.find("  hosts:")
    doAssert a >= 0 and b > a
    text[a ..< b]

  suite "repro home set: guarded config":

    test "e2e_home_set_writes_guarded_config":
      let sb = newProfileSandbox("gm3-set", Profile)
      defer: sb.dispose()
      let path = sb.profilePath

      # Refusals first, each leaving the file byte-identical.
      block:
        let r = sb.runRepro(["home", "set", "git.autocrlf", "false",
          "--no-apply"], host = Host)
        checkpoint("unguarded overlap stderr:\n" & r.stderr)
        check r.exitCode == 1
        check "refusing to add an assignment of 'git.autocrlf'" in r.stderr
        check "would override a guarded assignment" in r.stderr
        check ":14 (under `when windows():`)" in r.stderr
        check ":16 (under `elif macos():`)" in r.stderr
        check readFile(path) == Profile
      block:
        let r = sb.runRepro(["home", "set", "git.editor", "vim", "--if",
          "linux", "--no-apply"], host = Host)
        check r.exitCode == 2
        check "`--if` is not accepted" in r.stderr
        check readFile(path) == Profile
      block:
        let r = sb.runRepro(["home", "set", "git.editor", "vim", "--when",
          "linux and", "--no-apply"], host = Host)
        checkpoint("bad predicate stderr:\n" & r.stderr)
        check r.exitCode == 2
        check "invalid --when predicate 'linux and'" in r.stderr
        check readFile(path) == Profile
      block:
        # `wterm` is enabled only on Windows; this host is not Windows.
        let r = sb.runRepro(["home", "set", "wterm.theme", "dark",
          "--no-apply"], host = Host)
        check r.exitCode == 1
        check "NOT enabled by any active activity" in r.stderr
        check readFile(path) == Profile

      # `get` reads the guarded config: `ripgrep.smartCase` is guarded by
      # `linux()` (around its package block), so it is this host's value
      # on Linux only.
      block:
        let r = sb.runRepro(["home", "get", "ripgrep.smartCase"], host = Host)
        checkpoint("get stderr:\n" & r.stderr)
        when defined(linux):
          check r.exitCode == 0
          check r.stdout.strip() == "yes"
        else:
          check r.exitCode == 1
          check r.stdout.strip() == ""
          check "no value recorded for `ripgrep.smartCase`" in r.stderr

      # Default plus per-platform override, and a Windows-only package's
      # value set from a non-Windows host.
      for args in [@["git.editor", "nano"],
                   @["git.editor", "vim", "--when", "linux and arm64"],
                   @["wterm.theme", "dark", "--when", "windows"]]:
        let r = sb.runRepro(@["home", "set"] & args & @["--no-apply"],
          host = Host)
        checkpoint("set " & $args & " stderr:\n" & r.stderr)
        require r.exitCode == 0
      let add = sb.runRepro(["home", "add", "fd", "--no-apply"], host = Host)
      checkpoint("add stderr:\n" & add.stderr)
      require add.exitCode == 0

      let edited = readFile(path)
      checkpoint("edited home.nim:\n" & edited)
      check edited == Profile.
        replace("      wterm\n", "      wterm\n    fd\n").
        replace("        autocrlf = \"input\"\n",
          "        autocrlf = \"input\"\n" &
          "      editor = \"nano\"\n" &
          "      when arm64 and linux:\n" &
          "        editor = \"vim\"\n").
        replace("        smartCase = \"yes\"\n",
          "        smartCase = \"yes\"\n" &
          "    wterm:\n" &
          "      when windows:\n" &
          "        theme = \"dark\"\n")

      # Compile it and read the guards back as the planner does.
      let exportRun = sb.runRepro(["home", "export", "--host", Host],
        host = "")
      checkpoint("export stderr:\n" & exportRun.stderr)
      require exportRun.exitCode == 0
      let doc = parseJson(exportRun.stdout)
      var guards: seq[string]
      for c in doc["intent"]["configOverrides"]:
        guards.add c["pkg"].getStr & "." & c["key"].getStr & "=" &
          c["value"]["value"].getStr & ":" &
          (if c["guard"].kind == JNull: "-" else: c["guard"].getStr)
      checkpoint("config guards: " & $guards)
      check guards == @["git.userName=gm3:-",
        "git.autocrlf=true:windows",
        "git.autocrlf=input:macos and not windows",
        "git.editor=nano:-",
        "git.editor=vim:arm64 and linux",
        "ripgrep.smartCase=yes:linux",
        "wterm.theme=dark:windows"]
      for system in Targets:
        check doc["platforms"][system].getStr == "same"

      let want = [
        ("x86_64-linux", @["git.userName=gm3", "git.editor=nano",
          "ripgrep.smartCase=yes"]),
        ("aarch64-linux", @["git.userName=gm3", "git.editor=nano",
          "git.editor=vim", "ripgrep.smartCase=yes"]),
        ("aarch64-darwin", @["git.userName=gm3", "git.autocrlf=input",
          "git.editor=nano"]),
        ("x86_64-windows", @["git.userName=gm3", "git.autocrlf=true",
          "git.editor=nano", "wterm.theme=dark"])]
      for (system, expected) in want:
        checkpoint("target " & system)
        check configOf(evaluateHomeExport(doc, system)) == expected

      # The CLI's `--target` agrees for the platform the override is for.
      let cli = sb.runRepro(["home", "export", "--host", Host, "--target",
        "aarch64-linux"], host = "")
      checkpoint("--target stderr:\n" & cli.stderr)
      require cli.exitCode == 0
      check configOf(parseJson(cli.stdout)["evaluation"]) ==
        want[1][1]

      # A guarded value already present is updated in place; nothing else
      # in `config:` moves.
      let before = configSection(readFile(path))
      let upd = sb.runRepro(["home", "set", "git.editor", "hx", "--when",
        "arm64 and linux", "--no-apply"], host = Host)
      require upd.exitCode == 0
      check configSection(readFile(path)) ==
        before.replace("editor = \"vim\"", "editor = \"hx\"")
