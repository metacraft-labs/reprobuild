## A committed `repro.lock` entry for a repository records the repository's
## canonical fetch URL, never the spelling of the local clone's remote
## (Unified-Locking-And-Hooks.md §14.2, "The `url` a pin records").
##
## WHY. `repro lock refresh` recorded each sibling's `origin` exactly as
## `git remote get-url origin` printed it. A workspace whose siblings were
## cloned over SSH therefore wrote `url = "git@github.com:<org>/<repo>.git"`
## into the lock of a public repository, where a workspace cloned over HTTPS
## wrote `url = "https://github.com/<org>/<repo>"` for the same repository at
## the same commit. The SSH spelling cannot be fetched anonymously, it tells
## readers how one operator's machine is set up, and the two workspaces kept
## rewriting each other's lines. An HTTPS remote with userinfo
## (`https://user:token@host/…`) was copied verbatim the same way, which puts
## a credential into a committed file.
##
## Fixture: `committed_lock_siblings_fixture.nim`, a real manifest workspace
## (app → lib-b → lib-c) of real git repositories cloned from real bare
## origins and refreshed with the built `repro`. The case then re-points every
## repository's `origin` at one network spelling after another and refreshes
## after each. Nothing is fetched afterwards, so the URLs need not resolve;
## the pinned commits, the remote-tracking refs and the manifests stay exactly
## as they were, and the remote's spelling is the one thing that varies.
##
## Cases (one test, one sequence):
##   * HTTPS spelling: every entry records `https://example.invalid/acme/<r>`;
##   * scp-like SSH (`git@host:o/r.git`), `ssh://` with the default port,
##     scp-like SSH with no user, and an HTTPS URL carrying userinfo, a
##     trailing `.git/` and an upper-case host each leave the lock
##     BYTE-IDENTICAL to the HTTPS refresh;
##   * the userinfo never reaches the lock.
##
## A second test covers the other writer of sibling entries, the managed
## `pre-commit` re-pin (§13.3): with every origin re-pointed at scp-like SSH,
##   * a commit after lib-b moved re-pins lib-b and records its URL in the
##     canonical HTTPS form, leaving every other entry's bytes alone;
##   * a lock committed with a non-canonical `url` for lib-c (an older
##     writer's SSH spelling) has it rewritten to the canonical form by the
##     re-pin of that very commit, with no revision moved.
## Its hook is written by hand with the managed body's dispatch line, naming
## the built binary, as `t_commit_repins_committed_lock_siblings` does.
##
## Mutation: write the remote as `git remote get-url` spells it instead of
## `canonicalLockFetchUrl(...)` (the behaviour before the fix) ⇒ RED at the
## first SSH spelling in both tests, where the lock records
## `git@example.invalid:acme/lib-b.git`.
##
## NO MOCKS: the remotes are real git configuration read by the real `git`,
## the lock is written by the real `repro lock refresh` and by a real
## `git commit` running the real hook dispatch.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_test_support
import ./committed_lock_siblings_fixture

const AllowEnv = "REPRO_ALLOW_PIN_REGRESSION"

proc refresh(fx: SiblingFixture; target: string):
    tuple[code: int; output: string] =
  ## `repro lock refresh <target>`, with `REPRO_ALLOW_PIN_REGRESSION` cleared
  ## so a value exported in the suite's environment cannot leak in.
  runCmd(AllowEnv & "= " & q(fx.repro) & " lock refresh " & q(target) &
    " 2>&1")

proc pointOrigins(fx: SiblingFixture; spell: proc (repo: string): string) =
  ## Re-point the `origin` of app, lib-b and lib-c at `spell(<repo>)`.
  for name in ["app", "lib-b", "lib-c"]:
    discard fx.git(fx.ws / name, "remote set-url origin " & q(spell(name)))
    check fx.git(fx.ws / name, "remote get-url origin").strip() == spell(name)

proc installPreCommit(fx: SiblingFixture) =
  ## The managed `pre-commit` body's dispatch line, naming the built binary so
  ## a dev-shell `repro` on PATH cannot stand in for the one under test.
  let hook = fx.app / ".git" / "hooks" / "pre-commit"
  createDir(hook.parentDir)
  writeFile(hook,
    "#!/usr/bin/env sh\nset -eu\n" &
    "REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)\n" &
    "cd \"$REPO_ROOT\"\nREPRO_STATUS=0\n" &
    q(fx.repro) & " hooks dispatch pre-commit --repo-root \"$REPO_ROOT\" " &
      "-- \"$@\" || REPRO_STATUS=$?\nexit $REPRO_STATUS\n")
  var perms = getFilePermissions(hook)
  perms.incl({fpUserExec, fpGroupExec, fpOthersExec})
  setFilePermissions(hook, perms)

proc commitInApp(fx: SiblingFixture; label: string):
    tuple[code: int; output: string] =
  writeFile(fx.app / (label & ".txt"), label & "\n")
  discard fx.git(fx.app, "add " & q(label & ".txt"))
  runCmd(q(fx.gitBin) & " -C " & q(fx.app) & " commit -m " & q(label) &
    " 2>&1")

