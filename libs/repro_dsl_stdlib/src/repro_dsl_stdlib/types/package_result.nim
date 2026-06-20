## DSL-port M9.R.2b — multi-artifact package result records.
##
## ``meson_package(...)`` / ``cmake_package(...)`` /
## ``autotools_package(...)`` run a configure + build + install
## pipeline once and return a multi-artifact result whose
## ``.executable(name)`` / ``.library(name)`` / ``.files(name)`` methods
## slice install components into individual artifact bindings — one
## tool invocation maps to many artifact bindings without re-running
## the upstream build.
##
## v1 component layout: the slicing methods consult a hard-coded
## standard-layout table (``"runtime" -> "usr/bin"``, ``"library" ->
## "usr/lib"``, etc.) populated by each constructor at result
## construction time. Recipes that need a non-standard layout pass a
## populated ``components`` table to the result's ``newXResult``
## convenience constructor (the constructors expose this via their
## ``components`` argument; v1's three production constructors use the
## standard layout).
##
## The slicing methods do NOT re-run the build. They synthesise a thin
## ``Library`` / ``Executable`` / ``BuildActionDef`` value pointing at
## the package's ``installEdge`` plus the matched component's relative
## path.
##
## See [[file:Reprobuild-Standard-Library.md][Reprobuild-Standard-Library]]
## §"Multi-artifact result types" for the cross-tool contract.

import std/[os, strutils, tables]

import repro_project_dsl
import ./library
import ./executable

# DSL-port M9.R.2c — re-export the typed ``Library`` / ``Executable``
# records so the 79 from-source recipes that import
# ``repro_dsl_stdlib/types/package_result`` (for the
# ``MesonPackageResult`` / ``CmakePackageResult`` /
# ``AutotoolsPackageResult`` slicing surface) automatically pull the
# typed-value layer into scope. The package macro's M9.R.2c artifact
# slot injection (``var <n>: Library`` / ``var <n>: Executable``)
# references the types by bare ident; this re-export lets it resolve
# in every recipe without a second import line. The 5 outlier recipes
# without this import path get an explicit
# ``import repro_dsl_stdlib/types`` instead.
export library
export executable

type
  PackageResultBase = object of RootObj
    ## Shared fields across ``MesonPackageResult`` /
    ## ``CmakePackageResult`` / ``AutotoolsPackageResult``. v1 uses
    ## composition (rather than inheritance) for the three concrete
    ## result types so they can grow tool-specific fields
    ## independently; the base record documents the shared shape.

  MesonPackageResult* = object
    ## Returned by ``meson_package(...)``. Each of the three edges
    ## stamps one configure/build/install role; the slicing methods
    ## consult ``components`` to map a component name onto an
    ## install-tree relative path.
    buildEdge*: BuildActionDef
      ## The ``meson setup`` edge.
    compileEdge*: BuildActionDef
      ## The ``meson compile`` edge.
    installEdge*: BuildActionDef
      ## The ``meson install`` edge. ``.executable(name)`` and
      ## ``.library(name)`` return values whose ``install`` field
      ## points here.
    destdir*: string
      ## DESTDIR-style staging path (e.g. ``"out"``). Consumers
      ## prepend this to a component's relative path to land at the
      ## absolute file location.
    components*: Table[string, string]
      ## Component name → relative path within ``destdir``. v1 uses
      ## the standard meson install layout (``"runtime"``,
      ## ``"library"``, ``"share"``, ``"man"``, ``"include"``,
      ## ``"pkgconfig"``). Recipes that need a custom layout populate
      ## this directly.

  CmakePackageResult* = object
    ## Returned by ``cmake_package(...)``. Mirrors
    ## ``MesonPackageResult`` field-for-field; the difference is the
    ## installation driver (``cmake --install`` vs ``meson install``).
    buildEdge*: BuildActionDef
    compileEdge*: BuildActionDef
    installEdge*: BuildActionDef
    destdir*: string
    components*: Table[string, string]

  AutotoolsPackageResult* = object
    ## Returned by ``autotools_package(...)``. ``configureEdge`` is the
    ## ``./configure`` invocation; ``compileEdge`` is ``make``;
    ## ``installEdge`` is ``make install DESTDIR=...``. Recipes that
    ## need a separate ``make check`` edge wire it through the
    ## low-level ``make.run`` Layer-3 surface.
    buildEdge*: BuildActionDef
    compileEdge*: BuildActionDef
    installEdge*: BuildActionDef
    destdir*: string
      ## DESTDIR-style staging path. Relative to ``buildDir`` for
      ## autotools recipes (``make install DESTDIR=out`` from a
      ## ``cwd = buildDir`` process lands at
      ## ``<recipeRoot>/<buildDir>/out``).
    buildDir*: string
      ## M9.R.14c.5 — the out-of-tree build directory the install
      ## action runs ``make install DESTDIR=...`` from. Stage-copy
      ## emission joins ``buildDir / destdir`` to locate the
      ## DESTDIR staging tree on disk. Empty string means the destdir
      ## value is interpreted relative to the recipe root directly.
    components*: Table[string, string]

