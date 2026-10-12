## TC-8d — the first commit of a repository is certifiable (test-certificates
## Standard §3.2.3): on an UNBORN branch there is no HEAD, so the certificate
## omits ``base``, names the content of the files staged for the first commit,
## and covers that commit once it is made.
##
## ``app`` is re-created as a fresh ``git init`` with its files staged and a
## ``repro.lock`` written by ``repro lock refresh`` and staged too — nothing
## committed. ``repro test --certify`` issues; the record carries no ``base``
## key at all (never an empty one). ``git commit`` then makes the first
## commit, whose tree is that content, and the production verifier reports it
## covered.
##
## Falsifiability: requiring a HEAD commit (the pre-TC-8d rule) issues
## nothing here.
##
## NO MOCKS: real repositories, the built ``repro``. Skip rule: ``git`` or
## ``ssh-keygen`` missing.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import ./certify_working_tree_fixture

suite "TC-8d — the first commit is certifiable":

  test "t_first_commit_of_a_repository_is_certifiable":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs a certificate " &
        "in real repositories")
    else:
      var fx = setupCertifyFixture("tc8d-first-commit")
      defer: removeDir(fx.sib.scratch)
      let app = fx.sib.app
      # Re-create app with the same files and no history.
      let solver = readFile(app / "repro.solver")
      removeDir(app)
      discard runCmd(q(fx.sib.gitBin) & " init -q -b main " & q(app))
      discard fx.gitIn(app, "config user.email tester@example.invalid")
      discard fx.gitIn(app, "config user.name \"Lock Tester\"")
      discard fx.gitIn(app, "config commit.gpgsign false")
      writeFile(app / "README.md", "app, before its first commit\n")
      writeFile(app / "repro.solver", solver)
      writeFile(app / ".gitignore", ".repro/\n")
      let locked = runCmd(q(fx.sib.repro) & " lock refresh " & q(app))
      checkpoint(locked.output)
      check locked.code == 0
      discard fx.gitIn(app, "add -A")
      check runCmd(q(fx.sib.gitBin) & " -C " & q(app) &
        " rev-parse --verify -q HEAD").code != 0          # unborn
      let content = fx.workingTreeContentId(app)

      let fixtureJson = fx.writeFixtureJson("t-unit", "exit 0")
      let res = fx.certify(fixtureJson)
      checkpoint(res.output)
      check res.code == 0
      let certs = fx.issuedFor(content)
      check certs.len == 1
      if certs.len == 1:
        let cert = certs[0]
        check cert.vcs.content == content
        check cert.vcs.base == ""
        check "base = " notin serializeCertificateToToml(cert)
        check not cert.vcs.untracked
        check cert.isSigned

      discard fx.gitIn(app, "commit -q -m first")
      let first = fx.sib.headOf(app)
      check runCmd(q(fx.sib.gitBin) & " -C " & q(app) &
        " rev-parse --verify -q " & first & "^").code != 0  # a root commit
      check treeContentId(fx.sib.gitBin, app, first) == content
      let verdict = fx.coverageAt(app, first, "t-unit")
      checkpoint("untrusted=" & $verdict.untrusted & " unevaluated=" &
        $verdict.unevaluated)
      check verdict.outcome == voCovered
