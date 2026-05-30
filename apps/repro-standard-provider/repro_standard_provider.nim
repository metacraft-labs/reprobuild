## Standard provider binary for convention-only packages (Tier 2b).
##
## The Reprobuild engine routes any package whose declaration omits a
## ``build:`` block to this binary instead of compiling a per-project
## ``reprobuild.nim``. The binary walks the package's source tree
## following the ecosystem's conventional layout and emits the build
## graph directly.
##
## Per Provider-Compile-Tiering.md §"2b — repro-standard-provider" and
## Language-Conventions/README.md.
##
## **M1 framework.** Manifest requests advertise a single canonical
## entry point — ``StandardProviderRootEntryPointId`` — from the shared
## ``repro_standard_provider_protocol`` library (the manifest's shape
## doesn't depend on conventions — see
## Standard-Provider-Implementation.milestones.org §M1). Graph requests
## dispatch through ``defaultConventionRegistry``; on the first
## ``recognize`` hit the convention's ``emitFragment`` produces the
## fragment, otherwise we exit non-zero with a "no convention matched"
## diagnostic that names the project root and the package's ``uses:``
## hint (parsed heuristically — see project_intro.nim). Per-language
## convention plugins land in M3+.

import std/[options, os, strutils]

import repro_provider_runtime
import repro_standard_provider/convention
import repro_standard_provider/conventions/nim as nim_convention
import repro_standard_provider/conventions/rust as rust_convention
import repro_standard_provider/conventions/rust_direct as rust_direct_convention
import repro_standard_provider/conventions/go as go_convention
import repro_standard_provider/conventions/go_direct as go_direct_convention
import repro_standard_provider/conventions/python as python_convention
import repro_standard_provider/conventions/python_direct as python_direct_convention
import repro_standard_provider/conventions/javascript_typescript as jsts_convention
import repro_standard_provider/conventions/jsts_direct as jsts_direct_convention
import repro_standard_provider/conventions/c_cpp_make as c_cpp_make_convention
import repro_standard_provider/conventions/c_cpp_autotools as c_cpp_autotools_convention
import repro_standard_provider/conventions/c_cpp_cmake as c_cpp_cmake_convention
import repro_standard_provider/conventions/c_cpp_meson as c_cpp_meson_convention
import repro_standard_provider/conventions/java_maven as java_maven_convention
import repro_standard_provider/conventions/kotlin_gradle as kotlin_gradle_convention
import repro_standard_provider/conventions/csharp_dotnet as csharp_dotnet_convention
import repro_standard_provider/conventions/swift_swiftpm as swift_swiftpm_convention
import repro_standard_provider/conventions/c_cpp_direct as c_cpp_direct_convention
import repro_standard_provider/conventions/fortran_direct as fortran_direct_convention
import repro_standard_provider/conventions/zig_direct as zig_direct_convention
import repro_standard_provider/conventions/d_direct as d_direct_convention
import repro_standard_provider/conventions/ada_direct as ada_direct_convention
import repro_standard_provider/conventions/pascal_direct as pascal_direct_convention
import repro_standard_provider/conventions/crystal as crystal_convention
import repro_standard_provider/conventions/erlang_rebar3 as erlang_rebar3_convention
import repro_standard_provider/conventions/ocaml_dune as ocaml_dune_convention
import repro_standard_provider/conventions/haskell_cabal as haskell_cabal_convention
import repro_standard_provider/conventions/ruby_bundler as ruby_bundler_convention
import repro_standard_provider/conventions/php_composer as php_composer_convention
import repro_standard_provider/project_intro
import repro_standard_provider_protocol

const
  StandardProviderVersion = "0.0.2-m1-framework"
    ## Bump whenever ``--version`` output should change for release
    ## tracking. Engine routing keys off
    ## ``StandardProviderArtifactId``, not this string — this exists
    ## for humans inspecting the binary.

proc parseEarlyFlags(args: openArray[string]): tuple[wantVersion: bool] =
  for arg in args:
    if arg == "--version":
      result.wantVersion = true
      return

