## PHP / Composer language convention (Tier 2b) — M57.
##
## Third **Phase 2** language convention, immediately after M56
## ruby-bundler. Recognises a Composer ``composer.json`` at the
## project root and shells out to the stock ``composer`` driver for
## a single offline ``composer install --no-dev
## --optimize-autoloader --no-progress --quiet`` invocation
## (deploy mode = strict-lockfile, optimised autoloader = production
## class map). PHP is an interpreted language so there is no compile
## step per se — the "build" prepares ``vendor/`` with all packages
## vendored locally + emits a launcher ``.cmd`` shim that invokes
## ``php bin/<name>.php``.
##
## **Recognition contract**:
##   * ``<projectRoot>/composer.json`` exists (the Composer manifest).
##   * ``<projectRoot>/composer.lock`` exists (HARD precondition per
##     the M57 spec — the lockfile is Composer's reproducibility
##     guarantee, mirroring M42 csharp-dotnet's ``packages.lock.json``
##     and M56 ruby-bundler's ``Gemfile.lock`` HARD precondition;
##     Composer ``install`` resolves dependencies from the lockfile
##     when present and refuses to drift).
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists
##     AND ``uses:`` lists a PHP token (``php`` or ``composer``).
##     Composer is independent of PHP (it ships as a ``.phar`` users
##     fetch separately from ``https://getcomposer.org/``) so either
##     token is acceptable; declaring both is allowed but not required.
##   * at least one ``executable`` member declared (library targets +
##     PHAR packaging are DEFERRED to a follow-up M; see Honest scope
##     below).
##   * a ``php`` interpreter is on PATH.
##   * a ``composer`` driver is on PATH (Composer — usually
##     ``composer.bat``/``composer.phar`` on Windows, ``composer``
##     elsewhere).
##
## **Offline mode** (M57 keeps builds hermetic):
##   * The action runs ``composer install --no-dev
##     --optimize-autoloader --no-progress --quiet``. ``--no-dev``
##     omits ``require-dev`` packages (deploy mode).
##     ``--optimize-autoloader`` builds a classmap-authoritative
##     autoloader (production mode — same as
##     ``--classmap-authoritative`` in older Composer versions; both
##     forms emit an optimised classmap, the optimise flag is the
##     newer terminology). ``--no-progress`` suppresses Composer's
##     progress bar (the recognised "quiet" combo).
##     ``--quiet`` suppresses informational output.
##   * Real-world projects pulling external Packagist dependencies
##     should populate Composer's local cache once with network
##     access via ``composer install`` BEFORE invoking the convention
##     in offline mode, or ship a populated ``vendor/`` tree.
##     Composer's strict-lockfile mode (the default when
##     ``composer.lock`` is present) refuses to update the lockfile
##     and falls back to the lockfile resolution.
##   * The M57 fixture is stdlib-only (the ``composer.json`` declares
##     zero package dependencies) so the install is a near-no-op for
##     the fixture; the convention can be exercised end-to-end without
##     provisioning external Packagist packages.
##
## **Emitted actions**:
##   1. ``php-composer-install`` — single ``<composer> install
##      --no-dev --optimize-autoloader --no-progress --quiet`` action
##      under the project root. Inputs: the ``composer.json`` +
##      ``composer.lock``. Outputs:
##      ``<projectRoot>/vendor/.repro-composer-stamp`` (a sentinel
##      marker written by the wrapper — the ``vendor/`` tree's
##      content depends on the resolved dependency set and isn't
##      worth predicting at emit time; the sentinel gives the engine
##      a stable output path to fingerprint mirroring the M56
##      ruby-bundler convention's ``vendor/bundle/.repro-bundle-stamp``).
##      Uses ``automaticMonitorPolicy`` (automatic monitoring is the
##      spec baseline for opaque tools, Reprobuild-Development M17):
##      ``composer install`` spawns worker subprocesses (PHP scripts)
##      and the engine monitors their real read-set instead of trusting
##      only statically declared inputs.
##
##   2. ``php-composer-wrapper-<name>`` — one ``fs.writeText`` action
##      per declared executable. Outputs:
##      ``<projectRoot>/.repro/build/<name>/<name>.cmd`` (Windows) or
##      ``<projectRoot>/.repro/build/<name>/<name>`` (POSIX). The
##      script invokes ``php <entrypoint>`` with the caller's CWD set
##      to ``<projectRoot>`` so PHP and the autoloader can locate
##      ``vendor/autoload.php`` if the project's entry script
##      ``require``s it. The wrapper depends on the
##      ``php-composer-install`` action so the vendor/autoloader tree
##      is guaranteed populated by the time the launcher runs.
##
## **Entry-point resolution**:
##   * The M57 spec scopes down to ``bin/<name>.php`` as the canonical
##     entry-point shape (the conventional location for Composer
##     console-script entrypoints; Composer itself populates
##     ``vendor/bin/<name>`` for declared ``bin`` entries in
##     dependent packages, but the convention's own executable
##     members live at ``<root>/bin/<name>.php``). The wrapper's
##     ``php <entrypoint>`` argv pins ``<projectRoot>/bin/<name>.php``.
##     Per-member custom entrypoints are deferred to a follow-up M
##     (would require a new DSL field).
##
## **Honest scope** (deferred per M57 spec):
##   * Library targets (PHP packages shipped as ``library`` —
##     ``composer.json`` ``type=library`` with no ``bin`` entries) —
##     DEFERRED. The convention's executable wrapper is the M57
##     "build output"; library-only projects don't have one and
##     producing nothing is intentional.
##   * PHAR packaging (single-file distributable via ``box-project/box``
##     or hand-rolled phar manifest) — DEFERRED. The M57 fixture is
##     app-style with a launcher shim; the PHAR-packed binary path
##     is mentioned in the M57 spec but explicitly NOT shipped.
##   * Native PHP extensions (PECL — ``phpize`` + ``./configure``) —
##     DEFERRED. The convention's offline contract holds as long as
##     the compiled extension is pre-built and shipped on the host.
##   * Composer scripts (``scripts`` section in ``composer.json``
##     invoking post-install hooks) — DEFERRED. The convention runs
##     ``composer install`` literally; user-declared scripts under
##     ``"scripts"`` execute as a side effect (Composer's default
##     behaviour) but the convention doesn't model them as separate
##     actions.
##   * Composer phar binary installation (downloading
##     ``composer.phar`` and wrapping it in a ``composer.bat`` /
##     ``composer.cmd`` launcher) — DEFERRED. The convention requires
##     ``composer`` already on PATH; the documented provisioning path
##     for the M57 spec is the Windows installer from
##     ``https://getcomposer.org/Composer-Setup.exe``.
##   * Symfony / Laravel / Drupal application patterns — out of scope.
##   * ``composer run-script test`` discovery — deferred (mirrors
##     M40 / M41 / M42 / M43 / M46 / M55 / M56 test-task deferral).
##   * Per-version PHP management (``phpenv``, ``phpbrew``) — out of
##     scope. The convention assumes the ``php`` on PATH is the
##     project's intended interpreter.
##
## **Provisioning note**: on a development host that doesn't ship PHP
## (the M57 default on Windows — the dev shell doesn't currently
## bundle PHP), the canonical install paths on Windows are:
##   * PHP Windows binary from ``https://windows.php.net/downloads/``;
##     M57 pins ``PHP_VERSION=8.3.13``.
##   * Composer ``2.8.x`` ``.phar`` from
##     ``https://getcomposer.org/download/`` (or the Composer Windows
##     setup at ``https://getcomposer.org/Composer-Setup.exe``); M57
##     pins ``COMPOSER_VERSION=2.8.1``.
## Total dev-shell footprint ~85 MB.
##
## See ``reprobuild-specs/Provisioning-And-Languages-Expansion.milestones.org`` §M57.

