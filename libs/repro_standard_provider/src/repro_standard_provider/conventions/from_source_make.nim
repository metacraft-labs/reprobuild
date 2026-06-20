## From-source plain-Make / kbuild language convention (Tier 2b) — M9.L.3.
##
## Sibling of the M17 ``c-cpp-make`` convention and the M9.L.0 /
## M9.L.1 / M9.L.2 from-source siblings (meson / cmake / autotools).
## Where ``c-cpp-make`` recognises in-tree plain-Make projects (a
## ``Makefile`` / ``GNUmakefile`` exists at ``<projectRoot>``), this
## convention recognises **from-source recipes** — the recipe declares
## a ``fetch:`` block (vendored / upstream tarball) and *no*
## ``Makefile`` is present at projectRoot because the source has to
## be fetched + extracted first. The M9.L.3 vertical slice covers two
## from-source production recipes that drive a RAW Makefile (no
## ``./configure`` step):
##
##   * ``libcapSource`` (``recipes/packages/source/libcap/``) — vanilla
##     ``make install DESTDIR=<staging>`` against libcap's raw
##     Makefile. Stage-copy lands at ``<staging>/usr/sbin/capsh``
##     etc. Library member ``libCap`` lands at
##     ``<staging>/usr/lib/libcap.so``.
##   * ``kernelSource`` (``recipes/packages/source/kernel/``) — kbuild
##     against the kernel tree. ``make install`` is NOT the canonical
##     way to harvest kernel artefacts (kbuild's install target moves
##     things into ``/lib/modules`` etc.); instead the kernel image
##     and friends live at well-known paths inside the extracted
##     source tree (``arch/x86/boot/bzImage`` etc.). The stage-copy
##     step probes those kernel-specific paths first, then falls back
##     to the usual ``<staging>/usr/{bin,lib}/<member>`` layout.
##
## ## Recognition contract
##
## The convention claims a project when ALL of the following hold:
##
##   * ``<projectRoot>/repro.nim`` (or legacy ``reprobuild.nim``) exists.
##   * The first ``package <ident>:`` block has a registered
##     ``DslFetchSpec`` (M9.H) AND a non-empty URL — i.e. the recipe
##     declared a ``fetch:`` block.
##   * The package has a registered ``makeFlags:`` channel (M9.I
##     ``registeredBuildFlags(<pkg>, "", "make")`` returns a non-empty
##     seq). This is the **discriminator** — the channel is the
##     unambiguous signal that the recipe intends to drive ``make``.
##   * The package has NO registered ``configureFlags:`` channel
##     (otherwise the M9.L.2 ``from-source-autotools`` sibling claims
##     it first).
##   * The package has NO registered ``mesonOptions:`` channel
##     (otherwise the M9.L.0 ``from-source-meson`` sibling claims it).
##   * The package has NO registered ``cmakeFlags:`` channel
##     (otherwise the M9.L.1 ``from-source-cmake`` sibling claims it).
##   * NO in-tree ``Makefile.am`` / ``configure.ac`` / ``meson.build``
##     / ``CMakeLists.txt`` at ``<projectRoot>`` (otherwise the
##     existing in-tree convention for that build system claims it).
##   * At least one ``executable`` / ``library`` / ``files`` member is
##     declared in the recipe source.
##
## Tool availability (``make`` / ``gcc`` / ``sh`` on PATH) is NOT
## gated by ``recognize``. The actions emitted by ``emitFragment``
## reference the resolved binaries via ``findExe`` lazily — the host
## may legitimately register a from-source recipe (so the unit + smoke
## tests round-trip) on a machine without a C toolchain installed.
## The actual build step still requires the toolchain at execution
## time. This matches the from-source-meson / from-source-cmake /
## from-source-autotools siblings' behaviour.
##
## ## Pipeline
##
## ``emitFragment`` produces the following action chain:
##
##   1. **Fetch** (``ccpp-fetch-<package>``) — downloads the tarball
##      at the URL declared in ``fetch:``, verifies the sha256/blake3,
##      and extracts to ``<projectRoot>/src/`` (or the path declared
##      in ``extractedRoot``). Implemented by the shared
##      ``conventions/fetch_action.emitFetchAction`` helper.
##
##   2. **Build** (``from-source-make-build``) — runs ``make
##      <makeFlags...>`` from the extracted source dir. No configure
##      step — the recipes targeted by this convention drive raw
##      Makefiles (libcap) or kbuild's top-level Makefile (kernel)
##      directly. ``makeFlags`` come from the M9.I
##      ``registeredBuildFlags`` registry on the ``"make"`` channel;
##      order is preserved. Depends on the fetch action.
##
##   3. **Install** (``from-source-make-install``) — runs ``make
##      install DESTDIR=<staging>``. ``DESTDIR`` is the standard
##      escape hatch for non-root installs: make honours the
##      Makefile's own prefix and writes binaries to
##      ``<staging>/usr/...``. For libcap this lands binaries at
##      ``<staging>/usr/sbin/`` (per the recipe's ``prefix=/usr``
##      makeFlag); for the kernel the install action still runs but
##      the kernel-specific stage-copy probes the in-source paths
##      first so its output is not harvested from staging. Depends on
##      the build action.
##
##   4. **Per-artifact stage-copy** (``from-source-make-stage-<member>``)
##      — copies the artifact to
##      ``<projectRoot>/.repro/output/<member>/<member>``. One action
##      per declared ``executable`` / ``library`` / ``files`` member.
##      Depends on the install action. The probe order is:
##
##        * ``<src>/arch/x86/boot/<member>``   (kernel image path)
##        * ``<src>/<member>``                 (kernel root-tree path —
##                                              vmlinux / System.map)
##        * ``<src>/include/config/<file>``    (kernel KERNELRELEASE
##                                              maps via the
##                                              ``kernelRelease`` ->
##                                              ``kernel.release`` alias)
##        * ``<staging>/usr/sbin/<member>``    (libcap-style sbin layout)
##        * ``<staging>/usr/bin/<member>``     (vanilla install)
##        * ``<staging>/usr/lib/lib<member>.so`` (library member)
##
##      The probe is materialised in the emitted shell script as a
##      cascading ``[ -f ... ] || ...`` chain so the run hits the
##      first existing path. This keeps the kernel as a special-case
##      INSIDE the generic from-source-make convention without
##      forking off a dedicated convention; libcap's straight-install
##      members and the kernel's in-source artefacts both round-trip
##      through the same convention.
##
## ## Binary-cache publishing (M9.L.4-refactor Step B)
##
## The install + stage-copy actions stamp
## ``BuildActionDef.publishToBinaryCache = true`` AND
## ``cacheEntryIdentity = some(computeCacheEntryIdentity(...))`` so the
## engine's ``BinaryCachePublisher`` hook publishes ``<staging>`` to
## ``repro-cache`` after a successful run. The convention no longer
## emits a publish edge of its own — see the meson convention's
## "Binary-cache publishing" section for the architectural rationale.
## The kernel-vs-libcap publish-payload asymmetry called out in M9.L.4
## still holds: libcap's published payload covers
## ``<staging>/usr/{sbin,lib}/``; the kernel's published payload is
## empty (deferred until a custom prefix strategy lifts kernel artefacts
## out of the in-source tree).
##
## ## Scratch layout
##
##   * Source extraction lives at ``<projectRoot>/src/`` (shared with
##     ``fetch_action``'s default extractedRoot).
##   * Build runs in-tree under ``<projectRoot>/src/`` (no separate
##     build dir).
##   * Staging dir lives at
##     ``<projectRoot>/.repro/build/from-source-make/staging/``.
##   * Per-action stamps live at
##     ``<projectRoot>/.repro/build/from-source-make/stamps/``.
##   * Per-artifact output lives at
##     ``<projectRoot>/.repro/output/<member>/<member>``.
##
## ## Honest deferrals
##
##   * **End-to-end build run.** On hosts without ``make`` / ``gcc``
##     on PATH the convention still emits the action graph (so the
##     unit test exercises the wiring), but the run will fail at
##     action execution time. The
##     ``scripts/validate-from-source-make-libcap.ps1`` script is
##     gated on toolchain availability.
##   * **Kernel ``.config`` prerequisite.** A real kernel build needs
##     a ``.config`` file at the source root BEFORE ``make bzImage``
##     will produce anything — the canonical pattern is
##     ``make defconfig`` (or copy a pinned config file in) as a
##     prerequisite step. The M9.L.3 vertical slice does NOT emit
##     this step; the kernel recipe's smoke test exercises the
##     fetch + makeFlags + artifact-registration round-trip but the
##     end-to-end build is deferred until the convention grows a
##     ``preBuild:`` hook or auto-invokes ``make defconfig``.
##     ``recipes/packages/source/kernel/repro.nim``'s
##     "Honest deferrals" comment documents the upstream-DSL side of
##     the same gap.
##   * **Kernel ``make install`` semantics.** Kernel kbuild's
##     ``install`` target moves the bzImage to ``/boot/`` and the
##     modules tree to ``/lib/modules/<release>/``; the M9.L.3 slice
##     runs the install action regardless but the kernel stage-copy
##     probes the in-source paths first so the install output is not
##     actually consumed. A follow-up milestone can either (a) gate
##     the install action off for kernel-shaped recipes via a
##     ``noInstall:`` flag on the recipe DSL or (b) let the
##     stage-copy short-circuit when the in-source path already
##     exists. v1 keeps the install action for symmetry with the
##     libcap path.
##   * **Library SONAME-versioning.** Library member kinds emit a
##     stage-copy that looks under ``<staging>/usr/lib/`` for the
##     ``lib<member>.so`` shape (lowercased, ``lib`` prefix
##     preserved). SONAME-versioned shared objects
##     (``libcap.so.2.71``) and static archives (``libcap.a``) need
##     follow-up work — libcap (the M9.L.3 vertical slice) ships a
##     shared library that matches the ``lib<member>.so`` shape after
##     the Makefile's final-link symlink dance.
##   * **Modules tree.** The kernel build also emits a modules tree
##     (``$(MODLIB)/kernel/...``) with hundreds to thousands of
##     ``.ko`` files. v1 does NOT enumerate them — the per-config set
##     is too large and variable. A follow-up milestone will likely
##     model the modules tree as a single directory-output artifact.
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
# convention only supplies the convention tag (``"make"``) per stage-
# copy / install action. The Step-A-era publish-action emitter is gone
# — the engine's ``BinaryCachePublisher`` hook publishes transparently
# when ``BuildActionDef.publishToBinaryCache`` is true and
# ``cacheEntryIdentity`` is populated.
import std/options
import repro_standard_provider/conventions/from_source_identity

