## Canonical source/provider-closure identity for source-built packages.
##
## ## What this module binds (Reprobuild #171, campaign M13)
##
## A source package's cache identity must be a function of the COMPLETE
## solved instance, not of the entry recipe's bytes. Before #171 was
## fixed, ``sourceProviderRevisionHex`` hashed only
## ``resolveProjectFile(projectRoot).path``, so a project whose
## ``repro.nim`` contains ``import recipe`` kept the SAME identity when
## ``recipe.nim`` changed from ``const implementation = 1`` to
## ``const implementation = 2``. That aliases two different package
## implementations onto one key on the materialized-substitution and
## publication paths.
##
## The identity now binds:
##
##   * the **source closure** — the entry project file plus every local
##     Nim module reachable from it through ``import`` / ``from ...
##     import`` / ``include``, transitively, plus every compile-time
##     file read (``staticRead`` / ``slurp``) it performs, plus every
##     declared local non-Nim source input (SDK generator templates,
##     ``.c`` sources, data files, directories);
##   * the **selected options** actually solved for this instance;
##   * the **dependency instances** actually resolved for it (their
##     cache-entry-key hexes);
##   * the **target platform + ABI**;
##   * the **actual toolchain** (name AND version — an unidentified
##     toolchain is missing evidence, not an empty field).
##
## ## Relocation stability
##
## The closure digest is computed over ``(project-relative path,
## BLAKE3 of the bytes)`` pairs, sorted by the relative path with
## separators normalised to ``/``. No absolute path ever enters the
## digest: ``projectRelative`` answers "is this file inside the project
## root, and if so what is its relative spelling", and a file that is
## NOT inside the root never reaches the digest at all — it is either an
## external library (ignored) or missing evidence (refused). That closes
## the cross-drive hole in the previous ``relativePath`` fallback, which
## on Windows returns the ABSOLUTE path when the two paths sit on
## different drives (it does not raise), so an absolute path could enter
## the digest and break relocation stability silently. Hashing absolute
## paths would make the identity trivially "change on every mutation"
## while also changing on relocation — which is why the regression test
## pins relocation stability as the non-vacuity control.
##
## ## How a module spec is resolved
##
## Nim resolves an import against more than the importing file's own
## directory, and the scanner now models the same set:
##
##   * the importing file's own directory;
##   * the project root;
##   * the nimble ``srcDir`` declared by ``<root>/*.nimble``;
##   * every ``--path:`` / ``switch("path", "...")`` search root with a
##     STRING-LITERAL argument in ``<root>/nim.cfg``,
##     ``<root>/config.nims``, ``<root>/<entry>.nim.cfg`` or
##     ``<root>/<entry>.nims`` (``$projectDir`` / ``$projectPath`` /
##     ``$config`` expanded), restricted to roots that lie INSIDE the
##     project root;
##   * every root in ``SolvedSourceInstance.effectiveSearchRoots`` — the
##     ``--path`` set of the EFFECTIVE compile command, which the caller
##     supplies because no scan of the tree can recover it. These are
##     searched last, matching Nim's own order (config files before the
##     command line), and are NOT restricted to the project root: a
##     ``--path`` into a nimble dependency is legitimate, and a spec
##     that resolves through one lands outside the project root and is
##     then classified as external code. A supplied root that does NOT
##     EXIST refuses: see "A supplied root that does not exist" below.
##
## The effective search-root set is a REQUIRED input, not an optional
## hint: ``searchRootsKnown`` distinguishes "reconstructed, and it adds
## nothing beyond what is on disk" from "never reconstructed", and the
## identity REFUSES in the second case. See "The command-line --path
## channel" below for why anything weaker aliases.
##
## At each root the spec is tried as the literal path (so
## ``include "frag.inc"`` and ``include "frag.nim"`` resolve — the old
## scanner appended ``.nim`` unconditionally and dropped both), then
## with ``.nim``/``.nims`` appended, then as a package directory
## (``import pkgdir`` → ``pkgdir/pkgdir.nim``).
##
## ## External library vs unresolvable local module
##
## This is the load-bearing rule, and it is stated as a rule rather than
## a heuristic because both directions are safety-relevant: treating a
## local module as external re-creates the #171 aliasing class, and
## treating an external library as local makes every identity
## permanently PENDING and therefore useless.
##
## A spec that FAILS to resolve under the roots above is **missing
## evidence** (the identity refuses) when ANY of the following holds:
##
##   1. it is explicitly relative (``./x``, ``../x``) or absolute — it
##      names a file by construction;
##   2. it came from an ``include`` — Nim textually inlines the target,
##      and an ``include`` of a library is not a thing recipes do;
##   3. it carries a Nim source extension (``.nim``, ``.nims``,
##      ``.inc``) — it names a file, not a package;
##   4. the project declares search paths this scanner could not
##      evaluate (a non-literal ``switch("path", expr)``, a computed
##      ``--path``), so the search-root set itself is unknown and no
##      spec can be ruled out;
##   5. the spec's FIRST path segment matches an on-disk entry under one
##      of the search roots (a directory, or a ``.nim``/``.nims`` file) —
##      partial evidence that it points into this project.
##
## Otherwise it is an **external library** and is ignored. A spec
## starting ``std/`` or ``pkg/``, and ``system``, are external by
## Nim's own namespacing and short-circuit before any of the above.
## So does a spec that RESOLVES to a file outside the project root
## (a vendored sibling, an absolute import into another tree): it is
## not project source, and the code it contributes is bound through
## ``dependencyInstances`` instead.
##
## Why the negative direction is MOSTLY safe: a bare spec with no
## on-disk evidence anywhere under the project's own search roots is
## usually not a file this project ships, and Nim then satisfies it from
## OUTSIDE the project (stdlib, a nimble package, a ``--path`` into
## another tree). Why the positive direction is safe: rules 1-5 refuse
## rather than digest whenever the spec could be project source, so an
## under-approximated closure is never turned into a key.
##
## ## The command-line ``--path`` channel
##
## Rule 4 fires only on a search path this scanner can SEE and cannot
## evaluate. A ``--path`` supplied on the command line, or contributed
## by a nimble dependency, leaves no trace in any scanned config file,
## so there was nothing to mark unknown: the spec resolved for the
## compiler, was dropped here, and a digest was still produced. Measured
## at ca7864d0 on a tree whose ``internal/helper.nim`` is reachable only
## that way — closure digest ``337050709747f16f…`` unchanged across a
## change to ``const implementation`` from 1 to 2, two implementations
## on one key.
##
## That is why ``effectiveSearchRoots`` / ``searchRootsKnown`` are
## inputs of the solved instance rather than something the scanner tries
## to guess. Supplied, those roots resolve and whatever they reach is
## bound. NOT supplied, the identity refuses, naming the missing
## evidence — the same treatment an unresolvable candidate-local module
## already gets. There is no third behaviour in which a digest is
## produced over an unknown search-root set.
##
## A supplied root that does not exist. A caller that ASSERTS
## ``searchRootsKnown`` and then names a directory that is not on disk
## has reconstructed the compile command wrongly, and its claim is
## checkable in exactly this one respect — so it is checked, and the
## identity refuses naming the bad root. Measured at ``18e3f3b0``,
## where such a root was ignored "as the compiler ignores it": a typo'd
## ``internl`` for ``internal`` silently dropped the module it was meant
## to reach and landed back on closure digest ``337050709747f16f…``,
## one key across the ``implementation`` 1 -> 2 change. The compiler
## ignoring an absent ``-p`` is not a reason for the IDENTITY to ignore
## it: the compiler is not being asked whether the root set is the one
## the recipe was built with.
##
## What that still does NOT prove, and the residual it leaves. It does
## not prove the caller's set is COMPLETE: a root set whose every root
## EXISTS but which does not reach a module the project imports still
## produces a digest, and still aliases across that module's change,
## because a bare unresolved spec with no on-disk evidence is classified
## external by the rule above. Measured on the same tree: the incomplete
## (but existing) root set lands on digest ``337050709747f16f…`` and one
## key across 1 -> 2, exactly as before. That is left OPEN deliberately.
## Closing it the obvious way — refusing every bare spec that resolves
## nowhere — is the change that would make all 336 real project roots in
## this repository permanently unkeyable, which is the same uselessness
## as aliasing; nothing available from inside this module distinguishes
## "a module the caller forgot to tell me about" from "the stdlib".
## ``t_source_cache_identity_binds_complete_solved_instance`` pins the
## residual as a case so it cannot decay into a claim.
##
## No production call site supplies effective roots today — every one of
## them uses the legacy 4-argument constructor and is therefore refused.
##
## A ``config.nims`` that computes ``--path`` in a loop or from an
## expression is a DIFFERENT case and is unchanged: rule 4 fires, and
## such a project (reprobuild's own tree among them) refuses rather than
## aliases. Supplying effective roots does not lift that refusal,
## because a seen-but-unevaluatable switch is evidence that the scanner
## has an incomplete picture of the project's OWN configuration, which
## the caller's command line does not answer.
##
## ## Commented-out and quoted imports
##
## The source text is masked before scanning: ``#`` line comments,
## nestable ``#[ ]#`` / ``##[ ]##`` block comments and triple-quoted
## string literals are blanked (newlines preserved). An ``import
## ./ghost`` inside a block comment or a ``"""..."""`` literal is
## therefore NOT seen.
##
## That is deliberately on the permissive side of fail-closed, and the
## reason is that it is not a weakening at all: Nim does not read those
## bytes, so they are provably not an input. Refusing on them is not
## "failing closed", it is failing ALWAYS — a correct project with a
## commented-out import would be permanently unkeyable, which is the
## same uselessness as making everything PENDING. Masking moves the
## scan CLOSER to what the compiler sees in both directions. Ordinary
## single-line ``"..."`` literals are kept verbatim, because
## ``import "./x"`` and the ``staticRead`` argument live in them.
##
## ## Compile-time reads
##
## ``staticRead`` / ``slurp`` with a string-literal argument are
## resolved against the reading file's directory and then the project
## root, and their bytes enter the closure. A non-literal argument, an
## argument that does not resolve, or an argument resolving outside the
## project root is missing evidence. ``gorge`` / ``gorgeEx`` /
## ``staticExec`` run a command at compile time whose output cannot be
## bound at all, so their mere presence is missing evidence.
##
## This is still a textual scan rather than a parse, but it is no
## longer a bare identifier grep, because a grep false-refused three
## shapes of CORRECT recipe and a permanently unkeyable project is as
## useless as an aliased one. Three exclusions apply, and each is
## provable from the text rather than heuristic:
##
##   * an occurrence inside a KEPT single-line string literal is data,
##     not a call. Detection runs over a copy in which those literals
##     are blanked (``blankKeptStringLiterals``), with offsets
##     preserved so the ``staticRead`` ARGUMENT can still be read from
##     the unblanked text at the same position;
##   * the DECLARATION of the name is not a use of it: the occurrence
##     in ``proc slurp(...)`` is recorded by offset and skipped, so a
##     file that defines the symbol does not refuse on its own header;
##   * an unqualified CALL that this file's OWN routine declaration
##     provably takes is that routine, not the stdlib's — where "this
##     file's own declaration" means one the COMPILER would apply at
##     that call: at module scope (column 0) and textually before it.
##
## That third rule is per CALL, not per file, and the difference is the
## whole point. Measured against nim 2.2.8:
##
##   * ``proc slurp(label: string)`` + ``slurp("greeting")`` binds the
##     LOCAL routine — the stdlib read never happens, so refusing on it
##     costs a correct recipe its key for nothing;
##   * ``proc slurp(n: int)`` + ``slurp("payload.txt")`` binds
##     ``system.slurp`` and READS the file — the local overload cannot
##     take a string, so it does not shadow this call at all;
##   * ``const gorge = 3`` + ``gorge("echo hi")`` runs
##     ``system.gorge``, and ``var slurp = 3`` + ``slurp("x")`` reads
##     the file: a non-routine declaration is not overloadable and
##     never captures a call, though it does own a BARE mention of the
##     name (``const entry = gorge``), which reads nothing anyway.
##
## Scope and order are part of the same measurement, and a declaration
## table that ignored them was the THIRD fail-open this deliverable
## opened. Compiled and RUN under nim 2.2.8 (Windows) and nim 2.2.4
## (Linux), every one of these DOES read the payload even though the
## file declares ``proc slurp(label: string)``, because the compiler
## never applies that declaration at that call:
##
##   * the declaration comes textually AFTER the call (top-level code
##     is resolved in order, so the symbol does not exist there yet);
##   * the declaration is nested inside another routine's BODY, so it
##     is invisible at module scope;
##   * the declaration is under ``when false:`` or under a
##     ``when defined(...)`` the build never sets, so it is never
##     compiled.
##
## So a declaration excludes a call only when it sits at column 0 and
## before it. A declaration at indent > 0 is either nested or
## ``when``-guarded; which of those it is, and whether the guard is
## live, is not decidable from the text, so it yields the REFUSING
## verdict rather than the ignoring one. A non-routine declaration is
## exempt from that at any indentation, because it cannot join an
## overload set at all: measured, an ``outer`` body declaring
## ``const slurp = 3`` still reads the payload at module scope, so
## refusing there would be a false refusal rather than caution.
##
## An earlier revision excluded every unqualified occurrence in a file
## that declared the name, which is the second and third of those
## measurements inverted. Its cost was measured and it was an ALIAS,
## not a refusal: on ``proc slurp(n: int)`` plus a real
## ``slurp("payload.txt")``, the payload was absent from the closure
## and the key did not move when the payload changed — the #171 defect
## itself, re-created inside the fix for it, where ``ca7864d0``'s bare
## grep had refused. For a cache identity a false refusal is annoying
## and a false accept is the defect, so the exclusion now has to prove
## itself per call.
##
## Where the text does NOT decide the overload, the identity REFUSES
## rather than ignoring: a call whose argument is not a string literal
## (nothing rules the local overload in or out), a local parameter type
## that is neither exactly ``string`` nor one of the scalars a string
## literal provably cannot convert to (a generic parameter, an
## ``untyped`` template parameter, a type reachable by ``converter`` —
## any of these may or may not beat ``system``'s exact match), and a
## parameter list that does not close on its own line. Each of those is
## missing evidence and lands in ``missing`` like any other.
##
## A QUALIFIED occurrence is never excluded by shadowing at all.
## ``system.<fn>`` is the stdlib compile-time read by construction, and
## a foreign qualifier (``mymod.slurp``) names a symbol this scanner
## cannot see — so shadowing cannot be used to hide either one. A
## foreign qualifier is not "missing evidence" by itself, which an
## earlier revision of this docstring said it was: measured,
## ``mymod.slurp("payload.txt")`` with a literal that RESOLVES binds
## the payload and the key moves with it, which is an
## over-approximation and the safe direction. It is missing evidence
## only when the argument does not resolve.
##
## What that still does NOT prove, stated by DIRECTION — "not a parse"
## alone does not say which way each gap fails, and only one of them
## fails the dangerous way:
##
##   * a routine whose signature spans lines is read one declaration
##     line at a time and is undecidable, so it REFUSES;
##   * an ``import``ed overload is invisible to this scanner, so a call
##     that overload would capture is still treated as the stdlib read.
##     That over-approximates: it binds the argument, or refuses when
##     the argument does not resolve. It never ignores;
##   * ``when`` is not evaluated. A ROUTINE declaration under one is
##     indented, which is undecidable and refuses; a read or an import
##     inside one is bound whether or not the branch is live, which
##     over-approximates. Both are the safe direction;
##   * MACRO-GENERATED code is the one gap that fails the other way,
##     and it is an open residual rather than a caveat: a compile-time
##     read or an import that exists only after expansion leaves no
##     text for this scanner to see, is therefore not bound, and the
##     key can ALIAS across a change to what it reads.
##
## Measured over all 336 project roots in this repository, the scope
## and order rule costs zero new refusals and moves no closure digest.
##
## ## Case-sensitivity
##
## The de-duplication key for a visited path folds case ONLY on
## Windows. Folding it unconditionally — as this scanner used to —
## merges two genuinely distinct files on a case-sensitive filesystem,
## which is Linux, which is the build target: that is exactly the
## aliasing class #171 is about, re-introduced by the dedup table.
##
## ## Why this scanner is local rather than shared
##
## ``repro_interface_artifacts.discoverNimSources`` resolves search
## roots and is the natural host for this logic, but
## ``repro_interface_artifacts`` IMPORTS ``repro_project_dsl`` and this
## module is part of ``repro_project_dsl`` — importing it back is a hard
## library cycle. ``macros_a.producerSourceStamp`` is inside this
## package but ``macros_a`` is included into ``repro_project_dsl.nim``,
## which imports THIS module, so that direction is a cycle too (its own
## docstring records the same constraint for the same reason).
## ``repro_profile_compile/sources.nim`` has the ``(relative path,
## blake3) -> digest`` pipeline, which is mirrored here, but its scanner
## follows only ``import ./...`` and only the first module on a line, so
## consolidating onto it would LOSE coverage.
##
## ## Fail-closed
##
## ``PendingCacheIdentityOptionKey`` is stamped whenever ANY required
## input is unavailable: no project file, an unreadable source file, an
## unresolved candidate-local import or include, an unbindable
## compile-time read, a compile-time read this file's own declaration
## neither provably takes nor provably declines, a declared source input
## that does not exist or lives outside the project root, an effective
## search-root set that was never reconstructed or that names a
## directory which does not exist, unsolved options, unresolved
## dependency instances, a malformed dependency key, an unpopulated
## target triple, or a toolchain with no name/version. The marker makes
## ``deriveCacheEntryKey`` refuse, so an incomplete identity can neither
## look up nor publish a package. See ``docs/package-cache-identity.md``.
##
## ## Legacy constructor
##
## ``sourceCacheEntryIdentity(projectRoot, packageName, packageVersion,
## conventionTag)`` is retained for the call sites that cannot yet
## supply a solved instance (``dsl_port_runtime``, the DSL stdlib's
## ``nim.c`` alias and install-mirror stage-copy, the from-source
## conventions). It has no solved options, no resolved dependency
## instances and no detected toolchain version, so it stays PENDING by
## construction — the guard is unchanged for every production path that
## still uses it. Its ``providerRevision`` is now the full source-closure
## digest rather than the entry-file digest, so the diagnostic value it
## reports also moves when imported recipe code changes.
##
## This module deliberately accepts the selected package version as an
## argument. Provider/runtime layers own version selection; keeping that
## registry dependency out of this module lets both the standard provider
## and the Layer-1 package constructors share the exact same key logic.

