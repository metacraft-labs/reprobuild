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
##     file read (``staticRead`` / ``slurp``) it performs, plus the bytes
##     of every project config file the compiler reads (see "Config files
##     are source"), plus every declared local non-Nim source input (SDK
##     generator templates, ``.c`` sources, data files, directories);
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
## directory, and the scanner models the same set IN THE SAME ORDER
## (``options.findModule``, ``nimblecmd.addPath``):
##
##   * the importing file's own directory;
##   * every path switch with a literal value in ``<root>/nim.cfg``,
##     ``<root>/config.nims``, ``<root>/<entry>.nimcfg`` (or, when that is
##     absent, ``<root>/<entry>.nim.cfg``) and ``<root>/<entry>.nims``,
##     LAST-processed first -- ``addPath`` inserts each one at the front.
##     The switch name is compared as ``commands.processSwitch`` compares
##     it (``strutils.normalize``: ``--Path``, ``PATH =``, ``p:``,
##     ``--pa_th`` are all ``--path``), a ``nim.cfg`` is read with Nim's
##     lexer as ``nimconf`` reads it, and a NimScript ``switch`` call
##     counts wherever it sits (``when true: switch(...)``, command syntax,
##     arguments over several lines). ``$projectDir`` / ``$projectPath`` /
##     ``$config`` are expanded; roots are restricted to ones INSIDE the
##     project root;
##   * the nimble ``srcDir`` declared by ``<root>/*.nimble``;
##   * every root in ``SolvedSourceInstance.effectiveSearchRoots`` — the
##     ``--path`` set of the EFFECTIVE compile command, which the caller
##     supplies because no scan of the tree can recover it. The command
##     line is processed BEFORE the config files, so these are searched
##     after the config roots, and among themselves last-given first.
##     They are NOT restricted to the project root: a ``--path`` into a
##     nimble dependency is legitimate, and a spec that resolves through
##     one lands outside the project root and is then classified as
##     external code. A supplied root that does NOT EXIST refuses: see
##     "A supplied root that does not exist" below;
##   * the project root itself, LAST. The compiler does not search it
##     (measured: a subdirectory's bare ``import toplevel`` does not
##     compile), so this is an over-approximation; searching it FIRST, as
##     this scanner used to, bound the root's ``helper.nim`` for a
##     subdirectory's ``import helper`` while nim read ``lib/helper.nim``
##     through ``--path:"lib"``.
##
## ``pkg/x`` is ``x`` looked up in the search roots only (the standard
## library suppressed), so it CAN be project source: ``--path:"lib"`` plus
## ``import pkg/libmod`` reads ``lib/libmod.nim``.
##
## A config switch that makes the compiler read or relocate source by a
## rule this scanner does not model -- ``--import`` / ``--include`` (a
## module pulled into every module), ``--lib``, ``--excludePath``,
## ``patchFile`` -- refuses, as does a NimScript ``switch`` whose name is
## not a literal. ``--nimblePath`` marks the root set unknown (rule 4). A
## NimScript config that ``include``s / ``import``s another local script
## is followed.
##
## The effective search-root set is a REQUIRED input, not an optional
## hint: ``searchRootsKnown`` distinguishes "reconstructed, and it adds
## nothing beyond what is on disk" from "never reconstructed", and the
## identity REFUSES in the second case. See "The command-line --path
## channel" below for why anything weaker aliases.
##
## At each root the spec is tried as ``options.findModule`` tries it:
## ``addFileExt(spec, "nim")``, the spec as written when it carries ANY
## extension (``include "frag.inc"``, ``import "helper.x"``), else with
## ``.nim`` appended. When no root has that spelling, the roots are
## searched again for the LOWER-CASED spelling, as ``options.findFile``
## does (relevant only on a case-sensitive filesystem, and not measured
## there this round). ``<spec>.nims`` and a package directory's
## ``<spec>/<spec>.nim`` are also BOUND when they exist, but they are not
## files the compiler tries, so they never stop the search: stopping at
## one bound a decoy beside the importing file while nim read the real
## module through ``--path`` (measured).
##
## A STRING-literal spec is first substituted as ``options.pathSubs``
## substitutes it: ``$projectdir`` / ``$projectpath`` (the project root),
## ``$config`` (the importing file's directory) and ``$projectname`` are
## evaluated, ``$lib`` / ``$nim`` name the standard library (external),
## and anything else (``$home``, ``$nimcache``, ``~``) is missing
## evidence. A module name written with a dot is an ``nkDotExpr``, which
## the compiler renders with its dots replaced -- ``import sub.helper``
## reads ``sub/helper.nim`` and ``include other.nim`` reads
## ``other/nim.nim`` (measured), except inside an operand that starts
## with a prefix operator (``./a.b``). That reading (``dottedModuleName``)
## is bound, and so is the literal one this scanner used to bind, as an
## over-approximation.
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
##   3. it carries an extension (``.nim``, ``.nims``, ``.inc``, or any
##      other: ``addFileExt`` keeps it) — it names a file, not a package;
##   4. the project declares search paths this scanner could not
##      evaluate (a non-literal ``switch("path", expr)``, a computed
##      ``--path``), so the search-root set itself is unknown and no
##      spec can be ruled out;
##   5. the spec's FIRST path segment matches an on-disk entry under one
##      of the search roots (a directory, or a ``.nim``/``.nims`` file) —
##      partial evidence that it points into this project.
##
## Otherwise it is an **external library** and is ignored. A spec
## starting ``std/``, and ``system``, are external by Nim's own
## namespacing and short-circuit before any of the above. A ``pkg/``
## spec that resolves through no root is external too, unless the root
## set is unknown (rule 4).
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
## ## Reading the source: Nim's lexer, not line heuristics
##
## Source is TOKENISED (``nimTokens``) the way ``compiler/lexer.nim`` of
## nim 2.2.8 tokenises it, and every question below is asked of tokens:
## comments (``#``, nestable ``#[ ]#`` and ``##[ ]##``, each nesting on
## its own opener) produce none, and every literal kind -- ordinary,
## ``r"..."``, generalized ``tag"..."``, triple-quoted, character -- is ONE
## token whose value is decoded. An ``import ./ghost`` inside a comment or
## any literal is therefore not seen, which is not a weakening: Nim does
## not read those bytes as code, so they are provably not an input, and
## refusing on them would make a correct project permanently unkeyable.
##
## Up to this revision the scanner MASKED comments and triple-quoted
## literals and then grepped lines. Five rounds of fixes each closed a
## shape and left its neighbour open, because "is this byte code, and
## which statement is it part of" is the lexer's question. The last round
## still measured, each compiled by nim 2.2.8 and each reading a file the
## scanner produced a digest without:
##
##   * an import after ``;`` whose line began with another import
##     (``import std/os; import ./helper``), or after a backtick-quoted
##     ``from`` -- and the docstring here claimed such imports were read;
##   * the continuation line of a multi-line ``const`` value in command
##     syntax (``slurp "payload.txt"``, ``slurp"payload.txt"``, a
##     ``slurp:`` block), taken for a DECLARATION of ``slurp``;
##   * a triple-quoted argument (``slurp("""p""")``) or a ``slurp:`` block
##     beside ``proc slurp(): string``, taken for the nullary local call;
##   * config spellings ``nimconf`` / NimScript accept (see "How a module
##     spec is resolved");
##   * ``tag'#'`` -- a character literal directly after an identifier,
##     which the masker did not treat as a literal, so its ``#`` or ``"``
##     hid the rest of the line.
##
## A differential ORACLE against the real compiler then measured the
## class, not the instances. For each case of a generated corpus it runs
## ``nim c --compileOnly -d:nimBetterRun`` and reads ``depfiles`` from
## ``<nimcache>/<project>.json`` -- ``conf.m.fileInfos``, every file the
## compiler registered: modules, includes, and each ``staticRead`` /
## ``slurp`` payload (``vmdeps.opSlurp`` registers it). A compiled case
## whose closure is complete (no refusal) but lacks a project file the
## compiler registered is a false accept. Over 3055 compilable cases
## recombining comments, every literal kind, ``;``, ``when`` / ``if``,
## command syntax, block calls, method-call syntax, identifier styles,
## local overloads and config spellings, the masking scanner had 1524
## false accepts; this one has 0. Besides the shapes above it found
## style-insensitive keywords and read names (``imPort``, ``static_read``,
## ``sl_urp``: Nim compares identifiers ignoring case after the first
## character and ignoring underscores), ``"payload.txt".slurp``,
## ``slurp("payload" & ".txt")`` binding a decoy file ``payload``, config
## roots searched in the wrong order, ``pkg/`` specs resolving into the
## project, and ``--import`` / ``--include`` switches. What the oracle
## does NOT establish: it sees one configuration (a ``when`` branch not
## taken is not read, so it cannot fault an over-approximation there),
## only compilable cases, only Windows (nim 2.2.8), no macro-generated
## code (a residual pinned below), and nothing outside its corpus -- a
## zero there is a measurement of that corpus, not a proof.
##
## That caveat was then measured. An INDEPENDENT corpus (3500 cases,
## generated by a verifier that had not read the first generator) found
## eight classes the first corpus had not generated, each compiled by nim
## 2.2.8 and each reading a file this scanner digested without: a leading
## UTF-8 byte-order mark (lexed as identifier bytes, it hid a first-line
## ``import``); a Unicode operator (``"x"∙slurp(...)`` lexed as the
## identifier ``∙slurp``); ``from m as alias import x``; an import naming a
## non-Nim extension; a ``.nims`` or ``pkg/pkg.nim`` decoy stopping the
## search before the ``--path`` module; ``$projectdir`` / ``$config`` in a
## string module path; config-file CONTENTS (see "Config files are
## source"); and compile-time file-system access outside ``slurp`` (see
## "Compile-time reads"). The last two are invisible to the ``depfiles``
## oracle -- the compiler registers config files but the first corpus
## excluded them, and it does not register a VM ``readFile`` at all -- so
## the second corpus also used a BEHAVIOURAL oracle: delete each project
## file outside the closure, recompile, and compare the generated C. Both
## oracles now report 0 over both corpora; the ``depfiles`` oracle alone
## would still report 0 with the VM class open.
##
## ``nimTokens`` therefore also skips a leading byte-order mark
## (``nimlexbase.skipUTF8BOM``) and lexes the Unicode operators nim 2.2.8
## always accepts (``lexer.unicodeOprLen``), which end an identifier.
##
## Measured over the 339 project roots in this repository, the lexer-based
## scanner and the fixes above move no closure digest and add no refusal
## to any of the 338 keyed roots (the repository root, already refused,
## gains reasons from its ``config.nims``).
##
## ## Config files are source
##
## The bytes of every config file the compiler reads for the project --
## ``nim.cfg``, ``config.nims``, ``<entry>.nimcfg`` (else
## ``<entry>.nim.cfg``), ``<entry>.nims``, a script one of those
## ``include``s or ``import``s -- and of the root's ``*.nimble`` enter the
## closure, as does a payload a NimScript config ``slurp``s. They used to
## be read only for their ``--path`` switches, so two trees that differ
## ONLY by ``-d:variantB`` in ``nim.cfg`` -- different code under ``when
## defined(variantB)``, measured in the generated C -- got ONE key: the
## #171 class through the config channel. They are bound, not
## interpreted, so every switch a config can carry (``--define``,
## ``--undef``, ``--mm``, ``--opt`` ...) moves the key. A NimScript config
## is evaluated by the VM, so every file-system access in it other than a
## bound ``slurp`` / ``staticRead`` -- ``readFile``, ``fileExists``,
## ``listFiles`` ... -- is missing evidence. NOT bound, and not bindable
## relocation-stably: config files OUTSIDE the project root (the parent
## directories' ``nim.cfg`` / ``config.nims`` unless ``--skipParentCfg``,
## the user's and the system's), and a define given on the command line;
## those belong to the effective compile command, like
## ``effectiveSearchRoots``.
##
## ## Compile-time reads
##
## ``staticRead`` / ``slurp`` -- in any spelling the compiler takes for
## them (``static_read``, ``sl_urp``, backtick-quoted, ``system.``-
## qualified, method-call ``"p".slurp``) and in any call form (``f(a)``,
## ``f a``, ``f"a"``, a ``f:`` block) -- are bound when their one
## argument is a CONSTANT STRING EXPRESSION the scanner evaluates exactly:
## a literal of any kind, literals joined by ``&``, parentheses,
## ``.substr`` with integer literals (``evalConstString``). The path is
## resolved as ``vmdeps.opSlurp`` resolves it -- the reading file's
## directory, then the search roots in the compiler's order (the project
## root last) -- and its bytes enter the closure. Any other argument, an
## argument that does not resolve, or one resolving outside the project
## root is missing evidence. ``gorge`` / ``gorgeEx`` / ``staticExec`` run
## a command at compile time whose output cannot be bound at all, so
## their mere presence is missing evidence.
##
## The VM reads files OUTSIDE ``opSlurp`` too: ``vmops`` registers
## ``readFile``, ``readLines``, ``fileExists``, ``dirExists`` and the
## ``std/staticos`` procs as compile-time callbacks. The compiler records
## none of them as a dependency, and a relative path is resolved against
## its WORKING DIRECTORY, which this scanner does not know. Measured
## (behaviourally, since ``depfiles`` cannot see them): ``const c =
## readFile("p.txt")``, ``static(readLines(...))``, ``staticFileExists``
## and ``when fileExists(...)`` each changed the generated C with the
## closure digest unchanged. So ``readFile`` / ``readLines`` /
## ``staticFileExists`` / ``staticDirExists`` / ``staticWalkDir`` are
## missing evidence WHEREVER they occur -- a routine calling ``readFile``
## at run time can be evaluated at compile time from a ``const`` anywhere,
## and no keyed project root in this repository uses them -- while
## ``fileExists`` / ``dirExists`` / ``listFiles`` / ``listDirs``, common at
## run time in recipe code, are missing evidence only where the text
## evaluates them at compile time (``compileTimeContext``: a ``when`` or
## ``elif``-of-``when`` condition, a ``const`` section, ``static``, a
## ``{.compileTime.}`` declaration, a ``macro`` body, any NimScript
## config). An existence check inside a routine that a ``const`` calls is
## NOT seen, and is pinned as an open residual beside the macro one.
##
## This is still not a parse -- it tokenises, then reads statement and
## call SHAPES -- but it is no longer an identifier grep, because a grep
## false-refused three shapes of CORRECT recipe and a permanently
## unkeyable project is as useless as an aliased one. Three exclusions
## apply, and each is provable from the tokens rather than heuristic:
##
##   * an occurrence inside a literal or a comment is not a token at all,
##     so ``echo "slurp the file"`` mentions nothing;
##   * the DECLARATION of the name is not a use of it: the name token of
##     ``proc slurp(...)``, and of a ``let`` / ``var`` / ``const`` /
##     ``type`` entry (the first token of a line at its section's ENTRY
##     column -- a deeper line continues a value and is a use), is
##     skipped, so a file that defines the symbol does not refuse on its
##     own header;
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
## rather than ignoring: a call whose first argument does not start with
## a string literal on the call's own line (nothing rules the local
## overload in or out), a call whose argument count a trailing block
## leaves open, a local parameter type
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
##   * a routine whose parameter list does not close on the line it opens
##     on is treated as undecidable, so it REFUSES;
##   * command syntax follows the parser as measured: inside an enclosing
##     bracket a command call takes ONE argument (``(slurp "pay",
##     "load.txt")`` reads ``pay``), at statement level it takes every
##     comma-separated argument to the end of the statement;
##   * an ``import``ed overload is invisible to this scanner, so a call
##     that overload would capture is still treated as the stdlib read.
##     That over-approximates: it binds the argument, or refuses when
##     the argument does not resolve. It never ignores;
##   * ``when`` is not evaluated. A ROUTINE declaration under one is
##     indented, which is undecidable and refuses; a read or an import
##     inside one is bound whether or not the branch is live, which
##     over-approximates. Both are the safe direction;
##   * MACRO-GENERATED code is a gap that fails the other way, and it is
##     an open residual rather than a caveat: a compile-time read or an
##     import that exists only after expansion leaves no text for this
##     scanner to see, is therefore not bound, and the key can ALIAS
##     across a change to what it reads. The same holds for compile-time
##     evaluation the text does not show: an existence check
##     (``fileExists``) inside a routine that a ``const`` evaluates, and
##     ``getEnv`` / ``existsEnv`` at compile time (the environment is not
##     a file). Both are pinned or recorded as open;
##   * C-level inputs are the caller's to declare: a ``{.compile:
##     "x.c".}`` source, the headers it includes, a ``{.header.}`` file
##     reach the build through the C compiler, not through Nim, and enter
##     the identity only through ``declaredSourceInputs``.
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
## unresolved candidate-local import or include, an import expression
## that is not a path this scanner can evaluate, a config switch that
## imports or relocates source (or a NimScript ``switch`` whose name is
## not a literal), an unbindable
## compile-time read, a compile-time read this file's own declaration
## neither provably takes nor provably declines, a compile-time
## file-system access outside ``slurp`` / ``staticRead`` (or any in a
## NimScript config), a string module path with a substitution that is
## not project-relative, a declared source input
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
# Nim lexer
# ---------------------------------------------------------------------------
#
# Everything below reads Nim source (and ``nim.cfg``, which ``nimconf``
# reads with the same lexer) as TOKENS, following ``compiler/lexer.nim``
# of nim 2.2.8, rather than masking comments and grepping lines. Five
# rounds of line heuristics each left a neighbouring shape open, because
# the question "is this byte code, and which statement is it part of" is
# the lexer's to answer: a ``;`` ends a statement, ``tag'#'`` is an
# identifier followed by a character literal, ``imPort`` is the keyword
# ``import``, ``"""p"""`` is a literal that can be a call's argument, and
# a ``#`` inside any literal is not a comment.

