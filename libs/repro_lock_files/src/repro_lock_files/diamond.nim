## The diamond join — §9. Unify when possible; refuse co-linkage only where the
## library forbids it, and only **at the link closure**.
##
## Named-Lock-Files NLF-M8.
##
## ## The scope rule, which is the whole of this module
##
## §9's opening sentence names the shape: "Two edges under different lock files
## feeding one artifact." The corpus states the rule this module exists to hold
## in one line (`Named-Lock-Files-Test-Corpus.md` §4):
##
## > A workspace containing two versions of `libfoo` is **normal and allowed**.
## > A *binary* linking two is the error.
##
## So nothing here ever asks "how many versions of `libfoo` are in this
## workspace", or "in this lock file". Every question is asked of ONE link
## closure. Getting that wrong in the strict direction refuses a completely
## legal multi-application repository — NLF-DIA-1 — and getting it wrong in the
## permissive direction is silent at build time and an ODR violation at run
## time — NLF-DIA-4.
##
## ## What is a link edge, and what is not
##
## `propagation.DepPlatform` already carries the answer, because §4.6's three
## dependency lists mean three different things:
##
##   * `dpTarget`  — `uses:` / `buildDeps:`. HOST-platform, **linked into the
##     output**. This is the only kind the closure walk follows.
##   * `dpNative`  — `nativeBuildDeps:`. A BUILD-platform tool that is
##     *executed*, and whose output is consumed as bytes. §9.2 case 1: "no ABI
##     is shared; the artifact is bytes." Following it would refuse NLF-DIA-5,
##     the canonical motivating case of the whole design.
##   * `dpRuntime` — `runtimeDeps:`. Needed at run time, not linked.
##
## ## Why the policy default is per-language and not universal
##
## Q-11, settled 2026-08-18. The reason a second version of a C library in one
## binary is dangerous is that C links a flat native symbol table; the reason a
## second version of a Rust crate is safe is that Rust mangles per version.
## That is a property of the language, so the default is the language's. §9.3's
## naming rule still holds inside each convention: **silence means safe**, and
## a language nobody has written a convention for inherits `forbidden`.
##
## Q-11 also attaches a requirement rather than dismissing the objection to it:
## "the §9.4 diagnostic MUST state **where an inherited default came from** —
## naming the language convention and its source". `MultiVersionResolution`
## carries that, and `renderColinkingError` prints it. An inherited default
## that cannot be traced is the invisible-rule failure §4.7 is written against.
##
## ## Test-double policy
##
## No doubles, no test-only branches. The conventions below are the real
## conventions; the rendering below is the real diagnostic.

import std/[algorithm, sets, strutils, tables]

import ./declarations
import ./propagation

# ---------------------------------------------------------------------------
# §9.3 — the per-library property
# ---------------------------------------------------------------------------

type
  MultiVersionPolicy* = enum
    ## Whether several versions of one library may be linked into one binary.
    ##
    ## `mvUnset` is a THIRD state, not a synonym for `mvForbidden`, and the
    ## distinction is load-bearing twice over. §9.3 requires the effective
    ## answer for an undeclared library to be `forbidden`; Q-11 requires the
    ## diagnostic to say that the answer was **inherited** and from where. A
    ## two-valued enum could satisfy the first and could not express the
    ## second, and NLF-DIA-8 is exactly the case that separates them.
    mvUnset
    mvForbidden
    mvAllowed

  LanguageMultiVersionConvention* = object
    ## One language's default, and the citation the diagnostic prints for it.
    language*: string
    policy*: MultiVersionPolicy
    rationale*: string
      ## Why the language's runtime does or does not keep versions apart.
    source*: string
      ## Where the convention is written down, so a reader can go and read it.

  MultiVersionResolution* = object
    ## The effective policy for one library, and its provenance.
    policy*: MultiVersionPolicy
      ## Never `mvUnset`: resolution always terminates at `forbidden`.
    inherited*: bool
      ## True when the library's own recipe said nothing and the answer came
      ## from a language convention.
    convention*: LanguageMultiVersionConvention
      ## Meaningful only when `inherited`.

  LibraryMultiVersion* = object
    ## What a library declared, plus the language it is written in.
    library*: string
    declared*: MultiVersionPolicy
    language*: string
    sourceFile*: string
    sourceLine*: int
      ## §9.4 requires the error to cite "the declaration's file:line".

