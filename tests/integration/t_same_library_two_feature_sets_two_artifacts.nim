## A library consumed by two applications that select different compile-time
## features is built twice, once per feature set, and the two artifacts
## differ in the feature; a third application that selects the same features
## as the first is served the first one's library without compiling it.
##
## The library is `mathlib`, whose source defines `mul` only when
## `MATHLIB_WITH_MUL` is defined. Each application is its own project (its own
## Git checkout, under its own parent directory) whose build file compiles
## its copy of the library source with the features the application selects
## (`-D<feature>` on the library's compile and on its own), archives it, and
## links itself against it. The three applications are built one after the
## other against one host's action cache and store, with the C toolchain the
## engine realizes into the store root (`--tool-provisioning=tarball`), and
## with no `REPRO_PORTABLE_CACHE` set: the library's compile and archive
## edges take `hybrid` from the `gcc` and `ar` declarations and get the
## default, same-host portable identity.
##
## * `with-mul` selects the feature; its library edges execute.
## * `plain` selects none; its library edges must execute too (another key),
##   and its archive must differ from `with-mul`'s.
## * `with-mul-again` selects the feature, like `with-mul`; its library edges
##   must NOT execute: they resolve `with-mul`'s records, and the archive put
##   in place is byte-identical to `with-mul`'s.
##
## VACUITY GUARD: the two artifacts are asserted to differ in the feature's
## EFFECT, not only in a key or in some byte: `with-mul`'s archive indexes the
## symbol `mul` and `plain`'s does not, and the applications linked against
## them print `5 6` and `5`.
##
## NEGATIVE CONTROL: two applications selecting the same features share one
## artifact. The cache evidence shows one execution of each library edge
## across `with-mul` and `with-mul-again` (`launched` once, then
## `portable-resolved` naming the first execution's strong key).
##
## FALSIFYING MUTATION (run when this test was written, 2026-11-19): dropping every `-D` argument from the
## argv the portable weak fingerprint frames (`portableKeyDescription`) makes
## `plain` resolve `with-mul`'s library records -- a wrong hit, serving an
## archive with `mul` to an application that did not select it -- and this
## test fails on it.
##
## No mocks: the built `repro`, the engine-provisioned GCC and `ar`, real Git
## checkouts at different absolute paths, the real monitor and action cache,
## and the build reports the engine writes. Network: a store that does not
## hold the toolchain yet fetches the pinned archive (102 MB) once; set
## `REPRO_CONFORMANCE_STORE` to pay that once per pin.

import std/[os, strutils, unittest]

import repro_test_support
import library_cache_sharing_fixture

suite "one library, two feature sets, two artifacts":
  test "different features build two libraries; the same features share one":
    var host = newSharedHost("rbc4-features-")
    defer: host.cleanup()
    let withMul = host.scratch / "one" / "with-mul"
    let plain = host.scratch / "two" / "plain"
    let withMulAgain = host.scratch / "three" / "with-mul-again"
    writeFeatureLibraryProject(withMul, "withmul", [MathlibFeature])
    writeFeatureLibraryProject(plain, "plain", [])
    writeFeatureLibraryProject(withMulAgain, "withmulagain", [MathlibFeature])

    let first = host.build(withMul, portable = false,
      provisioning = "tarball")
    checkpoint(first.output)
    checkpoint(allEngineReasons(first))
    require first.code == 0
    let second = host.build(plain, portable = false,
      provisioning = "tarball")
    checkpoint(second.output)
    checkpoint(allEngineReasons(second))
    require second.code == 0
    let third = host.build(withMulAgain, portable = false,
      provisioning = "tarball")
    checkpoint(third.output)
    checkpoint(allEngineReasons(third))
    require third.code == 0

    for run in [first, second, third]:
      require run.hasEdge(LibraryCompileEdge)
      require run.hasEdge(LibraryArchiveEdge)

    # The first application builds its library.
    check first.launched(LibraryCompileEdge)
    check first.launched(LibraryArchiveEdge)
    let firstCompile = first.recordedPortableKey(LibraryCompileEdge)
    let firstArchive = first.recordedPortableKey(LibraryArchiveEdge)
    require firstCompile.weak.len == 64
    require firstArchive.strong.len == 64

    # Another feature set: another key, another build, another artifact.
    check second.launched(LibraryCompileEdge)
    check second.launched(LibraryArchiveEdge)
    let secondCompile = second.recordedPortableKey(LibraryCompileEdge)
    check secondCompile.weak.len == 64
    check secondCompile.weak != firstCompile.weak
    check second.resolvedPortableKey(LibraryCompileEdge) == ""
    check second.resolvedPortableKey(LibraryArchiveEdge) == ""
    let firstLib = withMul / LibraryArchive
    let secondLib = plain / LibraryArchive
    require nonEmptyFile(firstLib)
    require nonEmptyFile(secondLib)
    check not sameBytes(firstLib, secondLib)

    # Vacuity guard: the artifacts differ in what the feature does.
    let firstSymbols = archiveSymbols(firstLib)
    let secondSymbols = archiveSymbols(secondLib)
    checkpoint("with-mul archive symbols: " & firstSymbols.join(", "))
    checkpoint("plain archive symbols: " & secondSymbols.join(", "))
    check "add" in firstSymbols
    check "mul" in firstSymbols
    check "add" in secondSymbols
    check "mul" notin secondSymbols
    check runApplication(withMul) == "5 6"
    check runApplication(plain) == "5"

    # Negative control: the same features share the first artifact, and the
    # library edges executed once between the two applications.
    check not third.launched(LibraryCompileEdge)
    check not third.launched(LibraryArchiveEdge)
    check third.resolvedPortableKey(LibraryCompileEdge) == firstCompile.strong
    check third.resolvedPortableKey(LibraryArchiveEdge) == firstArchive.strong
    check third.recordedPortableKey(LibraryCompileEdge).strong == ""
    check sameBytes(withMulAgain / LibraryArchive, firstLib)
    check "mul" in archiveSymbols(withMulAgain / LibraryArchive)
    check runApplication(withMulAgain) == "5 6"
