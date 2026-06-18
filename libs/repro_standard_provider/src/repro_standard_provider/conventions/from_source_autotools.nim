## From-source Autotools language convention (Tier 2b) — M9.L.2.
##
## Sibling of both the M17/M28 ``c-cpp-autotools`` convention and the
## M9.L.0 ``from-source-meson`` / M9.L.1 ``from-source-cmake`` siblings.
## Where ``c-cpp-autotools`` recognises in-tree autotools projects
## (``<projectRoot>/configure.ac`` + ``<projectRoot>/Makefile.am``
## exist), this convention recognises **from-source recipes** — the
## recipe declares a ``fetch:`` block (vendored / upstream tarball) and
## *no* ``configure.ac`` / ``Makefile.am`` is present at projectRoot
## because the source has to be fetched + extracted first. The largest
## set of M9 from-source recipes (~30) follow this shape: expat,
## fontconfig, freetype, libpng, libjpeg-turbo, ..., plus several
## custom-configure dialects (zlib / openssl / sqlite) that LOOK like
## autotools to the convention dispatcher but actually run bespoke
## configure scripts.
##
## ## Recognition contract
##
## The convention claims a project when ALL of the following hold:
##
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists.
##   * The first ``package <ident>:`` block has a registered
##     ``DslFetchSpec`` (M9.H) AND a non-empty URL — i.e. the recipe
##     declared a ``fetch:`` block.
##   * The package has a registered ``configureFlags:`` channel
##     (M9.I ``registeredBuildFlags(<pkg>, "", "configure")`` returns a
##     non-empty seq). This is the **discriminator**: many recipes only
##     list ``make`` + ``gcc`` (and sometimes ``autoconf``/``automake``/
##     ``libtool``) in ``uses:``, so a uses-token check is unreliable.
##     The configureFlags channel is the unambiguous signal that the
##     recipe intends to drive a ``./configure`` step. The same
##     heuristic catches zlib / openssl / sqlite even though their
##     configure scripts aren't autoconf-generated — they all consume
##     a ``./configure``-style flag list.
##   * At least one ``executable`` / ``library`` member is declared in
##     the recipe source.
##   * NO ``configure.ac`` / ``Makefile.am`` at ``<projectRoot>``
##     (otherwise the existing in-tree M17/M28 ``c-cpp-autotools``
##     convention claims it).
##
## Tool availability (``make`` / ``gcc`` / ``sh`` on PATH) is NOT gated
## by ``recognize``. The actions emitted by ``emitFragment`` reference
## the resolved binaries via ``findExe`` lazily — the host may
## legitimately register a from-source recipe (so the unit + smoke
## tests round-trip) on a machine without a C toolchain installed. The
## actual build step still requires the toolchain at execution time.
## This matches the from-source-meson / from-source-cmake siblings'
## behaviour.
##
## ## Pipeline
##
## ``emitFragment`` produces the following action chain:
##
##   1. **Fetch** (``ccpp-fetch-<package>``) — downloads the tarball at
##      the URL declared in ``fetch:``, verifies the sha256/blake3, and
##      extracts to ``<projectRoot>/src/`` (or the path declared in
##      ``extractedRoot``). Implemented by the shared
##      ``conventions/fetch_action.emitFetchAction`` helper.
##
##   2. **Configure** (``from-source-autotools-configure``) — runs
##      ``./configure --prefix=/usr <configureFlags...>`` from the
##      extracted source dir. The ``--prefix=/usr`` anchor mirrors the
##      meson convention's ``--buildtype=release`` baseline and lets the
##      install step reason about ``<staging>/usr/{bin,lib}/`` layout
##      uniformly. ``configureFlags`` come from the M9.I
##      ``registeredBuildFlags`` registry on the ``"configure"`` channel;
##      order is preserved. Depends on the fetch action.
##
##   3. **Build** (``from-source-autotools-build``) — runs ``make`` from
##      the extracted source dir. In-tree build (no separate build dir)
##      because autotools projects historically default to in-tree;
##      out-of-tree builds with ``../configure`` are deferred. Depends on
##      the configure action.
##
##   4. **Install** (``from-source-autotools-install``) — runs ``make
##      install DESTDIR=<staging>``. ``DESTDIR`` is the standard
##      autotools escape hatch for non-root installs: make honours the
##      configure-time ``--prefix=/usr`` and writes binaries to
##      ``<staging>/usr/{bin,lib}/...``. Depends on the build action.
##
##   5. **Per-artifact stage-copy** (``from-source-autotools-stage-<member>``)
##      — copies the installed binary from ``<staging>/usr/bin/<member>``
##      (or ``lib/lib<member>.so`` for library members) to
##      ``<projectRoot>/.repro/output/<member>/<member>``. One action per
##      declared ``executable`` / ``library`` member. Depends on the
##      install action.
##
## ## Binary-cache publishing (M9.L.4-refactor Step B)
##
## The install + stage-copy actions stamp
## ``BuildActionDef.publishToBinaryCache = true`` AND
## ``cacheEntryIdentity = some(computeCacheEntryIdentity(...))`` so the
## engine's ``BinaryCachePublisher`` hook publishes ``<staging>/usr`` to
## ``repro-cache`` after a successful run. The convention no longer
## emits a publish edge of its own — see the meson convention's
## "Binary-cache publishing" section for the architectural rationale.
##
## ## Scratch layout
##
##   * Source extraction lives at ``<projectRoot>/src/`` (shared with
##     ``fetch_action``'s default extractedRoot).
##   * Build runs in-tree under ``<projectRoot>/src/`` (no separate
##     build dir).
##   * Staging dir lives at
##     ``<projectRoot>/.repro/build/from-source-autotools/staging/``.
##   * Per-action stamps live at
##     ``<projectRoot>/.repro/build/from-source-autotools/*.stamp``.
##   * Per-artifact output lives at
##     ``<projectRoot>/.repro/output/<member>/<member>``.
##
## ## Honest deferrals
##
##   * **End-to-end build run.** On hosts without ``make`` / ``gcc`` on
##     PATH the convention still emits the action graph (so the unit
##     test exercises the wiring), but the run will fail at action
##     execution time. The ``scripts/validate-from-source-autotools-
##     expat.ps1`` script is gated on toolchain availability.
##   * **Custom-configure dialects.** A handful of recipes look like
##     autotools to the dispatcher (they ship a ``./configure`` script
##     and consume a ``configureFlags:`` channel) but actually run
##     bespoke configure dialects:
##
##       * **zlib** — ``./configure`` is hand-written and uses
##         ``--shared`` (not ``--enable-shared``). The
##         ``./configure --prefix=/usr --shared`` invocation this
##         convention emits happens to be compatible with zlib's
##         dialect, but other zlib-style recipes with shorter / longer
##         flag conventions are not handled.
##       * **openssl** — drives a Perl ``./Configure linux-x86_64
##         <flags>`` script. The capital-C ``Configure`` script is NOT
##         what this convention invokes (it always emits lowercase
##         ``./configure``) AND the leading ``linux-x86_64`` platform
##         argument has no analogue in autoconf's flag model.
##       * **sqlite** — driven by ``./configure`` + a separate
##         ``Makefile.in`` template substitution step that this
##         convention's vanilla ``make`` won't perform.
##
##     These three recipes' authors should either (a) opt into a
##     follow-up sibling convention that knows about their dialect or
##     (b) carry a hand-written ``build:`` block in their ``repro.nim``.
##     For M9.L.2 they are **honest deferrals** documented in the
##     recipe's doc-comment; the convention's ``recognize`` may still
##     match them via the configureFlags discriminator but the
##     end-to-end build will fail loudly.
##   * **Installed-binary path resolution.** Autotools' default install
##     layout is ``${prefix}/bin/<exe>`` and ``${prefix}/lib/lib<name>.so``
##     where ``${prefix}`` is the configure-time ``--prefix`` value.
##     We pass ``--prefix=/usr`` as an anchor so paths are predictable;
##     the M9.L.2 vertical slice doesn't honour recipe-side ``--prefix=``
##     overrides in configureFlags (the right-most occurrence wins by
##     autoconf convention so a recipe that explicitly sets
##     ``--prefix=/usr/local`` will still install to /usr/local, and
##     our stage-copy will look in the wrong place — a known limitation).
##   * **Library outputs.** Library member kinds emit a stage-copy that
##     looks under ``<staging>/usr/lib/`` for the ``lib<member>.so``
##     shape. Libtool-archive (``.la``) files, SONAME-versioned shared
##     objects (``libexpat.so.1.10.0``), and static archives
##     (``lib<member>.a``) need follow-up work — expat (the M9.L.2
##     vertical slice) ships a shared library that matches the
##     ``lib<member>.so`` shape after libtool's
##     final-link symlink dance.
##   * **autoreconf bootstrap.** Recipes whose tarball ships a stale
##     ``configure`` (or doesn't ship one at all) need a leading
##     ``autoreconf -fi`` step. The M9.L.2 slice doesn't emit this
##     step — modern release tarballs (expat, fontconfig, freetype, ...)
##     all ship a pre-generated ``configure`` and the test set works
##     without bootstrapping. The c_cpp_autotools sibling has an
##     ``hasGeneratedConfigure`` probe + leading ``autoreconf`` that
##     could be lifted into a follow-up milestone when a recipe
##     surfaces the need.
##   * **Out-of-tree builds.** Autotools supports ``mkdir _build && cd
##     _build && ../configure`` for an out-of-tree build, but the
##     M9.L.2 slice runs configure + make in-tree under
##     ``<projectRoot>/src/``. Out-of-tree is a follow-up.
##
## See ``reprobuild-specs/M9-DSL-Port-Engine-Provider.milestones.org``
## §M9.L.

