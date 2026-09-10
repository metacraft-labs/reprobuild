## §5 — the runtime-wrapper / RPATH / env-default contract — encoded
## ONCE, here, and applied by staging rather than by any producer.
##
## Distribution-And-Packaging.md §5 is titled "the hard constraint" and
## says why: the Nix build wraps every installed binary with
## ``--set-default`` for ~18 environment variables and sets a DT_RPATH
## to the runtime library closure, and **every non-Nix package must
## reproduce this, or the binary won't run off-Nix**. §5 closes with the
## design rule this module exists to satisfy: "This contract is encoded
## **once** in the DSL packaging layer (§6) and reused by every format
## producer, so it is not re-hand-written per package."
##
## ## How "once" is enforced structurally, not by convention
##
## A comment saying "producers must apply the wrapper contract" would be
## a convention, and the first producer a third party writes would break
## it. Instead **no producer can see the contract at all**: a producer's
## input is a ``StagedTree``, which is a list of files that already
## exist as build-edge outputs. By the time any producer runs, the
## RPATH is patched, the wrappers are written and the modes are set.
## A producer that wanted to skip the contract would have to re-stage
## the tree from the ``Distribution`` itself — i.e. reimplement this
## module — rather than merely forget a step.
##
## That is also why ``stageInstallTree`` is not a producer parameter but
## a call every producer makes on its own dedicated tree root: the deb
## producer needs a ``DEBIAN/`` directory inside its tree that must not
## appear in the tarball, so the trees cannot be shared — but the code
## that fills them is one proc with one code path.
##
## ## Every staging edge is pure
##
## No edge in this module rewrites a file another edge produced. The
## pipeline for one executable is
##
##   patchelf --output <gen>/<n>.patched   <- the built binary
##   install  -m 0755 -D                   <- <gen>/<n>.patched
##   writeText <gen>/<n>.wrapper
##   install  -m 0755 -D                   <- <gen>/<n>.wrapper
##
## — four edges, four distinct outputs, none of them in-place. That is
## what makes the whole install tree, and therefore every artifact
## produced from it, a content-addressed function of the inputs: a
## rebuild is a cache hit rather than a re-run that happens to produce
## the same bytes.

import std/[strutils]

import repro_project_dsl
import ../fs as dslfs
import ../configurables/variants

import ./types

import ../packages/patchelf as patchelf_module
import ../packages/coreutils_install as install_module

{.experimental: "callOperator".}

const
  patchelfTool = patchelf_module.patchelf
  installTool = install_module.install_file

const
  PatchelfSelector* = "patchelf"
  InstallSelector* = "install-file"

type
  StagedFile* = object
    ## One file that exists in the staged install tree because some
    ## build edge produced it.
    rootRelPath*: string
      ## Path relative to the tree root, ``/``-separated. For a deb or
      ## an rpm the tree root IS the target filesystem root, so this is
      ## the absolute install path minus its leading slash. For a
      ## tarball or an MSI the tree root is the prefix.
    edge*: BuildActionDef
      ## The edge whose output this file is.
    role*: ComponentRole
    isPublicEntryPoint*: bool
      ## True for the wrapper (or, when unwrapped, the binary) a user
      ## actually invokes. Producers that must name entry points — the
      ## MSI's ``ServiceInstall``, a future ``.desktop`` emitter — read
      ## this rather than re-deriving "which of these is the real one".

  StagedTree* = object
    ## What a producer consumes. Deliberately carries no
    ## ``RuntimeContract``: see the header note on enforcing "once"
    ## structurally.
    dist*: Distribution
    root*: string
      ## Build-tree directory the files below are rooted at.
    genRoot*: string
      ## Scratch directory holding the generated intermediates
      ## (patched binaries, wrapper text) that are then ``install``ed
      ## into ``root``. Kept OUTSIDE ``root`` so a producer that
      ## archives the whole tree never picks them up.
    idPrefix*: string
      ## Action-id namespace for every edge in this tree.
      ##
      ## Carries the VARIANT, because two producers over one
      ## ``Distribution`` stage two trees whose per-file edges would
      ## otherwise be handed the same id: the deb tree's
      ## ``pkg-rpath-bin-hello`` and the tarball tree's are different
      ## edges with different outputs. That is not a cosmetic clash —
      ## the engine keys the ACTION CACHE by id, so a collision serves
      ## one edge's outputs for the other, and the wrong tree gets
      ## packaged. Found by ``t_packaging_content_addressed.nim``'s
      ## id-uniqueness case, which is there for exactly this.
    files*: seq[StagedFile]
    terminal*: seq[BuildActionDef]
      ## Every edge a producer must be ordered after. A producer passes
      ## this as ``after =`` and the staged paths as ``extraInputs``,
      ## which is what makes the artifact edge depend on the tree's
      ## contents rather than merely on its directory name.

  ToolDependencySite* = object
    ## Where the recipe's ``package`` declaration is, so a producer can
    ## register its tool as a native build dependency OF THAT PACKAGE.
    ##
    ## Distribution-And-Packaging.md §6 rule 2: "a project that depends
    ## on a producer transitively depends on the underlying tool". In
    ## reprobuild that dependency has two halves and a producer declares
    ## both — see ``declareProducerTool``.
    packageName*: string
    sourceFile*: string
    sourceLine*: int