import std/[algorithm, os, sets, strutils, tables]

import blake3
import repro_binary_cache_client/cache_key
import repro_binary_cache_server/types as bcs_types
import repro_core

type
  SourceClosure* = object
    ## The resolved local source closure of a project root.
    digestHex*: string
      ## BLAKE3 hex over the canonical ``(relative path, content
      ## digest)`` encoding. Empty when ``missing`` is non-empty.
    files*: seq[string]
      ## Project-relative paths of every file bound, sorted, with ``/``
      ## separators. Diagnostic; not part of the key beyond the digest.
    missing*: seq[string]
      ## Human-readable descriptions of evidence that could not be
      ## resolved. Non-empty means the closure is incomplete.

  SolvedSourceInstance* = object
    ## The complete solved instance a source package's cache identity is
    ## a function of. Every field is load-bearing: see the module
    ## docstring.
    projectRoot*: string
    packageName*: string
    packageVersion*: string
    declaredSourceInputs*: seq[string]
      ## Local non-Nim inputs the recipe consumes and the import scanner
      ## therefore cannot see: SDK/generator templates, ``.c``/``.rs``
      ## sources, data files, or whole directories. Project-relative
      ## paths (absolute paths are accepted and recorded relative to the
      ## project root so relocation stays stable; an absolute path
      ## OUTSIDE the project root is missing evidence, because there is
      ## no relocation-stable spelling for it).
    effectiveSearchRoots*: seq[string]
      ## The search roots of the EFFECTIVE compile command — every
      ## ``--path`` the compiler will actually be given, including the
      ## ones that leave no trace in any file this scanner can read: a
      ## ``--path`` on the command line, one contributed by a nimble
      ## dependency, one injected by a wrapper. Absolute or
      ## project-relative; a root that does not exist is REFUSED when
      ## ``searchRootsKnown`` is set, because the claim it forms part of
      ## is then demonstrably wrong. Roots OUTSIDE the project root are
      ## accepted and are resolution evidence only: a spec that resolves
      ## through one lands outside the project root and is therefore
      ## external code, bound through ``dependencyInstances`` rather
      ## than through this closure. The roots themselves never enter the
      ## digest — only the project-relative spelling of the files they
      ## reach does, which is what keeps relocation invariance when they
      ## are supplied as absolute paths.
    searchRootsKnown*: bool
      ## As with ``optionsSolved``: distinguishes "the effective compile
      ## command was reconstructed and contributes no roots beyond the
      ## ones this scanner can read" from "it was never reconstructed".
      ## Only the former can produce a key. Without it a module
      ## reachable only through an unseen ``--path`` is silently dropped
      ## and a digest is still produced, which is the Reprobuild #171
      ## aliasing class: two implementations, one key.
    selectedOptions*: seq[(string, string)]
    optionsSolved*: bool
      ## Distinguishes "solved to the empty set" from "not solved yet".
      ## Only the former can produce a key.
    dependencyInstances*: seq[string]
      ## 64-char cache-entry-key hexes of the dependency INSTANCES this
      ## instance was solved against.
    dependenciesResolved*: bool
      ## As with ``optionsSolved``: an empty-but-resolved closure is
      ## complete evidence; an unresolved one is not.
    platform*: bcs_types.PlatformTriple
    toolchain*: bcs_types.ToolchainIdentity

