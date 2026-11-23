## M67 bulk-harvest realizations test.
##
## GM4b: the M67-harvested ``<tool>Catalog`` records are now ``tarball``
## realizations of each tool's canonical ``package`` definition. This test
## walks the M67 tool set and asserts, over the records a recipe's ``uses:``
## and a home profile actually select from (``profileToolUse``):
##
##   * every tool is a linked definition with at least one archive
##     realization;
##   * every realization is well-formed (``realization_checks.
##     recordProblems``: url, exactly one valid digest, executable, version,
##     readable coordinate / install method / env / pre-install / launcher
##     entries, and a realizer that performs everything it asks for);
##   * an unpinned reference on x86_64-windows selects a versioned record —
##     the "default entry" of the retired catalog;
##   * every tool keeps a Windows realization (the M49-M62 tool set is
##     Windows-focused).
##
## **Known M69 realize-time gaps** (catalog passes ``validateCatalog``
## but the M64 ``archive realizer`` adapter cannot realize the prefix as-is;
## these tools need follow-up provisioning logic in M69 / a future M
## before ``repro home apply`` will succeed for them):
##
##   * ``swift`` — manifest URL is a ``.exe`` MSI installer. The
##     harvester records ``afRaw + imExtract`` (the format sniffer
##     can't tell NSIS from MSI from the ``.exe`` extension alone);
##     the upstream Scoop pre_install runs ``Expand-DarkArchive`` to
##     flatten the MSI into ``Toolchains/`` + ``Runtimes/``. archive realizer
##     would deposit the raw .exe at the prefix root — ``bin_relpath``
##     entries will not resolve. M69 needs an MSI-flatten hook.
##   * ``composer`` — ``bin_relpath = @["composer.ps1"]`` but the
##     manifest fetches a ``.phar`` and Scoop's pre_install generates
##     the ``.ps1`` shim. archive realizer produces no ``composer.ps1``.
##     M69 needs a generic launcher-emit hook OR the catalog needs to
##     point at ``composer.phar`` directly.
##   * ``ruby`` / ``erlang`` — ``afSevenZip`` archives; the M64
##     archive realizer raises ``EBuiltinExtractFailed`` (no 7z dispatch).
##     M69 (or a follow-up M) must add a 7z extractor.
##
## These are EXPECTED for the M49–M62 toolchains and were called out
## up front in the M67 review (scrutiny C/D/E). The catalog files
## record the manifest truthfully — the realization gap belongs to
## M69, not M67.

import std/[options, unittest]

import ./realization_checks

const M67Tools = ["cabal", "composer", "crystal", "elixir", "erlang", "ghc",
  "gradle", "maven", "php", "ruby", "swift", "zig"]

suite "M67 — bulk-harvested realizations validate":

  test "every harvested tool has archive realizations":
    for name in M67Tools:
      checkpoint name
      check tarballRecordsOf(name).len > 0

  test "every realization is well-formed":
    var failures: seq[string] = @[]
    for name in M67Tools:
      failures.add(realizationProblems(name))
    for f in failures: echo f
    check failures.len == 0

  test "an unpinned reference selects a versioned record per tool":
    for name in M67Tools:
      let picked = unpinnedSelection(name, pcX86_64, poWindows)
      checkpoint name
      check picked.isSome
      if picked.isSome:
        check picked.get.detail.version.len > 0
        check picked.get.executablePath.len > 0

  test "no realization carries two digests":
    for name in M67Tools:
      for r in tarballRecordsOf(name):
        check not (r.sha256.len > 0 and r.detail.sha512.len > 0)

  test "every M67 tool keeps a Windows realization":
    for name in M67Tools:
      var sawWindows = false
      for r in tarballRecordsOf(name):
        if r.os == "windows": sawWindows = true
      checkpoint name
      check sawWindows
