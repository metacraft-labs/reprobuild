## TC-8a — content ids reproduce the standard's ``vectors/content/`` suite.
##
## Every id in every ``vectors/content/<case>/expected.json`` (seven cases:
## ``git-tree-sha1``, ``git-tree-sha256`` and ``manifest-v1-sha256``,
## whole-repository and scoped) is computed from that case's
## ``entries.json`` and compared as a string. The ``git-tree-*`` ids are
## derived three ways, which must all agree with the vector:
##
##   1. without git: ``gitTreeIdOfEntries`` hashes blob and tree objects
##      directly;
##   2. through git, as the vectors README re-derives them: the entries are
##      staged into a scratch repository of the matching object format with
##      ``update-index --index-info``, and ``computeContentId`` reads the
##      index being committed, then the commit made from it;
##   3. through git from a WORKING TREE: the entries are written out as real
##      files, executable files and symbolic links, and ``computeContentId``
##      runs the temporary-index recipe over them.
##
## ``manifest-v1-sha256`` ids are computed from the entries and, again, from
## the committed scratch repository.
##
## Which revision of the suite
## ---------------------------
## The suite is read at the revision pinned in
## ``content_id/test-certificates-spec-content-vectors.pin``, extracted with
## ``git archive`` from the object store of the workspace's
## ``test-certificates-spec`` sibling (or ``$TEST_CERTIFICATES_SPEC``), never
## from its checkout. A checkout moves; a pin moves only in the change that
## teaches this implementation what the new revision says. A missing sibling,
## or one whose object store lacks the pinned revision, FAILS this test naming
## what to fetch. It does not skip: a conformance test that quietly stops
## running has stopped testing anything.
##
## A second case runs the scoping rules against a live repository: literal
## pathspecs (a scope named ``*``, ``?``, ``[ab]`` or ``:x`` names that file),
## ``src/db`` not taking in ``src/dbx``, and a scoped id that keeps full
## paths, so it is not the subtree ``T:src/db``.

import std/[base64, json, os, sets, strutils, unittest]

import repro_cli_support/content_id
import content_id_fixture
import spec_vectors_pin

proc extractVectors(scratch: string): tuple[root: string; error: string] =
  ## ``vectors/`` at the pinned revision, unpacked into ``scratch``; the pin
  ## and the extraction are shared with the conformance walker
  ## (``spec_vectors_pin``), so both read the suite at one revision.
  let extracted = extractPinnedVectors(scratch)
  if extracted.error.len > 0:
    return ("", extracted.error)
  echo "  content vectors: test-certificates-spec ", extracted.pin, " (",
    extracted.sibling, ")"
  (extracted.root, "")

proc entriesOf(path: string): seq[ContentEntry] =
  for node in parseFile(path):
    result.add ContentEntry(path: node["path"].getStr(),
                            mode: node["mode"].getStr(),
                            content: decode(node["content_b64"].getStr()))

proc scopeOf(node: JsonNode): seq[string] =
  if node.kind == JArray:
    for item in node: result.add item.getStr()

