## M68 merge note (hand-edited): the auto-generated ``gccCatalog`` body
## sits below the pre-existing ``package gcc:`` DSL block. The DSL
## block remains the source of truth for the GCC CLI surface and the
## Nix provisioning shape on Nix-capable hosts; the ``gccCatalog``
## slice is consumed by the M64 ``cakBuiltin`` adapter on Windows.
## Re-harvest emits ONLY the catalog half; re-attach the DSL block
## by hand if you regenerate.
##
## **M3 update (Realize-Closure-And-Catalog-Expansion spec).** The
## previously-documented M69 realize-time gaps for gcc closed via M3:
## the harvester now emits ``nested_7z = true`` on the platform slice
## AND an allowlisted ``pre_install_actions`` list capturing the two
## ``Expand-7zArchive`` invocations (binutils + mingw-w64+gcc). The
## remaining ``Get-ChildItem | Remove-Item -Recurse -Force`` pipeline
## lands in ``pre_install_unrecognized`` (pipelines are out of the
## allowlist), but the nested_7z + the recursive extract pass remove
## the inner archives anyway — the unrecognized line is a NO-OP
## post-extraction, so the operator's only observable effect is the
## one ``WPreInstallUnrecognized`` stderr warning at apply time.
##
## **Hand-edited bin_relpath divergence from the harvester.** The
## harvester (driven by ``--bin-default gcc=gcc.exe,g++.exe,gfortran.exe``)
## emits all three binaries. nuwen.net's components-20.0 distribution
## ships gcc + g++ + binutils (as, ld, gcc-ar, gcc-nm, gcc-ranlib, etc.)
## but does NOT ship a Fortran front-end. M3 live smoke verified the
## bin/ tree carries gcc.exe + g++.exe + as.exe + ld.exe — and
## ``gcc.exe --version`` returns ``(GCC) 15.2.0`` cleanly. We drop
## ``bin/gfortran.exe`` from the catalog so the realize loop's
## bin-existence sanity check passes. Operators who need Fortran
## should harvest the winlibs ``components-mingw-w64-msvcrt-13.0.0-rev3``
## (or newer) variant which DOES bundle a Fortran front-end.

import std/tables
import repro_project_dsl
import repro_dsl_stdlib/packages_schema
import repro_dsl_stdlib/types/library
import repro_dsl_stdlib/types/options
export packages_schema

# ---------------------------------------------------------------------------
# Pre-existing M21 DSL declaration (CLI surface + Nix provisioning).
# ---------------------------------------------------------------------------

