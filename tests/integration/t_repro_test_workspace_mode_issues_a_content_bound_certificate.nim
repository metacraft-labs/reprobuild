## TC-8e — ``repro test`` issues certificates on the real build path, for the
## certificate-producing nodes its plan materializes (Test-Certificates.md
## §"Issuance", §"Marking a node"; test-certificates Standard §3.2, §3.3, §8).
##
## ``app`` declares five edges: ``unit_a`` and ``unit_b`` (``unit_b`` reads
## ``unit_a``'s output; the two are marked together as
## ``certificate "unit-suite"``), ``lone`` (unmarked), ``side`` (marked as
## ``certificate "side-suite"``) and ``scratch``, whose input is an UNTRACKED
## file (marked as ``certificate "scratch-suite"``). ``aggregate("test", ...)``
## over the first three makes a plain ``repro test`` build them, so ``test`` is
## implicitly marked. In order, with no ``--fixture-from``:
##
##   1. a plain ``repro test`` issues ``targets = ["test"]`` for the working
##      tree's content: signed, ``base`` = HEAD, ``untracked = true`` (the
##      scratch input is present), its commands the three edges' argv as the
##      engine launched them, and a note on the shared ref under the tree.
##      ``unit-suite``, whose closure ``test`` builds whole, is certified too,
##      with its own two commands. The run ends naming the marked nodes it did
##      not select;
##   2. ``repro test lone-out`` (an unmarked sub-target) issues nothing;
##   3. after an edit to a tracked file no edge reads, ``repro test
##      unit-suite`` executes nothing (the run counter is unchanged): both
##      members are answered by records of executions this host observed,
##      whose keys cover what the monitor saw them read, so it issues
##      ``targets = ["unit-suite"]`` for the edited content with both commands
##      (Standard §6.2.1; decision D16);
##   3b. after ``unit_a``'s record is re-installed through the peer cache's
##      installer (as a LAN fetch installs one) and README is edited again,
##      the same run still executes nothing but withholds ``unit-suite``,
##      naming ``unit_a`` (and not ``unit_b``) and ``repro certify
##      unit-suite``;
##   4. ``repro certify unit-suite`` finds the same refused reuse, re-executes
##      both members and issues
##      ``targets = ["unit-suite"]`` for that content, its commands in
##      the order they ran; the production verifier reports the commit made
##      from that working tree covered for ``unit-suite``;
##   4b. after an edit to ``unit_a``'s input, both members re-run (a changed
##      input is not a hit) and the new content is certified;
##   5. with ``unit_a``'s input edited to fail (so ``unit_b``, which reads its
##      output, is blocked), ``repro test unit-suite
##      side-suite`` exits non-zero, leaves ``unit-suite`` uncertified for that
##      content, and certifies ``side-suite``;
##   5b. the same run again executes ``unit_a`` again (a failure is never
##      cached, so never reused) and withholds again;
##   6. ``repro test scratch-suite``: the monitor shows the edge read the
##      untracked file, so the certificate is withheld (the read-set arm of the
##      untracked-inputs rule, live on this path). Run again, the edge is
##      answered by the cache and the read set comes from its record, which
##      still names the file, so it is withheld again.
##
## Not covered here: the lock-update node a plain ``repro test`` is to run
## before its tests does not exist yet (Unified-Locking-And-Hooks HL-10).
##
## NO MOCKS: real repositories and manifest, the built ``repro``, the real
## provider, engine and monitor, the production verifier. Step 3b installs a
## record through the peer cache's production installer in-process rather than
## from a second peer (see ``installAsPeerRecord``): the property is the
## installed record's provenance, not the transport. Skip rule: ``git`` or
## ``ssh-keygen`` missing.

