## M8 verification: every populated example dir under
## ``reprobuild-examples/`` has a project file (``repro.nim`` or the
## legacy ``reprobuild.nim``) declaring at least one member and carrying
## NO ``build:`` block (Tier 2b opt-in shape).
##
## The check is intentionally textual rather than DSL-aware: at this
## milestone the standard provider hasn't grown conventions for every
## language yet, but the source tree + project file must already be in
## place so M9's end-to-end harness can iterate the full list.
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
  "nim/mode3-pilot",
  "nim/multi-binary",
  "rust/binary",
  "rust/library",
  "rust/library-with-tests",
  "rust/workspace",
  "rust/workspace-lib-chain",
  "rust/cdylib",
  "rust/binary-with-crates-io",
  "rust/binary-with-build-rs",
  "go/binary",
  "go/library",
  "go/library-with-tests",
  "go/multi-binary",
  "python/library-pure",
  "python/console-script",
  "python/pep517-maturin",
  "python/pep517-scikit-build-core",
  "javascript-typescript/typescript-library",
  "javascript-typescript/typescript-cli",
  "javascript-typescript/node-server",
  "javascript-typescript/vite-app",
  "javascript-typescript/webpack-app",
  "c-cpp-make/binary",
  "c-cpp-make/library-static",
  "c-cpp-autotools/hello-binary",
  "c-cpp-cmake/hello-binary",
  "c-cpp-meson/hello-binary",
  "java-maven/hello-binary",
  "kotlin-gradle/hello-binary",
  "csharp-dotnet/hello-binary",
  "swift-swiftpm/hello-binary",
  "ocaml-dune/hello-binary",
  "haskell-cabal/hello-binary",
  "ruby-bundler/hello-binary",
  "php-composer/hello-binary",
  "c-cpp-mode3/binary-with-library",
  "rust-mode3/binary-with-library",
  "go-mode3/binary-with-library",
  "python-mode3/binary-with-library",
  "jsts-mode3/binary-with-library",
  "mixed/nim-uses-cpp-lib",
  "mixed/cpp-uses-nim-lib",
  "mixed/rust-uses-cpp-lib",
  "mixed/cpp-uses-rust-lib",
  "mixed/nim-uses-rust-lib",
  "mixed/rust-uses-nim-lib",
  "mixed/go-uses-cpp-lib",
  "mixed/cpp-uses-go-lib",
  "fortran-mode3/binary-with-library",
  "mixed/fortran-uses-cpp-lib",
  "mixed/cpp-uses-fortran-lib",
  "zig-mode3/binary-with-library",
  "mixed/zig-uses-cpp-lib",
  "mixed/cpp-uses-zig-lib",
  "d-mode3/binary-with-library",
  "mixed/d-uses-cpp-lib",
  "mixed/cpp-uses-d-lib",
  "ada-mode3/binary-with-library",
  "mixed/ada-uses-cpp-lib",
  "mixed/cpp-uses-ada-lib",
  "pascal-mode3/binary-with-library",
  "mixed/pascal-uses-cpp-lib",
  "mixed/cpp-uses-pascal-lib",
  "crystal-shards/hello-binary",
  "crystal-mode3/hello-binary",
  "erlang-rebar3/hello-binary",
]

suite "examples layout M8":
  for example in PopulatedExamples:
    test "example " & example & " has minimal project file":
      let dir = ExamplesRoot / example
      check dirExists(dir)
      # Accept either the canonical ``repro.nim`` or the legacy
      # ``reprobuild.nim`` alias, per
      # ``Three-Mode-Convention-System.md`` §"`repro.nim` ↔
      # `reprobuild.nim` alias". The fixture corpus today uses the
      # legacy name everywhere except the Mode 3 pilot, which
      # dogfoods the canonical name.
      let canonical = dir / "repro.nim"
      let legacy = dir / "reprobuild.nim"
      check fileExists(canonical) or fileExists(legacy)
      let projectFile =
        if fileExists(canonical): canonical
        else: legacy
      let content = readFile(projectFile)
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
