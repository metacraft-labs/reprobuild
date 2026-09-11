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

import std/[strutils, algorithm, os]

import repro_project_dsl
import ../fs as dslfs
import ../configurables/variants

import ./types

import ../packages/patchelf as patchelf_module
import ../packages/coreutils_install as install_module
import ../packages/sh as sh_module
# Imported for its REGISTRATION side effect only. ``readelf`` is never
# CALLED from Nim -- the closure walk's generated shell program execs it
# off the PATH the resolver composed for that edge -- so there is no
# typed wrapper to reference and the compiler's unused-import heuristic
# does not apply. Same pattern as ``producers/tarball.nim``'s ``gzip``
# import, and the failure it prevents is the same one: without the
# import the ``package readelf:`` block never runs, the selector
# resolves against the bootstrap-floor name instead, and
# ``repro build`` refuses with "package readelf ... does not declare
# provisioning: nixPackage metadata" -- which is what happened on the
# first real Linux run of this code.
{.push warning[UnusedImport]: off.}
import ../packages/readelf
{.pop.}

{.experimental: "callOperator".}

const
  patchelfTool = patchelf_module.patchelf
  installTool = install_module.install_file

const
  PatchelfSelector* = "patchelf"
  InstallSelector* = "install-file"
  ShSelector* = "sh"
    ## The runtime-closure walk's interpreter.
    ##
    ## The walk cannot be Nim code in this module, and the reason is a
    ## fact about WHEN things exist rather than a preference. A
    ## component's ``DT_NEEDED`` list is a property of a file that no
    ## edge has produced yet at the moment the graph is built -- on a
    ## clean tree the compiler has not run -- so the closure is only
    ## knowable at BUILD time, inside an action. What that action needs
    ## is exactly two things the layer already packages: ``patchelf``'s
    ## ``--print-needed`` / ``--print-rpath`` to read an object, and a
    ## POSIX shell to drive the fixed-point. ``sh`` is a reprobuild
    ## package like every other tool here (§6 rule 1), so this is one
    ## more real build-graph dependency, not a host assumption.
    ##
    ## ``install-file`` is named on the same edge, and not because
    ## anything runs ``install``: the resolver puts the whole
    ## ``bin`` DIRECTORY of the package that provides an executable on
    ## the action's PATH, and ``install`` comes from coreutils -- which
    ## is where ``cp``, ``mkdir``, ``touch``, ``ls``, ``rm``, ``sort``
    ## and ``dirname`` come from too. Naming it is how the walk gets
    ## them; the tar/gzip finding of the first Linux build is the same
    ## lesson, one tool further out.
  ReadelfSelector* = "readelf"
    ## The dependency floor's reader, named on the SAME edge as the
    ## walk.
    ##
    ## Same edge and not one of its own, for the same reason ``gzip``
    ## rides on the ``tar`` edge: the floor is the maximum
    ## ``GLIBC_x.y`` reference over the payload AND the vendored
    ## closure, and the vendored set does not exist until the walk has
    ## finished putting it there. An edge that ran readelf over the
    ## private libdir would have to be ordered after the walk and would
    ## then have to re-derive which files the walk had chosen — which
    ## the walk already knows, in a shell variable, at the moment it
    ## finishes. See ``packages/readelf.nim`` for why patchelf cannot
    ## answer this and ``glibcFloorFunctions`` for the parse.
    ##
    ## Declared only when ``types.computesDependencyFloor`` holds, so a
    ## distribution that switches the floor off does not acquire a tool
    ## dependency it never uses.

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
    stagingSelectors*: seq[string]
      ## The tool packages the STAGING step made the calling project
      ## depend on, in the order it declared them.
      ##
      ## Derived rather than transcribed. Each producer used to repeat
      ## ``@[PatchelfSelector, InstallSelector]`` in its returned
      ## ``toolSelectors``, which meant the Windows producer had to
      ## remember NOT to, and a staging step that grew a tool (the
      ## closure walk's ``sh``) would have had to be copied into every
      ## producer -- the per-producer hand-writing §5 exists to forbid,
      ## in the one place it had quietly survived.
    producerExtraInputs*: seq[string]
      ## Files outside the tree that a producer must nonetheless depend
      ## on. Today this is the runtime-closure MANIFEST: the vendored
      ## libraries are written into the tree by an action rather than
      ## being per-file edge outputs, so there is no staged path for the
      ## producer to name, and without the manifest the artifact edge
      ## would not be re-run when the closure changed.
    sourceTreeRoots*: seq[string]
      ## Root-relative directory of every ``crSourceTree`` component in
      ## this tree.
      ##
      ## Carried separately from ``files`` because two producers need
      ## the DIRECTORY rather than its contents. rpm's ``%files`` owns a
      ## directory and everything under it recursively when it names the
      ## directory, so one entry replaces ~1,000 — and the alternative
      ## is not merely verbose: ``ownedDirectories`` would then emit a
      ## ``%dir`` line for every subdirectory of every shipped source
      ## tree, which is a spec the size of the payload. The tarball and
      ## the deb need neither, and the MSI needs the per-file list it
      ## already gets from ``files``, so this is additive rather than a
      ## replacement.
    glibcFloorPath*: string
      ## Build-tree path of the one-line file holding the C-library
      ## floor this tree needs (``2.38``), or empty when the tree
      ## computes none (``types.computesDependencyFloor``).
      ##
      ## A producer reads this, not the value: the value does not exist
      ## until the closure edge has run. What a producer does with it is
      ## write ``types.GlibcFloorToken`` into its own dependency field
      ## and hand the pair to ``addGeneratedFile``'s ``substitutions``,
      ## which splices the file's contents in at build time. That keeps
      ## the FORMAT knowledge where it belongs — ``libc6 (>= 2.38)`` is
      ## Debian's spelling and ``glibc >= 2.38`` is rpm's, and neither
      ## belongs in the walk that computed the number.

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
  PosixPrefixExpr* = "\"$__repro_prefix\""
    ## How the POSIX wrapper spells "the prefix this package was
    ## installed under" inside a value. Named once so the emitter and
    ## ``wrapperExportedValues`` — the reader that checks the emitter —
    ## cannot drift into two spellings, which is the failure mode that
    ## made M1's docker gate parse zero lines out of a wrapper it was
    ## asserting about.

  WindowsPrefixExpr* = "%REPRO_PACKAGE_PREFIX%"
    ## The ``cmd`` wrapper's spelling of the same thing.

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
      expr.add(PosixPrefixExpr)
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
      value = value.replace(PrefixToken, WindowsPrefixExpr)
      value = value.replace("/", "\\")
    result.add("if not defined " & name & " set \"" & name & "=" & value &
      "\"\r\n")
  result.add("\"%~dp0" & realName & "\" %*\r\n")
  result.add("exit /b %ERRORLEVEL%\r\n")

proc unquotePosixConcat(expr: string; ok: var bool): string =
  ## Turn a ``'a'"$__repro_prefix"'b'`` concatenation back into the
  ## string the shell would build, with the prefix token standing in
  ## for the run-time prefix. ``ok`` is set false for anything this
  ## does not understand, so a caller can refuse rather than guess.
  const
    Quote = '\x27'
    Backslash = '\x5C'
  ok = true
  var i = 0
  while i < expr.len:
    if expr[i] == Quote:
      inc i
      while true:
        if i >= expr.len:
          ok = false
          return
        if expr[i] == Quote:
          # ``posixSingleQuote`` writes an embedded quote as the four
          # characters close-quote, backslash, quote, open-quote. Read
          # that back rather than treating the first of them as the end
          # of the literal.
          if i + 3 < expr.len and expr[i + 1] == Backslash and
              expr[i + 2] == Quote and expr[i + 3] == Quote:
            result.add(Quote)
            i += 4
            continue
          inc i
          break
        result.add(expr[i])
        inc i
    elif expr.continuesWith(PosixPrefixExpr, i):
      result.add(PrefixToken)
      i += PosixPrefixExpr.len
    else:
      ok = false
      return

