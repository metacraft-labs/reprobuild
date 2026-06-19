## C / C++ (Autotools) language convention (Tier 2b) — Mode A
## "fine-grained" plugin (M28 per-source surface).
##
## Recognises a project whose ``reprobuild.nim`` ``uses:`` block lists
## a C compiler (``gcc``/``clang``) plus ``autoconf`` + ``automake`` +
## ``make``, AND ships ``configure.ac`` (or legacy ``configure.in``) +
## ``Makefile.am`` at the project root, AND declares at least one
## ``executable`` or ``library`` member.
##
## M17 shipped a hybrid surface — fine-grained configure stage plus a
## coarse-grained ``make`` build that delegated the per-source DAG to
## the generated Makefile. M28 graduates the build surface to Option A
## from the spec: per-source ``gcc -c`` + per-target link/archive actions
## lifted by parsing ``Makefile.am`` directly. The configure action is
## retained (it generates ``Makefile``/``config.h`` for tooling that
## inspects them and for projects where the convention chains to make)
## but no longer drives the build.
##
## **Approach** (Option A, simplified): ``Makefile.am`` parsing instead
## of ``make --print-data-base`` parsing. The two carry the same
## information for the M28 fixture set:
##
##   * ``bin_PROGRAMS = foo bar`` → two executables.
##   * ``foo_SOURCES = src/foo.c src/util.c`` → per-target source list.
##   * ``lib_LIBRARIES = libgreet.a`` → static library.
##   * ``libgreet_a_SOURCES = src/greet.c`` → per-library source list.
##
## Parsing ``Makefile.am`` instead of running ``make --print-data-base``
## means the per-source emit doesn't depend on configure having run yet.
## The convention spec called for ``make --print-data-base`` because that
## generalises to projects whose Makefile.am uses cpp conditionals etc.;
## the M28 fixture set fits the straightforward ``<target>_SOURCES = ...``
## shape that's parseable from ``Makefile.am`` directly. Projects that
## outgrow this should be flagged with a TODO; the spec's
## ``make --print-data-base`` route remains available as a follow-up.
##
## **Emitted actions** (per the spec):
##
##   1. ``ccpp-autotools-configure`` — one action running
##      ``autoreconf -fi`` (when ``configure`` isn't checked in) followed
##      by ``./configure`` via ``sh -c``. Produces ``Makefile`` +
##      ``config.h`` + ``<scratch>/configure.stamp``. The build actions
##      depend on it transitively so a stale configure forces a rebuild
##      cycle; the generated Makefile is no longer the build's source of
##      truth.
##   2. ``ccpp-autotools-compile-<member>-<source>`` — one per
##      ``.c`` listed in ``Makefile.am``'s ``<target>_SOURCES``. Argv
##      mirrors c_cpp_make's compile shape (``gcc -c -O2 -Wall -Wextra
##      -MD -MF <dep> -I <includes> -o <obj> <src>``).
##   3. ``ccpp-autotools-link-<member>`` (executable) or
##      ``ccpp-autotools-archive-<member>`` (static library).
##
## **Windows toolchain** (M28): the M9 harness's `Probe-Toolchain` for
## ``c-cpp-autotools`` prepends MSYS2's ``usr/bin`` to PATH so the
## extensionless ``autoreconf`` / ``automake`` shell scripts resolve.
## `env.ps1` also prepends that directory for ambient dev shells via
## `ensure-msys2-autotools.ps1`. On hosts without MSYS2 (or where pacman
## hasn't been invoked yet) recognition still returns ``false`` cleanly
## so the harness SKIPs with a precise reason.
##
## **Caveats**:
##   * Requires ``autoreconf`` (i.e. autoconf + automake) and ``make``
##     and a compiler on PATH at convention-emit time. The recognise step
##     uses a Windows-aware exe search that treats extensionless MSYS2
##     wrapper scripts as valid (Nim's stdlib ``findExe`` only checks
##     ``.exe``/``.cmd``/``.bat`` on Windows).
##   * Requires ``sh`` on PATH (MSYS2 / Git Bash / Unix). The configure
##     script is ``/bin/sh`` and the autoreconf+configure compound runs
##     via ``sh -c``.
##   * Per-source lift parses ``Makefile.am``; projects whose ``Makefile.am``
##     relies on cpp conditionals or generated source lists are not yet
##     supported (recognise returns ``false``).
##   * Out-of-tree builds (the spec's recommended ``mkdir _build && cd
##     _build``) are deferred — the M28 fixture builds in-tree under
##     ``.repro/build/<member>/``.