const
  MultiVersionConventionSource* =
    "repro_lock_files/diamond.nim (stdlib language conventions, Q-11)"
    ## The one place the conventions are written. Named in the diagnostic so
    ## an inherited default is findable from the error alone.

  FlatSymbolTableRationale* =
    "links a flat native symbol table, so two versions in one binary is a " &
    "duplicate-symbol failure at best and an ODR violation at worst"

proc languageMultiVersionConventions*(): seq[LanguageMultiVersionConvention] =
  ## Q-11's table. `forbidden` for anything linking a flat native symbol
  ## table; `allowed` only where the runtime keeps versions apart **by
  ## construction**, which is a claim about the language and not about a
  ## particular library's care.
  ##
  ## The list is deliberately short. A language that is not on it inherits
  ## `forbidden` (see `languageConventionFor`), which is §9.3's naming rule
  ## applied one level up: an absent convention must not be readable as a
  ## permission nobody granted.
  @[
    LanguageMultiVersionConvention(language: "c",
      policy: mvForbidden, rationale: "C " & FlatSymbolTableRationale,
      source: MultiVersionConventionSource),
    LanguageMultiVersionConvention(language: "cpp",
      policy: mvForbidden, rationale: "C++ " & FlatSymbolTableRationale,
      source: MultiVersionConventionSource),
    LanguageMultiVersionConvention(language: "objective-c",
      policy: mvForbidden,
      rationale: "Objective-C " & FlatSymbolTableRationale,
      source: MultiVersionConventionSource),
    LanguageMultiVersionConvention(language: "fortran",
      policy: mvForbidden, rationale: "Fortran " & FlatSymbolTableRationale,
      source: MultiVersionConventionSource),
    LanguageMultiVersionConvention(language: "ada",
      policy: mvForbidden, rationale: "Ada " & FlatSymbolTableRationale,
      source: MultiVersionConventionSource),
    LanguageMultiVersionConvention(language: "d",
      policy: mvForbidden, rationale: "D " & FlatSymbolTableRationale,
      source: MultiVersionConventionSource),
    LanguageMultiVersionConvention(language: "zig",
      policy: mvForbidden, rationale: "Zig " & FlatSymbolTableRationale,
      source: MultiVersionConventionSource),
    LanguageMultiVersionConvention(language: "nim",
      policy: mvForbidden,
      rationale: "Nim compiles through C and " & FlatSymbolTableRationale,
      source: MultiVersionConventionSource),
    LanguageMultiVersionConvention(language: "go",
      policy: mvForbidden,
      rationale: "Go links one package path once per binary and " &
        FlatSymbolTableRationale,
      source: MultiVersionConventionSource),
    LanguageMultiVersionConvention(language: "rust",
      policy: mvAllowed,
      rationale: "Rust mangles symbols per version, so two versions " &
        "coexist in one binary by construction",
      source: MultiVersionConventionSource),
    LanguageMultiVersionConvention(language: "python",
      policy: mvAllowed,
      rationale: "Python keeps versions apart at the module level",
      source: MultiVersionConventionSource),
    LanguageMultiVersionConvention(language: "javascript",
      policy: mvAllowed,
      rationale: "JavaScript keeps versions apart at the module level",
      source: MultiVersionConventionSource),
    LanguageMultiVersionConvention(language: "typescript",
      policy: mvAllowed,
      rationale: "TypeScript keeps versions apart at the module level",
      source: MultiVersionConventionSource),
    LanguageMultiVersionConvention(language: "java",
      policy: mvAllowed,
      rationale: "the JVM keeps versions apart at classloader boundaries",
      source: MultiVersionConventionSource),
    LanguageMultiVersionConvention(language: "kotlin",
      policy: mvAllowed,
      rationale: "the JVM keeps versions apart at classloader boundaries",
      source: MultiVersionConventionSource),
    LanguageMultiVersionConvention(language: "elixir",
      policy: mvAllowed,
      rationale: "BEAM keeps versions apart at application boundaries",
      source: MultiVersionConventionSource),
    LanguageMultiVersionConvention(language: "erlang",
      policy: mvAllowed,
      rationale: "BEAM keeps versions apart at application boundaries",
      source: MultiVersionConventionSource)]

