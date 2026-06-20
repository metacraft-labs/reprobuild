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
    id = mesonFetchActionId(packageName),
    call = inlineExecCall(argv),
    inputs = @[],
    outputs = @[stamp],
    pool = "fetch",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "meson_package.fetch." & hashAlgTag,
    toolIdentityRefs = @["sh"])
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
  var refs: seq[string] = @[]
  for raw in registeredNativeBuildDeps(pkgName):
    refs.add(m9r14eStripConstraint(raw))
  for raw in registeredBuildDeps(pkgName):
    refs.add(m9r14eStripConstraint(raw))
  appendRegisteredActionToolIdentityRefs(actionId, refs)

proc meson_package*(srcDir: string;
                    buildDir = "build";
                    destdir = "out";
                    prefix = "/usr";
                    buildtype = "release";
                    configureOptions: seq[string] = @[];
                    crossFile = "";
                    nativeFile = ""): MesonPackageResult =
  ## Configure → build → install pipeline for an upstream meson
  ## project. v1 ignores ``--tags`` filtering at install time — the
  ## ``.files("man")`` slicer returns the whole install edge and the
  ## caller resolves the specific component path via ``components``.
  ##
  ## M9.R.12.4: when the active package declares ``fetch:`` the setup
  ## action gains a dep on an auto-emitted fetch action so the engine
  ## sequences source extraction before ``meson setup``.
  let pkgName = currentOwningPackage()
  let projectRoot = activeProviderProjectRoot()
  let extractedRel = block:
    let raw = registeredFetchSpec(pkgName).extractedRoot
    if raw.len > 0: raw else: "src"
  let fetchActOpt = maybeEmitFetchAction(pkgName, projectRoot, extractedRel)
  var setupAfter: seq[BuildActionDef] = @[]
  if fetchActOpt.isSome:
    setupAfter.add(fetchActOpt.get())
  let setup = meson.setup(
    srcDir = srcDir,
    buildDir = buildDir,
    prefix = prefix,
    buildtype = buildtype,
    options = configureOptions,
    crossFile = crossFile,
    nativeFile = nativeFile,
    after = setupAfter)
  # M9.R.14e.5 — thread every nativeBuildDeps + buildDeps name onto the
  # setup action's ``toolIdentityRefs`` so the M9.R.14e.1 env-prepend
  # pass at fork time threads each from-source dep's
  # ``pkgConfigSearchList`` etc. onto ``PKG_CONFIG_PATH`` /
  # ``CMAKE_PREFIX_PATH`` / ``CPATH`` / ``LIBRARY_PATH`` /
  # ``LD_LIBRARY_PATH``. Without this the meson.setup typed-tool action
  # carries no refs and the from-source resolver's search-path channels
  # never make it into the action env.
  m9r14eThreadRecipeDepsAsToolRefs(setup.id, pkgName)
  # M9.R.14g.9 — compile MUST depend on setup. Mirror the install fix
  # below; the automatic-monitor evidence on ``meson setup`` may not
  # land before the scheduler dispatches ``meson compile``, races the
  # build.ninja file write, and breaks vendored-subproject builds.
  let compileEdge = meson.compile(workDir = buildDir, after = @[setup])
  m9r14eThreadRecipeDepsAsToolRefs(compileEdge.id, pkgName)
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
    after = @[compileEdge])
  m9r14eThreadRecipeDepsAsToolRefs(installEdge.id, pkgName)
  MesonPackageResult(
    buildEdge: setup,
    compileEdge: compileEdge,
    installEdge: installEdge,
    destdir: effectiveDestdir,
    components: standardComponents())
