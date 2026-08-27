## DSL-port M9.R.2b — Layer-1 ``meson_package`` multi-artifact
## constructor.
##
## Internally drives ``meson.setup`` + ``meson.compile`` + ``meson.install``
## and returns a ``MesonPackageResult`` whose ``.executable(name)`` /
## ``.library(name)`` / ``.files(name)`` methods slice install
## components into individual artifact bindings.
##
## The v1 component layout is the standard ``meson install`` layout
## (``usr/bin`` for runtime, ``usr/lib`` for libraries, ``usr/share/man``
## for man pages, ...) — see ``types/package_result.standardComponents``.
##
## ## M9.R.12.4 — auto-emit fetch action when recipe declared one
##
## Recipes with an explicit ``build:`` block route through the per-
## project provider; the convention layer's ``emitFragment`` (which
## owns fetch-action emission for the from-source-* family) is NOT
## called for them. ``meson_package`` therefore auto-emits a fetch
## action when ``registeredFetchSpec(currentOwningPackage())`` returns
## a populated spec AND the active provider context is available, and
## threads it as a dep of the ``meson.setup`` step. See the
## ``autotools_package`` constructor for the canonical rationale.

{.experimental: "callOperator".}

import std/[options, os, strutils]

import repro_project_dsl

import ../types/package_result
import ../packages/meson as meson_module
import ../packages/sh as sh_module
# M9.R.14d.3 — auto-import the bootstrap toolchain + ninja so their
# stdlib ``package <name>:`` provisioning blocks land in
# ``registeredPackages()`` for any recipe that consumes
# ``meson_package``. Without this, a recipe's
# ``nativeBuildDeps: "gcc"``/``"ninja"`` use carries an executable
# name but no provisioning channels, and the bootstrap cycle-break's
# stdlib fall-through fails with "no provisioning channel declared".
# Same idiom autotools_package uses for the autotools regen layer
# (M9.R.14c.9).
import ../packages/gcc as gcc_module
import ../packages/ninja as ninja_module
import ../packages/make as make_module
import ../packages/pkg_config as pkg_config_module

# ---------------------------------------------------------------------------
# Fetch action (M9.R.12.4) — shared shape with ``autotools_package``.
# Kept inline so the constructor module has no cross-stdlib dep on a
# shared "fetch" submodule (the convention-layer ``emitFetchAction``
# lives in ``repro_standard_provider`` which the stdlib doesn't import).
# ---------------------------------------------------------------------------

const FetchScratchSubdir = ".repro/fetch"

proc mesonFetchActionId(packageName: string): string =
  var sanitized = ""
  for ch in packageName:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      sanitized.add(ch)
    else:
      sanitized.add('_')
  if sanitized.len == 0:
    sanitized = "x"
  "meson-fetch-" & sanitized

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
  let hashTools =
    case spec.hashAlg
    of dshaSha256: @["sha256sum"]
    of dshaBlake3: @["b2sum", "blake3sum"]
  # M9.R.15q.5.4 — support relative ``file:./vendor/...`` URL form so
  # recipes that vendor a tarball can reference it without baking the
  # host's absolute path into the recipe (mirrors the equivalent
  # autotools_package helper).
  var resolvedUrl = spec.url
  if resolvedUrl.startsWith("file:./") or resolvedUrl.startsWith("file:../"):
    let relPath = resolvedUrl[5 .. ^1]
    let absPath = projectRoot / relPath
    let posixAbs = absPath.replace("\\", "/")
    resolvedUrl = "file://" & posixAbs
  let fetchToolRefs = shellFetchToolIdentityRefs(hashTools,
    copiesDataFile = spec.kind == dfkDataFile,
    archiveUrl = resolvedUrl)
  let escapedHash = spec.hashHex.replace("\"", "\\\"")
  let escapedTarball = tarball.replace("\\", "/").replace("\"", "\\\"")
  let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
  let escapedExtracted = extracted.replace("\\", "/").replace("\"", "\\\"")
  let staged = extracted & ".repro-extract-" & spec.hashHex
  let escapedStaged = staged.replace("\\", "/").replace("\"", "\\\"")
  var script = "set -e; "
  script.add("rm -rf \"" & escapedStaged & "\"; ")
  script.add("mkdir -p \"" & escapedStaged & "\"; ")
  script.appendCurlDownload(tarball, resolvedUrl)
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
  if spec.kind == dfkDataFile:
    script.add("cp \"" & escapedTarball & "\" \"" &
      escapedStaged & "/source\"; ")
  else:
    script.appendTarExtraction(tarball, staged, spec.extractStrip)
  script.add("rm -rf \"" & escapedExtracted & "\"; ")
  script.add("mv \"" & escapedStaged & "\" \"" & escapedExtracted & "\"; ")
  script.add(": > \"" & escapedStamp & "\"")
  let argv = @["sh", "-c", script]
  let act = buildAction(
    id = mesonFetchActionId(packageName),
    call = inlineExecCall(argv),
    inputs = @[],
    outputs = @[stamp],
    pool = "fetch",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "meson_package.fetch." & hashAlgTag,
    toolIdentityRefs = fetchToolRefs)
  some(act)

