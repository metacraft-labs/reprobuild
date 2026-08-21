## NLF-STAT-1 — an undeclared lock-file name is a RECIPE COMPILE ERROR, and
## the diagnostic says what §4.9 says it says.
##
## Named-Lock-Files NLF-M7. Corpus case **NLF-STAT-1**: "Assert on diagnostic
## content, not merely on failure."
##
## Design §4.9 states the requirement and the exact rendering:
##
## > **Requirement.** A lock-file name referenced but never declared MUST fail
## > at **recipe compile time**. It MUST NOT be a runtime lookup miss, MUST
## > NOT silently resolve to `default`, and MUST NOT produce an empty or zero
## > value.
##
## ```text
## Error: undeclared lock file `hostTool`
##   packages/mytool/repro.nim(28, 14)
##       lockFile hostTool
##                ^
##   no lock file with that name is declared in scope.
##
##   in scope here:
##     default        (stdlib, predeclared)
##     hostTools      (workspace.nim:12)
##     targetRuntime  (workspace.nim:16)
##
##   did you mean `hostTools`?
## ```
##
## ## Why "assert on content" is the instruction, and not pedantry
##
## §4.9's own justification is a documented incident:
##
## > This is the direct lesson of `Compiles-Are-Normal-Edges.md`, which
## > records a case where `--define` flags "reached the command line … but
## > `sharedProviderNimcacheKey` does not mention defines", so a stale
## > artifact was served, "the feature that depended on those defines silently
## > did nothing, and a green build reported success". A lock-file designation
## > that silently fell back to the wrong lock file would fail in exactly that
## > shape.
##
## What the requirement protects is not "the compile stops" — that is easy and
## almost useless — but that the author is told which name they typed, what
## the alternatives ARE and what each one means, and which one they probably
## meant. A `check not result.ok` would accept an implementation that fails
## with `undeclared identifier` and delivers none of it.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## See `lock_file_compile_probe`'s header. The compiler is real and the text
## asserted on is its real output.

import std/[strutils, unittest]

import ./lock_file_compile_probe

const Prelude = """
import repro_dsl_stdlib/prelude

## Tools that run on the build machine.
lockFile hostTools

## Everything we ship. Pinned to the aarch64 target graph.
lockFile targetRuntime, path = "locks/aarch64.lock"
"""

suite "NLF-STAT-1 an undeclared lock file is a recipe compile error":

  test "the recipe does not compile":
    let probe = checkRecipeSource(Prelude & """
package mytool:
  executable tablegen:
    lockFile hostTool
""", "undeclared")
    check not probe.ok

  test "and the diagnostic names the undeclared symbol":
    let probe = checkRecipeSource(Prelude & """
package mytool:
  executable tablegen:
    lockFile hostTool
""", "undeclared-names")
    check "undeclared lock file `hostTool`" in probe.output
    check "no lock file with that name is declared in scope" in probe.output

  test "and it enumerates what IS in scope, with descriptions":
    # §4.2's consumer (2): "The §4.9 diagnostic is exactly where a reader who
    # typed the wrong name learns what the right ones mean." A listing of bare
    # names satisfies the sentence "enumerate what is in scope" and defeats
    # the reason for it.
    let probe = checkRecipeSource(Prelude & """
package mytool:
  executable tablegen:
    lockFile hostTool
""", "undeclared-scope")
    check "in scope here:" in probe.output
    check "default" in probe.output
    check "hostTools" in probe.output
    check "targetRuntime" in probe.output
    check "(stdlib, predeclared)" in probe.output
    check "Tools that run on the build machine." in probe.output
    check "Everything we ship." in probe.output

  test "and it suggests the name the author probably meant":
    let probe = checkRecipeSource(Prelude & """
package mytool:
  executable tablegen:
    lockFile hostTool
""", "undeclared-suggest")
    check "did you mean `hostTools`?" in probe.output

  test "the same misspelling at a LIBRARY is caught too":
    # §4.3 makes `executable` and `library` the two designation sites; a check
    # wired to one of them would leave the other silently resolving to
    # `default`, which §4.9 forbids in terms.
    let probe = checkRecipeSource(Prelude & """
package mytool:
  library libfoo:
    lockFile targetRuntim
""", "undeclared-library")
    check not probe.ok
    check "undeclared lock file `targetRuntim`" in probe.output
    check "did you mean `targetRuntime`?" in probe.output

  test "and at a PACKAGE":
    let probe = checkRecipeSource(Prelude & """
package mytool:
  lockFile hostTolls
  executable tablegen:
    discard
""", "undeclared-package")
    check not probe.ok
    check "undeclared lock file `hostTolls`" in probe.output

  test "the CONTROL: the correctly spelled recipe compiles":
    # Without this the suite would pass against an implementation that
    # rejected every `lockFile` line, which is a way of being right about
    # nothing.
    let probe = checkRecipeSource(Prelude & """
package mytool:
  executable tablegen:
    lockFile hostTools

  library libfoo:
    lockFile targetRuntime
""", "declared-ok")
    if not probe.ok:
      checkpoint("the well-formed recipe failed to compile:\n" & probe.output)
    check probe.ok

  test "a well-known name needs no workspace declaration":
    # §4.8's library-portability rule: "the stdlib declares a small set of
    # **well-known lock files** that always exist — at minimum `default` and
    # `hostTools`". A library referencing `hostTools` must compile in a
    # workspace that declared nothing.
    let probe = checkRecipeSource("""
import repro_dsl_stdlib/prelude

package libfoo:
  executable tool:
    lockFile hostTools
""", "wellknown")
    if not probe.ok:
      checkpoint("a well-known name was rejected:\n" & probe.output)
    check probe.ok
