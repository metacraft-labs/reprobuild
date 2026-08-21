## `repro lock list` reports a workspace's declarations even when the recipe
## has no `build:` block.
##
## Named-Lock-Files NLF-M8, the second of the three criteria folded in from
## NLF-M7:
##
## > **`repro lock list` verified end to end**, not only at its renderer. …
## > It also inherits an early return from the existing solver-inputs probe:
## > **a project with no `build:` block, or none with a solver-bound `uses:`,
## > never runs the provider and the listing silently falls back to the
## > well-known set.** That fallback is the defect class this campaign exists
## > to catch — a listing that reports confidently about the wrong thing — so
## > it needs a test that a project WITH declarations and no qualifying
## > `build:` block still lists them.
##
## ## Why the fallback is the interesting failure and not a missing feature
##
## Because it is silent and it is plausible. `predeclaredLockFiles()` is a
## perfectly good answer to "what lock files are in scope" for a workspace
## that declares none, so a listing that printed it would look right. The two
## situations — "this workspace declares nothing" and "we never asked" —
## render identically, and §4.2's own worked example is on the wrong side of
## that line: a `workspace.nim` whose entire content is two `lockFile`
## declarations has no `build:` block at all.
##
## ## What "end to end" means here, exactly
##
## The verb's real implementation is reached: `runReproLockCommand(["list",
## dir])`, the exported dispatcher `main()` calls, with stdout redirected to a
## file so the printed text is what is asserted on. That is one frame below
## the `repro` binary's `main()`.
##
## **What is NOT covered, stated rather than implied:** the `repro` binary
## itself is not built or executed. `scripts/build_apps.sh` fails at link in
## this environment, and a claim of "verified end to end" that meant "through
## the dispatcher" without saying so would be the same kind of confident
## report about the wrong thing this file exists to catch.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## A real recipe file on disk, the real verb dispatcher, the real provider
## probe, and the real renderer. Nothing here substitutes for the compiled
## provider: when it cannot be produced in this environment the assertions
## below fail rather than being skipped, because a probe that quietly
## degrades is precisely the behaviour under test.

import std/[os, posix, strutils, unittest]

import repro_cli_support
import repro_lock_files

const
  Recipe = """
import repro_dsl_stdlib/prelude

## Tools that run on the build machine: code generators, compilers, anything
## whose output is consumed during the build rather than shipped.
lockFile listedHostTools

## Everything we ship. Pinned to the aarch64 target graph.
lockFile listedTargetRuntime

package declaresOnly:
  discard
"""

var root = ""

proc repoRoot(): string =
  currentSourcePath().parentDir().parentDir().parentDir().parentDir()

proc listingOf(dir: string): string =
  ## Run the real `repro lock list` verb and return what it printed.
  let captured = dir / "listing.txt"
  var rc = 0
  let original = dup(stdout.getFileHandle())
  defer:
    discard dup2(original, stdout.getFileHandle())
    discard close(original)
  let sink = open(captured, fmWrite)
  discard dup2(sink.getFileHandle(), stdout.getFileHandle())
  rc = runReproLockCommand(["list", dir])
  flushFile(stdout)
  sink.close()
  doAssert rc == 0, "repro lock list exited " & $rc
  readFile(captured)

suite "NLF-M8 repro lock list reports a recipe with no build: block":

  setup:
    resetLockFileDeclarations()
    # Under the repo's `build/` scratch, not the system temp dir: Nim finds
    # `config.nims` by walking UP from the compiled file, and this repo's is
    # what puts every `libs/*/src` on the module path. A recipe in /tmp
    # compiles against a different world and would fail for reasons that have
    # nothing to do with lock files — the same reason
    # `lock_file_compile_probe` gives for the same choice.
    root = repoRoot() / "build" /
      ("nlf-m8-locklist-" & $getCurrentProcessId())
    removeDir(root)
    createDir(root)
    writeFile(root / "repro.nim", Recipe)

  teardown:
    try: removeDir(root)
    except CatchableError: discard

  test "the recipe really has no build: block":
    # The premise. If the fixture grew one, the case would be asserting that
    # a path nobody takes works.
    check not ("build:" in readFile(root / "repro.nim"))

  test "the provider probe returns the workspace's declarations":
    let declared = lockFileDeclarationsFromCompiledProvider(root)
    var names: seq[string] = @[]
    for d in declared: names.add(d.name)
    checkpoint("declared: " & $names)
    check "listedTargetRuntime" in names

  test "and it is not merely the well-known set":
    # The assertion that separates "we read the recipe" from "we fell back".
    # `default` and `hostTools` are in the fallback, so a listing containing
    # only those two is indistinguishable from having asked nothing.
    let declared = lockFileDeclarationsFromCompiledProvider(root)
    check declared.len > predeclaredLockFiles().len

  test "the listing prints the declared name and its description":
    let text = listingOf(root)
    checkpoint(text)
    check "listedTargetRuntime" in text
    check "Everything we ship" in text

  test "the listing still carries the well-known names":
    # §3.1 and §4.8: `default` and `hostTools` are in scope in every
    # workspace, so reading the recipe must ADD to the set rather than
    # replace it.
    let text = listingOf(root)
    checkpoint(text)
    check DefaultLockFileName in text
    check HostToolsLockFileName in text
