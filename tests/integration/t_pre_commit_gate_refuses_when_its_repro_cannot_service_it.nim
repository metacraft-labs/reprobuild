## The pre-commit certificate gate fails CLOSED when the ``repro`` its hook
## resolves cannot service it (CLI/hooks.md §"Contract Handshake And
## Stand-Down"; Pre-Commit-Check-Sets.md §7.3).
##
## Why this exists: reprobuild-pm
## ``issues/2026-11-12-a-refusing-pre-commit-arm-under-skew-the-spec-says-it-blocks-while-hooks-md-and-the-code.md``.
## Every managed hook body asks its resolved ``repro`` to confirm the body's
## contract token before dispatching. On a failed handshake ``pre-push``
## refused and every other hook announced the mismatch and exited 0 —
## including the certificate-gate phase of ``pre-commit``, whose whole job
## under ``commit_gate = required`` is to refuse. So in exactly the shells
## where the handshake fails (a bare ``PATH``, a cached dev shell, an editor
## subprocess, an agent harness) an uncovered commit on a required branch went
## through, and nothing durable said the gate had not run. A gate an
## unidentified build decides is not a gate, and Failure-Semantics.md requires
## an ambiguous correctness failure to fail closed.
##
## The rule this pins: the certificate-gate phase of a canonical (not
## displaced) dispatcher REFUSES the commit when its ``repro`` does not confirm
## the contract or cannot be found at all. Everything that only reports keeps
## failing open, and the test holds that boundary too.
##
## Through the hooks the real ``repro hooks ensure --vcs`` generates, and real
## ``git commit`` invocations, on a branch whose rule is ``required``:
##
##   1. a ``repro`` that speaks the handshake but generates a different hook
##      (probe exit 3): the commit is REFUSED, HEAD does not move, the refusal
##      names that binary and how it was resolved, the stub is never asked to
##      dispatch, and the gate log shows the gate never evaluated anything;
##   2. a ``repro`` that predates the handshake (rejects the flag): REFUSED
##      the same way;
##   3. no ``repro`` resolvable at all (``REPROBUILD_REPRO`` names nothing
##      executable): REFUSED, and the refusal says no binary was found;
##   4. control: the same uncovered content, committed through the real
##      binary, is refused by the gate itself, in the gate's own words and
##      without the skew refusal — so 1–3 are not the gate's verdict;
##   5. control: covered content committed through the real binary goes
##      through, and covered content committed under the case-1 stub is
##      still refused — so 1–3 refuse because of the skew, not because of
##      the content;
##   6. a repository whose lock carries NO certificate policy (so its
##      dispatcher has no gate phase) still commits under the case-1 stub:
##      the lock refresh's refusal guards only its own write, and under a
##      mismatch it writes nothing, so it keeps announcing and exiting 0.
##
## A second test pins the displaced layout: with prek installed over the
## dispatcher the gate is only advisory (it cannot know it ran last), so under
## the case-1 stub that commit goes through and says the gate was not
## evaluated.
##
## Falsifiability: revert the fix (the gate phase exits 0 on a failed
## handshake, as before) → cases 1, 2 and 3 commit; refuse in every phase →
## case 6 and the displaced test are refused.
##
## Mocks, justified: the ``repro`` the hook resolves in 1, 2 and 6 is a STUB,
## because the defect is specifically about a binary the workspace did not
## build, and no real second build can be produced hermetically inside a test.
## The stubs are behavioural — they answer the probe exactly as a skewed or a
## predating build does (``t_managed_hooks_refuse_a_repro_that_does_not_speak_
## their_contract`` uses the same shapes) and record whether they were ever
## asked to dispatch. Everything else is real: git, the generated hooks, the
## production store, verifier and gate, signatures by the real ``ssh-keygen``.
## Skip rule: ``git`` or ``ssh-keygen`` missing (and ``prek`` for the second
## test; the reprobuild dev shell has all three).

import repro_test_support/reasoned_skip
import std/[os, osproc, strutils, unittest]

include policy_gate_fixture

proc toolsMissing(): bool =
  findExe("git").len == 0 or findExe("ssh-keygen").len == 0

const RefusalMarker = "the certificate gate REFUSES this commit"
const NotEvaluatedMarker = "the certificate gate was not evaluated"

proc writeSkewedStub(path, marker: string) =
  ## A ``repro`` that speaks the handshake but generates a different hook:
  ## the probe answers exit 3, as a build of another revision does.
  writeFile(path,
    "#!/usr/bin/env sh\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'repro 0.0.0-skewed'; " &
    "exit 0; fi\n" &
    "if [ \"${1:-}\" = \"hooks\" ] && [ \"${2:-}\" = \"protocol\" ]; then\n" &
    "  echo 'this build generates a different hook' >&2\n" &
    "  exit 3\n" &
    "fi\n" &
    ": > " & quoteShellPosix(marker) & "\n" &
    "exit 0\n")
  inclFilePermissions(path, {fpUserExec, fpGroupExec, fpOthersExec})

