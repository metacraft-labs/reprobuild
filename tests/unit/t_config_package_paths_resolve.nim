## Every package `config.nims` declares must actually get a `--path`, and
## the environment variable must be the route that wins.
##
## Why this gate exists, in the words of what went wrong without it. An
## agent set out to change the engine, found that neither `libs/nim-bearssl`
## nor `../nim-bearssl` exists in this workspace, watched
## `apps/repro/repro.nim` fail to compile, and concluded — in writing, and
## then acted on it for a whole work item — that "the engine cannot be
## compiled in this workspace at all". The absence was real. The conclusion
## was wrong: `addPackagePath` consults the ENVIRONMENT VARIABLE before the
## directory candidates, the flake declares the source as an input, and the
## development shell exports `BEARSSL_SRC`. Exporting that one variable
## builds the engine from an otherwise untouched ambient shell.
##
## Two things made the wrong conclusion reasonable, and this file pins both:
##
##   1. Nothing asserted that the declared packages resolve. The first
##      symptom of an unresolved one is `cannot open file: bearssl/ec`
##      tens of modules later, a message that names neither the variable,
##      nor `config.nims`, nor the shell.
##   2. Nothing asserted that the variable is preferred over the
##      directories. Read the call site alone and "the directories are the
##      route" is a perfectly natural reading.
##
## `config.nims` is a NimScript evaluated by the compiler's configuration
## stage, so its procs cannot be `import`ed. Re-implementing them here would
## produce a mirror that can drift from the original and assert nothing about
## it — the existing `t_config_nims_lib_resolution.nim` is explicitly that
## shape and says so. This gate instead RUNS the real file: `nim dump
## --dump.format:json` evaluates the project's `config.nims` and prints the
## resulting `--path` set, without compiling anything. Every assertion below
## is made against that output, so nothing here can agree with a `config.nims`
## that has stopped working.
##
## No mocks. The compiler is the real compiler, the configuration file is
## the repository's own, and the temporary trees are real directories.

import std/[json, os, osproc, sequtils, streams, strtabs, strutils,
            tempfiles, unittest]

const
  MinimumDeclaredPackages = 12
    ## A parser that silently matched nothing would make every per-package
    ## assertion below vacuously true. `config.nims` declares fourteen
    ## packages today; this floor is what stops a broken parse from passing
    ## as a clean tree.
  RequiredPackageNames = [
    "BEARSSL_SRC",
    "FASTSTREAMS_SRC",
    "NIMCRYPTO_SRC",
    "SHM_GSET_SRC",
    "SHM_QUEUE_SRC",
    "STACKABLE_HOOKS_SRC",
  ]
    ## Named individually rather than counted, so dropping one and adding
    ## an unrelated one cannot keep the total up. `BEARSSL_SRC` is here
    ## because it is the one the wrong conclusion was about.
  PreferenceProbeName = "RESULTS_SRC"
    ## The package used to prove the variable beats the directories. It is
    ## chosen for a property the assertion depends on: its only candidate,
    ## `libs/results/src`, is INSIDE this repository, so the preference can
    ## be exercised on any checkout without requiring a sibling. The test
    ## asserts that property before it relies on it.
  PreferenceProbeMarker = "results.nim"
  PreferenceProbeCandidate = "libs/results/src"

type
  PackageDecl = object
    envName: string
    marker: string
    optional: bool

proc reproRoot(): string =
  ## Walk up from this source file to the repository root — the directory
  ## that owns both `config.nims` and the engine entry point. The test is
  ## run from several different working directories, so the walk is
  ## anchored at `currentSourcePath` rather than at the cwd.
  var dir = parentDir(currentSourcePath())
  while dir.len > 0 and dir != parentDir(dir):
    if fileExists(dir / "config.nims") and
       fileExists(dir / "apps" / "repro" / "repro.nim"):
      return dir
    dir = parentDir(dir)
  raise newException(IOError,
    "could not locate the repository root from " & currentSourcePath())