import std/[algorithm, os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/fetch_action

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root the Autotools
    ## convention writes into. Identical to other conventions'.

type
  CCppAutotoolsMemberKind = enum
    catmkExecutable
    catmkLibraryStatic

  CCppAutotoolsMember = object
    name: string
    kind: CCppAutotoolsMemberKind

  CCppAutotoolsEmitTarget = object
    ## Resolved member: the kind plus the list of ``.c`` files extracted
    ## from ``Makefile.am`` via ``<target>_SOURCES`` lines. Computed by
    ## ``resolveTarget``; an empty ``sourceFiles`` signals recognition
    ## failure.
    member: CCppAutotoolsMember
    sourceFiles: seq[string]
      ## Absolute paths to the ``.c`` files for this member.

proc readReprobuildSource(projectRoot: string): string =
  ## Read the project file (``repro.nim`` or legacy ``reprobuild.nim``)
  ## or return the empty string. See ``repro_core/project_file``.
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

proc usesIncludesAutotools(source: string): bool =
  ## True when ``uses:`` lists ``autoconf`` (or ``automake``) AND a C
  ## compiler (``gcc``/``clang``) AND ``make``. The spec demands all
  ## three families; the convention is conservative and requires every
  ## one.
  if source.len == 0:
    return false
  var sawCompiler = false
  var sawMake = false
  var sawAutotools = false
  var inBlock = false
  proc consume(token: string) {.closure.} =
    if token == "gcc" or token == "clang":
      sawCompiler = true
    if token == "make":
      sawMake = true
    if token == "autoconf" or token == "automake":
      sawAutotools = true
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
  sawCompiler and sawMake and sawAutotools

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

proc extractMembers(source: string): seq[CCppAutotoolsMember] =
  for name in extractExecutables(source):
    result.add(CCppAutotoolsMember(name: name, kind: catmkExecutable))
  for name in extractLibraries(source):
    result.add(CCppAutotoolsMember(name: name, kind: catmkLibraryStatic))

proc extractFirstPackageName(source: string): string =
  ## DSL-port M9.K: heuristic scan for the first ``package <ident>:``
  ## declaration. Same shape as the sibling conventions' helpers — the
  ## lookup key for the M9.H ``registeredFetchSpec`` and M9.I
  ## ``registeredBuildFlags`` registries.
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if not stripped.startsWith("package"):
      continue
    if stripped.len > len("package") and
        stripped[len("package")] notin {' ', '\t'}:
      continue
    let rest = stripped[len("package") .. ^1].strip()
    if rest.len == 0:
      continue
    var name = ""
    for ch in rest:
      if ch in {' ', '\t', ':', ','}:
        break
      name.add(ch)
    if name.len > 0:
      return name
  ""

proc hasConfigureSource(projectRoot: string): bool =
  ## True when ``configure.ac`` or legacy ``configure.in`` exists.
  fileExists(extendedPath(projectRoot / "configure.ac")) or
    fileExists(extendedPath(projectRoot / "configure.in"))

proc hasMakefileAm(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "Makefile.am"))

proc hasGeneratedConfigure(projectRoot: string): bool =
  ## True when a generated ``configure`` script is checked in (the
  ## "released-tarball" shape). The convention prefers this — it skips
  ## the ``autoreconf -fi`` step.
  fileExists(extendedPath(projectRoot / "configure"))