proc writePredatingStub(path, marker: string) =
  ## A ``repro`` that predates the handshake: it answers the bare
  ## ``--require=2`` probe and rejects the ``--hook-contract=`` flag.
  writeFile(path,
    "#!/usr/bin/env sh\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then echo 'repro 0.0.0-predating'; " &
    "exit 0; fi\n" &
    "if [ \"${1:-}\" = \"hooks\" ] && [ \"${2:-}\" = \"protocol\" ]; then\n" &
    "  if [ \"$#\" -eq 3 ] && [ \"${3:-}\" = \"--require=2\" ]; then\n" &
    "    echo 2\n" &
    "    exit 0\n" &
    "  fi\n" &
    "  echo 'repro hooks protocol requires exactly --require=2' >&2\n" &
    "  exit 1\n" &
    "fi\n" &
    ": > " & quoteShellPosix(marker) & "\n" &
    "exit 0\n")
  inclFilePermissions(path, {fpUserExec, fpGroupExec, fpOthersExec})

proc commitWith(fx: StoreFixture; repro: string; args: varargs[string]):
    tuple[code: int; output: string] =
  ## ``git commit`` with the hook's interpreter forced to ``repro``. The
  ## variable outranks ``PATH`` in the managed body, so a dev-shell ``repro``
  ## on ``PATH`` cannot stand in for it; when ``repro`` names nothing
  ## executable the body resolves no binary at all.
  var argv = @["git", "-C", fx.libAPath, "commit"]
  for a in args: argv.add(a)
  runArgv(argv, fx.libAPath, @[(name: "REPROBUILD_REPRO", value: repro),
    (name: "PATH", value: fx.reproBin.parentDir & PathSep & getEnv("PATH"))])

proc requiredBranch(fx: StoreFixture) =
  ## A ``required`` rule for ``agents`` that names ``pre-commit``, the hooks
  ## installed, and ``agents`` checked out.
  discard fx.commitPolicy(snapshotOf([
    policyRule(["agents"], pmRequired, [req("pre-commit", "*")])]))
  fx.ensureHooks()
  doAssert hasCertificatePhase(fx.libAPath),
    "the dispatcher has no certificate phase; nothing below would test it"
  discard fx.mustGit("checkout", "-q", "-b", "agents")

proc checkRefusedForSkew(fx: StoreFixture; res: tuple[code: int;
    output: string]; before, marker, names: string; gateLinesBefore: int) =
  checkpoint(res.output)
  check res.code != 0
  check fx.head == before
  check RefusalMarker in res.output
  # The verdict line itself names who could not answer, so the refusal is
  # attributed by the gate phase and not only by the refresh phase's notice.
  var verdictNames = false
  for line in res.output.splitLines():
    if RefusalMarker in line and names in line:
      verdictNames = true
  check verdictNames
  # The stub never dispatched, so nothing it could say became the cause.
  if marker.len > 0:
    check not fileExists(marker)
  # The gate never ran: no verdict of its can be the reason for the refusal.
  check fx.gateLogLines("") == gateLinesBefore

suite "the pre-commit gate refuses when its repro cannot service it":

  test "t_pre_commit_gate_refuses_when_its_repro_cannot_service_it":
    if toolsMissing():
      skip("git or ssh-keygen not on PATH; this test signs certificates " &
        "and commits in real repositories")
    else:
      let fx = setupStoreFixture("", "pcg-skew", recordStore = false,
        committedLock = true)
      defer: removeDir(fx.scratch)
      fx.requiredBranch()

      writeFile(fx.libAPath / "a.txt", "uncovered\n")
      discard fx.mustGit("add", "a.txt")
      let before = fx.head

      # ---- 1. a skewed repro (probe exit 3) ------------------------------
      let skewed = fx.scratch / "skewed-repro"
      let skewedMarker = fx.scratch / "skewed-dispatched.marker"
      writeSkewedStub(skewed, skewedMarker)
      let c1 = fx.commitWith(skewed, "-m", "skewed")
      fx.checkRefusedForSkew(c1, before, skewedMarker,
        skewed & " (resolved from REPROBUILD_REPRO)", 0)

      # ---- 2. a repro that predates the handshake ------------------------
      let predating = fx.scratch / "predating-repro"
      let predatingMarker = fx.scratch / "predating-dispatched.marker"
      writePredatingStub(predating, predatingMarker)
      let c2 = fx.commitWith(predating, "-m", "predating")
      fx.checkRefusedForSkew(c2, before, predatingMarker,
        predating & " (resolved from REPROBUILD_REPRO)", 0)

      # ---- 3. no repro at all --------------------------------------------
      let c3 = fx.commitWith(fx.scratch / "no-such-repro", "-m", "absent")
      fx.checkRefusedForSkew(c3, before, "", "no 'repro' could be resolved", 0)

      # ---- 4. the real binary: the gate itself refuses the same content --
      let c4 = fx.commitWith(fx.reproBin, "-m", "real, uncovered")
      checkpoint(c4.output)
      check c4.code != 0
      check fx.head == before
      check RefusalMarker notin c4.output
      check "REFUSED (commit_gate = required)" in c4.output
      check fx.gateLogLines("refused not-covered") == 1

      # ---- 5. control: covered content through the real binary commits --
      fx.certifyTargets(fx.indexContentId, @["pre-commit"])
      let c5 = fx.commitWith(fx.reproBin, "-m", "real, covered")
      checkpoint(c5.output)
      check c5.code == 0
      check fx.head != before
      check fx.gateLogLines("covered") == 1
      # The same stub, the same branch, covered content: still refused,
      # because nothing could tell it was covered.
      writeFile(fx.libAPath / "b.txt", "covered too\n")
      discard fx.mustGit("add", "b.txt")
      fx.certifyTargets(fx.indexContentId, @["pre-commit"])
      let before5 = fx.head
      let lines5 = fx.gateLogLines("")
      let c5b = fx.commitWith(skewed, "-m", "skewed, covered")
      fx.checkRefusedForSkew(c5b, before5, skewedMarker,
        skewed & " (resolved from REPROBUILD_REPRO)", lines5)

  test "a repository with no certificate policy still commits under skew":
    if toolsMissing():
      skip("git or ssh-keygen not on PATH; this test commits in real " &
        "repositories")
    else:
      # ---- 6. no policy → no gate phase → the refresh fails open ---------
      let fx = setupStoreFixture("", "pcg-skew-nogate", recordStore = false,
        committedLock = true)
      defer: removeDir(fx.scratch)
      fx.ensureHooks()
      check not hasCertificatePhase(fx.libAPath)
      let skewed = fx.scratch / "skewed-repro"
      let skewedMarker = fx.scratch / "skewed-dispatched.marker"
      writeSkewedStub(skewed, skewedMarker)
      writeFile(fx.libAPath / "c.txt", "no gate here\n")
      discard fx.mustGit("add", "c.txt")
      let before = fx.head
      let c6 = fx.commitWith(skewed, "-m", "no policy")
      checkpoint(c6.output)
      check c6.code == 0
      check fx.head != before
      check "this hook could not be evaluated" in c6.output
      check RefusalMarker notin c6.output
      check not fileExists(skewedMarker)

