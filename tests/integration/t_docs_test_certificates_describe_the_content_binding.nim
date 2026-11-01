## The user guide for test certificates exists and describes what ships: the
## content binding, the pre-commit gate, the store, propagation and ``repro
## push``. It must not bring back the commit-bound workflow the standard's
## content binding removed.
##
## A pure documentation-content test, in the shape of
## ``t_docs_hooks_reflect_public_tier_only_server_gate``: it reads the file and
## asserts on stable phrases. It builds nothing and drives no binary.
##
## It also guards the two things a public guide must not carry: a private
## repository's name, and a private plan's milestone id.

import std/[os, strutils, unittest]

let guidePath = currentSourcePath().parentDir.parentDir.parentDir /
  "docs" / "user-guide" / "test-certificates.md"

suite "docs/user-guide/test-certificates.md":
  test "it exists and is linked from the guide's front page":
    check fileExists(guidePath)
    check "(test-certificates.md)" in
      readFile(guidePath.parentDir / "README.md")

  test "it names the content binding and the pre-commit gate":
    let guide = readFile(guidePath)
    check "A certificate names **content**, not a commit" in guide
    check "## Certify, then commit" in guide
    check "## The pre-commit gate" in guide
    check "keyed by tree" in guide.replace("\n", " ").replace("**", "")

  test "it covers everything a user meets on the way to a gateway":
    let guide = readFile(guidePath)
    for phrase in ["## The local store", "--no-certify",
                   "TEST_CERTIFICATES_HOOK_TIMEOUT", "TEST_CERTIFICATES_HOOK`",
                   "testCertificatesScope", "test-certificates notes publish",
                   "test-certificates notes push", "already-published",
                   "`advisory`", "`required`", "## Troubleshooting",
                   "https://github.com/metacraft-labs/test-certificates-spec"]:
      checkpoint(phrase)
      check phrase in guide

  test "it does not bring back the commit-bound workflow":
    let guide = readFile(guidePath).toLowerAscii()
    for stale in ["commit first", "commit, then certify",
                  "clean tree required", "must be clean",
                  "refs/notes/reprobuild/certificates`, which"]:
      checkpoint(stale)
      check stale notin guide

  test "it cites nothing private":
    # By shape rather than by name, so this public file does not list what it
    # guards against: a project-management or specification repository, and a
    # milestone id such as an upper-case prefix followed by a number.
    let guide = readFile(guidePath)
    for leak in ["-pm", "-specs", "milestones"]:
      checkpoint(leak)
      check leak notin guide
    for i in 1 ..< guide.high:
      if guide[i] == '-' and guide[i + 1] in Digits:
        var start = i
        while start > 0 and guide[start - 1] in UppercaseLetters:
          dec start
        checkpoint(guide[start .. min(i + 3, guide.high)])
        check i - start notin 2 .. 4