proc noSite*(): ToolDependencySite =
  ToolDependencySite(packageName: "", sourceFile: "", sourceLine: 0)

proc declareProducerTool*(site: ToolDependencySite; edgeId, selector: string) =
  ## Make ``selector`` a real build-graph dependency of the recipe that
  ## called a producer. §6 rule 2 is the whole point of the exercise —
  ## "dependency-on-a-recipe ⇒ dependency-on-its-tools" — and it has two
  ## halves in reprobuild, both of which a producer must declare and
  ## neither of which the recipe author writes by hand:
  ##
  ## 1. **Package level** — ``registerPackageNativeTool`` appends the
  ##    tool to the calling package's ``nativeBuildDeps``, the list
  ##    ``PackageDef.allToolUses()`` folds into
  ##    ``ProjectInterface.toolUses``. This is the same mechanism
  ##    ``fetch:`` uses for curl/tar/git (``source_fetch_tools.nim``)
  ##    and ``installMirror`` uses for its helpers
  ##    (``install_mirror_tools.nim``) — the packaging layer is a third
  ##    instance of an established surface, not a new one.
  ##
  ##    ONE CAVEAT, and it is why a recipe still writes ``uses:``
  ##    literals for the formats it builds. Those two precedents are
  ##    called from MACRO-EMITTED code, at package-registration time.
  ##    A producer is called from inside a ``build:`` body, which runs
  ##    after the project interface has already been extracted — so this
  ##    registration reaches ``registeredNativeBuildDeps`` and the
  ##    lowered graph, but it is NOT what provisions the tool for the
  ##    build that is running. The ``uses:`` literal is; and the layer
  ##    exports each producer's selector as a public constant
  ##    (``DpkgDebSelector``, ``CandleSelector``, …) with a test pinning
  ##    the fixture's literals against them, so the recipe author is
  ##    transcribing a name rather than guessing one.
  ## 2. **Edge level** — ``appendRegisteredActionToolIdentityRefs``
  ##    names the tool on the specific action, which is what the
  ##    engine's fork-time resolver walks to put the tool's bin
  ##    directory on that action's ``PATH``. A ``uses:`` entry alone is
  ##    necessary but not sufficient; ``repro.nim``'s own ``uses:``
  ##    block says so in as many words.
  ##
  ## The engine learns nothing from this: it resolves a named tool
  ## dependency exactly as it does for ``nim`` or ``gcc``, and an
  ## unavailable tool surfaces as an unresolvable dependency, which is
  ## what §6.1 names as the ONLY acceptable mechanism for "this format
  ## is not available here".
  if selector.len == 0:
    return
  # The edge-level half is the load-bearing one and is unconditional.
  if edgeId.len > 0:
    appendRegisteredActionToolIdentityRefs(edgeId, @[selector])
  if site.packageName.len == 0:
    return

  # The package-level half. ``registerPackageNativeTool`` matches on the
  # (name, sourceFile, sourceLine) TRIPLE, because one recipe module can
  # be instantiated several times in a single process — the per-consumer
  # sibling shims give each consumer its own module instance — and a
  # registration against the wrong instance would silently attach the
  # dependency to a different consumer's graph.
  #
  # A producer is called from inside a ``build:`` body and has no way to
  # know the triple, so the site is resolved BY NAME out of the package
  # registry and every declaration carrying that name is registered.
  # Resolving to only the first would be wrong in exactly the
  # multi-instantiation case the triple exists to distinguish.
  var sites: seq[(string, int)] = @[]
  if site.sourceFile.len > 0:
    sites.add((site.sourceFile, site.sourceLine))
  else:
    for pkg in registeredPackages():
      if pkg.packageName == site.packageName:
        sites.add((pkg.sourceFile, pkg.sourceLine))
  if sites.len == 0:
    # Nothing to attach to. This is the ordinary case when a producer is
    # exercised outside a ``package`` declaration — a unit test, or a
    # helper script — and it is not an error: the edge already names its
    # tool, which is what puts the tool on that action's PATH. Raising
    # here would make the layer unusable from a test for no gain.
    return
  for (file, line) in sites:
    if registerPackageNativeTool(site.packageName, file, line,
        PackageUseDef(
          rawConstraint: selector,
          packageSelector: selector,
          executableName: selector,
          depKind: DepKindNative)):
      registerPackageDep(site.packageName, DepKindNative, selector)
      registerSolverDependency(site.packageName, selector, selector,
        depKind = DepKindNative)