proc wrapperExportedValues*(dist: Distribution; text: string):
    seq[(string, string)] =
  ## Read the emitted wrapper BACK: the (name, value) pairs the script
  ## actually assigns, parsed out of its own text.
  ##
  ## This exists so an assertion about "what the wrapper names" can be
  ## made against the artifact rather than against the list the artifact
  ## was generated from. Two derivations of one list agree by
  ## construction and can therefore assert nothing about each other,
  ## which is exactly how M1's totality case came to measure nothing.
  ##
  ## It REFUSES rather than returning a short list: a parser that
  ## silently matches fewer lines than the wrapper has variables is the
  ## specific failure that made M1's docker gate print
  ## ``ALL WRAPPER PATHS EXIST`` over an empty loop. The count it
  ## recovers must equal ``envDefaults.len`` or this raises.
  var seen = 0
  for rawLine in text.splitLines():
    if dist.targetOs == toWindows:
      let line = rawLine.strip()
      if not line.startsWith("if not defined "):
        continue
      let cut = line.find(" set \"")
      if cut < 0:
        continue
      var assign = line[cut + " set \"".len .. ^1]
      if assign.endsWith("\""):
        assign = assign[0 ..< assign.len - 1]
      let eq = assign.find('=')
      if eq <= 0:
        continue
      var value = assign[eq + 1 .. ^1]
      if value.startsWith(WindowsPrefixExpr):
        value = PrefixToken & value[WindowsPrefixExpr.len .. ^1].replace("\\", "/")
      result.add((assign[0 ..< eq], value))
      inc seen
    else:
      if not rawLine.startsWith("  ") or rawLine.len < 3:
        continue
      let body = rawLine[2 .. ^1]
      let eq = body.find('=')
      if eq <= 0:
        continue
      let name = body[0 ..< eq]
      var isName = true
      for ch in name:
        if ch notin {'A' .. 'Z', '0' .. '9', '_'}: isName = false
      if not isName:
        continue
      var ok = false
      let value = unquotePosixConcat(body[eq + 1 .. ^1], ok)
      if not ok:
        raise newException(ValueError,
          "distribution '" & dist.name & "': the wrapper line '" &
          rawLine.strip() & "' is not in a form the layer can read back")
      result.add((name, value))
      inc seen
  if seen != dist.runtime.envDefaults.len:
    raise newException(ValueError,
      "distribution '" & dist.name & "': read " & $seen &
      " assignments back out of the generated wrapper but it was " &
      "generated from " & $dist.runtime.envDefaults.len &
      " env defaults; refusing a check that would pass over the " &
      "lines it failed to parse")

proc envDefaultPayloadGaps*(dist: Distribution; wrapperText: string;
                            stagedRootRelPaths: openArray[string];
                            rootedAtPrefix: bool): seq[string] =
  ## Every prefix-relative path the EMITTED wrapper names that nothing
  ## in the STAGED TREE puts there, as human-readable lines.
  ##
  ## The two sides are independent on purpose — see
  ## ``RuntimeContract.requireEnvDefaultPayload``. The staged side is
  ## the file list ``stageInstallTree`` built by enumerating the build
  ## tree on disk; the wrapper side is text.
  ##
  ## The private libdir is the one exemption, and it is not a hole: on
  ## Linux the runtime-closure walk fills it at BUILD time from a set
  ## discovered by reading ``DT_NEEDED``, so there are no per-file
  ## staged paths to match against — and that walk is itself a checked
  ## post-condition (``dlopenLeafNames``) that fails the build when a
  ## name will not resolve into it.
  let closureFills =
    dist.targetOs == toLinux and dist.runtime.vendorRuntimeClosure
  let privateLib = privateLibPrefixRelDir(dist)
  for (name, value) in wrapperExportedValues(dist, wrapperText):
    if not value.startsWith(PrefixToken & "/"):
      continue
    let rel = value[PrefixToken.len + 1 .. ^1]
    if closureFills and privateLib.len > 0 and
        (rel == privateLib or rel.startsWith(privateLib & "/")):
      continue
    let want =
      if rootedAtPrefix: rel else: prefixRelToRoot(dist, rel)
    var covered = false
    for staged in stagedRootRelPaths:
      if staged == want or staged.startsWith(want & "/"):
        covered = true
        break
    if not covered:
      result.add(name & " -> <prefix>/" & rel)

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

