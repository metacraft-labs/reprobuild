## A certificate may rest on a test result the action cache reused only when
## the inputs that result was computed from are byte-identical to the ones in
## the certified content (test-certificates Standard §6.2.1, "the record
## covers the inputs"; Test-Certificates.md §"Reused results"). A cache key
## match does not establish that: under the default ``timestamp`` input-check
## policy an input is identified by its size and mtime, and a ``hybrid``
## lookup trusts an input whose size and mtime are unchanged without reading
## it (Caching-Architecture.md §"Known Limit: The Default Policy Can Serve A
## Stale Result").
##
## Attack-shaped (reprobuild-pm Provisional-Issue-Lifecycle.md §2.1): each
## step replaces an input with bytes that make the test FAIL, keeping its size
## and restoring its mtime with ``touch -r`` -- what ``cp -p``, ``rsync -a``,
## ``tar -x`` or a restore leave behind. Before the fix every one of them was
## a cache hit and ``repro test`` signed a certificate claiming the failing
## content passes. Recorded as reprobuild-pm issue
## ``2026-11-12-certificates-attest-reused-test-results-whose-inputs-are-only-metadata-identical.md``.
##
## ``app`` declares four edges through the fixture's copying tool (it exits 1
## on an input that starts with ``FAIL``):
##
##   * ``side`` -- ``timestamp`` policy, the one member of ``side-suite``;
##   * ``pure`` -- ``hybrid`` policy, the one member of ``pure-suite``;
##   * ``gen``  -- ``timestamp`` policy, a member of no node;
##   * ``check`` -- ``hybrid`` policy, reads ``gen``'s output, the one member
##     of ``check-suite``, so ``gen`` is in that node's closure.
##
## In order:
##
##   0. ``repro certify`` runs all four and certifies the three nodes;
##   1. positive control: after an edit to a tracked file no edge reads,
##      ``repro test pure-suite`` executes nothing and IS certified -- a
##      content-checked record whose inputs still hash the same counts, so the
##      fix does not simply refuse every reuse;
##   2. ``side``'s input made to fail, size and mtime kept: ``repro test
##      side-suite`` is answered by the cache and withholds the name, naming
##      the timestamp policy; ``repro certify side-suite`` then re-executes
##      it, the test fails, and nothing is certified;
##   3. the same against ``pure`` (hybrid): withheld, naming the input whose
##      content moved; ``repro certify pure-suite`` re-executes and fails;
##   4. the same against ``gen``, which no node marks: ``check`` reads its
##      stale output and is a verified hit itself, yet ``check-suite`` is
##      withheld, naming ``gen``; ``repro certify check-suite`` re-executes
##      ``gen``, which fails, and nothing is certified.
##
## NO MOCKS: real repositories and manifest, the built ``repro``, the real
## provider, engine and monitor, the production certificate store. Skip rule:
## ``git``, ``ssh-keygen`` or ``touch`` missing.
##
## Falsifiability: make ``reusedContentRefusal`` return ``""`` (or set
## ``cacheRecordContentVerified`` true unconditionally in the engine's
## ``noteCacheRecordProvenance``) and steps 2-4 each find a certificate for
## content whose test fails.

