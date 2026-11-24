## t_absence_observations -- a failed lookup of an absent path is an absence
## observation the certificate binds as `absent`; creating the file later
## invalidates the certificate. Covers the rule in Test-Certificates.md,
## "Absence observations", on a real temporary repository.

import std/[os, sets, unittest]

import repro_cli_support/absence_observations

const Root = "absence-observations-repo"

proc freshRepo(): string =
  let dir = getTempDir() / Root
  removeDir(dir)
  createDir(dir / "tests")
  result = dir

suite "absence observations":

  test "an absent in-repository lookup is bound as absent":
    let repo = freshRepo()
    let lookup = repo / "tests" / "nim.cfg"
    check bindableAbsences([lookup], repo, initHashSet[string]()) ==
      @["tests/nim.cfg"]

  test "creating the file afterwards invalidates the certificate":
    let repo = freshRepo()
    let bound = bindableAbsences([repo / "tests" / "nim.cfg"], repo,
      initHashSet[string]())
    check bound == @["tests/nim.cfg"]
    check absenceViolations(bound, repo).len == 0
    writeFile(repo / "tests" / "nim.cfg", "--path:src\n")
    check absenceViolations(bound, repo) == @["tests/nim.cfg"]

  test "a lookup of a path that exists is not an absence":
    let repo = freshRepo()
    writeFile(repo / "tests" / "present.nim", "")
    check bindableAbsences([repo / "tests" / "present.nim"], repo,
      initHashSet[string]()).len == 0

  test "a lookup outside the repository is not bound here":
    let repo = freshRepo()
    let outside = getTempDir() / "absence-observations-outside" / "nim.cfg"
    check bindableAbsences([outside], repo, initHashSet[string]()).len == 0

  test "a tracked path that is absent is a deletion, not an absence":
    let repo = freshRepo()
    let tracked = toHashSet(["tests/nim.cfg"])
    check bindableAbsences([repo / "tests" / "nim.cfg"], repo, tracked).len == 0

  test "repeated lookups bind once, in sorted order":
    let repo = freshRepo()
    let lookups = [repo / "tests" / "b.cfg", repo / "tests" / "a.cfg",
                   repo / "tests" / "b.cfg"]
    check bindableAbsences(lookups, repo, initHashSet[string]()) ==
      @["tests/a.cfg", "tests/b.cfg"]