proc nimExe(): string =
  ## Prefer `$NIM` (the CI / env seed), then PATH. A missing compiler is a
  ## FAILURE here and not a skip: this gate's whole subject is what the
  ## compiler does with the configuration file, so "no compiler" means the
  ## gate did not run, and a gate that reports success when it did not run
  ## is the failure this file was written to prevent.
  let fromEnv = getEnv("NIM")
  if fromEnv.len > 0 and fileExists(fromEnv):
    return fromEnv
  result = findExe("nim")

proc stripNimComments(text: string): string =
  ## Remove `#` comments outside string literals, line by line. Without
  ## this, a declaration that has been COMMENTED OUT still parses as a
  ## declaration, and the positive check below would demand a `--path` for
  ## a package nobody asks for any more — or, worse, a deleted declaration
  ## could be "restored" as a comment and keep the count up.
  var lines: seq[string] = @[]
  for raw in text.splitLines():
    var kept = ""
    var inString = false
    var i = 0
    while i < raw.len:
      let c = raw[i]
      if inString:
        kept.add c
        if c == '\\' and i + 1 < raw.len:
          kept.add raw[i + 1]
          inc i
        elif c == '"':
          inString = false
      elif c == '"':
        inString = true
        kept.add c
      elif c == '#':
        break
      else:
        kept.add c
      inc i
    lines.add kept
  lines.join("\n")

proc quotedAfter(text: string; start: int): (string, int) =
  ## Read the next double-quoted literal at or after `start`. Returns the
  ## literal's contents and the index just past its closing quote, or
  ## `("", -1)` when there is none.
  var i = start
  while i < text.len and text[i] != '"':
    inc i
  if i >= text.len:
    return ("", -1)
  inc i
  var value = ""
  while i < text.len and text[i] != '"':
    value.add text[i]
    inc i
  if i >= text.len:
    return ("", -1)
  (value, i + 1)