import std/[algorithm, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root for launcher
    ## shim emission. Mirrors the M40 / M41 / M42 / M43 / M46 / M55 /
    ## M56 conventions' value.

  VendorSubdir* = "vendor"
    ## Project-local Composer install path. Composer's default
    ## install location is ``<projectRoot>/vendor/`` (the well-known
    ## Composer convention; not configurable via CLI flag in the same
    ## way Bundler's ``--path`` is). The install action emits a
    ## sentinel stamp file at ``vendor/.repro-composer-stamp`` to
    ## give the engine a stable output path to fingerprint.

  ComposerSentinelFile* = ".repro-composer-stamp"
    ## Sentinel filename written under ``vendor/`` after the
    ## ``composer install`` succeeds. See ``VendorSubdir``.

  EntryScriptSubdir* = "bin"
    ## Project-local entry-script directory. The M57 convention pins
    ## the wrapper to invoke ``<projectRoot>/bin/<name>.php`` as the
    ## entry point (mirrors the Composer ``bin/`` convention for
    ## console scripts). Custom entrypoints are deferred.

type
  PhpComposerMemberKind = enum
    pcmExecutable
    pcmLibrary

  PhpComposerMember = object
    name: string
    kind: PhpComposerMemberKind

proc readReprobuildSource(projectRoot: string): string =
  ## Read the project file (``repro.nim`` or legacy ``reprobuild.nim``)
  ## or return the empty string.
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

proc usesIncludesPhp(source: string): bool =
  ## True when ``uses:`` lists a PHP token (``php`` or ``composer``).
  ## Composer is independent of PHP (separate ``.phar``) so either
  ## token is acceptable as a recognise signal; declaring both is
  ## allowed but not required.
  if source.len == 0:
    return false
  var sawPhp = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if token == "php" or token == "composer":
      sawPhp = true
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if stripped.len == 0:
      if inBlock:
        inBlock = false
      continue
    if inBlock:
      let leading = line.len > 0 and line[0] in {' ', '\t'}
      if not leading:
        inBlock = false
      else:
        for raw in stripped.split({',', ' ', '\t'}):
          let entry = raw.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
          if entry.len == 0:
            continue
          let firstToken = entry.split({' ', '\t', '>', '<', '='})[0]
          consume(firstToken)
        continue
    if stripped.startsWith("uses:"):
      let payload = stripped[5 .. ^1].strip()
      if payload.len == 0:
        inBlock = true
      else:
        var clean = payload
        if clean.startsWith("["):
          clean = clean[1 .. ^1]
        if clean.endsWith("]"):
          clean = clean[0 ..< ^1]
        for raw in clean.split({',', ' ', '\t'}):
          let entry = raw.strip(chars = {' ', '\t', '"', '\'', ',', ';'})
          if entry.len == 0:
            continue
          let firstToken = entry.split({' ', '\t', '>', '<', '='})[0]
          consume(firstToken)
  sawPhp

proc extractExecutables(source: string): seq[string] =
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if not stripped.startsWith("executable"):
      continue
    if stripped.len > len("executable") and
        stripped[len("executable")] notin {' ', '\t'}:
      continue
    let rest = stripped[len("executable") .. ^1].strip()
    if rest.len == 0:
      continue
    var name = ""
    for ch in rest:
      if ch in {' ', '\t', ':', ','}:
        break
      name.add(ch)
    if name.len > 0:
      result.add(name)

proc extractLibraries(source: string): seq[string] =
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if not stripped.startsWith("library"):
      continue
    if stripped.len > len("library") and
        stripped[len("library")] notin {' ', '\t'}:
      continue
    let rest = stripped[len("library") .. ^1].strip()
    if rest.len == 0:
      continue
    var name = ""
    for ch in rest:
      if ch in {' ', '\t', ':', ','}:
        break
      name.add(ch)
    if name.len > 0:
      result.add(name)

proc extractMembers(source: string): seq[PhpComposerMember] =
  for name in extractExecutables(source):
    result.add(PhpComposerMember(name: name, kind: pcmExecutable))
  for name in extractLibraries(source):
    result.add(PhpComposerMember(name: name, kind: pcmLibrary))

proc hasComposerJson*(projectRoot: string): bool =
  ## True when ``<projectRoot>/composer.json`` exists.
  fileExists(extendedPath(projectRoot / "composer.json"))

proc hasComposerLock*(projectRoot: string): bool =
  ## True when ``<projectRoot>/composer.lock`` exists. HARD precondition
  ## per the M57 spec — Composer's strict-lockfile guarantee depends
  ## on the lockfile; the convention's offline-build contract requires
  ## it.
  fileExists(extendedPath(projectRoot / "composer.lock"))

proc phpExecutable(): string =
  ## Resolve a ``php`` interpreter on PATH. On Windows the binary is
  ## usually ``php.exe``; ``findExe`` resolves both shapes via PATHEXT.
  findExe("php")

proc composerExecutable(): string =
  ## Resolve a ``composer`` driver on PATH. On Windows the binary is
  ## usually ``composer.bat`` (Composer-Setup.exe shim) or
  ## ``composer.phar`` (manual install); ``findExe`` resolves all
  ## shapes via PATHEXT.
  findExe("composer")

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc phpComposerRecognize(projectRoot: string;
                          request: ProviderGraphRequest): bool {.gcsafe.} =
  ## Recognition contract — see module docstring.
  if not hasComposerJson(projectRoot):
    return false
  if not hasComposerLock(projectRoot):
    # HARD precondition (M57 spec): the lockfile is Composer's
    # reproducibility + offline guarantee. The convention refuses to
    # recognise a project missing it; ``emitFragment`` raises with a
    # clear diagnostic on the off-chance recognise is bypassed.
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesPhp(source):
    return false
  let members = extractMembers(source)
  if members.len == 0:
    return false
  # Only executables are supported in M57 — library-only projects are
  # deferred. ``recognize`` accepts the project as long as at least
  # one executable is declared (libraries alongside executables are
  # silently ignored at emit time).
  var sawExecutable = false
  for m in members:
    if m.kind == pcmExecutable:
      sawExecutable = true
      break
  if not sawExecutable:
    return false
  if phpExecutable().len == 0:
    return false
  if composerExecutable().len == 0:
    return false
  true

proc producedWrapperPath*(projectRoot, exeName: string): string =
  ## Predicted output path for the launcher wrapper script. On Windows
  ## the suffix is ``.cmd``; on POSIX no suffix (the script is a
  ## ``#!/usr/bin/env sh``-prefixed file). Mirrors the M32 python_direct
  ## + M56 ruby-bundler wrapper-path convention.
  when defined(windows):
    projectRoot / ScratchDirName / exeName / (exeName & ".cmd")
  else:
    projectRoot / ScratchDirName / exeName / exeName

proc producedSentinelPath*(projectRoot: string): string =
  ## Sentinel marker file written under ``vendor/`` after a successful
  ## ``composer install``. See ``VendorSubdir`` for why a sentinel is
  ## used instead of predicting Composer's actual install layout.
  projectRoot / VendorSubdir / ComposerSentinelFile

proc entryScriptPath*(projectRoot, exeName: string): string =
  ## Predicted entry-point path under ``<projectRoot>/bin/<name>.php``.
  projectRoot / EntryScriptSubdir / (exeName & ".php")

proc renderWrapperScript(phpExe, projectRoot, entryScript: string): string =
  ## Build the launcher shim content. On Windows emit a ``.cmd``
  ## (cmd.exe) script; on POSIX emit a ``sh`` script. The wrapper
  ## changes CWD to ``<projectRoot>`` so PHP's autoloader can locate
  ## the project-local ``vendor/autoload.php`` regardless of the
  ## caller's CWD.
  when defined(windows):
    var lines: seq[string] = @[]
    lines.add("@echo off")
    lines.add("setlocal")
    # cd /d switches drive + directory in one shot.
    lines.add("cd /d \"" & projectRoot & "\"")
    # ``php <entry> %*`` — forward any caller args.
    lines.add("\"" & phpExe & "\" \"" & entryScript & "\" %*")
    lines.add("set \"WRAPPER_EXIT=%ERRORLEVEL%\"")
    lines.add("endlocal & exit /b %WRAPPER_EXIT%")
    return lines.join("\r\n") & "\r\n"
  else:
    var lines: seq[string] = @[]
    lines.add("#!/usr/bin/env sh")
    lines.add("set -e")
    lines.add("cd '" & projectRoot & "'")
    lines.add("exec '" & phpExe & "' '" & entryScript & "' \"$@\"")
    return lines.join("\n") & "\n"

proc collectPhpInputs(projectRoot: string): seq[string] =
  ## Conservative input enumeration for the launcher wrapper: the
  ## ``composer.json`` + ``composer.lock`` + every ``.php`` source
  ## file recursively walked under the project root (excluding
  ## ``vendor/`` / ``.repro/`` / ``.git/`` / ``node_modules/``).
  if not dirExists(extendedPath(projectRoot)):
    return @[]
  for extra in @["composer.json", "composer.lock"]:
    let extraPath = projectRoot / extra
    if fileExists(extendedPath(extraPath)):
      result.add(extraPath)
  proc shouldSkipDir(name: string): bool =
    let lower = name.toLowerAscii
    lower in ["vendor", ".repro", ".git", "node_modules",
             "tmp", "log"]
  var stack: seq[string] = @[projectRoot]
  while stack.len > 0:
    let cur = stack[^1]
    stack.setLen(stack.len - 1)
    try:
      for kind, path in walkDir(cur):
        let basename = extractFilename(path)
        case kind
        of pcFile, pcLinkToFile:
          let lower = basename.toLowerAscii
          if lower.endsWith(".php"):
            result.add(path)
        of pcDir, pcLinkToDir:
          if shouldSkipDir(basename):
            continue
          stack.add(path)
    except OSError:
      discard
  # De-dup while preserving order.
  var seen: seq[string] = @[]
  for path in result:
    if path notin seen:
      seen.add(path)
  result = seen
  result.sort(system.cmp[string])

proc emitInstallAction(projectRoot, composerExe: string): BuildActionDef =
  ## Emit the single ``composer install --no-dev --optimize-autoloader
  ## --no-progress --quiet`` action. The action's "output" is the
  ## sentinel file under ``vendor/.repro-composer-stamp`` — Composer's
  ## actual install tree shape depends on the resolved dependency set
  ## and isn't worth predicting at emit time. The convention wraps
  ## the install in a single ``cmd /c`` (Windows) / ``sh -c`` (POSIX)
  ## so the sentinel touch + install run as one cacheable unit.
  ##
  ## ``--no-dev`` omits ``require-dev`` packages (deploy mode).
  ## ``--optimize-autoloader`` builds an optimised classmap-based
  ## autoloader (production mode). ``--no-progress`` suppresses the
  ## progress bar; ``--quiet`` suppresses informational output.
  let sentinelPath = producedSentinelPath(projectRoot)
  let stampDir = parentDir(sentinelPath)
  createDir(extendedPath(stampDir))
  let inputs = @[projectRoot / "composer.json", projectRoot / "composer.lock"]
  when defined(windows):
    # Composer install + sentinel touch chained in a single cmd /c so
    # the engine has a stable output to fingerprint. ``echo`` writes
    # a marker indicating the install succeeded.
    let composerCmd = quoteShell(composerExe) & " install --no-dev " &
      "--optimize-autoloader --no-progress --quiet"
    let stampCmd = "echo installed > " & quoteShell(sentinelPath)
    let argv = @[
      "cmd", "/c",
      composerCmd & " && " & stampCmd
    ]
    buildAction(
      id = "php-composer-install",
      call = inlineExecCall(argv, projectRoot),
      inputs = inputs,
      outputs = @[sentinelPath],
      pool = "compile",
      # ``composer install`` spawns PHP subprocesses whose FS reads
      # aren't reliably observed via the Windows DLL-interpose path.
      # Same constraint M40/M41/M42/M43/M46/M55/M56 face.
      dependencyPolicy = automaticMonitorPolicy(),
      commandStatsId = "php-composer.install")
  else:
    let composerCmd = "'" & composerExe & "' install --no-dev " &
      "--optimize-autoloader --no-progress --quiet"
    let stampCmd = "echo installed > '" & sentinelPath & "'"
    let argv = @[
      "sh", "-c",
      composerCmd & " && " & stampCmd
    ]
    buildAction(
      id = "php-composer-install",
      call = inlineExecCall(argv, projectRoot),
      inputs = inputs,
      outputs = @[sentinelPath],
      pool = "compile",
      dependencyPolicy = automaticMonitorPolicy(),
      commandStatsId = "php-composer.install")

proc emitWrapperAction(projectRoot, phpExe, exeName: string;
                       installActionId: string): BuildActionDef =
  ## ``fs.writeText`` action that materialises the launcher shim. The
  ## wrapper depends on the install action so ``vendor/`` is
  ## guaranteed populated before the launcher is invokable.
  let wrapperPath = producedWrapperPath(projectRoot, exeName)
  let entryScript = entryScriptPath(projectRoot, exeName)
  createDir(extendedPath(parentDir(wrapperPath)))
  let script = renderWrapperScript(phpExe, projectRoot, entryScript)
  fs.writeText(
    output = wrapperPath,
    text = script,
    actionId = "php-composer-wrapper-" & sanitizeNamePart(exeName),
    deps = @[installActionId],
    commandStatsId = "php-composer.executable.wrapper")

proc syntheticPackage(projectRoot: string;
                      members: seq[PhpComposerMember]): PackageDef =
  var name = "php_composer_convention"
  if members.len > 0:
    name = sanitizeNamePart(members[0].name)
  let projectMatch = resolveProjectFile(projectRoot)
  let sourceFile =
    if projectMatch.path.len > 0: projectMatch.path
    else: projectRoot / LegacyProjectFileName
  PackageDef(
    packageName: name,
    sourceFile: sourceFile,
    hasDevEnv: false,
    devEnvBodyHash: "",
    toolUses: @[])

proc phpComposerEmitFragment(projectRoot: string;
                             request: ProviderGraphRequest):
                               GraphFragment {.gcsafe.} =
  ## Convention entry — emit the install action + one wrapper per
  ## executable, hand the bundle to ``buildPackageFragment``.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let members = extractMembers(source)
    if members.len == 0:
      let projectMatch = resolveProjectFile(projectRoot)
      let projectFile =
        if projectMatch.path.len > 0: projectMatch.path
        else: projectRoot / LegacyProjectFileName
      raise newException(ValueError,
        "php-composer convention: no executable members declared in " &
          projectFile & " (M57 supports executable targets only — " &
          "library / PHAR targets are deferred)")
    var execs: seq[string] = @[]
    for m in members:
      if m.kind == pcmExecutable:
        execs.add(m.name)
    if execs.len == 0:
      raise newException(ValueError,
        "php-composer convention: no executable members declared — " &
          "M57 supports executables only (library / PHAR targets are " &
          "deferred)")
    let phpExe = phpExecutable()
    if phpExe.len == 0:
      raise newException(ValueError,
        "php-composer convention: no 'php' on PATH (PHP toolchain " &
          "required; on Windows install via the Windows binary from " &
          "https://windows.php.net/downloads/ — M57 pins PHP 8.3.13)")
    let composerExe = composerExecutable()
    if composerExe.len == 0:
      raise newException(ValueError,
        "php-composer convention: no 'composer' on PATH (Composer is " &
          "an independent .phar — install via Composer-Setup.exe " &
          "from https://getcomposer.org/Composer-Setup.exe — M57 pins " &
          "Composer 2.8.1)")
    if not hasComposerJson(projectRoot):
      raise newException(ValueError,
        "php-composer convention: no 'composer.json' at project root " &
          projectRoot)
    if not hasComposerLock(projectRoot):
      raise newException(ValueError,
        "php-composer convention: 'composer.lock' missing at " &
          projectRoot & "; this is a HARD PRECONDITION for the M57 " &
          "offline-build guarantee. Run 'composer install' once with " &
          "network access to generate the lockfile.")
    let pkg = syntheticPackage(projectRoot, members)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      let installAct = emitInstallAction(projectRoot, composerExe)
      var actions: seq[BuildActionDef] = @[installAct]
      for exe in execs:
        let wrapperAct = emitWrapperAction(projectRoot, phpExe, exe,
          installAct.id)
        actions.add(wrapperAct)
      defaultTarget(target("default", actions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc phpComposerConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  LanguageConvention(
    name: "php-composer",
    recognize: phpComposerRecognize,
    emitFragment: phpComposerEmitFragment)