proc findExeAnyExt(exe: string): string =
  ## Like ``std/os.findExe`` but on Windows ALSO considers the extension-
  ## less name (in addition to ``.exe``/``.cmd``/``.bat``). MSYS2 ships
  ## ``autoreconf`` / ``autoconf`` / ``automake`` as POSIX shell scripts
  ## without an extension; stock ``findExe`` misses those. We do the same
  ## PATH walk as Nim's stdlib but with an empty-extension first probe.
  if exe.len == 0:
    return ""
  let stockResult = findExe(exe)
  if stockResult.len > 0:
    return stockResult
  when defined(windows):
    let pathEnv = getEnv("PATH")
    for candidate in pathEnv.split(';'):
      if candidate.len == 0:
        continue
      let stripped = candidate.strip(chars = {' ', '"'})
      if stripped.len == 0:
        continue
      let probe = stripped / exe
      if fileExists(extendedPath(probe)):
        return probe
    return ""
  else:
    return ""

proc autoreconfExecutable(): string =
  ## M9.N Batch B: bare tool name; engine resolves via PATH plumbing.
  "autoreconf"

proc makeExecutable(): string =
  ## M9.N Batch B: bare tool name; engine resolves via PATH plumbing.
  ## The catalog dispatches to the platform-appropriate make
  ## (``mingw32-make`` on Windows when needed).
  "make"

proc shExecutable(): string =
  ## M9.N Batch B: bare tool name; engine resolves via PATH plumbing.
  "sh"

proc ccCompiler(): string =
  ## M9.N Batch B: bare tool name; engine resolves via PATH plumbing.
  "gcc"

proc arDriver(): string =
  ## M9.N Batch B: bare tool name; engine resolves via PATH plumbing.
  "ar"

proc parseMakefileAmVariables(content: string): seq[(string, string)] =
  ## Parse Make-style ``VAR = value`` and ``VAR += value`` assignments
  ## from a ``Makefile.am``. Returns variable name + the assigned tokens
  ## (whitespace-separated). Handles continuation lines (``\``) and ``+=``
  ## (concatenating onto the prior value). Comments (``#``) are dropped.
  ##
  ## The parser is deliberately minimal — it handles the M28 fixture set
  ## (``bin_PROGRAMS``, ``<target>_SOURCES``, ``lib_LIBRARIES``,
  ## ``<lib>_a_SOURCES``) but does NOT evaluate make variables or run
  ## cpp conditionals. Conditional ``Makefile.am`` is a follow-up.
  var pending = ""
  let lines = content.splitLines()
  var i = 0
  while i < lines.len:
    var line = lines[i]
    i += 1
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    if stripped.len == 0 and pending.len == 0:
      continue
    if stripped.endsWith("\\"):
      pending.add(' ')
      pending.add(stripped[0 ..< ^1].strip())
      continue
    if pending.len > 0:
      pending.add(' ')
      pending.add(stripped)
    else:
      pending = stripped
    # Parse ``VAR = ...`` / ``VAR += ...`` / ``VAR := ...``. Make
    # accepts whitespace between the variable name and the assignment
    # operator (``FOO = bar`` is the canonical form); the scanner walks
    # past the identifier, then optional whitespace, then expects ``=``,
    # ``+=``, ``:=``, or fails (e.g. a rule line ``target: deps``).
    var nameEnd = -1
    for j in 0 ..< pending.len:
      let ch = pending[j]
      if ch == '=':
        nameEnd = j
        break
      if ch == '+' or ch == ':':
        if j + 1 < pending.len and pending[j + 1] == '=':
          nameEnd = j
          break
        # Bare ``:`` or ``+`` without ``=`` chaser — not an assignment.
        nameEnd = -1
        break
      if ch in {' ', '\t'}:
        continue
    var eqIdx = -1
    var opLen = 1
    if nameEnd >= 0:
      let ch = pending[nameEnd]
      case ch
      of '=':
        eqIdx = nameEnd
      of '+', ':':
        eqIdx = nameEnd
        opLen = 2
      else:
        discard
    if eqIdx > 0:
      let name = pending[0 ..< eqIdx].strip()
      let value = pending[eqIdx + opLen .. ^1].strip()
      if name.len > 0:
        result.add((name, value))
    pending = ""