proc placeholderManifest(providerArtifactId: string): ProviderManifest =
  ## Manifest the standard provider advertises. The single canonical
  ## entry point uses ``StandardProviderRootEntryPointId`` — the engine
  ## (M2) dispatches on that id, and the M0/M1 smoke + no-match scripts
  ## now use it too (the legacy ``standardProvider.placeholder`` alias
  ## was dropped after M3 once real conventions are registered). Engine
  ## validation requires the returned ``providerArtifactId`` to match
  ## the request when the request supplied one; falling back to
  ## ``StandardProviderArtifactId`` keeps stand-alone smoke runs working
  ## when the caller leaves it empty.
  ProviderManifest(
    providerArtifactId:
      if providerArtifactId.len > 0: providerArtifactId
      else: StandardProviderArtifactId,
    protocolVersion: ProviderProtocolVersion,
    entryPoints: @[
      GraphEntryPointDescriptor(
        id: StandardProviderRootEntryPointId,
        kind: gpkProjectRoot,
        stableName: StandardProviderPackageName,
        bodyHash: StandardProviderRootBodyHash,
        argumentSchemaId: "reprobuild.project-root.v1",
        outputSchemaId: "reprobuild.graph-fragment.v1")
    ])

proc projectRootFromRequest(request: ProviderGraphRequest): string =
  ## At M1 the engine passes the project root via ``request.arguments``
  ## as a bare path string — same shape the Tier 2c trycompile provider
  ## uses. M2 will replace this with an interface-artifact handle.
  request.arguments.strip()

proc formatUsesHint(uses: seq[string]): string =
  if uses.len == 0:
    "(none declared)"
  else:
    uses.join(", ")

proc noConventionMatchedMessage(projectRoot: string;
                                uses: seq[string]): string =
  ## Diagnostic message emitted when no convention recognises the
  ## project. The substring ``"no convention matched"`` is part of the
  ## contract — ``scripts/validate-standard-provider-no-match.ps1``
  ## greps for it.
  "repro-standard-provider: no convention matched for project root '" &
    projectRoot & "' (uses: " & formatUsesHint(uses) & ")"

proc dispatchGraphRequest(request: ProviderGraphRequest):
    tuple[fragment: GraphFragment; matched: bool; projectRoot: string;
          uses: seq[string]] =
  ## Look up the first matching convention against
  ## ``defaultConventionRegistry`` and delegate to it. ``matched=false``
  ## tells the caller to emit the diagnostic and exit non-zero.
  let projectRoot = projectRootFromRequest(request)
  let uses = readUsesHint(projectRoot)
  let hit = firstMatchingConvention(defaultConventionRegistry,
    projectRoot, request)
  if hit.isSome:
    var fragment = hit.get.emitFragment(projectRoot, request)
    # Make sure the convention's emitFragment didn't forget to echo
    # back the request's identity — the engine cross-checks these.
    if fragment.entryPointId.len == 0:
      fragment.entryPointId = request.entryPointId
    if fragment.entryPointBodyHash.len == 0:
      fragment.entryPointBodyHash = request.entryPointBodyHash
    if fragment.arguments.len == 0:
      fragment.arguments = request.arguments
    if fragment.namespace.len == 0:
      fragment.namespace = request.namespace
    if fragment.fragmentDigest.len == 0:
      fragment.fragmentDigest = computeGraphFragmentDigest(fragment)
    return (fragment, true, projectRoot, uses)
  let empty = GraphFragment(
    entryPointId: request.entryPointId,
    entryPointBodyHash: request.entryPointBodyHash,
    arguments: request.arguments,
    namespace: request.namespace)
  (empty, false, projectRoot, uses)