import std/[os, strutils]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/fetch_action

# M9.L.4-refactor Step B binary-cache identity wiring. The shared
# ``from_source_identity`` module owns the cache-key composition; this
# convention only supplies the convention tag (``"autotools"``) per
# stage-copy / install action. The Step-A-era publish-action emitter is
# gone — the engine's ``BinaryCachePublisher`` hook publishes
# transparently when ``BuildActionDef.publishToBinaryCache`` is true
# and ``cacheEntryIdentity`` is populated.
import std/options
import repro_standard_provider/conventions/from_source_identity

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root — mirrors the
    ## in-tree c_cpp_* conventions and the from-source-meson /
    ## from-source-cmake siblings.

  FromSourceAutotoolsSubdir* = "from-source-autotools"
    ## Per-convention sub-directory under ``.repro/build/``. Lets a
    ## project simultaneously host an in-tree autotools build (the
    ## ``autotools`` subdir from ``c-cpp-autotools``) and a from-source
    ## build (this convention's subdir) without colliding.

  OutputDirName* = ".repro/output"
    ## Canonical per-artifact output dir. Mirrors the existing direct
    ## conventions' (c_cpp_direct etc.) shape.

  InstallPrefix* = "/usr"
    ## Anchor configure-time ``--prefix`` value. Autotools projects
    ## install to ``<prefix>/bin`` + ``<prefix>/lib`` so pinning the
    ## prefix lets the stage-copy step reason about the staging layout
    ## uniformly. Recipes whose configureFlags override ``--prefix``
    ## will see the stage-copy look in the wrong place — a known
    ## limitation; see module docstring's "Honest deferrals" section.