proc normalizedLanguage(language: string): string =
  ## Fold the spellings a recipe may reasonably use onto the convention keys.
  ## `c++` and `cxx` are the same language as `cpp`; case is not significant.
  let l = language.strip().toLowerAscii()
  case l
  of "c++", "cxx", "cplusplus": "cpp"
  of "objc", "objectivec": "objective-c"
  of "js", "node", "nodejs": "javascript"
  of "ts": "typescript"
  of "py": "python"
  else: l

proc languageConventionFor*(language: string):
    LanguageMultiVersionConvention =
  ## The convention governing `language`, or the restrictive fallback.
  ##
  ## The fallback is `forbidden` and says so in its own rationale, because a
  ## library in a language nobody has characterised is exactly the library
  ## whose author never considered the question — §9.3's argument for the
  ## naming, applied to the convention table itself.
  let key = normalizedLanguage(language)
  for c in languageMultiVersionConventions():
    if c.language == key:
      return c
  LanguageMultiVersionConvention(
    language: if key.len > 0: key else: "(unspecified)",
    policy: mvForbidden,
    rationale:
      "no language convention names " &
      (if key.len > 0: "`" & key & "`" else: "this library's language") &
      ", and an absent convention is read as `forbidden` rather than as a " &
      "permission nobody granted",
    source: MultiVersionConventionSource)

proc resolveMultiVersion*(lib: LibraryMultiVersion): MultiVersionResolution =
  ## §9.3's resolution: the library's own declaration wins; silence inherits
  ## the language convention; and the terminus is `forbidden`.
  if lib.declared != mvUnset:
    return MultiVersionResolution(policy: lib.declared, inherited: false)
  let convention = languageConventionFor(lib.language)
  MultiVersionResolution(
    policy: (if convention.policy == mvUnset: mvForbidden
             else: convention.policy),
    inherited: true, convention: convention)

# ---------------------------------------------------------------------------
# §9.6 — the link closure
# ---------------------------------------------------------------------------

type
  LinkDep* = object
    ## One dependency edge as the diamond sees it: the child, which list it
    ## was written in, and the version range the parent demanded.
    name*: string
    platform*: DepPlatform
    constraint*: string

  LinkPackage* = object
    ## A package for the closure walk. Mirrors `PropPackage`, adding the
    ## per-edge constraint text (which the propagation does not need and the
    ## §9.4 diagnostic cannot do without) and the library's own declaration.
    name*: string
    pinnedLockFile*: string
    language*: string
    multiVersion*: MultiVersionPolicy
    sourceFile*: string
    sourceLine*: int
    deps*: seq[LinkDep]

  ReachedInstance* = object
    ## One library instance reached from one binary through link edges only.
    library*: string
    version*: string
    lockFile*: string
    path*: seq[string]
      ## The dependency path from the binary, e.g.
      ## `@["app", "libimaging", "libfoo"]`. §9.4: "The demanding **paths**,
      ## not just the demanding packages, are the load-bearing part."
    constraint*: string
      ## The range the LAST edge on the path demanded.
    demander*: string
      ## The package that declared that edge.

  LinkClosure* = object
    ## One binary and everything its link edges reach.
    binary*: string
    package*: string
    lockFile*: string
    reached*: seq[ReachedInstance]