const
  SourceClosureDigestChars = 64
    ## Full BLAKE3-256 hex. The ``providerRevision`` field is an opaque
    ## hex string to the canonical encoder, so there is no reason to
    ## truncate the closure digest the way the legacy entry-file digest
    ## was truncated.

  NimSourceExts = [".nim", ".nims", ".inc"]

  CompileTimeFileReaders = ["staticRead", "slurp"]
    ## Compile-time file reads whose argument CAN be bound.

  CompileTimeCommandRunners = ["gorgeEx", "gorge", "staticExec"]
    ## Compile-time command executions whose output can NOT be bound.

proc cacheIdentityExtendedPath*(path: string): string =
  when defined(windows):
    if path.len == 0 or path.startsWith("\\\\"):
      path
    else:
      "\\\\?\\" & os.normalizedPath(absolutePath(path)).replace('/', '\\')
  else:
    path

# ---------------------------------------------------------------------------
# Path identity
# ---------------------------------------------------------------------------

proc normSlash(path: string): string =
  ## Normalised absolute-or-relative path with ``/`` separators and no
  ## trailing separator. Never turns the empty string into ``"."``.
  if path.len == 0:
    return ""
  result = os.normalizedPath(path).replace('\\', '/')
  while result.len > 1 and result.endsWith("/"):
    result.setLen(result.len - 1)

proc foldPathCase(path: string): string =
  ## Case folding is a PLATFORM fact here, not a convenience: NTFS
  ## resolves two spellings to one file, ext4 does not.
  when defined(windows):
    path.toLowerAscii()
  else:
    path

proc pathKey(path: string): string =
  ## De-duplication identity of a filesystem path.
  foldPathCase(normSlash(path))

proc sourceClosurePathKey*(path: string): string =
  ## The de-duplication identity of a path, exposed so the platform rule
  ## itself is testable rather than only its consequences. Case folding
  ## here is a PLATFORM fact: see ``foldPathCase``.
  pathKey(path)

proc projectRelative(root, path: string): tuple[inside: bool, rel: string] =
  ## ``(true, <root-relative, '/'-separated spelling>)`` when ``path``
  ## lies inside ``root``; ``(false, _)`` otherwise. Deliberately does
  ## NOT use ``os.relativePath``: on Windows that returns the ABSOLUTE
  ## path for a cross-drive pair instead of raising, which is how an
  ## absolute path used to reach the digest.
  let r = normSlash(root)
  let p = normSlash(path)
  if r.len == 0 or p.len == 0:
    return (false, p)
  let foldedR = foldPathCase(r)
  let foldedP = foldPathCase(p)
  if foldedP == foldedR:
    return (true, extractFilename(p))
  if foldedP.startsWith(foldedR & "/"):
    return (true, p[r.len + 1 .. ^1])
  (false, p)

# ---------------------------------------------------------------------------
# Source-text masking
# ---------------------------------------------------------------------------

proc maskNimNonCode(source: string): string =
  ## Blank every region Nim's parser does NOT read as code: ``#`` line
  ## comments, nestable ``#[ ]#`` / ``##[ ]##`` block comments and
  ## triple-quoted string literals. Blanked characters become spaces;
  ## newlines are preserved so line structure is unchanged.
  ##
  ## Ordinary single-line ``"..."`` (and ``r"..."``) literals and char
  ## literals are KEPT verbatim — ``import "./x"`` and the
  ## ``staticRead`` argument live in them.
  result = newStringOfCap(source.len)
  var i = 0
  let n = source.len
  template blank(ch: char) =
    result.add(if ch == '\n': '\n' else: ' ')
  while i < n:
    let ch = source[i]
    if ch == '#':
      let blockComment =
        (i + 1 < n and source[i + 1] == '[') or
        (i + 2 < n and source[i + 1] == '#' and source[i + 2] == '[')
      if blockComment:
        var depth = 0
        while i < n:
          if source[i] == '#' and i + 1 < n and source[i + 1] == '[':
            inc depth
            blank(source[i]); blank(source[i + 1]); i += 2
          elif source[i] == ']' and i + 1 < n and source[i + 1] == '#':
            dec depth
            blank(source[i]); blank(source[i + 1]); i += 2
            if depth <= 0:
              break
          else:
            blank(source[i]); inc i
      else:
        while i < n and source[i] != '\n':
          blank(source[i]); inc i
      continue
    if ch == '"':
      if i + 2 < n and source[i + 1] == '"' and source[i + 2] == '"':
        blank('"'); blank('"'); blank('"'); i += 3
        while i < n:
          if source[i] == '"' and i + 2 < n and source[i + 1] == '"' and
              source[i + 2] == '"':
            blank('"'); blank('"'); blank('"'); i += 3
            break
          blank(source[i]); inc i
        continue
      let raw = i > 0 and source[i - 1] in {'r', 'R'} and
        (i < 2 or source[i - 2] notin IdentChars)
      result.add(ch); inc i
      while i < n and source[i] != '\n':
        if not raw and source[i] == '\\' and i + 1 < n:
          result.add(source[i]); result.add(source[i + 1]); i += 2
          continue
        if source[i] == '"':
          if raw and i + 1 < n and source[i + 1] == '"':
            result.add(source[i]); result.add(source[i + 1]); i += 2
            continue
          result.add(source[i]); inc i
          break
        result.add(source[i]); inc i
      continue
    if ch == '\'' and (i == 0 or source[i - 1] notin IdentChars):
      result.add(ch); inc i
      while i < n and source[i] != '\n':
        if source[i] == '\\' and i + 1 < n:
          result.add(source[i]); result.add(source[i + 1]); i += 2
          continue
        if source[i] == '\'':
          result.add(source[i]); inc i
          break
        result.add(source[i]); inc i
      continue
    result.add(ch); inc i

# ---------------------------------------------------------------------------
# Nim import scanning
# ---------------------------------------------------------------------------

type
  ImportRef = object
    spec: string
    isInclude: bool

  CompileTimeReadKind = enum
    ctFileRead, ctCommand, ctAmbiguousShadow

  CompileTimeRead = object
    kind: CompileTimeReadKind
    fn: string
    literal: string
    hasLiteral: bool

proc splitTopLevelCommas(text: string): seq[string] =
  ## Split on commas that are not nested inside ``[]``.
  var depth = 0
  var current = ""
  for ch in text:
    case ch
    of '[':
      inc depth
      current.add(ch)
    of ']':
      if depth > 0: dec depth
      current.add(ch)
    of ',':
      if depth == 0:
        result.add(current)
        current = ""
      else:
        current.add(ch)
    else:
      current.add(ch)
  if current.strip().len > 0:
    result.add(current)

