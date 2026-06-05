## Reprobuild repo project file.
##
## A Mode 1 / Mode 3 hybrid (per
## ``reprobuild-specs/Three-Mode-Convention-System.md``):
##
## * Declares the upstream tool dependencies via ``uses:`` so future
##   consumers can ``uses: "reprobuild"`` and pick up the same toolchain
##   floor that the existing ``flake.nix`` provisions today (nim, gcc,
##   just, libblake3, xxhash, sqlite, plus the two source-only fixed
##   inputs nimcrypto-src and runquota-src).
## * Declares ``library reprobuild`` so consumers can express a
##   workspace dependency on this repo with ``uses: "reprobuild"``. The
##   library is the umbrella view of every ``libs/<name>/src`` tree
##   (see ``config.nims`` for the active path list); there is no single
##   ``src/reprobuild.nim`` umbrella because the repo is a fan-out of
##   independent libs the apps wire together explicitly.
## * Declares the eleven shipping executables one-for-one with
##   ``apps/entrypoints.txt``. The Nim-identifier names are camelCase
##   stand-ins for the hyphenated binary names; ``name: "<bin>"``
##   inside each ``executable`` body pins the on-disk artifact.
## * Wraps the existing ``scripts/build_apps.sh`` byte-for-byte in a
##   single ``build:`` action so today's build behaviour is preserved.
##   This is the option-(A) cut described in the repo packaging memo —
##   coarse-grained, opaque, but immediately consistent with what
##   ``just build`` / ``flake.nix`` already do. Option (B) — one
##   ``nim c`` per entrypoint via the DSL's per-entry ``buildAction``
##   primitive — is deferred to a follow-on milestone.
##
## The ``build:`` action inherits ``BLAKE3_PREFIX`` / ``XXHASH_PREFIX``
## / ``SQLITE_PREFIX`` / ``NIMCRYPTO_SRC`` / ``RUNQUOTA_SRC`` /
## ``REPROBUILD_USE_SYSTEM_HASH_LIBS`` from the calling environment, the
## same way the ``flake.nix`` devShell and the existing ``just build``
## drop-in do. The Nix package definition at
## ``nix/pkgs/by-name/re/reprobuild/package.nix`` sets every one of
## those before invoking ``just build``; an interactive developer gets
## them out of the ``nix develop`` shell.

import repro_project_dsl
import repro_dsl_stdlib/packages/sh

# Test-Edges-And-Parallel-Runner M1: ``ct_test_nim_unittest`` is the
# codetracer-side Nim-unittest framework adapter that supplies the
# ``buildNimUnittest.build(...)`` typed-tool used by every entry in
# the generated ``repro.tests.nim`` (included below inside the
# ``package reprobuild:`` body). The module re-exports
# ``repro_project_dsl`` so the import order is fine either way.
# ``config.nims`` adds ``../ct-test/libs/ct_test_nim_unittest/src`` to
# the Nim path.
import ct_test_nim_unittest