proc parseDeclaredPackages(configText: string): seq[PackageDecl] =
  ## Extract every package `config.nims` registers, from the file itself.
  ##
  ## The two registration spellings are `addPackagePath(ENV, [candidates],
  ## MARKER, ...)` and `addSiblingFirstPackagePath(SIBLING, ENV, MARKER)`.
  ## They differ in where the variable and the marker sit, so each is
  ## handled explicitly rather than by a shared "first and last string"
  ## heuristic that would silently mis-read one of them.
  let text = stripNimComments(configText)
  var i = 0
  while true:
    let direct = text.find("addPackagePath(", i)
    let sibling = text.find("addSiblingFirstPackagePath(", i)
    if direct < 0 and sibling < 0:
      break
    let siblingFirst = direct < 0 or (sibling >= 0 and sibling < direct)
    let at = if siblingFirst: sibling else: direct
    let open = text.find('(', at)
    # Balance parentheses so the argument text ends at THIS call's closing
    # paren and not at some later one. A forward scan for the next `)` would
    # stop inside the candidate array's own nested calls.
    var depth = 0
    var j = open
    while j < text.len:
      if text[j] == '(': inc depth
      elif text[j] == ')':
        dec depth
        if depth == 0: break
      inc j
    if j >= text.len:
      break
    let args = text[open + 1 ..< j]
    # Advance FIRST. An occurrence this scan cannot read -- the `proc`
    # declarations themselves, whose parameter lists carry no string
    # literals at all, and the generic forwarding call inside
    # `addSiblingFirstPackagePath`, whose arguments are identifiers -- must
    # be skipped, not treated as the end of the file. Stopping at the first
    # unreadable occurrence is how an earlier draft of this parser returned
    # an EMPTY list: the proc declaration is the first match in the file,
    # and every real registration comes after it.
    i = j + 1

    # Split the argument text into GROUPS. A group is one `"literal"`, or a
    # run of them joined by the path operator -- `"a" / "b" / "c.nim"` is
    # ONE group, because that is how `config.nims` spells both a candidate
    # directory and a nested marker. Reading them as separate literals is
    # not a small imprecision: it makes the third argument of
    # `addSiblingFirstPackagePath(".." / "nim-shm-queue" / "src", ...)`
    # land on `"nim-shm-queue"`, so the gate would then demand a `--path`
    # for a package that does not exist and pass over the one that does.
    var groups: seq[tuple[value: string, startsAt: int]] = @[]
    var scan = 0
    while scan < args.len:
      # Where the group STARTS is the opening quote, not where the search
      # began. The distinction decides which group is the marker: the
      # marker is the first one that opens after the candidate array
      # closes, and a group recorded at the end of the PREVIOUS literal
      # sits before that bracket rather than after it.
      let quoteAt = args.find('"', scan)
      if quoteAt < 0:
        break
      let (first, afterFirst) = quotedAfter(args, quoteAt)
      if afterFirst < 0:
        break
      var value = first
      var cursor = afterFirst
      while true:
        let rest = args[cursor ..< args.len].strip(trailing = false)
        if not rest.startsWith("/"):
          break
        let (part, next) = quotedAfter(args, cursor)
        if next < 0:
          break
        value = value / part
        cursor = next
      groups.add (value, quoteAt)
      scan = cursor

    var decl = PackageDecl(optional: args.contains("optional = true"))
    if siblingFirst:
      # (sibling, envName, marker)
      if groups.len < 3: continue
      decl.envName = groups[1].value
      decl.marker = groups[2].value
    else:
      # (envName, [candidates], marker, ...): the variable is the first
      # group; the marker is the first group that starts after the
      # candidate array closes.
      if groups.len == 0: continue
      decl.envName = groups[0].value
      let bracket = args.find('[')
      let bracketEnd = if bracket < 0: 0 else: args.find(']', bracket)
      for g in groups[1 ..< groups.len]:
        if g.startsAt > bracketEnd:
          decl.marker = g.value
          break
    if decl.envName.len > 0 and decl.marker.len > 0:
      result.add decl