const
  ScratchDirName* = ".repro/build"
    ## Top-level scratch directory under the project root — mirrors
    ## the other from-source siblings.

  FromSourceMakeSubdir* = "from-source-make"
    ## Per-convention sub-directory under ``.repro/build/``. Lets a
    ## project simultaneously host an in-tree make build (the
    ## ``c-cpp-make`` subdir) and a from-source build (this
    ## convention's subdir) without colliding.

  OutputDirName* = ".repro/output"
    ## Canonical per-artifact output dir. Mirrors the existing direct
    ## conventions' (c_cpp_direct etc.) shape.

type
  FromSourceMakeMemberKind = enum
    fsmkExecutable
    fsmkLibrary
    fsmkFiles
      ## ``files <name>:`` block — data outputs that route under
      ## ``share/`` / ``lib/`` in the package's output tree. The
      ## kernel's vmlinux / System.map / kernelRelease all land here.

  FromSourceMakeMember = object
    name: string
    kind: FromSourceMakeMemberKind

# ---------------------------------------------------------------------------
# Source helpers — same shape as the prior from-source siblings.
# Copied (not imported) because the siblings keep their procs private;
# the lift to a shared module is a future refactor.
# ---------------------------------------------------------------------------

proc readReprobuildSource(projectRoot: string): string =
  let match = resolveProjectFile(projectRoot)
  if match.path.len == 0:
    return ""
  try:
    readFile(extendedPath(match.path))
  except CatchableError:
    ""