import std/[os, osproc, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import ./certify_workspace_mode_fixture

const buildLines =
  # ``unit_b`` reads ``unit_a``'s output, so it depends on it and starts after
  # it: the two members have one execution order.
  "    let unit_b = certTool(actionId = \"unit_b\",\n" &
  "      input = \"build/unit_a-out\",\n" &
  "      output = \"build/unit_b-out\",\n" &
  "      marker = \".repro/runs.log\")\n" &
  "    certificate \"unit-suite\", aggregate(\"unit-suite\", @[unit_a, unit_b])\n" &
  "    certificate \"side-suite\", aggregate(\"side-suite\", @[side])\n" &
  "    certificate \"scratch-suite\", aggregate(\"scratch-suite\", @[scratch])\n" &
  "    discard aggregate(\"test\", @[unit_a, unit_b, lone])\n"

proc outputsEndWith(cert: TestCertificate; stems: openArray[string]): bool =
  let outputs = commandOutputs(cert)
  if outputs.len != stems.len:
    return false
  for i, stem in stems:
    if not outputs[i].endsWith("build/" & stem & "-out"):
      return false
  true

proc sortedOutputsEndWith(cert: TestCertificate;
                         stems: openArray[string]): bool =
  ## Parallel edges have no fixed relative order; compare as a set.
  var outputs = commandOutputs(cert)
  if outputs.len != stems.len:
    return false
  for stem in stems:
    var hit = -1
    for i, output in outputs:
      if output.endsWith("build/" & stem & "-out"):
        hit = i
    if hit < 0:
      return false
    outputs.delete(hit)
  true

suite "TC-8e — issue on the real repro test path":

  test "t_repro_test_workspace_mode_issues_a_content_bound_certificate":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs a certificate " &
        "in real repositories")
    else:
      var fx = setupWorkspaceCertifyFixture("tc8e-issue",
        ["unit_a", "lone", "side", "scratch"], buildLines,
        untrackedStems = ["scratch"])
      defer: removeDir(fx.cf.sib.scratch)
      let app = fx.app
      let base = fx.cf.sib.headOf(app)
      let content = fx.contentNow()

      # ---- 1. a plain repro test issues targets = ["test"] -----------------
      let plain = fx.reproIn(["test", "--tool-provisioning=path"])
      checkpoint(plain.output)
      check plain.code == 0
      let testCerts = fx.certificatesFor(content, "test")
      check testCerts.len == 1
      if testCerts.len == 1:
        let cert = testCerts[0]
        check cert.vcs.content == content
        check cert.vcs.base == base
        check cert.vcs.untracked
        check cert.isSigned
        check cert.framework == reprobuildFrameworkId
        check sortedOutputsEndWith(cert, ["unit_a", "unit_b", "lone"])
        for command in cert.commands:
          check command.argv[0].endsWith("cert-tool")
        # Noted on the shared ref under the tree the content names.
        let tree = content.split(':')[^1]
        let note = execCmdEx("git -C " & quoteShell(app) &
          " notes --ref=refs/notes/test-certificates/certificates show " &
          tree)
        checkpoint(note.output)
        check note.exitCode == 0
        check cert.signature.value in note.output
      check "issued test-certificate.v1 for 'test'" in plain.output
      # ``unit-suite``'s whole closure is part of what ``test`` builds, so the
      # plan materializes it too, and it is certified with its own commands.
      let unitFirst = fx.certificatesFor(content, "unit-suite")
      check unitFirst.len == 1
      if unitFirst.len == 1:
        check outputsEndWith(unitFirst[0], ["unit_a", "unit_b"])
      check "not certified by this run: side-suite, scratch-suite" in
        plain.output
      let afterPlain = fx.storedCount()
      check afterPlain == 2

      # ---- 2. an unmarked sub-target issues nothing ------------------------
      let lone = fx.reproIn(["test", "lone-out", "--tool-provisioning=path"])
      checkpoint(lone.output)
      check lone.code == 0
      check fx.storedCount() == afterPlain
      check "issued" notin lone.output

      # ---- 3. new content, members reused from this host's cache: issued ---
      # README.md is tracked and read by no edge: the content changes, the
      # edges' inputs do not. Both members are answered by records of
      # executions this host observed, whose keys cover what the monitor saw
      # them read, so the claim rests on them (Standard §6.2.1, D16).
      writeFile(app / "README.md", "app fixture, edited\n")
      let edited = fx.contentNow()
      check edited != content
      let ranBeforeCached = fx.executedOutputs().len
      let cached = fx.reproIn(["test", "unit-suite",
        "--tool-provisioning=path"])
      checkpoint(cached.output)
      check cached.code == 0
      check fx.executedOutputs().len == ranBeforeCached
      let reusedCerts = fx.certificatesFor(edited, "unit-suite")
      check reusedCerts.len == 1
      if reusedCerts.len == 1:
        check reusedCerts[0].isSigned
        check reusedCerts[0].vcs.base == base
        check outputsEndWith(reusedCerts[0], ["unit_a", "unit_b"])
      check "issued test-certificate.v1 for 'unit-suite'" in cached.output

      # ---- 3b. a member reused from a record a peer supplied: withheld -----
      # unit_a's record goes back into the cache through the peer cache's
      # installer, as a LAN fetch would put it there. The edge still hits;
      # the record no longer comes from an execution this host observed.
      check fx.installAsPeerRecord("unit_a") == ""
      writeFile(app / "README.md", "app fixture, edited twice\n")
      let peerContent = fx.contentNow()
      let ranBeforePeer = fx.executedOutputs().len
      let peer = fx.reproIn(["test", "unit-suite",
        "--tool-provisioning=path"])
      checkpoint(peer.output)
      check peer.code == 0
      check fx.executedOutputs().len == ranBeforePeer
      check fx.certificatesFor(peerContent, "unit-suite").len == 0
      check "cannot be attested" in peer.output
      check "unit_a (its cache record is not one this host observed" in
        peer.output
      check "unit_b (" notin peer.output
      check "repro certify unit-suite" in peer.output

      # ---- 4. repro certify re-executes them and issues --------------------
      let ranBefore = fx.executedOutputs().len
      let certified = fx.reproIn(["certify", "unit-suite",
        "--tool-provisioning=path"])
      checkpoint(certified.output)
      check certified.code == 0
      check "re-executing 2 test command(s) whose cached results cannot be " &
        "attested" in certified.output
      let executed = fx.executedOutputs()
      check executed.len == ranBefore + 2
      let unitCerts = fx.certificatesFor(peerContent, "unit-suite")
      check unitCerts.len == 1
      if unitCerts.len == 1:
        check unitCerts[0].isSigned
        check unitCerts[0].vcs.base == base
        # Execution order: unit_b depends on unit_a, so it ran second, and
        # the record lists the commands in that order.
        check outputsEndWith(unitCerts[0], ["unit_a", "unit_b"])
        if executed.len == ranBefore + 2:
          check executed[ranBefore].endsWith("build/unit_a-out")
          check executed[ranBefore + 1].endsWith("build/unit_b-out")
      # The commit made from the certified working tree is covered.
      discard fx.cf.gitIn(app, "commit -q -a -m edited")
      let committed = fx.cf.sib.headOf(app)
      let verdict = fx.cf.coverageAt(app, committed, "unit-suite")
      checkpoint("untrusted=" & $verdict.untrusted & " unevaluated=" &
        $verdict.unevaluated & " missing=" & $verdict.missing)
      check verdict.outcome == voCovered

      # ---- 4b. an input a member reads changed: not a hit, it re-runs ------
      writeFile(app / "src" / "unit_a.txt", "unit_a v2\n")
      let changed = fx.contentNow()
      let ranBeforeChange = fx.executedOutputs().len
      let rerun = fx.reproIn(["test", "unit-suite",
        "--tool-provisioning=path"])
      checkpoint(rerun.output)
      check rerun.code == 0
      check fx.executedOutputs().len == ranBeforeChange + 2
      let changedCerts = fx.certificatesFor(changed, "unit-suite")
      check changedCerts.len == 1
      if changedCerts.len == 1:
        check outputsEndWith(changedCerts[0], ["unit_a", "unit_b"])

      # ---- 5. a failing member: unit-suite withheld, side-suite issued -----
      writeFile(app / "src" / "unit_a.txt", "FAIL now\n")
      let failing = fx.contentNow()
      check failing != content
      let mixed = fx.reproIn(["test", "unit-suite", "side-suite",
        "--tool-provisioning=path"])
      checkpoint(mixed.output)
      check mixed.code != 0
      check fx.certificatesFor(failing, "unit-suite").len == 0
      check "no certificate for 'unit-suite'" in mixed.output
      check "did not pass" in mixed.output
      let sideCerts = fx.certificatesFor(failing, "side-suite")
      check sideCerts.len == 1
      if sideCerts.len == 1:
        check sideCerts[0].isSigned
        check outputsEndWith(sideCerts[0], ["side"])

      # ---- 5b. a failure is never reused: the same content fails again -----
      # The engine records no result for a failed action, so the failing
      # member executes again rather than being answered by the cache.
      let ranBeforeRetry = fx.executedOutputs().len
      let retry = fx.reproIn(["test", "unit-suite",
        "--tool-provisioning=path"])
      checkpoint(retry.output)
      check retry.code != 0
      check fx.executedOutputs().len == ranBeforeRetry + 1
      check fx.certificatesFor(failing, "unit-suite").len == 0
      check "did not pass" in retry.output
      writeFile(app / "src" / "unit_a.txt", "unit_a v1\n")

      # ---- 6. an edge that read an untracked file: withheld ----------------
      let scratch = fx.reproIn(["test", "scratch-suite",
        "--tool-provisioning=path"])
      checkpoint(scratch.output)
      check scratch.code == 0
      check fx.certificatesFor(fx.contentNow(), "scratch-suite").len == 0
      check "the tests read untracked files" in scratch.output
      check "src/scratch.txt" in scratch.output

      # ---- 6b. the same edge reused from the cache: still withheld ---------
      # Nothing executes; the read set now comes from the record of the
      # execution in step 6, which names the untracked file.
      let ranBeforeScratch = fx.executedOutputs().len
      let scratchAgain = fx.reproIn(["test", "scratch-suite",
        "--tool-provisioning=path"])
      checkpoint(scratchAgain.output)
      check scratchAgain.code == 0
      check fx.executedOutputs().len == ranBeforeScratch
      check fx.certificatesFor(fx.contentNow(), "scratch-suite").len == 0
      check "the tests read untracked files" in scratchAgain.output
      check "src/scratch.txt" in scratchAgain.output