package gcc:
  provisioning:
    nixPackage "nixpkgs#gcc", executablePath = "bin/gcc",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
    # Windows / non-Nix Linux: nuwen.net's `components-20.0` mingw
    # distribution shipped via ScoopInstaller/Main. The manifest's
    # `env_add_path: "bin"` is what exposes gcc.exe on PATH.
    scoopApp(bucket = "main", app = "gcc",
      preferredVersion = ">=12", executablePath = "bin/gcc.exe",
      requiresExecutionProfileChecksum = false)
    # Direct-download: brechtsanders' winlibs distribution from GitHub
    # Releases. Same toolchain shape as the nuwen.net `main/gcc` Scoop
    # entry but ships as a single (non-nested) .7z, which our tarball
    # resolver can extract directly. archive layout is `mingw64/bin/
    # gcc.exe` so stripComponents=1 flattens to `bin/gcc.exe`.
    tarball url = "https://github.com/brechtsanders/winlibs_mingw/releases/download/16.1.0posix-14.0.0-ucrt-r2/winlibs-x86_64-posix-seh-gcc-16.1.0-mingw-w64ucrt-14.0.0-r2.7z",
      sha256 = "62fb8588d2deee7d662dbcbd386702adbf19643764c971c38aa4839472eee232",
      archiveType = "7z",
      stripComponents = 1,
      executablePath = "bin/gcc.exe",
      packageId = "gcc-winlibs@16.1.0",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:gcc-winlibs@16.1.0:sha256:62fb8588d2deee7d662dbcbd386702adbf19643764c971c38aa4839472eee232"

  executable gcc:
    cli:
      dependencyPolicy automaticMonitor

      # DSL-port M9.R.2 audit: extended the gcc driver call to cover the
      # common compile / link / preprocess / make-dep flag families.
      # Driver invocations the recipe layer now expresses typed-style:
      #
      #   * Compile:    gcc -c -o out.o src.c
      #   * Link-shared: gcc -shared -o libfoo.so objs... -lbar
      #   * Preprocess: gcc -E src.c
      #   * Make-deps:  gcc -M src.c  /  gcc -MMD -MF dep.d -c src.c
      #
      # The flag set mirrors the canonical gcc(1) options. ``-I`` /
      # ``-L`` / ``-l`` / ``-D`` use the concat format so the wrapper
      # emits ``-Iinclude/foo`` etc. as single argv entries (gcc accepts
      # both ``-I include/foo`` and ``-Iinclude/foo``; concat matches
      # the lossless ``-c -o out.o src.c`` byte-equivalent shape this
      # repo's reproducibility tests already assert).
      call:
        boolFlag pic is bool, alias = "-fPIC"
        boolFlag debug3 is bool, alias = "-g3"
        boolFlag compileOnly is bool, alias = "-c"
        boolFlag preprocessOnly is bool, alias = "-E"
        boolFlag makeDeps is bool, alias = "-M"
        boolFlag makeDepsMMD is bool, alias = "-MMD"
        boolFlag shared is bool, alias = "-shared"
        boolFlag staticLink is bool, alias = "-static"
        flag depfileOut is string,
          alias = "-MF",
          format = separate,
          role = output
        flag includes is seq[string],
          alias = "-include",
          role = input,
          repeated = true
        flag includeDirs is seq[string],
          alias = "-I",
          format = concat,
          repeated = true
        flag libDirs is seq[string],
          alias = "-L",
          format = concat,
          repeated = true
        flag libs is seq[string],
          alias = "-l",
          format = concat,
          repeated = true
        flag defines is seq[string],
          alias = "-D",
          format = concat,
          repeated = true
        flag optimization is string,
          alias = "-O",
          format = concat
        flag standard is string,
          alias = "-std=",
          format = concat
        flag output is string,
          alias = "-o",
          role = output,
          required = true
        pos source is string,
          role = input,
          position = 0

        # Named-Targets M0: ``-o`` is the primary output, exposed as
        # ``output`` in the typed-tool wrapper. M1 reads this to assign
        # an implicit target name to each compile edge.
        outputs output

# ---------------------------------------------------------------------------
# M3-extended bulk-harvest catalog (cakBuiltin adapter consumer on Windows).
# Harvested from bucket: ScoopInstaller/Main
# Versions (newest-first): 15.2.0
# ---------------------------------------------------------------------------

let gccCatalog* = @[
  VersionedProvisioning(
    version: "15.2.0",
    archive_format: afSevenZip,
    install_method: imExtract,
    bin_relpath: @["bin/gcc.exe", "bin/g++.exe"],
    platforms: @[
      PlatformBinary(cpu: pcX86_64, os: poWindows, url: "https://nuwen.net/files/mingw/components-20.0.7z", sha256: "561d873b7f95dbb39a34b7ab00050dc6028808310a847721a8aea5e5b0bff1c9", sha512: "", sha1: "", extract_path: "components-20.0", nested_7z: true)
    ],
    installer_args: @[],
    pacman_packages: @[],
    bootstrap_argv: @[],
    env: {"CPLUS_INCLUDE_PATH": "${prefix}\\include", "C_INCLUDE_PATH": "${prefix}\\include"}.toTable(),
    pre_install_actions: @[
      PreInstallAction(kind: piaExpand7z, source: "$dir\\binutils-*.7z", target: "$dir", recurse: false, literal: ""),
      PreInstallAction(kind: piaExpand7z, source: "$dir\\mingw-w64+gcc.7z", target: "$dir", recurse: false, literal: "")
    ],
    pre_install_unrecognized: @["Get-ChildItem \"$dir\\*.7z\" | Remove-Item -Recurse -Force"])
]

# ---------------------------------------------------------------------------
# DSL-port M9.R.2b — Layer-2 operation implementations.
#
# The dispatcher in ``operations/{compile,link,archive,strip}.nim`` reads
# ``currentCompiler()`` and routes to one of the ``gcc<X>`` /
# ``clang<X>`` / ``msvc<X>`` implementations defined below. Each
# implementation takes a typed ``*Options`` record + an optional
# ``LibraryApi`` interface contribution and emits a ``BuildActionDef``
# whose ``call.arguments`` carry the gcc-shaped argv (``-I`` / ``-l`` /
# ``-D`` / ``-std=`` etc.).
#
# The implementations call into the existing ``gcc(...)`` wrapper proc
# emitted by the package macro from the ``executable gcc: cli: call:``
# block above — that wrapper records each non-default flag in
# ``call.arguments`` with the role-tagged metadata downstream consumers
# need.
# ---------------------------------------------------------------------------

