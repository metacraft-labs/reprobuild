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

import std/[options, os, osproc, strutils]

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
# M9.R.14c.8 — auto-import the autotools regen layer + m4 + perl so
# their stdlib ``package <name>:`` provisioning blocks land in
# ``registeredPackages()`` for any recipe that consumes
# ``autotools_package``. Without this, the recipe's
# ``nativeBuildDeps: "autoconf"`` carries an executable name but no
# provisioning channels (``toInterfaceToolUse`` matches on
# ``pkg.packageName`` against the registered set), so the bootstrap
# cycle-break's stdlib fall-through fails with "no provisioning
# channel declared".
import ../packages/autoconf as autoconf_module
import ../packages/automake as automake_module
import ../packages/libtool as libtool_module
import ../packages/m4 as m4_module
import ../packages/perl as perl_module

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
  # M9.R.13b.4 — ``--force-local`` is the standard GNU/MSYS2 tar flag
  # that tells the extractor not to interpret a leading ``X:`` (drive
  # letter) as ``host:`` -- without it, ``tar -xf D:/.../foo.tar``
  # fails with ``tar: Cannot connect to D: resolve failed`` on Windows
  # tar implementations (MSYS2 / Git-for-Windows) that default to
  # rsh-style host parsing. Linux/macOS GNU tar accepts the same flag
  # silently so the script stays portable. See:
  # https://www.gnu.org/software/tar/manual/html_node/local.html
  script.add("tar --force-local -xf \"" & escapedTarball & "\" -C \"" &
    escapedExtracted & "\" --strip-components=" & $spec.extractStrip & "; ")
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
  # M9.R.14b.3: out-of-tree autotools pattern. The previous shape ran
  # ``./src/configure`` from the recipe root, which wrote ``Makefile``
  # directly into the recipe root, NOT into the ``buildDir`` subdir
  # the downstream ``make -C build`` actions expect. On Linux this
  # surfaced as ``make: *** build: No such file or directory.  Stop.``
  # — the ``-C build`` flag pointed at a directory that ``configure``
  # had never created. (Pre-M9.R.14b the issue was hidden because the
  # Linux smoke trip happened earlier, at runquotad resolution.)
  #
  # The fix is the canonical autotools out-of-tree pattern: create the
  # buildDir, cd into it, run ``../src/configure`` (relative path
  # adjusts srcDir from a buildDir vantage point), so the generated
  # ``Makefile`` lands under ``buildDir/`` exactly where the downstream
  # ``make -C buildDir`` actions look for it. This mirrors the gcc
  # recipe's ``from-source-custom`` four-shell-action sequence (mkdir
  # / cd / configure / make) but keeps it inline so the higher-level
  # ``autotools_package`` constructor stays a single fire-and-forget
  # call site for recipes.
  #
  # ``srcDir`` is treated as a recipe-root-relative path; from the
  # buildDir vantage point we prepend ``../`` so e.g. ``./src``
  # becomes ``../src``. We strip a leading ``./`` from ``srcDir``
  # to keep the prepend clean.
  var relSrcDir = srcDir
  if relSrcDir.startsWith("./"):
    relSrcDir = relSrcDir[2 .. ^1]
  elif relSrcDir.startsWith("/"):
    # Absolute path: leave as-is.
    discard
  let srcFromBuild =
    if relSrcDir.len > 0 and relSrcDir[0] == '/': relSrcDir
    else: "../" & relSrcDir
  let configureScript =
    "mkdir -p " & buildDir & " && cd " & buildDir & " && " &
    srcFromBuild & "/configure " & configureArgs.join(" ")
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
  # M9.R.13b.5 — thread the configure edge as a sequencing dep through
  # the ``make`` build + install actions. Without this the engine sees
  # three independent actions (configure, compile, install) and may
  # schedule the compile concurrently with configure -- the recipe's
  # ``./src/configure`` writes ``build/Makefile`` which the make
  # invocations require as input, so an out-of-order schedule fails
  # with ``make: *** No rule to make target ...`` / ``Makefile not
  # found``. cmake_package + meson_package don't trip on this because
  # their configure actions declare ``buildDir`` as an output and the
  # build action declares ``buildDir`` as an input, so
  # ``inferDeclaredActionDeps`` (M5 / Recipe-Val M8) auto-wires the
  # edge via the output-producer table. The make typed CLI doesn't
  # carry a ``-C buildDir`` output slot so we have to wire it
  # explicitly via the ``after:`` parameter the typed-tool macro
  # generator emits on every typed-tool call site.
  #
  # M9.R.14c.1 — parallel make via ``MAKEFLAGS`` env-var injection.
  # The single-threaded make invocation dominated wall time on every
  # autotools-driven from-source recipe (binutils, gcc, expat,
  # autoconf, automake, libtool, ...): a 30-minute binutils compile
  # collapsed to ~4 minutes on a 32-core host once make ran with
  # ``-j N``. We compute ``N = max(1, min(countProcessors(), 8))`` at
  # action-emit time so the speedup applies anywhere.
  #
  # **Determinism guard.** The action's cache fingerprint
  # (``BuildAction.weakFingerprint``) is derived from the action ``id``
  # via ``weakFingerprintFromText(id)`` in ``repro_build_engine``. The
  # ``id`` here is derived from ``defaultToolActionId(call)``, whose
  # input is ``callIdentity(call)`` — the package name + executable
  # name + subcommand + per-argument encoded values. Neither
  # ``extraEnv`` nor the spawned-process ``BuildAction.env`` enters
  # the fingerprint. So passing ``MAKEFLAGS=-j N`` via ``extraEnv``
  # keeps the cache key BYTE-IDENTICAL across hosts with different
  # core counts. Same recipe + same source → same cache key.
  #
  # We deliberately do NOT pass ``-j N`` via the typed ``jobs`` flag
  # because that would land in ``callIdentity`` and the action id
  # would vary with N — defeating determinism.
  let jobs = max(1, min(countProcessors(), 8))
  let makeflags = "-j" & $jobs
  let buildEdge = make(workDir = buildDir, vars = @[], targets = @[],
    after = @[configureEdge],
    extraEnv = @[("MAKEFLAGS", makeflags)])
  # M9.R.14b.3b: install must wait for compile to finish; the prior
  # ``after = @[configureEdge]`` form let the engine schedule install
  # in parallel with compile (both only depended on configure), and
  # install raced ahead expecting object files that compile had not
  # yet emitted. Threading ``buildEdge`` (compile) onto install's
  # ``after`` list is the natural sequencing: configure -> compile ->
  # install. The configure dep is still implied through compile so we
  # don't need to keep it explicitly, but the chain is more readable
  # spelt out.
  let installEdge = make(
    workDir = buildDir,
    targets = @[installTarget],
    vars = @["DESTDIR=" & destdir],
    after = @[configureEdge, buildEdge],
    extraEnv = @[("MAKEFLAGS", makeflags)])
  AutotoolsPackageResult(
    buildEdge: configureEdge,
    compileEdge: buildEdge,
    installEdge: installEdge,
    destdir: destdir,
    buildDir: buildDir,
    components: standardComponents())
