## A test that read an IGNORED file is not certified: the content a
## certificate names does not bind ignored files any more than untracked ones,
## so nothing could verify what the test ran against (test-certificates
## Standard §3.2, Content-Id §2; Test-Certificates.md §"Issuance
## preconditions", the untracked-inputs bullet). The one exemption is a
## declared output of an action in the certified node's closure: the closure
## produced it from the bound content, so the content binds it too.
##
## Recorded as reprobuild-pm
## ``issues/2026-11-12-reads-of-ignored-files-and-runs-with-no-monitor-data-do-not-withhold-a-certificate.md``:
## the read-set rule judged a captured read only against ``git status``'s
## untracked, NON-ignored files, so a test that read ``.env`` (or a stray file
## under an ignored ``build/``) was certified, with ``untracked = false``.
##
## ``app`` declares, through the TC-8e fixture's copying tool:
##
##   * ``gen`` (``src/gen.txt`` → ``build/gen-out``) and ``use``, which reads
##     ``build/gen-out``: an ignored path that is ``gen``'s declared output.
##     ``certificate "derived-suite"`` marks ``use`` alone, so ``gen`` is in
##     its closure only as a dependency;
##   * ``envread``, which reads ``.env``, ignored by the committed
##     ``.gitignore`` and produced by no action (``certificate "env-suite"``);
##   * ``stale``, which reads ``build/handmade.txt``: under the ignored build
##     directory, but no action declares it (``certificate "stale-suite"``).
##
## In order:
##
##   1. ``repro test derived-suite`` issues: reading the closure's own declared
##      output is not a read of something the content fails to bind;
##   2. ``repro test env-suite`` withholds, naming ``.env``;
##   3. run again, the edge is answered by the cache and the read set comes
##      from its record, which still names ``.env``: withheld again;
##   4. ``repro test stale-suite`` withholds, naming ``build/handmade.txt``:
##      lying in an output directory does not make a file an output.
##
## ``untracked_inputs = "strict"`` withholding on the same reads is pinned at
## the judgement level by ``t_untracked_inputs_flag_read_set_and_strict``:
## on this path the lock-update node re-derives the policy snapshot from the
## recipe, so a hand-committed snapshot would not survive to the run.
##
## Falsifiability: a judgement that consults only ``git status``'s untracked
## list issues in steps 2–4; one that exempts every ignored path issues in
## step 4; one that exempts nothing withholds in step 1.
##
## NO MOCKS: real repositories and manifest, the built ``repro``, the real
## provider, engine and monitor. Skip rule: ``git`` or ``ssh-keygen`` missing.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import ./certify_workspace_mode_fixture

const buildLines =
  "    let use = certTool(actionId = \"use\",\n" &
  "      input = \"build/gen-out\",\n" &
  "      output = \"build/use-out\",\n" &
  "      marker = \".repro/runs.log\")\n" &
  "    let envread = certTool(actionId = \"envread\",\n" &
  "      input = \".env\",\n" &
  "      output = \"build/envread-out\",\n" &
  "      actionCachePolicy = acfpHybrid,\n" &
  "      marker = \".repro/runs.log\")\n" &
  "    let stale = certTool(actionId = \"stale\",\n" &
  "      input = \"build/handmade.txt\",\n" &
  "      output = \"build/stale-out\",\n" &
  "      marker = \".repro/runs.log\")\n" &
  "    discard gen\n" &
  "    certificate \"derived-suite\", aggregate(\"derived-suite\", @[use])\n" &
  "    certificate \"env-suite\", aggregate(\"env-suite\", @[envread])\n" &
  "    certificate \"stale-suite\", aggregate(\"stale-suite\", @[stale])\n"

suite "a test that read an ignored file is not certified":

  test "t_a_test_that_reads_an_ignored_file_is_not_certified":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs a certificate " &
        "in real repositories")
    else:
      var fx = setupWorkspaceCertifyFixture("ignored-read", ["gen"],
        buildLines, extraIgnores = [".env"])
      defer: removeDir(fx.cf.sib.scratch)
      let app = fx.app
      writeFile(app / ".env", "API_TOKEN=local-only\n")
      createDir(app / "build")
      writeFile(app / "build" / "handmade.txt", "put here by hand\n")
      # Both files are ignored: the content is what was committed.
      let content = fx.contentNow()
      check fx.cf.gitIn(app, "status --porcelain").strip() == ""

      # ---- 1. reading the closure's own declared output: issued ------------
      let derived = fx.reproIn(["test", "derived-suite",
        "--tool-provisioning=path"])
      checkpoint(derived.output)
      check derived.code == 0
      let derivedCerts = fx.certificatesFor(content, "derived-suite")
      check derivedCerts.len == 1
      if derivedCerts.len == 1:
        check not derivedCerts[0].vcs.untracked
      check "issued test-certificate.v1 for 'derived-suite'" in
        derived.output

      # ---- 2. reading an ignored file no action produces: withheld ---------
      let env = fx.reproIn(["test", "env-suite", "--tool-provisioning=path"])
      checkpoint(env.output)
      check env.code == 0
      let envCerts = fx.certificatesFor(content, "env-suite")
      for cert in envCerts:
        checkpoint("issued anyway, with untracked = " & $cert.vcs.untracked)
      check envCerts.len == 0
      check "no certificate for 'env-suite'" in env.output
      check "the tests read untracked files" in env.output
      check ".env" in env.output

      # ---- 3. the same edge answered by the cache: still withheld ----------
      # ``envread`` states ``hybrid`` so its reuse is attestable on its own
      # (Test-Certificates.md §"Reused results"); a ``timestamp`` record would
      # be refused before the read set is judged, and this step would no
      # longer test the read-set rule.
      let ranBefore = fx.executedOutputs().len
      let envAgain = fx.reproIn(["test", "env-suite",
        "--tool-provisioning=path"])
      checkpoint(envAgain.output)
      check envAgain.code == 0
      check fx.executedOutputs().len == ranBefore
      check fx.certificatesFor(content, "env-suite").len == 0
      check "the tests read untracked files" in envAgain.output
      check ".env" in envAgain.output

      # ---- 4. an ignored file in an output directory, not an output --------
      let stale = fx.reproIn(["test", "stale-suite",
        "--tool-provisioning=path"])
      checkpoint(stale.output)
      check stale.code == 0
      check fx.certificatesFor(content, "stale-suite").len == 0
      check "no certificate for 'stale-suite'" in stale.output
      check "build/handmade.txt" in stale.output
      check "build/gen-out" notin stale.output

