## DSL-port M9.R.2b — Layer-1 ``autotools_package`` multi-artifact
## constructor.
##
## Internally drives ``<srcDir>/configure`` + ``make`` + ``make
## install DESTDIR=...`` and returns an ``AutotoolsPackageResult``.
##
## ## M9.R.12.1 — configure edge routed through ``inlineExecCall``
##
## The configure edge used to call ``sh_module.shell`` which records a
## typed ``publicCliCall("sh", "sh", ...)``. The engine's path-mode
## resolver requires a profile for any non-builtin executable name in
## the lowering pipeline. Recipes consuming ``autotools_package`` were
## NOT declaring ``"sh"`` in their ``nativeBuildDeps:`` block (only
## ``gcc`` / ``make`` / ``perl`` / etc.), so the resolver hard-failed
## with ``tool-resolution failed: action sh-<hex> references executable
## sh but no tool profile was resolved for it`` for every from-source
## autotools recipe (binutils, expat, autoconf, etc.).
##
## The fix mirrors the production ``from-source-custom`` convention:
## emit the configure action via ``inlineExecCall(["sh", "-c", script],
## ...)`` with ``toolIdentityRefs = @["sh"]``. The engine recognises
## ``reprobuild.builtin.exec`` calls in ``lowerGraphAction`` and skips
## profile lookup; the ``toolIdentityRefs`` ride lets the engine
## prepend the resolved ``sh`` bin dir to PATH at fork time via the
## ``BuildEngineConfig.toolIdentityResolver`` hook. ``sh`` itself still
## resolves through the stdlib ``package sh`` provisioning channels
## (nix / scoop / tarball) via the M9.R.9 / M9.R.10a fall-through path.

{.experimental: "callOperator".}

import std/strutils

import repro_project_dsl

import ../types/package_result
# ``sh`` is no longer invoked through the typed CLI surface (the
# configure edge below uses ``inlineExecCall`` instead), but the module
# import is preserved so the ``package sh:`` provisioning blocks land
# in ``registeredPackages()`` and the M9.R.9 / M9.R.10a stdlib fall-
# through path can resolve ``toolIdentityRefs = @["sh"]`` for the
# configure action's PATH plumbing at fork time.
import ../packages/sh as sh_module
import ../packages/make as make_module

proc autotools_package*(srcDir: string;
                        buildDir = "build";
                        destdir = "out";
                        prefix = "/usr";
                        configureOptions: seq[string] = @[];
                        installTarget = "install"): AutotoolsPackageResult =
  ## Configure → build → install pipeline for an upstream autotools
  ## project. The configure step is emitted via ``inlineExecCall`` so
  ## the engine skips path-mode profile lookup for ``sh`` (recipes
  ## consuming this constructor don't need to declare ``"sh"`` in
  ## ``nativeBuildDeps:``); the subsequent steps run ``make`` typed-
  ## style and rely on the recipe's existing ``"make"`` dep.
  var configureArgs = @["--prefix=" & prefix]
  for o in configureOptions:
    configureArgs.add(o)
  let configureScript = srcDir & "/configure " & configureArgs.join(" ")
  let configureArgv = @["sh", "-c", configureScript]
  # Action id: use the inlineExecCall's built-in stable hashing via
  # ``defaultToolActionId``. The call's executableName is
  # ``"exec"`` (the builtin) and the hash incorporates the literal argv,
  # so two recipes with different configureOptions produce distinct ids
  # without colliding even when they share a srcDir/prefix.
  let call = inlineExecCall(configureArgv)
  let actionId = defaultToolActionId(call)
  let configureEdge = buildAction(
    id = actionId,
    call = call,
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "autotools_package.configure",
    toolIdentityRefs = @["sh"])
  let buildEdge = make(workDir = buildDir, vars = @[], targets = @[])
  let installEdge = make(
    workDir = buildDir,
    targets = @[installTarget],
    vars = @["DESTDIR=" & destdir])
  AutotoolsPackageResult(
    buildEdge: configureEdge,
    compileEdge: buildEdge,
    installEdge: installEdge,
    destdir: destdir,
    components: standardComponents())
