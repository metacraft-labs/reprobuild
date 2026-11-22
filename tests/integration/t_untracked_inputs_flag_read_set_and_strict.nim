## TC-8d — the untracked-inputs flag (operator decision D5): the certificate
## policy's ``untracked_inputs`` (``untrackedInputs`` in its declaration),
## read from the ``[certificate_policy]`` snapshot in the tested content's
## ``repro.lock`` (TC-9d; it was the project's ``[certificates]`` table).
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
##      only a tracked file withholds in neither mode. A read of a file outside
##      the content that ``git status`` does not list (an IGNORED file)
##      withholds in both modes, unless it is a declared output of the
##      certified closure or lies under one of its exempt output trees.
##      Strict mode tells the files the tests read from those merely present.
##   4. An invalid value (``"sometimes"``) in the snapshot → a loud error
##      naming the key and the accepted values, and no certificate — never a
##      silent default. The pre-push gate refuses the commit carrying it too.
##
## Falsifiability: a "strict" that fell back to "read-set" issues in case 2;
## a judgement that ignored the read set issues in case 3.
##
## NO MOCKS: real repositories, the built ``repro`` and its monitor. Skip
## rule: ``git`` or ``ssh-keygen`` missing.

import std/[os, sets, strutils, unittest]
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
      let strictSection = offPolicySection(puiStrict)
      check "untracked_inputs = \"strict\"" in strictSection
      fx.commitAppPolicySection(strictSection)
      # The snapshot is part of the content: the certified content moved.
      let strictContent = fx.workingTreeContentId(app)
      check strictContent != content
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
      let strictIssued = fx.issuedFor(strictContent)
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
          "cat " & q(readPath) & " > /dev/null 2>&1 || true"]))
        checkpoint(monitored.output)
        check monitored.code == 0
        readSetFromMonitorDepFile(depfile)
      # What the index tracks, as issuance lists it after the run.
      var tracked = initHashSet[string]()
      for entry in fx.gitIn(app, "ls-files --cached --full-name").splitLines():
        if entry.strip().len > 0:
          tracked.incl(entry.strip())
      check "README.md" in tracked
      let readScratch = capture("reads-scratch", scratchFile)
      check readScratch.captured
      for mode in [cuiReadSet, cuiStrict]:
        let judged = judgeUntrackedInputs(mode, app, @["scratch.txt"],
          tracked, readScratch)
        check judged.withhold
        check judged.offending == @["scratch.txt"]
        check judged.read == @["scratch.txt"]
      let readTracked = capture("reads-tracked", app / "README.md")
      check readTracked.captured
      let lenient = judgeUntrackedInputs(cuiReadSet, app, @["scratch.txt"],
        tracked, readTracked)
      check not lenient.withhold
      check lenient.note.len == 0          # a read set WAS captured
      # Strict needs no read set: any untracked file withholds.
      let strictTracked = judgeUntrackedInputs(cuiStrict, app,
        @["scratch.txt"], tracked, readTracked)
      check strictTracked.withhold
      check strictTracked.offending == @["scratch.txt"]
      check strictTracked.read.len == 0    # present, not read
      # An IGNORED file (untracked, but not in ``git status``'s list, so not
      # in ``untrackedPaths``) that the tests read withholds in both modes:
      # the content binds it no more than an untracked one. Declared as an
      # output of an action in the certified closure, the same read is exempt.
      let ignoredFile = app / "local.env"
      writeFile(ignoredFile, "TOKEN=local\n")
      let readIgnored = capture("reads-ignored", ignoredFile)
      check readIgnored.captured
      for mode in [cuiReadSet, cuiStrict]:
        let judged = judgeUntrackedInputs(mode, app, @["scratch.txt"],
          tracked, readIgnored)
        check judged.withhold
        check "local.env" in judged.offending
        check judged.read == @["local.env"]
      var asOutput = readIgnored
      asOutput.exemptOutputs = @[ignoredFile]
      check not judgeUntrackedInputs(cuiReadSet, app, @["scratch.txt"],
        tracked, asOutput).withhold
      # A tree whose name is a prefix of the file's ("local" of "local.env")
      # does not contain it.
      var besideTree = readIgnored
      besideTree.exemptOutputTrees = @[app / "local"]
      check judgeUntrackedInputs(cuiReadSet, app, @["scratch.txt"],
        tracked, besideTree).withhold
      removeFile(ignoredFile)
      # A lookup that FAILED read nothing: probing for an optional ignored
      # file that is absent must not withhold a certificate.
      let readAbsent = capture("reads-absent", app / "absent.env")
      check readAbsent.captured
      for mode in [cuiReadSet, cuiStrict]:
        let judged = judgeUntrackedInputs(mode, app, @["scratch.txt"],
          tracked, readAbsent)
        check "absent.env" notin judged.offending
        check "absent.env" notin judged.read
      # A file under an exempt tree (an output the engine empties first, or
      # the scratch directory of an action that ran) is exempt; the same
      # read with no such tree withholds.
      createDir(app / "cache-tree")
      let treeFile = app / "cache-tree" / "blob.bin"
      writeFile(treeFile, "written by the run\n")
      let readInTree = capture("reads-in-tree", treeFile)
      check readInTree.captured
      check judgeUntrackedInputs(cuiReadSet, app, @["scratch.txt"],
        tracked, readInTree).offending == @["cache-tree/blob.bin"]
      var inTree = readInTree
      inTree.exemptOutputTrees = @[app / "cache-tree"]
      check not judgeUntrackedInputs(cuiReadSet, app, @["scratch.txt"],
        tracked, inTree).withhold
      removeDir(app / "cache-tree")
      # No read set: the default issues and says why it could not judge.
      let none = judgeUntrackedInputs(cuiReadSet, app, @["scratch.txt"],
        tracked, noReadSetOnFixturePath)
      check not none.withhold
      check "no read set was captured" in none.note

      # ---- 3b. a read through a link is placed by the link ------------------
      # Test-Certificates §"Issuance preconditions": the link is the entry
      # read, so an untracked link withholds wherever it points (a verifier
      # who checks out the content has no such link). Only the ancestors of
      # the entry are resolved (Monitor-Hook-Shim §"Both sides in one
      # resolution"). Hand-built read sets: the judgement is the unit.
      createDir(app / "lib")
      createDir(app / "src")
      createDir(app / "gen")
      writeFile(app / "lib" / "tracked.txt", "tracked\n")
      writeFile(app / "gen" / "a.txt", "an output\n")
      writeFile(app / "lib" / "loose.txt", "untracked\n")
      var linkTracked = tracked
      linkTracked.incl("lib/tracked.txt")
      proc readsOf(paths: varargs[string]): CapturedReadSet =
        CapturedReadSet(captured: true, source: "hand-built",
          paths: @paths)
      # An untracked link to a tracked file withholds, naming the link.
      createSymlink("../lib/tracked.txt", app / "src" / "link")
      check judgeUntrackedInputs(cuiReadSet, app, @[], linkTracked,
        readsOf(app / "src" / "link")).offending == @["src/link"]
      # An untracked link into an exempt output tree is not exempt.
      createSymlink("../gen/a.txt", app / "src" / "gen-link")
      var viaTree = readsOf(app / "src" / "gen-link")
      viaTree.exemptOutputTrees = @[app / "gen"]
      check judgeUntrackedInputs(cuiReadSet, app, @[], linkTracked,
        viaTree).offending == @["src/gen-link"]
      var viaOutput = readsOf(app / "src" / "gen-link")
      viaOutput.exemptOutputs = @[app / "gen" / "a.txt"]
      check judgeUntrackedInputs(cuiReadSet, app, @[], linkTracked,
        viaOutput).offending == @["src/gen-link"]
      # A tracked link to a tracked file is bound by the content.
      createSymlink("../lib/tracked.txt", app / "src" / "tlink")
      var linkBound = linkTracked
      linkBound.incl("src/tlink")
      check not judgeUntrackedInputs(cuiReadSet, app, @[], linkBound,
        readsOf(app / "src" / "tlink")).withhold
      # A tracked link to an untracked file: the target is read too, and
      # the content binds only the link, so the target withholds.
      createSymlink("../lib/loose.txt", app / "src" / "tloose")
      linkBound.incl("src/tloose")
      check judgeUntrackedInputs(cuiReadSet, app, @[], linkBound,
        readsOf(app / "src" / "tloose")).offending == @["lib/loose.txt"]
      # A tracked link to an exempt output is exempt on both counts.
      createSymlink("../gen/a.txt", app / "src" / "tgen")
      linkBound.incl("src/tgen")
      var tgen = readsOf(app / "src" / "tgen")
      tgen.exemptOutputs = @[app / "gen" / "a.txt"]
      check not judgeUntrackedInputs(cuiReadSet, app, @[], linkBound,
        tgen).withhold
      # A link among the ANCESTORS is still resolved: it names a directory,
      # and the file under it is placed by where that directory is.
      createSymlink("lib", app / "alias")
      check not judgeUntrackedInputs(cuiReadSet, app, @[], linkTracked,
        readsOf(app / "alias" / "tracked.txt")).withhold
      check judgeUntrackedInputs(cuiReadSet, app, @[], linkTracked,
        readsOf(app / "alias" / "loose.txt")).offending == @["lib/loose.txt"]
      removeDir(app / "src"); removeDir(app / "lib"); removeDir(app / "gen")
      removeFile(app / "alias")

      # ---- 4. an invalid value is a loud error ------------------------------
      # Not renderable (the renderer only writes valid values), so the
      # valid snapshot is edited by hand, as a hand-edited lock would be.
      let bogus = offPolicySection().replace(
        "untracked_inputs = \"read-set\"", "untracked_inputs = \"sometimes\"")
      check "sometimes" in bogus
      fx.commitAppPolicySection(bogus)
      let res4 = fx.certify(fixtureJson)
      checkpoint(res4.output)
      check not fx.anyCertificateIssued()
      check "no certificate" in res4.output
      check "untracked_inputs" in res4.output
      check "sometimes" in res4.output
      check "read-set, strict" in res4.output
      # The pre-push gate, which reads the same snapshot out of the pushed
      # commit, refuses loudly too (a malformed policy is never "off").
      let gate = runCmd(q(fx.sib.repro) & " check --mode=pre-push" &
        " --workspace-root=" & q(fx.sib.ws) & " --current-repo=" & q(app))
      checkpoint(gate.output)
      check gate.code != 0
      check "untracked_inputs" in gate.output