type
  FromSourceAutotoolsMemberKind = enum
    fsaExecutable
    fsaLibraryStatic

  FromSourceAutotoolsMember = object
    name: string
    kind: FromSourceAutotoolsMemberKind

# ---------------------------------------------------------------------------
# Source helpers — shared verbatim with from_source_meson.nim /
# from_source_cmake.nim. Copied (not imported) because c_cpp_autotools
# keeps the procs private; lifting them to a shared module would force a
# refactor and the existing convention tests need byte-identical
# recognise behaviour on the in-tree path.
# ---------------------------------------------------------------------------

proc readReprobuildSource(projectRoot: string): string =
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

proc extractMembers(source: string): seq[FromSourceAutotoolsMember] =
  ## Scan the recipe text for ``executable <name>:`` / ``library <name>:``
  ## declarations. Same shape as ``from_source_cmake.extractMembers`` /
  ## ``from_source_meson.extractMembers``; the from-source convention
  ## claims every executable / library declared anywhere in the recipe
  ## body.
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    var kind = fsaExecutable
    var verb = ""
    if stripped.startsWith("executable") and
        (stripped.len == len("executable") or
         stripped[len("executable")] in {' ', '\t'}):
      verb = "executable"
      kind = fsaExecutable
    elif stripped.startsWith("library") and
        (stripped.len == len("library") or
         stripped[len("library")] in {' ', '\t'}):
      verb = "library"
      kind = fsaLibraryStatic
    else:
      continue
    let rest = stripped[verb.len .. ^1].strip()
    if rest.len == 0:
      continue
    var name = ""
    for ch in rest:
      if ch in {' ', '\t', ':', ','}:
        break
      name.add(ch)
    if name.len > 0:
      result.add(FromSourceAutotoolsMember(name: name, kind: kind))