const
  ClosureScriptPreamble = """
fail() {
  printf 'runtime-closure: %s\n' "$1" >&2
  exit 1
}

# Membership in a newline-separated list. Written with `case` rather than
# with grep so the walk needs nothing beyond patchelf, coreutils and the
# shell itself.
contains() {
  case "$NL$1$NL" in
    *"$NL$2$NL"*) return 0 ;;
    *) return 1 ;;
  esac
}

search=''
seen=''
vendored=''
pending=''
manifest=''

add_search() {
  if [ -d "$1" ]; then
    if contains "$search" "$1"; then
      :
    elif [ -z "$search" ]; then
      search=$1
    else
      search=$search$NL$1
    fi
  fi
  return 0
}

ORIGIN_BARE='$ORIGIN'
ORIGIN_BRACED='${ORIGIN}'

# Every directory THIS object was linked to look in -- the only place the
# walk can learn where a build-toolchain library actually lives.
scan_rpath() {
  scan_origin=$(dirname -- "$1")
  scan_rp=$(patchelf --print-rpath "$1" 2>/dev/null || printf '')
  if [ -n "$scan_rp" ]; then
    scan_ifs=$IFS
    IFS=':'
    for scan_dir in $scan_rp; do
      case $scan_dir in
        "$ORIGIN_BRACED"*) scan_dir=$scan_origin${scan_dir#"$ORIGIN_BRACED"} ;;
        "$ORIGIN_BARE"*) scan_dir=$scan_origin${scan_dir#"$ORIGIN_BARE"} ;;
      esac
      if [ -n "$scan_dir" ]; then
        add_search "$scan_dir"
      fi
    done
    IFS=$scan_ifs
  fi
  return 0
}

resolve() {
  res_ifs=$IFS
  IFS=$NL
  for res_dir in $search; do
    if [ -e "$res_dir/$1" ]; then
      IFS=$res_ifs
      printf '%s' "$res_dir/$1"
      return 0
    fi
  done
  IFS=$res_ifs
  return 1
}

push() {
  if contains "$seen" "$1"; then
    return 0
  fi
  if contains "$pending" "$1"; then
    return 0
  fi
  if [ -z "$pending" ]; then
    pending=$1
  else
    pending=$pending$NL$1
  fi
  return 0
}

vendor() {
  if contains "$vendored" "$1"; then
    return 0
  fi
  cp -L -- "$2" "$LIBDIR/$1"
  chmod 0755 "$LIBDIR/$1"
  # Step 4 in runtimeClosureScript's doc comment: without this the
  # vendored library keeps the RUNPATH the build toolchain gave it, and
  # glibc then refuses to consult the executable's RPATH on its behalf.
  patchelf --force-rpath --set-rpath '$ORIGIN' "$LIBDIR/$1"
  # patchelf rewrites the file, so its mtime becomes "now". Pinning it
  # keeps the staged tree -- and the archive built from it -- a pure
  # function of its inputs rather than of when the build ran.
  #
  # Pinned to the DISTRIBUTION's SOURCE_DATE_EPOCH rather than to a bare
  # @1, so every member of the produced archive carries the same
  # timestamp. dpkg-deb CLAMPS mtimes to SOURCE_DATE_EPOCH rather than
  # setting them, so a file left at @1 would stay at @1 while every
  # other member landed on the epoch -- deterministic either way, but
  # two answers to a question the layer now has one field for.
  touch -d @"$EPOCH" -- "$LIBDIR/$1"
  if [ -z "$vendored" ]; then
    vendored=$1
  else
    vendored=$vendored$NL$1
  fi
  manifest=$manifest$1$NL
  printf 'runtime-closure: vendored %s <- %s\n' "$1" "$2"
  return 0
}

seed() {
  if [ ! -e "$1" ]; then
    fail "component '$1' does not exist"
  fi
  scan_rpath "$1"
  push "$1"
  return 0
}

require_dlopen() {
  if contains "$vendored" "$1"; then
    return 0
  fi
  dl_path=$(resolve "$1" || printf '')
  if [ -z "$dl_path" ]; then
    fail "dlopen leaf name '$1' is declared by runtime.dlopenLeafNames but no search path contains it; add its directory to runtime.extraLibrarySearchDirs"
  fi
  vendor "$1" "$dl_path"
  push "$dl_path"
  return 0
}

"""
    ## The fixed half of the walk: list primitives, the search-path
    ## accumulator, the resolver and the vendoring step. Kept as one
    ## literal rather than assembled line by line so it reads as the
    ## shell program it is.
  ClosureScriptFixedPoint = """
while [ -n "$pending" ]; do
  cur=${pending%%"$NL"*}
  if [ "$cur" = "$pending" ]; then
    pending=''
  else
    pending=${pending#*"$NL"}
  fi
  if contains "$seen" "$cur"; then
    continue
  fi
  if [ -z "$seen" ]; then
    seen=$cur
  else
    seen=$seen$NL$cur
  fi
  scan_rpath "$cur"
  needed=$(patchelf --print-needed "$cur" 2>/dev/null || printf '')
  if [ -n "$needed" ]; then
    need_ifs=$IFS
    IFS=$NL
    for need in $needed; do
      IFS=$need_ifs
      if [ -n "$need" ]; then
        if is_system "$need"; then
          printf 'runtime-closure: system %s (left to the target)\n' "$need"
        else
          found=$(resolve "$need" || printf '')
          if [ -z "$found" ]; then
            fail "cannot resolve '$need' needed by '$cur'; add its directory to runtime.extraLibrarySearchDirs, or its leaf name to runtime.extraSystemLibraryLeafNames if the TARGET provides it"
          fi
          vendor "$need" "$found"
          push "$found"
        fi
      fi
      IFS=$NL
    done
    IFS=$need_ifs
  fi
done

"""
    ## The transitive ``DT_NEEDED`` fixed point itself.
  ClosureScriptFloorFunctions = """
# ---------------------------------------------------------------------------
# The C-library floor.
#
# Emitted only when the distribution asks for it. What it computes is the
# maximum GLIBC_x.y symbol-version reference across every object this walk
# SHIPS -- which is exactly `$seen`: the seeds are the payload, and the only
# other things pushed onto it are the files that were vendored. A system
# library the walk merely resolved and left to the target is never pushed,
# which is right: the floor is a statement about what the package NEEDS from
# the target's glibc, not about what the builder happened to have.
#
# Why this is here and not a Nim function: `.gnu.version_r` is a property of
# a file no edge has produced at the moment the graph is built -- the same
# reason the walk itself is a script. And why readelf rather than patchelf:
# patchelf edits DT_* dynamic-section entries and has no reader for the
# version-requirements section at all.
# ---------------------------------------------------------------------------

floor_maj=0
floor_min=0
floor_pat=0

# Record one `x`, `x.y` or `x.y.z` if it is greater than what we have.
# Three components because glibc really does use them (GLIBC_2.2.5), even
# though every version that matters in practice has two.
floor_note() {
  fn_a=${1%%.*}
  fn_r=${1#*.}
  if [ "$fn_r" = "$1" ]; then
    fn_b=0
    fn_c=0
  else
    fn_b=${fn_r%%.*}
    fn_r2=${fn_r#*.}
    if [ "$fn_r2" = "$fn_r" ]; then
      fn_c=0
    else
      fn_c=${fn_r2%%.*}
    fi
  fi
  case $fn_a in ''|*[!0-9]*) return 0 ;; esac
  case $fn_b in ''|*[!0-9]*) fn_b=0 ;; esac
  case $fn_c in ''|*[!0-9]*) fn_c=0 ;; esac
  if [ "$fn_a" -gt "$floor_maj" ] ||
     { [ "$fn_a" -eq "$floor_maj" ] && [ "$fn_b" -gt "$floor_min" ]; } ||
     { [ "$fn_a" -eq "$floor_maj" ] && [ "$fn_b" -eq "$floor_min" ] &&
       [ "$fn_c" -gt "$floor_pat" ]; }; then
    floor_maj=$fn_a
    floor_min=$fn_b
    floor_pat=$fn_c
  fi
  return 0
}

# `readelf -V` prints .gnu.version, .gnu.version_d AND .gnu.version_r. Only
# the last two spell a version as `Name: GLIBC_x.y`; the first prints
# `(GLIBC_x.y)` per symbol index, so matching on `Name: GLIBC_` selects the
# requirement entries without needing a section-aware parser. The output is
# walked out of a shell variable rather than through a pipe because a pipe
# would put the loop in a subshell and the running maximum would not survive
# it -- the same reason every other loop in this script sets IFS by hand.
floor_scan() {
  fs_out=$(readelf -V -W -- "$1" 2>/dev/null || printf '')
  if [ -z "$fs_out" ]; then
    return 0
  fi
  fs_ifs=$IFS
  IFS=$NL
  for fs_line in $fs_out; do
    IFS=$fs_ifs
    case $fs_line in
      *"Name: GLIBC_"[0-9]*)
        fs_v=${fs_line#*"Name: GLIBC_"}
        fs_v=${fs_v%% *}
        floor_note "$fs_v"
        ;;
    esac
    IFS=$NL
  done
  IFS=$fs_ifs
  return 0
}

"""
    ## The dependency-floor reader. Included in the generated program
    ## only when ``types.computesDependencyFloor`` holds for the
    ## distribution, so a tree that does not want the floor does not
    ## carry the code for it and its edge does not name ``readelf``.
  ClosureScriptFloorEpilogue = """
floor_ifs=$IFS
IFS=$NL
for floor_obj in $seen; do
  IFS=$floor_ifs
  floor_scan "$floor_obj"
  IFS=$NL
done
IFS=$floor_ifs

if [ "$floor_maj" -eq 0 ] && [ "$floor_min" -eq 0 ] && [ "$floor_pat" -eq 0 ]; then
  fail "no GLIBC_x.y version reference found across the payload and the vendored closure; this package cannot state the C-library floor its rewritten PT_INTERP binds it to. If the target is deliberately not glibc, set runtime.computeDependencyFloor = false and supply metadata.debDepends / metadata.rpmRequires by hand"
fi
if [ "$floor_pat" -gt 0 ]; then
  printf '%s.%s.%s\n' "$floor_maj" "$floor_min" "$floor_pat" > "$FLOOR"
else
  printf '%s.%s\n' "$floor_maj" "$floor_min" > "$FLOOR"
fi
printf 'runtime-closure: glibc floor %s\n' "$(cat -- "$FLOOR")"
"""
    ## Runs AFTER the fixed point, so ``$seen`` is complete, and after
    ## the manifest write, so a floor failure cannot leave a half-built
    ## tree looking finished.
    ##
    ## An empty result is a hard failure rather than an omitted field.
    ## The alternative -- emit ``Depends: libc6 (>= )`` -- is a control
    ## stanza dpkg rejects at build time in the good case and accepts as
    ## an unversioned dependency in the bad one, which is precisely the
    ## "installs cleanly, cannot start" failure the floor exists to
    ## stop.
  ClosureScriptEpilogue = """
stale_ifs=$IFS
IFS=$NL
for stale in $(ls -1 -- "$LIBDIR" 2>/dev/null || printf ''); do
  IFS=$stale_ifs
  if contains "$vendored" "$stale"; then
    IFS=$NL
    continue
  fi
  case "$NL$keep" in
    *"$NL$stale$NL"*) IFS=$NL; continue ;;
  esac
  printf 'runtime-closure: pruning stale %s\n' "$stale"
  rm -f -- "$LIBDIR/$stale"
  IFS=$NL
done
IFS=$stale_ifs

printf '%s' "$manifest" | LC_ALL=C sort > "$MANIFEST"
"""
    ## Stale-prune plus the manifest write. The manifest carries LEAF
    ## NAMES only, sorted: it is an input of the artifact edge, so
    ## putting the resolved build-host paths in it would make two hosts
    ## that produced the same package disagree about its cache key.

