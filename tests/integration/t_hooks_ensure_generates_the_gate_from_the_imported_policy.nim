## TC-9c — ``repro hooks ensure --vcs`` generates the pre-commit certificate
## phase from the policy a repository imports (Test-Certificates.md
## §"Generated gates"), and only where one is in effect.
##
## The TC-9b package fixture: a shared ``certpolicy`` package exports
## ``teamPolicy``; the ``consumer`` repository names it in ``uses:``, enacts
## it, and ``repro lock refresh`` records the snapshot in its ``repro.lock``.
## Every step drives the built ``repro`` and real ``git commit``:
##
##   0. Before any policy, ``ensure`` installs a ``pre-commit`` dispatcher
##      with NO certificate phase (its bytes are kept for step 5).
##   1. After enacting and refreshing, ``ensure`` installs the phase and
##      prints one ``certificate gate:`` line per rule.
##   2. On ``agents`` (required) an uncovered commit is REFUSED.
##   3. Switching to ``feature/x`` (no rule) changes the applied rule with no
##      re-install: the dispatcher bytes are unchanged and the same kind of
##      commit goes through, the gate saying no rule applies.
##   4. With the phase deleted from the dispatcher by hand, an uncovered
##      commit on ``agents`` is NOT gated — so steps 2–3 exercised the
##      generated phase, not something else in the hook chain.
##   5. Removing the policy (recipe and refresh) and re-running ``ensure``
##      restores dispatchers byte-identical to step 0's.
##
## Falsifiability: always generate the phase → 0 and 5 fail; never generate
## it → 1 and 2 fail; bake the rule into the hook → 3 is refused.
##
## NO MOCKS: real repositories, the real provider compile and lock writer,
## the real hooks. Skip rule: ``git`` missing.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip

import repro_cli_support
import ./certificate_policy_fixture

const gatePolicyModule = """
const teamPolicy* = certificatePolicy "team-default":
  rule "agents":
    gateMode required
    requires "pre-commit", platforms = anyPlatform
  rule "release/*":
    gateMode required
    commitGate advisory
    requires "pre-commit", platforms = anyPlatform
"""

proc hookRun(ws: PolicyWorkspace; repo: string;
             args: varargs[string]): PolicyRun =
  ## A command whose hooks resolve the build under test.
  var command = "REPROBUILD_REPRO=" & quoteShell(ws.repro) & " " &
    quoteShell(args[0])
  for a in args[1 .. ^1]:
    command.add(" " & quoteShell(a))
  run(command, repo)

proc gitH(ws: PolicyWorkspace; args: varargs[string]) =
  ## A git command in the consumer that must succeed. Once the hooks are
  ## installed every git command fires them, so every one names the build
  ## under test: a `repro` from elsewhere on PATH would answer for hooks it
  ## did not write (and re-anchor them to itself).
  var argv = @[ws.gitBin, "-C", ws.consumer]
  for a in args: argv.add(a)
  let res = ws.hookRun(ws.consumer, argv)
  doAssert res.code == 0, "git " & @args.join(" ") & ":\n" & res.output

proc commitRecipe(ws: PolicyWorkspace; recipe, message: string) =
  writeFile(ws.consumer / "repro.nim", recipe)
  ws.gitH("add", "-A")
  ws.gitH("commit", "-q", "--no-verify", "-m", message)

proc ensure(ws: PolicyWorkspace): PolicyRun =
  ws.hookRun(ws.consumer, ws.repro, "hooks", "ensure", "--vcs", ws.consumer)

proc commitFile(ws: PolicyWorkspace; file, body, message: string): PolicyRun =
  writeFile(ws.consumer / file, body)
  ws.gitH("add", file)
  ws.hookRun(ws.consumer, ws.gitBin, "-C", ws.consumer, "commit", "-m",
    message)

proc dispatchers(repo: string): seq[string] =
  for hook in ["pre-commit", "pre-push", "post-commit", "post-merge",
               "post-checkout"]:
    let path = repo / ".git" / "hooks" / hook
    result.add(if fileExists(path): readFile(path) else: "")

proc preCommitDispatcher(repo: string): string =
  readFile(repo / ".git" / "hooks" / "pre-commit")