# ---------------------------------------------------------------------------
# Standard component-layout helpers
# ---------------------------------------------------------------------------

proc standardComponents*(): Table[string, string] =
  ## v1 hard-coded layout shared across all three multi-artifact
  ## constructors. Mirrors the FHS-style tree ``meson install
  ## --destdir=<out>`` (and the matching ``cmake --install`` /
  ## ``make install DESTDIR=...``) writes by default.
  result = initTable[string, string]()
  result["runtime"]   = "usr/bin"
  result["library"]   = "usr/lib"
  result["share"]     = "usr/share"
  result["man"]       = "usr/share/man"
  result["include"]   = "usr/include"
  result["pkgconfig"] = "usr/lib/pkgconfig"

# ---------------------------------------------------------------------------
# Slicing methods — MesonPackageResult
# ---------------------------------------------------------------------------

proc componentPath(components: Table[string, string]; name: string): string =
  ## Resolve a component name → relative path. Falls back to the bare
  ## component name when no explicit entry exists (recipes that want
  ## a custom name like ``"man3"`` get an unmangled path back rather
  ## than an empty string).
  if name in components:
    return components[name]
  name

# Forward declarations — ``emitAutotoolsStageCopy`` /
# ``emitInstallTreeMirror`` are defined below in the stage-copy helpers
# section but are referenced by the meson slicing methods above.
# Forward-declaring (rather than reordering) keeps the related stage-
# copy logic in one block at the bottom of the module where the
# autotools slicing methods consume it too.
proc emitAutotoolsStageCopy(installEdge: BuildActionDef;
                            buildDir, destdir, packageName, kind, name: string)
proc emitInstallTreeMirror*(installEdge: BuildActionDef;
                            buildDir, destdir, packageName: string)

proc executable*(r: MesonPackageResult; name: string): Executable =
  ## Slice the meson install edge into an executable artifact. The
  ## ``installPrefix`` is the resolved component path (typically
  ## ``"usr/bin"``); recipe authors join it with the package's
  ## destdir to get the on-disk binary location.
  ##
  ## M9.R.14d.7 — emit a stage-copy action that bridges the meson
  ## install tree (`<destdir>/usr/bin/<name>`) onto the canonical
  ## from-source resolver path (`.repro/output/<name>/<name>`).
  ## ``r.destdir`` is the absolute path the meson_package constructor
  ## resolved at provider-compile time (see M9.R.14d.7); we pass it
  ## with an EMPTY ``buildDir`` so ``emitAutotoolsStageCopy`` treats
  ## it as the install-root verbatim rather than prepending another
  ## relative segment.
  emitAutotoolsStageCopy(r.installEdge, "", r.destdir,
    currentOwningPackage(), "executable", name)
  # M9.R.14e.2 — also emit the package's install-tree mirror so the
  # M9.R.14e.1 resolver's search-path probe finds the staged
  # ``.pc`` / ``include`` / ``lib`` tree at a layout-stable location.
  # Idempotent (one mirror per package) — see ``emitInstallTreeMirror``.
  emitInstallTreeMirror(r.installEdge, "", r.destdir,
    currentOwningPackage())
  newExecutable(
    install = r.installEdge,
    executableName = name,
    installPrefix = componentPath(r.components, "runtime"))