# ---------------------------------------------------------------------------
# The runtime-library closure walk.
# ---------------------------------------------------------------------------

proc shellSingleQuote*(value: string): string =
  ## Same escaping as ``posixSingleQuote``; kept separate because that
  ## one is part of the WRAPPER's text, which ships, and this one is
  ## part of a BUILD-TIME script, which does not — the two must be free
  ## to diverge.
  ##
  ## Exported for producers that generate a build-time script of their
  ## own (the Arch producer's installed-size measurement). Exporting the
  ## build-time one rather than the shipping one is the whole point: a
  ## third hand-written copy of shell quoting is how a package ends up
  ## with a path it cannot handle.
  result = "'"
  for ch in value:
    if ch == '\'': result.add("'\\''")
    else: result.add(ch)
  result.add("'")

proc runtimeClosureScript*(dist: Distribution;
                           componentSources: openArray[string];
                           libDir, manifestPath: string;
                           keepLeafNames: openArray[string];
                           floorPath = ""): string =
  ## The POSIX-shell program that walks the runtime closure and fills
  ## the private libdir the §5 RPATH points at.
  ##
  ## ## Why this is a build-time SCRIPT and not Nim code in this module
  ##
  ## A component's ``DT_NEEDED`` list is a property of a file that no
  ## edge has produced yet at the moment the graph is built: on a clean
  ## tree the compiler has not run. The closure is therefore only
  ## knowable inside an ACTION, and an action's vocabulary is the tools
  ## its edge named. Two of them suffice — ``patchelf --print-needed`` /
  ## ``--print-rpath`` to read an object, and a shell to drive the
  ## fixed-point — and both are already reprobuild packages, so nothing
  ## here assumes anything about the host.
  ##
  ## ## What it does, and why each step is there
  ##
  ## 1. **Seed** with the component binaries AS BUILT — never with the
  ##    patched copies. ``stageInstallTree`` replaces their RPATH with an
  ##    ``$ORIGIN`` one, which destroys the only record of where their
  ##    libraries actually live; the pre-patch object is the sole source
  ##    of that information.
  ## 2. **Fixed point over ``DT_NEEDED``**, resolving each name against
  ##    the ``DT_RPATH``/``DT_RUNPATH`` of every object visited so far
  ##    (``$ORIGIN`` expanded against that object's own directory) plus
  ##    any ``extraLibrarySearchDirs``. Transitive, because a vendored
  ##    library's own dependencies are just as absent from the target as
  ##    it is — ``libblake3`` pulls ``libtbb``, which pulls
  ##    ``libstdc++`` and ``libgcc_s``.
  ## 3. **Classify** each name with the system/private rule
  ##    (``types.isSystemLibraryLeafName``, emitted here as a ``case`` so
  ##    the shell applies exactly the rule the Nim predicate states). A
  ##    system name is left to the target; anything else is vendored.
  ## 4. **Rewrite each vendored library's own RPATH to ``$ORIGIN``.**
  ##    Not optional, and easy to miss. glibc consults the RPATH CHAIN of
  ##    an object's loaders only when the object itself has no
  ##    ``DT_RUNPATH``; a nixpkgs build always has one, pointing into the
  ##    store. So a vendored ``libblake3`` that kept its own RUNPATH
  ##    would be found through the executable's RPATH and would then fail
  ##    to find ``libtbb`` sitting right next to it.
  ## 5. **Check the ``dlopen`` post-condition** (see
  ##    ``RuntimeContract.dlopenLeafNames``) and **prune** anything an
  ##    earlier build left in the directory that this walk did not
  ##    produce and no component declares — so a rebuild that dropped a
  ##    dependency gives the same tree as a clean build.
  ##
  ## Every unresolvable name is a loud, named failure. Carrying on and
  ## shipping a package that is missing one library is precisely the
  ## defect this proc exists to close, and it is invisible until the
  ## package is installed on a machine that is not the builder.
  var systemCases: seq[string] = @[]
  for name in dist.runtime.extraSystemLibraryLeafNames:
    if name.len > 0:
      systemCases.add(name)
      let stem = libraryStem(name)
      if stem != name: systemCases.add(stem)
  result = ""
  result.add("set -euf\n")
  result.add("# Generated by the reprobuild DSL packaging layer\n")
  result.add("# (Distribution-And-Packaging.md " & "SECT" & "5). Do not edit.\n")
  result.add("NL='\n'\n")
  result.add("LIBDIR=" & shellSingleQuote(libDir) & "\n")
  result.add("MANIFEST=" & shellSingleQuote(manifestPath) & "\n")
  result.add("EPOCH=" & shellSingleQuote($dist.sourceDateEpoch) & "\n")
  if floorPath.len > 0:
    result.add("FLOOR=" & shellSingleQuote(floorPath) & "\n")
  result.add(ClosureScriptPreamble)
  if floorPath.len > 0:
    result.add(ClosureScriptFloorFunctions)
  # The system/private rule, emitted so the shell applies exactly the
  # rule ``types.isSystemLibraryLeafName`` states.
  result.add("is_system() {\n")
  result.add("  stem=${1%%.so*}\n")
  result.add("  case $stem in\n")
  result.add("    ld-linux*|ld|ld64*|linux-vdso*|linux-gate*|libnss_*)" &
    " return 0 ;;\n")
  var stems: seq[string] = @[]
  for stem in SystemLibraryStems:
    stems.add(stem)
  result.add("    " & stems.join("|") & ") return 0 ;;\n")
  if systemCases.len > 0:
    result.add("    " & systemCases.join("|") & ") return 0 ;;\n")
  result.add("  esac\n")
  result.add("  return 1\n")
  result.add("}\n\n")

  result.add("mkdir -p -- \"$LIBDIR\"\n")
  result.add("mkdir -p -- \"$(dirname -- \"$MANIFEST\")\"\n\n")
  for dir in dist.runtime.extraLibrarySearchDirs:
    if dir.len > 0:
      result.add("add_search " & shellSingleQuote(dir) & "\n")
  for source in componentSources:
    result.add("seed " & shellSingleQuote(source) & "\n")
  result.add("\n")
  # The dlopen leaf names are seeded BEFORE the fixed point, so their own
  # dependencies are walked too: a library opened by name still needs
  # everything IT needs.
  for leaf in dist.runtime.dlopenLeafNames:
    if leaf.len > 0:
      result.add("require_dlopen " & shellSingleQuote(leaf) & "\n")
  result.add(ClosureScriptFixedPoint)
  # The stale-prune keep list is the leaf names of the components the
  # DISTRIBUTION itself declares into this directory: those are staged by
  # ordinary install edges, not by this walk, and deleting one would be
  # this action eating another edge's output.
  result.add("keep=''\n")
  for leaf in keepLeafNames:
    if leaf.len > 0:
      result.add("keep=$keep" & shellSingleQuote(leaf) & "$NL\n")
  result.add(ClosureScriptEpilogue)
  if floorPath.len > 0:
    result.add(ClosureScriptFloorEpilogue)