suite "content ids against the conformance vectors":

  test "t_content_id_vectors_match_the_conformance_suite":
    let scratch = enterHermeticGit()
    let (root, error) = extractVectors(scratch)
    if error.len > 0:
      checkpoint(error)
      fail()
    else:
      # Every case index.json lists is walked, and nothing else is.
      let index = parseFile(root / "index.json")
      var listed: HashSet[string]
      for case0 in index["groups"]["content"]:
        listed.incl case0["name"].getStr()
      var walked: HashSet[string]
      for kind, path in walkDir(root / "content"):
        if kind == pcDir and fileExists(path / "pins.md"):
          walked.incl path.extractFilename
      check walked == listed
      check walked.len == 7

      var checkedIds = 0
      var formatsSeen: HashSet[string]
      for name in walked:
        let dir = root / "content" / name
        let entries = entriesOf(dir / "entries.json")
        var repos: array[ContentAlgorithm, string]
        for expectedNode in parseFile(dir / "expected.json"):
          let algorithmName = expectedNode["algorithm"].getStr()
          let scope = scopeOf(expectedNode["paths"])
          let expected = expectedNode["id"].getStr()
          let (known, algorithm) = lookupContentAlgorithm(algorithmName)
          checkpoint(name & ": " & algorithmName & " " & $scope)
          check known
          check parseContentId(expected).form == cifWellFormed
          formatsSeen.incl algorithmName

          # Derivation 1: from the entries alone.
          let direct =
            if algorithm == caManifestV1Sha256: manifestV1Sha256(entries, scope)
            else: gitTreeIdOfEntries(entries, algorithm, scope)
          check direct.outcome == cioComputed
          check direct.id == expected

          # Derivation 2: a scratch repository of the matching object format.
          let gitFormat = (if algorithm == caGitTreeSha256: caGitTreeSha256
                           else: caGitTreeSha1)
          if repos[gitFormat].len == 0:
            let repo = newRepo(scratch, name & "-" & $gitFormat,
              (if gitFormat == caGitTreeSha256: "sha256" else: "sha1"))
            stageEntries(repo, entries)
            repos[gitFormat] = repo
          let repo = repos[gitFormat]
          let staged = computeContentId(repo, indexState(), algorithm, scope)
          checkpoint(staged.reason)
          check staged.outcome == cioComputed
          check staged.id == expected

          # Derivation 3: real files in a working tree.
          let worktree = scratch / (name & "-" & $gitFormat & "-worktree")
          if not dirExists(worktree):
            discard newRepo(scratch, worktree.extractFilename,
              (if gitFormat == caGitTreeSha256: "sha256" else: "sha1"))
            materialiseEntries(worktree, entries)
          let fromFiles = computeContentId(worktree, workingTreeState(),
                                           algorithm, scope)
          checkpoint(fromFiles.reason)
          check fromFiles.outcome == cioComputed
          check fromFiles.id == expected
          inc checkedIds

        # The committed state, in every format this case used.
        for format, repo in repos:
          if repo.len == 0: continue
          discard git(repo, "commit", "-q", "-m", "vector " & name)
          for expectedNode in parseFile(dir / "expected.json"):
            let (_, algorithm) = lookupContentAlgorithm(
              expectedNode["algorithm"].getStr())
            if algorithm != caManifestV1Sha256 and algorithm != format:
              continue
            let scope = scopeOf(expectedNode["paths"])
            let committed = computeContentId(repo, commitState("HEAD"),
                                             algorithm, scope)
            checkpoint(name & " committed: " & committed.reason)
            check committed.id == expectedNode["id"].getStr()

      # Both git object formats and the manifest were exercised, and every
      # listed id was reproduced.
      check formatsSeen == toHashSet(["git-tree-sha1", "git-tree-sha256",
                                      "manifest-v1-sha256"])
      # 29 ids across the seven cases at the pinned revision.
      check checkedIds == 29
      check libraryTempLeftovers(scratch).len == 0
    removeDir(scratch)

  test "scoped ids of a live repository use literal paths and keep full paths":
    let scratch = enterHermeticGit()
    let entries = @[
      ContentEntry(path: "src/db/schema.sql", mode: "100644", content: "t\n"),
      ContentEntry(path: "lib/db/schema.sql", mode: "100644", content: "t\n"),
      ContentEntry(path: "src/dbx/extra.c", mode: "100644", content: "x\n"),
      ContentEntry(path: "glob/*", mode: "100644", content: "star\n"),
      ContentEntry(path: "glob/a", mode: "100644", content: "a\n"),
      ContentEntry(path: "glob/?", mode: "100644", content: "question\n"),
      ContentEntry(path: "glob/b", mode: "100644", content: "b\n"),
      ContentEntry(path: "glob/[ab]", mode: "100644", content: "class\n"),
      ContentEntry(path: ":top", mode: "100644", content: "colon\n"),
      ContentEntry(path: "README.md", mode: "100644", content: "r\n")]
    let repo = newRepo(scratch, "scoped")
    materialiseEntries(repo, entries)
    discard git(repo, "commit", "-q", "-m", "scoped")
    let whole = gitLine(repo, "rev-parse", "HEAD^{tree}")
    for scope in [@["glob/*"], @["glob/?"], @["glob/[ab]"], @[":top"],
                  @["src/db"], @["lib/db"], @["src/d"], @["README.md", "src/db"],
                  @["glob"], @["missing"]]:
      checkpoint($scope)
      let expected = gitTreeIdOfEntries(entries, caGitTreeSha1, scope)
      check expected.outcome == cioComputed
      for state in [workingTreeState(), indexState(), commitState("HEAD")]:
        let got = computeContentId(repo, state, caGitTreeSha1, scope)
        checkpoint($state.kind & ": " & got.reason)
        check got.id == expected.id
      let manifest = computeContentId(repo, commitState("HEAD"),
                                      caManifestV1Sha256, scope)
      check manifest.id == manifestV1Sha256(entries, scope).id
    # A glob would have taken `glob/a` and `glob/b` too.
    check computeContentId(repo, workingTreeState(), caGitTreeSha1,
                           ["glob/*"]).id !=
          computeContentId(repo, workingTreeState(), caGitTreeSha1,
                           ["glob"]).id
    # `src/db` and `lib/db` hold identical files: the same subtree object,
    # different scoped ids, neither of them that subtree.
    let srcSubtree = gitLine(repo, "rev-parse", "HEAD:src/db")
    check srcSubtree == gitLine(repo, "rev-parse", "HEAD:lib/db")
    let srcScoped = computeContentId(repo, commitState("HEAD"), caGitTreeSha1,
                                     ["src/db"]).id
    let libScoped = computeContentId(repo, commitState("HEAD"), caGitTreeSha1,
                                     ["lib/db"]).id
    check srcScoped != libScoped
    check srcScoped != "git-tree-sha1:" & srcSubtree
    check computeContentId(repo, commitState("HEAD"), caGitTreeSha1, []).id ==
      "git-tree-sha1:" & whole
    check computeContentId(repo, commitState("HEAD"), caGitTreeSha1,
                           ["src/d"]).id == emptyTree(caGitTreeSha1)

    # A commit's id needs no working tree: the same scoped ids in a bare clone.
    let bare = scratch / "bare.git"
    discard git(scratch, "clone", "-q", "--bare", repo, bare)
    check computeContentId(bare, commitState("HEAD"), caGitTreeSha1,
                           ["src/db"]).id == srcScoped
    check computeContentId(bare, commitState("HEAD"), caManifestV1Sha256,
                           ["glob/*"]).id ==
      manifestV1Sha256(entries, ["glob/*"]).id
    check libraryTempLeftovers(scratch).len == 0
    removeDir(scratch)