# ---------------------------------------------------------------------------
# Path arithmetic over the TARGET tree.
#
# All of it is ``/``-separated and none of it consults the host, for the
# same reason ``extractFilenameSlashOnly`` does not: the tree being
# described may be Windows-shaped while the build runs on Linux, and a
# host-conditional path would make the staged tree depend on which
# machine staged it.
# ---------------------------------------------------------------------------

proc dirOf(path: string): string =
  let cut = path.rfind('/')
  if cut < 0: "" else: path[0 ..< cut]

proc relativeTargetDir*(fromDir, toDir: string): string =
  ## ``bin`` → ``lib`` is ``../lib``; ``bin`` → ``bin`` is ``.``.
  ##
  ## Written out rather than delegated to ``os.relativePath`` because
  ## that one is host-separator-aware and would emit ``..\lib`` on a
  ## Windows builder — which, spliced into a DT_RPATH, is not merely
  ## ugly but wrong.
  var a: seq[string] = @[]
  var b: seq[string] = @[]
  for part in fromDir.split('/'):
    if part.len > 0 and part != ".": a.add(part)
  for part in toDir.split('/'):
    if part.len > 0 and part != ".": b.add(part)
  var common = 0
  while common < a.len and common < b.len and a[common] == b[common]:
    inc common
  var parts: seq[string] = @[]
  for _ in common ..< a.len: parts.add("..")
  for i in common ..< b.len: parts.add(b[i])
  if parts.len == 0: "." else: parts.join("/")

proc rpathFor*(dist: Distribution; fromPrefixRelDir: string): string =
  ## The ``$ORIGIN``-relative DT_RPATH an ELF at ``fromPrefixRelDir``
  ## needs in order for the vendored runtime libraries to be found.
  ##
  ## ``$ORIGIN``-relative and not absolute, deliberately. An absolute
  ## RPATH would bake the install prefix into the binary, so the very
  ## same staged tree could not also be shipped as the "relocatable,
  ## wrapper-baked" tarball §6 asks for, and a user who installed the
  ## deb to a non-default root would get a binary that silently loads
  ## the wrong libraries or none.
  let libDir = roleDefaultSubdir(dist, crRuntimeLibrary)
  let rel = relativeTargetDir(fromPrefixRelDir, libDir)
  if rel == ".": "$ORIGIN" else: "$ORIGIN/" & rel

# ---------------------------------------------------------------------------
# The wrapper.
# ---------------------------------------------------------------------------