# ---------------------------------------------------------------------------
# Staging.
# ---------------------------------------------------------------------------

proc sanitizeIdPart(value: string): string =
  for ch in value:
    if ch.isAlphaNumeric or ch == '-' or ch == '_': result.add(ch)
    elif ch == '/' or ch == '.': result.add('-')
    else: result.add('_')

proc stagedIdPrefix*(dist: Distribution; variant: string): string =
  ## Action-id namespace for one staged tree: variant AND distribution
  ## name.
  ##
  ## The variant alone was enough for M0, and stopped being enough the
  ## first time a recipe staged TWO distributions. M0 put the variant in
  ## here because two producers over ONE ``Distribution`` were handed the
  ## same per-file ids -- "the deb tree's ``pkg-rpath-bin-hello`` and the
  ## tarball tree's are different edges with different outputs", and the
  ## engine keys the action cache by id, so a collision serves one edge's
  ## outputs for the other.
  ##
  ## The SAME argument applies one axis over, and reprobuild's own
  ## packaging is what surfaced it: §3 splits the product into
  ## ``reprobuild`` and ``reprobuild-binary-cache``, both built from one
  ## recipe, both staging a ``deb`` tree. Their trees differ (the
  ## staging roots are derived from the distribution name) but their
  ## action ids did not, and the build refused outright with
  ## ``duplicate graph node id: project:action:pkg-deb-runtime-closure``.
  ## That refusal is the engine doing the right thing; a producer that
  ## had let it through would have shipped one package's runtime closure
  ## inside the other's.
  "pkg-" & sanitizeIdPart(variant) & "-" & sanitizeIdPart(dist.name) & "-"

