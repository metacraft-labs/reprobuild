## Spec-Implementation M3 — ``CrossTarget.splice`` integration test.
##
## Asserts:
##   1. The native adapter's splice is degenerate — each facet of the
##      output ``SplicedPackageSet`` mirrors the input list.
##   2. A non-native ``crossTargetFromTriple`` adapter is non-native
##      and reports the configured triple plus the GNU-style host
##      prefix (``"<triple>-"``).
##   3. The non-native adapter's splice transforms ``hostPkgs`` and
##      ``targetPkgs`` with the triple-specific suffix so adapters can
##      tell the facets apart.
##   4. ``tripleOrEmpty`` returns the triple for non-native targets.

import std/[strutils, unittest]

import repro_dsl_stdlib/interfaces/cross_target
import repro_dsl_stdlib/adapters/native_cross_target

suite "Spec-Implementation M3: CrossTarget splicing":

  test "native splice is degenerate":
    let ct = nativeCrossTarget()
    let spliced = ct.splice(@["nim", "gcc"], @["openssl"], @["libc"])
    check spliced.buildPkgs == @["nim", "gcc"]
    check spliced.hostPkgs == @["openssl"]
    check spliced.targetPkgs == @["libc"]

  test "cross adapter reports triple and prefix":
    let triple = "aarch64-linux-gnu"
    let ct = crossTargetFromTriple(triple)
    validate(ct)
    check not ct.isNative
    check ct.triple == triple
    check ct.targetTriple() == triple
    check ct.hostPrefix() == triple & "-"
    check tripleOrEmpty(ct) == triple
    check ct.cFlags.len > 0
    check "--target=" & triple in ct.cFlags

  test "cross splice transforms host and target facets":
    let triple = "aarch64-linux-gnu"
    let ct = crossTargetFromTriple(triple)
    let spliced = ct.splice(@["nim"], @["openssl", "zlib"], @["libc"])
    check spliced.buildPkgs == @["nim"]
    check spliced.hostPkgs.len == 2
    check spliced.hostPkgs[0].endsWith("-for-" & triple)
    check spliced.targetPkgs.len == 1
    check spliced.targetPkgs[0] == "libc-for-" & triple
