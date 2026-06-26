## DSL-port M9.R.2b — Layer-1 ``cmake_package`` multi-artifact
## constructor.
##
## Internally drives ``cmake.configure`` + ``cmake.build`` +
## ``cmake.install`` and returns a ``CmakePackageResult``.
##
## ## M9.R.12.4 — auto-emit fetch action when recipe declared one
##
## See ``autotools_package`` / ``meson_package`` for the canonical
## rationale. Per-project providers don't dispatch through the
## standard-provider's convention layer, so the fetch action has to be
## emitted from the constructor body for recipes with an explicit
## ``build:`` block.

{.experimental: "callOperator".}

import std/[options, os, strutils]

import repro_project_dsl

import ../types/package_result
import ../packages/cmake as cmake_module
import ../packages/sh as sh_module

# ---------------------------------------------------------------------------
# Fetch action (M9.R.12.4) — shared shape with ``autotools_package`` /
# ``meson_package``.
# ---------------------------------------------------------------------------

const FetchScratchSubdir = ".repro/fetch"

proc cmakeFetchActionId(packageName: string): string =
  var sanitized = ""
  for ch in packageName:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      sanitized.add(ch)
    else:
      sanitized.add('_')
  if sanitized.len == 0:
    sanitized = "x"
  "cmake-fetch-" & sanitized

proc maybeEmitFetchAction(packageName, projectRoot, extractedRel: string):
    Option[BuildActionDef] =
  if packageName.len == 0 or projectRoot.len == 0:
    return none(BuildActionDef)
  let spec = registeredFetchSpec(packageName)
  if spec.url.len == 0 or spec.hashHex.len == 0:
    return none(BuildActionDef)
  let scratch = projectRoot / FetchScratchSubdir
  createDir(scratch)
  let stamp = scratch / (spec.hashHex & ".stamp")
  let tarball = scratch / (spec.hashHex & ".tar")
  let extracted = projectRoot / extractedRel
  createDir(parentDir(extracted))
  let hashAlgTag =
    case spec.hashAlg
    of dshaSha256: "sha256"
    of dshaBlake3: "blake3"
  # M9.R.15q.5.4 — support relative ``file:./vendor/...`` URL form so
  # recipes that vendor a tarball can reference it without baking the
  # host's absolute path into the recipe (mirrors the equivalent
  # autotools_package / meson_package helpers).
  var resolvedUrl = spec.url
  if resolvedUrl.startsWith("file:./") or resolvedUrl.startsWith("file:../"):
    let relPath = resolvedUrl[5 .. ^1]
    let absPath = projectRoot / relPath
    let posixAbs = absPath.replace("\\", "/")
    resolvedUrl = "file://" & posixAbs
  let escapedUrl = resolvedUrl.replace("\"", "\\\"")
  let escapedHash = spec.hashHex.replace("\"", "\\\"")
  let escapedTarball = tarball.replace("\\", "/").replace("\"", "\\\"")
  let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
  let escapedExtracted = extracted.replace("\\", "/").replace("\"", "\\\"")
  var script = "set -e; "
  script.add("mkdir -p \"" & escapedExtracted & "\"; ")
  script.add("if [ ! -f \"" & escapedTarball & "\" ]; then ")
  script.add("curl -fsSL -o \"" & escapedTarball & "\" \"" & escapedUrl &
    "\"; fi; ")
  case spec.hashAlg
  of dshaSha256:
    script.add("echo \"" & escapedHash & "  " & escapedTarball &
      "\" | sha256sum -c -; ")
  of dshaBlake3:
    script.add("echo \"" & escapedHash & "  " & escapedTarball &
      "\" | b2sum -a blake3 -c - || ")
    script.add("echo \"" & escapedHash & "  " & escapedTarball &
      "\" | blake3sum -c -; ")
  # M9.R.13b.4 — ``--force-local`` so Windows tar (MSYS2 / Git-for-
  # Windows) doesn't interpret ``D:/...`` as a ``host:`` rsh path. See
  # the matching fix in ``autotools_package.nim`` for the full rationale.
  script.add("tar --force-local -xf \"" & escapedTarball & "\" -C \"" &
    escapedExtracted & "\" --strip-components=" & $spec.extractStrip & "; ")
  script.add("touch \"" & escapedStamp & "\"")
  let argv = @["sh", "-c", script]
  let act = buildAction(
    id = cmakeFetchActionId(packageName),
    call = inlineExecCall(argv),
    inputs = @[],
    outputs = @[stamp],
    pool = "fetch",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "cmake_package.fetch." & hashAlgTag,
    toolIdentityRefs = @["sh"])
  some(act)

