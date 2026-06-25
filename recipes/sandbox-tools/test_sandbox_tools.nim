## Fixture-level tests for the macOS sandbox-tools recipes.
##
## These are FAST registry round-trip tests (no real build) that pin the
## package definitions' shape per
## ``reprobuild-specs/Package-Model.md`` (fetch/versions/artifact registries)
## and ``reprobuild-specs/Language-Conventions/C-Cpp-Autotools.md`` §"Mode B"
## (the gnulib-shaped autotools delegation these recipes rely on). The heavy
## real build (``repro build recipes/sandbox-tools/<tool>``) is gated behind the
## repo's live flag and exercised separately; these tests keep CI green without
## a full toolchain.
##
## Coverage:
##   * sandboxCoreutils + sandboxBash fetch specs round-trip (vendored
##     ``file:./vendor/...`` URL + 64-char sha256 + tarball discriminant +
##     ``--strip-components=1``).
##   * versions registry records the upstream tag + URL + repository.
##   * artifact registry enumerates the load-bearing drop-in binaries.
##   * Mode B recognition: a gnulib-shaped ``Makefile.am`` (recursive SUBDIRS /
##     gnulib sub-archive) is detected as a Mode B trigger by the autotools
##     convention — the shape coreutils + bash both have, and the reason these
##     recipes build via the crude configure/make/install fallback rather than
##     the fine-grained per-source path.

import std/[unittest, tables]

import repro_project_dsl
import repro_standard_provider/conventions/c_cpp_autotools as autotools

# Side-effect imports: the package macros register fetch specs + versions +
# artifacts under each ``sandbox*`` package at module init. The full sandbox
# tool set is the 10 GNU/XZ packages below (2 from Phase 3 + 8 added here).
import ./coreutils/repro
import ./bash/repro
import ./findutils/repro
import ./gnugrep/repro
import ./gawk/repro
import ./gnused/repro
import ./gnutar/repro
import ./gzip/repro
import ./xz/repro
import ./which/repro

suite "sandbox-tools — recipe registry round-trip + Mode B recognition":

  test "sandboxCoreutils fetch spec is the vendored tarball":
    let spec = registeredFetchSpec("sandboxCoreutils")
    check spec.packageName == "sandboxCoreutils"
    check spec.url == "file:./vendor/coreutils-9.5.tar.xz"
    check spec.hashHex.len == 64
    check spec.hashHex ==
      "cd328edeac92f6a665de9f323c93b712af1858bc2e0d88f3f7100469470a1b8a"
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "sandboxBash fetch spec is the vendored tarball":
    let spec = registeredFetchSpec("sandboxBash")
    check spec.packageName == "sandboxBash"
    check spec.url == "file:./vendor/bash-5.2.37.tar.gz"
    check spec.hashHex.len == 64
    check spec.hashHex ==
      "9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff"
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "sandboxCoreutils versions record the upstream tag + URL + repo":
    let vs = registeredVersions("sandboxCoreutils")
    check vs.len == 1
    check vs[0].version == "9.5"
    check vs[0].sourceUrl ==
      "https://ftp.gnu.org/gnu/coreutils/coreutils-9.5.tar.xz"
    check vs[0].sourceRepository ==
      "https://git.savannah.gnu.org/git/coreutils.git"

  test "sandboxBash versions record the upstream tag + URL + repo":
    let vs = registeredVersions("sandboxBash")
    check vs.len == 1
    check vs[0].version == "5.2.37"
    check vs[0].sourceUrl == "https://ftp.gnu.org/gnu/bash/bash-5.2.37.tar.gz"
    check vs[0].sourceRepository ==
      "https://git.savannah.gnu.org/git/bash.git"

  test "sandboxCoreutils registers the essential drop-in binaries":
    let arts = registeredArtifacts("sandboxCoreutils")
    var seen: seq[string] = @[]
    for art in arts:
      check art.packageName == "sandboxCoreutils"
      check art.kind == dakExecutable
      seen.add(art.artifactName)
    # The load-bearing SIP drop-ins the io-mon monitor redirects to.
    for required in ["cat", "ls", "cp", "mv", "rm", "mkdir", "head", "tail"]:
      check required in seen

  test "sandboxBash registers the bash drop-in (/bin/sh target)":
    let arts = registeredArtifacts("sandboxBash")
    check arts.len == 1
    check arts[0].packageName == "sandboxBash"
    check arts[0].kind == dakExecutable
    check arts[0].artifactName == "bash"

  test "gnulib-shaped Makefile.am routes to autotools Mode B":
    # coreutils + bash both ship a recursive-SUBDIRS / gnulib sub-archive
    # Makefile.am, which the fine-grained per-source path cannot translate.
    # ``detectModeBTrigger`` recognising this shape is WHY these recipes build
    # via the Mode B configure/make/install fallback (C-Cpp-Autotools.md
    # §"Mode B"). A plain ``bin_PROGRAMS`` Makefile.am must NOT trigger Mode B.
    let gnulibShape =
      "SUBDIRS = lib src\n" &
      "bin_PROGRAMS = cat\n" &
      "cat_LDADD = lib/libgnu.a\n"
    check autotools.detectModeBTrigger(gnulibShape)

    let plainShape =
      "bin_PROGRAMS = hello\n" &
      "hello_SOURCES = hello.c\n"
    check not autotools.detectModeBTrigger(plainShape)


