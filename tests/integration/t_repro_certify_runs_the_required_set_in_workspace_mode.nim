## TC-8e — ``repro certify`` with no arguments materializes the project's
## certificate-producing nodes and certifies each, on the real build path
## (Test-Certificates.md §"Issuance"). Until the shared branch policy exists
## (TC-9b) "the required set" is every node the project declares, the implicit
## ``test`` marking included.
##
## ``app`` declares ``unit-suite`` (two edges), ``side-suite`` (one edge) and
## an ``aggregate("test", ...)`` over all three edges. Then:
##   1. ``repro certify`` issues one signed certificate per name —
##      ``test``, ``unit-suite``, ``side-suite`` — each with exactly its own
##      commands, for the working tree's content;
##   2. a second ``repro certify`` on the same content is a no-op: no edge
##      executes and no certificate is added;
##   3. after a tracked edit to ``side``'s input, ``repro certify`` executes
##      only ``side`` (the other two are reused from this host's cache
##      records, which count: Standard §6.2.1, D16) and certifies all three
##      names for the new content;
##   4. committing that content and running a plain ``git push`` carries all
##      three certificates to the origin, as a note on the tree, through the
##      managed hook. Until then the clone has no notes ref;
##   5. certifying a further edit, committing and running ``repro push`` does the
##      same.
##
## NO MOCKS: real repositories and manifest, the built ``repro``, the real
## provider and engine. Skip rule: ``git`` or ``ssh-keygen`` missing.

import std/[os, osproc, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import ./certify_workspace_mode_fixture

const buildLines =
  "    certificate \"unit-suite\", aggregate(\"unit-suite\", @[unit_a, unit_b])\n" &
  "    certificate \"side-suite\", side\n" &
  "    discard aggregate(\"test\", @[unit_a, unit_b, side])\n"

suite "TC-8e — repro certify materializes the declared set":

  test "t_repro_certify_runs_the_required_set_in_workspace_mode":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs a certificate " &
        "in real repositories")
    else:
      var fx = setupWorkspaceCertifyFixture("tc8e-certify",
        ["unit_a", "unit_b", "side"], buildLines)
      defer: removeDir(fx.cf.sib.scratch)
      let content = fx.contentNow()

      # ---- 1. every declared name, one certificate each --------------------
      let first = fx.reproIn(["certify", "--tool-provisioning=path"])
      checkpoint(first.output)
      check first.code == 0
      for (name, count) in [("test", 3), ("unit-suite", 2),
                            ("side-suite", 1)]:
        let certs = fx.certificatesFor(content, name)
        checkpoint(name)
        check certs.len == 1
        if certs.len == 1:
          check certs[0].isSigned
          check certs[0].vcs.content == content
          check certs[0].commands.len == count
      check fx.storedCount() == 3
      let ran = fx.executedOutputs().len
      check ran >= 3

      # ---- 2. the same content again: a no-op ------------------------------
      let again = fx.reproIn(["certify", "--tool-provisioning=path"])
      checkpoint(again.output)
      check again.code == 0
      check "re-certify is a no-op" in again.output
      check fx.executedOutputs().len == ran
      check fx.storedCount() == 3

      # ---- 3. new content: certified again ---------------------------------
      writeFile(fx.app / "src" / "side.txt", "side v2\n")
      let edited = fx.contentNow()
      check edited != content
      let third = fx.reproIn(["certify", "--tool-provisioning=path"])
      checkpoint(third.output)
      check third.code == 0
      for name in ["test", "unit-suite", "side-suite"]:
        checkpoint(name)
        check fx.certificatesFor(edited, name).len == 1
      # Incremental: only the edge whose input changed executes; the other
      # two are reused from records of this host's executions (D16).
      check fx.executedOutputs().len == ran + 1

      # ---- 4. a plain git push carries what certify stored ------------------
      putEnv("REPROBUILD_REPRO", fx.cf.sib.repro)
      let hooks = fx.reproIn(["hooks", "ensure", "--vcs", fx.cf.sib.ws])
      checkpoint(hooks.output)
      check hooks.code == 0
      proc git(args: string): tuple[output: string; exitCode: int] =
        execCmdEx("git -C " & quoteShell(fx.app) & " " & args)
      var origin = ""
      for (name, path) in fx.cf.sib.origins:
        if name == "app": origin = path
      proc recordsOnOrigin(content: string): int =
        let note = execCmdEx("git -C " & quoteShell(origin) & " notes --ref=" &
          certificateNotesRef & " show " & content.split(':')[^1])
        if note.exitCode != 0: 0
        else: note.output.count("# --- test-certificate ---")
      check git("rev-parse --verify --quiet " & certificateNotesRef).exitCode != 0
      check git("commit -q -a -m " & quoteShell("certified side")).exitCode == 0
      check git("rev-parse HEAD^{tree}").output.strip() == edited.split(':')[^1]
      let plainPush = git("push origin main")
      checkpoint(plainPush.output)
      check plainPush.exitCode == 0
      check recordsOnOrigin(edited) == 3

      # ---- 5. so does repro push -------------------------------------------
      writeFile(fx.app / "src" / "side.txt", "side v3\n")
      let further = fx.contentNow()
      let fourth = fx.reproIn(["certify", "--tool-provisioning=path"])
      checkpoint(fourth.output)
      check fourth.code == 0
      check git("commit -q -a -m " & quoteShell("certified side again")).exitCode == 0
      check git("rev-parse HEAD^{tree}").output.strip() == further.split(':')[^1]
      check recordsOnOrigin(further) == 0
      let pushed = fx.reproIn(["push", "--no-certify"])
      checkpoint(pushed.output)
      check pushed.code == 0
      check recordsOnOrigin(further) == 3
