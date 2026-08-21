## NLF-DOC-1 and NLF-DOC-2 — the captured description reaches its two
## consumers.
##
## Named-Lock-Files NLF-M7. Corpus cases **NLF-DOC-1** and **NLF-DOC-2**: "The
## description reaches the lock-file listing, and the undeclared-symbol
## diagnostic prints in-scope names WITH their descriptions."
##
## Design §4.2 states the requirement in terms of its readers, and says why:
##
## > **What the captured text is for.** Three consumers, and the requirement
## > should be stated in terms of them so that "captured" cannot be satisfied
## > by storing text nobody reads.
##
## > 1. **Listing lock files.** A `repro lock list` … prints each declared
## >    name with its description. This is the primary surface: a workspace
## >    with three declared lock files is unusable if a reader cannot find out
## >    what each is *for* without grepping the recipes.
## > 2. **The unbound-lock-file diagnostic (§5.3) and the undeclared-symbol
## >    error (§4.9).** Both already enumerate what is in scope; both should
## >    print each name's description alongside it.
##
## ## The measured background that makes this a real risk
##
## §4.2 records that no CLI surface prints a captured doc comment today, and
## that doc comments on `executable`, `library`, `files` and `package` "are
## specified as captured and are in fact **discarded**: those def types carry
## no description field, and the package-body walker skips `nnkCommentStmt`
## outright." So `lockFile` is "the first declaration form whose captured doc
## text has a working consumer", and a capture with no reader is exactly how
## the existing gap arose. This file is the reader, asserted.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## The declarations are real `lockFile` declarations expanded by the real
## macro; the listing is the renderer `repro lock list` prints; the diagnostic
## is the renderer the `--lock` binding and the §4.9 compile error both use.

import std/[strutils, unittest]

import repro_dsl_stdlib/lock_file_decl
import repro_lock_files

## Tools that run on the build machine: code generators, compilers,
## anything whose output is consumed during the build rather than shipped.
lockFile listedHostTools

## Everything we ship. Pinned to the aarch64 target graph.
lockFile listedTargetRuntime, path = "locks/aarch64.lock"

suite "NLF-DOC-1/2 the description reaches the listing and the diagnostic":

  test "NLF-DOC-1: the listing prints each name with its description":
    let listing = lockFileListingText()
    check "listedHostTools" in listing
    check "code generators, compilers," in listing
    check "anything whose output is consumed during the build" in listing
    check "listedTargetRuntime" in listing
    check "Everything we ship." in listing

  test "NLF-DOC-1: and the listing prints the committed binding":
    # A listing that named the lock files but not what they currently resolve
    # to would answer half the question an operator has.
    let listing = lockFileListingText()
    check "path: locks/aarch64.lock" in listing

  test "NLF-DOC-1: and it says where each one was declared":
    let listing = lockFileListingText()
    check "(stdlib, predeclared)" in listing
    check "t_doc_comment_reaches_listing_and_diagnostic.nim" in listing

  test "NLF-DOC-2: the undeclared-symbol diagnostic lists names AND meanings":
    let diagnostic = undeclaredLockFileDiagnostic(
      "listedHostTool", "packages/mytool/repro.nim", 28, 14)
    check "undeclared lock file `listedHostTool`" in diagnostic
    check "in scope here:" in diagnostic
    check "listedHostTools" in diagnostic
    # The description, not just the name — §4.2's consumer (2) in full.
    check "code generators, compilers," in diagnostic
    check "Everything we ship." in diagnostic

  test "NLF-DOC-2: and it points at the offending source position":
    let diagnostic = undeclaredLockFileDiagnostic(
      "listedHostTool", "packages/mytool/repro.nim", 28, 14)
    check "packages/mytool/repro.nim(28, 14)" in diagnostic
    check "lockFile listedHostTool" in diagnostic
    check "^" in diagnostic

  test "NLF-DOC-2: and it suggests the intended name":
    let diagnostic = undeclaredLockFileDiagnostic(
      "listedHostTool", "packages/mytool/repro.nim", 28, 14)
    check "did you mean `listedHostTools`?" in diagnostic

  test "a name with no plausible neighbour gets no suggestion":
    # A suggestion that is not what the author meant is worse than none: it
    # invites a second wrong edit. So the bound is tight enough that an
    # unrelated name produces no `did you mean` line at all.
    let diagnostic = undeclaredLockFileDiagnostic(
      "somethingEntirelyDifferent", "repro.nim", 1, 1)
    check "did you mean" notin diagnostic
    # It still enumerates what IS in scope, which is the part that helps.
    check "in scope here:" in diagnostic

  test "the description survives the round trip a compiled recipe makes":
    # §4.2's consumer (1) runs in the CLI process while the declarations live
    # in the recipe's, so the text crosses a process boundary as
    # tab-separated records. A description is multi-line by construction and
    # an un-escaped newline would truncate it at the record separator —
    # silently, and only for the descriptions that have more than one line,
    # which is every description worth printing.
    let rendered = renderLockFileDeclarations(lockFileDeclarations())
    let readBack = parseLockFileDeclarations(rendered)
    check readBack.len == lockFileDeclarations().len
    var found = false
    for d in readBack:
      if d.name != "listedHostTools": continue
      found = true
      check d.description ==
        "Tools that run on the build machine: code generators, compilers,\n" &
        "anything whose output is consumed during the build rather than shipped."
      check d.sourceLine > 0
      check d.sourceColumn == 1
    check found
