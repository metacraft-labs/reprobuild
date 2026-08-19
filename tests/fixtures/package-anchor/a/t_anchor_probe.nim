## Fixture for ``tests/unit/test_package_root_anchor.py``.
##
## The copies under ``a/`` and ``b/`` are BYTE-IDENTICAL and share a
## basename on purpose: they are the two same-named sources in different
## directories that the guard compiles to prove the package-root anchor is
## still doing its job. Keep them identical — the guard diffs them and fails
## if they are not.
##
## Each case is compiled as its OWN main module, the way every reprobuild test
## binary is built, because that is the configuration in which a
## ``projectPath``-relative rendering silently degrades to a bare basename.
##
## Lives under ``tests/fixtures/`` so ``scripts/generate_test_edges.nim``
## does not enrol it as a suite test (see ``acceptTestsTree``).

import std/unittest

suite "package anchor probe":
  test "location-bearing body":
    # ``check`` plants its location in the expanded body as a string literal,
    # and ``sighashes.hashBodyTree`` hashes string literals verbatim, so this
    # case's ``bodyHash`` is a direct readout of how that location rendered.
    let x = 1
    check x == 1

  test "no location literal":
    # Control: no assertion macro, therefore no location literal, therefore
    # this case MUST hash identically in ``a/`` and ``b/``. If it ever stops
    # doing so, the two fixtures have drifted apart and the guard is no longer
    # comparing what it thinks it is comparing.
    var x = 1
    x = x + 1
    if x != 2: quit 1

  test "failing check":
    # Deliberately fails, so the guard can read the rendered location out of
    # the human-facing failure message rather than only out of a hash.
    let x = 2
    check x == 1