proc expandImportSpec(spec: string): seq[string] =
  ## Normalise one import item into zero or more module paths.
  ## Handles ``foo``, ``"foo"``, ``foo/bar``, ``std/[os, strutils]``,
  ## ``foo as bar`` and ``foo except bar``.
  var item = spec.strip()
  if item.len == 0:
    return
  # ``x as y`` / ``x except y`` — only the left-hand module matters.
  for keyword in [" as ", " except "]:
    let idx = item.find(keyword)
    if idx >= 0:
      item = item[0 ..< idx].strip()
  let openIdx = item.find('[')
  if openIdx >= 0:
    let closeIdx = item.rfind(']')
    if closeIdx > openIdx:
      var prefix = item[0 ..< openIdx].strip()
      if prefix.endsWith("/"):
        prefix = prefix[0 ..< prefix.len - 1]
      for inner in splitTopLevelCommas(item[openIdx + 1 ..< closeIdx]):
        let leaf = inner.strip().strip(chars = {'"'})
        if leaf.len == 0:
          continue
        result.add(if prefix.len > 0: prefix & "/" & leaf else: leaf)
      return
  item = item.strip(chars = {'"'})
  if item.len > 0:
    result.add(item)

proc importRefsOf(masked: string): seq[ImportRef] =
  ## Every module spec named by ``import`` / ``from ... import`` /
  ## ``include`` statements in MASKED Nim source, including the
  ## multi-line continuation forms, tagged with whether the statement
  ## was an ``include`` (which carries its own file extension and is
  ## textually inlined by Nim).
  var pending = ""
  var pendingDepth = 0
  var inStatement = false
  var isInclude = false
  for rawLine in masked.splitLines():
    let trimmed = rawLine.strip()
    if inStatement:
      if trimmed.len == 0:
        continue
      pending.add(" ")
      pending.add(trimmed)
    else:
      var body = ""
      if trimmed == "import" or trimmed.startsWith("import "):
        body = trimmed[min(6, trimmed.len) .. ^1]
        isInclude = false
      elif trimmed == "include" or trimmed.startsWith("include "):
        body = trimmed[min(7, trimmed.len) .. ^1]
        isInclude = true
      elif trimmed.startsWith("from "):
        let rest = trimmed[5 .. ^1]
        let idx = rest.find(" import")
        body = if idx >= 0: rest[0 ..< idx] else: rest
        isInclude = false
      else:
        continue
      pending = body.strip()
      pendingDepth = 0
      inStatement = true
    for ch in trimmed:
      if ch == '[': inc pendingDepth
      elif ch == ']' and pendingDepth > 0: dec pendingDepth
    # A statement continues while a bracket group is open, while the
    # accumulated text ends in a comma, or while the keyword line
    # carried no module at all (Nim's multi-line ``import`` form).
    if pendingDepth > 0 or pending.strip().endsWith(",") or
        pending.strip().len == 0:
      continue
    for item in splitTopLevelCommas(pending):
      for spec in expandImportSpec(item):
        result.add(ImportRef(spec: spec, isInclude: isInclude))
    pending = ""
    pendingDepth = 0
    inStatement = false

proc stringLiteralAt(text: string; start: int):
    tuple[found: bool, value: string] =
  ## Read the string literal that begins at the first non-``(``,
  ## non-space character at or after ``start``. ``found`` is false when
  ## the argument is not a single-line string literal (a ``const``, a
  ## concatenation, an expression) — which is exactly the case the
  ## caller must fail closed on.
  var i = start
  while i < text.len and text[i] in {' ', '\t', '('}:
    inc i
  var raw = false
  if i + 1 < text.len and text[i] in {'r', 'R'} and text[i + 1] == '"':
    raw = true
    inc i
  if i >= text.len or text[i] != '"':
    return (false, "")
  inc i
  var value = ""
  while i < text.len and text[i] != '\n':
    if not raw and text[i] == '\\' and i + 1 < text.len:
      case text[i + 1]
      of '\\': value.add('\\')
      of '"': value.add('"')
      of 'n': value.add('\n')
      of 't': value.add('\t')
      else: value.add(text[i + 1])
      i += 2
      continue
    if text[i] == '"':
      if raw and i + 1 < text.len and text[i + 1] == '"':
        value.add('"')
        i += 2
        continue
      return (true, value)
    value.add(text[i])
    inc i
  (false, "")

proc identOccurrences(text, ident: string): seq[int] =
  ## Offsets of ``ident`` occurring as a whole identifier.
  var start = 0
  while true:
    let idx = text.find(ident, start)
    if idx < 0:
      break
    start = idx + ident.len
    let beforeOk = idx == 0 or text[idx - 1] notin IdentChars
    let afterOk = start >= text.len or text[start] notin IdentChars
    if beforeOk and afterOk:
      result.add(idx)

proc blankKeptStringLiterals(masked: string): string =
  ## ``masked`` with the delimiters and CONTENT of every kept
  ## single-line string / char literal replaced by spaces, and with the
  ## length and every newline position preserved so an offset in the
  ## result indexes the same character in ``masked``.
  ##
  ## Existence reason: the compile-time-read scan must not see the word
  ## ``slurp`` inside ``echo "slurp the file"``. It cannot simply run on
  ## a fully string-masked text either, because the ``staticRead``
  ## ARGUMENT is a string literal — so occurrences are FOUND here and
  ## their argument is then read from ``masked`` at the same offset.
  result = newStringOfCap(masked.len)
  var i = 0
  let n = masked.len
  template blank(ch: char) =
    result.add(if ch == '\n': '\n' else: ' ')
  while i < n:
    let ch = masked[i]
    if ch == '"':
      let raw = i > 0 and masked[i - 1] in {'r', 'R'} and
        (i < 2 or masked[i - 2] notin IdentChars)
      blank(ch); inc i
      while i < n and masked[i] != '\n':
        if not raw and masked[i] == '\\' and i + 1 < n:
          blank(masked[i]); blank(masked[i + 1]); i += 2
          continue
        if masked[i] == '"':
          if raw and i + 1 < n and masked[i + 1] == '"':
            blank(masked[i]); blank(masked[i + 1]); i += 2
            continue
          blank(masked[i]); inc i
          break
        blank(masked[i]); inc i
      continue
    if ch == '\'' and (i == 0 or masked[i - 1] notin IdentChars):
      blank(ch); inc i
      while i < n and masked[i] != '\n':
        if masked[i] == '\\' and i + 1 < n:
          blank(masked[i]); blank(masked[i + 1]); i += 2
          continue
        if masked[i] == '\'':
          blank(masked[i]); inc i
          break
        blank(masked[i]); inc i
      continue
    result.add(ch); inc i

proc leadingIndent(line: string): int =
  while result < line.len and line[result] in {' ', '\t'}:
    inc result

type
  LocalDeclKind = enum
    ldRoutine, ldValue

  LocalDecl = object
    kind: LocalDeclKind
    nameOffset: int
      ## Offset of the declared name in ``scanned``, so the declaration
      ## itself is never mistaken for a use of the symbol, and so a
      ## declaration can be told apart from one that comes textually
      ## AFTER a given call and therefore does not exist there yet.
    indent: int
      ## Leading indentation of the declaring line. Only a declaration
      ## at column 0 is at module scope; anything deeper is nested in a
      ## routine body or under a ``when`` branch this scanner cannot
      ## evaluate, which makes the file's overload set undecidable.
    params: string
      ## Raw parameter-list text of a routine, without the enclosing
      ## parentheses. Empty for a routine declared with no parameter
      ## list and for ``ldValue``.
    paramsKnown: bool
      ## False when the parameter list could not be read in full (it
      ## spans lines, or the group never closes) — the declaration is
      ## then undecidable rather than empty.

  ParamTypeClass = enum
    ptString, ptNotString, ptUnknown

  ArgFit = enum
    afAccepts, afRejects, afUnknown

  CallShape = object
    isCall: bool
    argCount: int
    argCountKnown: bool

proc routineNameEnd(line: string; start: int; ident: string): int =
  ## Offset just past ``ident`` when ``line`` spells it as a whole
  ## identifier at ``start`` (optionally backtick-quoted); -1 otherwise.
  if line.len > start and line[start] == '`':
    if line.continuesWith("`" & ident & "`", start):
      return start + ident.len + 2
    return -1
  if not line.continuesWith(ident, start):
    return -1
  let after = start + ident.len
  if after < line.len and line[after] in IdentChars:
    return -1
  after

proc declaredNamePos(line: string; start: int; ident: string): int =
  ## Offset of ``ident`` in ``line`` when the text at ``start`` declares
  ## it — the same shape ``startsWithIdent`` recognises, but reported by
  ## position so the declaration can be told apart from a use.
  var i = start
  while i < line.len and line[i] in {' ', '\t'}:
    inc i
  let after = routineNameEnd(line, i, ident)
  if after < 0:
    return -1
  var j = after
  while j < line.len and line[j] in {' ', '\t'}:
    inc j
  if j >= line.len or line[j] in {'*', '(', '[', ':', '=', ',', '{'}:
    return i
  -1

proc routineParamsAt(line: string; nameEnd: int):
    tuple[params: string, known: bool] =
  ## The parameter-list text of a routine whose name ends at ``nameEnd``
  ## on ``line``. ``known`` is false when a bracket group opens and does
  ## not close on this line, which makes the declaration undecidable
  ## rather than parameterless.
  var i = nameEnd
  while i < line.len and line[i] in {' ', '\t'}:
    inc i
  if i < line.len and line[i] == '*':
    inc i
    while i < line.len and line[i] in {' ', '\t'}:
      inc i
  if i < line.len and line[i] == '[':
    var depth = 0
    var closed = false
    while i < line.len:
      if line[i] == '[': inc depth
      elif line[i] == ']':
        dec depth
        if depth == 0:
          inc i
          closed = true
          break
      inc i
    if not closed:
      return ("", false)
    while i < line.len and line[i] in {' ', '\t'}:
      inc i
  if i >= line.len or line[i] != '(':
    # ``proc slurp: string = ...`` / ``template slurp = ...``: a
    # declaration with no parameter list at all, which IS decidable.
    return ("", true)
  var depth = 0
  let start = i + 1
  while i < line.len:
    case line[i]
    of '(', '[', '{': inc depth
    of ')', ']', '}':
      dec depth
      if depth == 0:
        return (line[start ..< i], true)
    else: discard
    inc i
  ("", false)