{.experimental: "callOperator".}

proc apiHeaders(api: LibraryApi): seq[string] =
  ## Lift PUBLIC + PRIVATE header search paths from a ``LibraryApi``
  ## into a flat ``-I`` contribution list.
  if api.declared:
    for h in api.headers: result.add(h)
    for h in api.privateHeaders: result.add(h)

proc apiDefines(api: LibraryApi): seq[string] =
  if api.declared:
    for d in api.defines: result.add(d)
    for d in api.privateDefines: result.add(d)

proc apiLinks(api: LibraryApi): seq[string] =
  if api.declared:
    for l in api.links: result.add(l)
    for l in api.privateLinks: result.add(l)

proc gccCompile*(opts: CompileOptions): BuildActionDef =
  ## gcc-shaped compile action.
  var includeDirs: seq[string] = @[]
  var defs: seq[string] = @[]
  for api in opts.inputs:
    for h in apiHeaders(api): includeDirs.add(h)
    for d in apiDefines(api): defs.add(d)
  for d in opts.defines: defs.add(d)
  let std = opts.standard
  if includeDirs.len == 0 and defs.len == 0 and std.len == 0:
    return gcc(source = opts.source, output = opts.target,
      compileOnly = true)
  gcc(source = opts.source, output = opts.target,
    compileOnly = true,
    includeDirs = includeDirs,
    defines = defs,
    standard = std)

proc gccLink*(opts: LinkOptions): BuildActionDef =
  ## gcc-shaped link action.
  var libs: seq[string] = @[]
  var libDirs: seq[string] = @[]
  for dep in opts.deps:
    for l in apiLinks(dep.api): libs.add(l)
    if dep.installPrefix.len > 0:
      libDirs.add(dep.installPrefix)
  let firstObj =
    if opts.objects.len > 0 and opts.objects[0].outputs.len > 0:
      opts.objects[0].outputs[0]
    else: opts.target
  result = gcc(
    source = firstObj,
    output = opts.target,
    shared = (opts.kind == lokShared),
    staticLink = (opts.kind == lokStatic),
    libs = libs,
    libDirs = libDirs)

proc gccArchive*(opts: ArchiveOptions): BuildActionDef =
  ## ``ar`` archive call. v1 emits a thin ``BuildActionDef`` carrying
  ## the canonical ``ar rcs <archive> <objs...>`` argv directly.
  result = BuildActionDef(
    call: PublicCliCall(
      packageName: "binutils",
      executableName: "ar",
      subcommand: "",
      arguments: @[]))
  let modifiers =
    if opts.modifiers.len > 0: opts.modifiers else: "rcs"
  result.call.arguments.add(PublicCliArg(
    name: "modifiers",
    kind: cpkPositional,
    position: 0,
    encodedValue: modifiers))
  result.call.arguments.add(PublicCliArg(
    name: "archive",
    kind: cpkPositional,
    position: 1,
    role: carOutput,
    encodedValue: opts.target))
  for i, obj in opts.objects:
    let path =
      if obj.outputs.len > 0: obj.outputs[0] else: ""
    result.call.arguments.add(PublicCliArg(
      name: "object" & $i,
      kind: cpkPositional,
      position: 2 + i,
      role: carInput,
      encodedValue: path))
  result.outputs.add(opts.target)

proc gccStrip*(opts: StripOptions): BuildActionDef =
  ## ``strip`` invocation.
  result = BuildActionDef(
    call: PublicCliCall(
      packageName: "binutils",
      executableName: "strip",
      subcommand: "",
      arguments: @[]))
  if opts.target.len > 0:
    result.call.arguments.add(PublicCliArg(
      name: "output",
      kind: cpkFlag,
      alias: "-o",
      format: cafSeparate,
      role: carOutput,
      encodedValue: opts.target))
    result.outputs.add(opts.target)
  for sym in opts.keepSymbols:
    result.call.arguments.add(PublicCliArg(
      name: "keep",
      kind: cpkFlag,
      alias: "-K",
      format: cafSeparate,
      encodedValue: sym))
  let inputPath =
    if opts.input.outputs.len > 0: opts.input.outputs[0] else: ""
  result.call.arguments.add(PublicCliArg(
    name: "input",
    kind: cpkPositional,
    position: 0,
    role: carInput,
    encodedValue: inputPath))