proc extractMembers(source: string): seq[FromSourceMakeMember] =
  ## Scan the recipe text for ``executable <name>:`` / ``library <name>:``
  ## / ``files <name>:`` declarations. The kernel recipe combines one
  ## executable (bzImage) with three files artefacts (vmlinux,
  ## System.map, kernelRelease); the convention claims every declared
  ## member regardless of kind so the stage-copy step can emit one
  ## action per artefact.
  for rawLine in source.splitLines():
    var line = rawLine
    let commentIdx = line.find('#')
    if commentIdx >= 0:
      line = line[0 ..< commentIdx]
    let stripped = line.strip()
    var kind = fsmkExecutable
    var verb = ""
    if stripped.startsWith("executable") and
        (stripped.len == len("executable") or
         stripped[len("executable")] in {' ', '\t'}):
      verb = "executable"
      kind = fsmkExecutable
    elif stripped.startsWith("library") and
        (stripped.len == len("library") or
         stripped[len("library")] in {' ', '\t'}):
      verb = "library"
      kind = fsmkLibrary
    elif stripped.startsWith("files") and
        (stripped.len == len("files") or
         stripped[len("files")] in {' ', '\t'}):
      verb = "files"
      kind = fsmkFiles
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
      result.add(FromSourceMakeMember(name: name, kind: kind))

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

