## The manifest editor changes only the span it edits.
##
## Workspace manifests are authored by people: they carry comments, a key
## order someone chose, and blank lines that group related keys. Every `repro
## ws` verb that writes a manifest goes through `manifest_editor`, so if the
## editor re-serialized a file on every edit, the first `repos add` would
## delete every comment in the workspace's membership files and re-order every
## key.
##
## Each case below edits ONE key of a real file on disk and compares the
## written bytes against the original text with exactly that one span
## replaced. The primary assertion is byte equality of the whole file, so any
## re-serialization — dropped comment, moved key, collapsed blank line,
## changed line ending — fails it. The edited file is then read back through
## the strict reader, so "preserved" never means "preserved but unparseable".
##
## No mocks: real files in a temporary directory, the real reader.

import std/[options, os, strutils, tempfiles, unittest]

import repro_workspace_manifests

const handAuthoredFragment = """schema = "reprobuild.workspace.repo.v1"

# Vendored compiler fork. Do not move without telling the CI owners.
[repo]
path = "reprobuild/references/llvm-project"   # path first, by choice
name = "llvm-project"

# The fetch URL is <url_prefix>/<url_suffix>.
url_prefix = "github"
url_suffix = "llvm/llvm-project"

branch = "dev"  # the branch completed work lands on
tags = ["references", "hcr"]
"""

suite "manifest editor preserves unrelated text":

  test "t_manifest_editor_preserves_unrelated_text":
    let dir = createTempDir("repro-editor-preserve-", "")
    defer: removeDir(dir)
    let path = dir / "llvm-project.toml"
    writeFile(path, handAuthoredFragment)

    var doc = loadManifestDoc(path)
    check doc.setKey("repo", "branch", tomlStr("main"))
    doc.saveManifestDoc()

    # PRIMARY: every byte other than the edited value is unchanged — the
    # comments, the hand-chosen `path`-before-`name` order, the blank lines and
    # the trailing comment on the edited line itself.
    let expected = handAuthoredFragment.replace(
      "branch = \"dev\"  # the branch", "branch = \"main\"  # the branch")
    check readFile(path) == expected

    let parsed = readRepoFragment(path)
    check parsed.repo.branch == some("main")
    check parsed.repo.name == "llvm-project"
    check parsed.repo.tags == @["references", "hcr"]

  test "setting a key to the value it already has writes nothing":
    let dir = createTempDir("repro-editor-same-", "")
    defer: removeDir(dir)
    let path = dir / "llvm-project.toml"
    writeFile(path, handAuthoredFragment)
    var doc = loadManifestDoc(path)
    check not doc.setKey("repo", "url_prefix", tomlStr("github"))
    check not doc.changed
    doc.saveManifestDoc()
    check readFile(path) == handAuthoredFragment

  test "removing one key leaves every other line alone":
    let dir = createTempDir("repro-editor-remove-", "")
    defer: removeDir(dir)
    let path = dir / "llvm-project.toml"
    writeFile(path, handAuthoredFragment)
    var doc = loadManifestDoc(path)
    check doc.removeKey("repo", "tags")
    doc.saveManifestDoc()
    check readFile(path) == handAuthoredFragment.replace(
      "tags = [\"references\", \"hcr\"]\n", "")
    check readRepoFragment(path).repo.tags.len == 0

  test "a new key lands after the key it is asked to follow":
    let dir = createTempDir("repro-editor-insert-", "")
    defer: removeDir(dir)
    let path = dir / "llvm-project.toml"
    writeFile(path, handAuthoredFragment)
    var doc = loadManifestDoc(path)
    check doc.setKey("repo", "revision",
      tomlStr("07f6bc4883b2a0ee1f7f999b25774003b75f9bc1"), after = ["branch"])
    doc.saveManifestDoc()
    check readFile(path) == handAuthoredFragment.replace(
      "the branch completed work lands on\n",
      "the branch completed work lands on\n" &
      "revision = \"07f6bc4883b2a0ee1f7f999b25774003b75f9bc1\"\n")

  test "a CRLF file keeps its line endings":
    let dir = createTempDir("repro-editor-crlf-", "")
    defer: removeDir(dir)
    let path = dir / "llvm-project.toml"
    let crlf = handAuthoredFragment.replace("\n", "\r\n")
    writeFile(path, crlf)
    var doc = loadManifestDoc(path)
    check doc.setKey("repo", "branch", tomlStr("main"))
    check doc.addArrayMember("repo", "tags", "llvm")
    doc.saveManifestDoc()
    check readFile(path) == crlf
      .replace("branch = \"dev\"", "branch = \"main\"")
      .replace("[\"references\", \"hcr\"]", "[\"references\", \"hcr\", \"llvm\"]")
    check readRepoFragment(path).repo.tags == @["references", "hcr", "llvm"]
