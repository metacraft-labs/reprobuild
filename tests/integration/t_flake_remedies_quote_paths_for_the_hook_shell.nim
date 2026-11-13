## NF-3 — **a flake-pin remedy names each path as ONE word of the shell the
## hooks run in.**
##
## Spec: Unified-Locking-And-Hooks.md §"The named command must RUN where the
## message is printed" and §"Remedy text shape" ("a single copy-pasteable next
## step"), which Nix-Flake-Coexistence.md §4 applies to this refusal.
##
## ## Why
##
## `flakeReconcileCommands` / `flakeReconcileAlternative` build the commands
## the behind-pin warning, the NF-2 withheld notice and the NF-3 gate refusal
## print inside backticks for the operator to paste. They used to concatenate
## each path bare. A Windows path then reached Git's `sh` with its backslashes
## eaten (`git -C M:\m\ws\io-mon` became `cannot change to 'M:mwsio-mon'`),
## and a path with a space split in two on every OS. The second half is the
## one this host can reproduce, so the workspace here lives under a directory
## whose name has a space in it.
##
## ## What is asserted
##
##   1. the reconciling command, lifted out of the warning and run by `sh`
##      from a directory OTHER than the sibling, exits 0 and really moves the
##      behind checkout onto its pin;
##   2. the alternative (`--record-downgrade`) splits, under the same `sh`,
##      into words whose `--flake=` and `--workspace-root=` values are exactly
##      the flake directory and the workspace root — each path one word — and
##      no backticked chunk of the warning leaves a fragment of a split path;
##   3. `remedyPathWord` spells a Windows path with `/` separators, quoted
##      for a POSIX shell, so one message spells every path the same way;
##      and the `nix flake update --flake` re-lock quotes its path the same
##      way;
##   4. the NF-3 pre-push refusal, whole: no backticked chunk leaves a
##      fragment of a split path, and its first command runs from the
##      directory the refusal names and moves the behind checkout to its pin
##      (`t_the_gate_refusal_quotes_paths_for_the_hook_shell`).
##
## ## Mutations
##
##   * drop `remedyPathWord` from `flakeReconcileCommands` (concatenate
##     `row.path` bare) ⇒ RED on (1): `sh` gets `git -C <half> <half> merge`;
##   * drop it from `flakeRefreshLockCommand` ⇒ RED on (2);
##   * drop the separator rewrite, or concatenate the re-lock's flake root
##     bare ⇒ RED on (3).
##
## Test-double policy: NO mocks, doubles or fakes. See the headers of
## `nf2_flake_lock_fixture.nim` and `nf3_override_state_fixture.nim`.

import std/[json, os, strutils, unittest]

import nf3_override_state_fixture
import repro_cli_support
import repro_cli_support/lock_consistency
import repro_test_support/reasoned_skip

proc shellWords(fx: Nf2Fixture; command: string): seq[string] =
  ## The words `sh` makes of ``command``: exactly what a paste into the
  ## hook's shell would pass to the program.
  let script = "set -- " & command & "; for w; do printf '%s\\n' \"$w\"; done"
  let res = run("sh -c " & q(script), cwd = fx.scratch)
  checkpoint("sh words of `" & command & "`:\n" & res.output)
  check res.code == 0
  res.output.strip(leading = false, chars = {'\n'}).splitLines()