suite "a sibling's clone transport does not change its lock entry":

  test "SSH, scp-like and credentialed origins write the bytes the " &
      "canonical HTTPS origin writes":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      delEnv("REPRO_WORKSPACE_CONFIG")
      let fx = setupSiblingFixture("clone-transport")
      defer: removeDir(fx.scratch)

      fx.pointOrigins(proc (r: string): string =
        "https://example.invalid/acme/" & r)
      var res = fx.refresh(fx.app)
      checkpoint("refresh with HTTPS origins:\n" & res.output)
      check res.code == 0
      let canonical = readFile(fx.app / "repro.lock")
      checkpoint("lock with HTTPS origins:\n" & canonical)
      for name in [".", "lib-b", "lib-c"]:
        let repo = if name == ".": "app" else: name
        check ("url = \"https://example.invalid/acme/" & repo & "\"") in
          depEntry(canonical, name)

      let spellings: seq[(string, proc (r: string): string)] = @[
        ("scp-like SSH", proc (r: string): string =
          "git@example.invalid:acme/" & r & ".git"),
        ("ssh:// with the default port", proc (r: string): string =
          "ssh://git@example.invalid:22/acme/" & r & ".git"),
        ("scp-like SSH without a user", proc (r: string): string =
          "example.invalid:acme/" & r),
        ("HTTPS with userinfo", proc (r: string): string =
          "https://alice:s3cret-token@EXAMPLE.invalid/acme/" & r & ".git/")]
      for (label, spell) in spellings:
        fx.pointOrigins(spell)
        res = fx.refresh(fx.app)
        checkpoint("refresh with " & label & " origins:\n" & res.output)
        check res.code == 0
        let body = readFile(fx.app / "repro.lock")
        if body != canonical:
          checkpoint("lock with " & label & " origins:\n" & body)
        # THE PROPERTY: one repository at one commit is one set of bytes,
        # whatever transport the local clone uses.
        check body == canonical
        check "git@" notin body
        check "s3cret-token" notin body
        check "alice" notin body

  test "the pre-commit re-pin writes the canonical URL whatever the " &
      "clone's transport":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      delEnv("REPRO_WORKSPACE_CONFIG")
      let fx = setupSiblingFixture("clone-transport-repin")
      defer: removeDir(fx.scratch)

      let https = proc (r: string): string =
        "https://example.invalid/acme/" & r
      fx.pointOrigins(https)
      let res = fx.refresh(fx.app)
      checkpoint("refresh with HTTPS origins:\n" & res.output)
      check res.code == 0
      discard fx.git(fx.app, "add repro.lock")
      discard fx.git(fx.app, "commit -q -m lock")
      let before = readFile(fx.app / "repro.lock")
      fx.installPreCommit()
      fx.pointOrigins(proc (r: string): string =
        "git@example.invalid:acme/" & r & ".git")

      # 1. lib-b moves (a local commit: the SSH origin does not resolve, and
      # the pre-commit re-pin reads the checkout, not the remote).
      writeFile(fx.ws / "lib-b" / "change.txt", "moved\n")
      discard fx.git(fx.ws / "lib-b", "add change.txt")
      discard fx.git(fx.ws / "lib-b", "commit -q -m moved")
      let libBNext = fx.headOf(fx.ws / "lib-b")
      let c1 = fx.commitInApp("after-lib-b")
      checkpoint("commit after lib-b moved:\n" & c1.output)
      check c1.code == 0
      let repinned = fx.git(fx.app, "show HEAD:repro.lock")
      checkpoint("lock after the re-pin:\n" & repinned)
      let libB = depEntry(repinned, "lib-b")
      check ("revision = \"" & libBNext & "\"") in libB
      check "url = \"https://example.invalid/acme/lib-b\"" in libB
      check depEntry(repinned, "lib-c") == depEntry(before, "lib-c")
      check depEntry(repinned, ".") == depEntry(before, ".")
      check "git@" notin repinned

      # 2. A lock committed with an older writer's SSH spelling for lib-c:
      # the re-pin of that commit writes the canonical URL and moves no pin.
      let libCBefore = depEntry(repinned, "lib-c")
      check libCBefore.len > 0
      let libCSsh = libCBefore.replace(
        "url = \"https://example.invalid/acme/lib-c\"",
        "url = \"git@example.invalid:acme/lib-c.git\"")
      check libCSsh != libCBefore
      writeFile(fx.app / "repro.lock",
        repinned.replace(libCBefore, libCSsh))
      discard fx.git(fx.app, "add repro.lock")
      let c2 = fx.commitInApp("ssh-url-in-lock")
      checkpoint("commit of a lock carrying an SSH url:\n" & c2.output)
      check c2.code == 0
      let repaired = fx.git(fx.app, "show HEAD:repro.lock")
      checkpoint("lock after the second commit:\n" & repaired)
      check repaired == repinned
      check fx.git(fx.app, "status --porcelain").strip().len == 0