proc hasInTreeBuildArtifact(projectRoot: string): bool =
  ## True when the project root carries an in-tree build-system
  ## manifest. The from-source variant intentionally yields when any
  ## of these are present at the root so the in-tree sibling
  ## convention claims the project. The check is OR'd over the four
  ## supported in-tree manifests because the convention sits at the
  ## bottom of the C/C++ recognition cascade and the existing
  ## conventions each take precedence on their own manifest.
  for name in ["Makefile.am", "configure.ac", "configure.in",
               "meson.build", "CMakeLists.txt"]:
    if fileExists(extendedPath(projectRoot / name)):
      return true
  false

# ---------------------------------------------------------------------------
# Path layout
# ---------------------------------------------------------------------------

proc stampDir(projectRoot: string): string =
  ## Per-action stamp directory (kept for the M9.R.6.1 sentinel).
  projectRoot / ScratchDirName / FromSourceMakeSubdir / "stamps"

proc sanitizeNamePart(value: string): string =
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "x"

# M9.R.6.1: ``stagingDir`` / ``buildStampPath`` / ``installStampPath`` /
# ``artifactOutputDir`` / ``artifactOutputPath`` / ``makeExecutable`` /
# ``stripLibPrefix`` + the legacy 5-stage emit procs were removed
# alongside the legacy ``emitFragment`` body.

# ---------------------------------------------------------------------------
# Action emission
# ---------------------------------------------------------------------------

proc sentinelStampPath(projectRoot: string): string =
  stampDir(projectRoot) / "from-source-make-sentinel.stamp"

proc emitSynthesisSentinelAction(projectRoot, dslPackageName: string;
                                 fetchActionId, fetchStamp: string;
                                 identity: CacheEntryIdentity):
                                   BuildActionDef =
  ## M9.R.6.1 narrowed synthesis sentinel — see
  ## ``from_source_meson.emitSynthesisSentinelAction`` for rationale.
  createDir(extendedPath(parentDir(sentinelStampPath(projectRoot))))
  let stamp = sentinelStampPath(projectRoot)
  let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
  let escapedStampDir = parentDir(stamp).replace("\\", "/").
    replace("\"", "\\\"")
  let script = "set -e; mkdir -p \"" & escapedStampDir &
    "\"; printf 'from-source-make sentinel for %s\\n' \"" &
    dslPackageName & "\" > \"" & escapedStamp & "\""
  let argv = @["sh", "-c", script]
  buildAction(
    id = "from-source-make-sentinel",
    call = inlineExecCall(argv, projectRoot),
    deps = @[fetchActionId],
    inputs = @[fetchStamp],
    outputs = @[stamp],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "from-source-make.sentinel",
    publishToBinaryCache = true,
    cacheEntryIdentity = some(identity),
    toolIdentityRefs = @["sh"])

# M9.R.6.1: ``emitBuildAction`` / ``emitInstallAction`` /
# ``kernelInSourcePath`` / ``stagingCandidatePaths`` /
# ``emitStageCopyAction`` were all removed (along with the 5-stage
# emitFragment body). The recipe's explicit ``build:`` body owns
# build/install/stage-copy via ``autotools_package(...)`` or, for
# raw-Makefile recipes, an explicit ``shell()`` chain.

# ---------------------------------------------------------------------------
# Convention entry
# ---------------------------------------------------------------------------