const
  PrefixToken* = "@PREFIX@"
    ## Placeholder a recipe may use inside ``RuntimeContract.envDefaults``
    ## values. It expands, AT RUN TIME inside the wrapper, to the
    ## directory the package was actually installed into.
    ##
    ## Expanding at run time rather than at generation time is what lets
    ## one staged tree serve both a fixed-prefix format (deb, rpm, MSI)
    ## and the relocatable tarball. Baking the prefix in at generation
    ## time would have made the tarball's own contract — "relocatable,
    ## wrapper-baked" (§6) — unsatisfiable without a second staging
    ## path, and a second staging path is exactly what §5's "encoded
    ## once" forbids.

proc posixSingleQuote(value: string): string =
  ## Wrap a value so a POSIX shell reproduces it byte for byte.
  result = "'"
  for ch in value:
    if ch == '\'': result.add("'\\''")
    else: result.add(ch)
  result.add("'")

proc posixWrapperText*(dist: Distribution; realName: string;
                       binPrefixRelDir: string): string =
  ## The ``sh`` wrapper that reproduces the flake's ``wrapProgram
  ## --set-default`` behaviour.
  ##
  ## ``--set-default`` and not ``--set``: the flake's own comment on the
  ## wrapper says it "preserves explicit development/source overrides
  ## while making an ordinary installed package independent of sibling
  ## checkouts and the build-time dev shell". ``: "${NAME:=value}"`` is
  ## the POSIX spelling of exactly that — assign only if unset or empty.
  ##
  ## The wrapper deliberately does NOT export ``LD_LIBRARY_PATH`` or
  ## ``DYLD_*``. flake.nix has a standing comment on why, and it applies
  ## with more force to a system package: arbitrary user build actions
  ## inherit the wrapper's environment, so a loader variable set here
  ## would leak into every process the tool ever spawns. The library
  ## search path is carried by the DT_RPATH on the binary instead, which
  ## affects that binary and nothing else.
  let toPrefix = relativeTargetDir(binPrefixRelDir, "")
  result = "#!/bin/sh\n"
  result.add("# Generated by the reprobuild DSL packaging layer.\n")
  result.add("# Reproduces the flake's wrapProgram --set-default contract\n")
  result.add("# (Distribution-And-Packaging.md " & "§" & "5). Do not edit.\n")
  result.add("set -e\n")
  # Resolve this script's own directory without relying on $0 being a
  # path: an invocation found through PATH gives a bare name.
  result.add("__repro_self=$0\n")
  result.add("case $__repro_self in\n")
  result.add("  */*) __repro_bin=${__repro_self%/*} ;;\n")
  result.add("  *) __repro_bin=$(command -v -- \"$__repro_self\" 2>/dev/null)" &
    " && __repro_bin=${__repro_bin%/*} || __repro_bin=. ;;\n")
  result.add("esac\n")
  result.add("__repro_bin=$(cd -- \"$__repro_bin\" && pwd)\n")
  if toPrefix == ".":
    result.add("__repro_prefix=$__repro_bin\n")
  else:
    result.add("__repro_prefix=$(cd -- \"$__repro_bin/" & toPrefix &
      "\" && pwd)\n")
  for (name, rawValue) in dist.runtime.envDefaults:
    # The value is built by shell concatenation so the run-time prefix
    # can participate; the literal halves stay single-quoted so nothing
    # else in them is ever re-expanded.
    var expr = ""
    var rest = rawValue
    while true:
      let idx = rest.find(PrefixToken)
      if idx < 0:
        if rest.len > 0: expr.add(posixSingleQuote(rest))
        break
      if idx > 0: expr.add(posixSingleQuote(rest[0 ..< idx]))
      expr.add("\"$__repro_prefix\"")
      rest = rest[idx + PrefixToken.len .. rest.high]
    if expr.len == 0: expr = "''"
    # Written as an explicit test rather than as ``${NAME:=value}``.
    # The parameter-expansion form has to nest double quotes inside a
    # ``${...}`` that is itself inside double quotes, which POSIX
    # permits but which shells disagree about in practice — and a
    # wrapper that works on dash and not on ksh is a packaging bug that
    # only shows up on one distro. The long form has one reading
    # everywhere.
    #
    # ``-z "${NAME:-}"`` and not ``-z "$NAME"``: this runs under
    # ``set -e`` and the caller may have ``set -u``. Testing for EMPTY
    # as well as unset is what makes it ``--set-default`` rather than
    # ``--set-if-undefined``; an exported-but-empty variable is not an
    # override anyone meant.
    result.add("if [ -z \"${" & name & ":-}\" ]; then\n")
    result.add("  " & name & "=" & expr & "\n")
    result.add("fi\n")
    result.add("export " & name & "\n")
  result.add("exec \"$__repro_bin/" & realName & "\" \"$@\"\n")