proc parseMakefileAmTargets(content: string): seq[(string, string)] =
  ## Extract per-target source assignments. For each variable named
  ## ``<sanitised>_SOURCES`` whose ``<sanitised>`` matches a configured
  ## target name (Automake's mangling rule: ``[.\-+/]`` → ``_``), the
  ## caller iterates these directly. We return the raw (var, value)
  ## tuples; matching happens in ``resolveTarget``.
  for (name, value) in parseMakefileAmVariables(content):
    if name.endsWith("_SOURCES"):
      result.add((name, value))

proc sanitiseAutomakeName(value: string): string =
  ## Automake mangles target names for the ``<target>_SOURCES`` variable
  ## by replacing every ``.`` / ``-`` / ``+`` with ``_``. The convention
  ## reproduces that mangling to look up source assignments by member
  ## name (e.g. ``library greet`` => archive ``libgreet.a`` => variable
  ## ``libgreet_a_SOURCES``).
  for ch in value:
    if ch in {'.', '-', '+', '/'}:
      result.add('_')
    else:
      result.add(ch)

proc resolveAutotoolsTarget(projectRoot, makefileAmContent: string;
                            member: CCppAutotoolsMember):
                              CCppAutotoolsEmitTarget =
  ## Locate the source files for a single member by scanning
  ## ``Makefile.am`` for the matching ``<sanitised>_SOURCES`` line.
  ##
  ## Lookup keys:
  ##   * executable ``foo`` → ``foo_SOURCES``
  ##   * library ``greet`` → ``libgreet_a_SOURCES`` (matches automake's
  ##     ``lib_LIBRARIES = libgreet.a`` convention)
  result.member = member
  let sources = parseMakefileAmTargets(makefileAmContent)
  let keys = case member.kind
    of catmkExecutable:
      @[sanitiseAutomakeName(member.name) & "_SOURCES"]
    of catmkLibraryStatic:
      # Try the ``lib<name>.a`` mangling first (the convention's default)
      # then the bare ``<name>`` mangling (some projects declare
      # ``<name>_LIBRARIES`` directly).
      @[
        sanitiseAutomakeName("lib" & member.name & ".a") & "_SOURCES",
        sanitiseAutomakeName(member.name) & "_SOURCES",
      ]
  for key in keys:
    for (varName, value) in sources:
      if varName != key:
        continue
      var collected: seq[string] = @[]
      for raw in value.split({' ', '\t'}):
        let entry = raw.strip()
        if entry.len == 0:
          continue
        if entry.startsWith("$"):
          # Skip make-variable references; the parser doesn't evaluate
          # them. Future enhancement: chase simple ``$(FOO)`` indirection.
          continue
        let abs = projectRoot / entry
        collected.add(abs)
      collected.sort(system.cmp[string])
      result.sourceFiles = collected
      return

proc cCppAutotoolsRecognize(projectRoot: string;
                            request: ProviderGraphRequest):
                              bool {.gcsafe.} =
  ## Recognition contract (M28):
  ##   * ``<projectRoot>/configure.ac`` (or legacy ``configure.in``)
  ##     exists.
  ##   * ``<projectRoot>/Makefile.am`` exists and resolves at least one
  ##     declared member to a non-empty source-file list.
  ##   * ``<projectRoot>/reprobuild.nim`` exists AND ``uses:`` lists
  ##     ``autoconf`` (or ``automake``) AND a compiler AND ``make``.
  ##   * at least one ``executable`` or ``library`` member is declared.
  ##   * a C compiler is on PATH.
  ##   * ``make`` (or ``mingw32-make`` on Windows) is on PATH.
  ##   * ``sh`` is on PATH (the configure script and the sh-c compound
  ##     both need it).
  ##   * EITHER a generated ``configure`` is checked in, OR
  ##     ``autoreconf`` is on PATH (so the convention can regenerate it).
  ##
  ## M9.N: tool availability (``gcc`` / ``make`` / ``sh`` /
  ## ``autoreconf`` on PATH) is NOT gated here. Recognition claims a
  ## recipe based on DECLARATION (``configure.ac`` + ``Makefile.am`` at
  ## projectRoot + ``uses:`` lists autotools tokens + per-member source
  ## resolution). Tool identity is resolved AFTER recognise, possibly
  ## via cache substitute or source build, so a host-PATH probe at
  ## recognise time is wrong.
  ##
  ## TODO(M9.N Batch B): resolve tool identity through engine instead of
  ## findExe at emit time.
  if not hasConfigureSource(projectRoot):
    return false
  if not hasMakefileAm(projectRoot):
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  if not usesIncludesAutotools(source):
    return false
  let members = extractMembers(source)
  if members.len == 0:
    return false
  # M28 per-source lift: every declared member must resolve to at least
  # one source file from ``Makefile.am``.
  let makefileAmPath = projectRoot / "Makefile.am"
  let makefileAm = try: readFile(extendedPath(makefileAmPath)) except CatchableError: ""
  if makefileAm.len == 0:
    return false
  for member in members:
    let resolved = resolveAutotoolsTarget(projectRoot, makefileAm, member)
    if resolved.sourceFiles.len == 0:
      return false
  true

