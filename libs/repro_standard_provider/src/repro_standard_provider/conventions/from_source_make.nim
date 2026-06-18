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

proc stagingDir(projectRoot: string): string =
  projectRoot / ScratchDirName / FromSourceMakeSubdir / "staging"

proc stampDir(projectRoot: string): string =
  projectRoot / ScratchDirName / FromSourceMakeSubdir / "stamps"

proc buildStampPath(projectRoot: string): string =
  stampDir(projectRoot) / "from-source-make-build.stamp"

proc installStampPath(projectRoot: string): string =
  stampDir(projectRoot) / "from-source-make-install.stamp"

proc artifactOutputDir(projectRoot, member: string): string =
  projectRoot / OutputDirName / member

proc artifactOutputPath(projectRoot, member: string;
                        kind: FromSourceMakeMemberKind): string =
  case kind
  of fsmkExecutable:
    when defined(windows):
      artifactOutputDir(projectRoot, member) / (member & ".exe")
    else:
      artifactOutputDir(projectRoot, member) / member
  of fsmkLibrary:
    artifactOutputDir(projectRoot, member) / ("lib" & member & ".so")
  of fsmkFiles:
    # Files artefacts preserve their member name verbatim in the
    # output tree (no ``.exe`` / ``lib<>.so`` decoration). The kernel
    # recipe's vmlinux / systemMap / kernelRelease all use this
    # shape — the activation layer reads them by member name.
    artifactOutputDir(projectRoot, member) / member

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
# register the convention, exercise it via tests, and lower the
# action graph; the actual build run will fail loudly at execution
# time.
# ---------------------------------------------------------------------------

proc makeExecutable(): string =
  let resolved = findExe("make")
  if resolved.len > 0:
    return resolved
  # Stable placeholder so ``inlineExecCall`` doesn't refuse an empty
  # argv[0]. The action will fail at execution time with a clearer
  # diagnostic than a silent skip.
  "make"

proc stripLibPrefix(name: string): string =
  ## Recipes declare library members under names like ``libCap`` whose
  ## installed file is ``libcap.so`` — i.e. the ``lib`` prefix is
  ## already part of the member name. The stage-copy logic expects to
  ## look at ``<staging>/usr/lib/<installed>``; if the member name
  ## starts with ``lib`` we use it verbatim, otherwise we prefix
  ## ``lib``. Same heuristic as the from-source-autotools sibling.
  if name.startsWith("lib") or name.startsWith("Lib"):
    name
  else:
    "lib" & name

# ---------------------------------------------------------------------------
# Action emission
# ---------------------------------------------------------------------------

proc emitBuildAction(projectRoot, makeExe, srcDir: string;
                     makeFlags: seq[string];
                     fetchDeps: seq[string];
                     fetchStamps: seq[string]):
                       tuple[action: BuildActionDef; stamp: string] =
  ## ``cd <srcDir> && make <makeFlags...>``. The stamp file lets
  ## downstream actions key off build success without relying on
  ## Makefile-touched targets. ``makeFlags`` are appended in declared
  ## order so variable overrides (``ARCH=x86_64`` /
  ## ``KBUILD_BUILD_TIMESTAMP=...`` / ``BUILD_CC=gcc`` / ``-j1``) and
  ## non-variable flags (``-jN`` / ``--debug=v`` / ...) round-trip
  ## verbatim.
  createDir(extendedPath(stampDir(projectRoot)))
  let stamp = buildStampPath(projectRoot)
  let shExe = findExe("sh")
  var argv: seq[string]
  if shExe.len > 0:
    let escapedMake = makeExe.replace("\\", "/").replace("\"", "\\\"")
    let escapedSrc = srcDir.replace("\\", "/").replace("\"", "\\\"")
    let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
    var trailingFlags = ""
    for flag in makeFlags:
      trailingFlags.add(" \"")
      trailingFlags.add(flag.replace("\"", "\\\""))
      trailingFlags.add("\"")
    let script = "set -e; cd \"" & escapedSrc & "\"; \"" & escapedMake &
      "\"" & trailingFlags & "; touch \"" & escapedStamp & "\""
    argv = @[shExe, "-c", script]
  else:
    argv = @[makeExe]
    for flag in makeFlags:
      argv.add(flag)
  var inputs: seq[string] = @[]
  for st in fetchStamps:
    inputs.add(st)
  let action = buildAction(
    id = "from-source-make-build",
    call = inlineExecCall(argv, projectRoot),
    deps = fetchDeps,
    inputs = inputs,
    outputs = @[stamp],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "from-source-make.build")
  (action, stamp)