# ---------------------------------------------------------------------------
# Constructor
# ---------------------------------------------------------------------------

proc m9r14eStripConstraint(value: string): string =
  ## Strip the version-constraint suffix off a raw constraint string so
  ## ``"wayland >=1.22"`` → ``"wayland"``. The ref-name matching in
  ## ``mkToolIdentityResolver`` does the same trim via a
  ## prefix-with-space-or-comparator probe; we strip here for
  ## cleanliness + so the lowered-graph snapshot reads as a list of
  ## names rather than constraints.
  for i, ch in value:
    if ch == ' ' or ch == '>' or ch == '<' or ch == '=' or
        ch == '~' or ch == '^':
      return value[0 ..< i]
  return value

proc m9r14eThreadRecipeDepsAsToolRefs(actionId, pkgName: string) =
  ## DSL-port M9.R.14e.5 — fold the recipe's declared ``nativeBuildDeps``
  ## + ``buildDeps`` constraint strings (e.g. ``"wayland >=1.22"``,
  ## ``"libxml2 >=2.9"``) into the registry's ``toolIdentityRefs`` seq
  ## for the action identified by ``actionId``, so the engine's
  ## env-prepend pass at fork time threads each dep's
  ## ``pkgConfigSearchList`` / ``cmakePrefixList`` / ``cpathList`` /
  ## ``libraryPathList`` onto the meson action's env.
  ##
  ## Why mutate the registry (not the local value the typed-tool wrapper
  ## returned): ``buildActionRegistry.add(...)`` stores a copy by value;
  ## mutating the wrapper's return value doesn't affect the registry
  ## entry the engine sees later. ``appendRegisteredActionToolIdentityRefs``
  ## (in ``repro_project_dsl``) updates the registry in place.
  var nativeRefs: seq[string] = @[]
  for raw in registeredNativeBuildDeps(pkgName):
    nativeRefs.add(m9r14eStripConstraint(raw))
  var buildRefs: seq[string] = @[]
  for raw in registeredBuildDeps(pkgName):
    buildRefs.add(m9r14eStripConstraint(raw))
  let refs = nativeRefs & buildRefs
  appendRegisteredActionToolIdentityRefs(actionId, refs)
  classifyRegisteredActionToolIdentityRefs(actionId, buildRefs)