proc library*(r: MesonPackageResult; name: string): Library =
  ## Slice the meson install edge into a library artifact.
  ##
  ## M9.R.14d.7 — emit a stage-copy action mirroring the executable
  ## slicing's pattern. Library-kind probing handles the wayland
  ## naming convention where the recipe declares ``library libwayland
  ## Client`` but meson installs ``libwayland-client.so`` — the probe
  ## walks the autotools naming taxonomy and matches the file the
  ## meson build actually emitted.
  emitAutotoolsStageCopy(r.installEdge, "", r.destdir,
    currentOwningPackage(), "library", name)
  # M9.R.14e.2 — install-tree mirror (see executable() above).
  emitInstallTreeMirror(r.installEdge, "", r.destdir,
    currentOwningPackage())
  newLibrary(
    install = r.installEdge,
    installPrefix = componentPath(r.components, "library"))

proc files*(r: MesonPackageResult; name: string): BuildActionDef =
  ## Return the install edge for ``name``-shaped files (man pages,
  ## docs, share data). The caller resolves the file paths via
  ## ``destdir`` + ``components[name]`` at consumption time.
  discard componentPath(r.components, name) # placeholder until typed PathRef
  r.installEdge

# ---------------------------------------------------------------------------
# Slicing methods — CmakePackageResult
# ---------------------------------------------------------------------------

proc executable*(r: CmakePackageResult; name: string): Executable =
  newExecutable(
    install = r.installEdge,
    executableName = name,
    installPrefix = componentPath(r.components, "runtime"))

proc library*(r: CmakePackageResult; name: string): Library =
  newLibrary(
    install = r.installEdge,
    installPrefix = componentPath(r.components, "library"))

proc files*(r: CmakePackageResult; name: string): BuildActionDef =
  discard componentPath(r.components, name)
  r.installEdge

# ---------------------------------------------------------------------------
# Stage-copy emission (M9.R.14c.5)
# ---------------------------------------------------------------------------
#
# The from-source-* tool resolver looks for the recipe's artefacts at
# the canonical ``<recipeRoot>/.repro/output/<name>/<name>`` path
# (per ``fromSourceArtifactCandidate`` in repro_tool_profiles). The
# autotools_package install action writes to a DESTDIR-style tree
# under ``destdir/usr/bin/<name>`` / ``destdir/usr/lib/<lib>.so``,
# so we need a stage-copy action that bridges the two layouts.
#
# The from-source-custom convention already ships an equivalent
# ``emitStageCopyAction`` helper for shell-action recipes (per the
# DslShellAction surface). v1 of the slicing-method stage emission
# duplicates that pattern inline so the autotools_package /
# meson_package / cmake_package slicing surface gains the same
# install-glue without a cross-module refactor.

import std/sets

var stageCopyEmitted {.threadvar.}: HashSet[string]
  ## Per-artifact stage-copy emission guard (executable/library kind).
var installMirrorEmitted {.threadvar.}: HashSet[string]
  ## M9.R.14e.2 — per-package install-tree-mirror emission guard. A
  ## recipe may call ``pkg.executable(...)`` AND ``pkg.library(...)``
  ## multiple times; we want the install-tree mirror emitted exactly
  ## once per package so the action registry doesn't collide.

proc stageCopyEmittedKey(packageName, kind, name: string): string =
  packageName & "." & kind & "." & name

