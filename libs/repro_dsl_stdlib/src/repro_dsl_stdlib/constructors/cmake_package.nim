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
  let escapedUrl = spec.url.replace("\"", "\\\"")
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
                    target = ""): CmakePackageResult =
  ## Configure → build → install pipeline for an upstream cmake
  ## project. v1 leaves component selection up to the recipe
  ## (``component`` field on the install call); the standard layout
  ## table populated on the result mirrors meson's.
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
  let pkgName = currentOwningPackage()
  let projectRoot = activeProviderProjectRoot()
  let extractedRel = block:
    let raw = registeredFetchSpec(pkgName).extractedRoot
    if raw.len > 0: raw else: "src"
  let fetchActOpt = maybeEmitFetchAction(pkgName, projectRoot, extractedRel)
  var configureAfter: seq[BuildActionDef] = @[]
  if fetchActOpt.isSome:
    configureAfter.add(fetchActOpt.get())
  # M9.R.15i.1 — auto-thread Qt6 component cmake-config dirs from every
  # ``qt6-*`` dep's install-mirror so KF6 / Plasma recipes consuming
  # qt6-tools transitively can resolve ``find_package(Qt6 ...
  # LinguistTools REQUIRED)`` even though qt6-base + qt6-tools install
  # to separate sibling prefixes. Without this, Qt6's CMake-config-
  # package expects every requested component to live at the same
  # install prefix as Qt6Core and the probe fails. Inert in unit-test
  # mode (empty ``projectRoot``) and for non-Qt6 deps.
  var effectiveCacheVars = cacheVars
  if projectRoot.len > 0:
    let qt6CompDirs = m9r15iCollectQt6ComponentDirs(projectRoot, pkgName)
    for entry in m9r15iEmitQt6ComponentCacheVars(qt6CompDirs):
      effectiveCacheVars.add(entry)
  let configureEdge = cmake.configure(
    srcDir = srcDir,
    buildDir = buildDir,
    generator = generator,
    cacheVars = effectiveCacheVars,
    after = configureAfter)
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
  # number defers job-count to the CMAKE_BUILD_PARALLEL_LEVEL env
  # var, falling back to the build engine's pool budget. The
  # build-engine's compile pool already caps parallelism so we get
  # deterministic scheduling.
  var buildArgv = @["cmake", "--build", buildDir, "--parallel"]
  if target.len > 0:
    buildArgv.add("--target")
    buildArgv.add(target)
  let buildStamp = projectRoot / ".repro" / "build" / "cmake-build.stamp"
  createDir(parentDir(buildStamp))
  let buildScript = block:
    var s = "set -e; "
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
    toolIdentityRefs = @["cmake", "sh"])
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
    toolIdentityRefs = @["cmake", "sh"])
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