proc fromSourceMakeRecognize(projectRoot: string;
                             request: ProviderGraphRequest):
                               bool {.gcsafe.} =
  ## Recognition contract — see module docstring.
  ##
  ## M9.N: claims a recipe based on DECLARATION (``fetch:`` registered +
  ## non-empty make flags channel + empty configure/meson/cmake channels
  ## + no in-tree build manifest at projectRoot). NO host-PATH gate —
  ## the engine resolves tool identity AFTER recognise, possibly via
  ## cache substitute or source build.
  ##
  ## TODO(M9.N Batch B): resolve tool identity through engine instead of
  ## findExe at emit time.
  if hasInTreeBuildArtifact(projectRoot):
    # In-tree build-system manifest at projectRoot — defer to the
    # existing in-tree convention.
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
    # M9.R.6.1: the flag-channel discriminators are gone — recognise via
    # ``registeredNativeBuildDeps`` for the ``make`` token while
    # rejecting recipes that also declare meson / cmake / autotools
    # (those siblings sit ABOVE this convention in the registration
    # order so they claim first; this check is defensive).
    var sawMake = false
    var sawHigherPriorityDriver = false
    for raw in registeredNativeBuildDeps(dslPackageName):
      let stripped = raw.strip()
      var head = ""
      for ch in stripped:
        if ch in {' ', '\t', '>', '<', '=', '!', ',', ';'}:
          break
        head.add(ch)
      if head == "make":
        sawMake = true
      elif head in ["meson", "cmake", "autoconf", "automake", "libtool"]:
        sawHigherPriorityDriver = true
    if not sawMake or sawHigherPriorityDriver:
      return false
  if extractMembers(source).len == 0:
    return false
  true

proc syntheticPackage(projectRoot: string;
                      members: seq[FromSourceMakeMember]): PackageDef =
  var name = "from_source_make_convention"
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

proc fromSourceMakeEmitFragment(projectRoot: string;
                                request: ProviderGraphRequest):
                                  GraphFragment {.gcsafe.} =
  ## Lower the recipe into a fetch + build + install + per-member
  ## stage-copy action graph. See module docstring's pipeline section.
  {.cast(gcsafe).}:
    let source = readReprobuildSource(projectRoot)
    let members = extractMembers(source)
    if members.len == 0:
      let projectMatch = resolveProjectFile(projectRoot)
      let projectFile =
        if projectMatch.path.len > 0: projectMatch.path
        else: projectRoot / LegacyProjectFileName
      raise newException(ValueError,
        "from-source-make convention: no executable / library / files " &
          "members declared in " & projectFile)
    let dslPackageName = extractFirstPackageName(source)
    if dslPackageName.len == 0:
      raise newException(ValueError,
        "from-source-make convention: no 'package <name>:' block in " &
          projectRoot)
    let spec = registeredFetchSpec(dslPackageName)
    if spec.url.len == 0 or spec.hashHex.len == 0:
      raise newException(ValueError,
        "from-source-make convention: no fetch: spec registered for " &
          "package '" & dslPackageName & "' — recognise() should have " &
          "rejected this project")
    let pkg = syntheticPackage(projectRoot, members)
    # M9.R.6.1: narrowed to fetch + sentinel. The build / install /
    # stage-copy actions live in the recipe's explicit ``build:`` block.
    let identity = computeCacheEntryIdentity(projectRoot,
      dslPackageName, "make")
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      discard buildPool("fetch", 2'u32)
      var allActions: seq[BuildActionDef] = @[]
      let fetchAct = emitFetchAction(projectRoot, dslPackageName, spec)
      allActions.add(fetchAct)
      let fetchStamp = fetchStampPath(projectRoot, spec.hashHex)
      let sentinelAct = emitSynthesisSentinelAction(projectRoot,
        dslPackageName, fetchAct.id, fetchStamp, identity)
      allActions.add(sentinelAct)
      defaultTarget(target("default", allActions))
    result = buildPackageFragment(pkg, request, registerAll,
      includeDefault = false)

proc fromSourceMakeConvention*(): LanguageConvention =
  ## The single value the standard provider binary registers at startup.
  ##
  ## Registered BEFORE the existing ``c-cpp-make`` sibling so the
  ## from-source variant claims recipes that declare a ``fetch:``
  ## block + a non-empty ``makeFlags:`` channel (no in-tree
  ## ``Makefile.am`` / ``configure.ac`` / ``meson.build`` /
  ## ``CMakeLists.txt`` at projectRoot — the source has to be
  ## fetched + extracted first). The convention's ``recognize``
  ## rejects when those in-tree manifests ARE present at the root so
  ## the in-tree M17 convention claims those projects; registration
  ## order is defensive in either direction.
  LanguageConvention(
    name: "from-source-make",
    recognize: fromSourceMakeRecognize,
    emitFragment: fromSourceMakeEmitFragment)