proc windowsWrapperText*(dist: Distribution; realName: string;
                         binPrefixRelDir: string): string =
  ## The ``cmd`` wrapper. Same contract, different mechanism, and the
  ## differences are the point of pairing MSI with deb in the M0 gate:
  ##
  ## * ``if not defined NAME set "NAME=…"`` is the ``--set-default``
  ##   semantics — an already-set variable wins.
  ## * There is no RPATH. The vendored libraries are placed next to the
  ##   executables instead (``roleDefaultSubdir`` returns the bin dir
  ##   for ``crRuntimeLibrary`` on ``toWindows``), because the Windows
  ##   loader searches the directory of the running image. §5 names this
  ##   as the Windows arm of the same requirement.
  ## * ``setlocal`` scopes the assignments to this script, but a process
  ##   started inside that scope still inherits them — which is exactly
  ##   the wrapper's job and no more.
  discard binPrefixRelDir
  result = "@echo off\r\n"
  result.add("rem Generated by the reprobuild DSL packaging layer.\r\n")
  result.add("rem Reproduces the flake's wrapProgram --set-default " &
    "contract. Do not edit.\r\n")
  result.add("setlocal EnableExtensions\r\n")
  # ``%~fI`` over a ``for`` variable is the only way cmd.exe normalises
  # a path. A bare ``%~dp0..`` would leave the literal ``\..`` in every
  # derived value, so the variable would read
  # ``C:\Program Files\X\bin\..`` in the environment of every child
  # process — it works, and it looks broken to anyone who inspects it.
  result.add("for %%I in (\"%~dp0..\") do set " &
    "\"REPRO_PACKAGE_PREFIX=%%~fI\"\r\n")
  for (name, rawValue) in dist.runtime.envDefaults:
    var value = rawValue
    if value.contains(PrefixToken):
      # A value containing the prefix token is by construction a path,
      # and the recipe wrote it once for every target. Turning its
      # separators into Windows ones here is the layer honouring the
      # single-definition promise. Values with NO token are left exactly
      # as authored, because nothing says they are paths.
      value = value.replace(PrefixToken, "%REPRO_PACKAGE_PREFIX%")
      value = value.replace("/", "\\")
    result.add("if not defined " & name & " set \"" & name & "=" & value &
      "\"\r\n")
  result.add("\"%~dp0" & realName & "\" %*\r\n")
  result.add("exit /b %ERRORLEVEL%\r\n")

proc wrapperFileName*(dist: Distribution; publicName: string): string =
  ## What the user-invoked file is called.
  ##
  ## On Windows the ``.exe`` is REPLACED, not suffixed: a wrapper named
  ## ``repro.exe.cmd`` is not reachable by typing ``repro``, which
  ## defeats the entire purpose of having one. ``repro.cmd`` is, via
  ## ``PATHEXT``.
  if dist.targetOs != toWindows:
    publicName
  elif publicName.toLowerAscii.endsWith(".exe"):
    publicName[0 ..< publicName.len - 4] & ".cmd"
  else:
    publicName & ".cmd"

proc realFileName*(dist: Distribution; publicName: string): string =
  ## What the actual binary is called once a wrapper has taken its name.
  if dist.targetOs == toWindows:
    if publicName.toLowerAscii.endsWith(".exe"):
      publicName[0 ..< publicName.len - 4] & "-real.exe"
    else:
      publicName & "-real.exe"
  else:
    publicName & ".real"