proc sourceTreeRelFiles*(root: string): seq[string] =
  ## Every regular file under ``root``, as ``/``-separated paths
  ## relative to it, SORTED.
  ##
  ## Walked at GRAPH TIME, which is the same thing
  ## ``repro_project_dsl.fs.preserveTree`` does with the same directory
  ## a line later — the staging edge below hands ``preserveTree`` the
  ## root and this walk enumerates it again so the ``StagedTree`` can
  ## tell a producer WHICH files the edge is going to write. rpm needs
  ## that to own the directory, the MSI needs it to emit one component
  ## per file, and the tarball and deb need it not at all.
  ##
  ## Sorted because a producer's output is a function of this list and
  ## ``walkDir`` order is a property of the filesystem, not of the
  ## graph. Symlinks are followed as their KIND rather than resolved:
  ## ``preserveTree`` re-creates a symlink as a symlink, so a link to a
  ## file is one entry here exactly as it is one entry there.
  if not dirExists(root):
    return @[]
  var pending = @[""]
  while pending.len > 0:
    let rel = pending.pop()
    let dir = if rel.len == 0: root else: root / rel
    for kind, child in walkDir(dir, relative = true):
      let childRel = if rel.len == 0: child else: rel & "/" & child
      case kind
      of pcDir:
        pending.add(childRel)
      of pcFile, pcLinkToFile:
        result.add(childRel)
      of pcLinkToDir:
        result.add(childRel)
  result.sort(system.cmp[string])

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
    idPrefix: stagedIdPrefix(dist, variant))

  # THE GENERATED-INTERMEDIATE DIRECTORY, created by an edge of its own.
  #
  # ``patchelf --output <path>`` does not create ``<path>``'s parent: it
  # answers ``patchelf: open: No such file or directory``, which names
  # neither the file nor the directory. Until now nothing noticed,
  # because every tree also had a ``writeText`` into the same genRoot
  # (the §5 wrapper, or a producer's control file) and ``fs.writeText``
  # DOES create parents — so the directory existed by the time patchelf
  # ran, whenever the scheduler happened to run that edge first.
  #
  # That is a race, and it was won by luck rather than by ordering. It
  # lost the moment a distribution with ``wrapExecutables = false``
  # staged a tree whose only genRoot writer was patchelf itself: the
  # ``reprobuild-binary-cache`` package's Arch tree, which stopped the
  # build with that message while its deb and rpm trees — identical in
  # every other way — passed.
  let genRootEdge = dslfs.ensureDir(genRoot,
    actionId = stagedIdPrefix(dist, variant) & "gen-root")

  var emittedWrapperTexts: seq[string] = @[]
    ## Every wrapper this staging actually WROTE, kept so the
    ## ``requireEnvDefaultPayload`` post-condition below can be made
    ## against the emitted text rather than against the list it was
    ## generated from.

  var selectors: seq[string] = @[]
  proc noteSelector(selector: string) =
    ## Record a tool the staging step actually used, so a producer can
    ## report it without transcribing a list that only staging knows.
    if selector.len > 0 and selector notin selectors:
      selectors.add(selector)

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

  let idPrefix = stagedIdPrefix(dist, variant)

  # The objects the runtime-closure walk starts from, AS BUILT. Not the
  # patched copies: patching replaces the RPATH, which is the only record
  # of where their libraries live. See ``runtimeClosureScript``.
  var closureSources: seq[string] = @[]
  var closureAfter: seq[BuildActionDef] = @[]
  # Leaf names the DISTRIBUTION itself stages into the private libdir.
  # The walk must not prune these -- they are another edge's output.
  var declaredLibLeafNames: seq[string] = @[]

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
      noteSelector(InstallSelector)
      edge
    else:
      dslfs.copyFile(source, target,
        actionId = idPrefix & "copy-" & sanitizeIdPart(idHint),
        after = after)

  for component in dist.components:
    let publicName = defaultInstallName(component)
    let prefixRel = installRelPath(dist, component)
    let prefixRelDir = dirOf(prefixRel)

    # ---- 0. a whole SOURCE TREE ------------------------------------
    #
    # Handled before everything else and by ``continue``, because none
    # of what follows applies: a source tree has no wrapper, no RPATH,
    # no ELF interpreter, no mode of its own and no place in the
    # runtime-closure walk. It is the one component role whose payload
    # is a directory, and ``fs.preserveTree`` -- an engine BUILTIN --
    # is what mirrors it, so this arm adds no tool dependency and
    # behaves identically on Windows.
    if component.role == crSourceTree:
      let treeRootRel = rootRelFor(prefixRel, crSourceTree)
      let destDir = treeRoot & "/" & treeRootRel
      let relFiles = sourceTreeRelFiles(component.buildPath)
      if relFiles.len == 0:
        # REFUSED, rather than staged empty. ``preserveTree`` over a
        # directory that does not exist (or that holds nothing) is
        # SILENT: it enumerates no entries, declares no outputs and
        # creates an empty directory in the tree. The package then
        # installs, its wrapper names the directory, the directory is
        # there -- and the compile that the tree exists to serve fails
        # on the target with a missing import. That is precisely the
        # failure mode this whole component role was added to close, so
        # it must not be reachable by forgetting to stage a payload.
        raise newException(ValueError,
          "distribution '" & dist.name & "': crSourceTree component '" &
          component.buildPath & "' (installing to '" & treeRootRel &
          "') contains no files; a source tree that stages empty would " &
          "give the target a directory the wrapper names and nothing " &
          "to compile against")
      let edge = dslfs.preserveTree(component.buildPath, destDir,
        actionId = idPrefix & "srctree-" & sanitizeIdPart(treeRootRel),
        after = component.producedBy)
      # One ``StagedFile`` per mirrored file, all naming the SAME edge.
      # That is not a fiction: ``preserveTree`` declares every one of
      # them as an output, so a producer that depends on these paths
      # depends on exactly the edge that writes them.
      for rel in relFiles:
        result.files.add(StagedFile(
          rootRelPath: treeRootRel & "/" & rel,
          edge: edge,
          role: crSourceTree,
          isPublicEntryPoint: false))
      result.terminal.add(edge)
      result.sourceTreeRoots.add(treeRootRel)
      continue
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
      closureSources.add(component.buildPath)
      for edge in component.producedBy:
        closureAfter.add(edge)
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
        # The ELF interpreter, on the SAME edge as the RPATH and for the
        # same reason: a binary built under a foreign toolchain names
        # that toolchain's loader in ``PT_INTERP``, and a target with no
        # such path cannot start it. ``execve`` answers ``ENOENT`` for a
        # missing INTERPRETER exactly as it does for a missing image, so
        # the symptom is ``not found`` for a file that is plainly there.
        #
        # Only executables get one. A shared library has no ``PT_INTERP``
        # and patchelf refuses ``--set-interpreter`` on one, so asking
        # would turn a vendored library into a build failure.
        setInterpreter =
          (if component.role == crRuntimeLibrary: ""
           else: interpreterPathFor(dist)),
        output = patched,
        file = component.buildPath,
        actionId = idPrefix & "rpath-" & sanitizeIdPart(prefixRel),
        # ...and the directory the ``--output`` lands in. See
        # ``genRootEdge``: patchelf will not create it, and the failure
        # it reports names neither the file nor the directory.
        after = component.producedBy & @[genRootEdge])
      declareProducerTool(site, edge.id, PatchelfSelector)
      noteSelector(PatchelfSelector)
      payloadSource = patched
      payloadAfter = @[edge]

    if component.role == crRuntimeLibrary:
      declaredLibLeafNames.add(defaultInstallName(component))

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
      emittedWrapperTexts.add(text)
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

  # ---- 3. the vendored runtime-library closure ---------------------
  #
  # LAST, and ordered after every other staging edge, for one reason
  # that is easy to get wrong: this edge OWNS a directory rather than a
  # file set, and it prunes what it does not recognise. Running it
  # before the install edges that stage a declared ``crRuntimeLibrary``
  # would let it delete another edge's output.
  if dist.targetOs == toLinux and dist.runtime.vendorRuntimeClosure and
      closureSources.len > 0:
    let libPrefixRel = privateLibPrefixRelDir(dist)
    let libRootRel = rootRelFor(libPrefixRel, crRuntimeLibrary)
    let libDir = treeRoot & "/" & libRootRel
    let manifestPath = genRoot & "/" & sanitizeIdPart(variant) &
      "-runtime-closure.manifest"
    let floorPath =
      if dist.computesDependencyFloor():
        genRoot & "/" & sanitizeIdPart(variant) & "-glibc-floor.txt"
      else:
        ""
    let script = runtimeClosureScript(dist, closureSources, libDir,
      manifestPath, declaredLibLeafNames, floorPath)
    var after = closureAfter
    for edge in result.terminal:
      after.add(edge)
    let edge = sh_module.shell(script,
      actionId = idPrefix & "runtime-closure",
      after = after,
      # The objects the walk reads. Declared so a rebuilt binary
      # re-runs the walk -- a new dependency in a component is exactly
      # the change that must reach the shipped library set.
      extraInputs = closureSources,
      # The floor file joins the manifest as a declared output rather
      # than being written into the tree: it is BUILD data, consumed by
      # the edge that splices it into a control stanza, and a file that
      # shipped inside the package would be telling the target
      # something it already knows.
      extraOutputs =
        (if floorPath.len > 0: @[manifestPath, floorPath]
         else: @[manifestPath]),
      # The walk reads back what it just wrote (patchelf re-reads the
      # copy it is about to rewrite, and the prune lists the
      # directory). Those are its own writes, not inputs, and treating
      # them as inputs would make the edge depend on its previous run.
      ignoredInputPrefixes = @[libDir])
    # The write ROOT, not a file list: the vendored set is discovered at
    # build time, so there are no per-file outputs to declare. Same
    # shape ``cmake_package``'s install edge uses for a DESTDIR, and the
    # same mechanism (M9.R.75's R7 pairwise write-root check) grades it.
    setRegisteredActionDeclaredOutputs(edge.id, @[libDir])
    declareProducerTool(site, edge.id, ShSelector)
    noteSelector(ShSelector)
    declareProducerTool(site, edge.id, PatchelfSelector)
    noteSelector(PatchelfSelector)
    # coreutils, reached through the ``install`` executable's package --
    # see the note on ``ShSelector``.
    declareProducerTool(site, edge.id, InstallSelector)
    noteSelector(InstallSelector)
    if floorPath.len > 0:
      # Named on THIS edge, not on one of its own: the floor covers the
      # vendored set, and the vendored set does not exist until this
      # action has put it there.
      declareProducerTool(site, edge.id, ReadelfSelector)
      noteSelector(ReadelfSelector)
    result.terminal.add(edge)
    result.producerExtraInputs.add(manifestPath)
    # NOT added to ``producerExtraInputs``. The floor reaches a producer
    # through ``addGeneratedFile``'s ``substitutions``, which names it as
    # an input of the edge that splices it; the artifact edge then
    # depends on it transitively through the staged control file. Naming
    # it in both places would be true and redundant.
    result.glibcFloorPath = floorPath

  # ---- 4. the env-default payload post-condition -------------------
  #
  # See ``RuntimeContract.requireEnvDefaultPayload``. Deliberately the
  # LAST thing staging does, and deliberately reading ``result.files``:
  # by this point that list is every path this tree will contain, and
  # the source-tree entries in it were enumerated from the build tree on
  # disk rather than derived from anything the wrapper was built from.
  #
  # A distribution that turns this on and emits no wrapper at all is a
  # contradiction rather than a vacuous pass, so it is refused too: the
  # check is about what the wrapper names, and there being no wrapper
  # means nothing was checked.
  if dist.runtime.requireEnvDefaultPayload:
    if dist.runtime.envDefaults.len > 0 and emittedWrapperTexts.len == 0:
      raise newException(ValueError,
        "distribution '" & dist.name & "': requireEnvDefaultPayload is set " &
        "and " & $dist.runtime.envDefaults.len & " env defaults are " &
        "declared, but this tree emitted no wrapper to check them against")
    var stagedRootRelPaths: seq[string] = @[]
    for f in result.files:
      stagedRootRelPaths.add(f.rootRelPath)
    var gaps: seq[string] = @[]
    for text in emittedWrapperTexts:
      for gap in envDefaultPayloadGaps(dist, text, stagedRootRelPaths,
          rootedAtPrefix):
        if gap notin gaps:
          gaps.add(gap)
    if gaps.len > 0:
      raise newException(ValueError,
        "distribution '" & dist.name & "' (" & variant & "): the wrapper " &
        "it emits names " & $gaps.len & " prefix-relative path(s) that " &
        "nothing in this package installs:" & "\n" & "  " &
        gaps.join("\n" & "  ") & "\n" &
        "A package whose wrapper points at nothing installs cleanly, " &
        "runs --version, and fails on the first thing that opens one of " &
        "these. Ship the payload, drop the variable, or turn " &
        "requireEnvDefaultPayload off and say why.")

  result.stagingSelectors = selectors

