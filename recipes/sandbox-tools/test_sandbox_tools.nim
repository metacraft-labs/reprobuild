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

import std/[unittest]

import repro_project_dsl
import repro_standard_provider/conventions/c_cpp_autotools as autotools

# Side-effect imports: the package macros register fetch specs + versions +
# artifacts under ``sandboxCoreutils`` / ``sandboxBash`` at module init.
import ./coreutils/repro
import ./bash/repro

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