# ---------------------------------------------------------------------------
# Staging.
# ---------------------------------------------------------------------------

proc sanitizeIdPart(value: string): string =
  for ch in value:
    if ch.isAlphaNumeric or ch == '-' or ch == '_': result.add(ch)
    elif ch == '/' or ch == '.': result.add('-')
    else: result.add('_')

proc stageInstallTree*(dist: Distribution; variant: string;
                       site = noSite()): StagedTree =
  ## Build the edges that materialise ``dist``'s install tree, with the
  ## §5 contract applied, under ``<stagingRoot>/<variant>``.
  ##
  ## ``variant`` exists because the formats disagree about what may be
  ## inside the tree: ``dpkg-deb --build`` requires a ``DEBIAN/``
  ## directory that must not appear in the tarball, and the MSI's tree
  ## is rooted at the prefix rather than at ``/``. One tree per producer
  ## keeps each format's requirements from contaminating the others
  ## while leaving the code that fills them a single proc.
  dist.validate()
  let posix = dist.targetOs != toWindows
  let treeRoot = dist.stagingRoot & "/" & variant
  let genRoot = dist.stagingRoot & "/gen-" & variant
  result = StagedTree(dist: dist, root: treeRoot, genRoot: genRoot,
    idPrefix: "pkg-" & sanitizeIdPart(variant) & "-")

  # For a deb/rpm the payload is rooted at ``/`` and the prefix is a
  # directory inside the tree; for a tarball or an MSI the tree root IS
  # the prefix. ``rootedAtPrefix`` is the switch, and it is the ONLY
  # format-shaped decision staging makes — everything else below is
  # identical for all three.
  let rootedAtPrefix = variant in ["tar", "msi"]

  proc rootRelFor(prefixRel: string; role: ComponentRole): string =
    ## Where a component sits relative to the TREE ROOT.
    ##
    ## Two rules, and the second only exists because the first has an
    ## exception. Normally a component's location is relative to the
    ## prefix, and a payload rooted at ``/`` puts the prefix inside it.
    ## But some locations belong to the SYSTEM rather than to the
    ## package — POSIX config at ``/etc`` — and those must not move with
    ## the prefix. See ``types.escapesPrefix``.
    ##
    ## A tree that is ITSELF rooted at the prefix has nowhere to put
    ## such a file, and that is not a gap: a relocatable tarball and an
    ## MSI installed under ``Program Files`` genuinely cannot own
    ## ``/etc``, so their config ships under the prefix and whatever
    ## installs them is responsible for placing it. Silently writing
    ## outside the tree would be worse than either.
    if rootedAtPrefix or not escapesPrefix(dist, role):
      if rootedAtPrefix: prefixRel else: prefixRelToRoot(dist, prefixRel)
    else:
      prefixRel

  proc treePath(prefixRel: string; role: ComponentRole): string =
    treeRoot & "/" & rootRelFor(prefixRel, role)

  let idPrefix = "pkg-" & sanitizeIdPart(variant) & "-"

  proc emitInstall(source, target: string; mode: int;
                   after: openArray[BuildActionDef];
                   idHint: string): BuildActionDef =
    ## Put one file in the tree with the mode the DISTRIBUTION says it
    ## has. On Windows there are no modes, so the engine's own
    ## ``fs.copyFile`` builtin does the job with no tool dependency at
    ## all — the layer does not invent a Windows mode concept just to
    ## keep the two paths looking alike.
    if posix:
      let edge = installTool(
        mode = "0" & mode.toOct(3),
        createParents = true,
        preserveTimestamps = true,
        source = source,
        target = target,
        actionId = idPrefix & "install-" & sanitizeIdPart(idHint),
        after = after)
      declareProducerTool(site, edge.id, InstallSelector)
      edge
    else:
      dslfs.copyFile(source, target,
        actionId = idPrefix & "copy-" & sanitizeIdPart(idHint),
        after = after)

  for component in dist.components:
    let publicName = defaultInstallName(component)
    let prefixRel = installRelPath(dist, component)
    let prefixRelDir = dirOf(prefixRel)
    let mode = if component.mode != 0: component.mode
               else: roleDefaultMode(component.role)
    let wrapThis =
      dist.runtime.wrapExecutables and component.role == crExecutable

    # ---- 1. the binary itself, RPATH-patched on Linux --------------
    var payloadSource = component.buildPath
    var payloadAfter: seq[BuildActionDef] = component.producedBy
    let needsRpath =
      dist.targetOs == toLinux and
      component.role in {crExecutable, crHelperExecutable, crRuntimeLibrary}
    if needsRpath:
      # The generated intermediate's FILE NAME carries the variant too,
      # not just its directory. Named-Targets derives an implicit target
      # name from an output's BASENAME, so ``gen-deb/bin-hello.patched``
      # and ``gen-tar/bin-hello.patched`` are two distinct outputs that
      # claim one target name — which the DSL rejects outright. Two
      # producers over one ``Distribution`` is the ordinary case, so the
      # names have to be distinct by construction rather than by luck.
      let patched = genRoot & "/" & sanitizeIdPart(variant) & "-" &
        sanitizeIdPart(prefixRel) & ".patched"
      let edge = patchelfTool(
        setRpath = rpathFor(dist, prefixRelDir),
        forceRpath = true,
        output = patched,
        file = component.buildPath,
        actionId = idPrefix & "rpath-" & sanitizeIdPart(prefixRel),
        after = component.producedBy)
      declareProducerTool(site, edge.id, PatchelfSelector)
      payloadSource = patched
      payloadAfter = @[edge]

    let realPrefixRel =
      if wrapThis:
        (if prefixRelDir.len > 0: prefixRelDir & "/" else: "") &
          realFileName(dist, publicName)
      else:
        prefixRel
    let payloadRootRel = rootRelFor(realPrefixRel, component.role)
    let payloadEdge = emitInstall(payloadSource,
      treePath(realPrefixRel, component.role),
      mode, payloadAfter, payloadRootRel)
    result.files.add(StagedFile(
      rootRelPath: payloadRootRel,
      edge: payloadEdge,
      role: component.role,
      isPublicEntryPoint: not wrapThis and component.role == crExecutable))
    result.terminal.add(payloadEdge)

    # ---- 2. the wrapper -------------------------------------------
    if wrapThis:
      let realName = realFileName(dist, publicName)
      let text =
        if dist.targetOs == toWindows:
          windowsWrapperText(dist, realName, prefixRelDir)
        else:
          posixWrapperText(dist, realName, prefixRelDir)
      let wrapperPublic =
        (if prefixRelDir.len > 0: prefixRelDir & "/" else: "") &
          wrapperFileName(dist, publicName)
      let genPath = genRoot & "/" & sanitizeIdPart(variant) & "-" &
        sanitizeIdPart(wrapperPublic) & ".wrapper"
      let writeEdge = dslfs.writeText(genPath, text,
        actionId = idPrefix & "wrapper-text-" & sanitizeIdPart(wrapperPublic))
      let wrapperRootRel = rootRelFor(wrapperPublic, crExecutable)
      let installEdge = emitInstall(genPath,
        treePath(wrapperPublic, crExecutable),
        0o755, @[writeEdge], wrapperRootRel)
      result.files.add(StagedFile(
        rootRelPath: wrapperRootRel,
        edge: installEdge,
        role: crExecutable,
        isPublicEntryPoint: true))
      result.terminal.add(installEdge)