proc scratchPathFor(projectRoot: string): string =
  projectRoot / ScratchDirName

proc memberScratchPath(projectRoot, member: string): string =
  scratchPathFor(projectRoot) / member

proc objDirFor(projectRoot, member: string): string =
  memberScratchPath(projectRoot, member) / "obj"

proc binaryPathFor(projectRoot, member: string): string =
  when defined(windows):
    memberScratchPath(projectRoot, member) / (member & ".exe")
  else:
    memberScratchPath(projectRoot, member) / member

proc staticLibraryPathFor(projectRoot, member: string): string =
  memberScratchPath(projectRoot, member) / ("lib" & member & ".a")

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

proc objFileFor(objDir, source: string): string =
  let base = extractFilename(source)
  let stem =
    if base.endsWith(".c"): base[0 ..< base.len - 2]
    else: base
  objDir / (sanitizeNamePart(stem) & ".o")

proc configureStampPath(projectRoot: string): string =
  ## The configure action's declared output. ``Makefile`` + ``config.h``
  ## are the headline outputs but the engine wants every declared output
  ## to exist after the action; we declare both the generated Makefile
  ## (always present) and a custom stamp so the action's success is
  ## recorded independently of the Makefile's mtime (which the make
  ## action would then overwrite). The stamp lives under the scratch
  ## dir so it doesn't pollute the source tree.
  scratchPathFor(projectRoot) / "configure.stamp"

proc collectAutotoolsSources(projectRoot: string): seq[string] =
  ## Every file relevant to the configure stage's invalidation set:
  ## ``configure.ac`` / ``configure.in``, every ``Makefile.am`` / ``*.m4``
  ## anywhere under ``projectRoot``, the checked-in ``configure`` script
  ## if present, and ``aclocal.m4`` / ``config.h.in`` when present.
  if not dirExists(extendedPath(projectRoot)):
    return @[]
  for path in [projectRoot / "configure.ac",
               projectRoot / "configure.in",
               projectRoot / "configure",
               projectRoot / "aclocal.m4",
               projectRoot / "config.h.in"]:
    if fileExists(extendedPath(path)):
      result.add(path)
  for entry in walkDirRec(projectRoot):
    let lower = entry.toLowerAscii
    if (ScratchDirName & "/") in entry.replace('\\', '/'):
      continue
    if "/.repro/" in entry.replace('\\', '/'):
      continue
    let base = extractFilename(entry).toLowerAscii
    if base == "makefile.am" or lower.endsWith(".m4"):
      result.add(entry)
  # De-dup while preserving order — ``walkDirRec`` may emit
  # ``configure.ac`` again if it sits alongside the .m4 files.
  var seen: seq[string] = @[]
  for path in result:
    if path notin seen:
      seen.add(path)
  result = seen