suite "TC-9c — hooks ensure generates the certificate gate":

  test "t_hooks_ensure_generates_the_gate_from_the_imported_policy":
    if findExe("git").len == 0:
      skip("git is not on PATH; this test drives real repositories")
    else:
      let ws = newPolicyWorkspace("tc9c-ensure", gatePolicyModule,
        consumerRecipe("", ["pre-commit"]))
      defer: removeDir(ws.root)

      # ---- 0. no policy: no certificate phase ------------------------------
      let e0 = ws.ensure()
      checkpoint("ensure without a policy:\n" & e0.output)
      check e0.code == 0
      check "certificate gate:" notin e0.output
      let before = dispatchers(ws.consumer)
      check PreCommitGatePhaseArg notin before[0]

      # ---- 1. enact, refresh, ensure ---------------------------------------
      ws.commitRecipe(consumerRecipe("teamPolicy", ["pre-commit"]),
        "enact the team policy")
      let refreshed = ws.refresh()
      checkpoint("refresh:\n" & refreshed.output)
      check refreshed.code == 0
      check "[certificate_policy]" in lockOf(ws.consumer)
      ws.gitH("add", "repro.lock")
      ws.gitH("commit", "-q", "--no-verify", "-m",
        "record the policy")
      let e1 = ws.ensure()
      checkpoint("ensure with the policy:\n" & e1.output)
      check e1.code == 0
      check e1.output.count("certificate gate:") == 2
      check "certificate gate: agents -> pre-commit (any platform); " &
        "commit required, push required" in e1.output
      check "certificate gate: release/* -> pre-commit (any platform); " &
        "commit advisory, push required" in e1.output
      let withPhase = preCommitDispatcher(ws.consumer)
      check PreCommitGatePhaseArg in withPhase
      check "agents" notin withPhase   # the hook embeds no rule
      # Only the pre-commit dispatcher depends on the policy.
      check dispatchers(ws.consumer)[1 .. ^1] == before[1 .. ^1]

      # ---- 2. agents: required, uncovered → refused ------------------------
      ws.gitH("checkout", "-q", "-b", "agents")
      let headBefore = ws.headOf(ws.consumer)
      let c2 = ws.commitFile("a.txt", "alpha\n", "uncovered on agents")
      checkpoint("commit on agents:\n" & c2.output)
      check c2.code != 0
      check ws.headOf(ws.consumer) == headBefore
      check "REFUSED (commit_gate = required)" in c2.output
      check "rule \"agents\"" in c2.output

      # ---- 3. feature/x: no rule, no re-install ----------------------------
      ws.gitH("checkout", "-q", "-b", "feature/x")
      check preCommitDispatcher(ws.consumer) == withPhase
      let c3 = ws.hookRun(ws.consumer, ws.gitBin, "-C", ws.consumer, "commit",
        "-m", "the same change on feature/x")
      checkpoint("commit on feature/x:\n" & c3.output)
      check c3.code == 0
      check ws.headOf(ws.consumer) != headBefore
      check "branch 'feature/x' matches no rule" in c3.output
      check preCommitDispatcher(ws.consumer) == withPhase

      # ---- 4. the phase deleted by hand: not gated -------------------------
      ws.gitH("checkout", "-q", "agents")
      var stripped: seq[string]
      for line in withPhase.splitLines():
        if PreCommitGatePhaseArg notin line:
          stripped.add(line)
      writeFile(ws.consumer / ".git" / "hooks" / "pre-commit",
        stripped.join("\n"))
      check PreCommitGatePhaseArg notin preCommitDispatcher(ws.consumer)
      let agentsBefore = ws.headOf(ws.consumer)
      let c4 = ws.commitFile("b.txt", "beta\n", "uncovered, phase removed")
      checkpoint("commit with the phase removed:\n" & c4.output)
      check c4.code == 0
      check ws.headOf(ws.consumer) != agentsBefore
      check "certificate gate" notin c4.output

      # ---- 5. remove the policy: byte-identical dispatchers ----------------
      ws.commitRecipe(consumerRecipe("", ["pre-commit"]),
        "stop enacting the policy")
      let unrefreshed = ws.refresh()
      checkpoint("refresh without the policy:\n" & unrefreshed.output)
      check unrefreshed.code == 0
      check "[certificate_policy]" notin lockOf(ws.consumer)
      ws.gitH("add", "repro.lock")
      ws.gitH("commit", "-q", "--no-verify", "-m",
        "drop the policy snapshot")
      let e5 = ws.ensure()
      checkpoint("ensure after removing the policy:\n" & e5.output)
      check e5.code == 0
      check "certificate gate:" notin e5.output
      check dispatchers(ws.consumer) == before