proc addGeneratedFile*(tree: var StagedTree; rootRelPath, text: string;
                       mode = 0o644; site = noSite()): BuildActionDef
    {.discardable.} =
  ## Put a producer-generated text file into an already-staged tree.
  ##
  ## Producers need this for the parts of a package that ARE the format:
  ## the deb ``control`` and maintainer scripts, the systemd units, the
  ## rpm ``%files`` payload. It goes through the same
  ## write-then-install-with-a-mode pipeline as everything else, so a
  ## ``postinst`` a producer generates is 0755 for the same reason and
  ## by the same code as a §5 wrapper — the modes are not a thing each
  ## producer remembers.
  let genPath = tree.genRoot & "/" & tree.idPrefix &
    sanitizeIdPart(rootRelPath) & ".gen"
  let writeEdge = dslfs.writeText(genPath, text,
    actionId = tree.idPrefix & "gen-text-" & sanitizeIdPart(rootRelPath))
  let target = tree.root & "/" & rootRelPath
  let installEdge =
    if tree.dist.targetOs != toWindows:
      let e = installTool(
        mode = "0" & mode.toOct(3),
        createParents = true,
        preserveTimestamps = true,
        source = genPath,
        target = target,
        actionId = tree.idPrefix & "gen-install-" & sanitizeIdPart(rootRelPath),
        after = @[writeEdge])
      declareProducerTool(site, e.id, InstallSelector)
      e
    else:
      dslfs.copyFile(genPath, target,
        actionId = tree.idPrefix & "gen-copy-" & sanitizeIdPart(rootRelPath),
        after = @[writeEdge])
  tree.files.add(StagedFile(
    rootRelPath: rootRelPath,
    edge: installEdge,
    role: crDataFile,
    isPublicEntryPoint: false))
  tree.terminal.add(installEdge)
  installEdge

