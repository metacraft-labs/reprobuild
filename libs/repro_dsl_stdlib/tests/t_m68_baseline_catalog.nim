## GM4b: the M68 ``<tool>Catalog`` records are now ``tarball`` realizations
## of each tool's canonical ``package`` definition. The properties below are
## asserted over the records a recipe's ``uses:`` and a home profile select
## from (``profileToolUse``, via ``realization_checks``); the retired
## catalog's "default entry" is what an unpinned reference selects for
## x86_64-windows. The original M68 notes follow.
##
## M68 baseline-catalog test.
##
## Imports every M68-harvested ``packages/<tool>Catalog`` and asserts:
##
##   * ``nim check`` succeeds (implicit — the import itself fails to
##     compile if the file is malformed);
##   * ``validateCatalog`` returns no errors (every slice is well-
##     formed: at least one platform, one sha256/sha512, non-empty
##     ``bin_relpath`` for ``imExtract`` records, etc.);
##   * the catalog seq is non-empty;
##   * ``selectDefault`` returns a populated entry whose ``version``
##     is non-empty.
##
## The list of catalogs walked here is the M68 baseline-tool harvest.
## ``clang`` is DEFERRED — there is no ``clang.json`` in
## ScoopInstaller/Main (only ``clangd.json``); the winlibs / dedicated
## ``ChrisDenton/clang`` buckets fall outside the M68 "main scoop"
## scope. The M70 ``home migrate-from-env-scripts`` synthesizer will
## either pin a hand-curated clang catalog or fall through to the
## host's existing clang install.
##
## **Known M69 realize-time gaps** (catalog passes ``validateCatalog``
## but the M64 ``cakBuiltin`` adapter cannot fully realize the prefix
## as-is; these tools need follow-up provisioning logic in M69 / a
## future M before ``repro home apply`` will succeed for them):
##
##   * ``nim`` — ``post_install`` hook copies
##     ``dist/nimble/src/nimblepkg`` into ``bin/``; ``nimble``
##     invocations from cakBuiltin's prefix will fail to locate the
##     package definitions until M69 wires a post-extract hook runner.
##   * ``git`` — afSevenZip archive (M64 raises
##     ``EBuiltinExtractFailed``) plus ``pre_install`` (restore
##     persisted etc/gitconfig) + ``post_install`` (emit
##     install-context.reg) hooks that cakBuiltin does not run.
##   * ``gcc`` — afSevenZip archive AND a critical ``pre_install``
##     hook that expands nested ``binutils-*.7z`` +
##     ``mingw-w64+gcc.7z`` from inside the outer 7z; without it the
##     realized prefix surfaces no ``bin/gcc.exe``.
##   * ``cmake`` — clean zip, no hooks; should realize cleanly under
##     M64 once afZip support stabilizes. (Originally documented as
##     carrying an ``installer.script: Add-Path`` hook — that hook
##     actually lives in ``nim``'s manifest, not cmake's; correction
##     applied during M68 review.)
##   * ``meson`` — ``afInstallerMsi`` with ``extract_path =
##     PFiles64\\Meson``; M64's afInstallerMsi extractor (if any) must
##     run ``msiexec /a`` administrative-install + flatten the
##     ``PFiles64\\Meson`` subdir.
##   * ``ninja`` — clean zip, no hooks; should realize cleanly under
##     M64 once afZip support stabilizes.
##   * ``node`` — afSevenZip archive + the ``bin/`` prefix in
##     ``bin_relpath`` (synthesized from
##     ``env_add_path = ["bin", "."]``) only exists after Scoop's
##     ``post_install`` runs ``Set-Content`` against
##     ``node_modules/npm/npmrc``. Root-relative entries
##     (``node.exe``, ``npm.cmd``, ``npx.cmd``) resolve on bare
##     extract.
##   * ``python3`` — ``installer.script`` runs Expand-DarkArchive on
##     the ``.exe`` self-extracting MSI bundle. Harvester records
##     ``imExtract + afRaw`` (script-only ``installer`` block treated
##     as a post-extract hook). cakBuiltin would deposit raw
##     ``setup.exe`` at the prefix root without ever extracting it;
##     M69 needs an ``installer.script`` runner OR a
##     ``afSelfExtractingMsi`` archive_format.
##   * ``dotnet_sdk`` — ``env_set`` carries the literal string
##     ``${prefix}\\sdk\\$version\\Sdks`` (Scoop's own ``$version``
##     placeholder is not translated); M69 needs a Scoop-style
##     ``$version`` substitution pass before setting MSBuildSDKsPath.
##   * ``gh`` / ``just`` — clean zips, no hooks; should realize
##     cleanly under M64.
##
## These gaps are EXPECTED and were enumerated up-front in the M68
## hand-off. The catalog files record the manifest truthfully — the
## realization gap belongs to M69, not M68.

import std/[options, unittest]

import ./realization_checks

const M68Tools = ["cmake", "dotnet-sdk", "gcc", "gh", "git", "just", "meson",
  "nim", "ninja", "node", "python3"]

suite "M68 — baseline dev-tool realizations validate":

  test "every harvested tool has archive realizations":
    for name in M68Tools:
      checkpoint name
      check tarballRecordsOf(name).len > 0

  test "every realization is well-formed":
    var failures: seq[string] = @[]
    for name in M68Tools:
      failures.add(realizationProblems(name))
    for f in failures: echo f
    check failures.len == 0

  test "an unpinned reference selects a versioned record per tool":
    for name in M68Tools:
      let picked = unpinnedSelection(name, pcX86_64, poWindows)
      checkpoint name
      check picked.isSome
      if picked.isSome:
        check picked.get.detail.version.len > 0
        check picked.get.executablePath.len > 0

  test "no realization carries two digests":
    for name in M68Tools:
      for r in tarballRecordsOf(name):
        check not (r.sha256.len > 0 and r.detail.sha512.len > 0)

  test "all M68 tools keep a Windows realization":
    ## The M68 baseline harvest is Windows-focused (the env.ps1 deprecation
    ## target is Windows-only).
    for name in M68Tools:
      var sawWindows = false
      for r in tarballRecordsOf(name):
        if r.os == "windows": sawWindows = true
      checkpoint name
      check sawWindows

  test "default versions are non-empty and contain a digit":
    ## Soft guard — the M68 spec ties the default version to what
    ## ``env.ps1`` installed. The format is loose (mingw-winlibs uses
    ## ``16.1.0posix-14.0.0-ucrt-r2``) but it must contain a digit.
    for name in M68Tools:
      let picked = unpinnedSelection(name, pcX86_64, poWindows)
      check picked.isSome
      if picked.isSome:
        var sawDigit = false
        for ch in picked.get.detail.version:
          if ch in {'0' .. '9'}: sawDigit = true
        checkpoint name & " version='" & picked.get.detail.version & "'"
        check sawDigit

  test "nim covers the macOS tarball platforms":
    # GM4b: the in-package statement and the former catalog arm were the
    # same archive; the in-package statement is the single record.
    for cpu in [pcAArch64, pcX86_64]:
      let picked = unpinnedSelection("nim", cpu, poMacos)
      checkpoint $cpu
      check picked.isSome
      if picked.isSome:
        check picked.get.sha256.len == 64
        check picked.get.archiveType == "tar.xz"
        check picked.get.executablePath == "bin/nim"
        check picked.get.detail.version == "2.2.10"
        # The catalog's other tools survived the merge as extras.
        check "bin/nimble" in picked.get.detail.extraExecutables