proc linkPackage*(name: string; deps: openArray[LinkDep] = @[];
                  pinnedLockFile = ""; language = "c";
                  multiVersion = mvUnset;
                  sourceFile = ""; sourceLine = 0): LinkPackage =
  LinkPackage(name: name, pinnedLockFile: pinnedLockFile, language: language,
    multiVersion: multiVersion, sourceFile: sourceFile,
    sourceLine: sourceLine, deps: @deps)

proc linkDep*(name: string; constraint = ""; platform = dpTarget): LinkDep =
  LinkDep(name: name, platform: platform, constraint: constraint)

proc asPropPackages*(packages: openArray[LinkPackage]): seq[PropPackage] =
  ## Project onto the propagation's input shape, so designation is computed by
  ## `propagate` and not by a second walk here. Two walks over the same graph
  ## that must agree about which lock file governs an edge is two things to
  ## drift; §4.6's precedence lives in `childLockFile` and this module calls
  ## it rather than restating it.
  result = @[]
  for p in packages:
    var deps: seq[PropDep] = @[]
    for d in p.deps:
      deps.add(PropDep(name: d.name, platform: d.platform))
    result.add(PropPackage(name: p.name, pinnedLockFile: p.pinnedLockFile,
      deps: deps))

proc linkClosures*(roots: openArray[PropRoot];
                   packages: openArray[LinkPackage];
                   versionOf: proc(demander, library, lockFile: string):
                     string {.closure.}): seq[LinkClosure] =
  ## Walk each root artifact's **link** closure and record every library
  ## instance it reaches.
  ##
  ## `versionOf` answers "which version does the edge `demander -> library`,
  ## resolved under `lockFile`, bind to". It is a parameter rather than a
  ## field on `LinkPackage` because the answer is the SOLVE's, and this module
  ## is deliberately below the solver: `repro_lock_files` is a `std`-only leaf
  ## by construction (see `repro_lock_files.nim`'s header) and reaching for
  ## `repro_solver` here would put the whole solver under the project DSL's
  ## macros.
  ##
  ## Only `dpTarget` edges are followed. See the module header for why
  ## following `dpNative` would refuse NLF-DIA-5.
  ##
  ## The walk is per (package, lock file, path) rather than per package: a
  ## package reached twice by two different paths must contribute BOTH paths,
  ## because the paths are what the §9.4 diagnostic prints and reporting one
  ## of them tells the author half of what to move. Cycles are cut by
  ## refusing to revisit a (package, lock file) pair already on the CURRENT
  ## path, which terminates without collapsing distinct paths.
  var byName = initTable[string, LinkPackage]()
  for p in packages:
    byName[p.name] = p

  result = @[]
  for r in roots:
    let rootPin =
      if byName.hasKey(r.package): byName[r.package].pinnedLockFile else: ""
    let rootLock =
      if rootPin.len > 0: rootPin
      elif r.lockFile.len > 0: r.lockFile
      else: DefaultLockFileName
    var closure = LinkClosure(binary: r.artifact, package: r.package,
      lockFile: rootLock, reached: @[])

    proc walk(pkg, lock: string; path: seq[string];
              onPath: HashSet[string]) =
      if not byName.hasKey(pkg): return
      for dep in byName[pkg].deps:
        if dep.platform != dpTarget: continue
        let depPin =
          if byName.hasKey(dep.name): byName[dep.name].pinnedLockFile else: ""
        let childLock = childLockFile(lock,
          PropDep(name: dep.name, platform: dep.platform), depPin)
        let key = dep.name & "\x1f" & childLock
        if key in onPath: continue
        let childPath = path & @[dep.name]
        closure.reached.add(ReachedInstance(
          library: dep.name,
          version: versionOf(pkg, dep.name, childLock),
          lockFile: childLock, path: childPath,
          constraint: dep.constraint, demander: pkg))
        var nextOnPath = onPath
        nextOnPath.incl(key)
        walk(dep.name, childLock, childPath, nextOnPath)

    var seed = initHashSet[string]()
    seed.incl(r.package & "\x1f" & rootLock)
    walk(r.package, rootLock, @[r.package], seed)
    result.add(closure)