proc extractFirstPackageName(source: string): string =
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

proc hasConfigureAc(projectRoot: string): bool =
  ## True when ``configure.ac`` or legacy ``configure.in`` exists at the
  ## project root. The from-source variant intentionally yields when the
  ## in-tree autoconf source is present so the existing M17/M28
  ## ``c-cpp-autotools`` convention claims it.
  fileExists(extendedPath(projectRoot / "configure.ac")) or
    fileExists(extendedPath(projectRoot / "configure.in"))

proc hasMakefileAm(projectRoot: string): bool =
  fileExists(extendedPath(projectRoot / "Makefile.am"))

# ---------------------------------------------------------------------------
# Path layout
# ---------------------------------------------------------------------------

proc stagingDir(projectRoot: string): string =
  projectRoot / ScratchDirName / FromSourceAutotoolsSubdir / "staging"

proc stampDir(projectRoot: string): string =
  ## Per-action stamp directory. The autotools convention has no
  ## meaningful "build dir" of its own (it runs configure + make in
  ## ``<projectRoot>/src/``) so stamps live in a sibling subdir under
  ## ``.repro/build/from-source-autotools/`` to keep ``repro clean``
  ## semantics consistent.
  projectRoot / ScratchDirName / FromSourceAutotoolsSubdir / "stamps"

proc configureStampPath(projectRoot: string): string =
  ## A custom stamp file the configure action touches on success. The
  ## downstream build / install actions key off the stamp instead of
  ## autotools' generated ``Makefile`` / ``config.status`` (which can be
  ## touched during build too).
  stampDir(projectRoot) / "from-source-autotools-configure.stamp"

proc buildStampPath(projectRoot: string): string =
  stampDir(projectRoot) / "from-source-autotools-build.stamp"

proc installStampPath(projectRoot: string): string =
  stampDir(projectRoot) / "from-source-autotools-install.stamp"

proc artifactOutputDir(projectRoot, member: string): string =
  projectRoot / OutputDirName / member

proc artifactOutputPath(projectRoot, member: string;
                        kind: FromSourceAutotoolsMemberKind): string =
  case kind
  of fsaExecutable:
    when defined(windows):
      artifactOutputDir(projectRoot, member) / (member & ".exe")
    else:
      artifactOutputDir(projectRoot, member) / member
  of fsaLibraryStatic:
    artifactOutputDir(projectRoot, member) / ("lib" & member & ".so")

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

# ---------------------------------------------------------------------------
# Tool discovery — lazy. ``recognize`` does NOT call these (per the
# module docstring): a host without ``make`` / ``gcc`` can still
# register the convention, exercise it via tests, and lower the action
# graph; the actual build run will fail loudly at execution time.
# ---------------------------------------------------------------------------

