## S7 — no BUILD path may be left unable to reach the CAS-restore
## configuration, and a new one may not quietly opt out.
##
## This is a structural audit over ``repro_cli_support.nim``'s source, and
## it is that shape on purpose: the defect S7 exists to close was found by
## reading the source, not by running anything. Every explicit
## ``BuildEngineConfig(...)`` construction in that file hard-coded
## ``rebuildMissingOutputsOnCacheHit: true``, and six of seven also
## hard-coded ``deferLocalOutputBlobs: true``. Nothing failed. Nothing was
## slow in a way anyone could attribute. The only visible symptom was that
## all 181 published records on the reference host were ``opkMetadataOnly``
## and a clean checkout with a warm cache still rebuilt everything.
##
## A behavioural test cannot catch the regression this guards. If someone
## adds an EIGHTH engine config for a new build entry point and forgets the
## opt-in, every existing behavioural test still passes — the new path is
## simply, silently, unable to restore, exactly as all seven were. What
## catches it is an assertion over the construction sites themselves, in
## the same spirit as ``auditGoverningLockIdentity``'s whole-graph sweep:
## assert over the population, so a newly added member cannot opt out by
## not being looked at.
##
## There are TWO populations, and saying "the construction sites" alone was
## the mistake this file was first submitted with. A build entry point can
## opt out without constructing anything: ``repro watch`` called
## ``executeBuildTarget`` without the parameter and read no environment, so
## it could not restore by either route, and an audit keyed on
## ``BuildEngineConfig(`` could not see it. Both populations are swept here
## — the construction sites AND the ``executeBuildTarget`` call sites — and
## neither sweep is sufficient alone.
##
## The end-to-end behaviour — that a real ``repro build
## --restore-cached-outputs`` stores blobs and restores a deleted output,
## and that the same build without the flag does not — is
## ``tests/integration/t_s7_repro_build_restores_a_deleted_output.nim``.

import std/[os, strutils, unittest]

const RepoMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc cliSupportSource(): string =
  readFile(findRepoRoot() / "libs" / "repro_cli_support" / "src" /
    "repro_cli_support.nim")

type ConfigSite = object
  ## One ``var <name> = BuildEngineConfig(`` construction.
  variableName: string
  line: int

proc configSites(source: string): seq[ConfigSite] =
  let lines: seq[string] = source.splitLines()
  for i, raw in lines:
    let line = raw.strip()
    if not line.endsWith("= BuildEngineConfig("):
      continue
    if not line.startsWith("var "):
      continue
    let name = line["var ".len ..< line.find(" =")]
    result.add(ConfigSite(variableName: name.strip(), line: i + 1))

# The construction sites that are NOT build paths, named individually
# rather than pattern-matched.
#
# Each is a single internal helper edge run in its own one-action engine —
# the interface-extract edge, the CMake regeneration edge, and the
# provider-compile edge (which has three call sites). They are out of S7's
# scope for a concrete reason rather than by oversight: their product is
# consumed immediately by the same process, in the same invocation, and the
# provider-compile one produces the binary that process is about to
# execute. Restoring those is a separable question with its own hazards,
# and S7 deliberately does not answer it.
#
# If a future change makes one of them a build path, deleting its name here
# is the reviewable one-line statement of that.
const NonBuildPathConfigVariables = [
  "edgeConfig",                 # __repro_interface_extract
  "cmakeRegenerationConfig",    # CMake regeneration edge
  "providerCompileConfig",      # provider compile (three sites)
]

# The build-path configs. Both live in ``executeBuildTarget`` and both are
# named ``engineConfig``: one in ``runLoweredGraphBuild``, one on the main
# inline path an ordinary ``repro build <target>`` reaches.
const BuildPathConfigVariable = "engineConfig"

