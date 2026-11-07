## A membership edit lands in the array it NAMES, never in its neighbour.
##
## A repo-set (and a converted project) declares membership in two arrays,
## `member_sets` and `member_repos`, and they are two NAMESPACES: in the
## metacraft manifest repo 7 of 11 projects have a set and a repo with the same
## name, so `"codetracer"` in the wrong array silently means a different thing.
## The line-scanning helper this editor replaced documented the hazard — it
## had to find an array by its key rather than by "the next lone `]`" — and the
## include helper next to it got it wrong (it put an `includes` path inside
## `member_sets`).
##
## Every case adds and removes members through the editor on a real file, then
## reads the file back through the strict reader and asserts BOTH arrays: the
## named one changed, the other one did not. The fixtures carry the same name
## in both arrays and put the arrays in both orders, so an editor that picked
## "the first array" or "the array containing the name" fails one of them.
##
## No mocks: real files in a temporary directory, the real reader.

import std/[os, strutils, tempfiles, unittest]

import repro_workspace_manifests

proc fixture(dir, name, body: string): string =
  result = dir / (name & ".toml")
  writeFile(result, body)

const setsFirst = """schema = "reprobuild.workspace.repo-set.v1"

# Sets this one pulls in.
member_sets = [
  "codetracer",
  "shared-infrastructure",
]

# Repos, by name. `codetracer` is BOTH a set and a repo.
member_repos = [
  "codetracer",  # the repo, not the set
  "io-mon",
]

[repo-set]
name = "codetracer"
"""

const reposFirst = """schema = "reprobuild.workspace.repo-set.v1"

member_repos = ["codetracer", "io-mon"]
member_sets = ["codetracer", "shared-infrastructure"]

[repo-set]
name = "codetracer"
"""

const legacyStubLayout = """schema = "reprobuild.workspace.repo-set.v1"

[repo-set]
name = "codetracer"

member_sets = [
  "codetracer",
]

member_repos = [
  "codetracer",
]
"""

suite "manifest editor member edits target the named array":

  test "t_manifest_editor_member_edits_target_the_named_array":
    let dir = createTempDir("repro-editor-members-", "")
    defer: removeDir(dir)
    for (label, body) in [("sets-first", setsFirst),
                          ("repos-first", reposFirst)]:
      checkpoint(label)
      let path = fixture(dir, label, body)

      # Gain a member in each namespace.
      check addArrayMemberInFile(path, "", "member_repos", "nim-pty")
      var m = readRepoSet(path)
      check m.member_repos == @["codetracer", "io-mon", "nim-pty"]
      check m.member_sets == @["codetracer", "shared-infrastructure"]

      check addArrayMemberInFile(path, "", "member_sets", "isonim")
      m = readRepoSet(path)
      check m.member_sets == @["codetracer", "shared-infrastructure", "isonim"]
      check m.member_repos == @["codetracer", "io-mon", "nim-pty"]

      # Lose the name both arrays carry — from the named array only.
      check removeArrayMemberInFile(path, "", "member_repos", "codetracer")
      m = readRepoSet(path)
      check m.member_repos == @["io-mon", "nim-pty"]
      check m.member_sets == @["codetracer", "shared-infrastructure", "isonim"]

      check removeArrayMemberInFile(path, "", "member_sets", "codetracer")
      m = readRepoSet(path)
      check m.member_sets == @["shared-infrastructure", "isonim"]
      check m.member_repos == @["io-mon", "nim-pty"]

      # A name present only in the OTHER array is not removed from it.
      check not removeArrayMemberInFile(path, "", "member_repos", "isonim")
      m = readRepoSet(path)
      check m.member_sets == @["shared-infrastructure", "isonim"]

  test "the arrays of a set written by the pre-editor stub are found in place":
    # `sets add` used to write the arrays BELOW `[repo-set]`, a layout the
    # pinned reader accepts for repo-sets. An edit must extend those arrays,
    # not declare a second `member_repos` at the top of the file.
    let dir = createTempDir("repro-editor-legacy-", "")
    defer: removeDir(dir)
    let path = fixture(dir, "legacy", legacyStubLayout)
    check addArrayMemberInFile(path, "", "member_repos", "io-mon")
    check removeArrayMemberInFile(path, "", "member_sets", "codetracer")
    let m = readRepoSet(path)
    check m.member_repos == @["codetracer", "io-mon"]
    check m.member_sets.len == 0
    check readFile(path) == legacyStubLayout
      .replace("member_repos = [\n  \"codetracer\",\n]",
               "member_repos = [\n  \"codetracer\",\n  \"io-mon\",\n]")
      .replace("member_sets = [\n  \"codetracer\",\n]", "member_sets = [\n]")

  test "a project's includes and membership arrays are distinct targets":
    let dir = createTempDir("repro-editor-project-", "")
    defer: removeDir(dir)
    let path = fixture(dir, "half-converted", """schema = "reprobuild.workspace.project.v1"

includes = [
  "repos/codetracer.toml",
]

member_sets = [
]

[project]
name = "half-converted"
""")
    var doc = loadManifestDoc(path)
    check doc.appendInclude("repos/io-mon.toml")
    check doc.addArrayMember("", "member_repos", "nim-pty")
    doc.saveManifestDoc()
    let m = readProjectManifest(path)
    check m.includes == @["repos/codetracer.toml", "repos/io-mon.toml"]
    check m.member_sets.len == 0
    check m.member_repos == @["nim-pty"]
    check m.project.name == "half-converted"
