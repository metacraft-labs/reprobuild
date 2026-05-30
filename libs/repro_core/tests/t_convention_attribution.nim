## Unit tests for ``repro_core/convention_attribution`` —
## the per-target attribution heuristic, no-match diagnostics, and
## toolchain probe used by ``repro show-conventions``.
##
## See ``reprobuild-specs/Three-Mode-Convention-System.md`` §"Observability"
## for the user-facing contract. The heuristic itself is option 1c
## (manifest detection plus extension census) and is documented at the
## top of ``libs/repro_core/src/repro_core/convention_attribution.nim``.

import std/[os, strutils, tables, unittest]

import repro_core

proc makeScratch(name: string): string =
  result = getTempDir() / ("repro-core-convattr-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "attributeConvention: manifest detection":

  test "Cargo.toml ⇒ rust":
    let dir = makeScratch("cargo-toml")
    writeFile(dir / "Cargo.toml", "[package]\nname = \"x\"\n")
    createDir(dir / "src")
    writeFile(dir / "src" / "lib.rs", "pub fn x() {}")
    let attr = attributeConvention(dir)
    check attr.convention == "rust"
    check attr.evidence.contains("Cargo.toml")
    removeDir(dir)

  test "go.mod ⇒ go":
    let dir = makeScratch("go-mod")
    writeFile(dir / "go.mod", "module example.com/x\ngo 1.21\n")
    let attr = attributeConvention(dir)
    check attr.convention == "go"
    check attr.evidence.contains("go.mod")
    removeDir(dir)

  test "pyproject.toml ⇒ python":
    let dir = makeScratch("pyproject")
    writeFile(dir / "pyproject.toml", "[project]\nname = \"x\"\n")
    let attr = attributeConvention(dir)
    check attr.convention == "python"
    check attr.evidence.contains("pyproject.toml")
    removeDir(dir)

  test "package.json ⇒ javascript-typescript":
    let dir = makeScratch("packagejson")
    writeFile(dir / "package.json", "{\"name\":\"x\"}")
    let attr = attributeConvention(dir)
    check attr.convention == "javascript-typescript"
    check attr.evidence.contains("package.json")
    removeDir(dir)

  test "configure.ac ⇒ c-cpp-autotools":
    let dir = makeScratch("autotools")
    writeFile(dir / "configure.ac", "AC_INIT([x], [1.0])\n")
    writeFile(dir / "Makefile.am", "")
    let attr = attributeConvention(dir)
    check attr.convention == "c-cpp-autotools"
    removeDir(dir)

  test "CMakeLists.txt ⇒ c-cpp-cmake":
    let dir = makeScratch("cmake")
    writeFile(dir / "CMakeLists.txt", "project(x)\n")
    let attr = attributeConvention(dir)
    check attr.convention == "c-cpp-cmake"
    removeDir(dir)

  test "meson.build ⇒ c-cpp-meson":
    let dir = makeScratch("meson")
    writeFile(dir / "meson.build", "project('x', 'c')\n")
    let attr = attributeConvention(dir)
    check attr.convention == "c-cpp-meson"
    removeDir(dir)

  test "pom.xml ⇒ java-maven":
    ## M40 — Maven manifest must attribute to ``java-maven``. Parallels
    ## the M38/M39 tests above for CMakeLists.txt and meson.build.
    let dir = makeScratch("maven")
    writeFile(dir / "pom.xml",
      "<?xml version=\"1.0\"?>\n" &
      "<project><modelVersion>4.0.0</modelVersion>" &
      "<groupId>g</groupId><artifactId>x</artifactId>" &
      "<version>1.0</version></project>\n")
    let attr = attributeConvention(dir)
    check attr.convention == "java-maven"
    removeDir(dir)

  test "build.gradle.kts ⇒ kotlin-gradle":
    ## M41 — Kotlin DSL Gradle manifest must attribute to
    ## ``kotlin-gradle``. Parallels the M40 test above for ``pom.xml``.
    let dir = makeScratch("gradle-kts")
    writeFile(dir / "build.gradle.kts",
      "plugins { kotlin(\"jvm\") version \"1.9.25\" }\n" &
      "version = \"1.0\"\n")
    writeFile(dir / "settings.gradle.kts",
      "rootProject.name = \"hello\"\n")
    let attr = attributeConvention(dir)
    check attr.convention == "kotlin-gradle"
    check attr.evidence.contains("build.gradle.kts")
    removeDir(dir)

  test "*.csproj ⇒ csharp-dotnet":
    ## M42 — SDK-style C# project filename pattern must attribute to
    ## ``csharp-dotnet``. Parallels the *.nimble glob-match sentinel
    ## (since csprojs are named after the project rather than using a
    ## fixed filename like ``pom.xml`` / ``build.gradle.kts``).
    let dir = makeScratch("csproj")
    writeFile(dir / "hello.csproj",
      "<Project Sdk=\"Microsoft.NET.Sdk\">\n" &
      "  <PropertyGroup>\n" &
      "    <OutputType>Exe</OutputType>\n" &
      "    <TargetFramework>net8.0</TargetFramework>\n" &
      "  </PropertyGroup>\n" &
      "</Project>\n")
    writeFile(dir / "packages.lock.json", "{\n  \"version\": 1\n}\n")
    let attr = attributeConvention(dir)
    check attr.convention == "csharp-dotnet"
    check attr.evidence.contains("hello.csproj")
    removeDir(dir)

  test "Package.swift ⇒ swift-swiftpm":
    ## M43 — SwiftPM manifest must attribute to ``swift-swiftpm``.
    ## Unique filename (no other convention recognises ``Package.swift``)
    ## so the manifest-pass picks it up directly.
    let dir = makeScratch("package-swift")
    writeFile(dir / "Package.swift",
      "// swift-tools-version:5.5\n" &
      "import PackageDescription\n" &
      "let package = Package(name: \"hello\",\n" &
      "  targets: [.executableTarget(name: \"hello\")])\n")
    let attr = attributeConvention(dir)
    check attr.convention == "swift-swiftpm"
    check attr.evidence.contains("Package.swift")
    removeDir(dir)

  test "<name>.cabal ⇒ haskell-cabal":
    ## M55 — Cabal package manifest must attribute to ``haskell-cabal``.
    ## The filename varies per package (named after the package, e.g.
    ## ``hello.cabal``); the attribution heuristic uses the ``*.cabal``
    ## sentinel mirroring the ``*.nimble`` and ``*.csproj`` cases.
    let dir = makeScratch("haskell-cabal")
    writeFile(dir / "hello.cabal",
      "cabal-version: 2.0\n" &
      "name: hello\n" &
      "version: 1.0\n" &
      "executable hello\n" &
      "  main-is: Main.hs\n" &
      "  hs-source-dirs: app\n" &
      "  build-depends: base >=4.14 && <5\n" &
      "  default-language: Haskell2010\n")
    createDir(dir / "app")
    writeFile(dir / "app" / "Main.hs",
      "module Main where\nmain :: IO ()\nmain = putStrLn \"hi\"\n")
    let attr = attributeConvention(dir)
    check attr.convention == "haskell-cabal"
    check attr.evidence.contains("hello.cabal")
    removeDir(dir)

  test "shard.yml ⇒ crystal":
    ## M60 — Crystal's Shards manifest must attribute to ``crystal``.
    ## Literal ``shard.yml`` filename (no glob — Shards' manifest
    ## filename is hard-coded). The ``crystal`` convention additionally
    ## requires ``shard.lock`` (HARD precondition for Mode 2) AND a
    ## ``crystal`` / ``shards`` token in ``uses:`` for full dispatch,
    ## but the attribution heuristic here is intentionally manifest-
    ## presence-only — the heuristic honestly attributes ``crystal``
    ## even when those preconditions aren't met (so ``repro
    ## show-conventions`` still tells the user which convention WOULD
    ## claim the project once the prerequisites are in place).
    let dir = makeScratch("crystal-shards")
    writeFile(dir / "shard.yml",
      "name: hello\nversion: 1.0.0\n" &
      "targets:\n  hello:\n    main: src/hello.cr\n" &
      "crystal: \">= 1.0\"\n")
    writeFile(dir / "shard.lock",
      "version: 2.0\nshards: {}\n")
    createDir(dir / "src")
    writeFile(dir / "src" / "hello.cr",
      "puts \"hello\"\n")
    let attr = attributeConvention(dir)
    check attr.convention == "crystal"
    check attr.evidence.contains("shard.yml")
    removeDir(dir)

  test "rebar.config ⇒ erlang-rebar3":
    ## M61 — rebar3's project manifest must attribute to
    ## ``erlang-rebar3``. Literal ``rebar.config`` filename (no glob —
    ## rebar3's manifest filename is hard-coded). The ``erlang-rebar3``
    ## convention additionally requires ``rebar.lock`` (HARD
    ## precondition) AND an ``erlang`` / ``erl`` / ``rebar3`` token in
    ## ``uses:`` for full dispatch, but the attribution heuristic here
    ## is intentionally manifest-presence-only — the heuristic honestly
    ## attributes ``erlang-rebar3`` even when those preconditions aren't
    ## met (so ``repro show-conventions`` still tells the user which
    ## convention WOULD claim the project once the prerequisites are in
    ## place).
    let dir = makeScratch("erlang-rebar3")
    writeFile(dir / "rebar.config",
      "{erl_opts, [debug_info]}.\n{deps, []}.\n" &
      "{escript_main_app, hello}.\n")
    writeFile(dir / "rebar.lock", "[].\n")
    createDir(dir / "src")
    writeFile(dir / "src" / "hello.app.src",
      "{application, hello, [{vsn, \"1.0.0\"}]}.\n")
    writeFile(dir / "src" / "hello.erl",
      "-module(hello).\n-export([main/1]).\nmain(_) -> ok.\n")
    let attr = attributeConvention(dir)
    check attr.convention == "erlang-rebar3"
    check attr.evidence.contains("rebar.config")
    removeDir(dir)

  test "mix.exs ⇒ elixir-mix":
    ## M62 — mix's project manifest must attribute to ``elixir-mix``.
    ## Literal ``mix.exs`` filename (no glob — mix's manifest filename
    ## is hard-coded). The ``elixir-mix`` convention additionally
    ## requires ``mix.lock`` (HARD precondition) AND an ``elixir`` /
    ## ``mix`` token in ``uses:`` for full dispatch, but the
    ## attribution heuristic here is intentionally manifest-presence-
    ## only — the heuristic honestly attributes ``elixir-mix`` even
    ## when those preconditions aren't met (so ``repro
    ## show-conventions`` still tells the user which convention WOULD
    ## claim the project once the prerequisites are in place).
    let dir = makeScratch("elixir-mix")
    writeFile(dir / "mix.exs",
      "defmodule Hello.MixProject do\n  use Mix.Project\n" &
      "  def project, do: [app: :hello, version: \"1.0.0\", " &
      "escript: [main_module: Hello]]\nend\n")
    writeFile(dir / "mix.lock", "%{}\n")
    createDir(dir / "lib")
    writeFile(dir / "lib" / "hello.ex",
      "defmodule Hello do\n  def main(_), do: IO.puts \"hi\"\nend\n")
    let attr = attributeConvention(dir)
    check attr.convention == "elixir-mix"
    check attr.evidence.contains("mix.exs")
    removeDir(dir)

  test "composer.json ⇒ php-composer":
    ## M57 — Composer manifest must attribute to ``php-composer``.
    ## Literal ``composer.json`` filename (no glob — Composer's manifest
    ## filename is hard-coded). The ``php-composer`` convention
    ## additionally requires ``composer.lock`` (HARD precondition) AND
    ## a ``php`` / ``composer`` token in ``uses:`` for full dispatch,
    ## but the attribution heuristic here is intentionally manifest-
    ## presence-only — the heuristic honestly attributes
    ## ``php-composer`` even when those preconditions aren't met (so
    ## ``repro show-conventions`` still tells the user which convention
    ## WOULD claim the project once the prerequisites are in place).
    let dir = makeScratch("php-composer")
    writeFile(dir / "composer.json",
      "{\n  \"name\": \"hello/hello\",\n  \"type\": \"project\"\n}\n")
    writeFile(dir / "composer.lock",
      "{\n  \"_readme\": [\"M57 fixture stub\"],\n" &
      "  \"content-hash\": \"" & "0".repeat(32) & "\",\n" &
      "  \"packages\": [],\n  \"packages-dev\": [],\n" &
      "  \"aliases\": [],\n  \"minimum-stability\": \"stable\",\n" &
      "  \"stability-flags\": {},\n  \"prefer-stable\": false,\n" &
      "  \"prefer-lowest\": false,\n  \"platform\": {},\n" &
      "  \"platform-dev\": {},\n  \"plugin-api-version\": \"2.6.0\"\n}\n")
    createDir(dir / "bin")
    writeFile(dir / "bin" / "hello.php",
      "<?php\necho \"hello\\n\";\n")
    let attr = attributeConvention(dir)
    check attr.convention == "php-composer"
    check attr.evidence.contains("composer.json")
    removeDir(dir)

  test "Gemfile ⇒ ruby-bundler":
    ## M56 — Bundler dependency manifest must attribute to
    ## ``ruby-bundler``. Literal ``Gemfile`` filename (no glob —
    ## Bundler's manifest filename is hard-coded). The
    ## ``ruby-bundler`` convention additionally requires
    ## ``Gemfile.lock`` (HARD precondition) AND a ``ruby`` /
    ## ``bundler`` token in ``uses:`` for full dispatch, but the
    ## attribution heuristic here is intentionally manifest-presence-
    ## only — the heuristic honestly attributes ``ruby-bundler`` even
    ## when those preconditions aren't met (so ``repro
    ## show-conventions`` still tells the user which convention WOULD
    ## claim the project once the prerequisites are in place).
    let dir = makeScratch("ruby-bundler")
    writeFile(dir / "Gemfile",
      "source 'https://rubygems.org'\nruby '>= 3.0'\n")
    writeFile(dir / "Gemfile.lock",
      "GEM\n  specs:\n\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n\n" &
      "RUBY VERSION\n   ruby 3.3.5p100\n\nBUNDLED WITH\n   2.5.18\n")
    createDir(dir / "bin")
    writeFile(dir / "bin" / "hello.rb",
      "#!/usr/bin/env ruby\nputs \"hello\"\n")
    let attr = attributeConvention(dir)
    check attr.convention == "ruby-bundler"
    check attr.evidence.contains("Gemfile")
    removeDir(dir)

  test "dune-project ⇒ ocaml-dune":
    ## M46 — Dune project manifest must attribute to ``ocaml-dune``.
    ## Unique filename (no other convention recognises ``dune-project``)
    ## so the manifest-pass picks it up directly.
    let dir = makeScratch("dune-project")
    writeFile(dir / "dune-project", "(lang dune 3.0)\n")
    writeFile(dir / "dune", "(executable (name hello))\n")
    writeFile(dir / "hello.ml",
      "let () = print_endline \"hi\"\n")
    let attr = attributeConvention(dir)
    check attr.convention == "ocaml-dune"
    check attr.evidence.contains("dune-project")
    removeDir(dir)

  test "build.gradle (Groovy DSL) ⇒ kotlin-gradle":
    ## M41 — Groovy DSL Gradle manifest must also attribute to
    ## ``kotlin-gradle`` (the convention accepts either DSL).
    let dir = makeScratch("gradle-groovy")
    writeFile(dir / "build.gradle",
      "plugins { id 'org.jetbrains.kotlin.jvm' version '1.9.25' }\n" &
      "version = '1.0'\n")
    writeFile(dir / "settings.gradle",
      "rootProject.name = 'hello'\n")
    let attr = attributeConvention(dir)
    check attr.convention == "kotlin-gradle"
    check attr.evidence.contains("build.gradle")
    removeDir(dir)

  test "*.nimble ⇒ nim":
    let dir = makeScratch("nimble")
    writeFile(dir / "mylib.nimble", "version = \"0.1.0\"\n")
    let attr = attributeConvention(dir)
    check attr.convention == "nim"
    check attr.evidence.contains("mylib.nimble")
    removeDir(dir)

  test "manifest dispatch order: Cargo.toml wins over package.json":
    ## Mirrors the standard-provider's ``addDefaultConvention`` order —
    ## rust is registered before javascript-typescript, so a dir
    ## carrying both manifests routes to rust.
    let dir = makeScratch("cargo-plus-pkgjson")
    writeFile(dir / "Cargo.toml", "[package]\nname = \"x\"\n")
    writeFile(dir / "package.json", "{}")
    let attr = attributeConvention(dir)
    check attr.convention == "rust"
    removeDir(dir)

  test "manifest dispatch order: configure.ac wins over Makefile":
    let dir = makeScratch("autotools-plus-make")
    writeFile(dir / "configure.ac", "AC_INIT([x], [1.0])\n")
    writeFile(dir / "Makefile", "all:\n\techo x\n")
    let attr = attributeConvention(dir)
    check attr.convention == "c-cpp-autotools"
    removeDir(dir)

suite "attributeConvention: extension census fallback":

  test "*.nim-dominant dir without nimble ⇒ nim":
    let dir = makeScratch("nim-extension")
    writeFile(dir / "main.nim", "echo \"hi\"\n")
    writeFile(dir / "helper.nim", "proc h*() = discard\n")
    let attr = attributeConvention(dir)
    check attr.convention == "nim"
    check attr.evidence.contains("extension census")
    removeDir(dir)

  test "*.rs-dominant dir without Cargo.toml ⇒ rust-direct (M30 refinement)":
    # M30: when ``.rs`` files dominate the dir but NO ``Cargo.toml``
    # is present, the project routes through the Mode 3 ``rust-direct``
    # convention. Mirror of the c-cpp-direct refinement above.
    let dir = makeScratch("rust-extension")
    createDir(dir / "src")
    writeFile(dir / "src" / "lib.rs", "pub fn x() {}\n")
    writeFile(dir / "src" / "main.rs", "fn main() {}\n")
    let attr = attributeConvention(dir)
    check attr.convention == "rust-direct"
    check attr.evidence.contains("extension census")
    removeDir(dir)

  test "*.rs-dominant dir WITH Cargo.toml ⇒ rust (Mode 2 wins)":
    let dir = makeScratch("rust-with-cargo")
    createDir(dir / "src")
    writeFile(dir / "src" / "lib.rs", "pub fn x() {}\n")
    writeFile(dir / "src" / "main.rs", "fn main() {}\n")
    writeFile(dir / "Cargo.toml", "[package]\nname=\"x\"\nversion=\"0.1.0\"\n")
    let attr = attributeConvention(dir)
    # ``Cargo.toml`` is a manifest signal so we land on ``rust`` via
    # the manifest table (no extension-census refinement needed).
    check attr.convention == "rust"
    removeDir(dir)

  test "*.adb-dominant dir ⇒ ada-direct (M58 extension census)":
    # M58: when ``.adb`` files dominate the dir, the project routes
    # through the Mode 3 ``ada-direct`` convention. There is no Mode 2
    # Ada manifest (``*.gpr`` recognition is deferred per the M58
    # honest-scope cut) so the extension census is the sole signal.
    let dir = makeScratch("ada-extension")
    createDir(dir / "src")
    writeFile(dir / "src" / "main.adb",
      "procedure Main is\nbegin\n   null;\nend Main;\n")
    writeFile(dir / "src" / "lib.adb",
      "package body Lib is\nend Lib;\n")
    writeFile(dir / "src" / "lib.ads",
      "package Lib is\nend Lib;\n")
    let attr = attributeConvention(dir)
    check attr.convention == "ada-direct"
    check attr.evidence.contains("extension census")
    removeDir(dir)

  test "*.erl-dominant dir ⇒ erlang-rebar3 (M61 extension census)":
    # M61: when ``.erl`` files dominate the dir but NO ``rebar.config``
    # is present, the project still attributes to ``erlang-rebar3``
    # (the only Erlang convention in the M61 registry). The actual
    # ``erlang-rebar3`` convention's ``recognize`` requires
    # ``rebar.config`` so attribution-without-recognise is the
    # diagnostic-only case — useful so ``repro show-conventions``
    # tells the user *which* convention WOULD claim the project once
    # the manifest is in place.
    let dir = makeScratch("erlang-extension")
    createDir(dir / "src")
    writeFile(dir / "src" / "main.erl",
      "-module(main).\n-export([go/0]).\ngo() -> ok.\n")
    writeFile(dir / "src" / "helper.erl",
      "-module(helper).\n-export([f/0]).\nf() -> ok.\n")
    let attr = attributeConvention(dir)
    check attr.convention == "erlang-rebar3"
    check attr.evidence.contains("extension census")
    removeDir(dir)

  test "*.ex-dominant dir ⇒ elixir-mix (M62 extension census)":
    # M62: when ``.ex`` files dominate the dir but NO ``mix.exs`` is
    # present, the project still attributes to ``elixir-mix`` (the
    # only Elixir convention in the M62 registry). The actual
    # ``elixir-mix`` convention's ``recognize`` requires ``mix.exs``
    # so attribution-without-recognise is the diagnostic-only case —
    # useful so ``repro show-conventions`` tells the user *which*
    # convention WOULD claim the project once the manifest is in
    # place. Mirror of the M61 erlang extension-census test.
    let dir = makeScratch("elixir-extension")
    createDir(dir / "lib")
    writeFile(dir / "lib" / "hello.ex",
      "defmodule Hello do\n  def main(_), do: :ok\nend\n")
    writeFile(dir / "lib" / "helper.ex",
      "defmodule Helper do\n  def f, do: :ok\nend\n")
    let attr = attributeConvention(dir)
    check attr.convention == "elixir-mix"
    check attr.evidence.contains("extension census")
    removeDir(dir)

  test "*.cr-dominant dir ⇒ crystal (M60 extension census)":
    # M60: when ``.cr`` files dominate the dir but NO ``shard.yml`` is
    # present, the project still routes through the ``crystal``
    # convention (Mode 3 — pure source). Mirror of the pascal-direct
    # extension census case. Crystal is unusual among the M60-era
    # conventions in that a single ``crystal`` convention covers both
    # Mode 2 (shard.yml present) and Mode 3 (no shard.yml) — so the
    # attribution heuristic threads ``crystal`` for both shapes.
    let dir = makeScratch("crystal-extension")
    createDir(dir / "src")
    writeFile(dir / "src" / "main.cr",
      "puts \"hello\"\n")
    writeFile(dir / "src" / "helper.cr",
      "def helper; end\n")
    let attr = attributeConvention(dir)
    check attr.convention == "crystal"
    check attr.evidence.contains("extension census")
    removeDir(dir)

  test "*.pas-dominant dir ⇒ pascal-direct (M59 extension census)":
    # M59: when ``.pas`` (or ``.pp`` / ``.lpr``) files dominate the
    # dir, the project routes through the Mode 3 ``pascal-direct``
    # convention. There is no Mode 2 Pascal manifest (``*.lpi``
    # recognition is deferred per the M59 honest-scope cut) so the
    # extension census is the sole signal.
    let dir = makeScratch("pascal-extension")
    createDir(dir / "src")
    writeFile(dir / "src" / "main.pas",
      "program Main;\nbegin\nend.\n")
    writeFile(dir / "src" / "lib.pas",
      "unit Lib;\ninterface\nimplementation\nend.\n")
    let attr = attributeConvention(dir)
    check attr.convention == "pascal-direct"
    check attr.evidence.contains("extension census")
    removeDir(dir)

  test "directory of only .png ⇒ no convention":
    let dir = makeScratch("png-only")
    writeFile(dir / "icon.png", "")
    writeFile(dir / "logo.png", "")
    let attr = attributeConvention(dir)
    check attr.convention == ""
    check attr.evidence.contains("no recognised source extensions")
    removeDir(dir)

  test "empty dir ⇒ no convention":
    let dir = makeScratch("empty-dir")
    let attr = attributeConvention(dir)
    check attr.convention == ""
    check attr.evidence.contains("no files found")
    removeDir(dir)

suite "findUnclaimedDirectories: no-match diagnostics":

  test "apps/<name> with only .png reports as unclaimed":
    let root = makeScratch("unclaimed-apps")
    createDir(root / "apps" / "asset-pack")
    writeFile(root / "apps" / "asset-pack" / "foo.png", "")
    writeFile(root / "apps" / "asset-pack" / "bar.json", "")
    let unclaimed = findUnclaimedDirectories(root, [])
    check unclaimed.len >= 1
    var sawAssetPack = false
    for entry in unclaimed:
      if entry.relPath == "apps/asset-pack":
        sawAssetPack = true
        check entry.reason.len > 0
        check entry.sampleFiles.len > 0
    check sawAssetPack
    removeDir(root)

  test "apps/<name> with manifest is NOT flagged":
    let root = makeScratch("claimed-apps")
    createDir(root / "apps" / "rustapp")
    writeFile(root / "apps" / "rustapp" / "Cargo.toml", "[package]\nname=\"x\"\n")
    let unclaimed = findUnclaimedDirectories(root, [])
    for entry in unclaimed:
      check entry.relPath != "apps/rustapp"
    removeDir(root)

  test "claimedPaths suppresses dirs the scanner already attributed":
    let root = makeScratch("claimed-suppress")
    createDir(root / "apps" / "needs-help")
    writeFile(root / "apps" / "needs-help" / "foo.png", "")
    # Mark it claimed via the explicit set — emulates the scanner
    # having a member whose projectRoot points here.
    let claimedAbs = absolutePath(root / "apps" / "needs-help")
    let unclaimed = findUnclaimedDirectories(root, [claimedAbs])
    for entry in unclaimed:
      check entry.relPath != "apps/needs-help"
    removeDir(root)

  test "libs/<name> with mixed C sources but no Makefile flags 'sources present but no manifest'":
    let root = makeScratch("c-no-makefile")
    createDir(root / "libs" / "legacy-c")
    createDir(root / "libs" / "legacy-c" / "src")
    writeFile(root / "libs" / "legacy-c" / "src" / "foo.c", "int x;\n")
    writeFile(root / "libs" / "legacy-c" / "src" / "foo.h", "extern int x;\n")
    let unclaimed = findUnclaimedDirectories(root, [])
    var sawLegacyC = false
    for entry in unclaimed:
      if entry.relPath == "libs/legacy-c":
        sawLegacyC = true
        check entry.reason.contains("no manifest") or
          entry.reason.contains("no language convention")
    check sawLegacyC
    removeDir(root)

  test "result is deterministic (sorted by relPath)":
    let root = makeScratch("ordering")
    createDir(root / "apps" / "zeta")
    writeFile(root / "apps" / "zeta" / "a.png", "")
    createDir(root / "apps" / "alpha")
    writeFile(root / "apps" / "alpha" / "b.png", "")
    createDir(root / "libs" / "middle")
    writeFile(root / "libs" / "middle" / "c.png", "")
    let unclaimed = findUnclaimedDirectories(root, [])
    var prev = ""
    for entry in unclaimed:
      if prev.len > 0:
        check entry.relPath > prev
      prev = entry.relPath
    removeDir(root)

suite "probeToolchain: caching":

  test "repeat probe returns cached value":
    resetToolchainProbeCache()
    let first = probeToolchain("nim")
    let second = probeToolchain("nim")
    # Equality across all fields. ``available`` matches; if Nim isn't
    # on PATH the version stays empty, which is fine — we just want
    # the SAME result on a repeat call.
    check first.available == second.available
    check first.version == second.version
    check first.path == second.path

  test "unknown convention returns not-available":
    resetToolchainProbeCache()
    let probe = probeToolchain("not-a-real-convention")
    check probe.available == false
    check probe.version == ""

  test "nim probe finds nim on PATH (env setup)":
    ## When the dev shell is active, ``nim --version`` is on PATH and
    ## the probe should fire. This is the load-bearing case for
    ## ``repro show-conventions`` against the dogfood workspace.
    resetToolchainProbeCache()
    let probe = probeToolchain("nim")
    if probe.path.len > 0:
      check probe.available
      check probe.version.len > 0
      check probe.version.toLowerAscii.contains("nim")