proc makeExecutable(): string =
  let resolved = findExe("make")
  if resolved.len > 0:
    return resolved
  # Stable placeholder so ``inlineExecCall`` doesn't refuse an empty
  # argv[0]. The action will fail at execution time with a clearer
  # diagnostic than a silent skip.
  "make"

# ---------------------------------------------------------------------------
# Action emission
# ---------------------------------------------------------------------------

proc emitConfigureAction(projectRoot, srcDir: string;
                         configureFlags: seq[string];
                         fetchDeps: seq[string];
                         fetchStamps: seq[string]):
                           tuple[action: BuildActionDef; stamp: string] =
  ## ``cd <srcDir> && ./configure --prefix=/usr <configureFlags...>``.
  ##
  ## The convention always passes ``--prefix=/usr`` as an anchor flag so
  ## the install step lands binaries at a predictable
  ## ``<staging>/usr/{bin,lib}/`` location. Recipes whose configureFlags
  ## already include ``--prefix=`` will see autoconf honour the LAST
  ## occurrence (right-most wins) — a known limitation; see module
  ## docstring.
  createDir(extendedPath(stampDir(projectRoot)))
  let stamp = configureStampPath(projectRoot)
  let shExe = findExe("sh")
  var argv: seq[string]
  if shExe.len > 0:
    let escapedSrc = srcDir.replace("\\", "/").replace("\"", "\\\"")
    let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
    var trailingOpts = ""
    for opt in configureFlags:
      trailingOpts.add(" \"")
      trailingOpts.add(opt.replace("\"", "\\\""))
      trailingOpts.add("\"")
    let script = "set -e; cd \"" & escapedSrc &
      "\"; ./configure --prefix=" & InstallPrefix & trailingOpts &
      "; touch \"" & escapedStamp & "\""
    argv = @[shExe, "-c", script]
  else:
    # On the rare host without ``sh`` on PATH we fall back to a direct
    # ``./configure`` argv that runs from ``projectRoot``; the
    # action's workingDir is set to ``srcDir`` by ``inlineExecCall``'s
    # second arg so the configure script resolves relatively. This path
    # is best-effort — autotools configure scripts assume a POSIX
    # ``sh`` is available regardless.
    argv = @["./configure", "--prefix=" & InstallPrefix]
    for opt in configureFlags:
      argv.add(opt)
  var inputs: seq[string] = @[]
  for st in fetchStamps:
    inputs.add(st)
  let action = buildAction(
    id = "from-source-autotools-configure",
    call = inlineExecCall(argv, projectRoot),
    deps = fetchDeps,
    inputs = inputs,
    outputs = @[stamp],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "from-source-autotools.configure")
  (action, stamp)

proc emitBuildAction(projectRoot, makeExe, srcDir, configureStamp: string):
                       tuple[action: BuildActionDef; stamp: string] =
  ## ``cd <srcDir> && make``. The stamp file lets downstream actions key
  ## off build success without relying on autotools-generated
  ## ``Makefile`` touch behaviour.
  let stamp = buildStampPath(projectRoot)
  let shExe = findExe("sh")
  var argv: seq[string]
  if shExe.len > 0:
    let escapedMake = makeExe.replace("\\", "/").replace("\"", "\\\"")
    let escapedSrc = srcDir.replace("\\", "/").replace("\"", "\\\"")
    let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
    let script = "set -e; cd \"" & escapedSrc & "\"; \"" & escapedMake &
      "\"; touch \"" & escapedStamp & "\""
    argv = @[shExe, "-c", script]
  else:
    argv = @[makeExe]
  let action = buildAction(
    id = "from-source-autotools-build",
    call = inlineExecCall(argv, projectRoot),
    deps = @["from-source-autotools-configure"],
    inputs = @[configureStamp],
    outputs = @[stamp],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "from-source-autotools.build")
  (action, stamp)