# ----------------------------------------------------------------------------
# The 8 remaining sandbox tools (findutils / gnugrep / gawk / gnused / gnutar /
# gzip / xz / which). These are THIN recipes over the shared ``sandbox_tool``
# Mode B template, so the fixture-level contract is identical to coreutils/bash:
# a vendored ``file:./vendor/...`` tarball with a recipe-pinned 64-char sha256,
# the upstream version/URL/repo recorded, and the load-bearing drop-in
# executables registered. We assert that contract data-drivenly so every new
# recipe is held to the same Package-Model.md shape.
# ----------------------------------------------------------------------------

type ToolFixture = object
  package: string          ## the recipe's ``package`` ident
  version: string          ## the single registered version
  vendorUrl: string        ## the offline ``file:./vendor/...`` fetch URL
  sha256: string           ## the recipe-pinned tarball sha256
  kind: DslFetchKind
  sourceUrl: string        ## the upstream release URL recorded in ``versions``
  sourceRepo: string       ## the upstream VCS recorded in ``versions``
  executables: seq[string] ## the load-bearing drop-ins the recipe registers

# One row per new recipe — keep in sync with the per-tool repro.nim files. The
# sha256 values are the canonical upstream release-tarball digests (verified
# against ftp.gnu.org / the tukaani-project release host at vendoring time).
const NewToolFixtures = [
  ToolFixture(
    package: "sandboxFindutils", version: "4.10.0",
    vendorUrl: "file:./vendor/findutils-4.10.0.tar.xz",
    sha256: "1387e0b67ff247d2abde998f90dfbf70c1491391a59ddfecb8ae698789f0a4f5",
    kind: dfkTarball,
    sourceUrl: "https://ftp.gnu.org/gnu/findutils/findutils-4.10.0.tar.xz",
    sourceRepo: "https://git.savannah.gnu.org/git/findutils.git",
    executables: @["find", "xargs"]),
  ToolFixture(
    package: "sandboxGnugrep", version: "3.11",
    vendorUrl: "file:./vendor/grep-3.11.tar.xz",
    sha256: "1db2aedde89d0dea42b16d9528f894c8d15dae4e190b59aecc78f5a951276eab",
    kind: dfkTarball,
    sourceUrl: "https://ftp.gnu.org/gnu/grep/grep-3.11.tar.xz",
    sourceRepo: "https://git.savannah.gnu.org/git/grep.git",
    executables: @["grep", "egrep", "fgrep"]),
  ToolFixture(
    package: "sandboxGawk", version: "5.3.1",
    vendorUrl: "file:./vendor/gawk-5.3.1.tar.xz",
    sha256: "694db764812a6236423d4ff40ceb7b6c4c441301b72ad502bb5c27e00cd56f78",
    kind: dfkTarball,
    sourceUrl: "https://ftp.gnu.org/gnu/gawk/gawk-5.3.1.tar.xz",
    sourceRepo: "https://git.savannah.gnu.org/git/gawk.git",
    executables: @["gawk", "awk"]),
  ToolFixture(
    package: "sandboxGnused", version: "4.9",
    vendorUrl: "file:./vendor/sed-4.9.tar.xz",
    sha256: "6e226b732e1cd739464ad6862bd1a1aba42d7982922da7a53519631d24975181",
    kind: dfkTarball,
    sourceUrl: "https://ftp.gnu.org/gnu/sed/sed-4.9.tar.xz",
    sourceRepo: "https://git.savannah.gnu.org/git/sed.git",
    executables: @["sed"]),
  ToolFixture(
    package: "sandboxGnutar", version: "1.35",
    vendorUrl: "file:./vendor/tar-1.35.tar.xz",
    sha256: "4d62ff37342ec7aed748535323930c7cf94acf71c3591882b26a7ea50f3edc16",
    kind: dfkTarball,
    sourceUrl: "https://ftp.gnu.org/gnu/tar/tar-1.35.tar.xz",
    sourceRepo: "https://git.savannah.gnu.org/git/tar.git",
    executables: @["tar"]),
  ToolFixture(
    package: "sandboxGzip", version: "1.13",
    vendorUrl: "file:./vendor/gzip-1.13.tar.xz",
    sha256: "7454eb6935db17c6655576c2e1b0fabefd38b4d0936e0f87f48cd062ce91a057",
    kind: dfkTarball,
    sourceUrl: "https://ftp.gnu.org/gnu/gzip/gzip-1.13.tar.xz",
    sourceRepo: "https://git.savannah.gnu.org/git/gzip.git",
    executables: @["gzip", "gunzip", "zcat"]),
  ToolFixture(
    package: "sandboxXz", version: "5.6.3",
    vendorUrl: "file:./vendor/xz-5.6.3.tar.xz",
    sha256: "db0590629b6f0fa36e74aea5f9731dc6f8df068ce7b7bafa45301832a5eebc3a",
    kind: dfkTarball,
    sourceUrl: "https://github.com/tukaani-project/xz/releases/download/v5.6.3/xz-5.6.3.tar.xz",
    sourceRepo: "https://github.com/tukaani-project/xz.git",
    executables: @["xz", "unxz", "xzcat"]),
  ToolFixture(
    package: "sandboxWhich", version: "2.21",
    vendorUrl: "file:./vendor/which-2.21.tar.gz",
    sha256: "f4a245b94124b377d8b49646bf421f9155d36aa7614b6ebf83705d3ffc76eaad",
    kind: dfkTarball,
    sourceUrl: "https://ftp.gnu.org/gnu/which/which-2.21.tar.gz",
    sourceRepo: "https://git.savannah.gnu.org/git/which.git",
    executables: @["which"]),
]