proc renderConfigureScript(needAutoreconf: bool;
                           configureFlags: seq[string]): string =
  ## sh-c command running ``autoreconf -fi`` (optionally) then
  ## ``./configure --prefix=/ --disable-dependency-tracking
  ## --disable-maintainer-mode <M9.K configureFlags>`` then touching the
  ## stamp.
  ##
  ## DSL-port M9.K: ``configureFlags`` (from the M9.I
  ## ``configureFlags:`` block, channel ``"configure"``) are appended
  ## verbatim to the ``./configure`` invocation in declaration order.
  var parts: seq[string] = @[]
  parts.add("set -e")
  if needAutoreconf:
    parts.add("autoreconf -fi")
  var configureCmd = "./configure --prefix=/ --disable-dependency-tracking " &
    "--disable-maintainer-mode"
  for flag in configureFlags:
    configureCmd.add(" \"")
    configureCmd.add(flag.replace("\"", "\\\""))
    configureCmd.add("\"")
  parts.add(configureCmd)
  parts.add("touch \"$REPRO_CONFIGURE_STAMP\"")
  parts.join("; ")

proc emitConfigureAction(projectRoot, shExe: string;
                         needAutoreconf: bool;
                         configureFlags: seq[string];
                         extraDeps: seq[string] = @[];
                         extraInputs: seq[string] = @[]):
                           tuple[action: BuildActionDef; stamp: string] =
  let stamp = configureStampPath(projectRoot)
  createDir(extendedPath(parentDir(stamp)))
  let script = renderConfigureScript(needAutoreconf, configureFlags)
  let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
  let fullScript = "REPRO_CONFIGURE_STAMP=\"" & escapedStamp & "\"; " & script
  let argv = @[shExe, "-c", fullScript]
  var inputs = collectAutotoolsSources(projectRoot)
  for ei in extraInputs:
    if ei notin inputs:
      inputs.add(ei)
  let outputs = @[projectRoot / "Makefile", stamp]
  let action = buildAction(
    id = "ccpp-autotools-configure",
    call = inlineExecCall(argv, projectRoot),
    deps = extraDeps,
    inputs = inputs,
    outputs = outputs,
    pool = "compile",
    # M28 note: automaticMonitorPolicy() rather than
    # automaticMonitorPolicy() because the configure compound
    # (autoreconf + ./configure) spawns a fan-out of perl/m4/sh
    # subprocesses that FS-snoop's DLL-interpose handles unreliably
    # on Windows (the second-level child of MSYS2's sh.exe deadlocks
    # waiting on a pipe that never drains). The configure action's
    # inputs list explicitly enumerates configure.ac + configure.in +
    # Makefile.am + every .m4 / aclocal.m4 / config.h.in under the
    # project root via ``collectAutotoolsSources`` so per-file
    # invalidation still works without monitoring.
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "ccpp-autotools.configure",
    # M9.N Batch B: autoreconf + ./configure compound shells out to
    # autotools' perl/m4 cascade and probes the C compiler at
    # configure time.
    toolIdentityRefs = @["autoreconf", "make", "gcc", "sh"])
  (action, stamp)

proc emitCompileAction(projectRoot, ccExe: string;
                       member: CCppAutotoolsMember;
                       source, objFile, depFile: string;
                       configureStamp: string;
                       configureActionId: string): BuildActionDef =
  ## One ``gcc -c`` action for a single C source extracted from
  ## ``Makefile.am``.
  # ``-I projectRoot`` so generated headers (``config.h``) end up on
  # the include search path even though M28's fixture set doesn't use
  # one. Mirrors what automake does for in-tree builds.
  let includeFlags = block:
    var flags: seq[string] = @[]
    flags.add("-I")
    flags.add(projectRoot)
    let srcDir = projectRoot / "src"
    if dirExists(extendedPath(srcDir)):
      flags.add("-I")
      flags.add(srcDir)
    let topIncludeDir = projectRoot / "include"
    if dirExists(extendedPath(topIncludeDir)):
      flags.add("-I")
      flags.add(topIncludeDir)
    flags
  var argv = @[ccExe, "-c", "-O2", "-Wall", "-Wextra",
    "-MD", "-MF", depFile]
  for flag in includeFlags:
    argv.add(flag)
  argv.add("-o")
  argv.add(objFile)
  argv.add(source)
  let actionId = "ccpp-autotools-compile-" & sanitizeNamePart(member.name) &
    "-" & sanitizeNamePart(extractFilename(source))
  let kindTag = case member.kind
    of catmkExecutable: "executable"
    of catmkLibraryStatic: "library-static"
  # The compile depends on the configure stage having run so generated
  # headers (config.h) are available.  Inputs include both the source
  # AND the configure stamp so a stale configure forces a recompile.
  buildAction(
    id = actionId,
    call = inlineExecCall(argv, projectRoot),
    deps = @[configureActionId],
    inputs = @[source, configureStamp],
    outputs = @[objFile],
    pool = "compile",
    depfile = depFile,
    dependencyPolicy = makeDepfilePolicy(depFile),
    commandStatsId = "ccpp-autotools." & kindTag & ".compile",
    # M9.N Batch B: gcc compile step.
    toolIdentityRefs = @["gcc"])

