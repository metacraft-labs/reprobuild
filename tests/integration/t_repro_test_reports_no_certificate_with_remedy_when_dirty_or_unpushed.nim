## TC-1 / TC-8d — ``repro test`` withholds the certificate (with an ambient
## remedy) when a develop-mode SIBLING is not in a publishable state, and
## certifies a modified CURRENT repository by its content.
##
## Principle 2 (Interactive-UX): when the certificate is withheld the tests
## STILL RUN, the exit code is the run's, and the run ends with an actionable
## message naming the offender and the remedy.
##
## Cases (a committed-lock workspace: app → lib-b → lib-c):
##   1. The CURRENT repository is modified (a tracked edit and an untracked
##      scratch file): CERTIFIED. TC-8d inverted this case. Before it, a dirty
##      current repository was refused with "commit first"; the standard now
##      binds a certificate to the content of the tracked files (Standard
##      §3.2.2), so the modified tree is certified as its own content, with
##      ``untracked = true``.
##   2. A SIBLING (lib-b) has an uncommitted change: WITHHELD, naming lib-b
##      and a commit / stash remedy. Siblings are outside the content a
##      certificate names, so they must be clean — that half did not change.
##
## The unpushed-HEAD case of the current repository was removed on
## 2026-10-06: its publication IS the gated push (Agents-Push-Gate.md §4.1),
## so issuance exempts it. Every sibling must still be published. The
## positive case is "an unpushed clean current HEAD is certified before push"
## in t_repro_test_issues_certificate_by_default_in_clean_state.
##
## Falsifiability: issuing with a dirty sibling fails case 2's "no
## certificate"; restoring the clean-current-repository rule fails case 1.
##
## NO MOCKS: real repositories, the built ``repro``. Skip rule: ``git`` or
## ``ssh-keygen`` missing.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import ./certify_working_tree_fixture

suite "TC-1 — repro test withholds the certificate on a non-publishable state":

  test "t_repro_test_reports_no_certificate_with_remedy_when_dirty_or_unpushed":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs a certificate " &
        "in real repositories")
    else:
      # --- case 1: a modified CURRENT repository is certified ---------------
      block:
        var fx = setupCertifyFixture("tc1d-dirty-current")
        defer: removeDir(fx.sib.scratch)
        let app = fx.sib.app
        writeFile(app / "README.md", "uncommitted edit\n")
        writeFile(app / "scratch.txt", "uncommitted\n")
        let content = fx.workingTreeContentId(app)
        let res = fx.certify(fx.writeFixtureJson("t-unit", "exit 0"))
        checkpoint(res.output)
        check res.code == 0
        let certs = fx.issuedFor(content)
        check certs.len == 1
        if certs.len == 1:
          check certs[0].vcs.content == content
          check certs[0].vcs.base == fx.sib.headOf(app)
          check certs[0].vcs.untracked

      # --- case 2: a dirty SIBLING withholds, with a remedy ------------------
      block:
        var fx = setupCertifyFixture("tc1d-dirty-sibling")
        defer: removeDir(fx.sib.scratch)
        let libB = fx.sib.ws / "lib-b"
        writeFile(libB / "README.md", "uncommitted in a sibling\n")
        let res = fx.certify(fx.writeFixtureJson("t-unit", "exit 0"))
        checkpoint(res.output)
        # The trivial target still PASSES (the run executed), so the shard
        # exit code is 0 — the only effect of the dirty sibling is no cert.
        check res.code == 0
        check fx.runs == 1
        check not fx.anyCertificateIssued()
        check "no certificate" in res.output
        check "dirty" in res.output
        check "lib-b" in res.output
        # RA-28 remedy: name a concrete next step (commit / stash).
        check ("commit" in res.output or "stash" in res.output)