proc localDeclarationsOf(scanned, ident: string): seq[LocalDecl] =
  ## Every declaration of ``ident`` THIS file makes — routines, and
  ## ``let`` / ``var`` / ``const`` / ``type`` entries in either their
  ## one-line or their indented-block form.
  ##
  ## ``scanned`` must be ``blankKeptStringLiterals`` output, so the word
  ## ``proc slurp`` inside a string literal declares nothing, and so the
  ## recorded offsets index the same characters the occurrence scan
  ## walks.
  const RoutineKeywords = ["proc", "func", "template", "macro", "method",
                           "iterator", "converter"]
  const SectionKeywords = ["let", "var", "const", "type"]
  var sectionIndent = -1
  var lineStart = 0
  # The lines are cut by hand rather than with ``splitLines`` because the
  # recorded offsets must index ``scanned`` exactly: ``splitLines`` drops
  # a ``\r\n`` pair as ONE separator, so a byte counter driven by it
  # drifts by a byte on every CRLF line and the declaration offsets stop
  # matching the occurrence offsets.
  while lineStart <= scanned.len:
    var scan = lineStart
    while scan < scanned.len and scanned[scan] != '\n':
      inc scan
    var lineEnd = scan
    if lineEnd > lineStart and scanned[lineEnd - 1] == '\r':
      dec lineEnd
    let rawLine = scanned[lineStart ..< lineEnd]
    let nextStart = scan + 1
    block processLine:
      let indent = leadingIndent(rawLine)
      let stripped = rawLine.strip()
      if stripped.len == 0:
        break processLine
      if sectionIndent >= 0:
        if indent > sectionIndent:
          let pos = declaredNamePos(rawLine, indent, ident)
          if pos >= 0:
            result.add(LocalDecl(kind: ldValue, indent: indent,
              nameOffset: lineStart + pos))
          break processLine
        sectionIndent = -1
      for keyword in RoutineKeywords:
        if rawLine.continuesWith(keyword & " ", indent):
          let pos = declaredNamePos(rawLine, indent + keyword.len + 1, ident)
          if pos >= 0:
            let nameEnd = routineNameEnd(rawLine, pos, ident)
            let parsed = routineParamsAt(rawLine, nameEnd)
            result.add(LocalDecl(kind: ldRoutine, indent: indent,
              nameOffset: lineStart + pos,
              params: parsed.params, paramsKnown: parsed.known))
      for keyword in SectionKeywords:
        if stripped == keyword:
          sectionIndent = indent
        elif rawLine.continuesWith(keyword & " ", indent):
          let pos = declaredNamePos(rawLine, indent + keyword.len + 1, ident)
          if pos >= 0:
            result.add(LocalDecl(kind: ldValue, indent: indent,
              nameOffset: lineStart + pos))
    if scan >= scanned.len:
      break
    lineStart = nextStart

proc splitParamItems(params: string): seq[string] =
  ## Split a parameter list on the separators Nim allows between
  ## parameters (``,`` and ``;``), ignoring separators nested inside
  ## brackets. Kept string literals are blanked in the text this runs
  ## on, so a separator inside one cannot be seen.
  var depth = 0
  var current = ""
  for ch in params:
    case ch
    of '[', '(', '{':
      inc depth
      current.add(ch)
    of ']', ')', '}':
      dec depth
      current.add(ch)
    of ',', ';':
      if depth == 0:
        result.add(current)
        current = ""
      else:
        current.add(ch)
    else: current.add(ch)
  result.add(current)

proc topLevelCharIndex(text: string; sep: char): int =
  ## Offset of the first ``sep`` at bracket depth 0; -1 when there is
  ## none.
  var depth = 0
  for i, ch in text:
    case ch
    of '[', '(', '{': inc depth
    of ']', ')', '}': dec depth
    else:
      if ch == sep and depth == 0:
        return i
  -1

proc routineParamInfo(params: string; known: bool):
    tuple[ok: bool, minArity, maxArity: int, variadic: bool,
          firstType: string] =
  ## Arity and first-parameter type of a parameter list. ``ok`` is false
  ## when the list cannot be read, which makes the declaration
  ## undecidable rather than empty.
  if not known:
    return (false, 0, 0, false, "")
  if params.strip().len == 0:
    return (true, 0, 0, false, "")
  var types: seq[string] = @[]
  var defaulted: seq[bool] = @[]
  var pendingNames = 0
  for item in splitParamItems(params):
    let text = item.strip()
    if text.len == 0:
      if pendingNames > 0:
        return (false, 0, 0, false, "")
      continue
    let colon = topLevelCharIndex(text, ':')
    let eq = topLevelCharIndex(text, '=')
    if colon < 0 and eq < 0:
      # A bare name sharing the next group's type annotation.
      inc pendingNames
      continue
    if colon < 0 or (eq >= 0 and eq < colon):
      # ``name = default`` with the type inferred: undecidable here.
      return (false, 0, 0, false, "")
    let rest =
      if eq > colon: text[colon + 1 ..< eq]
      else: text[colon + 1 .. ^1]
    let typeText = rest.strip()
    let withDefault = eq > colon
    for _ in 0 .. pendingNames:
      types.add(typeText)
      defaulted.add(withDefault)
    pendingNames = 0
  if pendingNames > 0:
    return (false, 0, 0, false, "")
  var minArity = 0
  var variadic = false
  for i, t in types:
    if t.startsWith("varargs"):
      variadic = true
    elif not defaulted[i]:
      minArity = i + 1
  (true, minArity, types.len, variadic,
   if types.len > 0: types[0] else: "")

proc classifyParamType(typeText: string): ParamTypeClass =
  ## Can a STRING LITERAL be passed to a parameter of this type?
  ##
  ## Only an exact ``string`` is ``ptString``. Measured against nim
  ## 2.2.8: a local ``proc slurp(label: string)`` wins the overload over
  ## ``system.slurp`` and the call reads nothing, while a local
  ## ``proc slurp(n: int)`` loses it and the call DOES read the file.
  ## Every type that is neither exactly ``string`` nor one of the
  ## scalars a string literal provably cannot convert to is
  ## ``ptUnknown``, because a weaker match (a generic parameter, a type
  ## reachable by ``converter``, an ``untyped`` template parameter) may
  ## or may not beat ``system``'s exact one — and an undecided overload
  ## must refuse rather than ignore.
  const NotString = ["int", "int8", "int16", "int32", "int64", "uint",
                     "uint8", "uint16", "uint32", "uint64", "float",
                     "float32", "float64", "bool", "char", "byte",
                     "Natural", "Positive", "pointer"]
  var text = typeText.strip()
  for prefix in ["sink ", "lent ", "var "]:
    if text.startsWith(prefix):
      text = text[prefix.len .. ^1].strip()
  if text == "string":
    return ptString
  if text in NotString:
    return ptNotString
  ptUnknown

proc routineFit(decl: LocalDecl; argCount: int;
                firstArgIsStringLiteral: bool): ArgFit =
  ## Can a call with ``argCount`` arguments bind to this declaration?
  let info = routineParamInfo(decl.params, decl.paramsKnown)
  if not info.ok:
    return afUnknown
  if argCount < info.minArity:
    return afRejects
  if argCount > info.maxArity and not info.variadic:
    return afRejects
  if argCount == 0:
    return afAccepts
  if not firstArgIsStringLiteral:
    return afUnknown
  case classifyParamType(info.firstType)
  of ptString: afAccepts
  of ptNotString: afRejects
  of ptUnknown: afUnknown

proc callShapeAt(scanned, masked: string; start: int): CallShape =
  ## Whether the identifier ending at ``start`` is CALLED there, and
  ## with how many arguments. ``scanned`` has kept string literals
  ## blanked, so a bracket or comma inside one cannot be counted;
  ## ``masked`` still carries them, so command syntax (``slurp "x"``)
  ## stays detectable.
  var i = start
  while i < scanned.len and scanned[i] in {' ', '\t'}:
    inc i
  if i >= scanned.len or scanned[i] == '\n':
    return CallShape(isCall: false, argCountKnown: true)
  if scanned[i] == '(':
    var depth = 0
    var commas = 0
    var body = 0
    var j = i
    while j < scanned.len:
      case scanned[j]
      of '(', '[', '{': inc depth
      of ')', ']', '}':
        dec depth
        if depth == 0:
          let count = if body == 0: 0 else: commas + 1
          return CallShape(isCall: true, argCount: count, argCountKnown: true)
      of ',':
        if depth == 1: inc commas
      else: discard
      # Argument CONTENT is read from ``masked``: a string-literal
      # argument is BLANKED in ``scanned``, so counting non-blank
      # characters there would read ``slurp("x")`` as a nullary call
      # and reject it against every one-parameter local overload.
      if j > i and depth >= 1 and masked[j] notin Whitespace:
        inc body
      inc j
    return CallShape(isCall: true, argCountKnown: false)
  if masked[i] == '"' or
      (masked[i] in {'r', 'R'} and i + 1 < masked.len and
       masked[i + 1] == '"'):
    # Command syntax: ``slurp "path"``. Arguments run comma-separated to
    # the end of the line, and the literals are blanked in ``scanned``.
    var commas = 0
    var depth = 0
    var j = i
    while j < scanned.len and scanned[j] != '\n':
      case scanned[j]
      of '(', '[', '{': inc depth
      of ')', ']', '}': dec depth
      of ',':
        if depth == 0: inc commas
      else: discard
      inc j
    return CallShape(isCall: true, argCount: commas + 1, argCountKnown: true)
  if scanned[i] in IdentChars or scanned[i] == '`':
    # Command syntax with an argument that is not a literal.
    return CallShape(isCall: true, argCountKnown: false)
  CallShape(isCall: false, argCountKnown: true)

