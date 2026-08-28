## ``openssl`` — the TLS library `nim c -d:ssl` links against.
##
## Until M8 this entry declared ONLY a ``nixPackage``, which made
## ``uses: "openssl"`` a promise the package kept on two platforms out of
## three. The Windows arm below, and the layout vocabulary in
## ``repro_dsl_stdlib/openssl_layout``, are what make the third one true.
##
## ## Which Windows distribution, and why this one
##
## conda-forge's win-64 package, pinned by sha256. The two candidates were
## conda-forge and MSYS2's ``mingw-w64-x86_64-openssl``; MSYS2 was the
## expected answer and lost on evidence.
##
##   * **`.pkg.tar.zst` is not an archive shape this DSL can fetch.** The
##     ``tarball`` realizer accepts ``tar.gz``/``tgz``, ``tar.xz``/``txz``,
##     ``tar.bz2``/``tbz``/``tbz2``, ``tar``, ``zip``, ``7z``, ``7z.exe``,
##     ``raw`` and ``conda``, and rejects everything else at realize time with
##     "unsupported tarball archiveType" (``repro_tool_profiles.nim``,
##     ``validateTarEntries`` / ``extractTarballArchive``). Pinning an MSYS2
##     package would mean first implementing a zstd tar arm. ``conda`` already
##     exists and is already proven by ``packages/clingo.nim``.
##   * **The ABI objection against conda-forge does not survive testing.**
##     conda-forge builds OpenSSL with MSVC and ships MSVC import libraries
##     (``Library/lib/libssl.lib``, ``Library/lib/libcrypto.lib``) — no
##     ``.dll.a``, no ``.a``. The expectation was that mingw's ``ld`` could not
##     use them. It can: a C file calling ``OPENSSL_init_ssl`` compiled with
##     the WinLibs gcc 15.2.0 this repo builds with, linked
##     ``-L<prefix>/Library/lib -lssl -lcrypto``, resolves against exactly
##     those two ``.lib`` files (confirmed with ``ld -t``) and the resulting
##     executable runs. GNU ld's PE emulation searches ``lib<name>.lib`` and
##     ``<name>.lib`` alongside the mingw spellings.
##   * **Retention.** MSYS2's main repo rotates old versions out, so a pinned
##     ``repo.msys2.org`` URL is expected to 404 eventually — a weakness the
##     MSYS2 proposal named itself. anaconda.org keeps historical builds, and
##     this repo already depends on that property for the clingo pin.
##
## What conda-forge does NOT ship is a static ``libssl.a``. That costs nothing
## here: nothing in this tree links OpenSSL statically, and in fact nothing
## links it at all — see ``openssl_layout``'s note on why ``-lssl -lcrypto``
## on Nim edges are a link-time satisfaction requirement rather than a real
## dependency edge. If a static link is ever needed, that is the point at
## which the zstd tar arm becomes worth building.
##
## ## The retention risk is real for BOTH arms
##
## Pinning by URL + sha256 makes the bytes verifiable, not eternal. If
## conda-forge ever relabels this build the URL moves and the entry stops
## resolving. The mitigation is the one that already applies to every pinned
## artefact in this catalog — reprobuild's own store/binary-cache retention,
## or a vendored mirror via ``tarball``'s ``mirror =`` argument — and not a
## claim that the pin cannot rot.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/prefix_layout

package openssl:
  provisioning:
    nixPackage "nixpkgs#openssl^*", executablePath = "bin/openssl",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

    # Windows: conda-forge win-64, through the same ``conda`` archiveType
    # ``packages/clingo.nim`` uses. The ``.conda`` container is a zip holding
    # ``info-*.tar.zst`` + ``pkg-*.tar.zst``; the archiveType unwraps both
    # layers, so no ``stripComponents`` is wanted — the payload's own
    # ``Library/`` tree IS the prefix shape, and every path below addresses
    # into it through ``prefix_layout`` rather than as a pasted string.
    #
    # sha256 obtained by fetching the artefact and hashing it here, not copied
    # from an index: 9427535 bytes, identical from both the
    # ``anaconda.org/conda-forge/openssl/...`` and
    # ``conda.anaconda.org/conda-forge/win-64/...`` forms.
    tarball url = "https://anaconda.org/conda-forge/openssl/3.6.3/download/win-64/openssl-3.6.3-hf411b9b_1.conda",
      sha256 = "2ebff5a1b5793e82495bf33c91fba040e11ff23333c2385ac66d0c3aee2cc14c",
      archiveType = "conda",
      executablePath = binDir(plConda) & "/openssl.exe",
      packageId = "openssl@3.6.3",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:openssl@3.6.3:sha256:2ebff5a1b5793e82495bf33c91fba040e11ff23333c2385ac66d0c3aee2cc14c"

  # The LOADABLE side of the package, declared for the same reason clingo
  # declares one: the directory a launcher has to make searchable is not the
  # directory the linker resolves against, and on every Windows-shaped layout
  # it is the BIN directory. conda-forge win-64 puts ``libssl-3-x64.dll`` and
  # ``libcrypto-3-x64.dll`` in ``Library/bin`` beside ``openssl.exe``; nixpkgs
  # puts ``libssl.so`` / ``libssl.dylib`` in ``lib``.
  #
  # Declared per stem rather than once, because the name is what a consumer's
  # ``runtimeDeps:`` join reports; the DIR is the same for both.
  runtimeLibrary "ssl", dir = runtimeLibDir(plConda),
    cpu = "x86_64", os = "windows"
  runtimeLibrary "crypto", dir = runtimeLibDir(plConda),
    cpu = "x86_64", os = "windows"
  runtimeLibrary "ssl", dir = runtimeLibDir(plUnix), os = "linux"
  runtimeLibrary "crypto", dir = runtimeLibDir(plUnix), os = "linux"
  runtimeLibrary "ssl", dir = runtimeLibDir(plUnix), os = "macos"
  runtimeLibrary "crypto", dir = runtimeLibDir(plUnix), os = "macos"