package reprobuild:
  uses:
    # Toolchain floor — mirrors flake.nix's nativeBuildInputs.
    "nim >=2.2 <3.0"
    "gcc >=12"
    "just >=1"

    # System hash libraries surfaced as ``uses:`` so consumers picking
    # up ``reprobuild`` inherit the same buildInputs. The Linux/macOS
    # flake.nix provisions these via libblake3 / xxHash / sqlite; the
    # selectors are recorded here even though the package catalog only
    # ships a ``sqlite3`` shape today — unknown selectors are
    # registered without an import, which keeps ``nim check`` green
    # while leaving the constraint visible to anyone resolving the
    # ``uses:`` graph.
    "libblake3"
    "xxhash"
    "sqlite3"

    # Source-only fixed inputs the reprobuild build needs at compile
    # time. ``config.nims`` resolves them via NIMCRYPTO_SRC /
    # RUNQUOTA_SRC env vars, which the flake.nix and the
    # nixpkgs-format package.nix both set before invoking ``just
    # build``.
    "nimcrypto"
    "runquota"

    # The dev-env artifact codec links against nim-ssz-serialization
    # (see config.nims's SSZ_SERIALIZATION_SRC slot).
    "ssz-serialization"

    # Test-Edges-And-Parallel-Runner M1: codetracer-supplied
    # Nim-unittest framework adapter. Each entry in the generated
    # ``repro.tests.nim`` (included below) calls
    # ``buildNimUnittest.build(...)`` from this module so the test
    # binaries become typed-output build edges.
    "ct_test_nim_unittest"

  # Library declaration — every ``.nim`` file under ``libs/<name>/src``
  # that ``config.nims`` adds to ``--path`` is importable when this
  # package is consumed via ``uses: "reprobuild"``. The umbrella is
  # implicit (no single ``src/reprobuild.nim``); consumers import the
  # individual lib modules they need (``import repro_core``,
  # ``import repro_cli_support``, ...).
  library reprobuild

  # Eleven shipping executables, one entry per non-comment line in
  # apps/entrypoints.txt. Nim identifiers are camelCase; the hyphenated
  # on-disk binary name is restored via ``name: "<bin>"``. The order
  # below matches apps/entrypoints.txt to make drift visually obvious.
  executable repro:
    discard

  executable reproFsSnoop:
    name: "repro-fs-snoop"

  executable reproHcrLink:
    name: "repro-hcr-link"

  executable reproController:
    name: "repro-controller"

  executable reproWorker:
    name: "repro-worker"

  executable reproDaemon:
    name: "repro-daemon"

  executable reprostored:
    discard

  executable reproProviderHost:
    name: "repro-provider-host"

  executable reproCmakeDyndepFragment:
    name: "repro-cmake-dyndep-fragment"

  executable reproCmakeTrycompileProvider:
    name: "repro-cmake-trycompile-provider"

  executable reproStandardProvider:
    name: "repro-standard-provider"

  # Test-Edges-And-Parallel-Runner M1: declared typed-output build
  # edges for every ``t_*.nim`` / ``test_*.nim`` file under tests/,
  # libs/*/tests/, and tools/*/tests/. The included file is generated
  # by ``scripts/generate_test_edges.nim``; do not edit it by hand.
  # The file emits its own ``build:`` block (collected by the package
  # macro via ``collectBuildStatements``) plus a final
  # ``aggregate("test", @[...])`` so ``repro build test`` schedules
  # every test-binary compilation in one engine pass.
  include "repro.tests.nim"

  build:
    # Option (A) from the repo packaging memo: wrap scripts/build_apps.sh
    # byte-for-byte so the action's behaviour is identical to ``just
    # build`` today. The action declares the union of source roots the
    # script reads (apps/, libs/, config.nims, reprobuild.nimble) as
    # extra inputs and every ``build/bin/<name>`` artifact as an extra
    # output so a future engine pass can cache-key correctly without
    # re-deriving the inputs.
    #
    # Env vars (BLAKE3_PREFIX / XXHASH_PREFIX / SQLITE_PREFIX /
    # NIMCRYPTO_SRC / RUNQUOTA_SRC / REPROBUILD_USE_SYSTEM_HASH_LIBS)
    # are inherited from the caller. Both the flake.nix and the new
    # nixpkgs-format package.nix at nix/pkgs/by-name/re/reprobuild/
    # set them before invoking this script.
    shell(
      command = "bash scripts/build_apps.sh",
      actionId = "reprobuild.build_apps",
      extraInputs = @[
        "apps/entrypoints.txt",
        "apps",
        "libs",
        "config.nims",
        "reprobuild.nimble",
        "scripts/build_apps.sh",
      ],
      extraOutputs = @[
        "build/bin/repro",
        "build/bin/repro-fs-snoop",
        "build/bin/repro-hcr-link",
        "build/bin/repro-controller",
        "build/bin/repro-worker",
        "build/bin/repro-daemon",
        "build/bin/reprostored",
        "build/bin/repro-provider-host",
        "build/bin/repro-cmake-dyndep-fragment",
        "build/bin/repro-cmake-trycompile-provider",
        "build/bin/repro-standard-provider",
      ])