proc qualifierBefore(scanned: string; idx: int): string =
  ## The module/expression qualifier of the identifier at ``idx``, i.e.
  ## ``system`` for ``system.slurp``; ``""`` when unqualified.
  if idx == 0 or scanned[idx - 1] != '.':
    return ""
  var start = idx - 1
  while start > 0 and scanned[start - 1] in IdentChars:
    dec start
  scanned[start ..< idx - 1]

proc shadowVerdict(decls: seq[LocalDecl]; scanned, masked: string;
                   idx, identLen: int;
                   firstArgIsStringLiteral: bool): ArgFit =
  ## Does THIS file's own declaration capture THIS occurrence?
  ##
  ## ``afAccepts`` — yes: the occurrence is the local symbol and binds
  ## nothing. ``afRejects`` — no local declaration can take this call,
  ## so it reaches ``system``'s compile-time read. ``afUnknown`` — the
  ## text does not decide it, which is missing evidence and refuses.
  ##
  ## The rule is per CALL, not per FILE, and that is the whole point.
  ## A declaration counts against a call only where the COMPILER would
  ## apply it: at module scope (column 0), textually BEFORE the call.
  ## Measured against nim 2.2.8, every one of these READS the payload
  ## even though the file declares ``proc slurp(label: string)``: the
  ## declaration placed after the call, the declaration nested inside
  ## another routine's body, the declaration under ``when false:``, and
  ## the declaration under ``when defined(flagNeverSet):``. A per-file
  ## declaration table applied to every occurrence ignored all four and
  ## produced a key that did not move with the payload — an ALIAS.
  ## Measured against nim 2.2.8: ``proc slurp(n: int)`` does NOT stop
  ## ``slurp("payload.txt")`` compiling to ``system.slurp`` and reading
  ## the file, and a non-routine declaration (``const gorge = 3``,
  ## ``var slurp = 3``) does not stop a CALL reaching the stdlib symbol
  ## at all. A per-file exclusion therefore dropped genuine
  ## compile-time reads out of the closure and ALIASED — the one
  ## failure this identity may not have.
  let shape = callShapeAt(scanned, masked, idx + identLen)
  if not shape.isCall:
    # A bare mention is not a read. ``const entry = gorge`` names this
    # file's own ``gorge`` (measured), and even where it named
    # ``system``'s it would read nothing by itself.
    return afAccepts
  if not shape.argCountKnown:
    return afUnknown
  var verdict = afRejects
  var undecidable = false
  for decl in decls:
    if decl.kind != ldRoutine:
      # Not overloadable and never a call target: measured, a local
      # ``const`` / ``var`` / ``let`` / ``type`` leaves ``system``'s
      # routine reachable for a call — at module scope and from inside
      # a nested body alike (measured: an ``outer`` body declaring
      # ``const slurp = 3`` still reads the payload at module scope).
      continue
    if decl.nameOffset >= idx:
      # Declared AFTER this call. Nim resolves in textual order, so the
      # declaration does not exist yet here and the call is the
      # stdlib's — measured, ``const blob = slurp("payload.txt")``
      # followed by ``proc slurp(label: string)`` READS the file.
      continue
    if decl.indent > 0:
      # Not at module scope. It is nested in another routine's body, or
      # under a ``when`` branch whose liveness this scanner cannot
      # evaluate. Measured, all three of those shapes leave
      # ``system.slurp`` reachable at the module-scope call — but a
      # LIVE ``when`` branch would not, and the text does not say which
      # this is. The file's overload set is therefore undecidable, and
      # undecidable REFUSES; it must not ignore.
      undecidable = true
      continue
    case routineFit(decl, shape.argCount, firstArgIsStringLiteral)
    of afAccepts: return afAccepts
    of afUnknown: verdict = afUnknown
    of afRejects: discard
  if undecidable: afUnknown else: verdict

proc compileTimeReadsOf(masked: string): seq[CompileTimeRead] =
  ## Every compile-time file read / command execution in MASKED source.
  ## These have no import syntax at all, so without this the bytes they
  ## fold into the build are invisible to the closure.
  ##
  ## Still a textual scan rather than a parse, but no longer a bare
  ## identifier grep: an occurrence inside a kept string literal is data
  ## rather than code, a DECLARATION of the identifier is not a use of
  ## it, and a call this file's OWN overload provably takes is that
  ## overload rather than the stdlib's. What the text does not decide —
  ## a call whose argument is not a literal, a local overload whose
  ## parameter type this scanner does not recognise, a parameter list
  ## that spans lines — is missing evidence and refuses. A QUALIFIED
  ## occurrence (``system.slurp``, ``mymod.slurp``) is never excluded by
  ## shadowing.
  let scanned = blankKeptStringLiterals(masked)
  for fn in @CompileTimeFileReaders & @CompileTimeCommandRunners:
    let isFileRead = fn in CompileTimeFileReaders
    let decls = localDeclarationsOf(scanned, fn)
    var declOffsets = initHashSet[int]()
    for decl in decls:
      declOffsets.incl(decl.nameOffset)
    for idx in identOccurrences(scanned, fn):
      if idx in declOffsets:
        continue
      let arg = stringLiteralAt(masked, idx + fn.len)
      if decls.len > 0 and qualifierBefore(scanned, idx).len == 0:
        case shadowVerdict(decls, scanned, masked, idx, fn.len, arg.found)
        of afAccepts: continue
        of afUnknown:
          result.add(CompileTimeRead(kind: ctAmbiguousShadow, fn: fn))
          continue
        of afRejects: discard
      if isFileRead:
        result.add(CompileTimeRead(kind: ctFileRead, fn: fn,
          literal: arg.value, hasLiteral: arg.found))
      else:
        result.add(CompileTimeRead(kind: ctCommand, fn: fn))

proc isExternalModuleSpec(spec: string): bool =
  spec.len == 0 or spec == "system" or spec == "std" or spec == "pkg" or
    spec.startsWith("std/") or spec.startsWith("pkg/")

proc hasNimSourceExt(spec: string): bool =
  spec.splitFile().ext.toLowerAscii() in NimSourceExts

# ---------------------------------------------------------------------------
# Search roots
# ---------------------------------------------------------------------------

proc addSearchRoot(roots: var seq[string]; projectRoot, base, value: string) =
  ## Record ``value`` (relative to ``base``) as a search root when it is
  ## an existing directory INSIDE ``projectRoot``. A ``--path`` pointing
  ## outside the project names external code, which is bound through
  ## ``dependencyInstances``, not through this closure.
  if value.len == 0:
    return
  let abs = normSlash(if value.isAbsolute: value else: base / value)
  if not dirExists(cacheIdentityExtendedPath(abs)):
    return
  if not projectRelative(projectRoot, abs).inside:
    return
  for existing in roots:
    if pathKey(existing) == pathKey(abs):
      return
  roots.add(abs)

proc addSuppliedSearchRoot(roots: var seq[string]; base, value: string) =
  ## Record a search root the CALLER supplied from the effective compile
  ## command. Two things differ from ``addSearchRoot``:
  ##
  ##   * it is NOT restricted to the project root. A ``--path`` into a
  ##     nimble dependency or a sibling checkout is a legitimate
  ##     effective root; a spec that resolves through one lands outside
  ##     the project root and the closure walk then classifies it as
  ##     external code (bound through ``dependencyInstances``) instead
  ##     of digesting it. Refusing such a root would make every real
  ##     compile command unkeyable;
  ##   * a root that does not exist on disk contributes nothing HERE
  ##     (there is nothing to search), but it is not thereby harmless:
  ##     ``sourceIdentity`` REFUSES on it, because a caller asserting
  ##     the effective root set and naming an absent directory has given
  ##     demonstrably wrong evidence about the compile command.
  ##
  ## The root itself never enters the digest. Only the project-relative
  ## spelling of the files it reaches does, so supplying absolute roots
  ## cannot break relocation invariance.
  if value.len == 0:
    return
  let abs = normSlash(if value.isAbsolute: value else: base / value)
  if not dirExists(cacheIdentityExtendedPath(abs)):
    return
  for existing in roots:
    if pathKey(existing) == pathKey(abs):
      return
  roots.add(abs)

proc expandConfigValue(value, configDir: string): string =
  result = value
  for token in ["$projectDir", "$projectPath", "$config", "$projectdir",
                "$projectpath"]:
    result = result.replace(token, configDir)
  result = result.replace('\\', '/')

