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
# the generated ``repro_tests.nim``. The module re-exports
# ``repro_project_dsl`` so the import order is fine either way.
# ``config.nims`` adds ``../ct-test/libs/ct_test_nim_unittest/src`` to
# the Nim path.
import ct_test_nim_unittest

# Project-DSL-Composition M6: the generated test-edge table.
# ``repro_tests.nim`` exports ``reprobuildTestSpecs*: seq[TestSpec]``;
# the ``build:`` block below iterates the table and registers one
# ``buildNimUnittest.build(...)`` edge per spec, then aggregates the
# resulting actions into the ``test`` target so ``repro build test``
# schedules every test-binary compilation in one engine pass.
#
# Pre-M6 the generated file was ``repro.tests.nim`` and emitted a
# ``build:`` block included from this file. The package macro's
# ``collectBuildStatements`` did not see through ``include`` nodes,
# so the 450+ edges were silently dropped — ``repro build test``
# reported "no named targets in this project". The data + iteration
# migration shape (Approach A from
# ``reprobuild-specs/Project-DSL-Composition.md``) lifts the
# registration into the caller, so the macro sees the typed-tool
# calls and the edges register correctly. The rename also lets Nim
# import the module by name (Nim does not accept dotted module
# identifiers in ``import`` statements).
import repro_tests

package reprobuild:
  # Declare ``path``-mode tool provisioning so the engine adopts it
  # automatically. Without this, ``repro build`` refuses to run with
  # "typed tool provisioning is required for uses declarations" unless
  # the caller passes ``--tool-provisioning=path`` explicitly. The
  # reprobuild dev shell (``nix develop``) and the Nix package both
  # furnish every tool we need via PATH and via env vars
  # (BLAKE3_PREFIX / XXHASH_PREFIX / SQLITE_PREFIX / NIMCRYPTO_SRC /
  # RUNQUOTA_SRC / SSZ_SERIALIZATION_SRC), so the weak-local PATH mode
  # is the right default for this repo.
  defaultToolProvisioning "path"

  uses:
    # Toolchain floor — mirrors flake.nix's nativeBuildInputs. These
    # are the PATH-resolvable binaries the reprobuild build needs;
    # they're sufficient for the path-mode tool resolver to succeed
    # under ``nix develop``.
    "nim >=2.2 <3.0"
    "gcc >=12"
    "just >=1"
    "sh"

    # Bootstrap-And-Self-Build B0: ``runquotad`` is a runtime
    # dependency (spawned as a subprocess by daemon tests at
    # ``../runquota/build/bin/runquotad``). Declaring it in ``uses:``
    # makes the dependency explicit + lets path-mode resolution find
    # the sibling-built binary when ``../runquota/build/bin`` is on
    # ``$PATH``. The sibling ``runquota`` repo now ships its own
    # ``repro.nim`` so later milestones (B1+) can flip this to
    # ``uses: "runquota"`` and consume runquota's typed
    # ``executable runquotad`` output via cross-project resolution;
    # ``runquotad`` (the bare executable selector) is the path-mode
    # form that works today.
    "runquotad"

    # Note: the system hash libraries (libblake3, xxhash, sqlite3) and
    # the source-only fixed inputs (nimcrypto, runquota,
    # ssz-serialization, ct_test_nim_unittest) are NOT listed here.
    # The path-mode resolver requires every ``uses:`` selector to be
    # findable on ``$PATH`` as an executable file, and these are
    # shared libraries, header bundles, or Nim source trees rather
    # than CLI binaries. They are provisioned by ``flake.nix`` /
    # ``nix/pkgs/by-name/re/reprobuild/package.nix`` via env vars
    # (BLAKE3_PREFIX / XXHASH_PREFIX / SQLITE_PREFIX / NIMCRYPTO_SRC /
    # RUNQUOTA_SRC / SSZ_SERIALIZATION_SRC) and consumed by
    # ``config.nims``. Once the DSL grows a typed "env-provided
    # dependency" concept (a ``provides:`` clause, or a Mode 2 catalog
    # shape for header-only / source-only deps) the list above will
    # grow back to capture them; until then the constraints live in
    # ``flake.nix`` and ``config.nims``.

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

  build:
    # Project-DSL-Composition M6: declared typed-output build edges for
    # every ``t_*.nim`` / ``test_*.nim`` file under tests/,
    # libs/*/tests/, and tools/*/tests/. The data table is generated by
    # ``scripts/generate_test_edges.nim`` into ``repro_tests.nim``; this
    # ``for`` loop registers one ``buildNimUnittest.build(...)`` edge
    # per ``TestSpec`` and aggregates the collected actions into the
    # ``test`` target so ``repro build test`` schedules every
    # test-binary compilation in one engine pass.
    #
    # The M5 active-build-context handle is what makes the iteration
    # shape work: each call to ``buildNimUnittest.build(...)`` reads
    # ``currentBuildState()`` to find the active package even though
    # the call now happens inside a runtime ``for`` loop rather than
    # at a literal top-level position in the ``build:`` body.
    var reprobuildTestActions: seq[BuildActionDef] = @[]
    for spec in reprobuildTestSpecs:
      let edge = buildNimUnittest.build(
        source = spec.source,
        binary = spec.binary,
        defines = spec.defines)
      reprobuildTestActions.add(edge.action)
    # Spec-Implementation M0: the ``test`` build graph collection
    # (per reprobuild-specs/Build-Graph-Collections.md). ``repro test``
    # and ``repro build test`` both materialize this collection's
    # closure. Previously expressed as ``aggregate("test", ...)``; the
    # ``collect`` primitive is the build-graph-collection-shaped name
    # for the same data model in M0 (the registry split lands later).
    discard collect("test", reprobuildTestActions)

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