when defined(reproProviderMode):
  # Register the language convention plugins this binary ships with.
  # The Nim convention is the first one to land (M3); the Rust
  # convention (M4) follows, the Go convention (M5) after that, the
  # Python convention (M15), the JavaScript/TypeScript convention
  # (M16), and the C/C++ Make + Autotools conventions (M17) close out
  # the milestone series' Mode A first wave. Future milestones add
  # CMake direct / etc. here in registration-order which is also
  # match-order. The list of registered conventions MUST stay in sync
  # with ``RegisteredStandardConventionToolchains`` in
  # ``libs/repro_interface_artifacts/src/repro_interface_artifacts.nim``
  # — the engine should only mark a package as standardBuildEligible
  # when at least one registered convention is plausibly going to match
  # it.
  #
  # Registration order between c-cpp-make and c-cpp-autotools matters:
  # c-cpp-autotools is registered FIRST so a project carrying both a
  # Makefile (generated or hand-written) and ``configure.ac`` /
  # ``Makefile.am`` routes through the Autotools convention. The
  # c-cpp-make ``recognize`` separately rejects projects with Autotools
  # artefacts so the order is defensive in either direction.
  addDefaultConvention(nim_convention.nimConvention())
  addDefaultConvention(rust_convention.rustConvention())
  addDefaultConvention(go_convention.goConvention())
  addDefaultConvention(python_convention.pythonConvention())
  addDefaultConvention(jsts_convention.javaScriptTypeScriptConvention())
  addDefaultConvention(c_cpp_autotools_convention.cCppAutotoolsConvention())
  # c_cpp_cmake (M38) registered BEFORE c_cpp_make so CMake claims any
  # project with a root-level CMakeLists.txt before the Make convention
  # gets a chance (the Make convention separately rejects projects with
  # ``CMakeLists.txt`` at the root, so the order is defensive in either
  # direction). c_cpp_cmake is the lightweight Tier 2b convention that
  # shells out to a stock ``cmake`` binary for configure + per-member
  # build. The heavier Tier 2c trycompile path
  # (apps/repro-cmake-trycompile-provider.exe) remains for projects that
  # need try_compile probes lifted into the reprobuild DAG; users opt
  # into Tier 2c via explicit provider declaration.
  addDefaultConvention(c_cpp_cmake_convention.cCppCMakeConvention())
  # c_cpp_meson (M39) registered AFTER c_cpp_cmake and BEFORE
  # c_cpp_make so Meson claims any project with a root-level
  # ``meson.build`` before the Make convention gets a chance. CMake
  # registers first because a project carrying BOTH ``CMakeLists.txt``
  # and ``meson.build`` is almost always primarily a CMake project
  # exporting a Meson side-build for some downstream consumer; the
  # Meson convention's ``recognize`` rejects when ``CMakeLists.txt`` is
  # present so the order is defensive in either direction. Like the
  # CMake convention, this is the lightweight Tier 2b path that shells
  # out to a stock ``meson`` + ``ninja`` for configure + per-member
  # build.
  addDefaultConvention(c_cpp_meson_convention.cCppMesonConvention())
  addDefaultConvention(c_cpp_make_convention.cCppMakeConvention())
  # java_maven (M40) — first JVM-ecosystem Tier 2b convention. Keys on
  # ``pom.xml`` at the project root; no overlap with the C/C++
  # conventions above (none of them recognise ``pom.xml``). Registration
  # position is alphabetical-by-language ('j' after 'c') but the
  # position has no recognition consequence — the convention's
  # recognition gate is closed-set on ``pom.xml`` presence + a
  # ``mvn``/``maven`` + ``java``/``jdk`` ``uses:`` declaration. Defers
  # to a future Gradle convention (M41) when both ``pom.xml`` AND
  # ``build.gradle[.kts]`` are present at the root (unusual but legal —
  # the Maven convention's ``recognize`` rejects in that case).
  addDefaultConvention(java_maven_convention.javaMavenConvention())
  # kotlin_gradle (M41) — second JVM-ecosystem Tier 2b convention.
  # Keys on ``build.gradle.kts`` or ``build.gradle`` at the project root
  # (Kotlin DSL preferred). Registered AFTER java_maven so a project
  # carrying BOTH ``pom.xml`` AND ``build.gradle[.kts]`` (unusual but
  # legal — usually a transient migration state) routes through the
  # Maven convention first. The kotlin_gradle convention's ``recognize``
  # additionally rejects projects with ``pom.xml`` at the root, so the
  # order is defensive in either direction. Registration position is
  # alphabetical-by-language ('k' after 'j') and the position has no
  # recognition consequence — the convention's recognition gate is
  # closed-set on ``build.gradle[.kts]`` presence + a
  # ``gradle``/``kotlin`` + ``java``/``jdk`` ``uses:`` declaration.
  addDefaultConvention(kotlin_gradle_convention.kotlinGradleConvention())
  # csharp_dotnet (M42) — third managed-runtime-ecosystem Tier 2b
  # convention. Keys on a single ``*.csproj`` at the project root plus
  # a HARD precondition ``packages.lock.json`` (the M42 offline-build
  # guarantee per the spec). Registered AFTER kotlin_gradle so the
  # JVM-ecosystem conventions form a contiguous block, then the
  # .NET-ecosystem convention follows; the order has no recognition
  # consequence because each convention's recognition gate is
  # closed-set on its own ecosystem's manifest (``*.csproj`` is unique
  # to .NET — no other convention recognises it). The convention's
  # ``recognize`` additionally rejects projects with ``*.fsproj`` at
  # the root (deferred future F# convention's territory). Registration
  # position is alphabetical-by-language ('c' is before 'j'/'k' but
  # the C# convention follows the JVM block here because that block is
  # the closest precedent — same lightweight Mode 2 ecosystem-
  # delegation shape).
  addDefaultConvention(csharp_dotnet_convention.csharpDotnetConvention())
  # swift_swiftpm (M43) — fourth managed-ecosystem Tier 2b convention.
  # Keys on a single ``Package.swift`` at the project root (the SwiftPM
  # package manifest filename — uniquely identifies a SwiftPM package;
  # no other convention recognises this filename). Registered AFTER
  # csharp_dotnet so the managed-ecosystem block forms a contiguous
  # cluster (Maven → Gradle → .NET → SwiftPM). The order has no
  # recognition consequence — each convention's recognition gate is
  # closed-set on its own ecosystem's manifest. The convention requires
  # a ``swift`` driver on PATH; when the Swift toolchain is absent
  # (which is the default on the M43 review host — Swift Windows isn't
  # in the standard dev shell) ``recognize`` returns false and the
  # M9-style harness SKIPs cleanly. Registration position is
  # alphabetical-by-language ('s' is after 'c') and follows the M43
  # spec's "register after csharp-dotnet in the chain" sequencing.
  addDefaultConvention(swift_swiftpm_convention.swiftSwiftpmConvention())
  # c_cpp_direct (Mode 3 / no-Makefile) is registered LAST among the
  # C/C++ conventions so a project shipping a Makefile routes through
  # the Make convention first; Mode 3 picks up the no-Makefile case
  # where the user declared their project shape in ``repro.nim`` with
  # no ecosystem manifest at all.
  addDefaultConvention(c_cpp_direct_convention.cCppDirectConvention())
  # rust_direct (Mode 3 / no-Cargo.toml) registered AFTER the Mode 2
  # rust convention so a project shipping a Cargo.toml routes through
  # the Mode 2 path first; Mode 3 picks up the case where the user
  # declared their crate shape in ``repro.nim`` with no Cargo
  # manifest. M30 of Mode3-Language-Expansion.milestones.org.
  addDefaultConvention(rust_direct_convention.rustDirectConvention())
  # go_direct (Mode 3 / no-go.mod) registered AFTER the Mode 2 go
  # convention so a project shipping a go.mod routes through the
  # Mode 2 path first; Mode 3 picks up the case where the user
  # declared their package shape in ``repro.nim`` with no Go module
  # manifest. M31 of Mode3-Language-Expansion.milestones.org.
  addDefaultConvention(go_direct_convention.goDirectConvention())
  # python_direct (Mode 3 / no-pyproject.toml) registered AFTER the
  # Mode 2 python convention so a project shipping a pyproject.toml
  # routes through the Mode 2 path first; Mode 3 picks up the case
  # where the user declared their package shape in ``repro.nim`` with
  # no Python build-system manifest. M32 of
  # Mode3-Language-Expansion.milestones.org.
  addDefaultConvention(python_direct_convention.pythonDirectConvention())
  # jsts_direct (Mode 3 / no-package.json) registered AFTER the Mode 2
  # javascript_typescript convention so a project shipping a
  # package.json (or tsconfig.json / vite.config.* / webpack.config.*
  # / etc.) routes through the Mode 2 path first; Mode 3 picks up the
  # case where the user declared their JS/TS member shape in
  # ``repro.nim`` with no ecosystem manifest. M33 of
  # Mode3-Language-Expansion.milestones.org.
  addDefaultConvention(jsts_direct_convention.jsTsDirectConvention())
  # fortran_direct (Mode 3, minimal Fortran) — registered AFTER all
  # the other Mode 3 conventions per M37 of
  # Mode3-Language-Expansion.milestones.org. There is no Mode 2 Fortran
  # convention sibling yet (fpm.toml recognition is deferred); this is
  # the only Fortran convention today. Registration order matters only
  # for mixed Fortran + C/C++ workspaces — c-cpp-direct defers to
  # fortran-direct when ``uses:`` anywhere names ``gfortran``/``fortran``,
  # mirroring the rust-direct / go-direct pattern.
  addDefaultConvention(fortran_direct_convention.fortranDirectConvention())
  # zig_direct (Mode 3 / no-build.zig) — registered AFTER all the other
  # Mode 3 conventions per M44 of
  # Mode3-Language-Expansion.milestones.org. There is no Mode 2 Zig
  # convention sibling yet (build.zig recognition is deferred per the
  # M44 honest-scope cut); this is the only Zig convention today.
  # Registration order matters only for mixed Zig + C/C++ workspaces —
  # c-cpp-direct defers to zig-direct when ``uses:`` anywhere names
  # ``zig`` AND no ``build.zig`` is present at the workspace root,
  # mirroring the rust-direct / go-direct / fortran-direct pattern.
  addDefaultConvention(zig_direct_convention.zigDirectConvention())
  # d_direct (Mode 3 / no-dub.json/sdl) — registered AFTER all the
  # other Mode 3 conventions per M45 of
  # Mode3-Language-Expansion.milestones.org. There is no Mode 2 D
  # convention sibling yet (dub.json/dub.sdl recognition is deferred
  # per the M45 honest-scope cut); this is the only D convention
  # today. Registration order matters only for mixed D + C/C++
  # workspaces — c-cpp-direct defers to d-direct when ``uses:``
  # anywhere names ``d``/``dmd``/``ldc2``/``gdc`` AND no
  # ``dub.json`` / ``dub.sdl`` is present at the workspace root,
  # mirroring the rust-direct / go-direct / fortran-direct /
  # zig-direct pattern.
  addDefaultConvention(d_direct_convention.dDirectConvention())
  # ada_direct (Mode 3 / no-*.gpr) — registered AFTER d-direct per M58
  # of Provisioning-And-Languages-Expansion.milestones.org. Ada is the
  # seventh Mode 3 language and the first Phase 2 obj+linker language —
  # the convention extends the cross-language matrix on the canonical
  # ``<root>/.repro/build/<name>/lib<name>.a`` schema shared with
  # c-cpp-direct, rust-direct, fortran-direct, zig-direct, d-direct.
  # There is no Mode 2 Ada convention sibling yet (.gpr / gprbuild
  # recognition is deferred per the M58 honest-scope cut); this is the
  # only Ada convention today. Registration order matters only for
  # mixed Ada + C/C++ workspaces — c-cpp-direct defers to ada-direct
  # when ``uses:`` anywhere names ``ada``/``gnat``/``gnatmake`` AND no
  # ``*.gpr`` is present at the workspace root, mirroring the
  # rust-direct / go-direct / fortran-direct / zig-direct / d-direct
  # pattern.
  addDefaultConvention(ada_direct_convention.adaDirectConvention())
  # pascal_direct (Mode 3 / no-*.lpi) — registered AFTER ada-direct per
  # M59 of Provisioning-And-Languages-Expansion.milestones.org. Pascal
  # is the eighth Mode 3 language — the convention extends the
  # cross-language matrix on the canonical
  # ``<root>/.repro/build/<name>/lib<name>.a`` schema shared with
  # c-cpp-direct, rust-direct, fortran-direct, zig-direct, d-direct,
  # ada-direct. There is no Mode 2 Pascal convention sibling yet
  # (.lpi / lazbuild recognition is deferred per the M59 honest-scope
  # cut); this is the only Pascal convention today. Registration order
  # matters only for mixed Pascal + C/C++ workspaces — c-cpp-direct
  # defers to pascal-direct when ``uses:`` anywhere names
  # ``pascal``/``fpc``/``freepascal`` AND no ``*.lpi`` is present at
  # the workspace root, mirroring the rust-direct / go-direct /
  # fortran-direct / zig-direct / d-direct / ada-direct pattern.
  addDefaultConvention(pascal_direct_convention.pascalDirectConvention())
  # crystal (M60) — Tier 2b convention covering BOTH Mode 2 (shards-
  # managed via ``shard.yml`` + ``shard.lock``) AND Mode 3 (pure source,
  # no ``shard.yml``) Crystal workspaces via in-procedure mode
  # detection. Single convention rather than two siblings per the M60
  # hand-off (Option A) — the recognise + emit halves dispatch on
  # ``shard.yml`` presence at the project root.
  #
  # Registered AFTER pascal-direct in the dispatch chain — registration
  # order matters only for mixed-language workspaces (Crystal alongside
  # another language). The convention's recognise gate keys on a
  # ``crystal`` / ``shards`` token in ``uses:`` so Crystal-flavoured
  # workspaces unambiguously claim dispatch.
  #
  # **Honest-scope cut** (M60): Mode 3 emits ONE ``crystal build``
  # action per executable (whole-program analysis — no per-source
  # ``-c`` DAG possible until Crystal grows a ``-c``-equivalent flag).
  # Library targets, ``lib LibFoo`` cross-language with C/C++, and the
  # ``require`` scanner are explicitly DEFERRED. The convention SKIPs
  # cleanly when ``crystal`` isn't on PATH (which is the M60 default
  # on Windows — env.ps1 doesn't yet provision Crystal; a follow-up
  # provisioning milestone covers that).
  addDefaultConvention(crystal_convention.crystalConvention())
  # erlang_rebar3 (M61) — Erlang/OTP Tier 2b convention. Seventh Phase 2
  # language milestone, immediately after M60 crystal. Keys on a
  # ``rebar.config`` (rebar3 manifest) at the project root and
  # additionally requires ``rebar.lock`` (HARD precondition per the M61
  # spec — rebar3 writes a lockfile on every compile, even for zero-
  # deps projects, mirroring the M42 / M55 / M56 / M57 / M60 lockfile-
  # required pattern). Registered AFTER crystal per the M61 spec's
  # "register after crystal in the chain" sequencing — the Phase 2
  # conventions form a contiguous block below the Phase 1 cluster. The
  # order has no recognition consequence — the convention's recognition
  # gate is closed-set on ``rebar.config`` + ``rebar.lock`` presence +
  # an Erlang/rebar3 token (``erlang``/``erl``/``rebar3``) in
  # ``uses:``. rebar3 ships alongside Erlang/OTP in most distribution
  # channels so the ``uses:`` check is single-token (mirroring M30
  # Rust's ``rust``-or-``cargo`` pattern, M56 ruby-bundler's
  # ``ruby``-or-``bundler``, M57 php-composer's ``php``-or-``composer``,
  # and M60 crystal's ``crystal``-or-``shards`` patterns rather than
  # M55 haskell-cabal's strict "both halves required" pattern). The
  # convention requires both ``erl`` AND ``rebar3`` drivers on PATH;
  # when either is absent (which is the M61 default on Windows
  # before ``scoop install erlang rebar3``) ``recognize`` returns
  # false and the M9-style harness SKIPs cleanly. Library / OTP-only
  # targets, ``rebar3 release`` packaging, ``rebar3 ct`` test
  # discovery, NIFs, erlang.mk sibling, and external Hex deps
  # cache-warm are all explicitly DEFERRED per the M61 honest-scope
  # cut — M61 supports app-style ``rebar.config`` + ``rebar3
  # escriptize`` only.
  addDefaultConvention(erlang_rebar3_convention.erlangRebar3Convention())
  # ocaml_dune (M46) — fifth managed-ecosystem Tier 2b convention. Keys
  # on a single ``dune-project`` at the project root (the Dune project
  # manifest filename — uniquely identifies a Dune project; no other
  # convention recognises this filename). Registered AFTER d_direct per
  # the M46 spec's "register after d-direct in the chain" sequencing —
  # the spec treats ocaml-dune as a late-registration Mode 2 convention
  # so the Mode 3 conventions block contiguously above it. The order has
  # no recognition consequence — the convention's recognition gate is
  # closed-set on ``dune-project`` presence + an OCaml token AND a
  # ``dune`` token in ``uses:`` (the HARD precondition pattern, mirroring
  # M40 java-maven's "both halves required"). The convention requires
  # both ``ocaml`` AND ``dune`` drivers on PATH; when either is absent
  # (which is the M46 default on Windows — the dev shell doesn't bundle
  # OCaml) ``recognize`` returns false and the M9-style harness SKIPs
  # cleanly. Mode 3 OCaml is explicitly DEFERRED per the M46 spec —
  # Dune's per-module dep-ordering + module-aliasing heuristics are
  # non-trivial to re-implement; track as a future milestone if demand
  # surfaces.
  addDefaultConvention(ocaml_dune_convention.ocamlDuneConvention())
  # haskell_cabal (M55) — sixth managed-ecosystem Tier 2b convention.
  # First Phase 2 language milestone. Keys on a ``<name>.cabal`` file
  # at the project root (the Cabal package manifest filename — uniquely
  # identifies a Cabal package; no other convention recognises this
  # extension). Registered AFTER ocaml_dune per the M55 spec's
  # "register after ocaml-dune in the chain" sequencing — the spec
  # treats haskell-cabal as the first Phase 2 Mode 2 convention so the
  # Phase 1 conventions form a contiguous block above it. The order has
  # no recognition consequence — the convention's recognition gate is
  # closed-set on ``<name>.cabal`` presence + a Haskell token AND a
  # ``cabal`` token in ``uses:`` (the HARD precondition pattern,
  # mirroring M40 java-maven's "both halves required" and M46
  # ocaml-dune's "ocaml + dune" required pattern). The convention
  # requires both ``ghc`` AND ``cabal`` drivers on PATH; when either is
  # absent (which is the M55 default on Windows — the dev shell doesn't
  # bundle Haskell) ``recognize`` returns false and the M9-style harness
  # SKIPs cleanly. Defers when ``stack.yaml`` is present at the root —
  # a future ``haskell-stack`` sibling will handle the Stack ecosystem.
  # Library targets, multi-package cabal projects, ``cabal v2-test``
  # discovery, and Mode 3 Haskell are all explicitly DEFERRED per the
  # M55 spec.
  addDefaultConvention(haskell_cabal_convention.haskellCabalConvention())
  # ruby_bundler (M56) — seventh managed-ecosystem Tier 2b convention.
  # Second Phase 2 language milestone, immediately after M55
  # haskell-cabal. Keys on a ``Gemfile`` (Bundler manifest) at the
  # project root and additionally requires ``Gemfile.lock`` (HARD
  # precondition per the M56 spec — Bundler's reproducibility +
  # offline guarantee). Registered AFTER haskell-cabal per the M56
  # spec's "register after haskell-cabal in the chain" sequencing —
  # the Phase 2 conventions form a contiguous block below the Phase 1
  # cluster. The order has no recognition consequence — the
  # convention's recognition gate is closed-set on ``Gemfile`` +
  # ``Gemfile.lock`` presence + a Ruby token (``ruby`` or ``bundler``)
  # in ``uses:``. Bundler ships with modern Ruby (≥ 2.6) so the
  # ``uses:`` check is single-token (mirroring M30 Rust's
  # ``rust``-or-``cargo`` pattern rather than M55 haskell-cabal's
  # strict "both halves required" pattern). The convention requires
  # both ``ruby`` AND ``bundle`` drivers on PATH; when either is
  # absent (which is the M56 default on Windows — the dev shell
  # doesn't bundle Ruby) ``recognize`` returns false and the M9-style
  # harness SKIPs cleanly. Library targets (Ruby gems), gem packaging
  # via ``rake build``, native gem extensions, and Rails/Sinatra
  # patterns are all explicitly DEFERRED per the M56 spec — M56
  # supports app-style ``Gemfile`` + ``bundle exec ruby <entry>``
  # only.
  addDefaultConvention(ruby_bundler_convention.rubyBundlerConvention())
  # php_composer (M57) — eighth managed-ecosystem Tier 2b convention.
  # Third Phase 2 language milestone, immediately after M56
  # ruby-bundler. Keys on a ``composer.json`` (Composer manifest) at
  # the project root and additionally requires ``composer.lock`` (HARD
  # precondition per the M57 spec — Composer's reproducibility +
  # offline guarantee, mirroring the M56 ruby-bundler ``Gemfile.lock``
  # pattern). Registered AFTER ruby-bundler per the M57 spec's
  # "register after ruby-bundler in the chain" sequencing — the Phase
  # 2 conventions form a contiguous block below the Phase 1 cluster.
  # The order has no recognition consequence — the convention's
  # recognition gate is closed-set on ``composer.json`` +
  # ``composer.lock`` presence + a PHP token (``php`` or ``composer``)
  # in ``uses:``. Composer is independent of PHP (separate ``.phar``)
  # so the ``uses:`` check is single-token (mirroring M30 Rust's
  # ``rust``-or-``cargo`` pattern and M56 ruby-bundler's
  # ``ruby``-or-``bundler`` pattern rather than M55 haskell-cabal's
  # strict "both halves required" pattern). The convention requires
  # both ``php`` AND ``composer`` drivers on PATH; when either is
  # absent (which is the M57 default on Windows — the dev shell
  # doesn't bundle PHP) ``recognize`` returns false and the M9-style
  # harness SKIPs cleanly. Library targets (PHP packages with no
  # binary), PHAR packaging, PECL extensions, Composer scripts, and
  # Symfony/Laravel/Drupal patterns are all explicitly DEFERRED per
  # the M57 spec — M57 supports app-style ``composer.json`` +
  # ``php bin/<name>.php`` only.
  addDefaultConvention(php_composer_convention.phpComposerConvention())

  proc runStandardProvider(): int =
    try:
      let args = commandLineParams()
      let early = parseEarlyFlags(args)
      if early.wantVersion:
        stdout.writeLine("repro-standard-provider " &
          StandardProviderVersion)
        return 0
      let paths = parseProviderProtocolArgs(args)
      let request = readProviderRequestFile(paths.requestPath)
      let manifest = placeholderManifest(request.providerArtifactId)
      case request.kind
      of prkManifest:
        writeProviderResponseFile(paths.responsePath,
          manifestResponse(manifest))
      of prkGraphInvocation:
        let outcome = dispatchGraphRequest(request)
        if not outcome.matched:
          stderr.writeLine(noConventionMatchedMessage(outcome.projectRoot,
            outcome.uses))
          return 3
        writeProviderResponseFile(paths.responsePath,
          graphResponse(manifest, outcome.fragment))
      of prkDevEnvIntrospection:
        stderr.writeLine(
          "repro-standard-provider: dev-env introspection not supported " &
          "in the M1 framework")
        return 2
      0
    except CatchableError as err:
      stderr.writeLine("repro-standard-provider: " & err.msg)
      1

  when isMainModule:
    quit runStandardProvider()
else:
  when isMainModule:
    # Allow `--version` even outside provider mode so packaging
    # smoke-tests can identify the binary without enabling the
    # protocol surface. Anything else falls through to a hard error so
    # an accidental release build without ``-d:reproProviderMode``
    # fails loudly.
    let args = commandLineParams()
    let early = parseEarlyFlags(args)
    if early.wantVersion:
      stdout.writeLine("repro-standard-provider " &
        StandardProviderVersion)
      quit 0
    stderr.writeLine(
      "repro-standard-provider must be compiled with -d:reproProviderMode")
    quit 2
