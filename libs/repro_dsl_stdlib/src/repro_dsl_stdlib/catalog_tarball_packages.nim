## Every built-in catalog module that declares a ``tarball`` arm, imported.
##
## The conformance sweeps of Provisioning-Contributions.md §"Where it is
## enforced" enumerate ``registeredPackages()``, so an arm reaches a sweep
## only if something imported the module that declares it. Nothing did for a
## large part of the catalog, and the consequence was not hypothetical:
##
## * ``package_registry`` links the BUNDLED selectors
##   (``BundledStdlibSelectors``) plus the packages that once carried a
##   ``VersionedProvisioning`` catalog — 108 packages, 181 arms;
## * the catalog declares **227** arms across **101** modules. The 46-arm
##   difference includes every core shell tool a recipe reaches by an explicit
##   import rather than by name: ``rm``, ``cp``, ``mv``, ``mkdir``, ``touch``,
##   ``sed``, ``chmod``, ``sha256sum``, ``printf``, ``tar`` and ``gzip``, ten
##   of which point by hand-written path into one PortableGit archive.
##
## Those ten are the case the issue this module answers calls the sharpest
## exposure: not even the text-level Windows-arm check saw them, because its
## floor list names six tools and none of the ten is among them
## (reprobuild-pm/issues/2026-09-24-no-conformance-check-runs-against-stdlib-tarball-arms.md).
## An arm nothing enumerates passes every gate by being invisible.
##
## So the enrolment is EXPLICIT and CHECKED. The list below is the committed
## enrolment; ``libs/repro_dsl_stdlib/tests/
## t_every_catalog_tarball_arm_is_enrolled_for_conformance.nim`` scans the
## catalog's own source and fails when a module declares an arm and is absent
## here, or when an entry here declares none. A new arm therefore reddens an
## offline gate before anything downloads it.
##
## Importing this module registers all of them. It is deliberately NOT
## imported by the engine: a recipe reaches a package through ``uses:`` or an
## explicit import, and a profile through ``package_registry``. This module
## exists for the checks, which must see the whole catalog rather than the part
## some other consumer happens to link.

import std/macros

import repro_project_dsl

import ./packages_schema
export packages_schema

const CatalogTarballModules* = [
    "addlicense", "alire", "appimage_runtime", "appimagetool", "autoconf",
    "automake", "bash", "bun", "cabal", "capnp", "cargo", "cargo_nextest",
    "cargo_sort", "chocolatey", "circom", "clang", "claude_code", "clingo",
    "clippy", "cmake", "composer", "coreutils_install", "crystal", "curl",
    "dotnet_sdk", "electron_builder_nsis",
    "electron_builder_nsis_resources", "electron_builder_win_code_sign",
    "elixir", "emcc", "ergo", "erlang", "forc", "foundry", "fpc", "gcc",
    "gcc_winlibs", "gh", "ghc", "git", "go", "gradle", "gzip",
    "host_system_tools", "innounp", "jdk", "jq", "just", "lessmsi",
    "libtool", "llvm_mingw", "mailpit", "make", "maven", "mdbook", "meson",
    "mingw_gcc", "mktemp", "msys2_libevent", "msys2_ncurses", "neovim",
    "nim", "nimble", "ninja", "node", "npm", "npx", "nsis", "ocaml",
    "openssl", "perl", "php", "piper", "piper_voice_lessac_medium",
    "piper_voice_lessac_medium_config", "pkg_7zip", "postgresql",
    "python3", "python_dev", "ruby", "rustc", "rustfmt", "rustup", "sh",
    "solc", "stylus", "swift", "swig", "taplo", "tar", "tmux", "uv",
    "wasm_opt", "whisper_ggml_base", "windows_terminal", "winfsp", "wix",
    "wix3", "wix3_tools", "zig", "zstd"
  ]
  ## The ``repro_dsl_stdlib/packages/<module>`` basenames that declare at
  ## least one ``tarball`` arm. Keep it sorted; the gate names the module it
  ## expected when it fails, so adding one is a one-line edit.

macro importCatalogTarballPackages(): untyped =
  ## One ``import repro_dsl_stdlib/packages/<module>`` per entry, generated
  ## from the list so the two cannot disagree. A module imported twice is
  ## initialized once, so overlapping with ``package_registry`` costs nothing.
  result = newStmtList()
  for module in CatalogTarballModules:
    result.add(nnkImportStmt.newTree(
      nnkInfix.newTree(ident("/"),
        nnkInfix.newTree(ident("/"), ident("repro_dsl_stdlib"),
          ident("packages")),
        ident(module))))

importCatalogTarballPackages()