proc parseConfigPaths(configText, configDir, projectRoot: string;
                      roots: var seq[string]; dynamic: var bool) =
  ## Collect ``--path`` search roots declared by one config file.
  ## ``dynamic`` is set when a path switch is present whose argument
  ## this scanner cannot evaluate — the search-root set is then UNKNOWN
  ## and every unresolved spec must be treated as possibly local.
  for rawLine in configText.splitLines():
    var line = rawLine
    let hashIdx = line.find('#')
    if hashIdx >= 0:
      line = line[0 ..< hashIdx]
    line = line.strip()
    if line.len == 0:
      continue
    var arg = ""
    var quotedOnly = false
    var found = false
    if line.startsWith("switch("):
      var body = line[line.find('(') + 1 .. ^1]
      let closeIdx = body.rfind(')')
      if closeIdx >= 0:
        body = body[0 ..< closeIdx]
      let parts = splitTopLevelCommas(body)
      if parts.len >= 2:
        let key = parts[0].strip().strip(chars = {'"'})
        if key == "path" or key == "p":
          arg = parts[1].strip()
          quotedOnly = true
          found = true
    else:
      for prefix in ["--path", "--p", "-p", "path"]:
        if line.startsWith(prefix) and line.len > prefix.len and
            line[prefix.len] in {':', '='}:
          arg = line[prefix.len + 1 .. ^1].strip()
          found = true
          break
    if not found:
      continue
    var literal = ""
    var isLiteral = false
    if arg.len >= 2 and arg.startsWith("\"") and arg.endsWith("\""):
      literal = arg[1 ..< arg.len - 1]
      isLiteral = true
    elif not quotedOnly and arg.len > 0 and '&' notin arg and
        '(' notin arg and '"' notin arg:
      literal = arg
      isLiteral = true
    if not isLiteral:
      dynamic = true
      continue
    let expanded = expandConfigValue(literal, configDir)
    if '$' in expanded or expanded.len == 0:
      dynamic = true
      continue
    addSearchRoot(roots, projectRoot, configDir, expanded)

proc parseNimbleSrcDir(nimbleText: string): string =
  for rawLine in nimbleText.splitLines():
    var line = rawLine
    let hashIdx = line.find('#')
    if hashIdx >= 0:
      line = line[0 ..< hashIdx]
    line = line.strip()
    if not line.startsWith("srcDir"):
      continue
    let eq = line.find('=')
    if eq < 0:
      continue
    let value = line[eq + 1 .. ^1].strip().strip(chars = {'"'})
    if value.len > 0:
      return value
  ""

proc collectSearchRoots(projectRoot, entryPath: string;
                        suppliedSearchRoots: seq[string];
                        roots: var seq[string]; dynamic: var bool) =
  addSearchRoot(roots, projectRoot, projectRoot, projectRoot)
  var configNames = @["nim.cfg", "config.nims"]
  if entryPath.len > 0:
    let stem = entryPath.splitFile().name
    configNames.add(stem & ".nim.cfg")
    configNames.add(stem & ".nims")
  for name in configNames:
    let path = projectRoot / name
    if not fileExists(cacheIdentityExtendedPath(path)):
      continue
    var text = ""
    try:
      text = readFile(cacheIdentityExtendedPath(path))
    except CatchableError:
      # A config file we cannot read is a search-root set we cannot know.
      dynamic = true
      continue
    parseConfigPaths(text, projectRoot, projectRoot, roots, dynamic)
  var nimbleFiles: seq[string] = @[]
  try:
    for kind, child in walkDir(projectRoot):
      if kind in {pcFile, pcLinkToFile} and child.toLowerAscii.endsWith(".nimble"):
        nimbleFiles.add(child)
  except CatchableError:
    discard
  nimbleFiles.sort(cmp)
  for nimbleFile in nimbleFiles:
    var text = ""
    try:
      text = readFile(cacheIdentityExtendedPath(nimbleFile))
    except CatchableError:
      dynamic = true
      continue
    let srcDir = parseNimbleSrcDir(text)
    if srcDir.len > 0:
      addSearchRoot(roots, projectRoot, projectRoot, srcDir)
  # Last, because Nim processes its config files before the command
  # line and ``resolveSpec`` walks the roots in order: a module present
  # under both a config root and a supplied one resolves the way the
  # compiler resolves it.
  for supplied in suppliedSearchRoots:
    addSuppliedSearchRoot(roots, projectRoot, supplied)

# ---------------------------------------------------------------------------
# Spec resolution
# ---------------------------------------------------------------------------

proc specCandidates(base, spec: string; isInclude: bool): seq[string] =
  let joined = normSlash(if spec.isAbsolute: spec else: base / spec)
  if joined.len == 0:
    return
  # An ``include`` spec, and any spec carrying a Nim source extension,
  # names a file literally. Appending ``.nim`` to it (as this scanner
  # used to, unconditionally) drops it.
  if hasNimSourceExt(spec) or (isInclude and spec.splitFile().ext.len > 0):
    result.add(joined)
  result.add(joined & ".nim")
  result.add(joined & ".nims")
  # Package-directory import: ``import pkgdir`` -> ``pkgdir/pkgdir.nim``.
  let leaf = joined.lastPathPart
  if leaf.len > 0:
    result.add(joined & "/" & leaf & ".nim")

proc resolveSpec(spec: string; isInclude: bool; fromDir: string;
                 searchRoots: seq[string]): string =
  var bases: seq[string] = @[]
  if spec.isAbsolute:
    bases.add("")
  elif spec.startsWith("./") or spec.startsWith("../"):
    bases.add(fromDir)
  else:
    bases.add(fromDir)
    for root in searchRoots:
      if pathKey(root) != pathKey(fromDir):
        bases.add(root)
  for base in bases:
    for candidate in specCandidates(base, spec, isInclude):
      if fileExists(cacheIdentityExtendedPath(candidate)):
        return candidate
  ""

proc isCandidateLocalSpec(spec: string; isInclude: bool; fromDir: string;
                          searchRoots: seq[string];
                          dynamicSearchPath: bool): bool =
  ## See the module docstring, "External library vs unresolvable local
  ## module". True means "this could be project source" and therefore
  ## must refuse rather than be dropped.
  if spec.startsWith("./") or spec.startsWith("../") or spec.isAbsolute:
    return true
  if isInclude:
    return true
  if hasNimSourceExt(spec):
    return true
  if dynamicSearchPath:
    return true
  let firstSegment = spec.split('/')[0]
  if firstSegment.len == 0:
    return true
  var bases = @[fromDir]
  for root in searchRoots:
    if pathKey(root) != pathKey(fromDir):
      bases.add(root)
  for base in bases:
    if dirExists(cacheIdentityExtendedPath(base / firstSegment)):
      return true
    for ext in [".nim", ".nims"]:
      if fileExists(cacheIdentityExtendedPath(base / firstSegment & ext)):
        return true
  false

# ---------------------------------------------------------------------------
# Closure walk
# ---------------------------------------------------------------------------

proc readClosureFile(path: string; body: var string): bool =
  try:
    body = readFile(cacheIdentityExtendedPath(path))
    true
  except CatchableError:
    false

proc collectDeclaredInput(projectRoot, declared: string;
                          paths: var seq[string]): bool =
  ## Expand one declared source input into concrete file paths. Returns
  ## false when the declared input does not exist (fail closed).
  let resolved =
    if declared.isAbsolute: normSlash(declared)
    else: normSlash(projectRoot / declared)
  if fileExists(cacheIdentityExtendedPath(resolved)):
    paths.add(resolved)
    return true
  if dirExists(cacheIdentityExtendedPath(resolved)):
    var found: seq[string] = @[]
    for entry in walkDirRec(resolved, relative = false):
      found.add(normSlash(entry))
    found.sort(cmp)
    for entry in found:
      paths.add(entry)
    return true
  false