proc sanitizeStageCopyName(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc m9r14fStripDepConstraint*(value: string): string =
  ## DSL-port M9.R.14f.2 — strip a version-constraint suffix off a raw
  ## dep constraint string so ``"wayland >=1.22"`` → ``"wayland"``.
  ## Mirrors the equivalent helpers in meson_package.nim and
  ## repro_tool_profiles.nim. Exported for unit-test introspection.
  for i, ch in value:
    if ch == ' ' or ch == '>' or ch == '<' or ch == '=' or
        ch == '~' or ch == '^':
      return value[0 ..< i]
  return value

proc m9r14fAppendDepMirrorDir(dst: var seq[string]; recipeRoot, depRaw: string) =
  let dep = m9r14fStripDepConstraint(depRaw)
  if dep.len == 0: return
  let libDir = recipeRoot / dep / ".repro" / "output" / "install" /
    "usr" / "lib"
  let lib64Dir = recipeRoot / dep / ".repro" / "output" / "install" /
    "usr" / "lib64"
  let posixLib = libDir.replace("\\", "/")
  let posixLib64 = lib64Dir.replace("\\", "/")
  if posixLib notin dst:
    dst.add(posixLib)
  if posixLib64 notin dst:
    dst.add(posixLib64)

proc m9r14fCollectDepMirrorLibDirs*(projectRoot, packageName: string):
    seq[string] =
  ## DSL-port M9.R.14f.2 — enumerate the install-mirror ``lib/`` dirs
  ## of every declared dep of ``packageName``. Each path joined as
  ## ``<recipeRoot>/<depName>/.repro/output/install/usr/lib``. The
  ## returned strings are POSIX-style with forward slashes so the
  ## emitted shell script does not need additional escaping. Order is
  ## (nativeBuildDeps, then buildDeps) in source-declaration order —
  ## deterministic across runs.
  let recipeRoot = parentDir(projectRoot)
  if recipeRoot.len == 0:
    return
  for raw in registeredNativeBuildDeps(packageName):
    m9r14fAppendDepMirrorDir(result, recipeRoot, raw)
  for raw in registeredBuildDeps(packageName):
    m9r14fAppendDepMirrorDir(result, recipeRoot, raw)

proc m9r14fEmitRpathPatchScript*(escapedDstUsr: string;
                                 depMirrorLibDirs: seq[string]): string =
  ## DSL-port M9.R.14f.2 — emit a POSIX shell snippet that walks every
  ## ELF under ``<mirror>/lib`` + ``<mirror>/lib64`` + ``<mirror>/bin``
  ## and runs ``patchelf --set-rpath`` on each. RPATH layout:
  ## ``$ORIGIN:$ORIGIN/../lib:$ORIGIN/../lib64:<dep1>:<dep2>:...``.
  ##
  ## The ``$ORIGIN`` family covers same-directory + sibling-directory
  ## SONAME chains (``libwayland-server.so`` next to
  ## ``libwayland-client.so``; ``wayland-scanner`` in ``bin/`` reaching
  ## ``../lib/libwayland-client.so``). Absolute dep paths cover
  ## transitive runtime deps (libexpat for wayland-scanner; libffi for
  ## libwayland-server; etc.).
  ##
  ## Idempotent: ``patchelf`` overwrites the existing RPATH every time,
  ## so re-running the install-mirror produces the same final RPATH.
  ##
  ## Graceful skip: when ``patchelf`` is not on PATH (host orchestration
  ## that builds the action graph but doesn't run it), the loop short-
  ## circuits without failing. Inside the Linux smoke environment
  ## (where patchelf IS provisioned via the bootstrap-linux-smoke.sh
  ## nix-shell deps), the loop runs over every ELF.
  var script = ""
  script.add("if command -v patchelf >/dev/null 2>&1; then ")
  # Build the RPATH string. Single-quote ``$ORIGIN`` so the shell does
  # not expand it — ``$ORIGIN`` must reach patchelf verbatim so the
  # dynamic linker interprets it at load time. Use a here-doc-free
  # construction so the snippet stays compatible with /bin/sh.
  var rpathParts: seq[string] = @[
    "'$ORIGIN'",
    "'$ORIGIN/../lib'",
    "'$ORIGIN/../lib64'",
  ]
  for libDir in depMirrorLibDirs:
    rpathParts.add("\"" & libDir.replace("\"", "\\\"") & "\"")
  # Concatenate with ":" via printf so the variable holds a single
  # colon-separated string when expanded.
  script.add("rpath=$(printf '%s' " & rpathParts[0])
  for i in 1 ..< rpathParts.len:
    script.add("; printf ':%s' " & rpathParts[i])
  script.add("); ")
  # Walk lib/ + lib64/ for .so* files (the SONAME-versioned chain).
  # Walk bin/ for executables.
  script.add("for d in \"" & escapedDstUsr & "/lib\" \"" & escapedDstUsr &
    "/lib64\" \"" & escapedDstUsr & "/bin\"; do ")
  script.add("if [ -d \"$d\" ]; then ")
  script.add("find \"$d\" -maxdepth 2 -type f \\( ")
  script.add("-name '*.so' -o -name '*.so.*' -o -perm -u+x ")
  script.add("\\) 2>/dev/null | while IFS= read -r f; do ")
  # ``patchelf --set-rpath`` is no-op for non-ELF files (it errors with
  # ``not an ELF executable``); guard with file-magic check via ``head``
  # before patching so non-ELF executables (shell scripts, etc.) don't
  # pollute the log with errors. ``\\177ELF`` is the 4-byte magic.
  script.add("magic=$(head -c 4 \"$f\" 2>/dev/null | od -An -c | head -1 | tr -d ' '); ")
  script.add("case \"$magic\" in 177ELF*) ")
  script.add("patchelf --set-rpath \"$rpath\" \"$f\" 2>/dev/null || true; ")
  script.add(";; esac; ")
  script.add("done; ")
  script.add("fi; done; ")
  script.add("fi; ")
  script

proc emitInstallTreeMirror*(installEdge: BuildActionDef;
                            buildDir, destdir, packageName: string) =
  ## DSL-port M9.R.14e.2 — mirror the recipe's DESTDIR install tree
  ## (``<recipeRoot>/<buildDir>/<destdir>/usr/``) to the canonical
  ## stable location at ``<recipeRoot>/.repro/output/install/usr/`` so
  ## consumer recipes have a layout-stable on-disk install tree to
  ## point ``PKG_CONFIG_PATH`` / ``CMAKE_PREFIX_PATH`` / ``CPATH`` /
  ## ``LIBRARY_PATH`` at — independent of which ``buildDir`` /
  ## ``destdir`` parameters the upstream recipe configured.
  ##
  ## Why: M9.R.14e.1's resolver already probes ``build/out/usr/``
  ## directly, but two recipes may configure different ``buildDir``
  ## values (e.g. ``meson_package(buildDir = "build")`` vs
  ## ``cmake_package(buildDir = "_build")``). The mirror at
  ## ``.repro/output/install/usr/`` is the single canonical location the
  ## resolver enumerates first, so the threaded env vars stay stable
  ## across constructor variants and across upstream layout drift.
  ##
  ## The action runs ``cp -a`` to preserve symlinks (load-bearing for
  ## ``.so`` SONAME chains: ``libwayland-client.so.0.25.0`` is the real
  ## file; ``libwayland-client.so.0`` and ``libwayland-client.so`` are
  ## symlinks the linker / loader resolve at run time).
  ##
  ## Idempotent: gated by ``installMirrorEmitted`` so a recipe that
  ## calls ``pkg.executable(...)`` AND ``pkg.library(...)`` emits the
  ## mirror once. Inert in unit-test mode (empty ``projectRoot``).
  let projectRoot = activeProviderProjectRoot()
  if projectRoot.len == 0:
    return
  if installMirrorEmitted.len == 0:
    installMirrorEmitted = initHashSet[string]()
  if packageName in installMirrorEmitted:
    return
  installMirrorEmitted.incl(packageName)
  let effectiveDestRoot =
    if buildDir.len > 0: buildDir & "/" & destdir
    else: destdir
  let srcUsr = effectiveDestRoot & "/usr"
  let escapedSrcUsr = srcUsr.replace("\\", "/").replace("\"", "\\\"")
  let dstUsrRoot = projectRoot / ".repro" / "output" / "install"
  let dstUsr = dstUsrRoot / "usr"
  createDir(dstUsrRoot)
  let escapedDstUsrRoot = dstUsrRoot.replace("\\", "/").replace("\"", "\\\"")
  let escapedDstUsr = dstUsr.replace("\\", "/").replace("\"", "\\\"")
  # Output stamp: a touch file so the engine has a concrete artefact to
  # key the action on without enumerating every nested file (recipes
  # routinely install hundreds of headers).
  let stampPath = dstUsrRoot / ".m9r14e_2_install_mirror.stamp"
  let escapedStamp = stampPath.replace("\\", "/").replace("\"", "\\\"")
  var script = "set -e; "
  # Remove the previous mirror to avoid stale artefacts. ``rm -rf`` is
  # safe here because ``dstUsr`` is a deterministic per-recipe path that
  # we own; no user data lives under ``.repro/output/install/usr``.
  script.add("rm -rf \"" & escapedDstUsr & "\"; ")
  script.add("mkdir -p \"" & escapedDstUsrRoot & "\"; ")
  # ``cp -a`` preserves symlinks, modes, timestamps. The ``--`` guards
  # against a future ``destdir`` whose value starts with ``-`` from
  # being interpreted as a flag.
  script.add("if [ -d \"" & escapedSrcUsr & "\" ]; then ")
  script.add("cp -a -- \"" & escapedSrcUsr & "\" \"" & escapedDstUsrRoot & "/\"; ")
  script.add("fi; ")
  # M9.R.14e.8 — rewrite the .pc files' ``prefix=`` line to point at the
  # absolute path of the mirrored ``usr/`` tree so consumers that consult
  # ``pkg-config --variable=...`` or ``pkg-config --cflags`` see real
  # on-disk paths instead of the upstream-baked ``/usr``. Without this,
  # meson's ``Program /usr/bin/wayland-scanner found: NO`` trip
  # surfaces every time a downstream recipe asks pkg-config where the
  # producer's binaries / headers live.
  #
  # The rewrite uses ``sed -i`` against every ``.pc`` file under
  # ``lib/pkgconfig``, ``lib64/pkgconfig``, ``share/pkgconfig``. The
  # pattern matches an exact ``prefix=/usr`` line at the top of the pc
  # file (the standard autotools/meson layout). pc files that ship a
  # non-``/usr`` prefix (e.g. ``prefix=/opt/foo``) get one extra sed
  # invocation looking for ``prefix=`` at line start with any value —
  # the second pass is idempotent and inert when the first already
  # matched.
  script.add("for pcdir in \"" & escapedDstUsr & "/lib/pkgconfig\" \"" &
    escapedDstUsr & "/lib64/pkgconfig\" \"" & escapedDstUsr &
    "/share/pkgconfig\"; do ")
  script.add("if [ -d \"$pcdir\" ]; then ")
  script.add("for pc in \"$pcdir\"/*.pc; do ")
  script.add("[ -f \"$pc\" ] && sed -i ")
  script.add("'1,/^prefix=/{ s|^prefix=.*$|prefix=" & escapedDstUsr & "|; }' ")
  script.add("\"$pc\"; ")
  script.add("done; fi; done; ")
  # M9.R.14f.2 — patch RPATH on every ELF under the mirror's lib/lib64/bin
  # dirs so the resulting binaries can find their transitive deps without
  # relying on LD_LIBRARY_PATH at runtime.
  let depMirrorLibDirs = m9r14fCollectDepMirrorLibDirs(projectRoot, packageName)
  script.add(m9r14fEmitRpathPatchScript(escapedDstUsr, depMirrorLibDirs))
  script.add("touch \"" & escapedStamp & "\"")
  let argv = @["sh", "-c", script]
  let stageId = "install-mirror-" & sanitizeStageCopyName(packageName)
  discard buildAction(
    id = stageId,
    call = inlineExecCall(argv),
    deps = @[installEdge.id],
    inputs = installEdge.outputs,
    outputs = @[stampPath],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "autotools_package.install_mirror",
    toolIdentityRefs = @["sh"])

proc m9r14dPascalToKebab*(value: string): string =
  ## DSL-port M9.R.14d.7c — convert ``libwaylandClient`` → ``libwayland-client``.
  ## meson packages name their shared libraries in kebab-case
  ## (``libwayland-client.so``) while recipes commonly declare them
  ## in PascalCase (``library libwaylandClient:``). The probe order
  ## consumes both forms.
  result = ""
  for i, ch in value:
    if ch in {'A' .. 'Z'} and i > 0 and value[i - 1] notin {'-', '_'}:
      result.add('-')
      result.add(chr(ord(ch) - ord('A') + ord('a')))
    elif ch in {'A' .. 'Z'}:
      result.add(chr(ord(ch) - ord('A') + ord('a')))
    else:
      result.add(ch)

proc m9r14dPascalToKebabWithDigits*(value: string): string =
  ## DSL-port M9.R.14d.7d — extension of `m9r14dPascalToKebab` that
  ## also inserts ``-`` at letter-↔-digit transitions. Pixman names its
  ## SONAME ``libpixman-1.so`` while the recipe declares ``libpixman1``
  ## (the trailing digit is the SOVERSION). Used as a fallback probe so
  ## the existing kebab form (e.g. ``libwayland-client``) keeps its
  ## priority.
  result = ""
  for i, ch in value:
    if i > 0:
      let prev = value[i - 1]
      let prevAlpha = prev in {'a' .. 'z', 'A' .. 'Z'}
      let prevDigit = prev in {'0' .. '9'}
      let curUpper = ch in {'A' .. 'Z'}
      let curDigit = ch in {'0' .. '9'}
      if (curUpper and prevAlpha and prev notin {'-', '_'}) or
         (curDigit and prevAlpha) or
         (curUpper and prevDigit):
        result.add('-')
    if ch in {'A' .. 'Z'}:
      result.add(chr(ord(ch) - ord('A') + ord('a')))
    else:
      result.add(ch)

proc emitAutotoolsStageCopy(installEdge: BuildActionDef;
                            buildDir, destdir, packageName, kind, name: string) =
  ## Emit a single stage-copy action that copies the installed
  ## artefact at ``destdir/usr/{bin,lib}/<name>`` into the canonical
  ## ``<projectRoot>/.repro/output/<name>/<name>`` location so the
  ## from-source resolver can find it. Idempotent — guarded by the
  ## ``autotoolsStageCopyEmitted`` flag so a recipe that calls
  ## ``pkg.executable("autoconf")`` multiple times only emits the
  ## stage-copy once.
  let projectRoot = activeProviderProjectRoot()
  if projectRoot.len == 0:
    # Unit-test mode: no provider project root means no on-disk path
    # to stage into. Defer to the legacy "thin handle only" behaviour.
    return
  let flagKey = stageCopyEmittedKey(packageName, kind, name)
  if stageCopyEmitted.len == 0:
    stageCopyEmitted = initHashSet[string]()
  if flagKey in stageCopyEmitted:
    return
  stageCopyEmitted.incl(flagKey)
  let outputDir = projectRoot / ".repro" / "output" / name
  createDir(outputDir)
  let outputPath = outputDir / name
  let escapedOut = outputPath.replace("\\", "/").replace("\"", "\\\"")
  let escapedOutDir = outputDir.replace("\\", "/").replace("\"", "\\\"")
  let effectiveDestRoot =
    if buildDir.len > 0: buildDir & "/" & destdir
    else: destdir
  let installPrefix = effectiveDestRoot & "/usr/" & (if kind == "library": "lib" else: "bin")
  let escapedSrcDir = installPrefix.replace("\\", "/").replace("\"", "\\\"")
  let escapedName = name.replace("\"", "\\\"")
  # Probe order: <prefix>/<name>, <prefix>/<name>.exe (cross-build
  # safety), <prefix>/lib<name>.so (library shape).
  var script = "set -e; mkdir -p \"" & escapedOutDir & "\"; "
  if kind == "library":
    # Library: probe several common autotools / meson naming patterns.
    # The DSL allows the recipe author to declare ``library libExpat:``
    # while the actual file is ``libexpat.so`` (autotools lowercases +
    # prefixes ``lib``); meson uses kebab-case so ``library
    # libwaylandClient:`` maps to ``libwayland-client.so``. The probe
    # order:
    #   1. lib<name>.so          (exact-case)
    #   2. lib<lowerName>.so     (autotools convention — case-folded)
    #   3. <kebabName>.so        (meson kebab-case, with `lib` prefix
    #                             collapsed when the recipe already wrote
    #                             it — `libwaylandClient` → `libwayland-client`)
    #   4. <name>.so             (no lib- prefix, exact-case)
    #   5. <lowerName>.so        (no lib- prefix, case-folded)
    #   6. lib<name>.a / lib<lowerName>.a (static archive fallbacks)
    let escapedLowerName = name.toLowerAscii.replace("\"", "\\\"")
    let kebabName = m9r14dPascalToKebab(name).replace("\"", "\\\"")
    let kebabDigitsName =
      m9r14dPascalToKebabWithDigits(name).replace("\"", "\\\"")
    script.add("for candidate in ")
    script.add("\"" & escapedSrcDir & "/lib" & escapedName & ".so\" ")
    script.add("\"" & escapedSrcDir & "/lib" & escapedLowerName & ".so\" ")
    script.add("\"" & escapedSrcDir & "/" & kebabName & ".so\" ")
    script.add("\"" & escapedSrcDir & "/" & kebabDigitsName & ".so\" ")
    script.add("\"" & escapedSrcDir & "/" & escapedName & ".so\" ")
    script.add("\"" & escapedSrcDir & "/" & escapedLowerName & ".so\" ")
    script.add("\"" & escapedSrcDir & "/lib" & escapedName & ".a\" ")
    script.add("\"" & escapedSrcDir & "/lib" & escapedLowerName & ".a\" ")
    script.add("\"" & escapedSrcDir & "/" & kebabName & ".a\" ")
    script.add("\"" & escapedSrcDir & "/" & kebabDigitsName & ".a\"; ")
    script.add("do if [ -f \"$candidate\" ]; then cp -fL \"$candidate\" \"" & escapedOut & "\"; exit 0; fi; done; ")
    script.add("echo \"autotools_package stage-copy: no library candidate for " & escapedName & " under " & escapedSrcDir & "\" >&2; exit 1")
  else:
    # Executable: probe bare name; also try .exe for cross-builds and
    # kebab-case (meson convention — recipe declares
    # ``executable waylandScanner`` while meson installs
    # ``wayland-scanner``).
    let kebabName = m9r14dPascalToKebab(name).replace("\"", "\\\"")
    script.add("if [ -f \"" & escapedSrcDir & "/" & escapedName & "\" ]; then ")
    script.add("cp -fL \"" & escapedSrcDir & "/" & escapedName & "\" \"" & escapedOut & "\"; chmod +x \"" & escapedOut & "\"; ")
    script.add("elif [ -f \"" & escapedSrcDir & "/" & kebabName & "\" ]; then ")
    script.add("cp -fL \"" & escapedSrcDir & "/" & kebabName & "\" \"" & escapedOut & "\"; chmod +x \"" & escapedOut & "\"; ")
    script.add("elif [ -f \"" & escapedSrcDir & "/" & escapedName & ".exe\" ]; then ")
    script.add("cp -fL \"" & escapedSrcDir & "/" & escapedName & ".exe\" \"" & escapedOut & ".exe\"; ")
    script.add("else echo \"autotools_package stage-copy: no executable candidate for " & escapedName & " under " & escapedSrcDir & "\" >&2; exit 1; fi")
  let argv = @["sh", "-c", script]
  let stageId = "autotools-stage-" & kind & "-" & sanitizeStageCopyName(packageName) &
    "-" & sanitizeStageCopyName(name)
  discard buildAction(
    id = stageId,
    call = inlineExecCall(argv),
    deps = @[installEdge.id],
    inputs = installEdge.outputs,
    outputs = @[outputPath],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "autotools_package.stage." & kind,
    toolIdentityRefs = @["sh"])

# ---------------------------------------------------------------------------
# Slicing methods — AutotoolsPackageResult
# ---------------------------------------------------------------------------

proc executable*(r: AutotoolsPackageResult; name: string): Executable =
  # M9.R.14c.5 — emit a stage-copy action that bridges the autotools
  # DESTDIR install tree (``<buildDir>/<destdir>/usr/bin/<name>``)
  # onto the canonical from-source resolver path
  # (``.repro/output/<name>/<name>``) so consumers of the recipe can
  # resolve the artefact at the location the resolver looks for it.
  emitAutotoolsStageCopy(r.installEdge, r.buildDir, r.destdir,
    currentOwningPackage(), "executable", name)
  # M9.R.14e.2 — install-tree mirror at the canonical layout-stable
  # location ``.repro/output/install/usr/`` (see ``emitInstallTreeMirror``).
  emitInstallTreeMirror(r.installEdge, r.buildDir, r.destdir,
    currentOwningPackage())
  newExecutable(
    install = r.installEdge,
    executableName = name,
    installPrefix = componentPath(r.components, "runtime"))

proc library*(r: AutotoolsPackageResult; name: string): Library =
  emitAutotoolsStageCopy(r.installEdge, r.buildDir, r.destdir,
    currentOwningPackage(), "library", name)
  emitInstallTreeMirror(r.installEdge, r.buildDir, r.destdir,
    currentOwningPackage())
  newLibrary(
    install = r.installEdge,
    installPrefix = componentPath(r.components, "library"))

proc files*(r: AutotoolsPackageResult; name: string): BuildActionDef =
  discard componentPath(r.components, name)
  r.installEdge