proc stagedPaths*(tree: StagedTree): seq[string] =
  ## Every staged file's build-tree path, for a producer to declare as
  ## ``extraInputs``. This is what makes the artifact edge depend on the
  ## tree's CONTENTS rather than on its directory name — without it the
  ## engine would have no reason to re-run ``dpkg-deb`` when a binary
  ## inside the tree changed, and the producer would be content-
  ## addressed over the wrong thing.
  for f in tree.files:
    result.add(tree.root & "/" & f.rootRelPath)

proc publicEntryPoints*(tree: StagedTree): seq[StagedFile] =
  for f in tree.files:
    if f.isPublicEntryPoint: result.add(f)

# ---------------------------------------------------------------------------
# The reprobuild instance of the contract.
# ---------------------------------------------------------------------------

const
  ReprobuildWrapperVariables* = [
    "REPROBUILD_RUNTIME_LIBRARY_PATH",
    "REPROBUILD_SOURCE_ROOT",
    "BLAKE3_PREFIX",
    "NIMCRYPTO_SRC",
    "BEARSSL_SRC",
    "STACKABLE_HOOKS_SRC",
    "CODETRACER_TRACE_FORMAT_NIM_SRC",
    "IO_MON_SRC",
    "SHM_GSET_SRC",
    "SHM_QUEUE_SRC",
    "CODETRACER_PINNED_SRC",
    "REPRO_CT_TEST_RUNNER_SRC",
    "REPRO_TEST_ADAPTERS_SRC",
    "CT_INTERPOSE_SRC",
    "REPROBUILD_USE_SYSTEM_HASH_LIBS",
    "REPROBUILD_NIX_DAEMON_BIN",
    "RUNQUOTA_SRC",
    "SQLITE_PREFIX",
    "XXHASH_PREFIX",
    "CLINGO_PREFIX"
  ]
    ## §12's first open question — "exact ``REPROBUILD_*``/``*_PREFIX``
    ## wrapper-var list to encode in the packaging layer (derive
    ## mechanically from the flake wrapper contract)" — answered, in
    ## declaration order, from ``flake.nix``'s ``postFixup``
    ## ``wrapProgram`` loop.
    ##
    ## It lives here as data rather than being spelled into a producer
    ## because M1 is the milestone that packages reprobuild; M0's job is
    ## to have the list in the layer, under one name, so M1 supplies
    ## values for it instead of rediscovering it. A test asserts this
    ## list against ``flake.nix`` so the two cannot drift.
    ##
    ## NOTE the list is the VARIABLE NAMES only. The VALUES are Nix
    ## store paths in the flake and cannot be: a native package's values
    ## are paths inside its own install prefix, which is what
    ## ``PrefixToken`` exists to express.

  ReprobuildDlopenLeafNames* = ["zstd", "clingo"]
    ## §5: "clingo and zstd … the last two ``dlopen``'d by leaf name".
    ## These are the reason the RPATH is mandatory rather than
    ## redundant.