proc solvedSourceClosure*(projectRoot: string;
                          declaredSourceInputs: seq[string] = @[];
                          effectiveSearchRoots: seq[string] = @[]):
    SourceClosure =
  ## Resolve the complete local source closure of ``projectRoot``.
  ##
  ## ``effectiveSearchRoots`` are the ``--path`` roots of the effective
  ## compile command — the ones no config scan can see. Supplying them
  ## is what closes the command-line ``--path`` aliasing channel; the
  ## REFUSAL when they were never reconstructed lives in
  ## ``sourceIdentity``, because this proc also backs the diagnostic
  ## ``sourceProviderRevisionHex``, which has no instance to refuse on.
  ##
  ## Walks the entry project file's transitive ``import`` / ``from`` /
  ## ``include`` graph across every search root the project declares,
  ## folds in every compile-time file read, and adds every declared
  ## non-Nim source input. Any input that could be project source but
  ## cannot be resolved lands in ``missing`` and suppresses the digest,
  ## so callers fail closed rather than keying over partial data. See
  ## the module docstring for the external-vs-local rule.
  var missing: seq[string] = @[]
  let root =
    if projectRoot.len == 0: ""
    else:
      try: normSlash(absolutePath(projectRoot))
      except CatchableError: normSlash(projectRoot)
  if root.len == 0:
    missing.add("project root is empty")
    return SourceClosure(missing: missing)

  var entryPath = ""
  try:
    entryPath = resolveProjectFile(root).path
  except CatchableError as e:
    missing.add("project file is unresolvable: " & e.msg)
  if missing.len == 0 and entryPath.len == 0:
    missing.add("project file in " & root)

  var searchRoots: seq[string] = @[]
  var dynamicSearchPath = false
  collectSearchRoots(root, entryPath, effectiveSearchRoots, searchRoots,
    dynamicSearchPath)

  var contentByRel = initTable[string, string]()
  var queued = initHashSet[string]()
  var pending: seq[tuple[path: string, scan: bool]] = @[]

  if entryPath.len > 0:
    let normalizedEntry = normSlash(absolutePath(entryPath))
    pending.add((normalizedEntry, true))
    queued.incl(pathKey(normalizedEntry))

  while pending.len > 0:
    let current = pending.pop()
    var body = ""
    let located = projectRelative(root, current.path)
    if not located.inside:
      missing.add("source file outside the project root " & current.path)
      continue
    let rel = located.rel
    if not readClosureFile(current.path, body):
      missing.add("unreadable source file " & rel)
      continue
    contentByRel[rel] = blake3.toHex(blake3.digest(body))
    if not current.scan:
      continue
    let fromDir = normSlash(parentDir(current.path))
    let masked = maskNimNonCode(body)
    for reference in importRefsOf(masked):
      if isExternalModuleSpec(reference.spec):
        continue
      let resolved = resolveSpec(reference.spec, reference.isInclude,
        fromDir, searchRoots)
      if resolved.len > 0:
        if not projectRelative(root, resolved).inside:
          # Resolved, but not project source: an external library.
          continue
        let key = pathKey(resolved)
        if key notin queued:
          queued.incl(key)
          pending.add((resolved, true))
      elif isCandidateLocalSpec(reference.spec, reference.isInclude, fromDir,
          searchRoots, dynamicSearchPath):
        missing.add("unresolved local " &
          (if reference.isInclude: "include " else: "import ") &
          reference.spec & " from " & rel)
    for read in compileTimeReadsOf(masked):
      case read.kind
      of ctCommand:
        missing.add("compile-time command execution " & read.fn & "() in " &
          rel & " (its output cannot be bound)")
      of ctAmbiguousShadow:
        # This file declares its own ``read.fn`` AND calls the name in a
        # shape the text does not resolve to one symbol or the other.
        # Ignoring it would drop a real compile-time read when the call
        # in fact reaches ``system``'s, which ALIASES; binding it would
        # invent an input when it does not. Missing evidence, therefore.
        missing.add("compile-time read " & read.fn & "() in " & rel &
          " cannot be told apart from this file's own " & read.fn &
          " declaration")
      of ctFileRead:
        if not read.hasLiteral:
          missing.add("compile-time file read " & read.fn &
            "() with a non-literal path in " & rel)
          continue
        var resolvedRead = ""
        for base in [fromDir, root]:
          let candidate =
            if read.literal.isAbsolute: normSlash(read.literal)
            else: normSlash(base / read.literal)
          if fileExists(cacheIdentityExtendedPath(candidate)):
            resolvedRead = candidate
            break
        if resolvedRead.len == 0:
          missing.add("compile-time file read " & read.fn & "(\"" &
            read.literal & "\") from " & rel)
        elif not projectRelative(root, resolvedRead).inside:
          missing.add("compile-time file read outside the project root: " &
            read.fn & "(\"" & read.literal & "\") from " & rel)
        else:
          let key = pathKey(resolvedRead)
          if key notin queued:
            queued.incl(key)
            pending.add((resolvedRead, false))

  for declared in declaredSourceInputs:
    var expanded: seq[string] = @[]
    if not collectDeclaredInput(root, declared, expanded):
      missing.add("declared source input " & declared)
      continue
    for path in expanded:
      let located = projectRelative(root, path)
      if not located.inside:
        # No relocation-stable spelling exists for a path outside the
        # project root, and an absolute path in the digest would break
        # relocation invariance. Refuse instead.
        missing.add("declared source input outside the project root " &
          declared)
        continue
      var body = ""
      if not readClosureFile(path, body):
        missing.add("unreadable source input " & located.rel)
        continue
      contentByRel[located.rel] = blake3.toHex(blake3.digest(body))

  var rels: seq[string] = @[]
  for rel in contentByRel.keys:
    rels.add(rel)
  rels.sort(cmp)
  missing.sort(cmp)
  result = SourceClosure(files: rels, missing: missing)
  if missing.len > 0:
    return
  var canonical = ""
  for rel in rels:
    canonical.add(rel)
    canonical.add('\0')
    canonical.add(contentByRel[rel])
    canonical.add('\n')
  let full = blake3.toHex(blake3.digest(canonical))
  result.digestHex =
    if full.len >= SourceClosureDigestChars:
      full[0 ..< SourceClosureDigestChars]
    else:
      full

proc sourceProviderRevisionHex*(projectRoot: string): string =
  ## Source-closure digest of ``projectRoot``, truncated to 32 lowercase
  ## hex chars for the callers that kept the historical width.
  ##
  ## Reprobuild #171: this used to hash ONLY the entry recipe's bytes, so
  ## editing an imported ``recipe.nim`` left it unchanged. It now moves
  ## with every local module the entry recipe reaches. Empty when the
  ## closure cannot be resolved.
  let closure = solvedSourceClosure(projectRoot)
  if closure.missing.len > 0:
    return ""
  if closure.digestHex.len >= 32: closure.digestHex[0 ..< 32]
  else: closure.digestHex

proc isHex64(value: string): bool =
  if value.len != 64:
    return false
  for ch in value:
    if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      return false
  true

proc sourceIdentity(instance: SolvedSourceInstance;
                    revisionChars: int): CacheEntryIdentity =
  ## THE canonical source-package identity. Every path that needs a
  ## source-package cache key — materialized substitution (lookup),
  ## the engine's automatic publication hook, explicit materialized
  ## publication, operator backfill and graph inspection — derives it
  ## from this one tuple, so all of them agree by construction.
  ##
  ## Returns a PENDING identity (one that ``deriveCacheEntryKey``
  ## refuses) whenever any required input is missing. Completeness means
  ## ALL of: a resolvable source closure, a package name, solved
  ## options, resolved dependency instances with well-formed keys, a
  ## fully populated target triple, and a toolchain with both a name and
  ## a version.
  let closure = solvedSourceClosure(instance.projectRoot,
    instance.declaredSourceInputs, instance.effectiveSearchRoots)
  var missing = closure.missing

  if instance.packageName.len == 0:
    missing.add("package name")
  if instance.searchRootsKnown:
    # A caller that ASSERTS the effective root set and names a directory
    # that is not there has reconstructed the compile command wrongly,
    # and a wrong reconstruction re-opens the very channel this input
    # closes: measured, a typo'd root silently dropped the module it was
    # meant to reach and produced one key across two implementations.
    # The claim is checkable in exactly this one respect, so it is
    # checked.
    let suppliedBase =
      if instance.projectRoot.len == 0: ""
      else:
        try: normSlash(absolutePath(instance.projectRoot))
        except CatchableError: normSlash(instance.projectRoot)
    for supplied in instance.effectiveSearchRoots:
      if supplied.strip().len == 0:
        missing.add("supplied effective search root is empty")
        continue
      let abs = normSlash(
        if supplied.isAbsolute: supplied else: suppliedBase / supplied)
      if not dirExists(cacheIdentityExtendedPath(abs)):
        missing.add("supplied effective search root does not exist: " &
          supplied)
  if not instance.searchRootsKnown:
    # The effective compile command was never reconstructed, so a module
    # reachable only through a ``--path`` this scanner cannot read is
    # invisible AND unrefusable: it would be assumed external, dropped,
    # and a digest produced over the rest. Refuse instead — the same
    # treatment an unresolvable candidate-local module already gets.
    missing.add("effective compiler search roots (the --path set of the " &
      "compile command; a module reachable only through one leaves no " &
      "trace in any config file this scanner can read)")
  if not instance.optionsSolved:
    missing.add("selected options")
  if not instance.dependenciesResolved:
    missing.add("dependency instances")
  if instance.platform.cpu.len == 0 or instance.platform.os.len == 0 or
      instance.platform.abi.len == 0:
    missing.add("target platform/ABI")
  if instance.toolchain.name.len == 0 or instance.toolchain.version.len == 0:
    missing.add("toolchain identity")
  for dep in instance.dependencyInstances:
    if not isHex64(dep):
      missing.add("malformed dependency instance key " & dep)

  let revision =
    if closure.digestHex.len >= revisionChars:
      closure.digestHex[0 ..< revisionChars]
    else:
      closure.digestHex
  result = newCacheEntryIdentity(
    packageName = instance.packageName,
    packageVersion = instance.packageVersion,
    platform = instance.platform,
    toolchain = instance.toolchain,
    providerRevision = revision)
  for (name, value) in instance.selectedOptions:
    if name == PendingCacheIdentityOptionKey:
      # A caller must not smuggle the reserved marker in through the
      # option channel; treat it as missing evidence, never as data.
      missing.add("reserved option " & PendingCacheIdentityOptionKey)
      continue
    result.addOption(name, value)
  for dep in instance.dependencyInstances:
    if isHex64(dep):
      result.addDep(dep)

  if missing.len > 0:
    missing.sort(cmp)
    result.addOption(PendingCacheIdentityOptionKey,
      "unbound solved source instance: " & missing.join("; "))

proc solvedSourceCacheEntryIdentity*(instance: SolvedSourceInstance):
    CacheEntryIdentity =
  ## THE canonical source-package identity — see ``sourceIdentity``.
  ## Carries the full-width source-closure digest.
  sourceIdentity(instance, SourceClosureDigestChars)

proc sourceCacheEntryIdentity*(projectRoot, packageName, packageVersion,
                               conventionTag: string): CacheEntryIdentity =
  ## Legacy constructor for the call sites that cannot yet supply a
  ## solved instance. It binds the source closure (so the diagnostic
  ## ``providerRevision`` now moves with imported recipe code) but has
  ## NO effective search roots, NO solved options, NO resolved
  ## dependency instances and NO detected toolchain version, so the
  ## returned identity is always PENDING and can neither authorize a
  ## substitute nor a publication. Use
  ## ``solvedSourceCacheEntryIdentity`` once those inputs are solved.
  ##
  ## Its ``providerRevision`` keeps the historical 32-hex width (the
  ## from-source convention tests pin it): on a PENDING identity that
  ## field is diagnostic metadata, never a key input, so the extra
  ## collision headroom of the full digest buys nothing here.
  sourceIdentity(SolvedSourceInstance(
    projectRoot: projectRoot,
    packageName: packageName,
    packageVersion: packageVersion,
    searchRootsKnown: false,
    optionsSolved: false,
    dependenciesResolved: false,
    platform: publicInterfaceTriple(),
    toolchain: publicInterfaceToolchain(conventionTag)), 32)