proc emitInstallAction(projectRoot, makeExe, srcDir, staging,
                       buildStamp: string;
                       identity: CacheEntryIdentity):
                         tuple[action: BuildActionDef; stamp: string] =
  ## ``cd <srcDir> && make install DESTDIR=<staging>``.
  ##
  ## ``DESTDIR`` is the standard autotools escape hatch for non-root
  ## installs: make honours the configure-time ``--prefix`` and
  ## prefixes every install path with ``<destdir>``. Binaries land at
  ## ``<staging>/usr/bin/...`` and libraries at ``<staging>/usr/lib/...``
  ## given the ``--prefix=/usr`` anchor.
  ##
  ## M9.L.4-refactor Step B: stamps the binary-cache identity tuple on
  ## the install action so the engine's ``BinaryCachePublisher`` hook
  ## fires after a successful install.
  createDir(extendedPath(staging))
  let stamp = installStampPath(projectRoot)
  let shExe = findExe("sh")
  var argv: seq[string]
  if shExe.len > 0:
    let escapedMake = makeExe.replace("\\", "/").replace("\"", "\\\"")
    let escapedSrc = srcDir.replace("\\", "/").replace("\"", "\\\"")
    let escapedStaging = staging.replace("\\", "/").replace("\"", "\\\"")
    let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
    let script = "set -e; cd \"" & escapedSrc & "\"; \"" & escapedMake &
      "\" install DESTDIR=\"" & escapedStaging &
      "\"; touch \"" & escapedStamp & "\""
    argv = @[shExe, "-c", script]
  else:
    argv = @[makeExe, "install", "DESTDIR=" & staging]
  let action = buildAction(
    id = "from-source-autotools-install",
    call = inlineExecCall(argv, projectRoot),
    deps = @["from-source-autotools-build"],
    inputs = @[buildStamp],
    outputs = @[stamp],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "from-source-autotools.install",
    publishToBinaryCache = true,
    cacheEntryIdentity = some(identity))
  (action, stamp)

proc stripLibPrefix(name: string): string =
  ## Autotools recipes commonly declare library members under names like
  ## ``libExpat`` whose installed file is ``libexpat.so`` — i.e. the
  ## ``lib`` prefix is already part of the member name. The stage-copy
  ## logic expects to look at ``<staging>/usr/lib/<installed>``; if the
  ## member name starts with ``lib`` we use it verbatim, otherwise we
  ## prefix ``lib`` to match libtool's naming convention. This is a
  ## best-effort heuristic; recipes whose installed file name diverges
  ## (e.g. SONAME-versioned ``libexpat.so.1.10.0``) need an
  ## ``installedAs:`` knob (deferred — see module docstring).
  if name.startsWith("lib"):
    name
  else:
    "lib" & name

proc stagedBinaryPath(staging, member: string;
                      kind: FromSourceAutotoolsMemberKind): string =
  ## Heuristic guess at the autotools-installed path. ``make install
  ## DESTDIR=<staging>`` with ``--prefix=/usr`` lays binaries at
  ## ``<staging>/usr/bin/<member>`` and libraries at
  ## ``<staging>/usr/lib/<libname>.so``. For libraries the member name
  ## is normalised via ``stripLibPrefix`` because recipes commonly
  ## declare a member like ``libExpat`` whose installed file is
  ## already ``libexpat.so``.
  case kind
  of fsaExecutable:
    when defined(windows):
      staging / "usr" / "bin" / (member & ".exe")
    else:
      staging / "usr" / "bin" / member
  of fsaLibraryStatic:
    # ``stripLibPrefix(libExpat) == "libExpat"`` then we apply
    # ``toLowerAscii`` because libtool-built shared objects use the
    # lowercased package name (``libexpat.so``) regardless of the
    # camelCase member identifier used in the recipe. This matches
    # expat's installed file name; recipes whose installed file name
    # diverges (KF6 / Qt-style PascalCase SONAMEs) need an
    # ``installedAs:`` knob.
    let prefixed = stripLibPrefix(member)
    let lowered = prefixed.toLowerAscii()
    staging / "usr" / "lib" / (lowered & ".so")