proc cmake_package*(srcDir: string;
                    buildDir = "build";
                    destdir = "out";
                    prefix = "/usr";
                    generator = "";
                    cacheVars: seq[string] = @[];
                    target = "";
                    extraEnv: seq[(string, string)] = @[];
                    srcPatches: seq[string] = @[]): CmakePackageResult =
  ## Configure → build → install pipeline for an upstream cmake
  ## project. v1 leaves component selection up to the recipe
  ## (``component`` field on the install call); the standard layout
  ## table populated on the result mirrors meson's.
  ##
  ## ``extraEnv`` (M9.R.15q.6.3): per-edge env-var overrides applied
  ## to ALL THREE edges (configure / build / install). The engine
  ## extends the action's spawned-process env with each ``(NAME,
  ## VALUE)`` pair AFTER the M9.R.14e.3 search-path channels are
  ## threaded. Use this when a recipe needs to thread an env var that
  ## the from-source resolver's auto-channel detection misses (e.g.
  ## kwin's PKG_CONFIG_PATH_FOR_TARGET for the libdisplay-info /
  ## wayland-protocols / wayland-scanner trio that pkg_check_modules
  ## probes via the nix-wrapped pkg-config — the wrapper only consults
  ## PKG_CONFIG_PATH_FOR_TARGET, not the bare PKG_CONFIG_PATH, and the
  ## auto-channel doesn't compose for graphs with 70+ deps).
  ##
  ## ## M9.R.14g.6 — inline-exec build + install
  ##
  ## The legacy ``cmake.build(buildDir = ...)`` + ``cmake.install(...)``
  ## paths lowered through the DSL CLI surface with a leading subcommand
  ## literal (``cmake build --build <dir>`` / ``cmake install --install
  ## <dir>``). cmake does NOT accept ``build`` / ``install`` as
  ## subcommand names — its build/install modes are selected by the
  ## ``--build`` / ``--install`` flag itself. The legacy emission failed
  ## with ``CMake Error: Unknown argument --build`` because cmake
  ## consumed ``build`` as a positional source-dir path and then the
  ## ``--build`` flag was unexpected.
  ##
  ## Route both actions through ``inlineExecCall`` so the literal argv
  ## is what cmake actually accepts. Configure stays on the DSL CLI
  ## path because cmake silently tolerates the bogus ``configure``
  ## positional (with a warning), and reworking the configure shape
  ## would require fixing the broader cmake.nim subcommand surface
  ## (cross-cutting + outside this milestone's scope).
  ## ``srcPatches`` (M9.R.15q.10.5): list of ``sed -i`` expressions to
  ## apply to files inside the extracted source tree BEFORE cmake
  ## configure runs. Each entry is a self-contained ``sed -i`` argv
  ## (e.g. ``"sed -i 's/old/new/' src/CMakeLists.txt"``). Use this when
  ## a recipe needs to disable an upstream-required feature that pulls
  ## in a dep we don't ship from-source (the plasma-workspace v1 trip
  ## drops the ``TextEditor`` component from the umbrella
  ## ``find_package(KF6 ... REQUIRED COMPONENTS ...)`` probe + the
  ## ``add_subdirectory(interactiveconsole)`` glue to sidestep
  ## ktexteditor → qt6-speech → qt6-multimedia recipe inflation).
  ##
  ## The patch action runs in the recipe's project root (NOT inside
  ## srcDir), depends on the fetch action's stamp, and writes its own
  ## stamp under ``.repro/build/cmake-patch.stamp`` so the engine's
  ## action-cache fingerprint stays stable across rebuilds.
  let pkgName = currentOwningPackage()
  let projectRoot = activeProviderProjectRoot()
  let extractedRel = block:
    let raw = registeredFetchSpec(pkgName).extractedRoot
    if raw.len > 0: raw else: "src"
  let fetchActOpt = maybeEmitFetchAction(pkgName, projectRoot, extractedRel)
  var configureAfter: seq[BuildActionDef] = @[]
  if fetchActOpt.isSome:
    configureAfter.add(fetchActOpt.get())
  # M9.R.15q.10.5 — when ``srcPatches`` is non-empty, emit a per-recipe
  # source-patch action that runs every ``sed -i`` expression against
  # the extracted source tree, ordered AFTER the fetch action +
  # BEFORE the configure action.
  if srcPatches.len > 0 and projectRoot.len > 0:
    let patchStamp = projectRoot / ".repro" / "build" / "cmake-patch.stamp"
    createDir(parentDir(patchStamp))
    let escapedStamp = patchStamp.replace("\\", "/").replace("\"", "\\\"")
    var script = "set -e; "
    for sedExpr in srcPatches:
      # ``sedExpr`` is a complete ``sh -c`` argv body (e.g.
      # ``sed -i 's/X/Y/' src/foo.txt``). Append in declaration order
      # so subsequent patches see prior edits.
      script.add(sedExpr & "; ")
    script.add("touch \"" & escapedStamp & "\"")
    var patchDeps: seq[string] = @[]
    var patchInputs: seq[string] = @[]
    if fetchActOpt.isSome:
      patchDeps.add(fetchActOpt.get().id)
      for out0 in fetchActOpt.get().outputs:
        patchInputs.add(out0)
    let patchEdge = buildAction(
      id = "cmake-patch-" & pkgName,
      call = inlineExecCall(@["sh", "-c", script]),
      deps = patchDeps,
      inputs = patchInputs,
      outputs = @[patchStamp],
      pool = "fetch",
      dependencyPolicy = automaticMonitorPolicy(),
      commandStatsId = "cmake_package.patch",
      toolIdentityRefs = @["sh"])
    configureAfter.add(patchEdge)
  # M9.R.15i.1 — auto-thread Qt6 component cmake-config dirs from every
  # ``qt6-*`` dep's install-mirror so KF6 / Plasma recipes consuming
  # qt6-tools transitively can resolve ``find_package(Qt6 ...
  # LinguistTools REQUIRED)`` even though qt6-base + qt6-tools install
  # to separate sibling prefixes. Without this, Qt6's CMake-config-
  # package expects every requested component to live at the same
  # install prefix as Qt6Core and the probe fails. Inert in unit-test
  # mode (empty ``projectRoot``) and for non-Qt6 deps.
  #
  # M9.R.15i.5 — also auto-thread CMake-config dirs for EVERY declared
  # dep's install-mirror (not just qt6-*). KF6 modules consume each
  # other (kxmlgui declares find_package(KF6GlobalAccel REQUIRED);
  # kpackage declares find_package(KF6KArchive REQUIRED); etc.) and
  # each sibling installs to its own ``.repro/output/install/``
  # prefix.  Without per-Config_DIR threading, cmake's find_package
  # walks CMAKE_PREFIX_PATH alone and CMAKE_PREFIX_PATH (populated
  # via M9.R.14e.* resolver work) is not always honoured because Qt6/KF6
  # CMake-config packages frequently rely on a sibling-relative
  # convention assumption that breaks under sibling install prefixes.
  # Threading each ``<Component>_DIR`` explicitly is the surgical fix.
  var effectiveCacheVars = cacheVars
  if projectRoot.len > 0:
    let qt6CompDirs = m9r15iCollectQt6ComponentDirs(projectRoot, pkgName)
    for entry in m9r15iEmitQt6ComponentCacheVars(qt6CompDirs):
      effectiveCacheVars.add(entry)
    let allCmakeDirs = m9r15iCollectAllCmakeConfigDirs(projectRoot, pkgName)
    # Dedup against qt6CompDirs (which we already emitted) to avoid
    # double ``-D<Component>_DIR=`` flags. Use a per-component set.
    var seen: seq[string] = @[]
    for (comp, _) in qt6CompDirs:
      seen.add(comp)
    for entry in m9r15iEmitQt6ComponentCacheVars(allCmakeDirs):
      let dEq = entry.find('=')
      if dEq <= 0:
        continue
      let suffix = "_DIR"
      if dEq < suffix.len:
        continue
      let component = entry[0 ..< dEq - suffix.len]
      if component in seen:
        continue
      seen.add(component)
      effectiveCacheVars.add(entry)
    # M9.R.15q.3.1 — synthesize a virtual KF6 umbrella config when one
    # or more KF6 module configs are visible across the dep's install-
    # mirror cmake/ trees. cmake's ``find_package(KF6 REQUIRED COMPONENTS
    # Config CoreAddons I18n ...)`` umbrella form needs a top-level
    # ``KF6Config.cmake`` dispatcher; the per-module ``-DKF6<X>_DIR=...``
    # threading alone does not satisfy the umbrella probe. Emit the
    # dispatcher under ``.repro/build/cmake/KF6/`` and add
    # ``-DKF6_DIR=...`` so cmake routes the umbrella through our synth.
    let kf6Components = m9r15q31KF6Components(allCmakeDirs)
    if kf6Components.len > 0:
      let umbrellaDir = m9r15q31SynthesizeKF6UmbrellaConfig(projectRoot,
        kf6Components)
      if umbrellaDir.len > 0:
        # Don't double-emit if a recipe already pinned KF6_DIR.
        var hasKf6Dir = false
        for v in effectiveCacheVars:
          if v.startsWith("KF6_DIR="):
            hasKf6Dir = true
            break
        if not hasKf6Dir:
          effectiveCacheVars.add("KF6_DIR=" & umbrellaDir)
    # M9.R.15o.1 — auto-thread Qt6Gui transitive find_dependency targets
    # (libxkbcommon + mesa) into the CMake-config dir scan when any
    # qt6-* dep is present. M9.R.15n.3..5 hand-patched per-recipe
    # buildDeps for kcrash / kglobalaccel / kded; this constructor-
    # level fix obviates that boilerplate for every future Qt6Gui
    # consumer (ksvg / kio / plasma-framework / kwin / ...).
    let qt6XtraDirs = m9r15oCollectQt6TransitiveCmakeConfigDirs(
      projectRoot, pkgName)
    for entry in m9r15iEmitQt6ComponentCacheVars(qt6XtraDirs):
      let dEq = entry.find('=')
      if dEq <= 0:
        continue
      let suffix = "_DIR"
      if dEq < suffix.len:
        continue
      let component = entry[0 ..< dEq - suffix.len]
      if component in seen:
        continue
      seen.add(component)
      effectiveCacheVars.add(entry)
    # M9.R.15j.3 — inject ``-Wl,--copy-dt-needed-entries`` into the
    # default linker-flag cache vars so transitive DT_NEEDED dependencies
    # of sibling KF6 / Qt6 libraries resolve correctly.
    #
    # Symptom: kpackage's link line for ``bin/kpackagetool6`` references
    # ``-lKF6Archive`` (from the karchive sibling install-mirror). gcc's
    # default ``ld --as-needed`` walks libKF6Archive.so's DT_NEEDED
    # entries (libzstd.so.1, ...) but DROPS them from the resulting
    # binary's NEEDED set unless ``--copy-dt-needed-entries`` is set.
    # The drop causes ld to then complain that ZSTD_* symbols are
    # undefined references when libKF6Archive.so itself USES those
    # symbols transitively at link time.
    #
    # ``--copy-dt-needed-entries`` is the binutils-ld flag (the
    # historical default before ld changed to ``--no-copy-dt-needed-
    # entries`` in 2010). Re-enabling it via CMAKE_EXE_LINKER_FLAGS +
    # CMAKE_SHARED_LINKER_FLAGS_INIT lets ld pull the indirect zstd
    # SONAME entries into the final binary's NEEDED.
    #
    # We append to the cache var list (not _INIT) so this flag persists
    # across re-configures. Recipes that need different link flags can
    # still override via their own cacheVars entries — CMake honours
    # the LAST -D<var>=<value> wins.
    var hasExeLinkerFlags = false
    var hasSharedLinkerFlags = false
    for v in effectiveCacheVars:
      if v.startsWith("CMAKE_EXE_LINKER_FLAGS="):
        hasExeLinkerFlags = true
      if v.startsWith("CMAKE_SHARED_LINKER_FLAGS="):
        hasSharedLinkerFlags = true
    if not hasExeLinkerFlags:
      effectiveCacheVars.add("CMAKE_EXE_LINKER_FLAGS=-Wl,--copy-dt-needed-entries")
    if not hasSharedLinkerFlags:
      effectiveCacheVars.add("CMAKE_SHARED_LINKER_FLAGS=-Wl,--copy-dt-needed-entries")
    # M9.R.33.2 — auto-thread Qt6 FindXxx.cmake module dirs into
    # CMAKE_MODULE_PATH and GLESv2 hints into cacheVars whenever any
    # qt6-* dep is declared on the recipe.  Without this, a fresh
    # ``rm -rf .repro/build && repro build <qt6-consumer>`` trips with
    # "FindPlatformGraphics.cmake not in CMAKE_MODULE_PATH" + "Could
    # NOT find GLESv2".  The M9.R.32.1.2 recipe-local fallback in
    # plasma-workspace/repro.nim threaded the same dirs by hand; this
    # constructor-level fix lifts the work so every qt6-* consumer
    # gets it automatically.  Recipes that already set
    # ``CMAKE_MODULE_PATH=...`` via cacheVars take precedence (last
    # ``-D<var>=<value>`` wins under cmake; the explicit recipe-author
    # entry stays last).
    let qt6ModulePathDirs = m9r33Collect2Qt6CmakeModulePathDirs(
      projectRoot, pkgName)
    if qt6ModulePathDirs.len > 0:
      var hasModulePath = false
      for v in effectiveCacheVars:
        if v.startsWith("CMAKE_MODULE_PATH="):
          hasModulePath = true
          break
      if not hasModulePath:
        let entry = m9r33Emit2CmakeModulePathCacheVar(qt6ModulePathDirs)
        if entry.len > 0:
          effectiveCacheVars.add(entry)
    var hasGlesIncludeDir = false
    var hasGlesLibrary = false
    for v in effectiveCacheVars:
      if v.startsWith("GLESv2_INCLUDE_DIR="):
        hasGlesIncludeDir = true
      if v.startsWith("GLESv2_LIBRARY="):
        hasGlesLibrary = true
    if not hasGlesIncludeDir or not hasGlesLibrary:
      for entry in m9r33Emit2MesaGlesv2CacheVars(projectRoot, pkgName):
        let dEq = entry.find('=')
        if dEq <= 0:
          continue
        let key = entry[0 ..< dEq]
        if key == "GLESv2_INCLUDE_DIR" and hasGlesIncludeDir:
          continue
        if key == "GLESv2_LIBRARY" and hasGlesLibrary:
          continue
        effectiveCacheVars.add(entry)
  let configureEdge = cmake.configure(
    srcDir = srcDir,
    buildDir = buildDir,
    generator = generator,
    cacheVars = effectiveCacheVars,
    after = configureAfter,
    extraEnv = extraEnv)
  # M9.R.14g.6 — inline-exec build action. cmake's real "build" mode is
  # selected by the ``--build`` flag, NOT by a ``build`` subcommand
  # literal.
  #
  # M9.R.15f.3 — add ``--parallel`` so cmake auto-detects job count
  # and runs the underlying generator (typically make / ninja) with
  # full host parallelism. Without this flag cmake falls back to
  # the generator's default which for ``make`` is ``-j1``; qt6-base
  # is hundreds of compile units, so the serial default turns a
  # ~5 minute compile into an hour. cmake's ``--parallel`` without a
  # number reads CMAKE_BUILD_PARALLEL_LEVEL only when the underlying
  # generator (ninja/make) honors it; in practice ninja still ignores
  # CMAKE_BUILD_PARALLEL_LEVEL and falls back to nproc on a vanilla
  # cmake-4 build (verified M9.R.15q.7.1 on Linux: kwin spawned 343
  # cc1plus on a 32-core host even with extraEnv CMAKE_BUILD_PARALLEL_LEVEL=8).
  #
  # M9.R.15q.7.3 — opt-in numeric cap. When the recipe's extraEnv
  # carries an explicit ``CMAKE_BUILD_PARALLEL_LEVEL`` entry, we bake
  # ``--parallel <N>`` into the action argv. This keeps the action
  # fingerprint stable for recipes that DO NOT opt in (no env entry =
  # bare ``--parallel`` as before), and lets memory-bound recipes
  # (kwin / plasma-workspace / sddm) hard-cap parallelism without
  # changing the cmake_package signature. The argv mutation IS picked
  # up by the action-cache fingerprint, which is exactly the
  # invalidation we want for the opt-in recipes (the recipe's own
  # change already invalidates its cache, so the additional argv
  # mutation is free).
  var explicitParallel = ""
  for entry in extraEnv:
    if entry[0] == "CMAKE_BUILD_PARALLEL_LEVEL":
      explicitParallel = entry[1]
      break
  var buildArgv = @["cmake", "--build", buildDir, "--parallel"]
  if explicitParallel.len > 0:
    buildArgv.add(explicitParallel)
  if target.len > 0:
    buildArgv.add("--target")
    buildArgv.add(target)
  let buildStamp = projectRoot / ".repro" / "build" / "cmake-build.stamp"
  createDir(parentDir(buildStamp))
  # M9.R.15q.13 — explicitly bake LD_LIBRARY_PATH into the build script
  # so sibling-recipe helper binaries the cmake-spawned build invokes
  # at compile time (e.g. kcmutils' ``kcmdesktopfilegenerator`` from
  # plasma-workspace's KCM codegen) can dlopen their own transitive
  # Qt6/KF6 runtime deps even when those binaries' RUNPATH points at
  # the legacy ``/usr/local/lib`` install prefix.
  #
  # The build engine's action-env resolver populates LD_LIBRARY_PATH
  # from ``toolIdentityRefs`` via the M9.R.14e.* search-path channels,
  # but that env reaches the cmake-build sh process only — when ninja /
  # make spawn a sibling helper binary, the child inherits LD_LIBRARY_
  # PATH from the parent shell.  Empirically that propagation drops the
  # sibling install-mirror lib dirs on KDE recipes (the helper binaries
  # exit 127 with ``libQt6Core.so.6 not found``).  Baking the same set
  # of paths into the build script via ``export LD_LIBRARY_PATH`` makes
  # the channel bulletproof.  Inert in unit-test mode (empty
  # ``projectRoot``).
  proc m9r15q13StripDepConstraint(value: string): string =
    for i, ch in value:
      if ch == ' ' or ch == '>' or ch == '<' or ch == '=' or
          ch == '~' or ch == '^':
        return value[0 ..< i]
    return value
  var ldLibraryDirs: seq[string] = @[]
  if projectRoot.len > 0:
    # ``projectRoot`` is the recipe's package dir
    # (``recipes/packages/source/<pkg>``).  ``parentDir`` is the sibling
    # recipes' container (``recipes/packages/source``); siblings live
    # alongside as ``<recipesRoot>/<dep>/.repro/output/install/usr``.
    let recipesRoot = parentDir(projectRoot)
    var allDeps: seq[string] = @[]
    for raw in registeredNativeBuildDeps(pkgName):
      allDeps.add(m9r15q13StripDepConstraint(raw))
    for raw in registeredBuildDeps(pkgName):
      allDeps.add(m9r15q13StripDepConstraint(raw))
    for dep in allDeps:
      if dep.len == 0:
        continue
      let sibRoot = recipesRoot / dep / ".repro" / "output" / "install" / "usr"
      for sub in @["lib", "lib64"]:
        let candidate = sibRoot / sub
        if dirExists(candidate):
          var present = false
          for p in ldLibraryDirs:
            if p == candidate:
              present = true
              break
          if not present:
            ldLibraryDirs.add(candidate)
  let buildScript = block:
    var s = "set -e; "
    if ldLibraryDirs.len > 0:
      s.add("export LD_LIBRARY_PATH=\"")
      for i, d in ldLibraryDirs:
        if i > 0: s.add(":")
        s.add(d.replace("\\", "/").replace("\"", "\\\""))
      s.add(":${LD_LIBRARY_PATH:-}\"; ")
    var quoted: seq[string] = @[]
    for a in buildArgv:
      quoted.add("\"" & a.replace("\"", "\\\"") & "\"")
    s.add(quoted.join(" ") & "; ")
    s.add("touch \"" & buildStamp.replace("\\", "/") & "\"")
    s
  let buildEdge = buildAction(
    id = "cmake-build-" & pkgName,
    call = inlineExecCall(@["sh", "-c", buildScript]),
    deps = @[configureEdge.id],
    inputs = configureEdge.outputs,
    outputs = @[buildStamp],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "cmake_package.build",
    toolIdentityRefs = @["cmake", "sh"],
    env = extraEnv)
  # M9.R.14g.6 — inline-exec install action. cmake's real install mode
  # is selected by ``--install``, NOT by ``install`` subcommand.
  #
  # M9.R.14h.8 — match meson_package's destdir treatment: cmake's
  # ``--prefix`` argument is resolved relative to the action's cwd, NOT
  # to ``buildDir``, so the legacy ``destdir & prefix = "out/usr"``
  # form lands files at ``<cwd>/out/usr/...`` instead of the expected
  # ``<recipeRoot>/<buildDir>/<destdir>/usr/...``.  Stage-copy +
  # install-mirror both probe under the ``build/out/usr`` layout, so
  # files installed at the cwd-relative path go un-staged.  In provider
  # mode pass an absolute path; in unit-test mode keep the relative
  # form so existing tests stay green.
  #
  # ``effectiveDestRoot`` is the install-root WITHOUT the ``/usr``
  # suffix (mirrors meson_package's ``effectiveDestdir``); it's what
  # the per-artifact stage-copy + install-mirror actions consult to
  # find the upstream-installed files at ``<destRoot>/usr/lib*/``.
  # ``installArgv``'s ``--prefix`` is the same root WITH ``/usr``
  # appended so cmake itself stages under the canonical FHS layout.
  let providerProjectRootForInstall = activeProviderProjectRoot()
  let effectiveDestRoot =
    if providerProjectRootForInstall.len > 0:
      providerProjectRootForInstall / buildDir / destdir
    else:
      destdir
  let effectiveInstallPrefix = effectiveDestRoot & prefix
  let installArgv = @["cmake", "--install", buildDir, "--prefix", effectiveInstallPrefix]
  let installStamp = projectRoot / ".repro" / "build" / "cmake-install.stamp"
  createDir(parentDir(installStamp))
  let installScript = block:
    var s = "set -e; "
    # M9.R.15q.13.1 — same LD_LIBRARY_PATH baking as the build script,
    # so cmake --install's helper binaries (e.g. plugin-registration
    # binaries, ELF strippers from sibling toolchain recipes) inherit
    # the sibling install-mirror lib dirs.
    if ldLibraryDirs.len > 0:
      s.add("export LD_LIBRARY_PATH=\"")
      for i, d in ldLibraryDirs:
        if i > 0: s.add(":")
        s.add(d.replace("\\", "/").replace("\"", "\\\""))
      s.add(":${LD_LIBRARY_PATH:-}\"; ")
    var quoted: seq[string] = @[]
    for a in installArgv:
      quoted.add("\"" & a.replace("\"", "\\\"") & "\"")
    s.add(quoted.join(" ") & "; ")
    s.add("touch \"" & installStamp.replace("\\", "/") & "\"")
    s
  let installEdge = buildAction(
    id = "cmake-install-" & pkgName,
    call = inlineExecCall(@["sh", "-c", installScript]),
    deps = @[buildEdge.id],
    inputs = buildEdge.outputs,
    outputs = @[installStamp],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "cmake_package.install",
    toolIdentityRefs = @["cmake", "sh"],
    env = extraEnv)
  # M9.R.14e.5 — fold the recipe's declared ``nativeBuildDeps`` +
  # ``buildDeps`` into each action's ``toolIdentityRefs`` so the M9.R.14e.1
  # from-source search-path channels reach the action env at fork time.
  # Mirrors the same pattern in ``meson_package.nim`` /
  # ``autotools_package.nim``.
  proc stripConstraint(value: string): string =
    for i, ch in value:
      if ch == ' ' or ch == '>' or ch == '<' or ch == '=' or
          ch == '~' or ch == '^':
        return value[0 ..< i]
    return value
  var depRefs: seq[string] = @[]
  for raw in registeredNativeBuildDeps(pkgName):
    depRefs.add(stripConstraint(raw))
  for raw in registeredBuildDeps(pkgName):
    depRefs.add(stripConstraint(raw))
  # M9.R.15o.1 — virtually inject libxkbcommon + mesa as tool-identity
  # refs whenever any qt6-* dep is in the recipe's deps, so the M9.R.14e
  # search-path channels (PKG_CONFIG_PATH / CMAKE_PREFIX_PATH / CPATH /
  # LIBRARY_PATH / LD_LIBRARY_PATH) reach the action env at fork time.
  # Without this Qt6Gui's CMake config-package ``find_dependency(XKB)`` +
  # ``find_dependency(GLESv2)`` walks miss the sibling install-mirrors
  # at ``recipes/packages/source/{libxkbcommon,mesa}/.repro/output/...``
  # and ``find_package(Qt6Gui REQUIRED)`` fails for every KF6 / Plasma
  # consumer. The helper is inert when no qt6-* dep is present and
  # silently skips deps the recipe already declared (so the M9.R.15n
  # hand-patched recipes don't see duplicate refs).
  if projectRoot.len > 0:
    for extra in m9r15oCollectQt6TransitiveCmakeDeps(projectRoot, pkgName):
      depRefs.add(extra)
  appendRegisteredActionToolIdentityRefs(configureEdge.id, depRefs)
  appendRegisteredActionToolIdentityRefs(buildEdge.id, depRefs)
  appendRegisteredActionToolIdentityRefs(installEdge.id, depRefs)
  # M9.R.14h.8 — populate ``destdir`` with the SAME absolute install
  # prefix the install action passed via ``--prefix``.  meson_package
  # already does this (the destdir on the result is what stage-copy +
  # install-mirror probe to find the on-disk install tree).  Without
  # this, slicing methods ran stage-copy against the relative ``out``
  # value and missed the on-disk ``build/out/usr/lib*/`` layout.
  CmakePackageResult(
    buildEdge: configureEdge,
    compileEdge: buildEdge,
    installEdge: installEdge,
    destdir: effectiveDestRoot,
    components: standardComponents())
