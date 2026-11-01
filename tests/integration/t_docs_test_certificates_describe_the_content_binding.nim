## The user guide for test certificates exists and describes what ships: the
## content binding, the pre-commit gate, the store, propagation and ``repro
## push``. It must not bring back the commit-bound workflow the standard's
## content binding removed.
##
## A documentation-content test, in the shape of
## ``t_docs_hooks_reflect_public_tier_only_server_gate``. It builds nothing and
## drives no binary. Beyond the guide's own phrases, it holds the guide to the
## code: the messages it quotes must exist in the source that prints them, and
## the defaults it states must be the defaults the code uses, so rewording a
## message or moving a default fails here instead of leaving the guide wrong.
##
## It also guards the two things a public guide must not carry: a private
## repository's name, and a private plan's milestone id.

import std/[os, strutils, unittest]

from repro_cli_support/certificate_store import DefaultStoreRetention
from test_certificates/hook import DefaultHookTimeoutMs

let guidePath = currentSourcePath().parentDir.parentDir.parentDir /
  "docs" / "user-guide" / "test-certificates.md"

const quotedInSource = [
  # The certifying run and the pre-commit gate.
  "re-certify is a no-op",
  "no trusted certificate covers the content being committed",
  "on exactly what you are committing",
  # The push path and the gateway.
  "is not this checkout's content",
  "no certificate note on the pushed tree",
  "content must be the content that was tested",
  # The health row.
  "this build writes no notes",
  "pre-push hook ",
  "snapshot current",
  # Names a reader types or configures.
  "REPRO_CERTIFICATE_STORE_KEEP",
  "certificate_store",
  "REPRO_DAEMON_SIGNING_KEY",
  "REPRO_DAEMON_KEY_ID",
  "repro-daemon-key",
  "registered-keys.toml",
  "REPRO_ALLOW_PIN_REGRESSION",
  "TEST_CERTIFICATES_HOOK",
  "--no-certify",
  "--check-set",
  "--current-repo"]

proc cliSource(): string =
  ## Everything the guide's messages can come from, as one text, with string
  ## literals split across lines joined again, as a reader sees the message.
  for path in walkDirRec(guidePath.parentDir.parentDir.parentDir / "libs" /
      "repro_cli_support" / "src"):
    if not path.endsWith(".nim"):
      continue
    for line in readFile(path).splitLines():
      let trimmed = line.strip()
      if result.endsWith("\" &") and trimmed.startsWith("\""):
        result.setLen(result.len - 3)
        result.add(trimmed[1 .. ^1])
      else:
        result.add("\n" & trimmed)

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

  test "what it quotes is what the code prints":
    let guide = readFile(guidePath).replace("\n", " ")
    let source = cliSource()
    for phrase in quotedInSource:
      checkpoint(phrase)
      # Booleans, because a failed check prints its operands, and one of these
      # is every source file of the library.
      let inGuide = phrase in guide
      let inSource = phrase in source
      check inGuide
      check inSource

  test "the defaults it states are the code's":
    let guide = readFile(guidePath).replace("\n", " ")
    check ("to the newest " & $DefaultStoreRetention & " content directories") in guide
    check ("The default is " & $(DefaultHookTimeoutMs div 1000) & ".") in guide

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