proc emitLinkAction(projectRoot, ccExe: string;
                    member: CCppAutotoolsMember;
                    objFiles: seq[string];
                    compileActionIds: seq[string]): BuildActionDef =
  ## ``gcc -o <bin> <objs>`` link action for an ``executable`` member.
  let binaryOutput = binaryPathFor(projectRoot, member.name)
  createDir(extendedPath(parentDir(binaryOutput)))
  var argv = @[ccExe, "-o", binaryOutput]
  for obj in objFiles:
    argv.add(obj)
  buildAction(
    id = "ccpp-autotools-link-" & sanitizeNamePart(member.name),
    call = inlineExecCall(argv, projectRoot),
    deps = compileActionIds,
    inputs = objFiles,
    outputs = @[binaryOutput],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "ccpp-autotools.executable.link",
    # M9.N Batch B: gcc link step.
    toolIdentityRefs = @["gcc"])

proc emitArchiveAction(projectRoot, arExe: string;
                       member: CCppAutotoolsMember;
                       objFiles: seq[string];
                       compileActionIds: seq[string]): BuildActionDef =
  ## ``ar rcs lib<name>.a <objs>`` archive action for a static library.
  let archiveOutput = staticLibraryPathFor(projectRoot, member.name)
  createDir(extendedPath(parentDir(archiveOutput)))
  var argv = @[arExe, "rcs", archiveOutput]
  for obj in objFiles:
    argv.add(obj)
  buildAction(
    id = "ccpp-autotools-archive-" & sanitizeNamePart(member.name),
    call = inlineExecCall(argv, projectRoot),
    deps = compileActionIds,
    inputs = objFiles,
    outputs = @[archiveOutput],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "ccpp-autotools.library-static.archive",
    # M9.N Batch B: ar archive step.
    toolIdentityRefs = @["ar"])

proc emitForMember(projectRoot, ccExe, arExe: string;
                   target: CCppAutotoolsEmitTarget;
                   configureStamp: string;
                   configureActionId: string):
                     tuple[compiles: seq[BuildActionDef];
                           terminal: BuildActionDef] =
  let objDir = objDirFor(projectRoot, target.member.name)
  createDir(extendedPath(objDir))
  var compileActions: seq[BuildActionDef] = @[]
  var objFiles: seq[string] = @[]
  var compileIds: seq[string] = @[]
  for source in target.sourceFiles:
    let objFile = objFileFor(objDir, source)
    let depFile = objFile & ".d"
    objFiles.add(objFile)
    let action = emitCompileAction(projectRoot, ccExe, target.member,
      source, objFile, depFile, configureStamp, configureActionId)
    compileActions.add(action)
    compileIds.add(action.id)
  case target.member.kind
  of catmkExecutable:
    let link = emitLinkAction(projectRoot, ccExe, target.member, objFiles,
      compileIds)
    (compileActions, link)
  of catmkLibraryStatic:
    let archive = emitArchiveAction(projectRoot, arExe, target.member,
      objFiles, compileIds)
    (compileActions, archive)

proc syntheticPackage(projectRoot: string;
                      members: seq[CCppAutotoolsMember]): PackageDef =
  var name = "c_cpp_autotools_convention"
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