type
  NimTokKind = enum
    ntkIdent, ntkStr, ntkChar, ntkNumber, ntkOp, ntkPunct, ntkInvalid

  NimTok = object
    kind: NimTokKind
    text: string
      ## Identifier: its spelling, without the backticks of a quoted one.
      ## Operator / punctuation / number: its spelling.
    norm: string
      ## Identifier only: ``nimIdentNorm(text)``.
    quoted: bool
      ## A backtick-quoted identifier: the same symbol as the unquoted
      ## spelling, but never a keyword (``let `from` = 1``).
    value: string
      ## String literal only: the decoded value.
    valueKnown: bool
      ## String literal only: false when an escape was not decoded or the
      ## literal never closed. Such a literal is not a path.
    generalized: bool
      ## String literal only: ``ident"..."`` / ``ident"""..."""``, which
      ## is a CALL of ``ident`` with this one raw literal as argument.
    offset, endOffset: int
    line: int
      ## Line the token starts on, 0-based.
    col: int
    lineIndent: int
      ## Column of the first token that starts on this token's line.
    firstOnLine: bool
      ## No earlier token starts or ends on this token's line.

const
  NimSymChars = {'a'..'z', 'A'..'Z', '0'..'9', '\x80'..'\xFF'}
  NimOpChars = {'+', '-', '*', '/', '\\', '<', '>', '!', '?', '^', '.',
                '|', '=', '%', '&', '$', '@', '~', ':'}
  NimUnaryMinusWhitelist = {' ', '\t', '\n', '\r', ',', ';', '(', '[', '{'}
  NimOpeners = ["(", "(.", "[", "[.", "[:", "{", "{."]
  NimClosers = [")", ".)", "]", ".]", "}", ".}"]

const
  UnicodeOperatorStartChars = {'\226', '\194', '\195'}
    ## ``lexer.UnicodeOperatorStartChars``: the lead bytes of the Unicode
    ## operators nim 2.2.8 always accepts (``∙ ∘ × ★ ⊗ ⊘ ⊙ ⊛ ⊠ ⊡ ∩ ∧ ⊓ ±
    ## ⊕ ⊖ ⊞ ⊟ ∪ ∨ ⊔``).

proc unicodeOprLen(src: string; pos: int): int =
  ## ``lexer.unicodeOprLen``: the byte length of the Unicode operator
  ## starting at ``src[pos]``, 0 when there is none. Such an operator ENDS
  ## an identifier (``getSymbol`` breaks on it), so ``x∙slurp`` is three
  ## tokens -- read as one identifier, the ``slurp`` call after it
  ## vanished (measured by the verifier's corpus).
  template at(k: int): char =
    (if k >= 0 and k < src.len: src[k] else: '\0')
  case at(pos)
  of '\226':
    if at(pos + 1) == '\136':
      if at(pos + 2) in {'\152', '\153', '\167', '\168', '\169', '\170'}:
        return 3
    elif at(pos + 1) == '\138':
      if at(pos + 2) in {'\147', '\148', '\149', '\150', '\151', '\152',
                         '\153', '\155', '\158', '\159', '\160', '\161'}:
        return 3
    elif at(pos + 1) == '\152' and at(pos + 2) == '\133':
      return 3
  of '\194':
    if at(pos + 1) == '\177': return 2
  of '\195':
    if at(pos + 1) == '\151': return 2
  else:
    discard
  0

proc nimIdentNorm(s: string): string =
  ## Identifier equality as ``idents.getIdent`` / ``cmpIgnoreStyle``
  ## define it: the FIRST character exactly, every other one ignoring
  ## case, and underscores ignored. So ``imPort`` and ``im_port`` are the
  ## keyword ``import`` and ``static_read`` is ``staticRead``, while
  ## ``Import`` and ``StaticRead`` are different identifiers.
  if s.len == 0:
    return ""
  result = newStringOfCap(s.len)
  result.add(s[0])
  for i in 1 ..< s.len:
    if s[i] != '_':
      result.add(toLowerAscii(s[i]))