# ---------------------------------------------------------------------------
# §9.4 — the co-linking check and its diagnostic
# ---------------------------------------------------------------------------

type
  ColinkingConflict* = object
    ## One binary linking one library at two or more versions, where the
    ## library's effective policy forbids it.
    binary*: string
    lockFile*: string
    library*: string
    resolution*: MultiVersionResolution
    declSite*: string
      ## `file:line` of the `multiVersion` declaration, or `""` when the
      ## policy was inherited and there is no declaration to cite.
    instances*: seq[ReachedInstance]
      ## One entry per distinct version, each carrying its demanding path.
    unificationAttempted*: bool
      ## Always true on the path that produces this record, and printed,
      ## because §9.4 requires the message to say so: "a reader who does not
      ## know that will reasonably assume the tool simply refused."
    unificationFailure*: string
      ## Why unification could not succeed, in the constraints' own terms.

  SplitReport* = object
    ## §9.1 / NLF-DIA-7 — a library the solve could not unify, reported
    ## whether or not anybody objected to it.
    library*: string
    versions*: seq[string]
    constraints*: seq[string]
    lockFiles*: seq[string]

proc versionsIn(instances: openArray[ReachedInstance]): seq[string] =
  var seen = initHashSet[string]()
  result = @[]
  for i in instances:
    if i.version.len == 0: continue
    if i.version in seen: continue
    seen.incl(i.version)
    result.add(i.version)
  result.sort()

proc renderPath(path: openArray[string]; constraint: string): string =
  result = path.join("  ->  ")
  if constraint.len > 0:
    result.add("  " & constraint)

proc unificationFailureText*(instances: openArray[ReachedInstance]): string =
  ## §9.4's "unification was attempted and failed: no version satisfies both
  ## `>=2.0 <3.0` and `>=1.4 <2.0`." Built from the constraints the edges
  ## actually carried, so the sentence names the real ranges rather than
  ## asserting a generic incompatibility.
  var seen = initHashSet[string]()
  var ranges: seq[string] = @[]
  for i in instances:
    if i.constraint.len == 0: continue
    if i.constraint in seen: continue
    seen.incl(i.constraint)
    ranges.add("`" & i.constraint & "`")
  if ranges.len == 0:
    return "unification was attempted and failed"
  if ranges.len == 1:
    return "unification was attempted and failed: " & ranges[0] &
      " cannot be satisfied by one version here"
  result = "unification was attempted and failed: no version satisfies " &
    (if ranges.len == 2: "both " else: "all of ") & ranges.join(" and ")

proc findColinkingConflicts*(closures: openArray[LinkClosure];
                             packages: openArray[LinkPackage]):
    seq[ColinkingConflict] =
  ## The check, evaluated **per link closure**.
  ##
  ## A workspace containing two versions of one library produces no record
  ## here unless some single binary reaches both — which is the corpus's scope
  ## rule and the reason this proc takes closures rather than a package set.
  var byName = initTable[string, LinkPackage]()
  for p in packages:
    byName[p.name] = p

  result = @[]
  for closure in closures:
    var byLibrary = initOrderedTable[string, seq[ReachedInstance]]()
    for reached in closure.reached:
      if not byLibrary.hasKey(reached.library):
        byLibrary[reached.library] = @[]
      byLibrary[reached.library].add(reached)
    for library, instances in byLibrary.pairs:
      let versions = versionsIn(instances)
      if versions.len < 2: continue
      let decl =
        if byName.hasKey(library): byName[library]
        else: LinkPackage(name: library, multiVersion: mvUnset)
      let resolution = resolveMultiVersion(LibraryMultiVersion(
        library: library, declared: decl.multiVersion,
        language: decl.language, sourceFile: decl.sourceFile,
        sourceLine: decl.sourceLine))
      if resolution.policy == mvAllowed: continue
      # One representative instance per distinct version, keeping the FIRST
      # path that reached it: the first is the shortest by construction of
      # the breadth of the walk, and a long path is harder to act on.
      var representative: seq[ReachedInstance] = @[]
      var taken = initHashSet[string]()
      for v in versions:
        for i in instances:
          if i.version == v and v notin taken:
            taken.incl(v)
            representative.add(i)
      result.add(ColinkingConflict(
        binary: closure.binary, lockFile: closure.lockFile,
        library: library, resolution: resolution,
        declSite:
          (if resolution.inherited or decl.sourceFile.len == 0: ""
           else: decl.sourceFile & ":" & $decl.sourceLine),
        instances: representative,
        unificationAttempted: true,
        unificationFailure: unificationFailureText(representative)))