proc substitutionScript*(text: string; genPath: string;
                         substitutions: openArray[(string, string)]): string =
  ## The POSIX-shell program that writes ``genPath`` from ``text`` with
  ## each ``(token, valueFile)`` pair spliced in.
  ##
  ## ## Why a script rather than a Nim string replace
  ##
  ## Same reason as the closure walk, one step further on: the VALUE
  ## does not exist at graph time. The C-library floor is read out of
  ## ``.gnu.version_r`` of files no edge has produced yet, so the only
  ## place that can put it into a ``Depends:`` line is an action.
  ##
  ## ## Why splicing and not rewriting the staged file in place
  ##
  ## An in-place rewrite would mean two edges writing one path, which
  ## breaks the property the header of this module states plainly:
  ## no edge here rewrites a file another edge produced. So the
  ## substitution happens on the way IN — this script replaces the
  ## ``writeText`` edge rather than following it — and the tree still
  ## has one producer per path.
  ##
  ## The text is split on the token at GRAPH time and re-assembled by
  ## ``printf`` at build time, so no ``sed`` is needed and no escaping
  ## question arises about what the value might contain: the pieces are
  ## single-quoted literals and the value arrives through ``$(cat)``,
  ## which strips the trailing newline ``printf '%s\n'`` wrote.
  result = "set -euf\n"
  result.add("# Generated by the reprobuild DSL packaging layer\n")
  result.add("# (Distribution-And-Packaging.md " & "SECT" & "6). Do not edit.\n")
  result.add("mkdir -p -- \"$(dirname -- " & shellSingleQuote(genPath) &
    ")\"\n")
  var pieces = @[text]
  var valueVars: seq[string] = @[]
  for i in 0 ..< substitutions.len:
    let token = substitutions[i][0]
    let valueFile = substitutions[i][1]
    let varName = "SUBST" & $i
    result.add(varName & "=$(cat -- " & shellSingleQuote(valueFile) & ")\n")
    result.add("if [ -z \"$" & varName & "\" ]; then\n")
    result.add("  printf 'packaging: substitution value file %s is empty\\n' " &
      shellSingleQuote(valueFile) & " >&2\n")
    result.add("  exit 1\n")
    result.add("fi\n")
    valueVars.add(varName)
    # Split every piece produced so far on this token, so a token that
    # occurs more than once (rpm states the same floor in ``Requires:``
    # and nowhere else today, but deb's ``Pre-Depends`` would repeat it)
    # is replaced at every occurrence rather than only at the first.
    var next: seq[string] = @[]
    for piece in pieces:
      var rest = piece
      while true:
        let cut = rest.find(token)
        if cut < 0:
          next.add(rest)
          break
        next.add(rest[0 ..< cut])
        next.add("\x00" & varName)
        rest = rest[cut + token.len .. ^1]
    pieces = next
  result.add("{\n")
  for piece in pieces:
    if piece.len > 1 and piece[0] == '\x00':
      result.add("  printf '%s' \"$" & piece[1 .. ^1] & "\"\n")
    elif piece.len > 0:
      result.add("  printf '%s' " & shellSingleQuote(piece) & "\n")
  result.add("} > " & shellSingleQuote(genPath) & "\n")

proc addGeneratedFile*(tree: var StagedTree; rootRelPath, text: string;
                       mode = 0o644; site = noSite();
                       substitutions: openArray[(string, string)] = []):
    BuildActionDef {.discardable.} =
  ## Put a producer-generated text file into an already-staged tree.
  ##
  ## Producers need this for the parts of a package that ARE the format:
  ## the deb ``control`` and maintainer scripts, the systemd units, the
  ## rpm ``%files`` payload. It goes through the same
  ## write-then-install-with-a-mode pipeline as everything else, so a
  ## ``postinst`` a producer generates is 0755 for the same reason and
  ## by the same code as a §5 wrapper — the modes are not a thing each
  ## producer remembers.
  ##
  ## ``substitutions`` names ``(token, valueFilePath)`` pairs whose
  ## value is only knowable at BUILD time — today just the C-library
  ## floor (``types.GlibcFloorToken`` against
  ## ``StagedTree.glibcFloorPath``). With the list empty the file is
  ## written by an ordinary ``writeText`` edge, exactly as before;
  ## with entries, that edge becomes a ``sh`` one that assembles the
  ## same text with the values spliced in. Either way the file's ONE
  ## producer is a single edge and the install step is unchanged.
  let genPath = tree.genRoot & "/" & tree.idPrefix &
    sanitizeIdPart(rootRelPath) & ".gen"
  let writeEdge =
    if substitutions.len == 0:
      dslfs.writeText(genPath, text,
        actionId = tree.idPrefix & "gen-text-" & sanitizeIdPart(rootRelPath))
    else:
      var valueFiles: seq[string] = @[]
      for i in 0 ..< substitutions.len:
        valueFiles.add(substitutions[i][1])
      let e = sh_module.shell(
        substitutionScript(text, genPath, substitutions),
        actionId = tree.idPrefix & "gen-subst-" & sanitizeIdPart(rootRelPath),
        # The value files are real inputs: a floor that moved because a
        # vendored library grew a newer symbol version must re-write the
        # control stanza, and without this the edge would have no reason
        # to notice.
        extraInputs = valueFiles,
        extraOutputs = @[genPath])
      declareProducerTool(site, e.id, ShSelector)
      # ``cat``/``mkdir``/``dirname`` come from coreutils, reached
      # through the ``install`` executable's package -- the same
      # indirection the closure walk uses and for the same reason.
      declareProducerTool(site, e.id, InstallSelector)
      e
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