proc emitInstallAction(projectRoot, makeExe, srcDir, staging,
                       buildStamp: string;
                       makeFlags: seq[string]):
                         tuple[action: BuildActionDef; stamp: string] =
  ## ``cd <srcDir> && make install DESTDIR=<staging> <makeFlags...>``.
  ##
  ## ``DESTDIR`` is the standard escape hatch for non-root installs:
  ## make honours the Makefile's own prefix and writes install paths
  ## prefixed with ``<destdir>``. Binaries land at
  ## ``<staging>/usr/{bin,sbin,lib}/...`` given the recipe's
  ## ``prefix=/usr`` makeFlag (libcap) or wherever the kernel's
  ## install target writes (typically a no-op for the artefacts the
  ## stage-copy step probes for).
  ##
  ## The ``makeFlags`` are re-applied to the install action so any
  ## ``prefix=`` / ``lib=`` overrides the build action saw also apply
  ## to install — libcap's Makefile reads both at install time.
  createDir(extendedPath(staging))
  let stamp = installStampPath(projectRoot)
  let shExe = findExe("sh")
  var argv: seq[string]
  if shExe.len > 0:
    let escapedMake = makeExe.replace("\\", "/").replace("\"", "\\\"")
    let escapedSrc = srcDir.replace("\\", "/").replace("\"", "\\\"")
    let escapedStaging = staging.replace("\\", "/").replace("\"", "\\\"")
    let escapedStamp = stamp.replace("\\", "/").replace("\"", "\\\"")
    var trailingFlags = ""
    for flag in makeFlags:
      trailingFlags.add(" \"")
      trailingFlags.add(flag.replace("\"", "\\\""))
      trailingFlags.add("\"")
    let script = "set -e; cd \"" & escapedSrc & "\"; \"" & escapedMake &
      "\" install DESTDIR=\"" & escapedStaging & "\"" & trailingFlags &
      "; touch \"" & escapedStamp & "\""
    argv = @[shExe, "-c", script]
  else:
    argv = @[makeExe, "install", "DESTDIR=" & staging]
    for flag in makeFlags:
      argv.add(flag)
  let action = buildAction(
    id = "from-source-make-install",
    call = inlineExecCall(argv, projectRoot),
    deps = @["from-source-make-build"],
    inputs = @[buildStamp],
    outputs = @[stamp],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "from-source-make.install")
  (action, stamp)

proc kernelInSourcePath(srcDir, member: string): string =
  ## Probe-order helper #1 — well-known kernel artefact paths inside
  ## the extracted source tree. The kernel's bzImage lives at
  ## ``arch/x86/boot/bzImage`` and vmlinux + System.map at the source
  ## root; ``kernelRelease`` is an alias for the
  ## ``include/config/kernel.release`` text file kbuild emits during
  ## compile.
  case member
  of "bzImage":
    srcDir / "arch" / "x86" / "boot" / "bzImage"
  of "vmlinux":
    srcDir / "vmlinux"
  of "systemMap":
    srcDir / "System.map"
  of "kernelRelease":
    srcDir / "include" / "config" / "kernel.release"
  else:
    ""

proc stagingCandidatePaths(staging, member: string;
                           kind: FromSourceMakeMemberKind): seq[string] =
  ## Probe-order helper #2 — generic staging-dir paths the
  ## ``make install DESTDIR=<staging>`` step might land the artefact
  ## at. libcap's Makefile installs ``capsh`` / ``getcap`` / ``setcap``
  ## under ``<staging>/usr/sbin/`` (the ``sbin`` flavour is the
  ## libcap-specific quirk — vanilla autotools puts binaries under
  ## ``/usr/bin/``). The probe sequence covers both layouts so a
  ## future recipe that installs to ``/usr/bin/`` instead of
  ## ``/usr/sbin/`` doesn't need a new convention.
  case kind
  of fsmkExecutable:
    @[
      staging / "usr" / "sbin" / member,
      staging / "usr" / "bin" / member,
      staging / "sbin" / member,
      staging / "bin" / member,
    ]
  of fsmkLibrary:
    let prefixed = stripLibPrefix(member)
    let lowered = prefixed.toLowerAscii()
    @[
      staging / "usr" / "lib" / (lowered & ".so"),
      staging / "usr" / "lib64" / (lowered & ".so"),
      staging / "lib" / (lowered & ".so"),
      staging / "lib64" / (lowered & ".so"),
    ]
  of fsmkFiles:
    @[
      staging / "usr" / "share" / member,
      staging / "usr" / "lib" / member,
      staging / member,
    ]