proc emitStageCopyAction(projectRoot, staging, installStamp: string;
                         member: FromSourceAutotoolsMember;
                         identity: CacheEntryIdentity): BuildActionDef =
  ## Copy ``<staging>/usr/bin/<member>`` (or
  ## ``<staging>/usr/lib/lib<member>.so``) to
  ## ``<projectRoot>/.repro/output/<member>/<member>``. This action is
  ## what the engine's output-collection step keys off — the canonical
  ## per-artifact output path matches the existing direct conventions'
  ## ``<root>/.repro/output/<name>/<name>`` schema.
  ##
  ## M9.L.4-refactor Step B: stamps the binary-cache identity tuple on
  ## the stage-copy action so the engine's ``BinaryCachePublisher`` hook
  ## fires after a successful per-artifact stage.
  let outDir = artifactOutputDir(projectRoot, member.name)
  createDir(extendedPath(outDir))
  let outPath = artifactOutputPath(projectRoot, member.name, member.kind)
  let stagedPath = stagedBinaryPath(staging, member.name, member.kind)
  let shExe = findExe("sh")
  var argv: seq[string]
  if shExe.len > 0:
    let escapedStaged = stagedPath.replace("\\", "/").replace("\"", "\\\"")
    let escapedOut = outPath.replace("\\", "/").replace("\"", "\\\"")
    let escapedOutDir = outDir.replace("\\", "/").replace("\"", "\\\"")
    let script = "set -e; mkdir -p \"" & escapedOutDir &
      "\"; cp -f \"" & escapedStaged & "\" \"" & escapedOut & "\""
    argv = @[shExe, "-c", script]
  else:
    argv = @["cp", stagedPath, outPath]
  let kindTag = case member.kind
    of fsaExecutable: "executable"
    of fsaLibraryStatic: "library-static"
  buildAction(
    id = "from-source-autotools-stage-" & sanitizeNamePart(member.name),
    call = inlineExecCall(argv, projectRoot),
    deps = @["from-source-autotools-install"],
    inputs = @[installStamp],
    outputs = @[outPath],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "from-source-autotools.stage." & kindTag,
    publishToBinaryCache = true,
    cacheEntryIdentity = some(identity))

# ---------------------------------------------------------------------------
# Convention entry
# ---------------------------------------------------------------------------

proc fromSourceAutotoolsRecognize(projectRoot: string;
                                  request: ProviderGraphRequest):
                                    bool {.gcsafe.} =
  ## Recognition contract — see module docstring.
  ##
  ## M9.N: claims a recipe based on DECLARATION (``fetch:`` registered +
  ## non-empty configure flags channel + no in-tree autotools manifest
  ## at projectRoot). NO host-PATH gate — the engine resolves tool
  ## identity AFTER recognise, possibly via cache substitute or source
  ## build.
  ##
  ## TODO(M9.N Batch B): resolve tool identity through engine instead of
  ## findExe at emit time.
  if hasConfigureAc(projectRoot) or hasMakefileAm(projectRoot):
    # In-tree autotools project — the existing M17/M28
    # ``c-cpp-autotools`` convention claims this. The from-source
    # variant intentionally yields so the in-tree fixture tests don't
    # change behaviour.
    return false
  let source = readReprobuildSource(projectRoot)
  if source.len == 0:
    return false
  let dslPackageName = extractFirstPackageName(source)
  if dslPackageName.len == 0:
    return false
  {.cast(gcsafe).}:
    let spec = registeredFetchSpec(dslPackageName)
    if spec.url.len == 0 or spec.hashHex.len == 0:
      return false
    # The configureFlags channel is the unambiguous discriminator.
    # Recipes that list ``make`` / ``gcc`` in ``uses:`` without
    # ``autoconf``/``automake``/``libtool`` still legitimately drive a
    # ``./configure`` step (zlib, openssl, sqlite). The presence of any
    # registered configure-channel flag tells us the recipe author
    # intends to use ``./configure`` regardless of the ``uses:`` token
    # mix.
    let configureFlags = registeredBuildFlags(dslPackageName, "", "configure")
    if configureFlags.len == 0:
      return false
  if extractMembers(source).len == 0:
    return false
  true