suite "a displaced dispatcher's gate stays advisory under skew":

  test "t_pre_commit_gate_is_advisory_under_skew_when_displaced":
    if toolsMissing() or findExe("prek").len == 0:
      skip("needs git, ssh-keygen and prek on PATH (the reprobuild dev " &
        "shell has all three)")
    else:
      let fx = setupStoreFixture("", "pcg-skew-prek", recordStore = false,
        committedLock = true)
      defer: removeDir(fx.scratch)
      fx.requiredBranch()
      let ranFile = fx.scratch / "prek-ran.txt"
      writeFile(fx.libAPath / ".pre-commit-config.yaml",
        "repos:\n" &
        "- repo: local\n" &
        "  hooks:\n" &
        "  - id: record\n" &
        "    name: record\n" &
        "    entry: sh -c 'echo ran >> " & ranFile & "'\n" &
        "    language: system\n" &
        "    pass_filenames: false\n" &
        "    always_run: true\n")
      discard fx.mustGit("add", ".pre-commit-config.yaml")
      discard fx.mustGit("commit", "-q", "--no-verify", "-m", "prek config")
      # What git-hooks.nix's installation script does on every dev-shell
      # entry: prek displaces the dispatcher to ``pre-commit.legacy``.
      let prekHome = fx.scratch / "prek-home"
      createDir(prekHome)
      let prekEnv = fx.hookEnv & @[(name: "PREK_HOME", value: prekHome)]
      for hook in ["pre-commit", "pre-push", "post-commit", "post-merge",
          "post-checkout", "commit-msg"]:
        discard runArgv(@[findExe("prek"), "uninstall", "-t", hook],
          fx.libAPath, prekEnv)
      let installed = runArgv(@[findExe("prek"), "install", "-c",
        ".pre-commit-config.yaml", "-t", "pre-commit"], fx.libAPath, prekEnv)
      doAssert installed.code == 0, installed.output
      let hooks = fx.libAPath / ".git" / "hooks"
      doAssert readFile(hooks / "pre-commit").contains(
        "File generated by prek"), "prek did not install over the dispatcher"
      doAssert readFile(hooks / "pre-commit.legacy").contains(
        "reprobuild hook dispatcher"), "prek did not displace the dispatcher"

      let skewed = fx.scratch / "skewed-repro"
      let skewedMarker = fx.scratch / "skewed-dispatched.marker"
      writeSkewedStub(skewed, skewedMarker)
      writeFile(fx.libAPath / "d.txt", "uncovered, displaced\n")
      discard fx.mustGit("add", "d.txt")
      let before = fx.head
      let res = runArgv(@["git", "-C", fx.libAPath, "commit", "-m",
        "displaced"], fx.libAPath,
        @[(name: "REPROBUILD_REPRO", value: skewed),
          (name: "PATH", value: fx.reproBin.parentDir & PathSep &
            getEnv("PATH")),
          (name: "PREK_HOME", value: prekHome)])
      checkpoint(res.output)
      check res.code == 0
      check fx.head != before
      check RefusalMarker notin res.output
      check NotEvaluatedMarker in res.output
      check fileExists(ranFile)                 # prek's own hooks ran too
      check not fileExists(skewedMarker)
