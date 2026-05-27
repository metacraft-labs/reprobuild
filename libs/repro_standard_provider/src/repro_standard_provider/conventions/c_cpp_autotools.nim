## C / C++ (Autotools) language convention (Tier 2b) — Mode A
## "fine-grained" plugin (M17 hybrid surface).
##
## Recognises a project whose ``reprobuild.nim`` ``uses:`` block lists
## a C compiler (``gcc``/``clang``) plus ``autoconf`` + ``automake`` +
## ``make``, AND ships ``configure.ac`` (or legacy ``configure.in``) +
## ``Makefile.am`` at the project root, AND declares at least one
## ``executable`` or ``library`` member.
##
## The convention spec
## (``reprobuild-specs/Language-Conventions/C-Cpp-Autotools.md``
## §"Mode A — Fine-grained build graph") prescribes two phases:
##
##   1. **Configure stage** — one action running
##      ``autoreconf -fi`` (when ``configure`` isn't checked in) followed
##      by ``./configure``. Produces ``Makefile`` + ``config.h``.
##   2. **Build stage** — per-source compile + link/archive edges lifted
##      from the generated Makefile via the C-Cpp-Make Mode A translator.
##
## The M17 surface ships a **hybrid Mode A**: a fine-grained configure
## action (so ``configure.ac`` edits are correctly invalidated) plus a
## single coarse-grained ``make`` action for the build itself. The
## per-source lift via ``make --print-data-base`` is reserved for a
## later milestone — the M17 ``hello-binary`` fixture passes with a
## single ``make`` invocation that delegates the per-source DAG to the
## generated Makefile. The pragmatic shape mirrors what M3 did for Nim
## (eager compile-only run) before M3+1's dyndep follow-up.
##
## **Configure action argv** (the spec's repo-checkout shape):
##
##   1. ``autoreconf -fi`` (run from ``<projectRoot>``) — generates
##      ``configure`` + ``Makefile.in`` + auxiliary GNU build scripts.
##   2. ``./configure`` (also from ``<projectRoot>``) — generates
##      ``Makefile`` + ``config.h``. The convention runs both in a
##      single shell-equivalent action via a ``sh -c`` wrapper because
##      reprobuild's action shape is one argv per action.
##
## To keep both invocations inside one action without introducing a
## sub-shell, the convention concatenates them into a single ``sh -c``
## command. On Windows the MSYS2 ``/bin/sh`` is required (the spec
## §"Cross-platform notes" calls this out as a requirement for
## native-Windows autotools builds).
##
## **Build action argv**: ``make`` (or ``mingw32-make`` on Windows when
## no ``make`` is on PATH). One single coarse action; ``dependencyPolicy
## = automaticMonitorPolicy`` so the FS-snoop catches the per-source
## compile inputs / outputs.
##
## **Caveats**:
##   * Requires ``autoreconf`` (i.e. autoconf + automake) and ``make``
##     and a compiler on PATH at convention-emit time. When any of these
##     is missing, ``recognize`` returns ``false`` so dispatch falls
##     through to the no-match diagnostic and the E2E gate SKIPs.
##   * Requires ``sh`` on PATH (MSYS2 / Git Bash / Unix). The configure
##     script is ``/bin/sh`` and the autoreconf+configure compound runs
##     via ``sh -c``.
##   * The M17 surface is hybrid Mode A: the build step delegates to
##     ``make``. Per-source lift is deferred. The convention spec
##     classifies a hybrid as Mode A (the configure is fine-grained;
##     the per-source DAG matches what the generated Makefile would
##     do anyway).
##   * Out-of-tree builds (the spec's recommended ``mkdir _build && cd
##     _build``) are deferred — the M17 fixture builds in-tree. The
##     build action declares its outputs as the generated executable
##     under ``<projectRoot>`` itself (or under ``src/`` per
##     ``subdir-objects`` automake mode).