proc addGeneratedIntermediate*(tree: var StagedTree; name, text: string;
                               site = noSite();
                               substitutions: openArray[(string, string)] = []):
    tuple[path: string, edge: BuildActionDef] =
  ## Generate a text file BESIDE the tree rather than inside it, and
  ## make the tree's producer depend on it.
  ##
  ## The deb producer needs its ``control`` INSIDE the payload
  ## (``DEBIAN/control`` is where dpkg-deb looks); rpm needs its
  ## ``.spec`` OUTSIDE the buildroot, because anything inside the
  ## buildroot that ``%files`` does not list is an unpackaged-file
  ## error and anything it does list ships. That is a real difference
  ## between the two formats rather than an accident of either, so the
  ## layer offers both placements rather than making one producer
  ## work around the other's assumption.
  ##
  ## The returned path is appended to ``producerExtraInputs``, so the
  ## artifact edge depends on the file's CONTENTS — a spec whose
  ## ``Requires:`` changed must rebuild the rpm even though no staged
  ## file moved.
  # The FILE keeps ``name`` verbatim; only the ACTION ID is sanitised.
  # ``sanitizeIdPart`` maps ``.`` to ``-``, which is right for an id and
  # wrong for a file: rpmbuild is handed this path as its spec operand,
  # and a ``.spec`` that arrived as ``-spec`` is a working-by-accident
  # arrangement waiting for the first tool that dispatches on extension.
  let genPath = tree.genRoot & "/" & tree.idPrefix & name
  let edge =
    if substitutions.len == 0:
      dslfs.writeText(genPath, text,
        actionId = tree.idPrefix & "gen-aux-" & sanitizeIdPart(name))
    else:
      var valueFiles: seq[string] = @[]
      for i in 0 ..< substitutions.len:
        valueFiles.add(substitutions[i][1])
      let e = sh_module.shell(
        substitutionScript(text, genPath, substitutions),
        actionId = tree.idPrefix & "gen-aux-subst-" & sanitizeIdPart(name),
        extraInputs = valueFiles,
        extraOutputs = @[genPath])
      declareProducerTool(site, e.id, ShSelector)
      declareProducerTool(site, e.id, InstallSelector)
      e
  tree.terminal.add(edge)
  tree.producerExtraInputs.add(genPath)
  (genPath, edge)

proc stagedPaths*(tree: StagedTree): seq[string] =
  ## Every staged file's build-tree path, for a producer to declare as
  ## ``extraInputs``. This is what makes the artifact edge depend on the
  ## tree's CONTENTS rather than on its directory name — without it the
  ## engine would have no reason to re-run ``dpkg-deb`` when a binary
  ## inside the tree changed, and the producer would be content-
  ## addressed over the wrong thing.
  for f in tree.files:
    result.add(tree.root & "/" & f.rootRelPath)
  # The runtime-closure manifest is NOT in the tree (it sits beside the
  # other generated intermediates, so a producer that archives the whole
  # tree never picks it up), but it IS what tells the artifact edge that
  # the vendored library set changed. Appending it here rather than
  # asking every producer to remember it keeps the "a producer only
  # translates" property true.
  for path in tree.producerExtraInputs:
    result.add(path)

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
    "CLINGO_PREFIX",
    "REPRO_NIM_COMPILER"
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
    ##
    ## ``REPRO_NIM_COMPILER`` IS THE TWENTY-FIRST, AND IT WAS ADDED TO
    ## BOTH WORLDS AT ONCE. It is not a packaging invention: the
    ## resolver that consumes it (``repro_interface_artifacts.
    ## nimCompilerPath``) has always taken it as its highest-priority
    ## arm, and its next arm is ``BuiltNimCompilerPath``, a constant
    ## baked at COMPILE TIME out of ``staticExec("command -v nim")``.
    ## Under Nix that constant is a store path that exists, so the flake
    ## never needed to say anything; in a native package it is a store
    ## path that does not, and the arm after it is ``nim`` on ``$PATH``.
    ##
    ## That last arm is where the measurement bites. Neither
    ## ``debian:trixie-slim`` nor ``fedora:latest`` PACKAGES A NIM
    ## COMPILER AT ALL (Debian bookworm's is 1.6.10, older than the
    ## sources this package ships; Arch's is 2.2.12 and is the only
    ## adequate distribution build found), so ``Depends: nim`` is not a
    ## dependency a package manager could satisfy on the two images M1's
    ## gate uses -- it is a package that will not install. And
    ## reprobuild's own tool-provisioning cannot supply it either,
    ## because the compile that needs it is the one that READS THE
    ## RECIPE that would declare it. A bootstrap dependency with no
    ## external supplier is exactly the case for vendoring, so the
    ## package ships a toolchain and this variable names it.
    ##
    ## The flake sets it too, at the same store path its
    ## ``BuiltNimCompilerPath`` would have found, which makes the
    ## resolution explicit in both worlds rather than implicit in one.

  ReprobuildDlopenPackages* = ["zstd", "clingo"]
    ## §5: "clingo and zstd … the last two ``dlopen``'d by leaf name".
    ## These are the reason the RPATH is mandatory rather than
    ## redundant.
    ##
    ## PACKAGE names, which is all §5's prose gives. They are kept
    ## because they are what the spec says and what a human recognises,
    ## and they are NOT what ``RuntimeContract.dlopenLeafNames`` takes —
    ## see ``reprobuildDlopenLeafNames`` immediately below.

proc reprobuildDlopenLeafNames*(targetOs: TargetOs): seq[string] =
  ## The names reprobuild's own binaries actually hand to ``dlopen``,
  ## reduced to the LEAF FILE NAME the closure walk can look for.
  ##
  ## ## What was wrong with the constant this replaces
  ##
  ## M0 left ``ReprobuildDlopenLeafNames = ["zstd", "clingo"]`` in a
  ## field that had just become a CHECKED POST-CONDITION, and the two
  ## halves are not compatible. ``require_dlopen`` resolves a name by
  ## exact file name against the walk's search path, so ``zstd`` — a
  ## package name, not a file name — cannot resolve, and the first
  ## recipe to feed the constant to the field it was written for would
  ## have failed the build with "no search path contains it". The
  ## constant was inert when it was written and stopped being inert
  ## when the assertion landed; nothing rechecked it. M0 recorded that
  ## as residual R3 and left it, on the grounds that guessing the
  ## soversions would be inventing data — which was the right call,
  ## because the data is not a guess and does not live in §5's prose.
  ##
  ## ## Where the answer comes from
  ##
  ## The dlopen strings are already stated, exactly once each, at the
  ## call sites: ``repro_binary_cache_client/dynlib_names.zstdDynlibName``
  ## and ``repro_solver/dynlib_names.clingoDynlibName``, both written as
  ## per-target functions precisely so a non-Darwin host can verify what
  ## Darwin will pass to ``loadLib``. This proc mirrors them, per target,
  ## and ``t_packaging_wrapper_vars_match_flake`` asserts the two cannot
  ## drift — the same drift-guard shape ``ReprobuildWrapperVariables``
  ## already uses against ``flake.nix``.
  ##
  ## ## Why mirrored rather than imported
  ##
  ## Importing them would make the DSL stdlib — which every recipe
  ## compiles — depend on the solver and the cache client, two of the
  ## heaviest modules in the tree, for two string literals. The drift
  ## guard buys the same property for the price of one test.
  ##
  ## ## Leaf name, not the dlopen string
  ##
  ## On Darwin the dlopen argument is ``@rpath/libzstd.1.dylib``: a bare
  ## leaf name does NOT consult an image's ``LC_RPATH``, so the
  ## ``@rpath/`` prefix is load-bearing in the CALL. It is not part of
  ## the FILE's name, and the field is a post-condition about a file in
  ## the private libdir, so the prefix is stripped here. Getting that
  ## backwards would make the Darwin check ask for a file called
  ## ``@rpath/libzstd.1.dylib`` and fail a package that is correct.
  case targetOs
  of toLinux:
    @["libzstd.so.1", "libclingo.so"]
  of toDarwin:
    @["libzstd.1.dylib", "libclingo.dylib"]
  of toWindows:
    # Recorded for completeness and inert in practice: Windows stages no
    # closure edge (``stageInstallTree`` gates it on ``toLinux``), so
    # nothing consumes this arm today. It is written out rather than
    # left as an empty seq because an empty seq would read as "reprobuild
    # dlopens nothing on Windows", which is false.
    @["libzstd.dll", "clingo.dll"]
