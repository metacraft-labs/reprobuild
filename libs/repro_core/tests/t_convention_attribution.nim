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
