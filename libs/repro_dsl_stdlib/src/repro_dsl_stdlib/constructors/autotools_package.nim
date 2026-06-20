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
##
## ## M9.R.12.4 — auto-emit fetch action when recipe declared one
##
## Recipes that ship a ``fetch:`` block (URL + sha256) AND an explicit
## ``build:`` block (like every from-source-* recipe in
## ``recipes/packages/source/``) used to land in a state where the
## convention layer's ``emitFragment`` was skipped (per-project
## providers don't dispatch through the standard provider) but the
## recipe's ``build:`` body assumed the convention emitted a fetch
## action that wrote the extracted source to ``./src/``. Result: the
## configure step ran with the source missing, ``./src/configure``
## failed with ``No such file or directory``, exit 127.
##
## ``autotools_package`` now reads ``registeredFetchSpec(packageName)``
## via ``currentOwningPackage()`` + ``activeProviderProjectRoot()`` and
## emits a fetch action when the
## spec carries a non-empty URL + hashHex. The configure action gains
## a dep on the fetch action's stamp output so the engine sequences
## them correctly. When no fetch is registered the helper is inert and
## the constructor's behaviour matches the M9.R.12.1 baseline byte-
## for-byte — recipes that explicitly drove ``shell "git clone ..."``
## in their ``build:`` body before this milestone still work.

{.experimental: "callOperator".}

import std/[options, os, strutils]

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

# ---------------------------------------------------------------------------
# Fetch action (M9.R.12.4)
# ---------------------------------------------------------------------------

const FetchScratchSubdir = ".repro/fetch"

proc autotoolsFetchActionId(packageName: string): string =
  ## Stable per-package fetch action id. Distinct from the
  ## ``ccpp-fetch-<pkg>`` id used by the standard-provider's convention
  ## layer so the two emitters can coexist (e.g. a recipe routed through
  ## both a convention sentinel + an autotools_package constructor body
  ## won't collide on the action registry).
  var sanitized = ""
  for ch in packageName:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      sanitized.add(ch)
    else:
      sanitized.add('_')
  if sanitized.len == 0:
    sanitized = "x"
  "autotools-fetch-" & sanitized

proc maybeEmitFetchAction(packageName, projectRoot, extractedRel: string):
    Option[BuildActionDef] =
  ## Look up the package's registered ``fetch:`` spec; emit a fetch
  ## action when the URL + hash are present. Returns ``none`` for
  ## recipes that don't declare ``fetch:`` (the constructor's pre-
  ## M9.R.12.4 behaviour). Caller threads the returned action's id +
  ## stamp into the configure action's ``deps`` + ``inputs``.
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
  # Download (curl) → hash-verify → extract → touch stamp. ``file://``
  # URLs are handled by curl natively for the vendored-tarball case.
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
  script.add("tar -xf \"" & escapedTarball & "\" -C \"" & escapedExtracted &
    "\" --strip-components=" & $spec.extractStrip & "; ")
  script.add("touch \"" & escapedStamp & "\"")
  let argv = @["sh", "-c", script]
  let act = buildAction(
    id = autotoolsFetchActionId(packageName),
    call = inlineExecCall(argv),
    inputs = @[],
    outputs = @[stamp],
    pool = "fetch",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "autotools_package.fetch." & hashAlgTag,
    toolIdentityRefs = @["sh"])
  some(act)

# ---------------------------------------------------------------------------
# Constructor
# ---------------------------------------------------------------------------

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
  ##
  ## When the active package declares a ``fetch:`` block (M9.R.12.4) a
  ## fetch action is auto-emitted and the configure action gains a dep
  ## on its stamp so the configure step doesn't run before the source
  ## tree is extracted.
  var configureArgs = @["--prefix=" & prefix]
  for o in configureOptions:
    configureArgs.add(o)
  let configureScript = srcDir & "/configure " & configureArgs.join(" ")
  let configureArgv = @["sh", "-c", configureScript]
  let call = inlineExecCall(configureArgv)
  let actionId = defaultToolActionId(call)
  # M9.R.12.4 — emit fetch action when the recipe declared ``fetch:``.
  # The extracted-root defaults to ``src`` (mirrors the convention's
  # ``fetchExtractedRoot`` default); recipes that override via
  # ``extractedRoot:`` thread the override through ``DslFetchSpec`` and
  # the helper resolves accordingly.
  let pkgName = currentOwningPackage()
  let projectRoot = activeProviderProjectRoot()
  let extractedRel = block:
    let raw = registeredFetchSpec(pkgName).extractedRoot
    if raw.len > 0: raw else: "src"
  let fetchActOpt = maybeEmitFetchAction(pkgName, projectRoot, extractedRel)
  var configureDeps: seq[string] = @[]
  var configureInputs: seq[string] = @[]
  if fetchActOpt.isSome:
    let fetchAct = fetchActOpt.get()
    configureDeps.add(fetchAct.id)
    for output in fetchAct.outputs:
      configureInputs.add(output)
  let configureEdge = buildAction(
    id = actionId,
    call = call,
    deps = configureDeps,
    inputs = configureInputs,
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