proc meson_package*(srcDir: string;
                    buildDir = "build";
                    destdir = "out";
                    prefix = "/usr";
                    buildtype = "release";
                    configureOptions: seq[string] = @[];
                    crossFile = "";
                    nativeFile = "";
                    wrapMode = "nodownload";
                    extraEnv: seq[(string, string)] = @[];
                    srcPatches: seq[string] = @[]): MesonPackageResult =
  ## Configure → build → install pipeline for an upstream meson
  ## project. v1 ignores ``--tags`` filtering at install time — the
  ## ``.files("man")`` slicer returns the whole install edge and the
  ## caller resolves the specific component path via ``components``.
  ##
  ## M9.R.12.4: when the active package declares ``fetch:`` the setup
  ## action gains a dep on an auto-emitted fetch action so the engine
  ## sequences source extraction before ``meson setup``.
  ##
  ## ``srcPatches`` (M9.R.15q.12.2): list of ``sed -i`` expressions to
  ## apply to files inside the extracted source tree BEFORE meson setup
  ## runs. Each entry is a self-contained ``sh -c`` argv body (e.g.
  ## ``"sed -i 's/old/new/' src/foo.txt"``). Use this when a recipe
  ## needs to patch the upstream source — for example, the systemd
  ## recipe patches its vendored ``src/basic/linux/input-event-codes.h``
  ## to add ``KEY_LINK_PHONE`` (defined in linux 6.10 but missing from
  ## the v6.10-rc1 shim systemd v257 ships). Mirrors the cmake_package
  ## srcPatches channel (M9.R.15q.10.5) so meson recipes have the same
  ## per-recipe escape hatch the cmake recipes do.
  ##
  ## ``extraEnv`` applies per-edge environment overrides to setup,
  ## compile, and install. This matches ``cmake_package`` and keeps
  ## package-specific process controls scoped to the recipe pipeline.
  let pkgName = currentOwningPackage()
  let projectRoot = activeProviderProjectRoot()
  var effectiveConfigureOptions = configureOptions
  var hasExplicitLibdir = false
  for option in configureOptions:
    if option.startsWith("libdir=") or option.startsWith("--libdir="):
      hasExplicitLibdir = true
      break
  if not hasExplicitLibdir:
    # Meson's host-dependent default may be lib/<multiarch>, while the
    # package result and install mirror expose libraries from usr/lib.
    effectiveConfigureOptions.insert("libdir=lib", 0)
  let extractedRel = block:
    let raw = registeredFetchSpec(pkgName).extractedRoot
    if raw.len > 0: raw else: "src"
  let fetchActOpt = maybeEmitFetchAction(pkgName, projectRoot, extractedRel)
  var setupAfter: seq[BuildActionDef] = @[]
  if fetchActOpt.isSome:
    setupAfter.add(fetchActOpt.get())
  # M9.R.15q.12.2 — when ``srcPatches`` is non-empty, emit a per-recipe
  # source-patch action that runs every ``sed -i`` expression against
  # the extracted source tree, ordered AFTER the fetch action +
  # BEFORE the meson setup action. Mirrors cmake_package's pattern.
  if srcPatches.len > 0 and projectRoot.len > 0:
    let patchStamp = projectRoot / ".repro" / "build" / "meson-patch.stamp"
    createDir(parentDir(patchStamp))
    let escapedStamp = patchStamp.replace("\\", "/").replace("\"", "\\\"")
    var script = "set -e; "
    for sedExpr in srcPatches:
      # ``sedExpr`` is a complete ``sh -c`` argv body (e.g.
      # ``sed -i 's/X/Y/' src/foo.txt``). Append in declaration order
      # so subsequent patches see prior edits.
      script.add(sedExpr & "; ")
    script.add(": > \"" & escapedStamp & "\"")
    var patchDeps: seq[string] = @[]
    var patchInputs: seq[string] = @[]
    if fetchActOpt.isSome:
      patchDeps.add(fetchActOpt.get().id)
      for out0 in fetchActOpt.get().outputs:
        patchInputs.add(out0)
    let patchEdge = buildAction(
      id = "meson-patch-" & pkgName,
      call = inlineExecCall(@["sh", "-c", script]),
      deps = patchDeps,
      inputs = patchInputs,
      outputs = @[patchStamp],
      pool = "fetch",
      dependencyPolicy = automaticMonitorPolicy(),
      commandStatsId = "meson_package.patch",
      toolIdentityRefs = @["sh"])
    setupAfter.add(patchEdge)
  if projectRoot.len > 0:
    let cleanStamp = projectRoot / ".repro" / "build" / "meson-clean.stamp"
    let buildDirAbs = projectRoot / buildDir
    var cleanIdentityParts = @[
      "reprobuild.meson-clean.v1",
      srcDir,
      buildDir,
      prefix,
      buildtype,
      crossFile,
      nativeFile,
      wrapMode,
    ]
    cleanIdentityParts.add(effectiveConfigureOptions)
    for entry in extraEnv:
      cleanIdentityParts.add(entry[0] & "=" & entry[1])
    let cleanIdentity = cleanIdentityParts.join("\x1e")
    let cleanScript = "set -e; rm -rf \"" &
      buildDirAbs.replace("\"", "\\\"") & "\"; : > \"" &
      cleanStamp.replace("\"", "\\\"") & "\""
    var cleanDeps: seq[string] = @[]
    var cleanInputs: seq[string] = @[]
    for predecessor in setupAfter:
      cleanDeps.add(predecessor.id)
      for output in predecessor.outputs:
        cleanInputs.add(output)
    let cleanEdge = buildAction(
      id = "meson-clean-build-dir-" & pkgName,
      call = inlineExecCall(@[
        "sh", "-c", cleanScript, "reprobuild-meson-clean", cleanIdentity]),
      deps = cleanDeps,
      inputs = cleanInputs,
      outputs = @[cleanStamp],
      # The existing build tree is intentionally discarded state, not an
      # input. Monitoring it would make the downstream setup/compile writes
      # invalidate this cleanup edge on every warm build.
      dependencyPolicy = automaticMonitorPolicy(@[buildDirAbs]),
      commandStatsId = "meson_package.clean_build_dir",
      toolIdentityRefs = @["sh", "rm"])
    setupAfter = @[cleanEdge]

  var setupIdentityInputs: seq[string] = @[]
  for predecessor in setupAfter:
    setupIdentityInputs.add(predecessor.outputs)
  let setup = meson.setup(
    srcDir = srcDir,
    buildDir = buildDir,
    prefix = prefix,
    buildtype = buildtype,
    options = effectiveConfigureOptions,
    crossFile = crossFile,
    nativeFile = nativeFile,
    wrapMode = wrapMode,
    after = setupAfter,
    extraEnv = extraEnv)
  # M9.R.14e.5 — thread every nativeBuildDeps + buildDeps name onto the
  # setup action's ``toolIdentityRefs`` so the M9.R.14e.1 env-prepend
  # pass at fork time threads each from-source dep's
  # ``pkgConfigSearchList`` etc. onto ``PKG_CONFIG_PATH`` /
  # ``CMAKE_PREFIX_PATH`` / ``CPATH`` / ``LIBRARY_PATH`` /
  # ``LD_LIBRARY_PATH``. Without this the meson.setup typed-tool action
  # carries no refs and the from-source resolver's search-path channels
  # never make it into the action env.
  m9r14eThreadRecipeDepsAsToolRefs(setup.id, pkgName)
  # M9.R.79.2 — declare the write scope + read-only source scope for
  # spec R7 (double-write reject) + R6 (source-write reject)
  # enforcement.  meson.setup writes ``build.ninja`` etc. into
  # ``<buildDir>``; the upstream source at ``<srcDir>`` MUST NOT be
  # written to by setup.  Both paths are resolved against the recipe's
  # ``activeProviderProjectRoot()`` so the enforcement layer sees the
  # SAME shape the file monitor emits (absolute host paths); when the
  # provider context is absent (unit-test mode) we fall back to the
  # relative form so existing tests stay byte-identical.  Sequential
  # setup/compile/install edges share the same buildDir scope through
  # the dep chain, which the R7 pass exempts (M9.R.75.3.1 dep-chain
  # relaxation).
  let m9r79ProjectRoot = activeProviderProjectRoot()
  let m9r79BuildDirAbs =
    if m9r79ProjectRoot.len > 0: m9r79ProjectRoot / buildDir
    else: buildDir
  let m9r79SrcDirAbs =
    if m9r79ProjectRoot.len > 0: m9r79ProjectRoot / srcDir
    else: srcDir
  setRegisteredActionDeclaredOutputs(setup.id, @[m9r79BuildDirAbs])
  setRegisteredActionReadOnlyRoots(setup.id, @[m9r79SrcDirAbs])
  setRegisteredActionDependencyPolicy(setup.id,
    automaticMonitorPolicy(@[m9r79BuildDirAbs]))
  # M9.R.14g.9 — compile MUST depend on setup. Mirror the install fix
  # below; the automatic-monitor evidence on ``meson setup`` may not
  # land before the scheduler dispatches ``meson compile``, races the
  # build.ninja file write, and breaks vendored-subproject builds.
  let buildNinja = m9r79BuildDirAbs / "build.ninja"
  let refreshGeneratedMtime = buildAction(
    id = "meson-refresh-generated-mtime-" & pkgName,
    call = inlineExecCall(@["sh", "-c", "touch \"" &
      buildNinja.replace("\"", "\\\"") & "\""]),
    deps = @[setup.id],
    inputs = setupIdentityInputs,
    outputs = @[buildNinja],
    dependencyPolicy = automaticMonitorPolicy(@[m9r79BuildDirAbs]),
    commandStatsId = "meson_package.refresh_generated_mtime",
    toolIdentityRefs = @["sh"])
  var compileEdge = meson.compile(workDir = buildDir,
    after = @[refreshGeneratedMtime], extraEnv = extraEnv)
  compileEdge.inputs = setupIdentityInputs
  setRegisteredActionInputs(compileEdge.id, setupIdentityInputs)
  setRegisteredActionDependencyPolicy(compileEdge.id,
    automaticMonitorPolicy(@[m9r79BuildDirAbs]))
  m9r14eThreadRecipeDepsAsToolRefs(compileEdge.id, pkgName)
  # M9.R.79.2 — compile continues writing to buildDir; source stays
  # read-only.  Sequential edge via ``after = @[setup]`` — R7 dep-chain
  # relaxation permits the shared write root.
  setRegisteredActionDeclaredOutputs(compileEdge.id, @[m9r79BuildDirAbs])
  setRegisteredActionReadOnlyRoots(compileEdge.id, @[m9r79SrcDirAbs])
  # M9.R.14d.7 — meson rejects relative ``--destdir`` (it tries to
  # resolve `wayland/out` under the action's cwd at install time and
  # fails with `No such file or directory`). In provider mode pass the
  # absolute project-root path; in unit-test mode keep the legacy
  # relative form so existing tests stay green. The absolute path
  # does NOT enter the action's callIdentity (only ``call`` does), so
  # the cache key stays stable across hosts with different filesystem
  # layouts — same recipe + same source = same fingerprint.
  let providerProjectRoot = activeProviderProjectRoot()
  let effectiveDestdir =
    if providerProjectRoot.len > 0:
      providerProjectRoot / buildDir / destdir
    else:
      destdir
  # M9.R.14g.9 — install MUST depend on compile, not just on setup.
  # Without the explicit `after`, the scheduler may launch
  # ``meson install`` in parallel with ``meson compile`` when the
  # automatic-monitor evidence on compile hasn't landed yet (e.g. for
  # glib2 where ``meson compile`` rebuilds a vendored pcre2 subproject
  # in parallel with the parent build, racing the ninja log file write).
  # Symptom: ``ninja: warning: premature end of file; recovering`` with
  # exit 127 on the install action.
  let installEdge = meson.install(
    workDir = buildDir,
    destdir = effectiveDestdir,
    tags = @[],
    after = @[compileEdge],
    extraEnv = extraEnv)
  m9r14eThreadRecipeDepsAsToolRefs(installEdge.id, pkgName)
  # M9.R.79.2 — install writes the DESTDIR-staged tree at
  # ``effectiveDestdir``; source stays read-only.  The install-mirror
  # emit stage that runs downstream (see
  # ``types/package_result.emitInstallTreeMirror``) declares its own
  # scope; here we cover the meson install step only.
  setRegisteredActionDeclaredOutputs(installEdge.id, @[effectiveDestdir])
  setRegisteredActionReadOnlyRoots(installEdge.id, @[m9r79SrcDirAbs])
  MesonPackageResult(
    buildEdge: setup,
    compileEdge: compileEdge,
    installEdge: installEdge,
    destdir: effectiveDestdir,
    components: standardComponents())