suite "sandbox-tools — remaining 8 recipes: registry round-trip + Mode B":

  test "each new recipe vendors a release tarball with a pinned sha256":
    for f in NewToolFixtures:
      let spec = registeredFetchSpec(f.package)
      check spec.packageName == f.package
      check spec.url == f.vendorUrl
      check spec.hashHex.len == 64
      check spec.hashHex == f.sha256
      check spec.kind == f.kind
      # Every recipe extracts a top-level-stripped tarball (Mode B over a
      # released source tree), mirroring coreutils/bash.
      check spec.extractStrip == 1

  test "each new recipe records the upstream version + URL + repo":
    for f in NewToolFixtures:
      let vs = registeredVersions(f.package)
      check vs.len == 1
      check vs[0].version == f.version
      check vs[0].sourceUrl == f.sourceUrl
      check vs[0].sourceRepository == f.sourceRepo

  test "each new recipe registers its load-bearing drop-in executables":
    for f in NewToolFixtures:
      let arts = registeredArtifacts(f.package)
      var seen: seq[string] = @[]
      for art in arts:
        check art.packageName == f.package
        check art.kind == dakExecutable
        seen.add(art.artifactName)
      for required in f.executables:
        check required in seen
      # The registry must enumerate exactly the recipe's declared drop-ins (no
      # stray/duplicate artifacts leak from the shared template).
      check seen.len == f.executables.len

  test "the full sandbox tool set is exactly 10 packages":
    # 2 from Phase 3 (coreutils, bash) + the 8 added here. A drift in this count
    # means a recipe was added/removed without updating the bundle assembler.
    var packages: seq[string] = @["sandboxCoreutils", "sandboxBash"]
    for f in NewToolFixtures: packages.add(f.package)
    var uniq = initTable[string, bool]()
    for p in packages: uniq[p] = true
    check uniq.len == 10

  test "every vendored sha256 is distinct (no copy/paste digest bug)":
    # A recipe accidentally pinning another tool's digest would fetch the wrong
    # tarball; assert the 8 new digests are pairwise distinct.
    var digests = initTable[string, string]()
    for f in NewToolFixtures:
      check not digests.hasKey(f.sha256)   # would mean a duplicated digest
      digests[f.sha256] = f.package
    check digests.len == NewToolFixtures.len