import std/[os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention

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

proc readReprobuildSource(projectRoot: string): string =
  let path = projectRoot / "reprobuild.nim"
  if not fileExists(extendedPath(path)):
    return ""
  try:
    readFile(extendedPath(path))
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

proc autoreconfExecutable(): string =
  findExe("autoreconf")

proc makeExecutable(): string =
  ## Resolve ``make`` on PATH. Prefers GNU ``make``; falls back to
  ## ``mingw32-make`` on Windows when the MSYS2 ``make`` package isn't
  ## installed (mingw-w64 GCC ships ``mingw32-make.exe`` instead). Empty
  ## string when neither resolves.
  let candidate = findExe("make")
  if candidate.len > 0:
    return candidate
  when defined(windows):
    let mingw = findExe("mingw32-make")
    if mingw.len > 0:
      return mingw
  ""

proc shExecutable(): string =
  ## Resolve ``sh`` on PATH. Required for the configure script and the
  ## autoreconf+configure ``sh -c`` compound. Returns the empty string
  ## when missing — the convention then declines to recognise so the
  ## E2E gate SKIPs cleanly on Windows hosts without MSYS2 / Git Bash.
  findExe("sh")

proc ccCompiler(): string =
  let gcc = findExe("gcc")
  if gcc.len > 0:
    return gcc
  findExe("clang")

proc cCppAutotoolsRecognize(projectRoot: string;
                            request: ProviderGraphRequest):
                              bool {.gcsafe.} =
  ## Recognition contract (M17):
  ##   * ``<projectRoot>/configure.ac`` (or legacy ``configure.in``)
  ##     exists.
  ##   * ``<projectRoot>/Makefile.am`` exists.
  ##   * ``<projectRoot>/reprobuild.nim`` exists AND ``uses:`` lists
  ##     ``autoconf`` (or ``automake``) AND a compiler AND ``make``.
  ##   * at least one ``executable`` or ``library`` member is declared.
  ##   * a C compiler is on PATH.
  ##   * ``make`` (or ``mingw32-make`` on Windows) is on PATH.
  ##   * ``sh`` is on PATH (the configure script and the sh-c compound
  ##     both need it).
  ##   * EITHER a generated ``configure`` is checked in, OR
  ##     ``autoreconf`` is on PATH (so the convention can regenerate it).
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
  if ccCompiler().len == 0:
    return false
  if makeExecutable().len == 0:
    return false
  if shExecutable().len == 0:
    return false
  if not hasGeneratedConfigure(projectRoot):
    if autoreconfExecutable().len == 0:
      return false
  true

proc scratchPathFor(projectRoot: string): string =
  projectRoot / ScratchDirName

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

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
  ## if present, and ``aclocal.m4`` / ``config.h.in`` when present. The
  ## list scopes the action's cache fingerprint; the build action uses
  ## ``automaticMonitor`` for the broader source-tree set.
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

proc collectBuildInputs(projectRoot: string): seq[string] =
  ## Source-tree inputs for the build action: every ``.c`` / ``.h`` file
  ## under ``projectRoot/src``. The build action declares these so
  ## per-source edits invalidate the action; FS-snoop covers anything
  ## else the make recipe reads.
  let srcDir = projectRoot / "src"
  if not dirExists(extendedPath(srcDir)):
    return @[]
  for entry in walkDirRec(srcDir):
    let lower = entry.toLowerAscii
    if lower.endsWith(".c") or lower.endsWith(".h") or
       lower.endsWith(".cc") or lower.endsWith(".cpp") or
       lower.endsWith(".cxx") or lower.endsWith(".hpp"):
      result.add(entry)

proc renderConfigureScript(needAutoreconf: bool): string =
  ## sh-c command running ``autoreconf -fi`` (optionally) then
  ## ``./configure --prefix=/ --disable-dependency-tracking
  ## --disable-maintainer-mode`` then touching the stamp. The stamp is
  ## a separate file so subsequent ``make`` invocations rewriting
  ## ``Makefile`` don't break the action's cache hit signature.
  ##
  ## ``--disable-dependency-tracking`` collapses automake's
  ## ``.deps/*.Po`` machinery away (the convention spec calls it out as
  ## a soft requirement for the Mode A lift; even at M17's hybrid surface
  ## it makes the eventual Mode A graduation cheaper). Forcing
  ## ``--disable-maintainer-mode`` keeps autoreconf-rebuilds from
  ## triggering inside ``make``.
  ##
  ## ``set -e`` makes the compound abort on any non-zero exit — without
  ## it the stamp would be written even when ``configure`` failed.
  var parts: seq[string] = @[]
  parts.add("set -e")
  if needAutoreconf:
    parts.add("autoreconf -fi")
  parts.add("./configure --prefix=/ --disable-dependency-tracking " &
    "--disable-maintainer-mode")
  parts.add("touch \"$REPRO_CONFIGURE_STAMP\"")
  parts.join("; ")

proc emitConfigureAction(projectRoot, shExe: string;
                         needAutoreconf: bool):
                           tuple[action: BuildActionDef; stamp: string] =
  let stamp = configureStampPath(projectRoot)
  createDir(extendedPath(parentDir(stamp)))
  let script = renderConfigureScript(needAutoreconf)
  # Pass the stamp path through an env var to dodge embedded-quoting
  # hazards in the sh-c script: ``REPRO_CONFIGURE_STAMP`` is set on the
  # action's environment via a leading shell assignment ``REPRO_CONFIGURE_STAMP=...
  # set -e; ...``. Building the full sh-c argv with the var inline keeps
  # the action argv self-contained.
  let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
  let fullScript = "REPRO_CONFIGURE_STAMP=\"" & escapedStamp & "\"; " & script
  let argv = @[shExe, "-c", fullScript]
  let inputs = collectAutotoolsSources(projectRoot)
  let outputs = @[projectRoot / "Makefile", stamp]
  let action = buildAction(
    id = "ccpp-autotools-configure",
    call = inlineExecCall(argv, projectRoot),
    inputs = inputs,
    outputs = outputs,
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "ccpp-autotools.configure")
  (action, stamp)

proc binaryOutputs(projectRoot: string;
                   members: seq[CCppAutotoolsMember]): seq[string] =
  ## Predict the executable outputs the build will produce.  Automake's
  ## default in-tree shape puts ``bin_PROGRAMS = hello`` next to
  ## ``Makefile`` (with ``.exe`` suffix on Windows). Library outputs
  ## (``lib_LIBRARIES``) would land at the same level. The convention
  ## predicts the typical case; ``automaticMonitor`` would pick up the
  ## difference for any deviation.
  for member in members:
    case member.kind
    of catmkExecutable:
      when defined(windows):
        result.add(projectRoot / (member.name & ".exe"))
      else:
        result.add(projectRoot / member.name)
    of catmkLibraryStatic:
      result.add(projectRoot / ("lib" & member.name & ".a"))

proc emitBuildAction(projectRoot, makeExe, shExe: string;
                     configureActionId: string;
                     configureStamp: string;
                     members: seq[CCppAutotoolsMember]):
                       BuildActionDef =
  ## Single ``make`` action delegated to the generated Makefile. Inputs
  ## include the configure stamp (so a stale configure forces a rebuild)
  ## plus every source under ``src/``; outputs are the predicted
  ## binaries.
  ##
  ## On Windows we drive ``make`` via ``sh -c "make"`` so MSYS2's
  ## ``make`` finds its busybox ``cp`` / ``rm`` siblings on PATH (the
  ## convention spec §"Cross-platform notes" §"Windows" calls this out).
  ## On POSIX the direct ``make`` argv works without the shell wrap.
  let outputs = binaryOutputs(projectRoot, members)
  var inputs = @[configureStamp, projectRoot / "Makefile"]
  for src in collectBuildInputs(projectRoot):
    inputs.add(src)
  when defined(windows):
    let argv = @[shExe, "-c", "make"]
  else:
    let argv = @[makeExe]
  buildAction(
    id = "ccpp-autotools-build",
    call = inlineExecCall(argv, projectRoot),
    deps = @[configureActionId],
    inputs = inputs,
    outputs = outputs,
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "ccpp-autotools.build")

proc syntheticPackage(projectRoot: string;
                      members: seq[CCppAutotoolsMember]): PackageDef =
  var name = "c_cpp_autotools_convention"
  if members.len > 0:
    name = sanitizeNamePart(members[0].name)
  PackageDef(
    packageName: name,
    sourceFile: projectRoot / "reprobuild.nim",
    hasDevEnv: false,
    devEnvBodyHash: "",
    toolUses: @[])

proc cCppAutotoolsEmitFragment(projectRoot: string;
                               request: ProviderGraphRequest):
                                 GraphFragment {.gcsafe.} =
  ## Convention entry — emit two actions (configure + build), hand to
  ## ``buildPackageFragment``. The build action depends on the configure
  ## action via ``deps``.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let members = extractMembers(source)
    if members.len == 0:
      raise newException(ValueError,
        "c-cpp-autotools convention: no executable or library members " &
          "declared in " & projectRoot / "reprobuild.nim")
    let ccExe = ccCompiler()
    if ccExe.len == 0:
      raise newException(ValueError,
        "c-cpp-autotools convention: no C compiler on PATH")
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
    let pkg = syntheticPackage(projectRoot, members)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      let configurePair = emitConfigureAction(projectRoot, shExe,
        needAutoreconf)
      let buildAction = emitBuildAction(projectRoot, makeExe, shExe,
        configurePair.action.id, configurePair.stamp, members)
      defaultTarget(target("default", @[configurePair.action, buildAction]))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc cCppAutotoolsConvention*(): LanguageConvention =
  LanguageConvention(
    name: "c-cpp-autotools",
    recognize: cCppAutotoolsRecognize,
    emitFragment: cCppAutotoolsEmitFragment)
