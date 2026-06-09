## ``t_semver_range_parsing`` — Spec-Implementation M2c parser test.
##
## Exercises every operator form the ``parseSemverRange`` parser
## supports plus the comma/space combinator. Round-trips the parsed
## bound through the ``Option[SemverVersion]`` surface so the tests
## name the inclusive/exclusive intent explicitly.

import std/[options, unittest]

import repro_solver/version_constraints

suite "semver range parsing":
  test "exact pin parses both with and without operator":
    let r1 = parseSemverRange("1.2.3")
    let r2 = parseSemverRange("==1.2.3")
    let r3 = parseSemverRange("=1.2.3")

    # 1. Bare literal -> inclusive lower at the exact version.
    check r1.lower.isSome
    check r1.lower.get == semver(1, 2, 3)
    # 2. Bare literal -> exclusive upper at the next patch (half-open form).
    check r1.upper.isSome
    check r1.upper.get == semver(1, 2, 4)
    # 3. ``==`` and ``=`` produce the same range as the bare form.
    check r2 == r1
    check r3 == r1

  test "greater-than-or-equal sets only the lower bound":
    let r = parseSemverRange(">=2.2.0")
    check r.lower.isSome
    check r.lower.get == semver(2, 2, 0)
    # 2. Upper is unbounded.
    check r.upper.isNone
    # 3. A version equal to the bound satisfies.
    check satisfies(semver(2, 2, 0), r)

  test "less-than sets only the (exclusive) upper bound":
    let r = parseSemverRange("<3.0.0")
    check r.lower.isNone
    check r.upper.isSome
    check r.upper.get == semver(3, 0, 0)
    # 3. The exclusive upper boundary rejects equality.
    check not satisfies(semver(3, 0, 0), r)

  test "greater-than bumps the inclusive lower bound by a patch":
    let r = parseSemverRange(">1.0.0")
    check r.lower.isSome
    # ``>1.0.0`` is encoded as ``>=1.0.1`` so the lower bound stays
    # inclusive in the half-open invariant.
    check r.lower.get == semver(1, 0, 1)
    check not satisfies(semver(1, 0, 0), r)

  test "less-than-or-equal bumps the exclusive upper":
    let r = parseSemverRange("<=2.0.0")
    check r.upper.isSome
    check r.upper.get == semver(2, 0, 1)
    # 2. The equal point satisfies because the upper is half-open at v+1.
    check satisfies(semver(2, 0, 0), r)
    # 3. The next patch falls outside.
    check not satisfies(semver(2, 0, 1), r)

  test "caret bumps major for >=1.0 inputs":
    let r = parseSemverRange("^1.5.0")
    check r.lower.get == semver(1, 5, 0)
    check r.upper.get == semver(2, 0, 0)
    # 3. ``1.99.0`` is in range, ``2.0.0`` is not.
    check satisfies(semver(1, 99, 0), r)
    check not satisfies(semver(2, 0, 0), r)

  test "caret bumps minor for 0.x inputs":
    let r = parseSemverRange("^0.5.0")
    check r.lower.get == semver(0, 5, 0)
    check r.upper.get == semver(0, 6, 0)
    # 3. ``0.5.99`` is in range, ``0.6.0`` is not.
    check satisfies(semver(0, 5, 99), r)
    check not satisfies(semver(0, 6, 0), r)

  test "caret bumps patch for 0.0.x inputs":
    let r = parseSemverRange("^0.0.3")
    check r.lower.get == semver(0, 0, 3)
    check r.upper.get == semver(0, 0, 4)
    check not satisfies(semver(0, 0, 4), r)

  test "tilde pins minor when minor is present":
    let r = parseSemverRange("~2.1.0")
    check r.lower.get == semver(2, 1, 0)
    check r.upper.get == semver(2, 2, 0)
    check satisfies(semver(2, 1, 5), r)
    check not satisfies(semver(2, 2, 0), r)

  test "tilde with no minor bumps the major":
    let r = parseSemverRange("~2")
    check r.lower.get == semver(2, 0, 0)
    check r.upper.get == semver(3, 0, 0)
    check satisfies(semver(2, 7, 1), r)
    check not satisfies(semver(3, 0, 0), r)

  test "comma combinator intersects two bounds":
    let r = parseSemverRange(">=2.2.0, <3.0.0")
    check r.lower.get == semver(2, 2, 0)
    check r.upper.get == semver(3, 0, 0)
    # 3. ``2.2.0`` is in, ``2.1.9`` is out, ``3.0.0`` is out.
    check satisfies(semver(2, 2, 0), r)
    check not satisfies(semver(2, 1, 9), r)
    check not satisfies(semver(3, 0, 0), r)

  test "space combinator intersects two bounds":
    let r = parseSemverRange(">=2.2 <3.0")
    check r.lower.get == semver(2, 2, 0)
    check r.upper.get == semver(3, 0, 0)
    # 3. The missing patch component defaults to zero.
    check satisfies(semver(2, 2, 0), r)

  test "pre-release literal parses and preserves the tag":
    let v = parseSemver("2.2.4-rc1")
    check v.major == 2
    check v.minor == 2
    check v.patch == 4
    check v.prerelease == "rc1"

  test "v-prefixed versions are accepted":
    let r = parseSemverRange(">=v1.2.0")
    check r.lower.get == semver(1, 2, 0)

  test "missing minor and patch default to zero":
    let v = parseSemver("2")
    check v == semver(2, 0, 0)
    let w = parseSemver("2.5")
    check w == semver(2, 5, 0)

  test "empty input raises ESemverParse":
    var caughtEmpty = false
    var caughtNonDigit = false
    var caughtEmptyRange = false
    try:
      discard parseSemver("")
    except ESemverParse:
      caughtEmpty = true
    try:
      discard parseSemver("1.x.0")
    except ESemverParse:
      caughtNonDigit = true
    try:
      discard parseSemverRange("")
    except ESemverParse:
      caughtEmptyRange = true
    check caughtEmpty
    check caughtNonDigit
    check caughtEmptyRange

  test "trailing dash with empty pre-release raises":
    var caught = false
    try:
      discard parseSemver("1.2.3-")
    except ESemverParse:
      caught = true
    check caught