proc syntheticPackage(projectRoot: string;
                      members: seq[FromSourceAutotoolsMember]): PackageDef =
  var name = "from_source_autotools_convention"
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

proc fromSourceAutotoolsEmitFragment(projectRoot: string;
                                     request: ProviderGraphRequest):
                                       GraphFragment {.gcsafe.} =
  ## Lower the recipe into a fetch + configure + build + install + per-
  ## member stage-copy action graph. See module docstring's pipeline
  ## section.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let members = extractMembers(source)
    if members.len == 0:
      let projectMatch = resolveProjectFile(projectRoot)
      let projectFile =
        if projectMatch.path.len > 0: projectMatch.path
        else: projectRoot / LegacyProjectFileName
      raise newException(ValueError,
        "from-source-autotools convention: no executable or library " &
          "members declared in " & projectFile)
    let dslPackageName = extractFirstPackageName(source)
    if dslPackageName.len == 0:
      raise newException(ValueError,
        "from-source-autotools convention: no 'package <name>:' block in " &
          projectRoot)
    let spec = registeredFetchSpec(dslPackageName)
    if spec.url.len == 0 or spec.hashHex.len == 0:
      raise newException(ValueError,
        "from-source-autotools convention: no fetch: spec registered for " &
          "package '" & dslPackageName & "' — recognise() should have " &
          "rejected this project")
    let makeExe = makeExecutable()
    let configureFlags = registeredBuildFlags(dslPackageName, "", "configure")
    let srcDir = fetchExtractedRoot(projectRoot, spec)
    let staging = stagingDir(projectRoot)
    let pkg = syntheticPackage(projectRoot, members)
    # M9.L.4-refactor Step B: compose the binary-cache identity once
    # and thread it onto the install + stage-copy edges. The engine's
    # ``BinaryCachePublisher`` hook consumes the same tuple from the
    # decoded ``BuildAction``; conventions stay tool-agnostic.
    let identity = computeCacheEntryIdentity(projectRoot,
      dslPackageName, "autotools")
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      discard buildPool("fetch", 2'u32)
      var allActions: seq[BuildActionDef] = @[]
      # 1. Fetch
      let fetchAct = emitFetchAction(projectRoot, dslPackageName, spec)
      allActions.add(fetchAct)
      let fetchStamp = fetchStampPath(projectRoot, spec.hashHex)
      # 2. Configure
      let configurePair = emitConfigureAction(projectRoot, srcDir,
        configureFlags, @[fetchAct.id], @[fetchStamp])
      allActions.add(configurePair.action)
      # 3. Build
      let buildPair = emitBuildAction(projectRoot, makeExe, srcDir,
        configurePair.stamp)
      allActions.add(buildPair.action)
      # 4. Install — carries the binary-cache identity so the engine
      # hook publishes the install tree after success.
      let installPair = emitInstallAction(projectRoot, makeExe, srcDir,
        staging, buildPair.stamp, identity)
      allActions.add(installPair.action)
      # 5. Per-artifact stage-copy — each edge also carries the
      # identity. The engine's hook fires per successful action; the
      # convention does NOT emit a separate publish edge any more (the
      # Step-A-era ``emitPublishAction`` retired in Step B).
      for member in members:
        let stageAct = emitStageCopyAction(projectRoot, staging,
          installPair.stamp, member, identity)
        allActions.add(stageAct)
      defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc fromSourceAutotoolsConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  ##
  ## Registered BEFORE the existing ``c-cpp-autotools`` sibling so the
  ## from-source variant claims recipes that declare a ``fetch:`` block
  ## (no in-tree ``configure.ac`` / ``Makefile.am`` at projectRoot — the
  ## source has to be fetched + extracted first). The convention's
  ## ``recognize`` rejects when those files ARE present at the root so
  ## the in-tree M17/M28 convention claims those projects; registration
  ## order is defensive in either direction.
  LanguageConvention(
    name: "from-source-autotools",
    recognize: fromSourceAutotoolsRecognize,
    emitFragment: fromSourceAutotoolsEmitFragment)