import std/[os, osproc, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import ./certify_workspace_mode_fixture

const buildLines =
  "    let check = certTool(actionId = \"check\",\n" &
  "      input = \"build/gen-out\",\n" &
  "      output = \"build/check-out\",\n" &
  "      actionCachePolicy = acfpHybrid,\n" &
  "      marker = \".repro/runs.log\")\n" &
  "    certificate \"side-suite\", aggregate(\"side-suite\", @[side])\n" &
  "    certificate \"pure-suite\", aggregate(\"pure-suite\", @[pure])\n" &
  "    certificate \"check-suite\", aggregate(\"check-suite\", @[check])\n"

proc replaceKeepingSizeAndMtime(path, content: string) =
  ## Write ``content`` over ``path`` and put the old mtime back, the way
  ## ``cp -p`` or an archive extraction leaves a replaced file. The new bytes
  ## must be exactly as long as the old ones, or the size alone would give
  ## the change away and the test would prove nothing.
  let old = readFile(path)
  doAssert content.len == old.len and content != old,
    "the replacement must keep the size and change the bytes"
  let mtime = getLastModificationTime(path)
  let reference = path & ".mtime-ref"
  doAssert execCmdEx("cp -p " & quoteShell(path) & " " &
    quoteShell(reference)).exitCode == 0
  writeFile(path, content)
  # GNU touch sets the times with utimensat(2), nanoseconds included.
  doAssert execCmdEx("touch -r " & quoteShell(reference) & " " &
    quoteShell(path)).exitCode == 0
  removeFile(reference)
  doAssert getFileSize(path) == old.len
  doAssert getLastModificationTime(path) == mtime
  doAssert readFile(path) == content

suite "a reused result is attested only over byte-identical inputs":

  test "an input replaced with its size and mtime kept is never attested":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0 or
        findExe("touch").len == 0:
      skip("git, ssh-keygen or touch not on PATH; this test signs " &
        "certificates in real repositories")
    else:
      var fx = setupWorkspaceCertifyFixture("reuse-bytes",
        ["side", "pure", "gen"], buildLines, hybridStems = ["pure"])
      defer: removeDir(fx.cf.sib.scratch)
      let app = fx.app

      # ---- 0. every node certified from a full run ------------------------
      let first = fx.reproIn(["certify", "side-suite", "pure-suite",
        "check-suite", "--tool-provisioning=path"])
      checkpoint(first.output)
      check first.code == 0
      let original = fx.contentNow()
      for name in ["side-suite", "pure-suite", "check-suite"]:
        checkpoint(name)
        check fx.certificatesFor(original, name).len == 1
      check fx.executedOutputs().len == 4

      # ---- 1. positive control: verified reuse still counts ----------------
      writeFile(app / "README.md", "app fixture, edited\n")
      let readmeEdited = fx.contentNow()
      check readmeEdited != original
      let ranBeforeControl = fx.executedOutputs().len
      let control = fx.reproIn(["test", "pure-suite",
        "--tool-provisioning=path"])
      checkpoint(control.output)
      check control.code == 0
      check fx.executedOutputs().len == ranBeforeControl
      check fx.certificatesFor(readmeEdited, "pure-suite").len == 1
      check "issued test-certificate.v1 for 'pure-suite'" in control.output

      # ---- 2. timestamp member: the replaced input is never attested -------
      replaceKeepingSizeAndMtime(app / "src" / "side.txt", "FAIL v1\n")
      let sideFails = fx.contentNow()
      let ranBeforeSide = fx.executedOutputs().len
      let sideTest = fx.reproIn(["test", "side-suite",
        "--tool-provisioning=path"])
      checkpoint(sideTest.output)
      # The edge was a cache hit (nothing executed): exactly the reuse the
      # certificate must not rest on.
      check fx.executedOutputs().len == ranBeforeSide
      check fx.certificatesFor(sideFails, "side-suite").len == 0
      check "cannot be attested" in sideTest.output
      # A one-edge aggregate is the edge's public name, so the refused
      # command is reported as ``side-suite``.
      check "side-suite (its cache record was made under the timestamp " &
        "input-check policy" in sideTest.output
      check "repro certify side-suite" in sideTest.output
      let sideCertify = fx.reproIn(["certify", "side-suite",
        "--tool-provisioning=path"])
      checkpoint(sideCertify.output)
      check sideCertify.code != 0
      check fx.executedOutputs().len == ranBeforeSide + 1
      check fx.certificatesFor(sideFails, "side-suite").len == 0

      # ---- 3. hybrid member: metadata kept, content moved -----------------
      replaceKeepingSizeAndMtime(app / "src" / "pure.txt", "FAIL v1\n")
      let pureFails = fx.contentNow()
      let ranBeforePure = fx.executedOutputs().len
      let pureTest = fx.reproIn(["test", "pure-suite",
        "--tool-provisioning=path"])
      checkpoint(pureTest.output)
      check fx.executedOutputs().len == ranBeforePure
      check fx.certificatesFor(pureFails, "pure-suite").len == 0
      check "cannot be attested" in pureTest.output
      check "src/pure.txt no longer has the content" in pureTest.output
      let pureCertify = fx.reproIn(["certify", "pure-suite",
        "--tool-provisioning=path"])
      checkpoint(pureCertify.output)
      check pureCertify.code != 0
      check fx.executedOutputs().len == ranBeforePure + 1
      check fx.certificatesFor(pureFails, "pure-suite").len == 0

      # ---- 4. a reused action the member depends on ------------------------
      # ``gen`` is no node's member; ``check`` reads its (now stale) output,
      # whose bytes have not moved, so ``check`` itself is a verified hit.
      replaceKeepingSizeAndMtime(app / "src" / "gen.txt", "FAIL v\n")
      let genFails = fx.contentNow()
      let ranBeforeGen = fx.executedOutputs().len
      let genTest = fx.reproIn(["test", "check-suite",
        "--tool-provisioning=path"])
      checkpoint(genTest.output)
      check fx.executedOutputs().len == ranBeforeGen
      check fx.certificatesFor(genFails, "check-suite").len == 0
      check "gen (its cache record was made under the timestamp " &
        "input-check policy" in genTest.output
      check "check (" notin genTest.output
      check "repro certify check-suite" in genTest.output
      let genCertify = fx.reproIn(["certify", "check-suite",
        "--tool-provisioning=path"])
      checkpoint(genCertify.output)
      check genCertify.code != 0
      check fx.certificatesFor(genFails, "check-suite").len == 0
      # ``gen`` was re-executed (and failed), not reused again.
      check fx.executedOutputs().len > ranBeforeGen
      check fx.executedOutputs()[ranBeforeGen].endsWith("build/gen-out")
