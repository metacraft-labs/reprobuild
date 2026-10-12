## TC-8d — the untracked-inputs flag (operator decision D5):
## ``[certificates] untracked_inputs`` in ``projects/<project>.toml``.
##
## Untracked files are outside the content a certificate names, so a test that
## read one ran against something the certificate does not identify
## (test-certificates Standard §3.2).
##
##   1. Default (no key, i.e. "read-set"): an untracked scratch file the run
##      did not read → issued with ``untracked = true``, and the output says no
##      read set was captured — the fixture path has none.
##   2. ``untracked_inputs = "strict"``: the same state → withheld, naming the
##      file; exit code unchanged. With the file removed → issued with
##      ``untracked = false``.
##   3. A file the run DID read, per a CAPTURED read set → withheld in both
##      modes. No issuing path captures a read set yet (the TC-8d finding), so
##      this is driven through ``judgeUntrackedInputs`` with a read set
##      produced by the real filesystem monitor: ``repro internal io monitor``
##      runs ``cat`` on the scratch file, and ``readSetFromMonitorDepFile``
##      reads the depfile it wrote. The same capture of a command that read
##      only a tracked file withholds in neither mode.
##   4. An invalid value (``"sometimes"``) → a loud error naming the key and
##      the accepted values, and no certificate — never a silent default.
##
## Falsifiability: a "strict" that fell back to "read-set" issues in case 2;
## a judgement that ignored the read set issues in case 3.
##
## NO MOCKS: real repositories, the built ``repro`` and its monitor. Skip
## rule: ``git`` or ``ssh-keygen`` missing.

import std/[os, strutils, unittest]
import repro_test_support
import repro_test_support/reasoned_skip
import repro_cli_support
import repro_workspace_manifests
import ./certify_working_tree_fixture

suite "TC-8d — the untracked-inputs flag":

  test "t_untracked_inputs_flag_read_set_and_strict":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs a certificate " &
        "in real repositories")
    else:
      var fx = setupCertifyFixture("tc8d-untracked")
      defer: removeDir(fx.sib.scratch)
      let app = fx.sib.app
      let scratchFile = app / "scratch.txt"
      writeFile(scratchFile, "an untracked file\n")
      let content = fx.workingTreeContentId(app)
      let fixtureJson = fx.writeFixtureJson("t-unit", "exit 0")

      # ---- 1. default: read-set, no read set captured → issued -------------
      let res1 = fx.certify(fixtureJson)
      checkpoint(res1.output)
      check res1.code == 0
      let issued = fx.issuedFor(content)
      check issued.len == 1
      if issued.len == 1:
        check issued[0].vcs.untracked
      check "no read set was captured" in res1.output
      removeDir(fx.certStore)

      # ---- 2. strict → withheld; without the file → issued ----------------
      let projectToml = readFile(fx.sib.ws / "projects" / "app.toml")
      fx.appendProjectToml("[certificates]\nuntracked_inputs = \"strict\"\n")
      let res2 = fx.certify(fixtureJson)
      checkpoint(res2.output)
      check res2.code == 0
      check not fx.anyCertificateIssued()
      check "no certificate" in res2.output
      check "strict" in res2.output
      check "scratch.txt" in res2.output
      removeFile(scratchFile)
      let res2b = fx.certify(fixtureJson)
      checkpoint(res2b.output)
      check res2b.code == 0
      let strictIssued = fx.issuedFor(content)
      check strictIssued.len == 1
      if strictIssued.len == 1:
        check not strictIssued[0].vcs.untracked
      removeDir(fx.certStore)
      writeFile(scratchFile, "an untracked file\n")

      # ---- 3. a captured read set ------------------------------------------
      proc capture(label, readPath: string): CapturedReadSet =
        let depfile = fx.sib.scratch / (label & ".iomon")
        let monitored = runShell(shellCommand(@[fx.sib.repro, "internal",
          "io", "monitor", "--depfile", depfile, "--", "sh", "-c",
          "cat " & q(readPath) & " > /dev/null"]))
        checkpoint(monitored.output)
        check monitored.code == 0
        readSetFromMonitorDepFile(depfile)
      let readScratch = capture("reads-scratch", scratchFile)
      check readScratch.captured
      for mode in [cuiReadSet, cuiStrict]:
        let judged = judgeUntrackedInputs(mode, app, @["scratch.txt"],
          readScratch)
        check judged.withhold
        check judged.offending == @["scratch.txt"]
      let readTracked = capture("reads-tracked", app / "README.md")
      check readTracked.captured
      let lenient = judgeUntrackedInputs(cuiReadSet, app, @["scratch.txt"],
        readTracked)
      check not lenient.withhold
      check lenient.note.len == 0          # a read set WAS captured
      # Strict needs no read set: any untracked file withholds.
      check judgeUntrackedInputs(cuiStrict, app, @["scratch.txt"],
        readTracked).withhold
      # No read set: the default issues and says why it could not judge.
      let none = judgeUntrackedInputs(cuiReadSet, app, @["scratch.txt"],
        noReadSetOnFixturePath)
      check not none.withhold
      check "no read set was captured" in none.note

      # ---- 4. an invalid value is a loud error ------------------------------
      writeFile(fx.sib.ws / "projects" / "app.toml", projectToml)
      fx.appendProjectToml("[certificates]\nuntracked_inputs = \"sometimes\"\n")
      let res4 = fx.certify(fixtureJson)
      checkpoint(res4.output)
      check not fx.anyCertificateIssued()
      check "no certificate" in res4.output
      check "untracked_inputs" in res4.output
      check "sometimes" in res4.output
      check "read-set | strict" in res4.output
      # The pre-push gate, which resolves the same table, refuses loudly too.
      let gate = runCmd(q(fx.sib.repro) & " check --mode=pre-push" &
        " --workspace-root=" & q(fx.sib.ws) & " --current-repo=" & q(app))
      checkpoint(gate.output)
      check gate.code != 0
      check "untracked_inputs" in gate.output