proc cCppAutotoolsEmitFragment(projectRoot: string;
                               request: ProviderGraphRequest):
                                 GraphFragment {.gcsafe.} =
  ## Convention entry — emit configure + per-source + link/archive
  ## actions, hand the bundle to ``buildPackageFragment``.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let members = extractMembers(source)
    if members.len == 0:
      let projectMatch = resolveProjectFile(projectRoot)
      let projectFile =
        if projectMatch.path.len > 0: projectMatch.path
        else: projectRoot / LegacyProjectFileName
      raise newException(ValueError,
        "c-cpp-autotools convention: no executable or library members " &
          "declared in " & projectFile)
    let ccExe = ccCompiler()
    if ccExe.len == 0:
      raise newException(ValueError,
        "c-cpp-autotools convention: no C compiler on PATH")
    let arExe = arDriver()
    let makeExe = makeExecutable()
    if makeExe.len == 0:
      raise newException(ValueError,
        "c-cpp-autotools convention: no 'make' on PATH")
    let shExe = shExecutable()
    if shExe.len == 0:
      raise newException(ValueError,
        "c-cpp-autotools convention: no 'sh' on PATH; the configure " &
          "script and the autoreconf+configure compound require a " &
          "POSIX shell")
    let needAutoreconf = not hasGeneratedConfigure(projectRoot)
    if needAutoreconf and autoreconfExecutable().len == 0:
      raise newException(ValueError,
        "c-cpp-autotools convention: no 'autoreconf' on PATH and no " &
          "checked-in 'configure' script — cannot generate the build " &
          "scaffolding")
    let makefileAmPath = projectRoot / "Makefile.am"
    let makefileAm = try: readFile(extendedPath(makefileAmPath)) except CatchableError: ""
    if makefileAm.len == 0:
      raise newException(ValueError,
        "c-cpp-autotools convention: Makefile.am missing at " &
          makefileAmPath)
    var targets: seq[CCppAutotoolsEmitTarget] = @[]
    for member in members:
      let target = resolveAutotoolsTarget(projectRoot, makefileAm, member)
      if target.sourceFiles.len == 0:
        raise newException(ValueError,
          "c-cpp-autotools convention: no .c sources resolved for " &
            "member '" & member.name & "' under " & projectRoot &
            " (looked for a matching <target>_SOURCES line in " &
            makefileAmPath & ")")
      targets.add(target)
    let pkg = syntheticPackage(projectRoot, members)
    # DSL-port M9.K: look up the DSL package name and read the M9.H
    # fetch spec + M9.I configure flag seq against that key.
    let dslPackageName = extractFirstPackageName(source)
    let fetchSpec =
      if dslPackageName.len > 0: registeredFetchSpec(dslPackageName)
      else: DslFetchSpec()
    let hasFetch = fetchSpec.url.len > 0 and fetchSpec.hashHex.len > 0
    # M9.R.6.1: ``registeredBuildFlags`` registry retired; recipes route
    # configureFlags through an explicit ``build:`` calling
    # ``autotools_package(...)``.
    let configureFlags: seq[string] = @[]
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      var allActions: seq[BuildActionDef] = @[]
      var configureDeps: seq[string] = @[]
      var configureInputsExtra: seq[string] = @[]
      if hasFetch:
        discard buildPool("fetch", 2'u32)
        let fetchAct = emitFetchAction(projectRoot, dslPackageName, fetchSpec)
        allActions.add(fetchAct)
        configureDeps.add(fetchAct.id)
        configureInputsExtra.add(fetchStampPath(projectRoot, fetchSpec.hashHex))
      let configurePair = emitConfigureAction(projectRoot, shExe,
        needAutoreconf, configureFlags, configureDeps,
        configureInputsExtra)
      allActions.add(configurePair.action)
      for target in targets:
        let emitted = emitForMember(projectRoot, ccExe, arExe, target,
          configurePair.stamp, configurePair.action.id)
        for a in emitted.compiles:
          allActions.add(a)
        allActions.add(emitted.terminal)
      defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc cCppAutotoolsConvention*(): LanguageConvention =
  LanguageConvention(
    name: "c-cpp-autotools",
    recognize: cCppAutotoolsRecognize,
    emitFragment: cCppAutotoolsEmitFragment)
