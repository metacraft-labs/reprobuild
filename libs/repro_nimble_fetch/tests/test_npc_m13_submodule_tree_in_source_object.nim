## NPC-M13 verification `test_npc_m13_submodule_tree_in_source_object`
## (spec § 6.1, "Submodule sources"; NPC-AREQ12).
##
## A package whose tag has a gitlink to a submodule, itself with a nested
## submodule (a relative URL), is offered. Its record carries the
## `submodules` list of both; its canonical archive holds their files under
## the gitlink paths and no gitlink or `.git` member; its `tree` equals the
## canonical hash of the composed tree, computed here from the content the
## test wrote; the solver offers the version; and a lock of it fetches from
## a directory mirror and installs that tree.
##
## Real repositories behind the TLS test listener, reached through the
## production egress policy. Falsifying mutation: composing the
## superproject's entries only leaves the submodule files out of the archive
## and the installed tree.

import std/[options, os, strutils, tempfiles, unittest]

import repro_domain_types/nimble_index
import repro_nimble_index

import ./fetch_fixtures
import ../../repro_nimble_generator/tests/submodule_fixtures

suite "NPC-M13: submodule trees are in the source object":
  test "nested submodules: the record lists both, the archive and tree hold them, a lock installs it":
    let mirrorDir = createTempDir("npc-m13-tree-mirror-", "")
    let f = newFixture("m13-tree")
    let work = createTempDir("npc-m13-tree-", "")
    let innerH = "int inner;\n"
    let (_, innerCommit) = f.served("nim/inner.git",
      @[file("inner.h", innerH)])
    let subGitmodules = gitmodules(@[("deep", "../inner.git")])
    let (_, subCommit) = f.served("nim/sub.git", @[file("sub.c",
      "int sub;\n"), subGitmodules, gitlinkTo("deep", innerCommit)])
    let pkgNimble = nimbleFile("withsub")
    let pkgGitmodules = gitmodules(@[("vendor/sub", f.url("nim/sub.git"))])
    let pkgSrc = "import os\n"
    let (_, pkgCommit) = f.served("nim/withsub.git", @[pkgNimble,
      file("src/withsub.nim", pkgSrc), pkgGitmodules,
      gitlinkTo("vendor/sub", subCommit)], tags = @["v1.0.0"])
    let reg = f.registryOf(@[("withsub", f.url("nim/withsub.git"))])
    let g = f.generation(reg, 1_790_000_000, work / "state",
      outputDir = work / "index", mirror = mirrorDir)
    checkpoint "diagnostics: " & g.diagnostics.join("\n")
    checkpoint "events: " & $g.events

    let rec = g.built.recordOf("withsub", "v1.0.0")
    require rec.isSome
    let r = rec.get
    check r.commit == pkgCommit
    check flGitlinks in r.flags
    check flUnreadable notin r.flags
    check r.submodules == @[
      RecordSubmodule(path: "vendor/sub", url: f.url("nim/sub.git"),
        commit: subCommit),
      RecordSubmodule(path: "vendor/sub/deep", url: f.url("nim/inner.git"),
        commit: innerCommit)]
    check g.goneOf("withsub").len == 0

    # The digest of the composed tree, computed from what was written.
    let expected = expectedTree(@[
      expectFile(pkgNimble.path, pkgNimble.content),
      expectFile("src/withsub.nim", pkgSrc),
      expectFile(".gitmodules", pkgGitmodules.content),
      expectFile("vendor/sub/sub.c", "int sub;\n"),
      expectFile("vendor/sub/.gitmodules", subGitmodules.content),
      expectFile("vendor/sub/deep/inner.h", innerH)])
    check $r.tree == expected

    # The canonical archive on the mirror: the submodule files are members
    # under their gitlink paths; no gitlink and no `.git`.
    let archivePath = mirrorDir / sourceObjectPath($r.tree)
    require fileExists(archivePath)
    let archive = readFile(archivePath)
    check int64(archive.len) == int64(r.size)
    let staged = work / "extracted"
    createDir(staged)
    discard extractArchive(archive, staged,
      ExtractOptions(limits: DefaultExtractLimits))
    check readFile(staged / "vendor/sub/sub.c") == "int sub;\n"
    check readFile(staged / "vendor/sub/deep/inner.h") == innerH
    check readFile(staged / "src/withsub.nim") == pkgSrc
    check not hasGitDir(staged)
    check treeDigestOf(staged) == expected

    # The solver offers it.
    check g.built.offeredTags("withsub") == @["v1.0.0"]
    check g.built.exclusionsOf("withsub", "v1.0.0").len == 0

    # A lock of it fetches from the directory mirror and installs that tree.
    var row = NimbleLockRow(name: "withsub", origin: f.url("nim/withsub.git"),
      commit: r.commit, tree: $r.tree,
      archiveSha256: toHexLower(r.archiveSha256), size: int64(r.size),
      submodules: r.submodules.len > 0)
    let fr = fetchLocked(@[row], f.fetchConfig(work / "client",
      @[parseMirror(mirrorDir)]).withNoOrigin())
    check fr.ok
    require fr.packages.len == 1
    let p = fr.packages[0]
    checkpoint "attempts: " & $p.attempts
    check p.state == psFetched
    check p.transport == tMirror
    check treeDigestOf(p.storePath) == expected
    check readFile(p.storePath / "vendor/sub/deep/inner.h") == innerH
    check not hasGitDir(p.storePath)