suite "S7 every build-path engine config can reach the restore configuration":

  test "the construction sites partition into build paths and named helpers":
    ## Fails if a NEW ``var <something> = BuildEngineConfig(`` appears whose
    ## name is neither the build-path name nor one of the helpers listed
    ## above. That is the "quietly opt out" case: the author of the new site
    ## has to decide, in this file, which side it is on.
    let sites = configSites(cliSupportSource())
    check sites.len >= 7
    var unclassified: seq[string] = @[]
    for site in sites:
      if site.variableName == BuildPathConfigVariable:
        continue
      if site.variableName in NonBuildPathConfigVariables:
        continue
      unclassified.add(site.variableName & " at line " & $site.line)
    checkpoint("unclassified: " & unclassified.join(", "))
    check unclassified.len == 0

  test "every build-path config takes the restore opt-in":
    ## The load-bearing assertion. Each ``engineConfig`` construction must
    ## be followed, before the next construction site, by the guarded
    ## ``enableCachedOutputRestore()`` call — so the flag's effect does not
    ## depend on which of the two build paths an invocation happened to
    ## take. (``--peer-cache=…`` selects the other one.)
    let source = cliSupportSource()
    let lines = source.splitLines
    let sites = configSites(source)
    var buildPathSites = 0
    var optedIn = 0
    for site in sites:
      if site.variableName != BuildPathConfigVariable:
        continue
      inc buildPathSites
      var sawGuard = false
      var sawCall = false
      # Scan forward to the end of this construction's follow-up block. 80
      # lines is well past the wiring that follows each construction and
      # well short of the next one.
      for i in site.line ..< min(site.line + 80, lines.len):
        let line = lines[i].strip()
        if line == "if restoreCachedOutputs:":
          sawGuard = true
        if line == BuildPathConfigVariable & ".enableCachedOutputRestore()":
          sawCall = true
      checkpoint("site at line " & $site.line & " guard=" & $sawGuard &
        " call=" & $sawCall)
      if sawGuard and sawCall:
        inc optedIn
    check buildPathSites == 2
    check optedIn == buildPathSites

  test "every executeBuildTarget CALLER forwards the opt-in":
    ## The audit above closes the new-CONSTRUCTION route. It does not close
    ## the new-CALLER route, and that distinction is not academic: ``repro
    ## watch`` drove ``executeBuildTarget`` without the parameter and read no
    ## environment, so it could not restore by either route — a build entry
    ## point that had quietly opted out, invisible to a check keyed on
    ## ``BuildEngineConfig(`` sites because it constructs none of its own.
    ##
    ## So the population asserted here is the call sites. A new command that
    ## drives a build has to say ``restoreCachedOutputs = …`` or fail this.
    let source = cliSupportSource()
    let lines = source.splitLines
    var callSites = 0
    var forwarding = 0
    var missing: seq[string] = @[]
    for i, raw in lines:
      let line = raw.strip()
      if "executeBuildTarget(" notin line:
        continue
      if line.startsWith("proc executeBuildTarget("):
        continue
      if line.startsWith("#") or line.startsWith("##"):
        continue
      inc callSites
      # Scan the argument block. Call sites here are multi-line keyword-
      # argument lists; 30 lines clears the longest of them.
      var forwards = false
      for j in i ..< min(i + 30, lines.len):
        if "restoreCachedOutputs = " in lines[j]:
          forwards = true
          break
        if lines[j].strip().endsWith(")") and j > i:
          break
      if forwards:
        inc forwarding
      else:
        missing.add("line " & $(i + 1))
    checkpoint("call sites without the opt-in: " & missing.join(", "))
    check callSites >= 5
    check forwarding == callSites

  test "the flag and its environment default are both parsed":
    ## ``--restore-cached-outputs`` has to be a real flag: the build parser
    ## rejects any unrecognised argument starting with ``-``, so a missing
    ## branch here is a hard error rather than a silently ignored request.
    ## The negative spelling is asserted too — a mode with no way to turn it
    ## back off cannot be put in a shell profile.
    ##
    ## The environment default goes through ONE helper,
    ## ``restoreCachedOutputsEnvDefault``, and the assertion is that
    ## ``getEnv`` for this variable appears nowhere else. Two commands read
    ## it (``repro build`` and ``repro watch``) and two copies of a default
    ## is how they come to disagree.
    ##
    ## Recorded because the milestone first got it backwards: the FLAG
    ## reaches a daemon-hosted build (the daemon re-parses the client's
    ## ``request.rawArgs`` through ``runBuildCommand``), and it is the ENV
    ## spelling that a daemon started earlier does not see. The env variable
    ## is a session/CI convenience, not the only route in.
    let source = cliSupportSource()
    check "elif arg == \"--restore-cached-outputs\":" in source
    check "elif arg == \"--no-restore-cached-outputs\":" in source
    check "proc restoreCachedOutputsEnvDefault(): bool =" in source
    check source.count("getEnv(\"REPRO_RESTORE_CACHED_OUTPUTS\")") == 1
    check source.count("restoreCachedOutputsEnvDefault()") >= 3

  test "the opt-in is not spelled out field by field at the call sites":
    ## ``enableCachedOutputRestore`` groups three fields that must move
    ## together (blobs stored, restore branch taken, gate on). A caller that
    ## set two of them by hand would get either disk spent on a branch it
    ## cannot take or the restore branch without the gate — the exact hazard
    ## the milestone refused to ship. So the CLI must not assign these
    ## fields directly outside the constructions themselves.
    let source = cliSupportSource()
    check "engineConfig.requireCompleteOutputEvidence" notin source
    check "engineConfig.rebuildMissingOutputsOnCacheHit" notin source
    check "engineConfig.deferLocalOutputBlobs" notin source