proc emitStageCopyAction(projectRoot, srcDir, staging,
                         installStamp: string;
                         member: FromSourceMakeMember): BuildActionDef =
  ## Copy the staged artefact to
  ## ``<projectRoot>/.repro/output/<member>/<member>``. The emitted
  ## shell script probes the in-source kernel path first (for the
  ## kernel-specific artefacts) then walks the staging-dir candidate
  ## list. The first existing path wins; the script hard-fails if
  ## NONE of the probes match (so a regression that breaks every
  ## probe surfaces as a build failure, not a silent missing-output).
  let outDir = artifactOutputDir(projectRoot, member.name)
  createDir(extendedPath(outDir))
  let outPath = artifactOutputPath(projectRoot, member.name, member.kind)
  let shExe = findExe("sh")
  var argv: seq[string]

  # Build the ordered candidate list.
  var candidates: seq[string] = @[]
  let kernelPath = kernelInSourcePath(srcDir, member.name)
  if kernelPath.len > 0:
    candidates.add(kernelPath)
  for c in stagingCandidatePaths(staging, member.name, member.kind):
    candidates.add(c)

  if shExe.len > 0:
    let escapedOut = outPath.replace("\\", "/").replace("\"", "\\\"")
    let escapedOutDir = outDir.replace("\\", "/").replace("\"", "\\\"")
    var script = "set -e; mkdir -p \"" & escapedOutDir & "\"; "
    # Emit one ``if [ -f <c> ]; then cp -f <c> <out>; else ...`` chain
    # so the first existing candidate wins.
    var open = 0
    for c in candidates:
      let escapedC = c.replace("\\", "/").replace("\"", "\\\"")
      script.add("if [ -f \"" & escapedC & "\" ]; then cp -f \"" &
        escapedC & "\" \"" & escapedOut & "\"; else ")
      inc open
    script.add("echo \"from-source-make: no candidate found for member " &
      member.name & "\" >&2; exit 1")
    for _ in 0 ..< open:
      script.add("; fi")
    argv = @[shExe, "-c", script]
  else:
    # Fallback for hosts without ``sh``: just attempt the first
    # candidate via plain ``cp``. The action fails loudly at
    # execution time if the file is missing — the script-based
    # cascade above is the production path.
    argv = @["cp", candidates[0], outPath]

  let kindTag = case member.kind
    of fsmkExecutable: "executable"
    of fsmkLibrary: "library"
    of fsmkFiles: "files"
  buildAction(
    id = "from-source-make-stage-" & sanitizeNamePart(member.name),
    call = inlineExecCall(argv, projectRoot),
    deps = @["from-source-make-install"],
    inputs = @[installStamp],
    outputs = @[outPath],
    pool = "compile",
    dependencyPolicy = automaticMonitorPolicy(),
    commandStatsId = "from-source-make.stage." & kindTag)

# ---------------------------------------------------------------------------
# Convention entry
# ---------------------------------------------------------------------------

proc fromSourceMakeRecognize(projectRoot: string;
                             request: ProviderGraphRequest):
                               bool {.gcsafe.} =
  ## Recognition contract — see module docstring.
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
    # The makeFlags channel is the unambiguous discriminator. The
    # convention sits BELOW the autotools / meson / cmake siblings in
    # the registration order so a recipe that declares BOTH
    # ``makeFlags:`` and ``configureFlags:`` (a custom-configure
    # dialect that ALSO drives make explicitly) routes through the
    # autotools sibling first. We additionally reject when any of
    # the configureFlags / mesonOptions / cmakeFlags channels are
    # populated, even though the registration order makes the check
    # redundant — defensive in case the registration order changes.
    let makeFlags = registeredBuildFlags(dslPackageName, "", "make")
    if makeFlags.len == 0:
      return false
    let configureFlags = registeredBuildFlags(dslPackageName, "", "configure")
    if configureFlags.len > 0:
      return false
    let mesonOptions = registeredBuildFlags(dslPackageName, "", "meson")
    if mesonOptions.len > 0:
      return false
    let cmakeFlags = registeredBuildFlags(dslPackageName, "", "cmake")
    if cmakeFlags.len > 0:
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
    let makeExe = makeExecutable()
    let makeFlags = registeredBuildFlags(dslPackageName, "", "make")
    let srcDir = fetchExtractedRoot(projectRoot, spec)
    let staging = stagingDir(projectRoot)
    let pkg = syntheticPackage(projectRoot, members)
    let registerAll = proc() =
      discard buildPool("compile", 8'u32)
      discard buildPool("fetch", 2'u32)
      var allActions: seq[BuildActionDef] = @[]
      # 1. Fetch
      let fetchAct = emitFetchAction(projectRoot, dslPackageName, spec)
      allActions.add(fetchAct)
      let fetchStamp = fetchStampPath(projectRoot, spec.hashHex)
      # 2. Build (no configure step — raw Makefile / kbuild)
      let buildPair = emitBuildAction(projectRoot, makeExe, srcDir,
        makeFlags, @[fetchAct.id], @[fetchStamp])
      allActions.add(buildPair.action)
      # 3. Install
      let installPair = emitInstallAction(projectRoot, makeExe, srcDir,
        staging, buildPair.stamp, makeFlags)
      allActions.add(installPair.action)
      # 4. Per-artifact stage-copy
      for member in members:
        allActions.add(emitStageCopyAction(projectRoot, srcDir, staging,
          installPair.stamp, member))
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