suite "NF-3: flake-pin remedies quote paths for the hook shell":

  test "t_flake_remedies_quote_paths_for_the_hook_shell":
    const caseName = "t_flake_remedies_quote_paths_for_the_hook_shell"
    # ---- (3) one spelling, POSIX-quoted, whatever host built the message --
    check remedyPathWord("M:\\m\\blocktracer\\io-mon", windowsHost = true) ==
      "M:/m/blocktracer/io-mon"
    check remedyPathWord("C:\\Users\\a b\\ws", windowsHost = true) ==
      "'C:/Users/a b/ws'"
    check remedyPathWord("/tmp/a b/ws", windowsHost = false) == "'/tmp/a b/ws'"
    # The re-lock a refusal names beside these remedies takes the same word.
    check flakeRelockInputCommand("io-mon-src", "/tmp/a b/ws") ==
      "nix flake update io-mon-src --flake '/tmp/a b/ws'"

    if not nf3Prerequisites(caseName):
      skip("needs a real git and a built ./build/bin/repro; " &
        "nf3Prerequisites printed which is missing")
    else:
      # The space is the point: the label becomes part of the scratch path.
      let fx = setupNf2Fixture("remedy quoting")
      defer: removeDir(fx.scratch)
      check ' ' in fx.ws
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      removePreCommitDispatch(fx)

      let alphaNew = advanceSibling(fx, "alpha", 1)
      setFlakePins(fx, alphaNew, fx.seedSha[1], fx.seedSha[2])
      discard rewindSibling(fx, "alpha", 1)

      let status = flakeStatus(fx)
      checkpoint("override-status stderr:\n" & status.stderr)
      check status.code == 0
      var warning = ""
      for line in status.stderr.splitLines():
        if line.contains("WARNING") and line.contains("'alpha'"):
          warning = line
      check warning.len > 0
      let commands = backtickedCommands(warning)
      check commands.len == 2
      if commands.len == 2:
        let reconcile = commands[0]
        let alternative = commands[1]
        check reconcile.startsWith("git -C ")
        check alternative.contains("--record-downgrade")

        # ---- (2) each path is one word --------------------------------
        let words = shellWords(fx, alternative)
        check ("--workspace-root=" & fx.ws) in words
        var flakeWord = ""
        for w in words:
          if w.startsWith("--flake="): flakeWord = w["--flake=".len .. ^1]
        check flakeWord.len > 0
        check dirExists(flakeWord)
        check fileExists(flakeWord / "flake.lock")

        # ---- (2b) no chunk of the message holds a split path -----------
        # The space sits right after this prefix, so a bare path anywhere
        # in the message leaves a word (or `--flag=` word) ending in it.
        let fragment = fx.ws[0 ..< fx.ws.find(' ')]
        for chunk in commands:
          for w in shellWords(fx, chunk):
            check not w.endsWith(fragment)

        # ---- (1) the pasted reconcile really runs, from elsewhere ------
        let ran = run("sh -c " & q(reconcile), cwd = fx.scratch)
        checkpoint("sh -c `" & reconcile & "`:\n" & ran.output)
        check ran.code == 0
        check headOf(fx, siblingDir(fx, "alpha")) == alphaNew

  test "t_the_gate_refusal_quotes_paths_for_the_hook_shell":
    # The NF-3 pre-push refusal is the message the field report came from. It
    # joins the reconciling commands with every other remedy the gate has for
    # the row, so it is asserted whole: no backticked chunk may leave a
    # fragment of the split path, and the first one runs from the directory
    # the refusal names.
    const caseName = "t_the_gate_refusal_quotes_paths_for_the_hook_shell"
    if not nf3Prerequisites(caseName):
      skip("needs a real git and a built ./build/bin/repro; " &
        "nf3Prerequisites printed which is missing")
    else:
      let fx = setupNf2Fixture("gate quoting")
      defer: removeDir(fx.scratch)
      check ' ' in fx.ws
      isolateNf2Config(fx)
      defer: releaseNf2Config()
      removePreCommitDispatch(fx)

      let gammaPinned = advanceSibling(fx, "gamma", 2)
      discard rewindSibling(fx, "gamma", 2)
      setFlakePins(fx, fx.seedSha[0], fx.seedSha[1], gammaPinned)
      publishAll(fx)
      commitLockAndPublish(fx, "a lock pinned ahead of the gamma checkout")

      let gate = gatePrePush(fx)
      checkpoint("gate output:\n" & gate.output)
      check gate.code == 2
      check hasGateFailure(gate.report, "flake_lock_stale")
      if hasGateFailure(gate.report, "flake_lock_stale"):
        let remediation =
          gateFailureOf(gate.report, "flake_lock_stale")["remediation"].getStr()
        checkpoint("remediation: " & remediation)
        let commands = backtickedCommands(remediation)
        check commands.len > 0
        let fragment = fx.ws[0 ..< fx.ws.find(' ')]
        for chunk in commands:
          for w in shellWords(fx, chunk):
            check not w.endsWith(fragment)
        let namedDir = directoryNamedForRunning(remediation)
        check dirExists(namedDir)
        if commands.len > 0 and dirExists(namedDir):
          let ran = run("sh -c " & q(commands[0]), cwd = namedDir)
          checkpoint("sh -c `" & commands[0] & "`:\n" & ran.output)
          check ran.code == 0
          check headOf(fx, siblingDir(fx, "gamma")) == gammaPinned