proc hexValue(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1

proc decodeNimEscape(src: string; i: var int; value: var string;
                     known: var bool) =
  ## Decode the escape whose backslash is at ``src[i]``, as
  ## ``lexer.getEscapedChar`` does, and advance ``i`` past it. ``\p``
  ## (host-dependent), ``\u`` (not decoded here) and an invalid escape
  ## leave ``known`` false.
  inc i
  if i >= src.len:
    known = false
    return
  let c = src[i]
  inc i
  case c
  of 'n', 'N', 'l', 'L': value.add('\n')
  of 'r', 'R', 'c', 'C': value.add('\r')
  of 'f', 'F': value.add('\f')
  of 'e', 'E': value.add('\e')
  of 'a', 'A': value.add('\a')
  of 'b', 'B': value.add('\b')
  of 'v', 'V': value.add('\v')
  of 't', 'T': value.add('\t')
  of '\'', '"', '\\': value.add(c)
  of 'x', 'X':
    var code = 0
    for _ in 0 ..< 2:
      if i < src.len and hexValue(src[i]) >= 0:
        code = code * 16 + hexValue(src[i])
        inc i
      else:
        known = false
        return
    value.add(chr(code))
  of '0'..'9':
    var code = ord(c) - ord('0')
    while i < src.len and src[i] in Digits:
      if code <= 255:
        code = code * 10 + ord(src[i]) - ord('0')
      inc i
    if code > 255:
      known = false
    else:
      value.add(chr(code))
  of 'u', 'U':
    known = false
    if i < src.len and src[i] == '{':
      while i < src.len and src[i] notin {'}', '\n', '\r'}:
        inc i
      if i < src.len and src[i] == '}':
        inc i
    else:
      var k = 0
      while k < 4 and i < src.len and hexValue(src[i]) >= 0:
        inc i
        inc k
  else:
    known = false

proc nimTokens(src: string): seq[NimTok] =
  ## Tokenise ``src`` as ``lexer.rawGetTok`` does, dropping comments.
  let n = src.len
  var i = 0
  var line = 0
  var lineStart = 0
  var lastTokLine = -1
  var indent = 0
  template at(k: int): char =
    (if k >= 0 and k < n: src[k] else: '\0')
  template stepNewline() =
    ## ``src[i]`` is ``\n`` or ``\r``: step over one line break.
    if src[i] == '\r' and at(i + 1) == '\n':
      i += 2
    else:
      inc i
    inc line
    lineStart = i
  template symbolChar(k: int): bool =
    ## ``getSymbol``'s loop: a symbol character that does not start a
    ## Unicode operator.
    at(k) in NimSymChars and
      not (at(k) in UnicodeOperatorStartChars and unicodeOprLen(src, k) > 0)
  template scanOperator() =
    ## ``getOperator``: ASCII operator characters and Unicode operators.
    while true:
      if at(i) in NimOpChars:
        inc i
      elif at(i) in UnicodeOperatorStartChars and unicodeOprLen(src, i) > 0:
        i += unicodeOprLen(src, i)
      else:
        break
  if n >= 3 and src[0] == '\xEF' and src[1] == '\xBB' and src[2] == '\xBF':
    # ``nimlexbase.skipUTF8BOM``: a leading byte-order mark is not a
    # token, and the first line's columns start after it. Lexed as the
    # bytes of an identifier, it hid a first-line ``import`` (measured).
    i = 3
    lineStart = 3
  template emit(tok: NimTok; startOff, startLine, startLineStart: int) =
    var t = tok
    t.offset = startOff
    t.endOffset = i
    t.line = startLine
    t.col = startOff - startLineStart
    t.firstOnLine = startLine != lastTokLine
    if t.firstOnLine:
      indent = t.col
    t.lineIndent = indent
    if t.kind == ntkStr:
      t.text = src[startOff ..< i]
    lastTokLine = line
    result.add(t)

  proc lexString(src: string; i, line, lineStart: var int;
                 generalized, raw: bool): NimTok =
    ## ``src[i]`` is the opening quote.
    let n = src.len
    template at(k: int): char =
      (if k >= 0 and k < n: src[k] else: '\0')
    result = NimTok(kind: ntkStr, valueKnown: true, generalized: generalized)
    inc i
    if at(i) == '"' and at(i + 1) == '"':
      i += 2
      # ``getString``: whitespace then a line break right after the
      # opening quotes are not part of the value.
      if at(i) in {' ', '\t'}:
        var k = i + 1
        while at(k) in {' ', '\t'}:
          inc k
        if at(k) in {'\r', '\n'}:
          i = k
      if at(i) in {'\r', '\n'}:
        if src[i] == '\r' and at(i + 1) == '\n': i += 2 else: inc i
        inc line
        lineStart = i
      while true:
        if i >= n:
          result.valueKnown = false
          break
        let c = src[i]
        if c == '"' and at(i + 1) == '"' and at(i + 2) == '"' and
            at(i + 3) != '"':
          i += 3
          break
        if c in {'\r', '\n'}:
          result.value.add('\n')
          if c == '\r' and at(i + 1) == '\n': i += 2 else: inc i
          inc line
          lineStart = i
          continue
        result.value.add(c)
        inc i
      return
    while true:
      if i >= n or src[i] in {'\r', '\n'}:
        result.valueKnown = false
        break
      let c = src[i]
      if c == '"':
        if (raw or generalized) and at(i + 1) == '"':
          result.value.add('"')
          i += 2
          continue
        inc i
        break
      if c == '\\' and not raw and not generalized:
        decodeNimEscape(src, i, result.value, result.valueKnown)
        continue
      result.value.add(c)
      inc i

  while i < n:
    let c = src[i]
    let startOff = i
    let startLine = line
    let startLineStart = lineStart
    case c
    of '\n', '\r':
      stepNewline()
    of ' ', '\t', '\f', '\v':
      inc i
    of '#':
      let docBlock = at(i + 1) == '#' and at(i + 2) == '['
      if docBlock or at(i + 1) == '[':
        # ``lexer.skipMultiLineComment``: a doc block nests on ``##[`` and
        # closes on ``]##``, a plain one nests on ``#[`` and closes on
        # ``]#``; nesting advances one byte.
        i += (if docBlock: 3 else: 2)
        var nesting = 0
        while i < n:
          let ch = src[i]
          if ch == '#':
            if docBlock:
              if at(i + 1) == '#' and at(i + 2) == '[': inc nesting
            elif at(i + 1) == '[':
              inc nesting
            inc i
          elif ch == ']':
            if docBlock:
              if at(i + 1) == '#' and at(i + 2) == '#':
                if nesting == 0:
                  i += 3
                  break
                dec nesting
            elif at(i + 1) == '#':
              if nesting == 0:
                i += 2
                break
              dec nesting
            inc i
          elif ch in {'\n', '\r'}:
            stepNewline()
          else:
            inc i
      else:
        while i < n and src[i] notin {'\n', '\r'}:
          inc i
    of '"':
      # ``rawGetTok``: a quote directly after a symbol character opens a
      # GENERALIZED raw literal -- the lexer's own test, on the raw byte.
      let generalized = i > 0 and src[i - 1] in NimSymChars
      let tok = lexString(src, i, line, lineStart, generalized, false)
      emit(tok, startOff, startLine, startLineStart)
    of 'r', 'R':
      if at(i + 1) == '"':
        inc i
        let tok = lexString(src, i, line, lineStart, false, true)
        emit(tok, startOff, startLine, startLineStart)
      else:
        while symbolChar(i) or (at(i) == '_' and at(i + 1) in NimSymChars):
          inc i
        let text = src[startOff ..< i]
        emit(NimTok(kind: ntkIdent, text: text, norm: nimIdentNorm(text)),
          startOff, startLine, startLineStart)
    of 'a'..'q', 's'..'z', 'A'..'Q', 'S'..'Z', '\x80'..'\xFF':
      if c in UnicodeOperatorStartChars and unicodeOprLen(src, i) > 0:
        # ``rawGetTok``: a Unicode operator is an operator, not a symbol.
        scanOperator()
        emit(NimTok(kind: ntkOp, text: src[startOff ..< i]),
          startOff, startLine, startLineStart)
        continue
      while symbolChar(i) or (at(i) == '_' and at(i + 1) in NimSymChars):
        inc i
      let text = src[startOff ..< i]
      emit(NimTok(kind: ntkIdent, text: text, norm: nimIdentNorm(text)),
        startOff, startLine, startLineStart)
    of '_':
      inc i
      if at(i) notin NimSymChars + {'_'}:
        emit(NimTok(kind: ntkIdent, text: "_", norm: "_"),
          startOff, startLine, startLineStart)
      else:
        emit(NimTok(kind: ntkInvalid, text: "_"),
          startOff, startLine, startLineStart)
    of '`':
      # A quoted identifier is the concatenation of what the backticks
      # enclose; it names the same symbol and is never a keyword.
      var k = i + 1
      while k < n and src[k] notin {'`', '\n', '\r'}:
        inc k
      if at(k) == '`' and k > i + 1:
        var text = ""
        for ch in src[i + 1 ..< k]:
          if ch notin {' ', '\t'}:
            text.add(ch)
        i = k + 1
        emit(NimTok(kind: ntkIdent, text: text, norm: nimIdentNorm(text),
          quoted: true), startOff, startLine, startLineStart)
      else:
        inc i
        emit(NimTok(kind: ntkPunct, text: "`"),
          startOff, startLine, startLineStart)
    of '\'':
      # ``getCharacter``. Always a character literal here: only a NUMBER
      # takes a ``'`` suffix, and ``getNumber`` consumes that itself.
      inc i
      var value = ""
      var known = true
      let ch = at(i)
      if ch == '\\':
        decodeNimEscape(src, i, value, known)
      elif ch in {'\0'..pred(' '), '\''}:
        discard
      else:
        inc i
      if at(i) == '\'':
        inc i
      elif startOff > 0 and src[startOff - 1] == '`':
        i = startOff + 1
      emit(NimTok(kind: ntkChar, text: src[startOff ..< i]),
        startOff, startLine, startLineStart)
    of '0'..'9', '-':
      if c == '-' and not (at(i + 1) in Digits and
          (i == 0 or src[i - 1] in NimUnaryMinusWhitelist)):
        scanOperator()
        emit(NimTok(kind: ntkOp, text: src[startOff ..< i]),
          startOff, startLine, startLineStart)
      else:
        if c == '-':
          inc i
        if at(i) == '0' and at(i + 1) in {'x', 'X', 'o', 'O', 'b', 'B', 'c', 'C'}:
          i += 2
          while hexValue(at(i)) >= 0 or at(i) == '_':
            inc i
        else:
          while at(i) in Digits or at(i) == '_':
            inc i
          if at(i) == '.' and at(i + 1) in Digits:
            inc i
            while at(i) in Digits or at(i) == '_':
              inc i
          if at(i) in {'e', 'E'} and (at(i + 1) in Digits or
              (at(i + 1) in {'+', '-'} and at(i + 2) in Digits)):
            i += 2
            while at(i) in Digits or at(i) == '_':
              inc i
        if at(i) == '\'':
          inc i
          while at(i) in NimSymChars or at(i) == '_':
            inc i
        elif at(i) in Letters:
          while at(i) in NimSymChars or at(i) == '_':
            inc i
        emit(NimTok(kind: ntkNumber, text: src[startOff ..< i]),
          startOff, startLine, startLineStart)
    of '(', '[', '{':
      inc i
      var text = $c
      if at(i) == '.' and at(i + 1) != '.':
        text.add('.')
        inc i
      elif c == '[' and at(i) == ':':
        text.add(':')
        inc i
      emit(NimTok(kind: ntkPunct, text: text),
        startOff, startLine, startLineStart)
    of ')', ']', '}', ',', ';':
      inc i
      emit(NimTok(kind: ntkPunct, text: $c),
        startOff, startLine, startLineStart)
    of '.':
      if at(i + 1) in {']', '}', ')'}:
        i += 2
        emit(NimTok(kind: ntkPunct, text: src[startOff ..< i]),
          startOff, startLine, startLineStart)
      else:
        scanOperator()
        emit(NimTok(kind: ntkOp, text: src[startOff ..< i]),
          startOff, startLine, startLineStart)
    of '*':
      # ``*:`` is two tokens (``var v*: int``).
      if at(i + 1) == ':' and at(i + 2) notin NimOpChars:
        inc i
      else:
        scanOperator()
      emit(NimTok(kind: ntkOp, text: src[startOff ..< i]),
        startOff, startLine, startLineStart)
    else:
      if c in NimOpChars:
        scanOperator()
        emit(NimTok(kind: ntkOp, text: src[startOff ..< i]),
          startOff, startLine, startLineStart)
      else:
        inc i
        emit(NimTok(kind: ntkInvalid, text: $c),
          startOff, startLine, startLineStart)

proc isKw(t: NimTok; kw: string): bool =
  ## ``t`` is the keyword ``kw`` (given in its canonical lower-case form).
  t.kind == ntkIdent and not t.quoted and t.norm == kw

proc isOp(t: NimTok; op: string): bool =
  t.kind == ntkOp and t.text == op

proc isPunct(t: NimTok; p: string): bool =
  t.kind == ntkPunct and t.text == p

proc isOpener(t: NimTok): bool =
  t.kind == ntkPunct and t.text in NimOpeners

proc isCloser(t: NimTok): bool =
  t.kind == ntkPunct and t.text in NimClosers

proc bracketDepths(toks: seq[NimTok]): seq[int] =
  ## ``result[k]`` is the bracket depth BEFORE token ``k``: an opener sits
  ## at the depth outside it, a closer at the depth inside it.
  result = newSeq[int](toks.len)
  var depth = 0
  for k, t in toks:
    if isCloser(t) and depth > 0:
      dec depth
      result[k] = depth + 1
      continue
    result[k] = depth
    if isOpener(t):
      inc depth

proc matchingCloser(toks: seq[NimTok]; depths: seq[int]; openIdx: int): int =
  ## Index of the closer matching the opener at ``openIdx``; -1 if none.
  let d = depths[openIdx]
  for k in openIdx + 1 ..< toks.len:
    if isCloser(toks[k]) and depths[k] == d + 1:
      return k
    if depths[k] < d + 1 and k > openIdx + 1:
      return -1
  -1

proc continuesStatement(prev: NimTok): bool =
  ## A statement continues onto the next line after a comma, an operator,
  ## or an opener (``lexer`` / ``parser`` ``optInd``).
  isPunct(prev, ",") or prev.kind == ntkOp or isOpener(prev)

proc statementEnd(toks: seq[NimTok]; depths: seq[int]; start, base: int): int =
  ## Index of the first token at or after ``start`` that is NOT part of
  ## the statement running at bracket depth ``base``: a ``;``, a closer
  ## of an enclosing group, or a token starting a new line that does not
  ## continue the previous one.
  var k = start
  while k < toks.len:
    let t = toks[k]
    if depths[k] < base:
      return k
    if depths[k] == base:
      if isPunct(t, ";") or isCloser(t):
        return k
      if k > start and t.firstOnLine and not continuesStatement(toks[k - 1]):
        return k
    inc k
  toks.len

# ---------------------------------------------------------------------------
# Nim import scanning
# ---------------------------------------------------------------------------

type
  ImportRef = object
    spec: string
    isInclude: bool
    alt: string
      ## The module name ``modulepaths.getModuleName`` builds when the
      ## expression contains a lone ``.`` (an ``nkDotExpr``): ``a.b`` is
      ## ``a/b`` -- except inside an operand that starts with a prefix
      ## operator (``./a.b`` stays ``./a.b``). Empty when that is ``spec``.

  ImportScan = object
    refs: seq[ImportRef]
    unevaluable: seq[string]
      ## Module expressions this scanner cannot turn into a path. Missing
      ## evidence: the compiler reads SOME module there.
    covered: HashSet[int]
      ## Token indices inside import / from / include statements.

proc tokensText(toks: openArray[NimTok]): string =
  for k, t in toks:
    if k > 0: result.add(' ')
    result.add(if t.kind == ntkStr: "\"" & t.value & "\"" else: t.text)

proc specText(toks: openArray[NimTok]; ok: var bool): string =
  ## The path a module expression spells: identifiers, literals and the
  ## ``/`` ``./`` ``../`` operators joined without blanks, as
  ## ``modulepaths.getModuleName`` renders them. Anything else is not a
  ## path this scanner can evaluate.
  if toks.len == 0:
    ok = false
  for t in toks:
    case t.kind
    of ntkIdent, ntkNumber:
      result.add(t.text)
    of ntkStr:
      if not t.valueKnown:
        ok = false
      result.add(t.value)
    of ntkOp:
      var pathOp = true
      for ch in t.text:
        if ch notin {'.', '/'}:
          pathOp = false
      if pathOp:
        result.add(t.text)
      else:
        ok = false
    else:
      ok = false

proc dottedModuleName(toks: openArray[NimTok]): string =
  ## ``getModuleName`` over an unbracketed module expression that contains
  ## a lone ``.``: operands are separated by the infix ``/``-operators, a
  ## ``.`` inside an operand is a ``/`` (``nkDotExpr`` is rendered and its
  ## dots replaced) unless the operand starts with a prefix operator
  ## (``nkPrefix`` is rendered as written). Measured: ``include other.nim``
  ## makes nim 2.2.8 read ``other/nim.nim`` (and fail when only
  ## ``other.nim`` exists), and ``import sub.helper`` reads
  ## ``sub/helper.nim`` -- which this scanner read as the file
  ## ``sub.helper`` and, finding none, classed external.
  var prefixed = toks.len > 0 and toks[0].kind == ntkOp and toks[0].text != "."
  var dotted = false
  for k, t in toks:
    if t.kind == ntkOp and t.text == ".":
      dotted = true
      result.add(if prefixed: "." else: "/")
    elif t.kind == ntkOp:
      if k > 0 and t.text.startsWith("/"):
        prefixed = false
      result.add(t.text)
    elif t.kind == ntkStr:
      result.add(t.value)
    else:
      result.add(t.text)
  if not dotted:
    result = ""

proc moduleSpecsOf(item: seq[NimTok];
                   itemDepths: seq[int]):
    tuple[specs, alts: seq[string], ok: bool] =
  ## Expand one import item (``a/b``, ``"x"``, ``std/[os, strutils]``).
  ## ``alts[i]`` is the dotted reading of ``specs[i]`` (see ``ImportRef``).
  result.ok = true
  if item.len == 0:
    return
  var openAt = -1
  for k, t in item:
    if isPunct(t, "[") and itemDepths[k] == itemDepths[0]:
      openAt = k
      break
  if openAt < 0:
    let text = specText(item, result.ok)
    if result.ok:
      result.specs.add(text)
      let alt = dottedModuleName(item)
      result.alts.add(if alt == text: "" else: alt)
    return
  for t in item:
    if t.kind == ntkOp and t.text == ".":
      # A dotted name inside a bracket group: not evaluated.
      result.ok = false
      return
  if not isPunct(item[^1], "]") or itemDepths[^1] != itemDepths[openAt] + 1:
    result.ok = false
    return
  var prefix = if openAt == 0: "" else: specText(item[0 ..< openAt], result.ok)
  while prefix.endsWith("/"):
    prefix.setLen(prefix.len - 1)
  var current: seq[NimTok] = @[]
  var leaves: seq[seq[NimTok]] = @[]
  for k in openAt + 1 ..< item.len - 1:
    if isPunct(item[k], ",") and itemDepths[k] == itemDepths[openAt] + 1:
      leaves.add(current)
      current = @[]
    else:
      current.add(item[k])
  leaves.add(current)
  for leafToks in leaves:
    if leafToks.len == 0:
      continue
    let leaf = specText(leafToks, result.ok)
    result.specs.add(if prefix.len > 0: prefix & "/" & leaf else: leaf)
    result.alts.add("")

proc importStatementsOf(toks: seq[NimTok]; depths: seq[int]): ImportScan =
  ## Every ``import`` / ``from ... import`` / ``include`` statement,
  ## wherever it sits: at the start of a line, after a ``;``, after a
  ## ``when ...:``, and in any keyword spelling Nim accepts. A quoted
  ## identifier is never a keyword.
  result.covered = initHashSet[int]()
  var fromImports = initHashSet[int]()
  var k = 0
  while k < toks.len:
    let t = toks[k]
    let base = depths[k]
    if isKw(t, "from"):
      var j = k + 1
      var item: seq[NimTok] = @[]
      var itemDepths: seq[int] = @[]
      var found = false
      var aliased = false
      while j < toks.len:
        let u = toks[j]
        if depths[j] < base:
          break
        if depths[j] == base:
          if isKw(u, "import"):
            found = true
            break
          if isPunct(u, ";") or isCloser(u) or
              (u.firstOnLine and not continuesStatement(toks[j - 1]) and
               j > k + 1):
            break
          if isKw(u, "as"):
            # ``from m as alias import x``: ``getModuleName`` turns the
            # ``as`` infix into ``nkImportAs`` and takes the module from
            # its left side. Joined into the spec, the alias made the path
            # name no file, and the module was classed as external
            # (measured by the verifier's corpus).
            aliased = true
        if not aliased:
          item.add(u)
          itemDepths.add(depths[j])
        inc j
      if not found:
        inc k
        continue
      fromImports.incl(j)
      let expanded = moduleSpecsOf(item, itemDepths)
      if not expanded.ok:
        result.unevaluable.add("from " & tokensText(item))
      for n, spec in expanded.specs:
        result.refs.add(ImportRef(spec: spec, isInclude: false,
          alt: expanded.alts[n]))
      let e = statementEnd(toks, depths, j + 1, base)
      for m in k ..< e:
        result.covered.incl(m)
      k = e
      continue
    let isImport = isKw(t, "import") and k notin fromImports
    let isInclude = isKw(t, "include")
    if not (isImport or isInclude):
      inc k
      continue
    var items: seq[seq[NimTok]] = @[@[]]
    var itemDepths: seq[seq[int]] = @[@[]]
    var j = k + 1
    var symbolsOnly = false
    while j < toks.len:
      let u = toks[j]
      if depths[j] < base:
        break
      if depths[j] == base:
        if isPunct(u, ";") or isCloser(u):
          break
        if u.firstOnLine and not (j == k + 1 or continuesStatement(toks[j - 1])):
          break
        if isPunct(u, ","):
          items.add(@[])
          itemDepths.add(@[])
          inc j
          continue
        if isKw(u, "except"):
          # ``import m except a, b``: everything after is a symbol list.
          symbolsOnly = true
        elif isKw(u, "as") and not symbolsOnly:
          # ``import m as alias``: the alias names no module.
          j += 2
          continue
        elif isPunct(u, "{.") and not symbolsOnly:
          # ``import m {.all.}``
          let close = matchingCloser(toks, depths, j)
          j = (if close < 0: toks.len else: close + 1)
          continue
      if not symbolsOnly:
        items[^1].add(u)
        itemDepths[^1].add(depths[j])
      inc j
    for m in k ..< j:
      result.covered.incl(m)
    for idx, item in items:
      if item.len == 0:
        continue
      let expanded = moduleSpecsOf(item, itemDepths[idx])
      if not expanded.ok:
        result.unevaluable.add((if isInclude: "include " else: "import ") &
          tokensText(item))
      for n, spec in expanded.specs:
        result.refs.add(ImportRef(spec: spec, isInclude: isInclude,
          alt: expanded.alts[n]))
    k = max(j, k + 1)

# ---------------------------------------------------------------------------
# Constant string arguments
# ---------------------------------------------------------------------------

type
  ConstStringParser = object
    toks: seq[NimTok]
    pos: int

proc intLiteral(t: NimTok; v: var int): bool =
  if t.kind != ntkNumber:
    return false
  var digits = ""
  for ch in t.text:
    if ch in Digits: digits.add(ch)
    elif ch == '_': discard
    else: return false
  if digits.len == 0 or digits.len > 9:
    return false
  v = parseInt(digits)
  true

proc constStringExpr(p: var ConstStringParser; v: var string): bool

proc constStringPrimary(p: var ConstStringParser; v: var string): bool =
  let n = p.toks.len
  if p.pos >= n:
    return false
  let t = p.toks[p.pos]
  if t.kind == ntkStr and not t.generalized:
    if not t.valueKnown:
      return false
    v = t.value
    inc p.pos
  elif isPunct(t, "("):
    inc p.pos
    if not constStringExpr(p, v):
      return false
    if p.pos >= n or not isPunct(p.toks[p.pos], ")"):
      return false
    inc p.pos
  else:
    return false
  # Postfix ``.substr(first[, last])``.
  while p.pos < n and isOp(p.toks[p.pos], "."):
    if p.pos + 2 >= n or p.toks[p.pos + 1].kind != ntkIdent or
        p.toks[p.pos + 1].norm != "substr" or
        not isPunct(p.toks[p.pos + 2], "("):
      return false
    p.pos += 3
    var first = 0
    if p.pos >= n or not intLiteral(p.toks[p.pos], first):
      return false
    inc p.pos
    var last = v.len - 1
    if p.pos < n and isPunct(p.toks[p.pos], ","):
      inc p.pos
      if p.pos >= n or not intLiteral(p.toks[p.pos], last):
        return false
      inc p.pos
    if p.pos >= n or not isPunct(p.toks[p.pos], ")"):
      return false
    inc p.pos
    # ``system.substr(s, first, last)`` clamps to the string.
    let a = max(first, 0)
    let b = min(last, v.len - 1)
    v = if a > b: "" else: v[a .. b]
  true

proc constStringExpr(p: var ConstStringParser; v: var string): bool =
  if not constStringPrimary(p, v):
    return false
  while p.pos < p.toks.len and isOp(p.toks[p.pos], "&"):
    inc p.pos
    var rhs = ""
    if not constStringPrimary(p, rhs):
      return false
    v.add(rhs)
  true

proc evalConstString(toks: seq[NimTok]; value: var string): bool =
  ## Evaluate an argument that is a CONSTANT STRING EXPRESSION whose value
  ## this scanner knows exactly: string literals, ``&`` concatenation,
  ## parentheses and ``.substr(first[, last])`` with integer literals, with
  ## Nim's semantics. Anything else -- an identifier, a call, any other
  ## operator -- is not evaluated, and the result is false.
  ##
  ## Exact or nothing. Taking the FIRST literal of an argument, as the
  ## textual scanner did, bound ``payload`` for ``slurp("payload" &
  ## ".txt")`` -- a file the compiler never reads -- and left out the one
  ## it does read (measured by the oracle, with both files present).
  var p = ConstStringParser(toks: toks, pos: 0)
  var v = ""
  if toks.len == 0 or not constStringExpr(p, v) or p.pos != toks.len:
    return false
  value = v
  true

# ---------------------------------------------------------------------------
# Compile-time reads
# ---------------------------------------------------------------------------

type
  CompileTimeReadKind = enum
    ctFileRead, ctCommand, ctAmbiguousShadow, ctVmFileAccess

  CompileTimeRead = object
    kind: CompileTimeReadKind
    fn: string
    literal: string
    hasLiteral: bool

  LocalDeclKind = enum
    ldRoutine, ldValue

  LocalDecl = object
    kind: LocalDeclKind
    nameIdx: int
      ## Token index of the declared name, so the declaration is never a
      ## use of the symbol, and so a declaration can be told apart from
      ## one that comes textually AFTER a given call.
    moduleScope: bool
      ## The routine keyword is the first token of its line at column 0.
      ## Anything else is nested in a routine body or under a ``when``
      ## branch this scanner cannot evaluate, which makes the file's
      ## overload set undecidable.
    params: seq[NimTok]
    paramDepths: seq[int]
    paramsKnown: bool
      ## False when the parameter list does not close on the line it
      ## opens on: the declaration is then undecidable, not empty.

  ParamTypeClass = enum
    ptString, ptNotString, ptUnknown

  ArgFit = enum
    afAccepts, afRejects, afUnknown

  CallShape = object
    isCall: bool
    argCount: int
    argCountKnown: bool
    args: seq[seq[NimTok]]
      ## The arguments, when ``argCountKnown``.
    firstArgIsStringLiteral: bool
      ## The first argument STARTS with a string literal on the call's own
      ## line -- the shadowing decision's notion of "a string argument".

const
  CompileTimeReadNames = [("staticread", "staticRead"), ("slurp", "slurp"),
                          ("gorgeex", "gorgeEx"), ("gorge", "gorge"),
                          ("staticexec", "staticExec"),
                          ("readfile", "readFile"), ("readlines", "readLines"),
                          ("staticfileexists", "staticFileExists"),
                          ("staticdirexists", "staticDirExists"),
                          ("staticwalkdir", "staticWalkDir"),
                          ("fileexists", "fileExists"),
                          ("direxists", "dirExists"),
                          ("listfiles", "listFiles"), ("listdirs", "listDirs")]
    ## ``nimIdentNorm`` spelling -> canonical name.
  VmFileAccessNames = ["readFile", "readLines", "staticFileExists",
                       "staticDirExists", "staticWalkDir"]
    ## File-system access the compile-time VM performs OUTSIDE
    ## ``vmdeps.opSlurp`` (``vmops`` registers ``readFile`` / ``readLines``
    ## and the ``std/staticos`` procs as VM callbacks). None of them is
    ## recorded as a dependency by the compiler, a relative path is
    ## resolved against the compiler's WORKING DIRECTORY (unknown here),
    ## and ``staticFileExists`` / ``staticDirExists`` / ``staticWalkDir``
    ## observe presence rather than bytes. Measured: ``const c =
    ## readFile("p.txt")`` and ``staticFileExists("flag.txt")`` each put the
    ## file into the generated C while the closure produced a key without
    ## it. So every occurrence is missing evidence -- ``readFile`` /
    ## ``readLines`` too, although they also run at RUN time, because a
    ## routine that calls one can be evaluated at compile time from a
    ## ``const`` anywhere (no occurrence exists in the repository's 338
    ## keyable project roots, so this costs none of them its key).
  ContextFileAccessNames = ["fileExists", "dirExists", "listFiles",
                            "listDirs"]
    ## Existence / listing checks that are common at RUN time in recipe
    ## code (``kwin`` and ``sddm`` probe ``/nix/store`` with them), so they
    ## are missing evidence only where the text evaluates them at COMPILE
    ## time: a ``when`` / ``elif`` condition, a ``const`` section, a
    ## ``static`` block or expression, a ``{.compileTime.}`` declaration, a
    ## ``macro`` body, and anywhere in a NimScript config. A routine called
    ## from one of those is not seen (see the macro residual).
  RoutineKeywords = ["proc", "func", "template", "macro", "method",
                     "iterator", "converter"]
  SectionKeywords = ["let", "var", "const", "type"]
  CommandArgKeywords = ["cast", "addr", "static", "not", "nil", "if", "case",
                        "block", "try", "when", "proc", "func", "iterator"]
    ## Keywords that START an expression, so ``name <keyword>...`` is a
    ## command-syntax call rather than a bare mention.

proc compileTimeReadName(t: NimTok): string =
  if t.kind != ntkIdent:
    return ""
  for (norm, canonical) in CompileTimeReadNames:
    if t.norm == norm:
      return canonical
  ""

proc isKeywordTok(t: NimTok): bool =
  const Keywords = ["addr", "and", "as", "asm", "bind", "block", "break",
    "case", "cast", "concept", "const", "continue", "converter", "defer",
    "discard", "distinct", "div", "do", "elif", "else", "end", "enum",
    "except", "export", "finally", "for", "from", "func", "if", "import",
    "in", "include", "interface", "is", "isnot", "iterator", "let", "macro",
    "method", "mixin", "mod", "nil", "not", "notin", "object", "of", "or",
    "out", "proc", "ptr", "raise", "ref", "return", "shl", "shr", "static",
    "template", "try", "tuple", "type", "using", "var", "when", "while",
    "xor", "yield"]
  t.kind == ntkIdent and not t.quoted and t.norm in Keywords

proc sectionEntryNames(toks: seq[NimTok]; depths: seq[int]; start: int;
                       names: var seq[int]) =
  ## The declared names of a ``let`` / ``var`` / ``const`` / ``type``
  ## entry starting at ``start``: ``a, b*: T = v``, ``name {.p.} = v``.
  ## Nothing is recorded unless the entry really has that shape.
  var m = start
  var candidates: seq[int] = @[]
  while m < toks.len and toks[m].kind == ntkIdent and not isKeywordTok(toks[m]):
    candidates.add(m)
    inc m
    if m < toks.len and isOp(toks[m], "*"):
      inc m
    if m < toks.len and isPunct(toks[m], "{."):
      let close = matchingCloser(toks, depths, m)
      if close < 0:
        return
      m = close + 1
    if m < toks.len and isPunct(toks[m], ","):
      inc m
      continue
    if m < toks.len and (isOp(toks[m], ":") or isOp(toks[m], "=") or
        isPunct(toks[m], "[")):
      for c in candidates:
        names.add(c)
    return

proc localDeclarationsOf(toks: seq[NimTok]; depths: seq[int]):
    Table[string, seq[LocalDecl]] =
  ## Every declaration THIS file makes of a compile-time read's name:
  ## routines, and ``let`` / ``var`` / ``const`` / ``type`` entries in
  ## their one-line and their section form. A section entry is the first
  ## token of a line at the section's ENTRY column; a deeper line is the
  ## continuation of a value (``    slurp "p"``), which is a use.
  result = initTable[string, seq[LocalDecl]]()
  for k, t in toks:
    if t.kind != ntkIdent or t.quoted:
      continue
    if t.norm in RoutineKeywords:
      let nameIdx = k + 1
      if nameIdx >= toks.len or toks[nameIdx].line != t.line:
        continue
      let fn = compileTimeReadName(toks[nameIdx])
      if fn.len == 0:
        continue
      var decl = LocalDecl(kind: ldRoutine, nameIdx: nameIdx,
        moduleScope: t.firstOnLine and t.col == 0, paramsKnown: true)
      var j = nameIdx + 1
      if j < toks.len and isOp(toks[j], "*"):
        inc j
      if j < toks.len and isPunct(toks[j], "["):
        let close = matchingCloser(toks, depths, j)
        if close < 0:
          decl.paramsKnown = false
          j = toks.len
        else:
          j = close + 1
      if j < toks.len and isPunct(toks[j], "(") and decl.paramsKnown:
        let close = matchingCloser(toks, depths, j)
        if close < 0 or toks[close].line != toks[j].line:
          decl.paramsKnown = false
        else:
          for m in j + 1 ..< close:
            decl.params.add(toks[m])
            decl.paramDepths.add(depths[m] - depths[j] - 1)
      result.mgetOrPut(fn, @[]).add(decl)
    elif t.norm in SectionKeywords:
      if k + 1 >= toks.len:
        continue
      var names: seq[int] = @[]
      let next = toks[k + 1]
      if not next.firstOnLine:
        sectionEntryNames(toks, depths, k + 1, names)
      elif next.col > t.lineIndent:
        let entryCol = next.col
        var j = k + 1
        while j < toks.len:
          let u = toks[j]
          if u.firstOnLine:
            if u.col <= t.lineIndent:
              break
            if u.col == entryCol and depths[j] == depths[k]:
              sectionEntryNames(toks, depths, j, names)
          inc j
      for nameIdx in names:
        let fn = compileTimeReadName(toks[nameIdx])
        if fn.len > 0:
          result.mgetOrPut(fn, @[]).add(LocalDecl(kind: ldValue,
            nameIdx: nameIdx))

proc routineParamInfo(decl: LocalDecl):
    tuple[ok: bool, minArity, maxArity: int, variadic: bool,
          firstType: seq[NimTok]] =
  ## Arity and first-parameter type of a parameter list. ``ok`` is false
  ## when the list cannot be read, which makes the declaration
  ## undecidable rather than empty.
  if not decl.paramsKnown:
    return (false, 0, 0, false, @[])
  if decl.params.len == 0:
    return (true, 0, 0, false, @[])
  var items: seq[seq[NimTok]] = @[@[]]
  var itemDepths: seq[seq[int]] = @[@[]]
  for m, t in decl.params:
    if decl.paramDepths[m] == 0 and (isPunct(t, ",") or isPunct(t, ";")):
      items.add(@[])
      itemDepths.add(@[])
    else:
      items[^1].add(t)
      itemDepths[^1].add(decl.paramDepths[m])
  var types: seq[seq[NimTok]] = @[]
  var defaulted: seq[bool] = @[]
  var pendingNames = 0
  for idx, item in items:
    if item.len == 0:
      if pendingNames > 0:
        return (false, 0, 0, false, @[])
      continue
    var colon = -1
    var eq = -1
    for m, t in item:
      if itemDepths[idx][m] != 0:
        continue
      if colon < 0 and isOp(t, ":"): colon = m
      if eq < 0 and isOp(t, "="): eq = m
    if colon < 0 and eq < 0:
      # A bare name sharing the next group's type annotation.
      if item.len != 1:
        return (false, 0, 0, false, @[])
      inc pendingNames
      continue
    if colon < 0 or (eq >= 0 and eq < colon):
      # ``name = default`` with the type inferred: undecidable here.
      return (false, 0, 0, false, @[])
    let typeToks =
      if eq > colon: item[colon + 1 ..< eq]
      else: item[colon + 1 .. ^1]
    for _ in 0 .. pendingNames:
      types.add(typeToks)
      defaulted.add(eq > colon)
    pendingNames = 0
  if pendingNames > 0:
    return (false, 0, 0, false, @[])
  var minArity = 0
  var variadic = false
  for m, t in types:
    if t.len > 0 and t[0].kind == ntkIdent and t[0].norm == "varargs":
      variadic = true
    elif not defaulted[m]:
      minArity = m + 1
  (true, minArity, types.len, variadic,
   if types.len > 0: types[0] else: @[])

proc classifyParamType(typeToks: seq[NimTok]): ParamTypeClass =
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
  ## or may not beat ``system``'s exact one -- and an undecided overload
  ## must refuse rather than ignore. Type names compare the way the
  ## compiler compares identifiers (``nimIdentNorm``).
  const NotString = ["int", "int8", "int16", "int32", "int64", "uint",
                     "uint8", "uint16", "uint32", "uint64", "float",
                     "float32", "float64", "bool", "char", "byte",
                     "Natural", "Positive", "pointer"]
  var m = 0
  while m < typeToks.len and typeToks[m].kind == ntkIdent and
      not typeToks[m].quoted and typeToks[m].norm in ["sink", "lent", "var"]:
    inc m
  if typeToks.len - m != 1 or typeToks[m].kind != ntkIdent:
    return ptUnknown
  let norm = typeToks[m].norm
  if norm == "string":
    return ptString
  for name in NotString:
    if norm == nimIdentNorm(name):
      return ptNotString
  ptUnknown

proc routineFit(decl: LocalDecl; shape: CallShape): ArgFit =
  ## Can this call bind to this declaration?
  let info = routineParamInfo(decl)
  if not info.ok:
    return afUnknown
  if shape.argCount < info.minArity:
    return afRejects
  if shape.argCount > info.maxArity and not info.variadic:
    return afRejects
  if shape.argCount == 0:
    return afAccepts
  if not shape.firstArgIsStringLiteral:
    return afUnknown
  case classifyParamType(info.firstType)
  of ptString: afAccepts
  of ptNotString: afRejects
  of ptUnknown: afUnknown

proc splitArgs(toks: seq[NimTok]; depths: seq[int]; first, last,
               depth: int): seq[seq[NimTok]] =
  ## ``toks[first ..< last]`` split on commas at bracket depth ``depth``.
  result = @[@[]]
  for k in first ..< last:
    if isPunct(toks[k], ",") and depths[k] == depth:
      result.add(@[])
    else:
      result[^1].add(toks[k])
  if result.len == 1 and result[0].len == 0:
    result = @[]

proc startsWithStringLiteral(arg: seq[NimTok]; line: int): bool =
  var m = 0
  while m < arg.len and isPunct(arg[m], "("):
    inc m
  m < arg.len and arg[m].kind == ntkStr and arg[m].line == line

proc callShapeAt(toks: seq[NimTok]; depths: seq[int]; idx: int): CallShape =
  ## Whether the identifier at ``idx`` is CALLED there, with how many
  ## arguments, and what its first argument is -- following the parser:
  ## ``f(a, b)``, ``f"raw"`` (a call with one raw literal), command
  ## syntax ``f a`` (ONE argument inside an enclosing bracket, measured:
  ## ``(slurp "pay", "load.txt")`` reads ``pay``), a ``f:`` block, and
  ## method-call syntax ``"lit".f``.
  let name = toks[idx]
  let d = depths[idx]
  var receiver: seq[NimTok] = @[]
  var hasReceiver = false
  if idx >= 2 and isOp(toks[idx - 1], "."):
    hasReceiver = true
    if toks[idx - 2].kind == ntkStr:
      receiver = @[toks[idx - 2]]
  template done(s: CallShape): CallShape =
    var r = s
    if hasReceiver and toks[idx - 2].kind == ntkStr:
      # Method-call syntax: the literal receiver is the first argument.
      r.isCall = true
      if not s.isCall:
        r.argCountKnown = true
        r.args = @[]
      r.argCount = r.args.len + 1
      r.args = @[receiver] & r.args
      r.firstArgIsStringLiteral = true
    r
  if idx + 1 >= toks.len:
    return done(CallShape(isCall: false, argCountKnown: true))
  let nt = toks[idx + 1]
  if nt.firstOnLine:
    return done(CallShape(isCall: false, argCountKnown: true))
  if isPunct(nt, "(") and nt.offset == name.endOffset:
    let close = matchingCloser(toks, depths, idx + 1)
    if close < 0:
      return done(CallShape(isCall: true, argCountKnown: false))
    let args = splitArgs(toks, depths, idx + 2, close, d + 1)
    result = CallShape(isCall: true, argCount: args.len, argCountKnown: true,
      args: args)
    if args.len > 0:
      result.firstArgIsStringLiteral = startsWithStringLiteral(args[0], name.line)
    if close + 1 < toks.len and (isOp(toks[close + 1], ":") or
        isKw(toks[close + 1], "do")) and not toks[close + 1].firstOnLine:
      # A trailing block may be one more argument: undecidable.
      result.argCountKnown = false
    return done(result)
  if nt.kind == ntkStr and nt.generalized:
    # ``name"raw"`` is ``name(r"raw")``: its argument is that literal.
    var arg = nt
    arg.generalized = false
    return done(CallShape(isCall: true, argCount: 1, argCountKnown: true,
      args: @[@[arg]], firstArgIsStringLiteral: true))
  if isOp(nt, ":"):
    if d > 0:
      # ``(slurp: x)`` / ``Obj(slurp: x)``: a field name, not a call.
      return done(CallShape(isCall: false, argCountKnown: true))
    # A ``name:`` block call: the block is the one argument.
    var content: seq[NimTok] = @[]
    let base = name.lineIndent
    var j = idx + 2
    while j < toks.len:
      let u = toks[j]
      if u.firstOnLine and u.col <= base:
        break
      if u.line == nt.line and isPunct(u, ";") and depths[j] == d:
        break
      content.add(u)
      inc j
    return done(CallShape(isCall: true, argCount: 1, argCountKnown: true,
      args: @[content],
      firstArgIsStringLiteral: startsWithStringLiteral(content, name.line)))
  let spaced = nt.offset > name.endOffset
  var commandArg = false
  case nt.kind
  of ntkStr, ntkChar, ntkNumber, ntkIdent:
    # Blank or not: with no blank, only a backtick-quoted name can precede
    # one of these (```slurp`"p"`` reads ``p``, measured -- the literal is
    # NOT generalized, the byte before its quote being a backtick).
    commandArg = nt.kind != ntkIdent or not isKeywordTok(nt) or
      (not nt.quoted and nt.norm in CommandArgKeywords)
  of ntkPunct:
    commandArg = spaced and (isPunct(nt, "(") or isPunct(nt, "[") or
      isPunct(nt, "{"))
    if not spaced and isPunct(nt, "["):
      # ``slurp[T](...)``: a generic instantiation or an index -- a call
      # this scanner cannot shape.
      return done(CallShape(isCall: true, argCountKnown: false))
  of ntkOp:
    # A prefix operator (blank before, none after) starts a command-syntax
    # argument: ``slurp $name``.
    commandArg = spaced and idx + 2 < toks.len and
      toks[idx + 2].offset == nt.endOffset and
      not toks[idx + 2].firstOnLine and not isOp(nt, "=") and
      not isOp(nt, ".")
  of ntkInvalid:
    commandArg = false
  if not commandArg:
    return done(CallShape(isCall: false, argCountKnown: true))
  # Command syntax. Its arguments run to the end of the statement; inside
  # an enclosing bracket the first comma ends it (one argument).
  let e = statementEnd(toks, depths, idx + 1, d)
  var args = splitArgs(toks, depths, idx + 1, e, d)
  result = CallShape(isCall: true, argCountKnown: true)
  if d > 0 and args.len > 1:
    args.setLen(1)
  result.argCount = args.len
  result.args = args
  if args.len > 0:
    result.firstArgIsStringLiteral = startsWithStringLiteral(args[0], name.line)
  for k in idx + 1 ..< e:
    if depths[k] == d and isOp(toks[k], ":"):
      # ``if slurp "p": ...`` vs a block argument: undecidable.
      result.argCountKnown = false
  return done(result)

proc shadowVerdict(decls: seq[LocalDecl]; shape: CallShape;
                   idx: int): ArgFit =
  ## Does THIS file's own declaration capture THIS occurrence?
  ##
  ## ``afAccepts`` -- yes: the occurrence is the local symbol and binds
  ## nothing. ``afRejects`` -- no local declaration can take this call,
  ## so it reaches ``system``'s compile-time read. ``afUnknown`` -- the
  ## text does not decide it, which is missing evidence and refuses.
  ##
  ## The rule is per CALL, not per FILE. A declaration counts against a
  ## call only where the COMPILER would apply it: at module scope, and
  ## textually BEFORE the call. Measured against nim 2.2.8, every one of
  ## these READS the payload even though the file declares ``proc
  ## slurp(label: string)``: the declaration placed after the call, the
  ## declaration nested inside another routine's body, the declaration
  ## under ``when false:``, and under ``when defined(flagNeverSet):``.
  ## A non-routine declaration (``const gorge = 3``) never stops a CALL
  ## reaching the stdlib symbol.
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
      continue
    if decl.nameIdx >= idx:
      # Declared AFTER this call: it does not exist yet here.
      continue
    if not decl.moduleScope:
      # Nested in a body, or under a ``when`` branch whose liveness this
      # scanner cannot evaluate: undecidable, which REFUSES.
      undecidable = true
      continue
    case routineFit(decl, shape)
    of afAccepts: return afAccepts
    of afUnknown: verdict = afUnknown
    of afRejects: discard
  if undecidable: afUnknown else: verdict

proc indentedBlockEnd(toks: seq[NimTok]; start, indent: int): int =
  ## First token at or after ``start`` that begins a line at column
  ## ``<= indent``: the end of the block a construct at ``indent`` opens.
  var j = start
  while j < toks.len:
    if toks[j].firstOnLine and toks[j].col <= indent:
      return j
    inc j
  toks.len

proc compileTimeContext(toks: seq[NimTok]; depths: seq[int]): HashSet[int] =
  ## Token indices the compiler evaluates at COMPILE time, as far as the
  ## text shows it: ``when`` / ``elif``-of-``when`` conditions, ``const``
  ## statements and sections, ``static:`` blocks and ``static(...)``, a
  ## statement carrying ``{.compileTime.}`` (with its body), and ``macro``
  ## bodies. Over-marking is the safe direction: it can only refuse.
  result = initHashSet[int]()
  var lastWhenOrIf: seq[tuple[col: int, isWhen: bool]] = @[]
  for k, t in toks:
    if t.kind != ntkIdent or t.quoted:
      continue
    case t.norm
    of "when", "if":
      if t.firstOnLine:
        lastWhenOrIf.add((t.col, t.norm == "when"))
      if t.norm == "when":
        var j = k + 1
        while j < toks.len and not (isOp(toks[j], ":") and depths[j] == depths[k]):
          result.incl(j)
          inc j
    of "elif":
      var isWhen = false
      if t.firstOnLine:
        # The ``when`` / ``if`` this ``elif`` continues: the latest one that
        # opened a line at the same column.
        for m in countdown(lastWhenOrIf.len - 1, 0):
          if lastWhenOrIf[m].col == t.col:
            isWhen = lastWhenOrIf[m].isWhen
            break
      else:
        # An inline ``elif``: of a ``when`` if one opens earlier on the line.
        isWhen = false
        for m in countdown(k - 1, 0):
          if toks[m].line != t.line: break
          if isKw(toks[m], "when"): isWhen = true; break
          if isKw(toks[m], "if"): break
      if isWhen:
        var j = k + 1
        while j < toks.len and not (isOp(toks[j], ":") and depths[j] == depths[k]):
          result.incl(j)
          inc j
    of "const", "macro":
      let e = indentedBlockEnd(toks, k + 1, t.lineIndent)
      for j in k + 1 ..< e:
        result.incl(j)
    of "static":
      if k + 1 < toks.len and isPunct(toks[k + 1], "("):
        let close = matchingCloser(toks, depths, k + 1)
        let e = if close < 0: toks.len else: close
        for j in k + 1 .. min(e, toks.len - 1):
          result.incl(j)
      elif k + 1 < toks.len and isOp(toks[k + 1], ":"):
        let e = indentedBlockEnd(toks, k + 2, t.lineIndent)
        for j in k + 1 ..< e:
          result.incl(j)
    of "compiletime":
      # The whole statement the pragma sits in, and its indented body.
      var first = k
      while first > 0 and not toks[first].firstOnLine:
        dec first
      let e = indentedBlockEnd(toks, k + 1, toks[first].col)
      for j in first ..< e:
        result.incl(j)
    else:
      discard

proc compileTimeReadsOf(toks: seq[NimTok]; depths: seq[int];
                        covered: HashSet[int];
                        allCompileTime = false): seq[CompileTimeRead] =
  ## Every compile-time file read / command execution. These have no
  ## import syntax at all, so without this the bytes they fold into the
  ## build are invisible to the closure.
  ##
  ## An occurrence is any identifier token the compiler takes for
  ## ``staticRead`` / ``slurp`` / ``gorge`` / ``gorgeEx`` /
  ## ``staticExec`` -- any style-insensitive spelling, quoted or not --
  ## outside an import statement. A literal or a comment is not a token,
  ## so a mention inside one is not an occurrence. A DECLARATION of the
  ## name is not a use of it, and a call this file's OWN overload
  ## provably takes is that overload rather than the stdlib's. What the
  ## text does not decide is missing evidence and refuses. An occurrence
  ## after a ``.`` (``system.slurp``, ``mymod.slurp``, ``"p".slurp``) is
  ## never excluded by shadowing.
  let decls = localDeclarationsOf(toks, depths)
  let ctx = if allCompileTime: initHashSet[int]()
            else: compileTimeContext(toks, depths)
  var declIdx = initHashSet[int]()
  for _, list in decls:
    for decl in list:
      declIdx.incl(decl.nameIdx)
  for idx, t in toks:
    let fn = compileTimeReadName(t)
    if fn.len == 0 or idx in declIdx or idx in covered:
      continue
    let isFileRead = fn in ["staticRead", "slurp"]
    let shape = callShapeAt(toks, depths, idx)
    let dotted = idx > 0 and isOp(toks[idx - 1], ".")
    let local = decls.getOrDefault(fn)
    if local.len > 0 and not dotted:
      case shadowVerdict(local, shape, idx)
      of afAccepts: continue
      of afUnknown:
        result.add(CompileTimeRead(kind: ctAmbiguousShadow, fn: fn))
        continue
      of afRejects: discard
    if fn in VmFileAccessNames:
      result.add(CompileTimeRead(kind: ctVmFileAccess, fn: fn))
      continue
    if fn in ContextFileAccessNames:
      if allCompileTime or idx in ctx:
        result.add(CompileTimeRead(kind: ctVmFileAccess, fn: fn))
      continue
    if not isFileRead:
      result.add(CompileTimeRead(kind: ctCommand, fn: fn))
      continue
    var literal = ""
    let known = shape.isCall and shape.argCountKnown and
      shape.argCount == 1 and shape.args.len == 1 and
      evalConstString(shape.args[0], literal)
    result.add(CompileTimeRead(kind: ctFileRead, fn: fn, literal: literal,
      hasLiteral: known))

type
  PathSubsVerdict = enum
    psUnchanged, psExpanded, psExternal, psUnknown

proc expandModulePathSubs(spec, projectRoot, fromDir, entryStem: string;
                          expanded: var string): PathSubsVerdict =
  ## ``modulepaths.getModuleName`` passes a STRING-literal module name
  ## through ``options.pathSubs`` before resolving it: ``strutils.%`` over
  ## ``$nim``, ``$lib``, ``$home``, ``$config``, ``$projectname``,
  ## ``$projectpath``, ``$projectdir`` and ``$nimcache`` (names compared
  ## ignoring style, ``${name}`` accepted, ``$$`` a literal ``$``), then
  ## ``expandTilde``. Measured: ``import "$projectdir/helper"`` compiles and
  ## reads ``helper.nim``, while the unexpanded spec named no file and was
  ## classed as an external library. The project-relative substitutions
  ## are evaluated (``$config`` is the importing file's directory);
  ## ``$lib`` / ``$nim`` name the standard library, which is external; any
  ## other substitution (``$home``, ``$nimcache``, ``~``) is unknown.
  if '$' notin spec and not spec.startsWith("~"):
    return psUnchanged
  if spec.startsWith("~"):
    return psUnknown
  var i = 0
  var external = false
  while i < spec.len:
    let c = spec[i]
    if c != '$':
      expanded.add(c)
      inc i
      continue
    if i + 1 >= spec.len:
      return psUnknown
    var name = ""
    if spec[i + 1] == '$':
      expanded.add('$')
      i += 2
      continue
    elif spec[i + 1] == '{':
      let close = spec.find('}', i + 2)
      if close < 0:
        return psUnknown
      name = spec[i + 2 ..< close]
      i = close + 1
    elif spec[i + 1] in {'a'..'z', 'A'..'Z', '\128'..'\255', '_'}:
      var j = i + 1
      while j < spec.len and spec[j] in {'a'..'z', 'A'..'Z', '0'..'9',
                                         '\128'..'\255', '_'}:
        inc j
      name = spec[i + 1 ..< j]
      i = j
    else:
      return psUnknown
    case strutils.normalize(name)
    of "projectdir", "projectpath": expanded.add(projectRoot)
    of "config": expanded.add(fromDir)
    of "projectname": expanded.add(entryStem)
    of "lib", "nim":
      external = true
      expanded.add("$" & name)
    else:
      return psUnknown
  if external: psExternal else: psExpanded

proc isExternalModuleSpec(spec: string): bool =
  spec.len == 0 or spec == "system" or spec == "std" or spec == "pkg" or
    spec.startsWith("std/")

proc hasNimSourceExt(spec: string): bool =
  spec.splitFile().ext.toLowerAscii() in NimSourceExts

# ---------------------------------------------------------------------------
# Spec resolution
# ---------------------------------------------------------------------------

proc specCandidates(base, spec: string; isInclude: bool): seq[string] =
  ## The ONE file ``options.findModule`` tries at ``base``:
  ## ``addFileExt(spec, "nim")`` -- the spec as written when it carries any
  ## extension (``import "helper.x"`` reads ``helper.x``), else with
  ## ``.nim`` appended. Import and include alike.
  ##
  ## The appended ``.nim`` this scanner used to add unconditionally was
  ## the wrong file for any extension but a Nim one.
  discard isInclude
  let joined = normSlash(if spec.isAbsolute: spec else: base / spec)
  if joined.len == 0:
    return
  if searchExtPos(spec) >= 0:
    result.add(joined)
  else:
    result.add(joined & ".nim")

proc extraCandidates(base, spec: string): seq[string] =
  ## Files this scanner ALSO binds for an extensionless spec although the
  ## compiler never tries them: ``<spec>.nims`` and a package directory's
  ## ``<spec>/<spec>.nim``. Binding them is an over-approximation; STOPPING
  ## the search at one, as this scanner used to, was not: a
  ## ``sub/helper.nims`` or ``sub/helper/helper.nim`` beside the importing
  ## file bound itself while nim read ``lib/helper.nim`` through ``--path``,
  ## which was never bound (measured by the verifier's corpus). So they
  ## are collected, and the search for the file nim reads goes on.
  if searchExtPos(spec) >= 0:
    return
  let joined = normSlash(if spec.isAbsolute: spec else: base / spec)
  if joined.len == 0:
    return
  result.add(joined & ".nims")
  let leaf = joined.lastPathPart
  if leaf.len > 0:
    result.add(joined & "/" & leaf & ".nim")

proc resolveSpec(spec: string; isInclude: bool; fromDir: string;
                 searchRoots: seq[string]; extras: var seq[string]): string =
  ## ``searchRoots`` is in the compiler's search order (see
  ## ``collectSearchRoots``). ``pkg/x`` is ``x`` looked up in the search
  ## roots only (``options.findModule``: ``findFile`` with the standard
  ## library suppressed) -- which CAN be a project root: ``--path:"lib"``
  ## plus ``import pkg/libmod`` reads ``lib/libmod.nim``.
  var bases: seq[string] = @[]
  var target = spec
  if spec.startsWith("pkg/"):
    target = spec["pkg/".len .. ^1]
    for root in searchRoots:
      bases.add(root)
  elif spec.isAbsolute:
    bases.add("")
  elif spec.startsWith("./") or spec.startsWith("../"):
    bases.add(fromDir)
  else:
    bases.add(fromDir)
    for root in searchRoots:
      if pathKey(root) != pathKey(fromDir):
        bases.add(root)
  ## ``extras`` receives every ``extraCandidates`` file that exists at a
  ## base searched before the one that resolves (all of them when nothing
  ## resolves): bound too, never a reason to stop.
  for base in bases:
    for candidate in specCandidates(base, target, isInclude):
      if fileExists(cacheIdentityExtendedPath(candidate)):
        return candidate
    for extra in extraCandidates(base, target):
      if fileExists(cacheIdentityExtendedPath(extra)):
        extras.add(extra)
  # ``options.findFile``: when no search root has the spelling as written,
  # the roots are searched again for the LOWER-CASED spelling. Irrelevant
  # on a case-insensitive filesystem; on Linux ``import Helper`` then reads
  # ``lib/helper.nim``.
  if not (spec.isAbsolute or spec.startsWith("./") or
      spec.startsWith("../")) and target != target.toLowerAscii:
    for root in searchRoots:
      for candidate in specCandidates(root, target.toLowerAscii, isInclude):
        if fileExists(cacheIdentityExtendedPath(candidate)):
          return candidate
  ""

proc isCandidateLocalSpec(spec: string; isInclude: bool; fromDir: string;
                          searchRoots: seq[string];
                          dynamicSearchPath: bool): bool =
  ## See the module docstring, "External library vs unresolvable local
  ## module". True means "this could be project source" and therefore
  ## must refuse rather than be dropped.
  if spec.startsWith("pkg/"):
    # Resolved through the search roots only, so it can be project source
    # only through a root this scanner does not know.
    return dynamicSearchPath
  if spec.startsWith("./") or spec.startsWith("../") or spec.isAbsolute:
    return true
  if isInclude:
    return true
  if hasNimSourceExt(spec) or searchExtPos(spec) >= 0:
    # Any extension: ``addFileExt`` keeps it, so the spec names a file.
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

const
  PathSwitches = ["path", "p"]
    ## ``commands.processSwitch`` matches ``switch.normalize`` -- every
    ## character lower-cased, underscores dropped -- so ``--Path``,
    ## ``PATH``, ``--pa_th`` and ``P`` are all this switch.
  SourceRelocatingSwitches = ["import", "include", "lib", "excludepath"]
    ## Normalised switch names that make the compiler READ a module no
    ## statement names (``--import`` / ``--include`` pull one into every
    ## module), relocate the standard library (``--lib``, after which a
    ## ``std/`` spec can be project source), or remove a search root the
    ## scanner would otherwise resolve through (``--excludePath``). None
    ## of them can be bound from here, so each one refuses.
  UnknownRootSwitches = ["nimblepath"]
    ## Adds package roots a bare spec may resolve through: the root set
    ## becomes unknown (rule 4).

type
  ConfigScan = object
    roots: seq[string]
      ## Config search roots in the order the compiler PROCESSES them.
    dynamic: bool
      ## A path switch was seen whose value this scanner cannot evaluate:
      ## the search-root set is unknown.
    refusals: seq[string]
      ## Config evidence that cannot be bound at all.
    files: seq[string]
      ## Every config file the compiler reads for this project (``nim.cfg``,
      ## ``config.nims``, ``<entry>.nimcfg`` / ``<entry>.nim.cfg``,
      ## ``<entry>.nims``, a script one of them includes or imports, the
      ## root's ``*.nimble``) and every file a NimScript config reads with
      ## ``slurp`` / ``staticRead``. Their BYTES are bound into the closure:
      ## see "Config files are source" in the module docstring.

proc applySwitch(scan: var ConfigScan; key, configName, configDir,
                 projectRoot: string; value: string; valueIsLiteral: bool) =
  ## Apply one config switch. ``value`` is meaningful only when
  ## ``valueIsLiteral``.
  let normKey = strutils.normalize(key)
  if normKey in PathSwitches:
    if not valueIsLiteral:
      scan.dynamic = true
      return
    let expanded = expandConfigValue(value, configDir)
    if '$' in expanded or expanded.len == 0:
      scan.dynamic = true
      return
    addSearchRoot(scan.roots, projectRoot, configDir, expanded)
  elif normKey in SourceRelocatingSwitches:
    scan.refusals.add("config switch --" & key & " in " & configName &
      " (it makes the compiler read or relocate source that no statement " &
      "names)")
  elif normKey in UnknownRootSwitches:
    scan.dynamic = true

proc scanNimCfg(scan: var ConfigScan; text, configName, configDir,
                projectRoot: string) =
  ## A ``nim.cfg`` / ``<entry>.nim.cfg`` / ``<entry>.nimcfg`` file, read
  ## as ``nimconf.parseAssignment`` reads it: with Nim's own lexer, so a
  ## comment, a line break or blanks may sit anywhere between the key,
  ## the ``:`` / ``=`` / ``%=`` and the value. ``@if`` branches are not
  ## evaluated: a switch in any branch counts (an over-approximation).
  let toks = nimTokens(text)
  var i = 0
  while i < toks.len:
    let t = toks[i]
    if isOp(t, "@"):
      # A directive. Its condition names defines, not files.
      inc i
      if i < toks.len and (isKw(toks[i], "if") or isKw(toks[i], "elif")):
        while i < toks.len and not isOp(toks[i], ":"):
          inc i
        inc i
      elif i < toks.len and toks[i].kind == ntkIdent and
          toks[i].norm in ["putenv", "prependenv", "appendenv"]:
        i += 3
      elif i < toks.len and toks[i].kind == ntkIdent and toks[i].norm == "write":
        i += 2
      else:
        inc i
        if i < toks.len and isOp(toks[i], ":"):
          inc i
      continue
    if isOp(t, "-") or isOp(t, "--"):
      inc i
    if i >= toks.len:
      break
    let keyTok = toks[i]
    var key = if keyTok.kind == ntkStr: keyTok.value else: keyTok.text
    inc i
    while i + 1 < toks.len and isOp(toks[i], "."):
      key.add("." & toks[i + 1].text)
      i += 2
    if i < toks.len and isPunct(toks[i], "["):
      while i < toks.len and not isPunct(toks[i], "]"):
        inc i
      inc i
    var valueToks: seq[NimTok] = @[]
    var percent = false
    var wellFormed = true
    if i < toks.len and (isOp(toks[i], ":") or isOp(toks[i], "=") or
        isOp(toks[i], "%=")):
      percent = toks[i].text == "%="
      inc i
      if i < toks.len:
        valueToks.add(toks[i])
        inc i
      if i + 1 < toks.len and (isOp(toks[i], ":") or isOp(toks[i], "=")):
        valueToks.add(toks[i])
        valueToks.add(toks[i + 1])
        i += 2
      while i + 1 < toks.len and isOp(toks[i], "&"):
        valueToks.add(toks[i])
        valueToks.add(toks[i + 1])
        i += 2
    elif i < toks.len and toks[i].kind == ntkOp and
        (toks[i].text[0] in {':', '='} or toks[i].text.startsWith("%=")):
      # ``--path:./lib`` lexes ``:./`` as ONE operator, which ``nimconf``
      # does not accept as a separator. Not a value this scanner can read.
      wellFormed = false
      inc i
    var value = ""
    var literal = false
    if wellFormed and not percent and valueToks.len == 1:
      let v = valueToks[0]
      if v.kind == ntkStr and v.valueKnown and not v.generalized:
        value = v.value
        literal = true
      elif v.kind in {ntkIdent, ntkNumber}:
        value = v.text
        literal = true
    applySwitch(scan, key, configName, configDir, projectRoot, value, literal)

proc singleStringLiteral(arg: seq[NimTok]; value: var string): bool =
  if arg.len == 1 and arg[0].kind == ntkStr and arg[0].valueKnown and
      not arg[0].generalized:
    value = arg[0].value
    return true
  false

proc scanNimScriptConfig(scan: var ConfigScan; path, projectRoot: string;
                         visited: var HashSet[string]; depth: int) =
  ## A ``config.nims`` / ``<entry>.nims`` file -- ordinary Nim code, so a
  ## ``switch`` call may be wrapped (``when true: switch(...)``), spread
  ## over lines, written in command syntax or spelled in any style, and
  ## all of those count. So does ``--key:value``, the ``nimscript``
  ## template. ``when`` / ``if`` are not evaluated: every switch counts.
  ## A local script this one ``include``s or ``import``s is followed.
  let key = pathKey(path)
  if key in visited:
    return
  visited.incl(key)
  let configName = extractFilename(path)
  var text = ""
  try:
    text = readFile(cacheIdentityExtendedPath(path))
  except CatchableError:
    # A config file we cannot read is a search-root set we cannot know.
    scan.dynamic = true
    return
  scan.files.add(path)
  let configDir = normSlash(parentDir(path))
  let toks = nimTokens(text)
  let depths = bracketDepths(toks)
  # A NimScript config is evaluated by the VM from top to bottom, so every
  # read in it is a compile-time read: ``slurp`` / ``staticRead`` of a
  # constant path is bound like any other (``vmdeps.opSlurp`` resolves it
  # against the script's own directory), everything else refuses.
  let scriptImports = importStatementsOf(toks, depths)
  for read in compileTimeReadsOf(toks, depths, scriptImports.covered,
                                 allCompileTime = true):
    if read.kind == ctFileRead and read.hasLiteral:
      let candidate =
        if read.literal.isAbsolute: normSlash(read.literal)
        else: normSlash(configDir / read.literal)
      if fileExists(cacheIdentityExtendedPath(candidate)):
        scan.files.add(candidate)
        continue
    scan.refusals.add("config script " & configName & ": " & read.fn &
      "() it evaluates at compile time cannot be bound")
  for k, t in toks:
    if t.kind == ntkIdent and t.norm == "switch":
      let shape = callShapeAt(toks, depths, k)
      if not shape.isCall or not shape.argCountKnown:
        scan.refusals.add("switch in " & configName &
          " that this scanner cannot read")
        continue
      var keyArg, valueArg: seq[NimTok] = @[]
      var positional = 0
      for arg in shape.args:
        var a = arg
        var slot = ""
        if a.len >= 2 and a[0].kind == ntkIdent and isOp(a[1], "="):
          slot = a[0].norm
          a = a[2 .. ^1]
        elif positional == 0:
          slot = "key"
          inc positional
        else:
          slot = "val"
          inc positional
        if slot == "key": keyArg = a
        elif slot == "val": valueArg = a
      var switchName = ""
      if not singleStringLiteral(keyArg, switchName):
        scan.refusals.add("switch in " & configName &
          " whose name is not a string literal")
        continue
      var value = ""
      let literal = singleStringLiteral(valueArg, value)
      applySwitch(scan, switchName, configName, configDir, projectRoot,
        value, literal)
    elif isOp(t, "--") and k + 1 < toks.len and toks[k + 1].kind == ntkIdent and
        toks[k + 1].offset == t.endOffset:
      # ``template `--`(key, val: untyped) = switch(astToStr(key),
      # astToStr(val))``: the value is the SOURCE TEXT of one token, which
      # ``processCfgPath`` unescapes when it is a plain quoted literal.
      let switchName = toks[k + 1].text
      var value = ""
      var literal = false
      if k + 2 < toks.len and isOp(toks[k + 2], ":") and
          not toks[k + 2].firstOnLine:
        let e = statementEnd(toks, depths, k + 3, depths[k])
        if e == k + 4:
          let v = toks[k + 3]
          if v.kind == ntkStr and v.valueKnown and not v.generalized and
              v.text.startsWith("\"") and not v.text.startsWith("\"\"\""):
            value = v.value
            literal = true
          elif v.kind in {ntkIdent, ntkNumber}:
            value = v.text
            literal = true
      applySwitch(scan, switchName, configName, configDir, projectRoot,
        value, literal)
    elif t.kind == ntkIdent and t.norm == "patchfile":
      scan.refusals.add("patchFile in " & configName &
        " (it replaces a module with a file no statement names)")
  let imports = scriptImports
  for u in imports.unevaluable:
    scan.refusals.add("config script " & configName & ": " & u)
  for original in imports.refs:
    var reference = original
    var substituted = ""
    case expandModulePathSubs(reference.spec, projectRoot, configDir,
                              "", substituted)
    of psUnchanged: discard
    of psExpanded: reference.spec = substituted
    of psExternal: continue
    of psUnknown:
      scan.refusals.add("config script " & configName &
        ": module path substitution " & reference.spec)
      continue
    if isExternalModuleSpec(reference.spec) or reference.spec.startsWith("pkg/"):
      continue
    var found = ""
    for candidate in specCandidates(configDir, reference.spec,
                                    reference.isInclude) &
                     extraCandidates(configDir, reference.spec):
      if fileExists(cacheIdentityExtendedPath(candidate)):
        found = candidate
        break
    if found.len > 0:
      if depth < 8:
        scanNimScriptConfig(scan, found, projectRoot, visited, depth + 1)
      else:
        scan.refusals.add("config script include depth in " & configName)
    elif isCandidateLocalSpec(reference.spec, reference.isInclude, configDir,
                              @[], false):
      scan.refusals.add("config script " & configName &
        " reaches an unresolved local script " & reference.spec)

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
                        roots: var seq[string]; dynamic: var bool;
                        refusals: var seq[string];
                        configFiles: var seq[string]) =
  ## The search roots, IN THE ORDER THE COMPILER SEARCHES THEM, after the
  ## importing file's own directory:
  ##
  ##   1. the config roots, LAST-processed first. ``nimblecmd.addPath``
  ##      inserts every ``--path`` at the FRONT of ``searchPaths`` (and
  ##      ignores one already present), and ``nimconf.loadConfigs``
  ##      processes ``nim.cfg``, ``config.nims``, ``<entry>.nimcfg`` (or,
  ##      when that is absent, ``<entry>.nim.cfg``), then ``<entry>.nims``;
  ##   2. the nimble ``srcDir`` (nimble passes it on the command line);
  ##   3. the caller's effective roots -- the command line, processed
  ##      before the config files and therefore searched after them, and
  ##      among themselves last-given first for the same ``addPath``
  ##      reason;
  ##   4. the project root itself, LAST. The compiler never searches it
  ##      (it is not in ``searchPaths``; measured: a subdirectory's
  ##      ``import toplevel`` does not compile), so resolving through it is
  ##      an over-approximation -- and searching it FIRST, as this scanner
  ##      did, made a subdirectory's ``import helper`` bind the root's
  ##      ``helper.nim`` while the compiler read ``lib/helper.nim``
  ##      through ``--path:"lib"`` (a false accept the oracle measured).
  var scan = ConfigScan()
  var visited = initHashSet[string]()
  var configNames = @["nim.cfg", "config.nims"]
  if entryPath.len > 0:
    let stem = entryPath.splitFile().name
    if fileExists(cacheIdentityExtendedPath(projectRoot / (stem & ".nimcfg"))):
      configNames.add(stem & ".nimcfg")
    else:
      configNames.add(stem & ".nim.cfg")
    configNames.add(stem & ".nims")
  for name in configNames:
    let path = normSlash(projectRoot / name)
    if not fileExists(cacheIdentityExtendedPath(path)):
      continue
    if name.endsWith(".nims"):
      scanNimScriptConfig(scan, path, projectRoot, visited, 0)
      continue
    var text = ""
    try:
      text = readFile(cacheIdentityExtendedPath(path))
    except CatchableError:
      # A config file we cannot read is a search-root set we cannot know.
      scan.dynamic = true
      continue
    scan.files.add(path)
    scanNimCfg(scan, text, name, projectRoot, projectRoot)
  for k in countdown(scan.roots.len - 1, 0):
    addSearchRoot(roots, projectRoot, projectRoot, scan.roots[k])
  dynamic = dynamic or scan.dynamic
  for r in scan.refusals:
    refusals.add(r)
  for f in scan.files:
    configFiles.add(f)
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
    configFiles.add(normSlash(nimbleFile))
    let srcDir = parseNimbleSrcDir(text)
    if srcDir.len > 0:
      addSearchRoot(roots, projectRoot, projectRoot, srcDir)
  for k in countdown(suppliedSearchRoots.len - 1, 0):
    addSuppliedSearchRoot(roots, projectRoot, suppliedSearchRoots[k])
  addSearchRoot(roots, projectRoot, projectRoot, projectRoot)

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
  var configRefusals: seq[string] = @[]
  var configFiles: seq[string] = @[]
  collectSearchRoots(root, entryPath, effectiveSearchRoots, searchRoots,
    dynamicSearchPath, configRefusals, configFiles)
  for refusal in configRefusals:
    missing.add(refusal)

  var contentByRel = initTable[string, string]()
  var queued = initHashSet[string]()
  var pending: seq[tuple[path: string, scan: bool]] = @[]

  # Config files are source: their BYTES enter the closure. A ``--define``
  # in ``nim.cfg`` selects a ``when defined(...)`` branch, so two trees that
  # differ only there compile different code -- and, with the config files
  # read only for their ``--path`` switches, got ONE key (measured: two
  # trees differing in ``-d:variantB``, ``impl`` 1 vs 2 in the generated C,
  # key ``c0b23ff7...`` for both). Bound, not interpreted: every switch a
  # config file can carry (``--define``, ``--undef``, ``--mm``, ``--opt``,
  # ``-d:release`` ...) moves the key, which is the safe direction.
  for configFile in configFiles:
    let key = pathKey(configFile)
    if key notin queued:
      queued.incl(key)
      pending.add((configFile, false))

  let entryStem = if entryPath.len > 0: entryPath.splitFile().name else: ""
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
    let toks = nimTokens(body)
    let depths = bracketDepths(toks)
    let imports = importStatementsOf(toks, depths)
    for expression in imports.unevaluable:
      # The compiler reads SOME module here; which one is not decidable
      # from the text, so the closure cannot be complete.
      missing.add("import expression this scanner cannot evaluate in " &
        rel & ": " & expression)
    for original in imports.refs:
      var reference = original
      var substituted = ""
      case expandModulePathSubs(reference.spec, root, fromDir, entryStem,
                                substituted)
      of psUnchanged: discard
      of psExpanded: reference.spec = substituted
      of psExternal: continue
      of psUnknown:
        missing.add("module path substitution this scanner cannot evaluate " &
          "in " & rel & ": " & reference.spec)
        continue
      if isExternalModuleSpec(reference.spec) or
          (reference.alt.len > 0 and isExternalModuleSpec(reference.alt)):
        continue
      var extras: seq[string] = @[]
      let resolved = resolveSpec(reference.spec, reference.isInclude,
        fromDir, searchRoots, extras)
      if reference.alt.len > 0:
        # A dotted name: bind the file nim reads (the ``alt`` reading) AND
        # the literal one this scanner used to bind -- over-approximating,
        # never stopping at the wrong one. Neither found is judged below
        # under BOTH readings.
        let altResolved = resolveSpec(reference.alt, reference.isInclude,
          fromDir, searchRoots, extras)
        if altResolved.len > 0:
          extras.add(altResolved)
      for extra in extras:
        if projectRelative(root, extra).inside:
          let key = pathKey(extra)
          if key notin queued:
            queued.incl(key)
            pending.add((extra, true))
      if resolved.len == 0 and extras.len > 0:
        continue
      if resolved.len > 0:
        if not projectRelative(root, resolved).inside:
          # Resolved, but not project source: an external library.
          continue
        let key = pathKey(resolved)
        if key notin queued:
          queued.incl(key)
          pending.add((resolved, true))
      elif isCandidateLocalSpec(reference.spec, reference.isInclude, fromDir,
          searchRoots, dynamicSearchPath) or
          (reference.alt.len > 0 and isCandidateLocalSpec(reference.alt,
            reference.isInclude, fromDir, searchRoots, dynamicSearchPath)):
        missing.add("unresolved local " &
          (if reference.isInclude: "include " else: "import ") &
          reference.spec & " from " & rel)
    for read in compileTimeReadsOf(toks, depths, imports.covered):
      case read.kind
      of ctCommand:
        missing.add("compile-time command execution " & read.fn & "() in " &
          rel & " (its output cannot be bound)")
      of ctVmFileAccess:
        missing.add("compile-time file-system access " & read.fn & "() in " &
          rel & " (the compiler does not record it, and it resolves a " &
          "relative path against its working directory)")
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
        # ``vmdeps.opSlurp``: the reading file's own directory, then
        # ``findFile`` over the search roots, in the compiler's order (the
        # project root last, as the over-approximation it is).
        var resolvedRead = ""
        for base in @[fromDir] & searchRoots:
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
