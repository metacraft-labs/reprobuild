## t_absence_is_accepted_by_the_judge -- the untracked-input judge accepts a read
## whose path is absent on disk at test time (an absence observation,
## Test-Certificates.md "Absence observations") and still refuses a read of a
## path that is present. The judge is a pure function over the read set, so the
## test drives it with a real temporary repository and no certificate machinery.

import std/[os, sets, unittest]

import repro_cli_support
# The untracked-inputs mode enum (cuiReadSet, cuiStrict) is declared in the
# manifests package, which repro_cli_support does not re-export.
import repro_workspace_manifests

const Root = "judge-absence-repo"

proc freshRepo(): string =
  result = getTempDir() / Root
  removeDir(result)
  createDir(result / "tests")

proc readSetOf(path: string): CapturedReadSet =
  CapturedReadSet(captured: true, source: "test", paths: @[path])

suite "the judge accepts absence observations":

  test "a read of an absent in-repository path is accepted":
    let repo = freshRepo()
    let absent = repo / "tests" / "nim.cfg"
    let judgement = judgeUntrackedInputs(cuiReadSet, repo, [],
      initHashSet[string](), readSetOf(absent))
    check not judgement.withhold
    check judgement.read.len == 0

  test "a read of a present untracked in-repository path is refused":
    let repo = freshRepo()
    let present = repo / "tests" / "present.cfg"
    writeFile(present, "--path:src\n")
    let judgement = judgeUntrackedInputs(cuiReadSet, repo, [],
      initHashSet[string](), readSetOf(present))
    check judgement.withhold
    check judgement.read == @["tests/present.cfg"]
