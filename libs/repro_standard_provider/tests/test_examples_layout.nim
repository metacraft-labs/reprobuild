## M8 verification: every populated example dir under
## ``reprobuild-examples/`` has a ``reprobuild.nim`` declaring at least
## one member and carrying NO ``build:`` block (Tier 2b opt-in shape).
##
## The check is intentionally textual rather than DSL-aware: at this
## milestone the standard provider hasn't grown conventions for every
## language yet, but the source tree + ``reprobuild.nim`` must already
## be in place so M9's end-to-end harness can iterate the full list.
##
## Path math: ``currentSourcePath`` lands inside
## ``D:/metacraft/reprobuild/libs/repro_standard_provider/tests/``.
## Five ``parentDir`` calls walk back to ``D:/metacraft/``, then we
## append ``reprobuild-examples`` to land at the sibling checkout.

import std/[os, strutils, unittest]

const
  ## ``parentDir`` five times from
  ## ``libs/repro_standard_provider/tests/test_examples_layout.nim``:
  ## tests → repro_standard_provider → libs → reprobuild → metacraft.
  MetacraftRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir
  ExamplesRoot = MetacraftRoot / "reprobuild-examples"

const PopulatedExamples = [
  "nim/binary",
  "nim/library",
  "nim/library-with-tests",
  "nim/multi-binary",
  "rust/binary",
  "rust/library",
  "rust/library-with-tests",
  "rust/workspace",
  "rust/binary-with-build-rs",
  "go/binary",
  "go/library",
  "go/multi-binary",
  "python/library-pure",
  "python/console-script",
  "javascript-typescript/typescript-library",
  "javascript-typescript/typescript-cli",
  "javascript-typescript/node-server",
  "c-cpp-make/binary",
  "c-cpp-make/library-static",
  "c-cpp-autotools/hello-binary",
]

suite "examples layout M8":
  for example in PopulatedExamples:
    test "example " & example & " has minimal reprobuild.nim":
      let dir = ExamplesRoot / example
      check dirExists(dir)
      let nim = dir / "reprobuild.nim"
      check fileExists(nim)
      let content = readFile(nim)
      # No `build:` block — Tier 2b opt-in requires the engine to
      # dispatch to the standard provider. Look for either an
      # indented ``  build:`` (the canonical DSL shape) or a
      # left-flush ``build:`` line. Both are rejected.
      check not content.contains("\n  build:")
      check not content.contains("\nbuild:")
      # At least one declared member: ``executable``, ``library``, or
      # ``files``. Matches the trailing space so substrings of
      # surrounding text (e.g. "executablePath") don't false-positive.
      let hasMember = content.contains("executable ") or
                      content.contains("library ") or
                      content.contains("files ")
      check hasMember