proc runNimDump(nim, workDir: string;
                env: openArray[(string, string)] = []): (int, string) =
  ## Evaluate the `config.nims` that governs `workDir` and return
  ## (exit code, combined output). `nim dump` runs the configuration stage
  ## and nothing else, so this is cheap and compiles no code. The project
  ## file is deliberately one that does not exist: `nim dump` never opens
  ## it, and naming a path INSIDE `workDir` is what makes the configuration
  ## file's relative candidates resolve the way a real build resolves them.
  var e = newStringTable()
  for k, v in envPairs():
    e[k] = v
  for (k, v) in env:
    e[k] = v
  let p = startProcess(nim,
    workingDir = workDir,
    args = @["dump", "--dump.format:json", "./__package_path_probe__.nim"],
    env = e,
    options = {poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (code, output)

proc libPathsOf(output: string): seq[string] =
  ## Pull `lib_paths` out of a `nim dump` run. The JSON object is located by
  ## its first `{`, because `config.nims` is allowed to print a warning
  ## ahead of it (an OPTIONAL package that did not resolve does exactly
  ## that) and that warning is not JSON.
  let start = output.find('{')
  doAssert start >= 0, "nim dump produced no JSON object:\n" & output
  let parsed = parseJson(output[start .. ^1])
  for entry in parsed["lib_paths"]:
    result.add entry.getStr()

suite "config.nims resolves every package it declares":

  let root = reproRoot()
  let nimBin = nimExe()
  let configText = readFile(root / "config.nims")
  let declaredPackages = parseDeclaredPackages(configText)

  test "the compiler this gate needs is present":
    # Stated as its own case so an absent compiler reads as a red gate with
    # a reason, not as a suite that quietly asserted nothing.
    check nimBin.len > 0
    check fileExists(nimBin)

  test "config.nims declares the packages this gate speaks for":
    check declaredPackages.len >= MinimumDeclaredPackages
    let names = declaredPackages.mapIt(it.envName)
    for required in RequiredPackageNames:
      check required in names
    for decl in declaredPackages:
      check decl.marker.len > 0

  test "every declared package gets a --path carrying its marker":
    let (code, output) = runNimDump(nimBin, root)
    check code == 0
    let paths = libPathsOf(output)
    var unresolved: seq[string] = @[]
    for decl in declaredPackages:
      if decl.optional:
        # An optional package is allowed to be absent, but it is NOT
        # allowed to be absent silently: `config.nims` must have said so.
        # This is the honest-absence case, asserted rather than skipped.
        let resolved = paths.anyIt(fileExists(it / decl.marker))
        if not resolved:
          check output.contains("added no --path for " & decl.envName)
        continue
      if not paths.anyIt(fileExists(it / decl.marker)):
        unresolved.add decl.envName & " (wanted " & decl.marker & ")"
    check unresolved.len == 0
    if unresolved.len > 0:
      echo "unresolved packages: ", unresolved.join(", ")

  test "the environment variable is preferred over the directories":
    # THE case the wrong conclusion turned on. Both routes are made
    # available at once and the variable must win.
    #
    # The precondition is asserted, not assumed: if the in-repo candidate
    # directory were absent, the variable would win by default and this
    # case would prove nothing at all.
    let candidate = root / PreferenceProbeCandidate
    check fileExists(candidate / PreferenceProbeMarker)

    let decoy = createTempDir("repro-pkg-path-", "-env")
    try:
      writeFile(decoy / PreferenceProbeMarker,
        "## stand-in for the real package; only its presence matters\n")
      let (code, output) = runNimDump(nimBin, root,
        {PreferenceProbeName: decoy})
      check code == 0
      let paths = libPathsOf(output)
      check decoy in paths
      check candidate notin paths
    finally:
      removeDir(decoy)

  test "an unresolved package is reported, naming the fix":
    # NEGATIVE. `config.nims` is evaluated in a bare directory where no
    # candidate exists and no variable is set, so nothing can resolve.
    # Silence here is the defect this gate is named for, so the assertion
    # is that the configuration stage SAYS which package, which variable,
    # which marker and what to do about it.
    let bare = createTempDir("repro-pkg-path-", "-bare")
    try:
      copyFile(root / "config.nims", bare / "config.nims")
      var cleared: seq[(string, string)] = @[]
      for decl in declaredPackages:
        cleared.add (decl.envName, "")
      let (code, output) = runNimDump(nimBin, bare, cleared)
      check output.contains("config.nims added no --path for ")

      # Every package the report named must be one config.nims actually
      # declares, and each must carry its OWN marker — not merely the
      # headline, and not another package's marker.
      var named: seq[string] = @[]
      for decl in declaredPackages:
        if output.contains("added no --path for " & decl.envName):
          named.add decl.envName
          check output.contains("wanted a directory containing: " &
            decl.marker)
      check named.len > 0
      check output.contains("$" & named[0] & ": unset")
      check output.contains("which exports " & named[0])
      check output.contains("nix develop")

      # AND THE BUILD PROCEEDS. This is not decoration; it is the property
      # the first version of this fix got wrong, and it was wrong in a way
      # no ambient run could show. That version ended in `quit(1)`, and the
      # engine's project-interface extraction — which compiles a STORE COPY
      # of this repository where none of the vendored `libs/` trees exist,
      # supplying its own `--path` flags — died on the first unresolved
      # package, taking a previously working build with it. A configuration
      # file cannot know whether an unresolved package is WANTED by the
      # compilation about to run.
      #
      # So: exit 0, and the report covers EVERY unresolved package rather
      # than stopping at the first. The multi-package check is what makes
      # this a real assertion — a config that refused at the first one
      # would name exactly one.
      check code == 0
      check named.len > 1
      check output.contains("the build CONTINUES without it")
    finally:
      removeDir(bare)
