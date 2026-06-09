## ``t_semver_satisfies`` — Spec-Implementation M2c version-in-range
## probe test. Focused on boundary cases (inclusive lower vs.
## exclusive upper, pre-release ordering) the encoder relies on when
## grounding ``version_in_range/3``.

import std/[options, unittest]

import repro_solver/version_constraints

suite "semver satisfies":
  test "inclusive lower boundary lets the bound itself satisfy":
    let r = parseSemverRange(">=2.2.0")
    check satisfies(semver(2, 2, 0), r)
    check satisfies(semver(2, 99, 99), r)
    check not satisfies(semver(2, 1, 9), r)

  test "exclusive upper boundary rejects the bound itself":
    let r = parseSemverRange("<3.0.0")
    check satisfies(semver(2, 99, 99), r)
    check not satisfies(semver(3, 0, 0), r)
    check satisfies(semver(0, 0, 1), r)

  test "exact pin only matches the exact version":
    let r = parseSemverRange("1.2.3")
    check satisfies(semver(1, 2, 3), r)
    check not satisfies(semver(1, 2, 4), r)
    check not satisfies(semver(1, 2, 2), r)

  test "pre-release is less than the same stable triple":
    let r = parseSemverRange(">=2.0.0")
    # ``2.0.0-rc1`` is strictly less than ``2.0.0`` per semver.org §11,
    # so the inclusive ``>=2.0.0`` lower bound rejects it.
    check not satisfies(semver(2, 0, 0, "rc1"), r)
    check satisfies(semver(2, 0, 0), r)
    # And it's still less than 2.0.1.
    check satisfies(semver(2, 0, 1, "rc1"), r)

  test "pre-release ordering uses lexicographic compare":
    let v1 = semver(1, 0, 0, "alpha")
    let v2 = semver(1, 0, 0, "beta")
    let v3 = semver(1, 0, 0)
    check v1 < v2
    check v2 < v3
    check not (v3 < v1)

  test "intersection of two operators":
    let r = parseSemverRange(">=2.0, <3.0")
    check satisfies(semver(2, 5, 0), r)
    check not satisfies(semver(1, 9, 9), r)
    check not satisfies(semver(3, 0, 0), r)
    # Boundary on lower is included.
    check satisfies(semver(2, 0, 0), r)

  test "unbounded range satisfies any non-prerelease version":
    let r = SemverRange(lower: none(SemverVersion),
                        upper: none(SemverVersion))
    check satisfies(semver(0, 0, 1), r)
    check satisfies(semver(999, 0, 0), r)
    check satisfies(semver(1, 2, 3, "rc1"), r)

  test "string overload re-parses on each call":
    check satisfies("2.5.0", ">=2.0 <3.0")
    check not satisfies("3.0.0", ">=2.0 <3.0")
    check satisfies("1.2.3", "1.2.3")