proc renderColinkingError*(conflict: ColinkingConflict): string =
  ## §9.4's diagnostic, in the shape the design writes it.
  ##
  ## Every element the corpus asks NLF-DIA-2 to assert on separately is a
  ## separate line here: both versions, both dependency paths, the
  ## declaration's `file:line`, the statement that unification was attempted,
  ## and — for an inherited default — the convention it came from (Q-11).
  ##
  ## The `resolutions:` block carries THREE remedies, not two. §9.4: "A user
  ## who has hit an irreconcilable co-linking conflict is precisely the user
  ## who needs to know that lock-file scope is adjustable", and the third one
  ## — separate the consumers into different lock files — is Spack's
  ## scope-widening remedy, which is the one an error that never mentions it
  ## hides at the exact moment it would help.
  result = "error: `" & conflict.library &
    "` cannot be linked at two versions into one binary\n"
  if conflict.resolution.inherited:
    result.add("  " & conflict.library &
      " declares no `multiVersion`; it inherits `multiVersion forbidden` " &
      "from the " & conflict.resolution.convention.language &
      " language convention\n")
    result.add("    " & conflict.resolution.convention.rationale & "\n")
    result.add("    convention source: " &
      conflict.resolution.convention.source & "\n")
  else:
    result.add("  " & conflict.library &
      " declares `multiVersion forbidden`")
    if conflict.declSite.len > 0:
      result.add(" (" & conflict.declSite & ")")
    result.add("\n")
  result.add("\n  " & conflict.binary & " (lock file `" &
    conflict.lockFile & "`) requires both:\n\n")
  for instance in conflict.instances:
    result.add("    " & conflict.library & " " & instance.version & "\n")
    result.add("      " & renderPath(instance.path, instance.constraint) &
      "\n")
  result.add("\n  " & conflict.unificationFailure & ".\n")
  result.add("\n  resolutions:\n")
  result.add("    - relax one constraint so a single version satisfies " &
    "every demander\n")
  result.add("    - if " & conflict.library &
    " is genuinely safe to co-link, declare\n" &
    "        multiVersion allowed\n" &
    "      in its `api:` block — see §9.3 for when this is true\n")
  result.add("    - separate the consumers into different lock files, if " &
    "they need not\n      share a binary at all\n")

proc renderSplitReport*(report: SplitReport): string =
  ## NLF-DIA-7 — a split is reported, not silent.
  ##
  ## "A build that quietly produces two copies of a library is how a closure
  ## doubles without anyone noticing, and it is the observability half of §8's
  ## argument that trimming is not needed at v1 — that argument depends on
  ## explosion being *visible*."
  result = "note: `" & report.library & "` was split into " &
    $report.versions.len & " instances\n"
  for v in report.versions:
    result.add("    " & report.library & " " & v & "\n")
  if report.constraints.len > 0:
    result.add("  forced by: " & report.constraints.join(", ") & "\n")
  if report.lockFiles.len > 0:
    result.add("  under lock files: " & report.lockFiles.join(", ") & "\n")
  result.add("  unification was attempted first and could not satisfy " &
    "every demander with one version.\n")
