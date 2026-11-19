## `repro catalog generate` and `repro catalog verify` (spec/CLI/catalog.md),
## measured through the verbs' own entry points, `runCatalogGenerateCommand`
## and `runCatalogVerifyCommand`, on a real index repository layout
## (`nimble-sources.toml` and `published-index/`) against local origins
## served over real HTTPS.
##
##   * `generate` writes `published-index/`; `verify` of it, from a state
##     directory of its own (so every origin is fetched again), exits 0 and
##     prints the root.
##   * An origin that changes between the two runs (a new tag) makes
##     `verify` exit 1 and print the difference by package and field.
##   * A second `generate` carries the first as its previous generation;
##     `verify` then needs `--previous`, refuses without it (exit 2), and
##     exits 0 with it.
##   * A tampered object of `published-index/` is a difference (exit 1),
##     although the root file is untouched and the repeat's root equals it:
##     what a reader fetches is the objects.
##
## The verbs are given the fixture's egress policy (its resolver and dialer
## reach the local listener); the command line always passes the default
## one. Falsifying mutations: `verifyIndex` reporting every repeat as
## verified exits 0 on the changed origin; comparing the roots alone exits 0
## on the tampered object.

import std/[os, posix, strutils, tempfiles, unittest]

import repro_nimble_index
import repro_cli_support/catalog_generate

import ./generator_fixtures

proc captured(body: proc(): int): tuple[code: int; output: string] =
  ## Run ``body`` with this process's stdout sent to a file; its exit code
  ## and what it printed.
  let dir = createTempDir("npc-m4-verb-out-", "")
  let path = dir / "stdout"
  flushFile(stdout)
  let saved = dup(1)
  let f = open(path, fmWrite)
  discard dup2(getFileHandle(f), 1)
  try:
    result.code = body()
  finally:
    flushFile(stdout)
    discard dup2(saved, 1)
    discard close(saved)
    f.close()
  result.output = readFile(path)

suite "repro catalog generate and verify":

  test "generate, verify, a changed origin, a previous generation, a tampered object":
    let f = newFixture("verbs")
    let alpha = f.newRepo("nim/alpha.git")
    discard alpha.commit(@[nimbleFile("alpha", @["beta >= 1.0.0"]),
      file("src/alpha.nim", "discard\n")])
    alpha.tag("v1.0.0")
    alpha.publish()
    let beta = f.newRepo("nim/beta.git")
    discard beta.commit(@[nimbleFile("beta"), file("src/beta.nim",
      "discard\n")])
    beta.tag("1.0.0")
    beta.publish()
    let reg = f.newRepo("nim-lang/packages.git")
    let regCommit = reg.commit(@[packagesJson(@[
      ("alpha", f.url("nim/alpha.git")), ("beta", f.url("nim/beta.git"))])])
    reg.publish()
    let policy = f.testPolicy()

    let work = createTempDir("npc-m4-verbs-run-", "")
    let repo = work / "index-repo"
    createDir(repo)
    writeFile(repo / "nimble-sources.toml",
      sourceSetText(f.url("nim-lang/packages.git"), regCommit))

    # generate writes published-index/.
    let gen = captured(proc(): int =
      runCatalogGenerateCommand(repo, "", work / "state-a", "1790000000",
        policy))
    checkpoint gen.output
    check gen.code == 0
    check fileExists(repo / "published-index" / "root")
    check "packages=2" in gen.output
    let generatedRoot = indexDirRootId(repo / "published-index")

    # verify repeats it from nothing (its own state directory): equal roots.
    let ok = captured(proc(): int =
      runCatalogVerifyCommand(repo, "", "", work / "state-v1", policy))
    checkpoint ok.output
    check ok.code == 0
    check ("verified: root blake3:" & $generatedRoot) in ok.output

    # An origin changes between the runs: verify reports it and exits 1.
    discard alpha.commit(@[nimbleFile("alpha", @["beta >= 1.0.0"]),
      file("src/alpha.nim", "echo 2\n")], date = 1_700_100_000)
    alpha.tag("v2.0.0")
    alpha.publish()
    let differs = captured(proc(): int =
      runCatalogVerifyCommand(repo / "published-index", "", "",
        work / "state-v2", policy))
    checkpoint differs.output
    check differs.code == 1
    check "differs: published blake3:" & $generatedRoot in differs.output
    check "alpha origin tag v2.0.0: published \"absent\"" in differs.output
    check "alpha version tag v2.0.0" in differs.output

    # A second generation names the first as its previous generation.
    let gen1Copy = work / "gen1"
    copyDir(repo / "published-index", gen1Copy / "published-index")
    let gen2 = captured(proc(): int =
      runCatalogGenerateCommand(repo, "", work / "state-a", "1790086400",
        policy))
    checkpoint gen2.output
    check gen2.code == 0
    check "events=0" in gen2.output
    let noPrevious = captured(proc(): int =
      runCatalogVerifyCommand(repo, "", "", work / "state-v3", policy))
    check noPrevious.code == 2
    let withPrevious = captured(proc(): int =
      runCatalogVerifyCommand(repo, "", gen1Copy, work / "state-v3", policy))
    checkpoint withPrevious.output
    check withPrevious.code == 0
    check "verified: root blake3:" in withPrevious.output

    # A tampered object: the root file is untouched, the repeat's root
    # equals it, and the directory is still not the index.
    # Not the root object: that one the reader checks against the root file
    # before it compares anything (exit 2).
    let currentRoot = $indexDirRootId(repo / "published-index")
    var tampered = ""
    for kind, p in walkDir(repo / "published-index" / "objects"):
      if kind == pcFile and tampered.len == 0 and
          extractFilename(p) != currentRoot:
        tampered = p
    check tampered.len > 0
    var bytes = readFile(tampered)
    bytes[bytes.len div 2] = char(ord(bytes[bytes.len div 2]) xor 0x01)
    writeFile(tampered, bytes)
    let bad = captured(proc(): int =
      runCatalogVerifyCommand(repo, "", gen1Copy, work / "state-v4", policy))
    checkpoint bad.output
    check bad.code == 1
    check ("object " & extractFilename(tampered) & ": published \"blake3:") in
      bad.output
    check "verified" notin bad.output
